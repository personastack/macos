import Foundation
import PersonaStackCore
import WebKit

@MainActor
protocol DesktopVoicePermissionPage: AnyObject {
    func test(id: String, completion: @escaping (Result<Bool, Error>) -> Void)
    func cancel(id: String)
}

@MainActor
final class DesktopVoicePermissionWebPage: DesktopVoicePermissionPage {
    typealias Evaluate = (String, [String: Any], @escaping (Result<Any, Error>) -> Void) -> Void
    private let evaluate: Evaluate
    private let isCapturing: () -> Bool

    init(view: WKWebView) {
        isCapturing = { [weak view] in view.map { $0.microphoneCaptureState != WKMediaCaptureState.none } ?? true }
        evaluate = { [weak view] script, arguments, completion in
            guard let view else { completion(.failure(DesktopVoicePermissionError.pageChanged)); return }
            view.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in completion(result) }
        }
    }

    init(isCapturing: @escaping () -> Bool, evaluate: @escaping Evaluate) {
        self.isCapturing = isCapturing
        self.evaluate = evaluate
    }

    func test(id: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        guard !isCapturing() else { completion(.failure(DesktopVoicePermissionError.busy)); return }
        evaluate(DesktopVoicePermissionScript.test, ["testID": id]) { result in
            switch result {
            case .success(let value):
                if value as? String == "ready" { completion(.success(true)) }
                else { completion(.failure(DesktopVoicePermissionError(result: value as? String))) }
            case .failure(let error):
                completion(.failure(error as? DesktopVoicePermissionError ?? .evaluationFailed))
            }
        }
    }

    func cancel(id: String) {
        evaluate(DesktopVoicePermissionScript.cancel, ["expectedID": id]) { _ in }
    }
}

enum DesktopVoicePermissionError: Error {
    case busy, timedOut, pageChanged, unsupported, denied, noInput, emptyRecording, recordingFailed, evaluationFailed

    init(result: String?) {
        switch result {
        case "busy": self = .busy
        case "timedOut": self = .timedOut
        case "cancelled": self = .pageChanged
        case "unsupported": self = .unsupported
        case "denied": self = .denied
        case "noInput": self = .noInput
        case "empty": self = .emptyRecording
        default: self = .recordingFailed
        }
    }

    var observation: DesktopPermissionObservation {
        switch self {
        case .busy: .init(.verificationRequired, detail: "Finish the current voice recording, then retry Setup Microphone.")
        case .timedOut: .init(.failed, detail: "The microphone test timed out. Check the selected audio input and retry.")
        case .pageChanged: .init(.checking, detail: "The page or microphone changed. Retry Setup Microphone.")
        case .unsupported: .init(.unsupported, detail: "This page cannot record audio. Open the selected HTTPS PersonaStack app and retry.")
        case .denied: .init(.denied, detail: "WebKit could not access the microphone. Allow PersonaStack microphone access, reload the app page, and retry.")
        case .noInput: .init(.failed, detail: "No live microphone input is available. Choose an input in Sound settings and retry.")
        case .emptyRecording: .init(.failed, detail: "The microphone recorder returned no audio data. Check the selected audio input and retry Setup Microphone.")
        case .recordingFailed: .init(.failed, detail: "The microphone recorder could not finish. Finish any voice recording, check the audio input, and retry.")
        case .evaluationFailed: .init(.failed, detail: "The microphone check could not run in this app page. Reload the page and retry Setup Microphone.")
        }
    }
}

/// Bounds the native continuation independently of the page's recording timer.
/// Results and cancellation belong to one explicit test and one current page.
@MainActor
final class DesktopVoicePermissionVerifier {
    private struct Pending {
        let id: String
        let page: any DesktopVoicePermissionPage
        let isCurrent: () -> Bool
        let continuation: CheckedContinuation<Bool, Error>
    }

    private let wait: @MainActor () async throws -> Void
    private var pending: Pending?
    private var timeout: Task<Void, Never>?

    init(wait: @escaping @MainActor () async throws -> Void = {
        try await Task.sleep(for: .seconds(12))
    }) { self.wait = wait }

    func verify(page: any DesktopVoicePermissionPage, isCurrent: @escaping () -> Bool) async throws -> Bool {
        guard pending == nil else { throw DesktopVoicePermissionError.busy }
        let id = UUID().uuidString
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard isCurrent() else {
                    continuation.resume(throwing: DesktopVoicePermissionError.pageChanged)
                    return
                }
                pending = Pending(id: id, page: page, isCurrent: isCurrent, continuation: continuation)
                timeout = Task { [weak self, wait] in
                    do { try await wait() } catch { return }
                    self?.complete(id: id, result: .failure(DesktopVoicePermissionError.timedOut))
                }
                page.test(id: id) { [weak self] result in self?.complete(id: id, result: result) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.complete(id: id, result: .failure(CancellationError())) }
        }
        try Task.checkCancellation()
        guard isCurrent() else { throw DesktopVoicePermissionError.pageChanged }
        return result
    }

    func invalidate() {
        guard let pending else { return }
        complete(id: pending.id, result: .failure(DesktopVoicePermissionError.pageChanged))
    }

    private func complete(id: String, result: Result<Bool, Error>) {
        guard let value = pending, value.id == id else { return }
        pending = nil
        timeout?.cancel()
        timeout = nil
        // Cancel only the recording we started. A stale callback cannot cancel a successor.
        value.page.cancel(id: id)
        if !value.isCurrent() {
            value.continuation.resume(throwing: DesktopVoicePermissionError.pageChanged)
        } else {
            value.continuation.resume(with: result)
        }
    }
}
