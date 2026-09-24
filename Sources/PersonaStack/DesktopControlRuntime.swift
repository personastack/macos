import AppKit
import Foundation
import PersonaStackCore

@MainActor
final class DesktopControlRuntime {
    static let shared = DesktopControlRuntime()

    private let installer = CuaDriverInstaller()
    private var cuaApplication: NSRunningApplication?
    private var proxy: CuaMCPProxy?
    private var gateway: DesktopControlGatewayConnection?
    private var reconnectTask: Task<Void, Never>?
    private var activeInstallation: DesktopControlInstallation?
    private var executor = DesktopControlCommandExecutor()
    private(set) var gatewayConnected = false
    private(set) var tools: Set<String> = []
    private(set) var paused = false
    private var readiness = "unknown"

    private init() {}

    func resume() async throws {
        if proxy == nil {
            do {
                let installation = try await installer.validateOrInstall()
                let application = try await launchCuaService(at: installation.applicationURL)
                cuaApplication = application

                let candidate = CuaMCPProxy(executableURL: installation.executableURL)
                do {
                    _ = try await candidate.start()
                    let catalog = try await candidate.listTools()
                    tools = try await candidate.validateToolCatalog(catalog)
                    try await verifyCuaReadiness(candidate)
                    proxy = candidate
                } catch {
                    await candidate.stop()
                    application.terminate()
                    cuaApplication = nil
                    throw error
                }
            } catch {
                await publishReadinessFailure(error)
                throw error
            }
        }
        paused = false
        readiness = "ready"
        if let saved = try? KeychainDesktopControlCredentialStore().load() {
            await gateway?.setReadiness("ready")
            beginReconnectLoop(for: saved)
        }
    }

    func startPaused() async throws {
        paused = true
        readiness = "paused"
        guard let installation = try KeychainDesktopControlCredentialStore().load() else { return }
        activeInstallation = installation
        if await gateway?.isConnected() == true {
            await gateway?.setReadiness("paused")
        } else {
            do {
                try await establishConnection(installation)
            } catch {
                gatewayConnected = false
            }
        }
        beginReconnectLoop(for: installation)
    }

    func pause() async {
        paused = true
        readiness = "paused"
        await gateway?.setReadiness("paused")
        await executor.close()
        executor = DesktopControlCommandExecutor()
        if let proxy {
            await proxy.stop()
            self.proxy = nil
        }
        tools = []
        cuaApplication?.terminate()
        cuaApplication = nil
    }

    func disconnect() async throws {
        guard let installation = try KeychainDesktopControlCredentialStore().load() else { return }
        paused = true
        await gateway?.setReadiness("paused")
        await executor.close()
        executor = DesktopControlCommandExecutor()
        if let proxy {
            await proxy.stop()
            self.proxy = nil
        }
        tools = []
        cuaApplication?.terminate()
        cuaApplication = nil

        let enrollment = DesktopControlEnrollmentClient(credentials: KeychainDesktopControlCredentialStore())
        try await enrollment.revokeRemote(installation: installation, appURL: Bundle.main.bundleURL)

        reconnectTask?.cancel()
        reconnectTask = nil
        await gateway?.stop()
        gateway = nil
        gatewayConnected = false
        activeInstallation = nil
        try KeychainDesktopControlCredentialStore().delete()
        paused = false
    }

    func connect(installation: DesktopControlInstallation) async {
        activeInstallation = installation
        if await gateway?.isConnected() == true {
            gatewayConnected = true
            beginReconnectLoop(for: installation)
            return
        }
        do {
            try await establishConnection(installation)
        } catch {
            gatewayConnected = false
        }
        beginReconnectLoop(for: installation)
    }

    func isReady() -> Bool {
        !paused && isCuaReady() && gatewayConnected
    }

    func isCuaReady() -> Bool {
        proxy != nil && !tools.isEmpty && cuaApplication?.isTerminated == false
    }

    static func cuaServiceLaunchConfiguration(
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["serve"]
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.environment = CuaDriverCompatibility.processEnvironment(from: inheritedEnvironment)
        return configuration
    }

