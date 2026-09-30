import Foundation

public enum DesktopMicrophoneAuthorization: Sendable {
    case notDetermined, authorized, denied, restricted
}

public enum DesktopMediaPermissionDecision: Equatable, Sendable {
    case grant, prompt, deny
}

public enum DesktopMediaPermissionPolicy {
    public static func decision(
        scheme: String, host: String, port: Int, mainFrame: Bool,
        appURL: URL, microphoneOnly: Bool,
        authorization: DesktopMicrophoneAuthorization
    ) -> DesktopMediaPermissionDecision {
        guard microphoneOnly,
              ChatWindowCommand.permitsBridge(scheme: scheme, host: host, port: port,
                                              mainFrame: mainFrame, appURL: appURL),
              isSecureContext(scheme: scheme, host: host) else { return .deny }
        switch authorization {
        case .authorized: return .grant
        case .notDetermined: return .prompt
        case .denied, .restricted: return .deny
        }
    }

    public static func isSecureContext(scheme: String, host: String) -> Bool {
        scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
    }
}
