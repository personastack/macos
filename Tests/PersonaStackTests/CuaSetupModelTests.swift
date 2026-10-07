import Foundation
import Testing
import PersonaStackCore
@testable import PersonaStack

@MainActor
private final class CuaSetupOperationsFixture {
    var calls: [String] = []
    var readiness = CuaSetupReadiness.absent
    var observeError: (any Error)?
    var installError: (any Error)?
    var permissionError: (any Error)?
    var hasBundle = false
    var downloads = 0

    var operations: CuaSetupModel.Operations {
        .init(observe: {
            self.calls.append("observe")
            if let error = self.observeError { throw error }
            return self.readiness
        }, install: { progress in
            self.calls.append("install")
            if !self.hasBundle {
                await progress(.downloading)
                self.downloads += 1
                self.hasBundle = true
            }
            await progress(.installed)
            await progress(.starting)
            if let error = self.installError {
                self.readiness = .stopped
                throw error
            }
            self.readiness = .permissions(Self.missingAccessibility)
        }, permissions: {
            self.calls.append("permissions")
            if let error = self.permissionError { throw error }
            self.readiness = .ready
        })
    }

    static var missingAccessibility: CuaDriverPermissionSnapshot {
        .init(accessibility: false, screenRecording: true, standaloneAttributionValid: true)
    }
}

/// Intentionally ignores cancellation so fixtures can deliver a stale result.
/// Every test resumes the gate and joins the old operation before returning.
@MainActor
private final class CuaSetupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var entered = false

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
        }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func joinCurrentOperation(of model: CuaSetupModel) async -> Task<Void, Never> {
    var waiter: Task<Void, Never>!
    await withCheckedContinuation { started in
        waiter = Task { @MainActor in
            started.resume()
            await model.waitForOperation()
        }
    }
    return waiter
}

@Test @MainActor
func cuaSetupDecisionTableHasOneActionFromCurrentObservation() async {
    let permissions = CuaSetupReadiness.permissions(CuaSetupOperationsFixture.missingAccessibility)
    let rows: [(CuaSetupReadiness, CuaSetupModel.PrimaryAction, String, Bool)] = [
        (.unknown, .check, "Check Again", false),
        (.absent, .install, "Install CUA", false),
        (.installed, .check, "Check Again", true),
        (.stopped, .start, "Start CUA", true),
        (permissions, .permissions, "Grant CUA Permissions", true),
        (.unavailable(installed: true, message: "Status unavailable"), .check, "Check Again", true),
        (.ready, .finish, "Done", true)
    ]
    for (readiness, action, label, installed) in rows {
        let fixture = CuaSetupOperationsFixture()
        fixture.readiness = readiness
        let model = CuaSetupModel(operations: fixture.operations)
        model.refresh()
        await model.waitForOperation()
        #expect(model.primaryAction == action)
        #expect(model.primaryLabel == label)
        #expect(model.installed == installed)
        #expect(model.ready == (readiness == .ready))
        #expect(!model.busy && !model.message.isEmpty)
        #expect(fixture.calls == ["observe"])
    }
}

@Test @MainActor
func cuaSetupPermissionGuidanceNamesOnlyMissingGrants() async {
    let rows: [(Bool, Bool, String)] = [
        (false, true, "Accessibility access"),
        (true, false, "Screen Recording access"),
        (false, false, "Accessibility and Screen Recording"),
        (true, true, "capture your screen directly")
    ]
    for (accessibility, recording, expected) in rows {
        let fixture = CuaSetupOperationsFixture()
        fixture.readiness = .permissions(.init(accessibility: accessibility,
            screenRecording: recording, standaloneAttributionValid: true))
        let model = CuaSetupModel(operations: fixture.operations)
        model.refresh()
        await model.waitForOperation()
        #expect(model.message.contains(expected))
        #expect(model.primaryAction == .permissions && !model.ready)
        #expect(fixture.calls == ["observe"])
    }
}

