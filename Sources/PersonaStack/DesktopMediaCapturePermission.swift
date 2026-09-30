import AVFoundation
import PersonaStackCore
import WebKit

@MainActor
enum DesktopMediaCapturePermission {
    static func decide(
        origin: WKSecurityOrigin, frame: WKFrameInfo, type: WKMediaCaptureType,
        appURL: URL, activeView: Bool
    ) -> WKPermissionDecision {
        guard activeView else { return .deny }
        let authorization: DesktopMicrophoneAuthorization
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: authorization = .authorized
        case .notDetermined: authorization = .notDetermined
        case .denied: authorization = .denied
        case .restricted: authorization = .restricted
        @unknown default: authorization = .restricted
        }
        let decision = DesktopMediaPermissionPolicy.decision(
            scheme: origin.protocol, host: origin.host, port: origin.port,
            mainFrame: frame.isMainFrame, appURL: appURL,
            microphoneOnly: type == .microphone, authorization: authorization
        )
        switch decision {
        case .grant: return .grant
        case .prompt: return .prompt
        case .deny: return .deny
        }
    }
}
