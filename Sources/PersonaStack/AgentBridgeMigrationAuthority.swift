import Foundation
import PersonaStackCore

struct AgentBridgeMigrationState: Sendable {
    let personaID: String
    let userPaused: Bool
    let pauseVersion: Int
    let laneIdle: Bool
}

/// Reuses the API-owned settings, Pause, Stop and bounded wake-test routes.
struct AgentBridgeMigrationAuthority: Sendable {
    let transport: any AgentBridgeHostedTransport
    init(transport: any AgentBridgeHostedTransport = AgentBridgeURLTransport()) { self.transport = transport }

    func state(configuration: DesktopEnvironmentConfiguration, cookies: String, persona: String) async throws -> AgentBridgeMigrationState {
        struct Settings: Decodable {
            struct Persona: Decodable {
                let id: String; let user_paused: Bool; let user_pause_version: Int
            }
            struct Runtime: Decodable { let run_lane_status: String }
            let persona: Persona; let external_runtime: Runtime
        }
        var components = URLComponents(url: configuration.appURL.appendingPathComponent("user/mobile/personas/settings"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "persona_id", value: persona)]
        var request = base(configuration: configuration, cookies: cookies, url: components.url!)
        request.httpMethod = "GET"
        let (data, status) = try await transport.request(request)
        guard status == 200 else { throw AgentBridgeFailure.credentialUnavailable }
        let settings = try JSONDecoder().decode(Settings.self, from: data)
        guard settings.persona.id == persona, settings.persona.user_pause_version >= 0 else { throw AgentBridgeFailure.scopeChanged }
        return AgentBridgeMigrationState(personaID: persona, userPaused: settings.persona.user_paused,
            pauseVersion: settings.persona.user_pause_version, laneIdle: settings.external_runtime.run_lane_status == "idle")
    }

    func pause(configuration: DesktopEnvironmentConfiguration, cookies: String, csrf: String, persona: String,
               paused: Bool, expectedVersion: Int) async throws -> Int {
        struct Response: Decodable { let ok: Bool; let paused: Bool; let effective_paused: Bool; let user_pause_version: Int }
        let data = try await mutation(configuration: configuration, cookies: cookies, csrf: csrf,
            path: "user/personas/pause/save", body: ["persona_id": persona, "paused": paused, "expected_user_pause_version": expectedVersion])
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.ok, response.paused == paused, !paused || response.effective_paused,
              response.user_pause_version >= expectedVersion else { throw AgentBridgeFailure.scopeChanged }
        return response.user_pause_version
    }

    func stop(configuration: DesktopEnvironmentConfiguration, cookies: String, csrf: String, persona: String) async throws {
        struct Response: Decodable { let accepted: Bool; let ok: Bool }
        let data = try await mutation(configuration: configuration, cookies: cookies, csrf: csrf,
            path: "user/personas/stop", body: ["persona_id": persona])
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.accepted, response.ok else { throw AgentBridgeFailure.busy }
    }

    func test(configuration: DesktopEnvironmentConfiguration, cookies: String, csrf: String, persona: String) async throws {
        struct Response: Decodable { let accepted: Bool }
        let data = try await mutation(configuration: configuration, cookies: cookies, csrf: csrf,
            path: "user/personas/external-runtime/test-dispatch", body: ["persona_id": persona])
        guard try JSONDecoder().decode(Response.self, from: data).accepted else { throw AgentBridgeFailure.runtimeConflict }
    }

    private func mutation(configuration: DesktopEnvironmentConfiguration, cookies: String, csrf: String,
                          path: String, body: [String: Any]) async throws -> Data {
        guard !csrf.isEmpty, csrf.utf8.count <= 512, !csrf.contains(where: { $0.isWhitespace }) else { throw AgentBridgeFailure.invalidRequest }
        var request = base(configuration: configuration, cookies: cookies, url: configuration.appURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, status) = try await transport.request(request)
        guard status == 200 || status == 202 else { throw AgentBridgeFailure.scopeChanged }
        return data
    }
    private func base(configuration: DesktopEnvironmentConfiguration, cookies: String, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue(configuration.appOrigin, forHTTPHeaderField: "Origin")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