@Test @MainActor
func cuaSetupInstallFailureRetryGrantAndFinishReuseCompletedWork() async {
    let fixture = CuaSetupOperationsFixture()
    fixture.installError = CuaStandaloneServiceError.startFailed
    let model = CuaSetupModel(operations: fixture.operations)
    model.reset(connecting: true)
    model.refresh()
    await model.waitForOperation()
    #expect(model.primaryAction == .install)

    model.install()
    #expect(model.busy && model.feedback == .working)
    await model.waitForOperation()
    #expect(model.installed && !model.ready && !model.busy)
    #expect(model.primaryLabel == "Retry Start" && model.feedback == .failure)
    #expect(model.message == CuaStandaloneServiceError.startFailed.errorDescription)
    #expect(fixture.downloads == 1)

    fixture.installError = nil
    model.install()
    await model.waitForOperation()
    #expect(fixture.downloads == 1)
    #expect(model.outcome == .none && model.primaryAction == .permissions)
    model.permissions()
    #expect(model.operation == "Requesting CUA permissions")
    await model.waitForOperation()
    #expect(model.ready && model.primaryLabel == "Connect PersonaStack")
    var completions = 0
    model.verifyForFinish { completions += 1 }
    #expect(!model.ready && model.busy)
    await model.waitForOperation()
    #expect(completions == 1 && model.ready)
    #expect(fixture.calls == ["observe", "install", "observe", "install", "observe", "permissions", "observe", "observe"])
}

@Test @MainActor
func cuaSetupFailedGrantReadsCurrentPermissionsAndPreservesCommandError() async {
    let fixture = CuaSetupOperationsFixture()
    fixture.readiness = .permissions(CuaSetupOperationsFixture.missingAccessibility)
    fixture.permissionError = CuaStandaloneServiceError.permissionTimedOut
    let model = CuaSetupModel(operations: fixture.operations)
    model.permissions()
    await model.waitForOperation()
    #expect(fixture.calls == ["permissions", "observe"])
    #expect(model.installed && !model.ready && !model.busy)
    #expect(model.feedback == .failure)
    #expect(model.message == CuaStandaloneServiceError.permissionTimedOut.errorDescription)
    #expect(model.nextStep?.contains("Accessibility") == true)
    #expect(model.primaryAction == .check)
}

@Test @MainActor
func cuaSetupPassiveRefreshKeepsFailureUntilExplicitSuccessfulCheck() async {
    let fixture = CuaSetupOperationsFixture()
    fixture.permissionError = CuaStandaloneServiceError.permissionCommandFailed
    fixture.readiness = .permissions(CuaSetupOperationsFixture.missingAccessibility)
    let model = CuaSetupModel(operations: fixture.operations)
    model.permissions()
    await model.waitForOperation()
    let failure = model.outcome
    let message = model.message
    fixture.readiness = .ready
    model.refresh()
    #expect(model.message == message)
    await model.waitForOperation()
    #expect(model.ready && model.feedback == .failure)
    #expect(model.outcome == failure && model.message == message)
    model.check()
    await model.waitForOperation()
    #expect(model.ready && model.feedback == .success && model.outcome == .none)
    #expect(fixture.calls == ["permissions", "observe", "observe", "observe"])
}

@Test @MainActor
func cuaSetupReturnedCheckFailureSurvivesPassiveRecovery() async {
    let fixture = CuaSetupOperationsFixture()
    let reason = "CUA could not be checked. Check Again to continue."
    fixture.readiness = .unavailable(installed: true, message: reason)
    let model = CuaSetupModel(operations: fixture.operations)
    model.check()
    await model.waitForOperation()
    #expect(model.outcome == .failure(reason))
    fixture.readiness = .ready
    model.refresh()
    await model.waitForOperation()
    #expect(model.ready && model.message == reason && model.feedback == .failure)
    model.check()
    await model.waitForOperation()
    #expect(model.outcome == .none && model.feedback == .success)
    #expect(fixture.calls == ["observe", "observe", "observe"])
}

@Test @MainActor
func cuaSetupFailedPassiveRefreshCannotReplaceLastOperationError() async {
    let fixture = CuaSetupOperationsFixture()
    fixture.permissionError = CuaStandaloneServiceError.permissionTimedOut
    fixture.readiness = .permissions(CuaSetupOperationsFixture.missingAccessibility)
    let model = CuaSetupModel(operations: fixture.operations)
    model.permissions()
    await model.waitForOperation()
    let failure = model.outcome
    let message = model.message
    fixture.observeError = CuaMCPProxyError.notStarted
    model.refresh()
    await model.waitForOperation()
    #expect(!model.busy && !model.ready)
    #expect(model.outcome == failure && model.message == message)
    #expect(model.primaryAction == .check)
}

@Test @MainActor
func cuaSetupUnknownReadbackNeverBecomesMissingGrantOrInstallAdvice() async {
    let fixture = CuaSetupOperationsFixture()
    fixture.readiness = .unavailable(installed: true, message: "CUA status could not be checked.")
    let model = CuaSetupModel(operations: fixture.operations)
    model.refresh()
    await model.waitForOperation()
    #expect(model.installed && !model.ready)
    #expect(model.primaryAction == .check && model.feedback == .failure)
    #expect(fixture.calls == ["observe"])
}

