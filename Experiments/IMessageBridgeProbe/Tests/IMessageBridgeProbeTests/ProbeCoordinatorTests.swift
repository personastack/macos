import Foundation
import Testing
@testable import IMessageBridgeProbe

private let selectedTarget = ProbeTarget(
    conversationID: "42", accountID: "synthetic-account", sourceGeneration: "source-1", displayName: "Test contact"
)

private actor FakeBackend: ProbeBackend {
    var observed: [String] = []
    var automationIntents: [Bool] = []
    var readinessValue = ProbeReadiness(
        databaseReady: true, liveAccountID: "synthetic-account", sourceGeneration: "source-1", adapterRevision: 2
    )
    var readValue = ProbeReadObservation(
        target: selectedTarget, service: .imessage, messagesObserved: 1, continuityVerified: true
    )
    var sendValue = ProbeSendObservation.localRecordConfirmed(messageID: "synthetic-guid", service: .imessage, target: selectedTarget)
    var sendThrows = false
    var readGate: TestGate?
    var readStarted: TestGate?
    var cancelled = false
    var sendPrecheckGate: TestGate?
    var sendPrecheckStarted: TestGate?
    var postDispatchGate: TestGate?
    var dispatchStarted: TestGate?
    var mutationDispatches = 0
    var sentTargets: [ProbeTarget] = []
    var readinessGate: TestGate?
    var readinessStarted: TestGate?

    func readiness(requestAutomation: Bool) async throws -> ProbeReadiness {
        observed.append("readiness")
        automationIntents.append(requestAutomation)
        await readinessStarted?.release()
        await readinessGate?.wait()
        return readinessValue
    }

    func inspect(_ target: ProbeTarget) async throws -> ProbeReadObservation {
        observed.append("inspect")
        await readStarted?.release()
        await readGate?.wait()
        return readValue
    }

    func send(_ target: ProbeTarget, text: String) async throws -> ProbeSendObservation {
        observed.append("send")
        #expect(target == selectedTarget)
        #expect(text == ProbeCoordinator.testText)
        await sendPrecheckStarted?.release()
        await sendPrecheckGate?.wait()
        guard !Task.isCancelled, !cancelled else { return .notStarted }
        mutationDispatches += 1
        sentTargets.append(target)
        await dispatchStarted?.release()
        await postDispatchGate?.wait()
        guard !Task.isCancelled, !cancelled else { return .outcomeUnknown }
        if sendThrows { throw ProbeFailure.providerUnavailable }
        return sendValue
    }

    func cancel() async {
        cancelled = true
        await readinessGate?.release()
        await readGate?.release()
        await sendPrecheckGate?.release()
        await postDispatchGate?.release()
    }

    func setReadiness(_ value: ProbeReadiness) { readinessValue = value }
    func setRead(_ value: ProbeReadObservation) { readValue = value }
    func setSend(_ value: ProbeSendObservation) { sendValue = value }
    func failSend() { sendThrows = true }
    func gates(started: TestGate, wait: TestGate) { readStarted = started; readGate = wait }
    func holdBeforeDispatch(started: TestGate, wait: TestGate) { sendPrecheckStarted = started; sendPrecheckGate = wait }
    func holdAfterDispatch(started: TestGate, wait: TestGate) { dispatchStarted = started; postDispatchGate = wait }
    func holdReadiness(started: TestGate, wait: TestGate) { readinessStarted = started; readinessGate = wait }
}

