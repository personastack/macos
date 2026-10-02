import Foundation
import Testing
@testable import PersonaStack
@testable import PersonaStackCore

@MainActor
struct LocalRunViewModelTests {
    @Test func rejectedFirstMessageAllowsAFreshTurn() throws {
        let socket = LocalRunRecordingTransport()
        let model = LocalRunViewModel(sessionID: "session", workspace: URL(fileURLWithPath: "/tmp"), socket: socket)
        model.receive(LocalRunFrame(type: "ready", sessionID: "session"))
        model.draft = "First message"
        model.send()
        let first = try #require(socket.frames.last)
        model.receive(LocalRunFrame(type: "error", sessionID: "session", requestID: first.request_id,
                                    turnID: first.turn_id, text: "Rejected message"))
        #expect(model.ready && !model.busy && model.status == "Ready")
        #expect(model.failure == "Rejected message")
        model.draft = "Try again"
        model.send()
        let retry = try #require(socket.frames.last)
        #expect(retry.type == "send")
        #expect(retry.turn_id != first.turn_id)
        #expect(retry.request_id != first.request_id)
    }

    @Test func failedTurnKeepsTheSessionReadyForAnotherMessage() throws {
        let socket = LocalRunRecordingTransport()
        let model = LocalRunViewModel(sessionID: "session", workspace: URL(fileURLWithPath: "/tmp"), socket: socket)
        model.receive(LocalRunFrame(type: "ready", sessionID: "session"))
        model.draft = "Start"
        model.send()
        let turn = try #require(socket.frames.last?.turn_id)
        var question = try JSONDecoder().decode(LocalRunFrame.self, from: Data(#"{"version":1,"type":"input_requested","session_id":"session","request_id":"question","control":{"kind":"question","prompt":"Choose","allow_text":true}}"#.utf8))
        question.turn_id = turn
        model.receive(question)
        model.receive(LocalRunFrame(type: "error", sessionID: "session", turnID: turn, text: "Provider failed"))
        #expect(model.ready && !model.busy && model.status == "Ready")
        #expect(model.items.last?.closed == true)
        model.draft = "Next message"
        model.send()
        #expect(socket.frames.count == 2)
        #expect(socket.frames.last?.type == "send")
        #expect(socket.frames.last?.turn_id != turn)
        model.receive(LocalRunFrame(type: "error", sessionID: "session", text: "Session closed"))
        #expect(!model.ready && !model.busy && model.status == "Agent unavailable")
    }

    @Test func rejectedFollowUpAndInterruptPreserveTheActiveTurn() throws {
        let socket = LocalRunRecordingTransport()
        let model = LocalRunViewModel(sessionID: "session", workspace: URL(fileURLWithPath: "/tmp"), socket: socket)
        model.receive(LocalRunFrame(type: "ready", sessionID: "session"))
        model.draft = "Start"
        model.send()
        let turn = try #require(socket.frames.last?.turn_id)
        model.draft = "Follow up"
        model.send()
        let followUp = try #require(socket.frames.last)
        #expect(followUp.type == "steer" && followUp.turn_id == turn)
        model.receive(LocalRunFrame(type: "error", sessionID: "session", requestID: followUp.request_id,
                                    turnID: turn, text: "Follow up rejected"))
        #expect(model.ready && model.busy && model.status == "Working…")
        model.interrupt()
        let interrupt = try #require(socket.frames.last)
        #expect(interrupt.type == "interrupt")
        model.receive(LocalRunFrame(type: "error", sessionID: "session", requestID: interrupt.request_id,
                                    turnID: turn, text: "Interrupt rejected"))
        #expect(model.ready && model.busy && model.status == "Working…")
        model.receive(LocalRunFrame(type: "turn_completed", sessionID: "session", turnID: turn))
        model.draft = "New turn"
        model.send()
        #expect(socket.frames.last?.type == "send")
        #expect(socket.frames.last?.turn_id != turn)
    }

    @Test func oldTurnErrorsAndCompletionDoNotClearANewerTurn() throws {
        let socket = LocalRunRecordingTransport()
        let model = LocalRunViewModel(sessionID: "session", workspace: URL(fileURLWithPath: "/tmp"), socket: socket)
        model.receive(LocalRunFrame(type: "ready", sessionID: "session"))
        model.draft = "First"
        model.send()
        let first = try #require(socket.frames.last)
        model.receive(LocalRunFrame(type: "turn_completed", sessionID: "session", turnID: first.turn_id))
        model.draft = "Second"
        model.send()
        let second = try #require(socket.frames.last)
        model.receive(LocalRunFrame(type: "error", sessionID: "session", requestID: first.request_id,
                                    turnID: first.turn_id, text: "Old rejection"))
        model.receive(LocalRunFrame(type: "error", sessionID: "session", turnID: first.turn_id, text: "Old failure"))
        model.receive(LocalRunFrame(type: "turn_completed", sessionID: "session", turnID: first.turn_id))
        #expect(model.ready && model.busy && model.failure == nil)
        model.draft = "Follow up"
        model.send()
        #expect(socket.frames.last?.type == "steer")
        #expect(socket.frames.last?.turn_id == second.turn_id)
    }

    @Test func localRunTranscriptReplacesSnapshotsWithinTurnAndKeepsLaterTurns() throws {
        let model = LocalRunViewModel(sessionID: "session", workspace: URL(fileURLWithPath: "/tmp"))
        func event(_ turn: String, _ text: String) throws -> LocalRunFrame {
            try JSONDecoder().decode(LocalRunFrame.self, from: JSONSerialization.data(withJSONObject: [
                "version": 1, "type": "text", "session_id": "session", "turn_id": turn, "event_id": "same-item", "text": text
            ]))
        }
        model.receive(try event("one", "partial"))
        model.receive(try event("one", "complete"))
        model.receive(try event("two", "next"))
        #expect(model.items.map(\.text) == ["complete", "next"])
        model.receive(LocalRunFrame(type: "text", sessionID: "foreign", text: "must not appear"))
        #expect(model.items.count == 2)
    }

    @Test func localRunCompletionClosesOldInputCardsWithoutClaimingUserAnswered() throws {
        let model = LocalRunViewModel(sessionID: "session", workspace: URL(fileURLWithPath: "/tmp"))
        let event = try JSONDecoder().decode(LocalRunFrame.self, from: Data(#"{"version":1,"type":"input_requested","session_id":"session","turn_id":"turn","request_id":"question","control":{"kind":"question","prompt":"Choose","options":[],"allow_text":true}}"#.utf8))
        model.receive(event)
        model.receive(LocalRunFrame(type: "turn_interrupted", sessionID: "session", turnID: "turn"))
        #expect(model.items[0].closed)
        #expect(!model.items[0].answered)
        #expect(model.status == "Stopped")
    }

    @Test func localRunLateRedemptionKeepsRevocationFailureVisibleAndRetryable() async throws {
        let bundle = try LocalRunTests().fixture()
        let gate = LocalRunRedemptionGate(bundle: bundle)
        let revocation = LocalRunRevocationFixture()
        let runtime = LocalRunContainer(command: { _ in throw LocalRunError.invalidFrame }, networking: { _, _ in })
        let model = LocalRunViewModel(sessionID: bundle.session_id, workspace: URL(fileURLWithPath: "/tmp"), runtime: runtime,
                                      redeem: { _, _, _, _, _ in await gate.redeem() },
                                      revoke: { origin, bundle in try await revocation.revoke(origin: origin, bundle: bundle) })
        model.start(appURL: URL(string: "https://selected.example")!, personaID: bundle.persona_id, ticket: "opaque", verifier: "private")
        await gate.waitForRequest()
        let close = Task { await model.close() }
        while !model.closing { await Task.yield() }
        await gate.release()
        #expect(await close.value == false)
        #expect(model.status == "Local agent stopped. Credential revocation unconfirmed.")
        #expect(model.failure == LocalRunError.revocationUnconfirmed.rawValue)
        #expect(!model.ready && !model.closing)
        model.receive(LocalRunFrame(type: "ready", sessionID: bundle.session_id))
        #expect(!model.ready)
        #expect(await revocation.attempts == 1)
        #expect(await model.close())
        #expect(await revocation.attempts == 2)
        #expect(model.status == "Closed" && model.failure == nil)
    }

    @Test func localRunCloseFencesSubsequentReadyEvents() async {
        let model = LocalRunViewModel(sessionID: "session", workspace: URL(fileURLWithPath: "/tmp"))
        #expect(await model.close())
        model.receive(LocalRunFrame(type: "ready", sessionID: "session"))
        #expect(!model.ready)
        #expect(model.closing)
    }
}

private final class LocalRunRecordingTransport: LocalRunTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [LocalRunFrame] = []
    var frames: [LocalRunFrame] { lock.withLock { sent } }
    func connect(path: String, sessionID: String, secret: String) async throws -> AsyncThrowingStream<LocalRunFrame, Error> {
        throw LocalRunError.connectionFailed
    }
    func send(_ frame: LocalRunFrame) throws { lock.withLock { sent.append(frame) } }
    func close() {}
}

private actor LocalRunRedemptionGate {
    let bundle: LocalRunBundle
    var continuation: CheckedContinuation<LocalRunBundle, Never>?
    var observer: CheckedContinuation<Void, Never>?
    init(bundle: LocalRunBundle) { self.bundle = bundle }
    func redeem() async -> LocalRunBundle {
        await withCheckedContinuation {
            continuation = $0; observer?.resume(); observer = nil
        }
    }
    func waitForRequest() async {
        if continuation != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { continuation?.resume(returning: bundle); continuation = nil }
}

private actor LocalRunRevocationFixture {
    var attempts = 0
    func revoke(origin: URL, bundle: LocalRunBundle) throws {
        #expect(origin.absoluteString == "https://selected.example")
        #expect(bundle.bearer_token == String(repeating: "b", count: 64))
        attempts += 1
        if attempts == 1 { throw LocalRunError.revocationUnconfirmed }
    }
}