@Test @MainActor
func cuaSetupManualRepairFailuresAlwaysOfferCheck() async {
    let failures: [any Error] = [CuaStandaloneServiceError.serviceDisabled,
        CuaMCPProxyError.serviceMismatch, CuaDriverInstallError.invalidSignature,
        CuaDriverInstallError.invalidLayout]
    for failure in failures {
        let fixture = CuaSetupOperationsFixture()
        fixture.installError = failure
        let model = CuaSetupModel(operations: fixture.operations)
        model.install()
        await model.waitForOperation()
        #expect(model.primaryAction == .check && model.primaryLabel == "Check Again")
        #expect(!model.message.isEmpty && model.feedback == .failure)
    }
}

@Test @MainActor
func cuaSetupDownloadChecksumCanRetryButInvalidExistingBundleRequiresRecheck() async {
    for installed in [false, true] {
        let fixture = CuaSetupOperationsFixture()
        fixture.readiness = installed
            ? .unavailable(installed: true, message: CuaDriverInstallError.checksumMismatch.localizedDescription)
            : .absent
        var operations = fixture.operations
        operations.install = { _ in throw CuaDriverInstallError.checksumMismatch }
        let model = CuaSetupModel(operations: operations)
        model.install()
        await model.waitForOperation()
        #expect(model.primaryAction == (installed ? .check : .install))
        #expect(model.primaryLabel == (installed ? "Check Again" : "Retry Install"))
        #expect(model.installed == installed && model.feedback == .failure)
    }
}

@Test @MainActor
func cuaSetupUnknownFailureHasSafeNonemptyFeedbackAndSettlesActivity() async {
    let fixture = CuaSetupOperationsFixture()
    fixture.observeError = NSError(domain: "private-diagnostic", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "raw private command output"])
    let model = CuaSetupModel(operations: fixture.operations)
    model.check()
    await model.waitForOperation()
    #expect(!model.busy && !model.ready && model.feedback == .failure)
    #expect(!model.message.isEmpty && !model.message.contains("raw private"))
    #expect(model.primaryAction == .check)
}

@Test @MainActor
func cuaSetupBusyRejectsDuplicateAndDifferentActions() async {
    let fixture = CuaSetupOperationsFixture()
    let gate = CuaSetupGate()
    var operations = fixture.operations
    operations.install = { _ in fixture.calls.append("install"); await gate.suspend() }
    fixture.readiness = .ready
    let model = CuaSetupModel(operations: operations)
    model.install()
    await gate.waitUntilEntered()
    model.install()
    model.permissions()
    model.check()
    model.refresh()
    var finishes = 0
    model.verifyForFinish { finishes += 1 }
    #expect(model.busy && fixture.calls == ["install"])
    gate.resume()
    await model.waitForOperation()
    #expect(model.ready && !model.busy && finishes == 0)
    #expect(fixture.calls == ["install", "observe"])
}

@Test @MainActor
func cuaSetupProgressIsVisibleAndPreservesInstalledStageAfterFailedStart() async {
    let fixture = CuaSetupOperationsFixture()
    let download = CuaSetupGate()
    let start = CuaSetupGate()
    var operations = fixture.operations
    operations.install = { progress in
        await progress(.downloading)
        await download.suspend()
        await progress(.installed)
        await progress(.starting)
        await start.suspend()
        fixture.readiness = .stopped
        throw CuaStandaloneServiceError.startTimedOut
    }
    let model = CuaSetupModel(operations: operations)
    model.install()
    await download.waitUntilEntered()
    #expect(model.operation == "Downloading CUA" && !model.installed)
    #expect(model.message.contains("few minutes") && model.busy)
    download.resume()
    await start.waitUntilEntered()
    #expect(model.installed && !model.ready && model.busy)
    #expect(model.operation == "Starting CUA service")
    start.resume()
    await model.waitForOperation()
    #expect(model.installed && !model.ready && !model.busy)
    #expect(model.installStage == nil && model.operation == nil)
    #expect(model.message == CuaStandaloneServiceError.startTimedOut.errorDescription)
}

