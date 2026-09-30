import Foundation
import WebKit

@MainActor
protocol DesktopVoicePermissionPage: AnyObject {
    func test(id: String, completion: @escaping (Result<Bool, Error>) -> Void)
    func cancel(id: String)
}

@MainActor
final class DesktopVoicePermissionWebPage: DesktopVoicePermissionPage {
    private weak var view: WKWebView?

    init(view: WKWebView) { self.view = view }

    func test(id: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        guard let view else {
            completion(.failure(DesktopVoicePermissionError.pageChanged))
            return
        }
        view.callAsyncJavaScript("""
            if (window.top !== window || !window.isSecureContext) return false;
            const owner = window.personastackVoicePermission;
            if (!owner || owner.version !== '1' || typeof owner.test !== 'function') return false;
            return await owner.test(testID) === true;
            """, arguments: ["testID": id], in: nil, in: .page) { result in
                switch result {
                case .success(let value): completion(.success(value as? Bool == true))
                case .failure(let error): completion(.failure(error))
                }
            }
    }

    func cancel(id: String) {
        view?.callAsyncJavaScript("""
            const owner = window.personastackVoicePermission;
            if (owner && owner.version === '1' && typeof owner.cancel === 'function') owner.cancel(expectedID);
            """, arguments: ["expectedID": id], in: nil, in: .page, completionHandler: nil)
    }
}

enum DesktopVoicePermissionError: Error {
    case busy, timedOut, pageChanged
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
