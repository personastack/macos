import Foundation
import Darwin
import PersonaStackCore

enum DesktopPermissionResetResult: Sendable {
    case cleared, notApplicable, failed
}

/// Only an explicit native Setup action may invoke this owner. Never reset
/// every service, another bundle, another user, or the TCC database directly.
enum DesktopPermissionReset {
    static let bundleIdentifier = "ai.personastack.desktop"

    static func arguments(for permission: DesktopPermissionID) -> [String]? {
        let service: String
        switch permission {
        case .accessibility: service = "Accessibility"
        case .screenRecording, .directCapture: service = "ScreenCapture"
        case .microphone: service = "Microphone"
        case .fullDiskAccess: service = "SystemPolicyAllFiles"
        case .desktopFiles: service = "SystemPolicyDesktopFolder"
        case .documentsFiles: service = "SystemPolicyDocumentsFolder"
        case .downloadsFiles: service = "SystemPolicyDownloadsFolder"
        case .removableVolumes: service = "SystemPolicyRemovableVolumes"
        case .networkVolumes: service = "SystemPolicyNetworkVolumes"
        default: return nil
        }
        return ["reset", service, bundleIdentifier]
    }

    static func reset(_ permission: DesktopPermissionID,
                      run: @Sendable (URL, [String]) async -> Bool = runTool) async -> DesktopPermissionResetResult {
        guard let arguments = arguments(for: permission) else { return .notApplicable }
        guard !Task.isCancelled else { return .failed }
        return await run(URL(fileURLWithPath: "/usr/bin/tccutil"), arguments) ? .cleared : .failed
    }

    private static func runTool(_ executable: URL, _ arguments: [String]) async -> Bool {
        guard Bundle.main.bundleIdentifier == bundleIdentifier,
              Bundle.main.bundleURL.pathExtension == "app" else { return false }
        let task = Task.detached {
            guard !Task.isCancelled else { return false }
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while process.isRunning && !Task.isCancelled && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !process.isRunning else {
                process.terminate()
                // Bound cleanup even when cancellation has already been requested.
                let grace = ContinuousClock.now.advanced(by: .milliseconds(200))
                while process.isRunning && ContinuousClock.now < grace { usleep(10_000) }
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                return false
            }
            return process.terminationReason == .exit && process.terminationStatus == 0
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