@Test @MainActor
func cuaSetupCancelReopenFencesEverySuspendedOperationAndOldProgress() async {
    for action in [CuaSetupModel.Action.install, .permissions, .check] {
        let fixture = CuaSetupOperationsFixture()
        let gate = CuaSetupGate()
        var operations = fixture.operations
        if action == .install {
            operations.install = { progress in
                fixture.calls.append("install")
                await progress(.downloading)
                await gate.suspend()
                await progress(.installed)
                await progress(.starting)
            }
        } else if action == .permissions {
            operations.permissions = { fixture.calls.append("permissions"); await gate.suspend() }
        } else {
            var first = true
            operations.observe = {
                fixture.calls.append("observe")
                if first {
                    first = false
                    await gate.suspend()
                    return .ready
                }
                return .absent
            }
        }
        let model = CuaSetupModel(operations: operations)
        switch action {
        case .install: model.install()
        case .permissions: model.permissions()
        default: model.check()
        }
        await gate.waitUntilEntered()
        let oldOperation = await joinCurrentOperation(of: model)
        model.cancel()
        model.reset(connecting: true)
        model.refresh()
        await model.waitForOperation()
        let outcome = model.outcome
        let message = model.message
        gate.resume()
        await oldOperation.value
        #expect(!model.installed && !model.ready && !model.busy)
        #expect(model.connecting && model.primaryAction == .install)
        #expect(model.installStage == nil && model.outcome == outcome && model.message == message)
        #expect(fixture.calls == [action == .install ? "install" : action == .permissions ? "permissions" : "observe", "observe"])
    }
}

@Test @MainActor
func cuaSetupUnexpectedCancellationShowsErrorAndSettlesBusy() async {
    let fixture = CuaSetupOperationsFixture()
    fixture.permissionError = CancellationError()
    fixture.readiness = .permissions(CuaSetupOperationsFixture.missingAccessibility)
    let model = CuaSetupModel(operations: fixture.operations)
    model.permissions()
    await model.waitForOperation()
    #expect(!model.busy && model.feedback == .failure)
    #expect(model.message.contains("interrupted") && model.primaryAction == .permissions)
    #expect(fixture.calls == ["permissions", "observe"])
}

@Test @MainActor
func cuaSetupFinishRechecksRevokedPermissionsBeforeRunningContinuation() async {
    let fixture = CuaSetupOperationsFixture()
    fixture.readiness = .ready
    let model = CuaSetupModel(operations: fixture.operations)
    model.reset(connecting: true)
    model.refresh()
    await model.waitForOperation()
    #expect(model.ready && model.primaryLabel == "Connect PersonaStack")
    fixture.readiness = .permissions(CuaSetupOperationsFixture.missingAccessibility)
    var completions = 0
    model.verifyForFinish { completions += 1 }
    #expect(!model.ready && model.busy)
    await model.waitForOperation()
    #expect(completions == 0 && !model.ready && model.primaryAction == .permissions)
    #expect(fixture.calls == ["observe", "observe"])
}

@Test @MainActor
func cuaSetupRepairReopenEndsWithDoneWithoutEnrollment() async {
    let fixture = CuaSetupOperationsFixture()
    fixture.readiness = .ready
    let model = CuaSetupModel(operations: fixture.operations)
    model.reset(connecting: false)
    #expect(model.observation == .unknown && !model.ready)
    model.refresh()
    await model.waitForOperation()
    #expect(model.primaryLabel == "Done" && !model.connecting)
    var completed = false
    model.verifyForFinish { completed = true }
    await model.waitForOperation()
    #expect(completed && fixture.calls == ["observe", "observe"])
}

@Test @MainActor
func cuaSetupCloudFailureKeepsCuaReadyAndOffersReturnWithoutDeadConnect() async {
    let fixture = CuaSetupOperationsFixture()
    fixture.readiness = .ready
    let model = CuaSetupModel(operations: fixture.operations)
    model.reset(connecting: true)
    model.refresh()
    await model.waitForOperation()
    model.beginConnection()
    #expect(model.connectingToCloud && model.message.contains("Connecting"))
    model.install()
    model.permissions()
    model.check()
    model.refresh()
    #expect(fixture.calls == ["observe"])
    model.failConnection("Connection result could not be confirmed.")
    #expect(model.ready && !model.busy && !model.connectingToCloud)
    #expect(!model.connecting && model.primaryAction == .returnToConnection)
    #expect(model.primaryLabel == "Return to Connection" && model.feedback == .failure)
    model.check()
    model.install()
    var completions = 0
    model.verifyForFinish { completions += 1 }
    await model.waitForOperation()
    #expect(completions == 0 && fixture.calls == ["observe"])
    #expect(model.message == "Connection result could not be confirmed.")
}
