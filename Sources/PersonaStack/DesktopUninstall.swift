import Foundation
import PersonaStackCore

@MainActor
enum DesktopUninstall {
    static func run() async throws {
        let service = AgentBridgeService.shared
        let coordinator = DesktopUninstallCoordinator(
            acquireApplicationOwner: { DesktopApplicationInstanceLock.shared.acquire() },
            removal: .forService(service),
            unregisterAgentBridge: { try await service.unregisterForUninstall() },
            unregisterLoginItems: { try DesktopLoginItemRegistration.unregisterForUninstall() })
        try await coordinator.run()
    }
}

extension DesktopLocalRuntimeRemoval {
    static func forService(_ service: AgentBridgeService) -> Self {
        Self(
            controlAvailable: { service.status == .enabled },
            removeUsingControl: { try await service.removeLocalRuntimeDataUsingControl() },
            removeUsingBundledHelper: service.removeUsingBundledHelper)
    }

    static func runBundledHelper() async throws {
        try await DesktopUninstallHelperCommand(bundleURL: Bundle.main.bundleURL).run(
            verifySignature: { try AgentBridgeService.validateHelperIdentity() },
            execute: { try await runHelper($0, arguments: $1) })
    }

    /// The Go command owns its removal deadline and exact stopped/data proof.
    /// A native timeout never authorizes unregistering or deleting the app.
    private static func runHelper(_ executable: URL, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while process.isRunning {
            guard ContinuousClock.now < deadline else { throw AgentBridgeFailure.operationTimeout }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw AgentBridgeFailure.cleanupRequired
        }
    }
}