private actor TestGate {
    var released = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private func readyToSend(_ backend: FakeBackend = FakeBackend()) async -> ProbeCoordinator {
    let probe = ProbeCoordinator(backend: backend, target: selectedTarget)
    #expect(await probe.checkPrerequisites().phase == .readyToRead)
    #expect(await probe.readSelectedConversation().phase == .readyToSend)
    return probe
}

@Test func idleProbeHasNoProviderEffects() async {
    let backend = FakeBackend()
    let probe = ProbeCoordinator(backend: backend, target: selectedTarget)
    #expect(await probe.snapshot().phase == .idle)
    #expect(await probe.sendOneConfirmedTestMessage().phase == .idle)
    #expect(await backend.observed.isEmpty)
}

@Test func oneConfirmedSendNeedsPriorExplicitRead() async {
    let backend = FakeBackend()
    let probe = await readyToSend(backend)
    let first = await probe.sendOneConfirmedTestMessage()
    #expect(first.phase == .localRecordConfirmed)
    #expect(first.sendAttempted && first.localOutgoingRecordVerified)
    #expect(await probe.cancel().phase == .localRecordConfirmed)
    _ = await probe.sendOneConfirmedTestMessage()
    #expect(await backend.observed.filter { $0 == "send" }.count == 1)
    #expect(await backend.automationIntents == [true, false, false])
}

@Test func accountChangeBeforeSendPreventsDispatch() async {
    let backend = FakeBackend()
    let probe = await readyToSend(backend)
    await backend.setReadiness(ProbeReadiness(databaseReady: true, liveAccountID: "other", sourceGeneration: "source-1", adapterRevision: 2))
    let result = await probe.sendOneConfirmedTestMessage()
    #expect(result.phase == .needsAttention && result.failure == .identityChanged)
    #expect(!result.sendAttempted)
    #expect(await backend.observed.filter { $0 == "send" }.isEmpty)
}

@Test(arguments: [false, true]) func missingDatabaseOrAdapterFailsBeforeRead(wrongAdapter: Bool) async {
    let backend = FakeBackend()
    await backend.setReadiness(ProbeReadiness(databaseReady: wrongAdapter, liveAccountID: "synthetic-account", sourceGeneration: "source-1", adapterRevision: wrongAdapter ? 1 : 2))
    let probe = ProbeCoordinator(backend: backend, target: selectedTarget)
    #expect(await probe.checkPrerequisites().failure == .prerequisitesUnavailable)
    #expect(await backend.observed == ["readiness"])
}

@Test func ambiguousLiveAccountFailsClosed() async {
    let backend = FakeBackend()
    await backend.setReadiness(ProbeReadiness(databaseReady: true, liveAccountID: nil, sourceGeneration: "source-1", adapterRevision: 2))
    let probe = ProbeCoordinator(backend: backend, target: selectedTarget)
    #expect(await probe.checkPrerequisites().failure == .identityChanged)
}

@Test(arguments: [ProbeService.other, .imessage]) func readNeedsExactScopeAndIMessage(service: ProbeService) async {
    let backend = FakeBackend()
    let target = service == .imessage
        ? ProbeTarget(conversationID: "99", accountID: "synthetic-account", sourceGeneration: "source-1", displayName: "Other")
        : selectedTarget
    await backend.setRead(ProbeReadObservation(target: target, service: service, messagesObserved: 1, continuityVerified: true))
    let probe = ProbeCoordinator(backend: backend, target: selectedTarget)
    _ = await probe.checkPrerequisites()
    #expect(await probe.readSelectedConversation().phase == .needsAttention)
    #expect(await backend.observed.filter { $0 == "send" }.isEmpty)
}

@Test func cancelledReadCannotApproveSendingWhenItsResultArrivesLate() async {
    let backend = FakeBackend()
    let started = TestGate()
    let gate = TestGate()
    await backend.gates(started: started, wait: gate)
    let probe = ProbeCoordinator(backend: backend, target: selectedTarget)
    _ = await probe.checkPrerequisites()
    let reading = Task { await probe.readSelectedConversation() }
    await started.wait()
    #expect(await probe.cancel().phase == .cancelled)
    await gate.release()
    #expect(await reading.value.phase == .cancelled)
    _ = await probe.sendOneConfirmedTestMessage()
    #expect(await backend.observed.filter { $0 == "send" }.isEmpty)
}

@Test func uncertainSendCannotRetry() async {
    let backend = FakeBackend()
    await backend.failSend()
    let probe = await readyToSend(backend)
    #expect(await probe.sendOneConfirmedTestMessage().phase == .outcomeUnknown)
    _ = await probe.checkPrerequisites()
    _ = await probe.readSelectedConversation()
    _ = await probe.sendOneConfirmedTestMessage()
    #expect(await backend.observed.filter { $0 == "send" }.count == 1)
}

@Test func missingGuidIsUnknownRatherThanSuccess() async {
    let backend = FakeBackend()
    await backend.setSend(.localRecordConfirmed(messageID: "", service: .imessage, target: selectedTarget))
    let probe = await readyToSend(backend)
    #expect(await probe.sendOneConfirmedTestMessage().phase == .outcomeUnknown)
}

@Test func publicCancelJoinsHeldBackendPrechecksAndPreventsMutation() async {
    let backend = FakeBackend()
    let probe = await readyToSend(backend)
    let started = TestGate()
    let gate = TestGate()
    await backend.holdBeforeDispatch(started: started, wait: gate)
    let sending = Task { await probe.sendOneConfirmedTestMessage() }
    await started.wait()
    let cancelled = await probe.cancel()
    #expect(cancelled.phase == .cancelled)
    #expect(await sending.value.phase == .cancelled)
    #expect(await backend.mutationDispatches == 0)
    #expect(await backend.cancelled)
    _ = await probe.sendOneConfirmedTestMessage()
    #expect(await backend.mutationDispatches == 0)
}

@Test func publicCancelAfterPossibleDispatchKeepsUnknownAndJoinsCleanup() async {
    let backend = FakeBackend()
    let probe = await readyToSend(backend)
    let started = TestGate()
    let gate = TestGate()
    await backend.holdAfterDispatch(started: started, wait: gate)
    let sending = Task { await probe.sendOneConfirmedTestMessage() }
    await started.wait()
    let cancelled = await probe.cancel()
    #expect(cancelled.phase == .outcomeUnknown)
    #expect(await sending.value.phase == .outcomeUnknown)
    #expect(await backend.mutationDispatches == 1)
    #expect(await backend.cancelled)
}

@Test func heldVerificationKeepsPresentationAndExecutionBoundToApprovedSelection() async {
    let backend = FakeBackend()
    let started = TestGate(), gate = TestGate()
    await backend.holdReadiness(started: started, wait: gate)
    var pickerSelection = selectedTarget
    let probe = ProbeCoordinator(backend: backend, target: pickerSelection)
    let verification = Task { await probe.checkPrerequisites() }
    await started.wait()
    // The caller changes its selection while the approved selection's account
    // verification is suspended. It cannot supply a second label to the view.
    pickerSelection = ProbeTarget(conversationID: "99", accountID: "synthetic-account",
                                  sourceGeneration: "source-1", displayName: "Other contact")
    #expect(probe.approvedTargetDisplayName == selectedTarget.displayName)
    #expect(probe.approvedTargetDisplayName != pickerSelection.displayName)
    await gate.release()
    #expect(await verification.value.phase == .readyToRead)
    #expect(await probe.readSelectedConversation().phase == .readyToSend)
    #expect(await probe.sendOneConfirmedTestMessage().phase == .localRecordConfirmed)
    let dispatched = await backend.sentTargets
    #expect(dispatched == [selectedTarget])
    #expect(dispatched.first?.displayName == probe.approvedTargetDisplayName)
    #expect(dispatched.first?.conversationID != pickerSelection.conversationID)
}

@Test func receiptHasNoSelectorsNamesBodiesOrClaimedOsProof() async throws {
    let backend = FakeBackend()
    let probe = await readyToSend(backend)
    let evidence = await probe.sendOneConfirmedTestMessage()
    let text = String(decoding: try evidence.redactedJSON(), as: UTF8.self)
    for secret in ["synthetic-account", "source-1", "Test contact", "synthetic-guid", ProbeCoordinator.testText] {
        #expect(!text.contains(secret))
    }
    #expect(evidence.requiresExternalSignatureVerification)
    #expect(evidence.evidenceKind == "provider_probe_observation")
    #expect(evidence.continuityScope == "same_probe_session")
    #expect(evidence.observedCheckpointContinuityVerified)
}
