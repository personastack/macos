import Foundation
import Testing
@testable import PersonaStackCore

private actor TrajectoryDispatchFixture {
    var calls: [(String, DesktopControlJSONValue)] = []
    var delays: [Int] = []
    func call(_ name: String, _ arguments: DesktopControlJSONValue, isError: Bool = false) -> DesktopControlJSONValue {
        calls.append((name, arguments))
        return .object(["isError": .bool(isError), "content": .array([.object(["type": .string("text"), "text": .string("result")])])])
    }
    func delay(_ milliseconds: Int) { delays.append(milliseconds) }
    func names() -> [String] { calls.map(\.0) }
}

@Suite
struct DesktopCuaTrajectoryReplayTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trajectory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func write(_ root: URL, turn: String = "turn-00001", tool: String = "press_key",
                       arguments: DesktopControlJSONValue = .object(["key": .string("enter")])) throws {
        let directory = root.appendingPathComponent(turn)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let data = try JSONEncoder().encode(DesktopControlJSONValue.object([
            "tool": .string(tool), "arguments": arguments,
            "timestamp": .string("2026-10-04T00:00:00Z"), "result_summary": .string("prior result"),
        ]))
        try data.write(to: directory.appendingPathComponent("action.json"))
    }

    @Test func boundedSnapshotDispatchesSortedActionsAndStripsOnlyTransportIdentity() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, turn: "turn-00002", tool: "type_text", arguments: .object(["text": .string("fixture")]))
        try write(root, arguments: .object(["key": .string("enter"), "session": .string("old"), "_session_id": .string("old")]))
        let replay = try await DesktopFileSystem().loadCuaTrajectory(path: root.path)
        #expect(replay.count == 2)
        let fixture = TrajectoryDispatchFixture()
        let result = try await replay.run(delayMilliseconds: 7, sleep: { await fixture.delay($0) }) {
            await fixture.call($0, $1)
        }
        #expect(await fixture.names() == ["press_key", "type_text"])
        #expect(await fixture.calls.first?.1 == .object(["key": .string("enter")]))
        #expect(await fixture.delays == [7])
        guard case .object(let summary) = result else { Issue.record("Missing summary"); return }
        #expect(summary["attempted"] == .number(2) && summary["succeeded"] == .number(2) && summary["failed"] == .number(0))
    }

    @Test(arguments: [true, false])
    func returnedToolFailureRespectsStopPolicy(stop: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root)
        try write(root, turn: "turn-00002")
        let replay = try await DesktopFileSystem().loadCuaTrajectory(path: root.path)
        let fixture = TrajectoryDispatchFixture()
        let result = try await replay.run(delayMilliseconds: 0, stopOnError: stop) {
            await fixture.call($0, $1, isError: true)
        }
        #expect(await fixture.names().count == (stop ? 1 : 2))
        guard case .object(let fields) = result else { Issue.record("Missing summary"); return }
        #expect(fields["failed"] == .number(stop ? 1 : 2))
        #expect(fields["first_failure"] != nil)
    }

    @Test func cancelledPacingAndThrownAdmissionAlwaysStopBeforeTheNextAction() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root)
        try write(root, turn: "turn-00002")
        let replay = try await DesktopFileSystem().loadCuaTrajectory(path: root.path)
        let fixture = TrajectoryDispatchFixture()
        await #expect(throws: CancellationError.self) {
            try await replay.run(stopOnError: false, sleep: { _ in throw CancellationError() }) {
                await fixture.call($0, $1)
            }
        }
        #expect(await fixture.names().count == 1)
        await #expect(throws: DesktopControlExecution.Expired.self) {
            try await replay.run(delayMilliseconds: 0, stopOnError: false) { _, _ in throw DesktopControlExecution.Expired() }
        }
    }

    @Test func invalidLaterActionPreventsAnyReplayAndStaleTargetIsNeverStripped() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root)
        try write(root, turn: "turn-00002", tool: "replay_trajectory", arguments: .object(["dir": .string(root.path)]))
        await #expect(throws: DesktopCuaTrajectoryReplay.Failure.unsupportedAction) {
            try await DesktopFileSystem().loadCuaTrajectory(path: root.path)
        }
        for key in ["element_index", "element_token", "snapshot_id", "capture_id", "ref", "snapshot", "from_zoom"] {
            let data = try JSONEncoder().encode(DesktopControlJSONValue.object([
                "tool": .string("click"), "arguments": .object([key: .bool(true), "x": .number(2), "y": .number(3)]),
            ]))
            #expect(throws: DesktopCuaTrajectoryReplay.Failure.staleTarget) {
                try DesktopCuaTrajectoryReplay.action(data: data, name: "turn-00001")
            }
        }
        for tool in ["set_config", "start_session", "browser_prepare", "kill_app", "page"] {
            let data = try JSONEncoder().encode(DesktopControlJSONValue.object(["tool": .string(tool), "arguments": .object([:])]))
            #expect(throws: DesktopCuaTrajectoryReplay.Failure.unsupportedAction) {
                try DesktopCuaTrajectoryReplay.action(data: data, name: "turn-00001")
            }
        }
    }

    @Test func finiteArgumentSchemaRejectsUnknownReservedAndMissingFields() throws {
        for fields: [String: DesktopControlJSONValue] in [["key": .string("enter"), "_unexpected": .bool(true)],
                                                         ["key": .string("enter"), "unknown": .bool(true)], [:]] {
            let data = try JSONEncoder().encode(DesktopControlJSONValue.object(["tool": .string("press_key"), "arguments": .object(fields)]))
            #expect(throws: CuaToolCatalog.ValidationError.invalidArguments) {
                try DesktopCuaTrajectoryReplay.action(data: data, name: "turn-00001")
            }
        }
    }

    @Test(arguments: ["root", "turn", "action"])
    func symlinkBoundariesAreRejected(component: String) async throws {
        let root = try directory(), outside = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try write(outside)
        let manager = FileManager.default
        var path = root.path
        switch component {
        case "root":
            let link = root.appendingPathComponent("linked")
            try manager.createSymbolicLink(at: link, withDestinationURL: outside)
            path = link.path + "/"
        case "turn":
            try manager.createSymbolicLink(at: root.appendingPathComponent("turn-00001"),
                                          withDestinationURL: outside.appendingPathComponent("turn-00001"))
        default:
            let turn = root.appendingPathComponent("turn-00001")
            try manager.createDirectory(at: turn, withIntermediateDirectories: false)
            try manager.createSymbolicLink(at: turn.appendingPathComponent("action.json"),
                                          withDestinationURL: outside.appendingPathComponent("turn-00001/action.json"))
        }
        await #expect(throws: DesktopFileSystemError.invalidPath) { try await DesktopFileSystem().loadCuaTrajectory(path: path) }
    }

    @Test func trajectoryTurnAndByteLimitsRejectBeforeDispatch() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...1_001 {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(String(format: "turn-%05d", index)), withIntermediateDirectories: false)
        }
        await #expect(throws: DesktopFileSystemError.contentTooLarge) { try await DesktopFileSystem().loadCuaTrajectory(path: root.path) }
        let large = try directory()
        defer { try? FileManager.default.removeItem(at: large) }
        try write(large)
        try Data(repeating: 32, count: DesktopCuaTrajectoryReplay.maximumBytes + 1).write(to: large.appendingPathComponent("turn-00001/action.json"))
        await #expect(throws: DesktopFileSystemError.contentTooLarge) { try await DesktopFileSystem().loadCuaTrajectory(path: large.path) }
    }
}
