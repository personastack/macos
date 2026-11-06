import Foundation

/// Shared native menu/uninstall entry to the existing managed-runtime eraser.
@MainActor
public struct DesktopLocalRuntimeRemoval {
    private let controlAvailable: () -> Bool
    private let removeUsingControl: () async throws -> Void
    private let removeUsingBundledHelper: () async throws -> Void
    public init(controlAvailable: @escaping () -> Bool,
                removeUsingControl: @escaping () async throws -> Void,
                removeUsingBundledHelper: @escaping () async throws -> Void) {
        self.controlAvailable = controlAvailable
        self.removeUsingControl = removeUsingControl
        self.removeUsingBundledHelper = removeUsingBundledHelper
    }

    public func run() async throws {
        if controlAvailable() {
            do { try await removeUsingControl() }
            catch AgentBridgeFailure.serviceUnavailable {
                // A live daemon holds the same process lock as this one-shot
                // command. An unreachable live owner therefore fails closed.
                try await removeUsingBundledHelper()
            }
        } else {
            // Removal never registers or enables a disabled login helper.
            try await removeUsingBundledHelper()
        }
    }
}

/// Remove the managed VM before retiring the tools needed to retry cleanup.
/// The package owner removes the app bundle only after this operation succeeds.
@MainActor
public struct DesktopUninstallCoordinator {
    private let acquireApplicationOwner: () -> Bool
    private let removal: DesktopLocalRuntimeRemoval
    private let unregisterAgentBridge: () async throws -> Void
    private let unregisterLoginItems: () throws -> Void

    public init(acquireApplicationOwner: @escaping () -> Bool = { true },
                removal: DesktopLocalRuntimeRemoval,
                unregisterAgentBridge: @escaping () async throws -> Void,
                unregisterLoginItems: @escaping () throws -> Void) {
        self.acquireApplicationOwner = acquireApplicationOwner
        self.removal = removal
        self.unregisterAgentBridge = unregisterAgentBridge
        self.unregisterLoginItems = unregisterLoginItems
    }

    public init(acquireApplicationOwner: @escaping () -> Bool = { true },
                controlAvailable: @escaping () -> Bool,
                removeUsingControl: @escaping () async throws -> Void,
                removeUsingBundledHelper: @escaping () async throws -> Void,
                unregisterAgentBridge: @escaping () async throws -> Void,
                unregisterLoginItems: @escaping () throws -> Void) {
        self.init(acquireApplicationOwner: acquireApplicationOwner,
            removal: DesktopLocalRuntimeRemoval(controlAvailable: controlAvailable,
            removeUsingControl: removeUsingControl, removeUsingBundledHelper: removeUsingBundledHelper),
            unregisterAgentBridge: unregisterAgentBridge, unregisterLoginItems: unregisterLoginItems)
    }

    public func run() async throws {
        guard acquireApplicationOwner() else { throw AgentBridgeFailure.busy }
        try await removal.run()
        try await unregisterAgentBridge()
        try unregisterLoginItems()
    }
}

/// No shell, caller-supplied arguments, paths, environment or credentials.
@MainActor
public struct DesktopUninstallHelperCommand {
    public let executableURL: URL
    public let arguments = ["--remove-local-runtime"]

    public init(bundleURL: URL) {
        executableURL = bundleURL.appendingPathComponent("Contents/MacOS/PersonaStackAgentBridge")
    }

    public func run(verifySignature: () throws -> Void,
                    execute: (URL, [String]) async throws -> Void) async throws {
        try verifySignature()
        try await execute(executableURL, arguments)
    }
}
