import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

@Suite struct DesktopControlPresentationTests {
    private var activity: DesktopControlActivity {
        .init(personaName: "Prototype", workspaceName: "Home", operation: .shell, elapsedSeconds: 125)
    }

    @Test func enabledDoesNotImplyConnectedOrReady() {
        let offline = DesktopControlPresentation(enabled: true, paused: false, connected: false, readiness: "ready")
        #expect(offline.state == .connecting)
        let denied = DesktopControlPresentation(enabled: true, paused: false, connected: true, readiness: "permission_required")
        #expect(denied.state == .needsAttention)
        #expect(offline.symbol != denied.symbol)
    }

    @Test func activeOwnerAndElapsedTimeAreVisibleOnlyForCurrentConnection() {
        let active = DesktopControlPresentation(enabled: true, paused: false, connected: true, readiness: "ready", activity: activity)
        #expect(active.state == .controlling)
        #expect(active.activity?.ownerLabel == "Prototype · Home")
        #expect(active.activity?.elapsedLabel == "2 min")
        let disconnected = DesktopControlPresentation(enabled: true, paused: false, connected: false, readiness: "ready", activity: activity)
        #expect(disconnected.activity == nil)
        let paused = DesktopControlPresentation(enabled: true, paused: true, connected: true, readiness: "ready", activity: activity)
        #expect(paused.activity == nil)
        let switching = DesktopControlPresentation(enabled: true, paused: false, connected: true, readiness: "ready",
                                                  environmentSwitchPending: true, activity: activity)
        #expect(switching.activity == nil)
    }

    @Test func degradedActiveWorkKeepsStopAvailable() throws {
        let state = DesktopControlPresentation(enabled: true, paused: false, connected: true,
                                               readiness: "permission_required", hasError: true, activity: activity)
        #expect(state.activity != nil)
        let action = try #require(DesktopMenuRelayAction(relayEnabled: true, relayPaused: false, hasError: true,
                                                       hasTrustedConfiguration: true, environmentSwitchPending: false,
                                                       activelyControlling: state.activity != nil))
        #expect(action.title == "Stop Control")
        #expect(action.isEnabled)
    }

    @Test func cleanupDoesNotClaimControlStoppedSuccessfully() {
        let pending = DesktopControlPresentation(enabled: true, paused: true, connected: true, readiness: "paused", cleanupPending: true)
        #expect(pending.message == "Stopping remote control…")
        let failed = DesktopControlPresentation(enabled: true, paused: true, connected: true, readiness: "paused", cleanupFailed: true)
        #expect(failed.state == .needsAttention)
        #expect(failed.message.contains("Cleanup needs attention"))
    }

    @Test func disconnectedPauseDoesNotClaimAnActiveConnection() {
        let state = DesktopControlPresentation(enabled: true, paused: true, connected: false, readiness: "paused")
        #expect(state.message == "Remote control paused. Disconnected.")
    }

    @Test func categoriesNeverUseRemoteArgumentsOrUnknownOperationText() {
        #expect(DesktopControlActivityKind(operation: "desktop_control_execute") == .shell)
        #expect(DesktopControlActivityKind(operation: "secret command text") == nil)
        #expect(DesktopControlActivityKind(operation: "desktop_control_status") == nil)
    }

    @Test func reportHasOnlyAllowlistedLocalStatus() {
        let report = Self.report()
        #expect(report.text.contains("Processes: 2"))
        #expect(report.text.contains("Last successful connection: Not observed"))
        #expect(!report.text.contains("Prototype"))
        #expect(!report.text.contains("Home"))
        #expect(!report.text.contains("control_token"))
        #expect(report.text.count < 1500)
    }

    static func report() -> DesktopControlDiagnosticReport {
        .init(appVersion: "0.1.0", driverVersion: "0.29.1", state: .ready, connected: true,
              lastConnection: nil, guiReady: true, nativeReady: true, session: .unlocked,
              login: .enabled, reconnectPending: false, cleanupPending: false,
              resources: .init(activeProcesses: 2, openFileHandles: 1, bufferedOutputBytes: 32, outputGapsTotal: 0))
    }
}

@MainActor
@Suite struct DesktopControlDiagnosticsModelTests {
    @Test func openingReadsWithoutRepairAndClosingFencesThePendingRead() async {
        var finish: CheckedContinuation<DesktopControlDiagnosticReport, Never>?
        var reads = 0
        var repairs = 0
        let model = DesktopControlDiagnosticsModel(read: {
            reads += 1
            return await withCheckedContinuation { finish = $0 }
        }, repair: { repairs += 1 })
        model.start()
        for _ in 0..<100 where finish == nil { await Task.yield() }
        #expect(reads == 1)
        #expect(repairs == 0)
        model.stop()
        finish?.resume(returning: DesktopControlPresentationTests.report())
        for _ in 0..<10 { await Task.yield() }
        #expect(model.report == nil)
        #expect(repairs == 0)
    }

    @Test func repairIsExplicitAndFailureRemainsVisible() async {
        struct Failure: LocalizedError { var errorDescription: String? { "Service unavailable" } }
        var repairs = 0
        let model = DesktopControlDiagnosticsModel(read: { DesktopControlPresentationTests.report() }, repair: {
            repairs += 1
            throw Failure()
        })
        #expect(repairs == 0)
        await model.repairControl()
        #expect(repairs == 1)
        #expect(!model.isRepairing)
        #expect(model.repairError == "Service unavailable")
    }
}
