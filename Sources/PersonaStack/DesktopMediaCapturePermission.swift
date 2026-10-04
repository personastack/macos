import AppKit
import AVFoundation
import PersonaStackCore
import WebKit

/// One OS authorization request serves current chat recording requests. This
/// owner never starts capture. The requesting chat owns its MediaStream tracks.
@MainActor
final class DesktopMediaCapturePermission {
    static let shared = DesktopMediaCapturePermission()
    static let bridgeName = "personastackMicrophone"
    private struct Key: Hashable { let owner: UUID; let request: UUID }
    private struct Pending {
        let isCurrent: @MainActor () -> Bool
        let completion: @MainActor (Bool) -> Void
    }
    private let authorization: @MainActor () -> DesktopMicrophoneAuthorization
    private let requestAuthorization: @MainActor (@escaping @MainActor (Bool) -> Void) -> Void
    private let openSettings: @MainActor () -> Void
    private var pending: [Key: Pending] = [:]
    private var prompt: UUID?

    init(authorization: @escaping @MainActor () -> DesktopMicrophoneAuthorization = DesktopMediaCapturePermission.currentAuthorization,
         requestAuthorization: @escaping @MainActor (@escaping @MainActor (Bool) -> Void) -> Void = { completion in
             AVCaptureDevice.requestAccess(for: .audio) { allowed in
                 Task { @MainActor in completion(allowed) }
             }
         },
         openSettings: @escaping @MainActor () -> Void = {
             if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                 NSWorkspace.shared.open(url)
             }
         }) {
        self.authorization = authorization
        self.requestAuthorization = requestAuthorization
        self.openSettings = openSettings
    }

    static func trusted(origin: WKSecurityOrigin, frame: WKFrameInfo, appURL: URL) -> Bool {
        DesktopMediaPermissionPolicy.decision(
            scheme: origin.protocol, host: origin.host, port: origin.port,
            mainFrame: frame.isMainFrame, appURL: appURL, microphoneOnly: true,
            authorization: .authorized) == .grant
    }

    func decide(origin: WKSecurityOrigin, frame: WKFrameInfo, type: WKMediaCaptureType,
                appURL: URL, owner: UUID, isCurrent: @escaping @MainActor () -> Bool,
                completion: @escaping @MainActor (WKPermissionDecision) -> Void) {
        request(owner: owner, id: UUID(),
                trusted: type == .microphone && Self.trusted(origin: origin, frame: frame, appURL: appURL),
                isCurrent: isCurrent) { completion($0 ? .grant : .deny) }
    }

    func request(owner: UUID, id: UUID, trusted: Bool,
                 isCurrent: @escaping @MainActor () -> Bool,
                 completion: @escaping @MainActor (Bool) -> Void) {
        guard trusted, isCurrent() else { completion(false); return }
        switch authorization() {
        case .authorized: completion(true)
        case .denied, .restricted: completion(false)
        case .notDetermined:
            let key = Key(owner: owner, request: id)
            guard pending[key] == nil else { completion(false); return }
            pending[key] = Pending(isCurrent: isCurrent, completion: completion)
            guard prompt == nil else { return }
            let token = UUID()
            prompt = token
            requestAuthorization { [weak self] allowed in
                guard let self, self.prompt == token else { return }
                self.prompt = nil
                let waiting = self.pending
                self.pending.removeAll()
                let granted = allowed && self.authorization() == .authorized
                for request in waiting.values { request.completion(granted && request.isCurrent()) }
            }
        }
    }

    func cancel(owner: UUID, id: UUID? = nil) {
        let keys = pending.keys.filter { $0.owner == owner && (id == nil || $0.request == id) }
        let cancelled = keys.compactMap { pending.removeValue(forKey: $0) }
        for request in cancelled { request.completion(false) }
        // The OS prompt cannot be cancelled. Keep its single in-flight owner
        // so a fresh chat action joins it without opening a second prompt.
    }

    func handleMessage(_ body: Any, owner: UUID, trusted: Bool,
                       isCurrent: @escaping @MainActor () -> Bool,
                       reply: @escaping @MainActor (Any?, String?) -> Void) {
        guard trusted, isCurrent(), let value = body as? [String: Any],
              let operation = value["operation"] as? String else {
            reply(nil, "Invalid microphone request."); return
        }
        if operation == "settings", Set(value.keys) == ["operation"] {
            openSettings()
            reply(["ok": true], nil)
            return
        }
        guard Set(value.keys) == ["operation", "request_id"],
              let rawID = value["request_id"] as? String, let id = UUID(uuidString: rawID) else {
            reply(nil, "Invalid microphone request."); return
        }
        switch operation {
        case "authorize":
            request(owner: owner, id: id, trusted: trusted, isCurrent: isCurrent) { allowed in
                reply(["authorized": allowed], nil)
            }
        case "cancel":
            cancel(owner: owner, id: id)
            reply(["ok": true], nil)
        default: reply(nil, "Invalid microphone request.")
        }
    }

    private static func currentAuthorization() -> DesktopMicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }
}
