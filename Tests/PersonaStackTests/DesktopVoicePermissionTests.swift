import Foundation
import Testing
@testable import PersonaStack

@MainActor
private final class VoicePermissionPageFake: DesktopVoicePermissionPage {
    var expectedTests = 1
    var tests: [String] = []
    var cancellations: [String] = []
    var callbacks: [String: (Result<Bool, Error>) -> Void] = [:]
    var immediate: Result<Bool, Error>?

    func test(id: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        #expect(tests.count < expectedTests)
        #expect(UUID(uuidString: id) != nil && !tests.contains(id))
        tests.append(id)
        callbacks[id] = completion
        if let immediate { completion(immediate) }
    }

    func cancel(id: String) {
        #expect(tests.contains(id) && !cancellations.contains(id))
        cancellations.append(id)
    }

    func reply(_ result: Result<Bool, Error>, id: String? = nil) {
        guard let target = id ?? tests.last, let callback = callbacks[target] else {
            Issue.record("Unexpected callback without an owned test")
            return
        }
        callback(result)
    }
}

private enum VoicePermissionFixtureError: Error { case failed }

@Test @MainActor func voicePermissionImmediateReplyCancelsOnlyItsOwnedRecording() async throws {
    for ready in [false, true] {
        let page = VoicePermissionPageFake()
        page.immediate = .success(ready)
        let verifier = DesktopVoicePermissionVerifier()
        #expect(try await verifier.verify(page: page, isCurrent: { true }) == ready)
        #expect(page.tests.count == 1 && page.cancellations == page.tests)
    }
}

@Test @MainActor func voicePermissionCurrentSuccessAndPageErrorHaveCanonicalCleanup() async throws {
    let page = VoicePermissionPageFake()
    page.expectedTests = 2
    let verifier = DesktopVoicePermissionVerifier()
    let first = Task { try await verifier.verify(page: page, isCurrent: { true }) }
    while page.tests.isEmpty { await Task.yield() }
    page.reply(.success(true))
    #expect(try await first.value)
    let second = Task { try await verifier.verify(page: page, isCurrent: { true }) }
    while page.tests.count != 2 { await Task.yield() }
    page.reply(.failure(VoicePermissionFixtureError.failed))
    await #expect(throws: VoicePermissionFixtureError.failed) { try await second.value }
    #expect(page.cancellations == page.tests)
}

@Test @MainActor func voicePermissionStaleContextBeforeStartHasNoPageSideEffects() async {
    let page = VoicePermissionPageFake()
    let verifier = DesktopVoicePermissionVerifier()
    await #expect(throws: DesktopVoicePermissionError.pageChanged) {
        try await verifier.verify(page: page, isCurrent: { false })
    }
    #expect(page.tests.isEmpty && page.cancellations.isEmpty)
}

@Test @MainActor func voicePermissionOldDocumentDeviceOrEnvironmentCannotSupplyProof() async {
    let page = VoicePermissionPageFake()
    let verifier = DesktopVoicePermissionVerifier()
    var current = true
    let test = Task { try await verifier.verify(page: page, isCurrent: { current }) }
    while page.tests.isEmpty { await Task.yield() }
    current = false
    page.reply(.success(true))
    await #expect(throws: DesktopVoicePermissionError.pageChanged) { try await test.value }
    #expect(page.cancellations == page.tests)
}

@Test @MainActor func voicePermissionBusyRivalCannotTouchExistingTest() async throws {
    let owner = VoicePermissionPageFake()
    let rival = VoicePermissionPageFake()
    let verifier = DesktopVoicePermissionVerifier()
    let test = Task { try await verifier.verify(page: owner, isCurrent: { true }) }
    while owner.tests.isEmpty { await Task.yield() }
    await #expect(throws: DesktopVoicePermissionError.busy) {
        try await verifier.verify(page: rival, isCurrent: { true })
    }
    #expect(rival.tests.isEmpty && rival.cancellations.isEmpty && owner.cancellations.isEmpty)
    owner.reply(.success(true))
    #expect(try await test.value)
    #expect(owner.cancellations == owner.tests)
}

