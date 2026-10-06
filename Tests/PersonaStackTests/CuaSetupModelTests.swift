import Foundation
import Testing
@testable import PersonaStack

@MainActor
private final class CuaSetupOperationsFixture {
    var calls: [String] = []
    var installed = false
    var checkError: Error?
    var installContinuation: CheckedContinuation<Void, Never>?
    var startedContinuation: CheckedContinuation<Void, Never>?

    var operations: CuaSetupModel.Operations {
        .init(installed: { self.calls.append("installed"); return self.installed },
              install: { self.calls.append("install"); self.installed = true },
              permissions: { self.calls.append("permissions") },
              check: {
                  self.calls.append("check")
                  if let error = self.checkError { throw error }
              })
    }
}

@Test @MainActor
func cuaSetupRefreshNeverInstallsOrPrompts() async {
    let fixture = CuaSetupOperationsFixture()
    let model = CuaSetupModel(operations: fixture.operations)
    model.reset(connecting: true)
    model.refresh()
    await model.waitForOperation()
    #expect(fixture.calls == ["installed"])
    #expect(!model.installed && !model.ready && !model.busy)
    #expect(model.connecting)
}

@Test @MainActor
func cuaSetupUsesExplicitInstallPermissionsAndConnectionChecks() async {
    let fixture = CuaSetupOperationsFixture()
    let model = CuaSetupModel(operations: fixture.operations)
    model.install()
    await model.waitForOperation()
    #expect(model.installed && !model.ready)
    model.permissions()
    await model.waitForOperation()
    #expect(!model.ready)
    model.check()
    await model.waitForOperation()
    #expect(model.ready && !model.busy)
    #expect(fixture.calls == ["install", "permissions", "check"])
}

@Test @MainActor
func cuaSetupConnectingFencesStepActionsButCancellationRemainsAvailable() async {
    let fixture = CuaSetupOperationsFixture()
    let model = CuaSetupModel(operations: fixture.operations)
    model.connectingToCloud = true
    model.install()
    model.permissions()
    model.check()
    model.refresh()
    await model.waitForOperation()
    #expect(fixture.calls.isEmpty)
    model.cancel()
    #expect(!model.connectingToCloud && !model.busy)
    model.refresh()
    await model.waitForOperation()
    #expect(fixture.calls == ["installed"])
}

@Test @MainActor
func cuaSetupBusyFencesDuplicateAndDifferentStepActions() async {
    let fixture = CuaSetupOperationsFixture()
    var operations = fixture.operations
    operations.install = {
        fixture.calls.append("install")
        await withCheckedContinuation { continuation in
            fixture.installContinuation = continuation
            fixture.startedContinuation?.resume()
            fixture.startedContinuation = nil
        }
    }
    let model = CuaSetupModel(operations: operations)
    model.install()
    await withCheckedContinuation { continuation in
        if fixture.installContinuation != nil { continuation.resume() }
        else { fixture.startedContinuation = continuation }
    }
    model.install()
    model.permissions()
    model.check()
    #expect(model.busy && fixture.calls == ["install"])
    fixture.installContinuation?.resume()
    fixture.installContinuation = nil
    await model.waitForOperation()
    #expect(model.installed && !model.busy && !model.ready)
}

@Test @MainActor
func cuaSetupResetDropsPreviouslyObservedReadinessAndInstallation() async {
    let fixture = CuaSetupOperationsFixture()
    fixture.installed = true
    let model = CuaSetupModel(operations: fixture.operations)
    model.refresh()
    await model.waitForOperation()
    model.check()
    await model.waitForOperation()
    #expect(model.installed && model.ready)
    model.reset(connecting: false)
    #expect(!model.installed && !model.ready && !model.connecting)
    #expect(model.message.isEmpty)
    #expect(fixture.calls == ["installed", "check"])
}

private enum CuaSetupFixtureError: LocalizedError {
    case denied
    var errorDescription: String? { "CUA permission was denied." }
}

@Test @MainActor
func cuaSetupDeniedPermissionsNeverRetryInstallOrCheck() async {
    let fixture = CuaSetupOperationsFixture()
    var operations = fixture.operations
    operations.permissions = {
        fixture.calls.append("permissions")
        throw CuaSetupFixtureError.denied
    }
    let model = CuaSetupModel(operations: operations)
    model.permissions()
    await model.waitForOperation()
    #expect(!model.ready && !model.busy)
    #expect(model.message == "CUA permission was denied.")
    #expect(fixture.calls == ["permissions"])
}

@Test @MainActor
func cuaSetupCancelledCheckCannotOverwriteSuccessorObservation() async {
    let fixture = CuaSetupOperationsFixture()
    var operations = fixture.operations
    operations.check = {
        fixture.calls.append("check")
        await withCheckedContinuation { continuation in
            fixture.installContinuation = continuation
            fixture.startedContinuation?.resume()
            fixture.startedContinuation = nil
        }
    }
    let model = CuaSetupModel(operations: operations)
    model.check()
    await withCheckedContinuation { continuation in
        if fixture.installContinuation != nil { continuation.resume() }
        else { fixture.startedContinuation = continuation }
    }
    // Capture the suspended operation before reset replaces the model's task.
    var oldOperation: Task<Void, Never>?
    await withCheckedContinuation { started in
        oldOperation = Task { @MainActor in
            started.resume()
            await model.waitForOperation()
        }
    }
    model.cancel()
    model.reset(connecting: true)
    model.refresh()
    await model.waitForOperation()
    let currentMessage = model.message
    #expect(!model.ready && !model.installed && !model.busy)
    fixture.installContinuation?.resume()
    fixture.installContinuation = nil
    await oldOperation?.value
    #expect(!model.ready && !model.installed && !model.busy)
    #expect(model.message == currentMessage)
    #expect(fixture.calls == ["check", "installed"])
}