    private func launchCuaService(at applicationURL: URL) async throws -> NSRunningApplication {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == CuaDriverCompatibility.bundleIdentifier && !$0.isTerminated
        }) {
            return running
        }
        return try await NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: Self.cuaServiceLaunchConfiguration()
        )
    }

    private func beginReconnectLoop(for installation: DesktopControlInstallation) {
        guard reconnectTask == nil else { return }
        activeInstallation = installation
        reconnectTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !(await self.gateway?.isConnected() ?? false) {
                    do {
                        try await self.establishConnection(installation)
                    } catch {
                        self.gatewayConnected = false
                    }
                }
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    private func establishConnection(_ installation: DesktopControlInstallation) async throws {
        guard paused || isCuaReady() || readiness != "ready" else { throw CuaMCPProxyError.notStarted }
        if let gateway {
            await gateway.stop()
        }
        let connection = DesktopControlGatewayConnection(
            installation: installation,
            onDisconnect: { [weak self] in await self?.gatewayDisconnected() },
            handler: { [weak self] frame, onChunk in
                guard let self else { return Self.failure(for: frame, code: "desktop_executor_unavailable") }
                return await self.handle(frame, onChunk: onChunk)
            }
        )
        do {
            try await connection.connect()
            await connection.setReadiness(readiness)
            gateway = connection
            activeInstallation = installation
            gatewayConnected = true
        } catch {
            gatewayConnected = false
            await connection.stop()
            throw error
        }
    }

    private func gatewayDisconnected() {
        gatewayConnected = false
    }

    private func publishReadinessFailure(_ error: Error) async {
        readiness = Self.readiness(for: error)
        guard let installation = try? KeychainDesktopControlCredentialStore().load() else { return }
        activeInstallation = installation
        if await gateway?.isConnected() != true {
            do { try await establishConnection(installation) }
            catch {
                gatewayConnected = false
                return
            }
        }
        await gateway?.setReadiness(readiness)
        beginReconnectLoop(for: installation)
    }

    static func readiness(for error: Error) -> String {
        guard let error = error as? CuaMCPProxyError else { return "cua_unavailable" }
        switch error {
        case .permissionsRequired:
            return "permission_required"
        case .functionalProbeFailed:
            return "cua_unavailable"
        default:
            return "cua_unavailable"
        }
    }

    private func handle(_ frame: DesktopControlFrame,
                        onChunk: @escaping @Sendable (DesktopControlFrame) async throws -> Void) async -> DesktopControlFrame {
        guard !paused else {
            return Self.failure(for: frame, code: "desktop_paused", message: "Desktop Control is paused on this Mac.")
        }
        guard readiness == "ready" else {
            return Self.failure(for: frame, code: readiness, message: "Desktop Control needs attention on this Mac. Review the connection status in PersonaStack Desktop.")
        }
        guard let activeInstallation, frame.target?.installationID == activeInstallation.installationID else {
            return Self.failure(for: frame, code: "desktop_executor_unavailable")
        }
        return await executor.handle(frame, proxy: proxy, onChunk: onChunk)
    }

    nonisolated private static func failure(for frame: DesktopControlFrame, code: String, message: String = "The desktop command is not available.") -> DesktopControlFrame {
        DesktopControlFrame(version: 1, type: "failure", requestID: frame.requestID, errorCode: code, errorMessage: message)
    }

    private func verifyCuaReadiness(_ candidate: CuaMCPProxy) async throws {
        let permissions = try await candidate.callTool(
            name: "check_permissions",
            argumentsJSON: Data(#"{"prompt":true,"probe_direct_capture":false}"#.utf8)
        )
        guard let permissionResult = Self.toolResult(permissions),
              let structured = permissionResult["structuredContent"] as? [String: Any],
              structured["accessibility"] as? Bool == true,
              structured["screen_recording"] as? Bool == true else {
            throw CuaMCPProxyError.permissionsRequired
        }

        let screenshot = try await candidate.callTool(
            name: "get_desktop_state",
            argumentsJSON: Data("{}".utf8)
        )
        guard let screenshotResult = Self.toolResult(screenshot),
              let screenshotContent = screenshotResult["content"] as? [[String: Any]],
              screenshotContent.contains(where: { $0["type"] as? String == "image" && $0["mimeType"] as? String == "image/png" }) else {
            throw CuaMCPProxyError.functionalProbeFailed
        }

        let accessibility = try await candidate.callTool(
            name: "get_accessibility_tree",
            argumentsJSON: Data("{}".utf8)
        )
        guard let accessibilityResult = Self.toolResult(accessibility),
              let accessibilityContent = accessibilityResult["content"] as? [[String: Any]],
              !accessibilityContent.isEmpty else {
            throw CuaMCPProxyError.functionalProbeFailed
        }
    }

    private static func toolResult(_ data: Data) -> [String: Any]? {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["error"] == nil,
              let result = response["result"] as? [String: Any],
              (result["isError"] as? Bool) != true else { return nil }
        return result
    }
}