@Test @MainActor func voicePermissionDocumentChangeAfterReplyBeforeResumptionRejectsProof() async {
    let page = VoicePermissionPageFake()
    let verifier = DesktopVoicePermissionVerifier()
    var current = true
    let test = Task { try await verifier.verify(page: page, isCurrent: { current }) }
    while page.tests.isEmpty { await Task.yield() }
    page.reply(.success(true))
    current = false
    await #expect(throws: DesktopVoicePermissionError.pageChanged) { try await test.value }
    #expect(page.cancellations == page.tests)
}

@Test @MainActor func voicePermissionInvalidationRejectsLateReplyWithoutCancelingSuccessor() async throws {
    let page = VoicePermissionPageFake()
    page.expectedTests = 2
    let verifier = DesktopVoicePermissionVerifier()
    let first = Task { try await verifier.verify(page: page, isCurrent: { true }) }
    while page.tests.isEmpty { await Task.yield() }
    let old = page.tests[0]
    verifier.invalidate()
    await #expect(throws: DesktopVoicePermissionError.pageChanged) { try await first.value }
    let second = Task { try await verifier.verify(page: page, isCurrent: { true }) }
    while page.tests.count != 2 { await Task.yield() }
    page.reply(.success(true), id: old)
    #expect(page.cancellations == [old])
    page.reply(.success(false))
    #expect(try await second.value == false)
    verifier.invalidate()
    page.reply(.success(true), id: old)
    #expect(page.cancellations == page.tests)
}

@Test @MainActor func voicePermissionCancellationSettlesWithoutWaitingForPage() async {
    let page = VoicePermissionPageFake()
    let verifier = DesktopVoicePermissionVerifier()
    let test = Task { try await verifier.verify(page: page, isCurrent: { true }) }
    while page.tests.isEmpty { await Task.yield() }
    test.cancel()
    await #expect(throws: CancellationError.self) { try await test.value }
    #expect(page.cancellations == page.tests)
    page.reply(.success(true))
    #expect(page.cancellations == page.tests)
}

@Test @MainActor func voicePermissionCanceledBeforeStartHasNoPageSideEffects() async {
    let page = VoicePermissionPageFake()
    let verifier = DesktopVoicePermissionVerifier()
    let test = Task { try await verifier.verify(page: page, isCurrent: { true }) }
    test.cancel()
    await #expect(throws: CancellationError.self) { try await test.value }
    #expect(page.tests.isEmpty && page.cancellations.isEmpty)
}

@Test @MainActor func voicePermissionNativeDeadlineBoundsAnUnresponsivePage() async {
    let page = VoicePermissionPageFake()
    var fire: CheckedContinuation<Void, Never>?
    let verifier = DesktopVoicePermissionVerifier(wait: {
        await withCheckedContinuation { fire = $0 }
    })
    let test = Task { try await verifier.verify(page: page, isCurrent: { true }) }
    while fire == nil { await Task.yield() }
    fire?.resume()
    await #expect(throws: DesktopVoicePermissionError.timedOut) { try await test.value }
    #expect(page.cancellations == page.tests)
    page.reply(.success(true))
    #expect(page.cancellations == page.tests)
}

@Test @MainActor func voicePermissionCoordinatorRetirementChangesDocumentAndCancelsVerification() {
    var cancellations = 0
    let coordinator = PersonaStackWebView.Coordinator(
        appURL: URL(string: "https://my.personastack.ai")!, notificationCoordinator: nil,
        configureNotificationCenter: { _ in Issue.record("Unexpected notification setup") },
        scheduleNotification: { _ in Issue.record("Unexpected notification delivery") },
        cancelPermissionVerification: { cancellations += 1 })
    let before = coordinator.documentGeneration
    coordinator.retire()
    #expect(coordinator.isRetired && coordinator.documentGeneration != before)
    #expect(cancellations == 1)
    let retired = coordinator.documentGeneration
    coordinator.retire()
    #expect(coordinator.documentGeneration == retired && cancellations == 1)
}
