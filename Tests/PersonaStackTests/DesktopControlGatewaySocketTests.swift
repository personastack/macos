import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

struct DesktopControlGatewaySocketTests {
    @Test func socketAcceptsTheGatewayFrameLimitAndPreservesMachineAuthentication() async throws {
        let profile = DesktopEnvironmentConfiguration.production
        let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: JSONSerialization.data(withJSONObject: [
            "installation_id": "fixture", "machine_credential": String(repeating: "A", count: 43),
            "gateway_websocket_url": profile.gatewayWebsocketURL.absoluteString, "environment_origin": profile.appOrigin,
        ]))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let connection = DesktopControlGatewayConnection(installation: installation, session: session) { _, _ in
            Issue.record("An unstarted socket must not receive commands")
            return DesktopControlFrame(type: "failure")
        }
        let socket = try await connection.makeSocket()
        defer { socket.cancel() }
        #expect(socket.state == .suspended)
        #expect(socket.maximumMessageSize == 8 * 1024 * 1024)
        #expect(socket.maximumMessageSize == DesktopControlFrameCodec.maximumFrameBytes)
        #expect(socket.originalRequest?.url == installation.gatewayWebsocketURL)
        #expect(socket.originalRequest?.timeoutInterval == 15)
        #expect(socket.originalRequest?.value(forHTTPHeaderField: "X-Desktop-Control-Installation-ID") == "fixture")
        #expect(socket.originalRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer " + installation.machineCredential)
    }
}
