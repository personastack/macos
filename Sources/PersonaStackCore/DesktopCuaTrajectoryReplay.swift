import Darwin
import Foundation

/// A bounded recording snapshot. The dispatcher remains the authority for
/// every replayed effect and must recheck the current lease before dispatch.
public struct DesktopCuaTrajectoryReplay: Sendable {
    public enum Failure: Error, Equatable {
        case invalidTrajectory, unsupportedAction, staleTarget, invalidDelay
    }
    struct Turn: Sendable {
        let name: String
        let tool: String
        let arguments: DesktopControlJSONValue
    }
    public static let maximumTurns = 1_000
    public static let maximumBytes = 8 * 1024 * 1024
    private let directory: String
    private let turns: [Turn]
    public var count: Int { turns.count }

    // Recorded GUI actions only. Session, configuration, browser preparation,
    // process administration and recording tools cannot be nested in replay.
    private static let actionTools: Set<String> = [
        "click", "double_click", "right_click", "scroll", "type_text", "press_key",
        "hotkey", "set_value", "drag", "move_cursor", "zoom",
        "bring_to_front", "invoke_menu", "set_window_frame",
    ]
    private static let staleFields: Set<String> = [
        "element_index", "element_token", "snapshot_id", "capture_id", "ref", "element_ref", "snapshot",
    ]

    public func run(delayMilliseconds: Int = 500, stopOnError: Bool = true,
                    sleep: @Sendable (Int) async throws -> Void = { milliseconds in
                        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                    },
                    dispatch: @Sendable (String, DesktopControlJSONValue) async throws -> DesktopControlJSONValue)
        async throws -> DesktopControlJSONValue {
        guard (0...10_000).contains(delayMilliseconds) else { throw Failure.invalidDelay }
        var succeeded = 0
        var failed = 0
        var results: [DesktopControlJSONValue] = []
        var firstFailure: DesktopControlJSONValue?
        for turn in turns {
            try DesktopControlExecution.check()
            if !results.isEmpty, delayMilliseconds > 0 {
                try await sleep(delayMilliseconds)
                try DesktopControlExecution.check()
            }
            // A thrown admission/transport/cancellation failure always aborts.
            // stopOnError applies only to an explicit returned tool failure.
            let result = try await dispatch(turn.tool, turn.arguments)
            try DesktopControlExecution.check()
            let (isError, summary) = Self.outcome(result)
            let record: DesktopControlJSONValue = .object([
                "turn": .string(turn.name), "tool": .string(turn.tool),
                "ok": .bool(!isError), "result_summary": .string(summary),
            ])
            results.append(record)
            if isError {
                failed += 1
                if firstFailure == nil {
                    firstFailure = .object(["turn": .string(turn.name), "tool": .string(turn.tool), "error": .string(summary)])
                }
                if stopOnError { break }
            } else { succeeded += 1 }
        }
        var summary: [String: DesktopControlJSONValue] = [
            "directory": .string(directory), "attempted": .number(Double(results.count)),
            "succeeded": .number(Double(succeeded)), "failed": .number(Double(failed)),
            "stop_on_error": .bool(stopOnError), "turns": .array(results),
        ]
        summary["first_failure"] = firstFailure
        return .object(summary)
    }

    private static func outcome(_ result: DesktopControlJSONValue) -> (Bool, String) {
        guard case .object(let fields) = result else { return (false, "") }
        let isError = fields["isError"] == .bool(true)
        guard case .array(let content)? = fields["content"] else { return (isError, "") }
        for case .object(let entry) in content {
            if entry["type"] == .string("text"), case .string(let text)? = entry["text"] {
                return (isError, String(text.prefix(1_024)))
            }
        }
        return (isError, "")
    }

