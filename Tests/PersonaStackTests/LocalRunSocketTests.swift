import Darwin
import Foundation
import Testing
@testable import PersonaStackCore

struct LocalRunSocketTests {
    @Test func aStalledPeerCannotAccumulateAnUnboundedWriteQueue() async throws {
        let fixture = try LocalSocketFixture()
        let client = LocalRunSocket()
        defer { client.close() }
        let events = try await client.connect(path: fixture.path, sessionID: "session", secret: "fixture-secret")
        let peer = try fixture.acceptPeer()
        defer { Darwin.close(peer) }
        let frame = LocalRunFrame(type: "send", sessionID: "session", text: String(repeating: "x", count: 512 * 1024))
        #expect(throws: LocalRunError.connectionFailed) {
            for _ in 0..<65 { try client.send(frame) }
        }
        var iterator = events.makeAsyncIterator()
        await #expect(throws: LocalRunError.connectionFailed) { _ = try await iterator.next() }
    }

    @Test func queuedWritesKeepFrameOrderAndIncomingMessagesFlowDuringBackpressure() async throws {
        let fixture = try LocalSocketFixture()
        let client = LocalRunSocket()
        defer { client.close() }
        let events = try await client.connect(path: fixture.path, sessionID: "session", secret: "fixture-secret")
        let peer = try fixture.acceptPeer()
        defer { Darwin.close(peer) }
        let frames = (0..<16).map {
            LocalRunFrame(type: $0 == 0 ? "send" : "steer", sessionID: "session", requestID: "request-\($0)",
                          text: String(repeating: "x", count: 32 * 1024))
        }
        for frame in frames { try client.send(frame) }
        let ready = try LocalRunFrame(type: "ready", sessionID: "session").encoded()
        let written = ready.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
        #expect(written == ready.count)
        // Bound the regression: a stalled reader must not hang the test process.
        let timeout = Task.detached {
            do { try await Task.sleep(for: .seconds(2)); client.close() } catch {}
        }
        defer { timeout.cancel() }
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next()?.type == "ready")
        var decoder = LocalRunFrameDecoder(sessionID: "session")
        var received: [LocalRunFrame] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        while received.count < frames.count + 1 {
            let count = Darwin.read(peer, &buffer, buffer.count)
            guard count > 0 else { throw LocalRunError.connectionFailed }
            received += try decoder.append(Data(buffer.prefix(count)))
        }
        #expect(received.first?.type == "hello")
        #expect(received.first?.secret == "fixture-secret")
        #expect(received.dropFirst().map(\.request_id) == frames.map(\.request_id))
        #expect(received.dropFirst().allSatisfy { $0.text?.utf8.count == 32 * 1024 })
    }

    @Test func peerFailureFinishesTheEventStreamAndRejectsFurtherWrites() async throws {
        let fixture = try LocalSocketFixture()
        let client = LocalRunSocket()
        defer { client.close() }
        let events = try await client.connect(path: fixture.path, sessionID: "session", secret: "fixture-secret")
        let peer = try fixture.acceptPeer()
        Darwin.close(peer)
        var iterator = events.makeAsyncIterator()
        await #expect(throws: LocalRunError.connectionFailed) { _ = try await iterator.next() }
        #expect(throws: LocalRunError.connectionFailed) {
            try client.send(LocalRunFrame(type: "send", sessionID: "session", text: "after failure"))
        }
    }

    @Test func closeInterruptsABlockedWriterWithoutWaitingForTheSendTimeout() async throws {
        let fixture = try LocalSocketFixture()
        let client = LocalRunSocket()
        defer { client.close() }
        let events = try await client.connect(path: fixture.path, sessionID: "session", secret: "fixture-secret")
        let peer = try fixture.acceptPeer()
        defer { Darwin.close(peer) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        #expect(Darwin.read(peer, &buffer, buffer.count) > 0) // Initial hello fits the socket buffer.
        let sendStarted = ContinuousClock.now
        try client.send(LocalRunFrame(type: "send", sessionID: "session", text: String(repeating: "x", count: 512 * 1024)))
        #expect(sendStarted.duration(to: .now) < .seconds(1))
        var readable = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
        #expect(Darwin.poll(&readable, 1, 2000) == 1)
        let started = ContinuousClock.now
        client.close()
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(throws: LocalRunError.connectionFailed) {
            try client.send(LocalRunFrame(type: "send", sessionID: "session", text: "after close"))
        }
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == nil)
    }
}

private final class LocalSocketFixture {
    let path = "/tmp/ps-local-socket-\(UUID().uuidString).sock"
    private var descriptor: Int32

    init() throws {
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LocalRunError.connectionFailed }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            descriptor = -1
            _ = Darwin.unlink(path)
            throw LocalRunError.connectionFailed
        }
    }

    func acceptPeer() throws -> Int32 {
        var readable = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&readable, 1, 2000) == 1 else { throw LocalRunError.connectionFailed }
        let peer = Darwin.accept(descriptor, nil, nil)
        guard peer >= 0 else { throw LocalRunError.connectionFailed }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return peer
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
        _ = Darwin.unlink(path)
    }
}
