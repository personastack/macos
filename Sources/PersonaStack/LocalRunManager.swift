import AppKit
import CryptoKit
import PersonaStackCore
import Security
import WebKit

@MainActor
final class LocalRunManager: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = LocalRunManager()
    private final class Page {
        let appURL: URL
        var scope = ""
        var generation = UUID()
        var pending: [String: Pending] = [:]
        init(_ appURL: URL) { self.appURL = appURL }
    }
    private struct Pending {
        let persona: String
        let verifier: String
        let workspace: URL
        let expires: Date
    }
    private let pages = NSMapTable<WKWebView, Page>.weakToStrongObjects()
    private var windows: [String: LocalRunWindow] = [:]
    var hasActiveSessions: Bool { !windows.isEmpty }

    func register(_ view: WKWebView, appURL: URL) { pages.setObject(Page(appURL), forKey: view) }
    func invalidate(_ view: WKWebView) {
        pages.object(forKey: view)?.generation = UUID()
        pages.removeObject(forKey: view)
        invalidateSession()
    }
    func invalidateSession() {
        for page in pages.objectEnumerator()?.allObjects as? [Page] ?? [] {
            page.generation = UUID(); page.scope = ""; page.pending.removeAll()
        }
        for window in windows.values { window.requestClose() }
    }
    @discardableResult
    func shutdown(waitForRetry: Bool = true) async -> Bool {
        invalidateSession()
        for window in Array(windows.values) { await window.closeSession() }
        // A failed stop stays visible and retryable. Quit/profile switching cannot
        // silently detach a live local container from its owning window.
        if waitForRetry {
            while !windows.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        }
        return windows.isEmpty
    }

    func showQuitRecovery() {
        for window in windows.values { window.focus() }
        guard let window = windows.values.first?.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "PersonaStack is waiting for local work to close."
        alert.informativeText = "Review the local chat window. Retry closing it if cleanup failed, then choose Quit or Restart PersonaStack again. PersonaStack will stay open while local work or credential cleanup is pending."
        alert.addButton(withTitle: "Keep Open")
        alert.beginSheetModal(for: window)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let view = message.webView, let page = pages.object(forKey: view),
              ChatWindowManager.trusted(message, base: page.appURL),
              let body = message.body as? [String: Any], let action = body["action"] as? String,
              let scope = body["scope"] as? String, scope.utf8.count <= 2048 else {
            replyHandler(nil, "Invalid local run request."); return
        }
        Task {
            do { replyHandler(try await apply(action, body: body, scope: scope, page: page), nil) }
            catch LocalRunError.setupCancelled { replyHandler(["ok": true, "cancelled": true], nil) }
            catch { replyHandler(nil, (error as? LocalRunError)?.rawValue ?? "Unable to start the local agent.") }
        }
    }

    private func apply(_ action: String, body: [String: Any], scope: String, page: Page) async throws -> [String: Any] {
        if action == "state" {
            if page.scope != scope {
                invalidateSession()
                page.scope = scope
            }
            return ["ok": true, "version": 1, "supported": LocalRunContainer.platformSupported()]
        }
        guard !scope.isEmpty, page.scope == scope else { throw LocalRunError.staleSession }
        let generation = page.generation
        if action == "prepare" {
            guard let persona = body["persona_id"] as? String, ChatWindowCommand.validPersonaID(persona) else { throw LocalRunError.invalidBundle }
            try await LocalRunSetupManager.shared.ensureReady {
                page.generation == generation && page.scope == scope
            }
            guard page.generation == generation else { throw LocalRunError.staleSession }
            let panel = NSOpenPanel()
            panel.title = "Run persona locally"
            panel.message = "Choose the working folder. This agent can access your Mac files and run Mac commands with PersonaStack's permissions."
            panel.prompt = "Use Folder"
            panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            guard await panel.begin() == .OK, let directory = panel.url,
                  !directory.path.contains(":"), !directory.path.contains("\n"), page.generation == generation else { throw LocalRunError.staleSession }
            let id = UUID().uuidString.lowercased()
            let verifier = try Self.randomSecret()
            let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
            page.pending = page.pending.filter { $0.value.expires > Date() }
            page.pending[id] = Pending(persona: persona, verifier: verifier, workspace: directory, expires: Date().addingTimeInterval(300))
            return ["ok": true, "session_id": id, "code_challenge": challenge]
        }
        guard action == "start", let id = body["session_id"] as? String,
              let ticket = body["ticket"] as? String, !ticket.isEmpty, ticket.utf8.count <= 4096,
              let pending = page.pending.removeValue(forKey: id), pending.expires > Date() else { throw LocalRunError.staleSession }
        let window = LocalRunWindow(sessionID: id, workspace: pending.workspace) { [weak self] in self?.windows.removeValue(forKey: id) }
        windows[id] = window
        window.focus()
        window.start(appURL: page.appURL, personaID: pending.persona, ticket: ticket, verifier: pending.verifier)
        return ["ok": true, "session_id": id]
    }

    static func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw LocalRunError.startupFailed }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

enum LocalRunAPI {
    static func redeem(appURL: URL, personaID: String, sessionID: String, ticket: String, verifier: String, session: URLSession? = nil) async throws -> LocalRunBundle {
        guard let environment = try? DesktopEnvironmentConfigurationStore.shared.environment(for: appURL) else { throw LocalRunError.invalidBundle }
        let body = try JSONEncoder().encode(["session_id": sessionID, "ticket": ticket, "code_verifier": verifier])
        let (data, response) = try await request(appURL: appURL, path: "/desktop/local-runs/redeem", body: body, session: session)
        guard response.statusCode == 200 || response.statusCode == 201 else { throw LocalRunError.startupFailed }
        return try LocalRunBundle.decode(data, sessionID: sessionID, personaID: personaID, mcpURL: environment.mcpEndpointURL)
    }
    static func revoke(appURL: URL, bundle: LocalRunBundle, session: URLSession? = nil) async throws {
        do {
            let body = try JSONEncoder().encode(["session_id": bundle.session_id])
            let (_, response) = try await request(appURL: appURL, path: "/desktop/local-runs/revoke", body: body, bearer: bundle.bearer_token, session: session)
            guard response.statusCode == 204 else { throw LocalRunError.revocationUnconfirmed }
        } catch { throw LocalRunError.revocationUnconfirmed }
    }
    static func request(appURL: URL, path: String, body: Data, bearer: String? = nil, session supplied: URLSession? = nil) async throws -> (Data, HTTPURLResponse) {
        guard var components = URLComponents(url: appURL, resolvingAgainstBaseURL: false) else { throw LocalRunError.invalidBundle }
        components.path = path; components.query = nil; components.fragment = nil
        guard let url = components.url else { throw LocalRunError.invalidBundle }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        let session = supplied ?? DesktopControlNetworkSession.makeWithoutRedirects()
        defer { if supplied == nil { session.finishTasksAndInvalidate() } }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, !(300..<400).contains(response.statusCode) else { throw LocalRunError.invalidBundle }
        let limit = 12 * 1024 * 1024
        guard response.expectedContentLength <= limit else { throw LocalRunError.invalidBundle }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw LocalRunError.invalidBundle }
            data.append(byte)
        }
        return (data, response)
    }
}