    static func action(data: Data, name: String) throws -> Turn {
        guard case .object(let action) = try JSONDecoder().decode(DesktopControlJSONValue.self, from: data),
              case .string(let tool)? = action["tool"], actionTools.contains(tool),
              case .object(var arguments)? = action["arguments"] else { throw Failure.unsupportedAction }
        // The public session label may be persisted. `_session_id` is the one
        // documented injected transport identity. Never copy either into replay.
        arguments.removeValue(forKey: "session")
        arguments.removeValue(forKey: "_session_id")
        guard !hasStaleTarget(.object(arguments)) else { throw Failure.staleTarget }
        try CuaToolCatalog.validate(tool: tool, arguments: .object(arguments))
        return Turn(name: name, tool: tool, arguments: .object(arguments))
    }

    private static func hasStaleTarget(_ value: DesktopControlJSONValue) -> Bool {
        switch value {
        case .object(let fields):
            return fields.contains { key, value in
                staleFields.contains(key) || (key == "from_zoom" && value == .bool(true)) || hasStaleTarget(value)
            }
        case .array(let values): return values.contains(where: hasStaleTarget)
        default: return false
        }
    }

    fileprivate static func load(path: String) throws -> Self {
        try DesktopControlExecution.check()
        let expanded = path.hasPrefix("~/")
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2))).path : path
        guard expanded.hasPrefix("/"), !expanded.contains("\0"), expanded.utf8.count <= 4_096 else {
            throw DesktopFileSystemError.invalidPath
        }
        let normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let root = try openDirectory(path: normalized)
        defer { Darwin.close(root) }
        let names = try turnNames(root)
        guard !names.isEmpty else { throw Failure.invalidTrajectory }
        var turns: [Turn] = []
        var remaining = maximumBytes
        for name in names.sorted() {
            try DesktopControlExecution.check()
            let turn = try openDirectory(path: name, relativeTo: root)
            defer { Darwin.close(turn) }
            let data = try readAction(directory: turn, remaining: remaining)
            remaining -= data.count
            turns.append(try action(data: data, name: name))
        }
        return Self(directory: normalized, turns: turns)
    }

    private static func openDirectory(path: String, relativeTo parent: Int32 = AT_FDCWD) throws -> Int32 {
        let descriptor = openat(parent, path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw fileError() }
        return descriptor
    }

    private static func turnNames(_ root: Int32) throws -> [String] {
        let copy = dup(root)
        guard copy >= 0 else { throw fileError() }
        guard let directory = fdopendir(copy) else { Darwin.close(copy); throw fileError() }
        defer { closedir(directory) }
        var names: [String] = []
        var scanned = 0
        while true {
            try DesktopControlExecution.check()
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw fileError() }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            scanned += 1
            guard scanned <= DesktopFileSystem.maxDirectoryScanEntries else { throw DesktopFileSystemError.contentTooLarge }
            guard name.hasPrefix("turn-") else { continue }
            guard name.range(of: "^turn-[0-9]{5,20}$", options: .regularExpression) != nil else { throw Failure.invalidTrajectory }
            names.append(name)
            guard names.count <= maximumTurns else { throw DesktopFileSystemError.contentTooLarge }
        }
        return names
    }

    private static func readAction(directory: Int32, remaining: Int) throws -> Data {
        let descriptor = openat(directory, "action.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw fileError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw DesktopFileSystemError.notRegularFile
        }
        guard info.st_size >= 0, info.st_size <= remaining else { throw DesktopFileSystemError.contentTooLarge }
        var data = Data()
        while data.count <= remaining {
            try DesktopControlExecution.check()
            let chunk = try handle.read(upToCount: min(64 * 1024, remaining - data.count + 1)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= remaining else { throw DesktopFileSystemError.contentTooLarge }
        return data
    }

    private static func fileError() -> DesktopFileSystemError {
        errno == EPERM || errno == EACCES ? .permissionDenied : .invalidPath
    }
}

extension DesktopFileSystem {
    /// Opens the selected root and reads only anchored regular action files.
    /// All actions validate before the first possible replay side effect.
    public func loadCuaTrajectory(path: String) throws -> DesktopCuaTrajectoryReplay {
        try DesktopCuaTrajectoryReplay.load(path: path)
    }
}
