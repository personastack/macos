import Foundation

/// Strict native boundary for the API-owned CLI operations. Command content is shell code.
public struct DesktopCLIArguments: Sendable {
    public let operation: String
    public let command: String?
    public let workingDirectory: String
    public let timeout: TimeInterval
    public let mode: DesktopTerminalMode
    public let executionID: UUID?
    public let cursor: UInt64
    public let waitMilliseconds: Int
    public let inputs: [DesktopProcessInput]
    private let rows: UInt16
    private let columns: UInt16

    public init(operation: String, arguments: DesktopControlJSONValue?) throws {
        guard case .object(let values)? = arguments else { throw DesktopShellError.invalidInput }
        let keys: Set<String>
        switch operation {
        case "desktop_control_execute":
            keys = ["control_token", "command", "working_directory", "timeout_seconds", "terminal_mode", "terminal_rows", "terminal_columns"]
        case "desktop_control_exec_read": keys = ["control_token", "execution_id", "cursor", "wait_ms"]
        case "desktop_control_exec_write":
            keys = ["control_token", "execution_id", "data_base64", "close_stdin", "interrupt", "terminal_rows", "terminal_columns"]
        case "desktop_control_exec_status", "desktop_control_exec_cancel": keys = ["control_token", "execution_id"]
        default: throw DesktopShellError.invalidInput
        }
        guard Set(values.keys).isSubset(of: keys) else { throw DesktopShellError.invalidInput }
        self.operation = operation
        command = try Self.string(values, "command")
        workingDirectory = try Self.directory(values, operation: operation)
        timeout = try Self.timeout(values)
        mode = try Self.mode(values)
        let rawID = try Self.string(values, "execution_id")
        executionID = rawID.flatMap(UUID.init(uuidString:))
        cursor = try Self.integer(values, "cursor", default: 0, maximum: 9_007_199_254_740_991)
        waitMilliseconds = Int(try Self.integer(values, "wait_ms", default: 0, maximum: 10_000))
        let rows = try Self.integer(values, "terminal_rows", default: 0, maximum: 1000)
        let columns = try Self.integer(values, "terminal_columns", default: 0, maximum: 1000)
        let dimensions = values["terminal_rows"] != nil || values["terminal_columns"] != nil
        guard !dimensions || (rows > 0 && columns > 0) else { throw DesktopShellError.invalidInput }
        inputs = try Self.inputs(values, dimensions: dimensions && operation == "desktop_control_exec_write",
                                 rows: UInt16(rows), columns: UInt16(columns))
        self.rows = dimensions ? UInt16(rows) : 24
        self.columns = dimensions ? UInt16(columns) : 80
        if operation == "desktop_control_execute" {
            guard let command, !command.isEmpty, !command.contains("\0"),
                  command.utf8.count <= DesktopShellExecutor.maximumCommandBytes, timeout >= 1,
                  !dimensions || mode == .pty else { throw DesktopShellError.invalidInput }
        } else {
            guard executionID != nil else { throw DesktopShellError.invalidInput }
        }
        if operation == "desktop_control_exec_write", inputs.isEmpty { throw DesktopShellError.invalidInput }
    }

    public var terminalSize: (UInt16, UInt16) { (rows, columns) }

    private static func directory(_ values: [String: DesktopControlJSONValue], operation: String) throws -> String {
        let directory = try Self.string(values, "working_directory")
        guard operation == "desktop_control_execute" else { return directory ?? "" }
        guard let directory, directory.hasPrefix("/"), !directory.contains("\0"), directory.utf8.count <= 4096 else {
            throw DesktopShellError.invalidWorkingDirectory
        }
        return directory
    }

    private static func timeout(_ values: [String: DesktopControlJSONValue]) throws -> TimeInterval {
        guard let value = values["timeout_seconds"] else { return 300 }
        guard case .number(let number) = value, number.isFinite, number >= 1, number <= 1800 else { throw DesktopShellError.invalidInput }
        return number
    }

    private static func mode(_ values: [String: DesktopControlJSONValue]) throws -> DesktopTerminalMode {
        guard let text = try Self.string(values, "terminal_mode") else { return .pipe }
        guard let mode = DesktopTerminalMode(rawValue: text) else { throw DesktopShellError.invalidInput }
        return mode
    }

    private static func inputs(_ values: [String: DesktopControlJSONValue], dimensions: Bool,
                               rows: UInt16, columns: UInt16) throws -> [DesktopProcessInput] {
        let encoded = try Self.string(values, "data_base64")
        let close = try Self.flag(values, "close_stdin")
        let interrupt = try Self.flag(values, "interrupt")
        guard !interrupt || (encoded == nil && !close && !dimensions) else { throw DesktopShellError.invalidInput }
        var actions: [DesktopProcessInput] = []
        if dimensions { actions.append(.resize(rows: rows, columns: columns)) }
        if let encoded {
            guard let bytes = Data(base64Encoded: encoded), !bytes.isEmpty,
                  bytes.count <= DesktopShellExecutor.maximumInputBytes else { throw DesktopShellError.invalidInput }
            actions.append(.data(bytes))
        }
        if close { actions.append(.close) }
        if interrupt { actions.append(.interrupt) }
        return actions
    }

    private static func string(_ values: [String: DesktopControlJSONValue], _ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard case .string(let text) = value else { throw DesktopShellError.invalidInput }
        return text
    }

    private static func flag(_ values: [String: DesktopControlJSONValue], _ key: String) throws -> Bool {
        guard let value = values[key] else { return false }
        guard case .bool(let flag) = value else { throw DesktopShellError.invalidInput }
        return flag
    }

    private static func integer(_ values: [String: DesktopControlJSONValue], _ key: String,
                                default fallback: UInt64, maximum: UInt64) throws -> UInt64 {
        guard let value = values[key] else { return fallback }
        guard case .number(let number) = value, number.isFinite, number >= 0,
              number.rounded(.towardZero) == number, number <= Double(maximum) else {
            throw DesktopShellError.invalidInput
        }
        return UInt64(number)
    }
}

public extension DesktopProcessRead {
    var resultObject: [String: Any] {
        var result: [String: Any] = [
            "execution_id": executionID.uuidString.lowercased(),
            "chunks": chunks.map { ["sequence": $0.sequence, "stream": $0.stream.rawValue, "data_base64": $0.data.base64EncodedString()] as [String: Any] },
            "next_cursor": nextCursor, "earliest_cursor": earliestCursor, "output_gap": outputGap,
            "state": state.rawValue, "terminal_mode": terminalMode.rawValue,
            "merged_output": terminalMode == .pty, "output_complete": outputComplete
        ]
        if let exitCode { result["exit_code"] = exitCode }
        if let signal { result["signal"] = signal }
        return result
    }
}
