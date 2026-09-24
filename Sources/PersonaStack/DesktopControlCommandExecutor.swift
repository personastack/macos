import Foundation
import PersonaStackCore

@MainActor
final class DesktopControlCommandExecutor {
    private struct Owner: Equatable {
        let installationID: String
        let workspaceID: String
        let configID: String
        let personaID: String
        let runID: String
        let generation: Int64
    }

    private struct ConfigScope: Hashable {
        let installationID: String
        let workspaceID: String
        let configID: String
    }

    private struct Lease {
        let owner: Owner
        let configVersion: Int64
        let token: String
        let started: ContinuousClock.Instant
        var lastActivity: ContinuousClock.Instant
    }

    private let files = DesktopFileSystem()
    private let shell = DesktopShellExecutor()
    private var lease: Lease?
    private var revokedConfigVersions: [ConfigScope: Int64] = [:]
    private var closed = false
    private var unavailable = false
    private var revocationInProgress = false
    private var expiryTask: Task<Void, Never>?

    init() {
        expiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await self.expireLeaseIfNeeded()
            }
        }
    }

    func diagnostics() async -> DesktopControlDiagnostics {
        let shellState = await shell.diagnostics()
        let handleCount = await files.openHandleCount()
        return DesktopControlDiagnostics(activeProcesses: shellState.activeProcesses,
                                         openFileHandles: handleCount,
                                         bufferedOutputBytes: shellState.bufferedOutputBytes,
                                         outputGapsTotal: shellState.outputGapsTotal)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        expiryTask?.cancel()
        expiryTask = nil
        lease = nil
        await files.closeAll()
        await shell.closeAll()
    }

    func handle(_ frame: DesktopControlFrame, proxy: CuaMCPProxy?) async -> DesktopControlFrame {
        await handle(frame, proxy: proxy, onChunk: nil)
    }

    func handle(_ frame: DesktopControlFrame, proxy: CuaMCPProxy?,
                onChunk: (@Sendable (DesktopControlFrame) async throws -> Void)?) async -> DesktopControlFrame {
        guard let requestID = frame.requestID, let target = frame.target else {
            return Self.failure(frame, "desktop_executor_unavailable", "The desktop control service is paused or recovering.")
        }
        if frame.operation == "desktop_control_revoke_config" {
            guard let version = target.configVersion, version > 0,
                  !target.installationID.isEmpty, !target.workspaceID.isEmpty, !target.configID.isEmpty,
                  target.personaID.isEmpty, target.runID.isEmpty, target.generation == 0 else {
                return Self.failure(frame, "invalid_arguments", "The Desktop Control revocation scope is invalid.")
            }
            return await revokeConfig(frame, scope: Self.scope(target), version: version)
        }
        guard !revocationInProgress else {
            return Self.failure(frame, "desktop_control_revocation_in_progress", "Another Desktop Control configuration is being cleaned up. Retry after it finishes.")
        }
        guard !closed, !unavailable else {
            return Self.failure(frame, "desktop_executor_unavailable", "The desktop control service is paused or recovering.")
        }
        let owner = Owner(installationID: target.installationID, workspaceID: target.workspaceID,
                          configID: target.configID, personaID: target.personaID, runID: target.runID,
                          generation: target.generation)
        let scope = Self.scope(target)
        let configVersion = target.configVersion ?? 0
        guard isConfigVersionAuthorized(scope, configVersion) else {
            return Self.failure(frame, "desktop_control_config_revoked", "This Desktop Control configuration is disabled or no longer authorized.")
        }
        do {
            let result: Any
            switch frame.operation {
            case "desktop_control_status":
                result = ["available": true, "busy": validLease() != nil]
            case "desktop_control_acquire":
                result = try await acquire(owner, scope: scope, configVersion: configVersion)
            case "desktop_control_release":
                try await requireLease(owner, arguments: frame.arguments, renew: false)
                await files.closeAll()
                guard await shell.closeAll() else {
                    unavailable = true
                    throw CommandError.executorUnavailable
                }
                lease = nil
                result = ["released": true]
            case "desktop_control_observe", "desktop_control_input", "desktop_control_application",
                 "desktop_control_window", "desktop_control_clipboard", "desktop_control_browser":
                try await requireLease(owner, arguments: frame.arguments)
                result = try await callCua(frame, proxy: proxy)
            case "desktop_control_file":
                try await requireLease(owner, arguments: frame.arguments)
                result = try await fileOperation(frame.arguments)
            case "desktop_control_execute":
                try await requireLease(owner, arguments: frame.arguments)
                result = try await shellStart(frame.arguments)
            case "desktop_control_exec_read":
                try await requireLease(owner, arguments: frame.arguments)
                result = try await shellRead(frame.arguments)
            case "desktop_control_exec_write":
                try await requireLease(owner, arguments: frame.arguments)
                result = try await shellWrite(frame.arguments)
            case "desktop_control_exec_status":
                try await requireLease(owner, arguments: frame.arguments)
                result = try await shellStatus(frame.arguments)
            case "desktop_control_exec_cancel":
                try await requireLease(owner, arguments: frame.arguments)
                result = try await shellCancel(frame.arguments)
            default:
                throw CommandError.invalidArguments
            }
            if let onChunk {
                try await forwardShellChunks(result, requestID: requestID, scope: scope,
                                             configVersion: configVersion, onChunk: onChunk)
            }
            guard isConfigVersionAuthorized(scope, configVersion) else { throw CommandError.configurationRevoked }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
            let value = try JSONDecoder().decode(DesktopControlJSONValue.self, from: data)
            return DesktopControlFrame(type: "result", requestID: requestID, result: value)
        } catch let error as CommandError {
            return Self.failure(frame, error.code, error.localizedDescription)
        } catch let error as DesktopFileSystemError {
            return Self.failure(frame, error.desktopControlCode, error.desktopControlMessage)
        } catch let error as DesktopShellError {
            return Self.failure(frame, error.desktopControlCode, error.desktopControlMessage)
        } catch {
            if frame.operation == "desktop_control_file" {
                let nsError = error as NSError
                if Self.isPermissionDenied(nsError) {
                    return Self.failure(frame, "desktop_file_permission_denied",
                                        "macOS denied this file operation for PersonaStack Desktop. Choose a file or folder your macOS account can access.")
                }
                if Self.mayHavePartialWrite(frame.arguments) {
                    return Self.failure(frame, "desktop_file_write_outcome_unknown",
                                        "The file may have changed before the write stopped. Read it again before retrying.")
                }
                return Self.failure(frame, "desktop_file_operation_failed",
                                    "PersonaStack Desktop could not complete this file operation.")
            }
            return Self.failure(frame, "desktop_command_failed", "The desktop command failed.")
        }
    }

    static func isPermissionDenied(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain {
            return error.code == NSFileReadNoPermissionError || error.code == NSFileWriteNoPermissionError
        }
        return error.domain == NSPOSIXErrorDomain && (error.code == Int(EACCES) || error.code == Int(EPERM))
    }

    static func mayHavePartialWrite(_ arguments: DesktopControlJSONValue?) -> Bool {
        guard let values = Self.object(arguments), values["action"] as? String == "write" else { return false }
        if values["offset"] != nil { return true }
        guard let mode = values["mode"] as? String else { return false }
        return mode == "append" || mode == "create"
    }

    private func forwardShellChunks(_ result: Any, requestID: String, scope: ConfigScope, configVersion: Int64,
                                    onChunk: @Sendable (DesktopControlFrame) async throws -> Void) async throws {
        guard let value = result as? [String: Any],
              value["execution_id"] is String,
              let chunks = value["chunks"] as? [[String: Any]] else { return }
        for (index, chunk) in chunks.enumerated() {
            guard isConfigVersionAuthorized(scope, configVersion) else { throw CommandError.configurationRevoked }
            guard let channel = chunk["stream"] as? String,
                  channel == "stdout" || channel == "stderr",
                  let encoded = chunk["data_base64"] as? String,
                  let data = Data(base64Encoded: encoded), !data.isEmpty else { continue }
            let frame = DesktopControlFrame(type: "result_chunk", requestID: requestID, streamID: requestID,
                                            sequence: UInt64(index + 1), streamChannel: channel, streamData: data)
            try await onChunk(frame)
        }
    }

    private func acquire(_ owner: Owner, scope: ConfigScope, configVersion: Int64) async throws -> [String: Any] {
        if let active = validLease() {
            guard active.owner == owner else { throw CommandError.busy }
            var renewed = active
            renewed.lastActivity = .now
            lease = renewed
            return ["control_token": active.token, "expires_in_seconds": 90]
        }
        if lease != nil, !(await clearExpiredLease()) { throw CommandError.executorUnavailable }
        guard isConfigVersionAuthorized(scope, configVersion) else { throw CommandError.configurationRevoked }
        let token = UUID().uuidString.lowercased()
        let now = ContinuousClock.now
        lease = Lease(owner: owner, configVersion: configVersion, token: token, started: now, lastActivity: now)
        return ["control_token": token, "expires_in_seconds": 90]
    }

    private func revokeConfig(_ frame: DesktopControlFrame, scope: ConfigScope, version: Int64) async -> DesktopControlFrame {
        guard !revocationInProgress else {
            return Self.failure(frame, "desktop_control_revocation_in_progress", "Another Desktop Control configuration is being cleaned up. Retry after it finishes.")
        }
        revocationInProgress = true
        defer { revocationInProgress = false }
        revokedConfigVersions[scope] = max(revokedConfigVersions[scope] ?? 0, version)
        if let lease, Self.scope(lease.owner) == scope, lease.configVersion <= version {
            self.lease = nil
            await files.closeAll()
            guard await shell.closeAll() else {
                unavailable = true
                return Self.failure(frame, "desktop_control_revoke_incomplete", "The Mac could not confirm that every command process stopped.")
            }
        }
        return DesktopControlFrame(type: "result", requestID: frame.requestID,
                                   result: .object(["revoked": .bool(true)]))
    }

    private func isConfigVersionAuthorized(_ scope: ConfigScope, _ version: Int64) -> Bool {
        guard version >= 0 else { return false }
        guard let revokedVersion = revokedConfigVersions[scope] else { return true }
        return version > revokedVersion
    }

    private static func scope(_ target: DesktopControlTarget) -> ConfigScope {
        ConfigScope(installationID: target.installationID, workspaceID: target.workspaceID, configID: target.configID)
    }

    private static func scope(_ owner: Owner) -> ConfigScope {
        ConfigScope(installationID: owner.installationID, workspaceID: owner.workspaceID, configID: owner.configID)
    }

    private func validLease() -> Lease? {
        guard let lease,
              lease.lastActivity.duration(to: .now) < .seconds(90),
              lease.started.duration(to: .now) < .seconds(1800) else { return nil }
        return lease
    }

    private func requireLease(_ owner: Owner, arguments: DesktopControlJSONValue?, renew: Bool = true) async throws {
        guard let lease = validLease(), lease.owner == owner,
              case .object(let values)? = arguments,
              case .string(let token)? = values["control_token"], token == lease.token else {
            if self.lease != nil && validLease() == nil, !(await clearExpiredLease()) { unavailable = true }
            throw CommandError.controlRequired
        }
        if renew { self.lease?.lastActivity = .now }
    }

    private func clearExpiredLease() async -> Bool {
        await files.closeAll()
        guard await shell.closeAll() else {
            unavailable = true
            return false
        }
        lease = nil
        return true
    }

    private func expireLeaseIfNeeded() async {
        guard !closed, lease != nil, validLease() == nil else { return }
        if !(await clearExpiredLease()) { unavailable = true }
    }

    private func callCua(_ frame: DesktopControlFrame, proxy: CuaMCPProxy?) async throws -> Any {
        guard let proxy, case .object(let values)? = frame.arguments,
              case .string(let name)? = values["tool"],
              CuaDriverCompatibility.exposedTools.contains(name),
              let rawArguments = values["arguments"] else { throw CommandError.invalidArguments }
        let allowed = Self.allowedTools(for: frame.operation ?? "")
        guard allowed.contains(name) else { throw CommandError.invalidArguments }
        let encoded = try JSONEncoder().encode(rawArguments)
        let response = try await proxy.callTool(name: name, argumentsJSON: encoded)
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = object["result"] as? [String: Any], object["error"] == nil else {
            throw CommandError.commandFailed
        }
        return result
    }

    private func fileOperation(_ arguments: DesktopControlJSONValue?) async throws -> Any {
        guard let args = Self.object(arguments), let action = args["action"] as? String else { throw CommandError.invalidArguments }
        switch action {
        case "stat":
            guard let path = args["path"] as? String else { throw CommandError.invalidArguments }
            return Self.entry(try await files.metadata(path: path))
        case "list":
            guard let path = args["path"] as? String else { throw CommandError.invalidArguments }
            let page = try await files.list(path: path, offset: args["offset"] as? Int ?? 0, limit: args["limit"] as? Int ?? 100)
            return ["entries": page.entries.map(Self.entry), "next_offset": page.nextOffset as Any? ?? NSNull()]
        case "search":
            guard let root = args["root"] as? String else { throw CommandError.invalidArguments }
            let entries = try await files.search(root: root, nameContains: args["name_contains"] as? String,
                                                 contentContains: args["content_contains"] as? String,
                                                 limit: args["limit"] as? Int ?? 100)
            return ["entries": entries.map(Self.entry)]
        case "open":
            guard let path = args["path"] as? String else { throw CommandError.invalidArguments }
            let opened = try await files.open(path: path)
            return ["handle": opened.id.uuidString, "path": opened.path, "size": opened.size,
                    "content_base64": opened.firstRead.content.base64EncodedString(), "next_offset": opened.firstRead.nextOffset,
                    "end_of_file": opened.firstRead.endOfFile]
        case "read":
            guard let id = Self.uuid(args["handle"]), let offset = Self.uint64(args["offset"]) else { throw CommandError.invalidArguments }
            let read = try await files.read(id: id, offset: offset, length: args["length"] as? Int ?? 256 * 1024)
            return ["path": read.path, "offset": read.offset, "content_base64": read.content.base64EncodedString(),
                    "next_offset": read.nextOffset, "end_of_file": read.endOfFile, "changed_since_open": read.changedSinceOpen]
        case "close":
            guard let id = Self.uuid(args["handle"]) else { throw CommandError.invalidArguments }
            try await files.close(id: id)
            return ["closed": true]
        case "write":
            guard let path = args["path"] as? String, let content = args["content_base64"] as? String,
                  let data = Data(base64Encoded: content), let mode = args["mode"] as? String else { throw CommandError.invalidArguments }
            let writeMode: DesktopFileWriteMode
            switch mode {
            case "create": writeMode = .create
            case "replace": writeMode = .replace
            case "append": writeMode = .append
            default: throw CommandError.invalidArguments
            }
            return Self.entry(try await files.write(path: path, content: data, mode: writeMode, offset: Self.uint64(args["offset"])))
        case "patch":
            guard let path = args["path"] as? String, let expected = args["expected"] as? String,
                  let replacement = args["replacement"] as? String else { throw CommandError.invalidArguments }
            return Self.entry(try await files.patch(path: path, expected: expected, replacement: replacement))
        case "mkdir":
            guard let path = args["path"] as? String else { throw CommandError.invalidArguments }
            try await files.makeDirectory(path: path)
            return ["created": true]
        case "move":
            guard let source = args["source"] as? String, let destination = args["destination"] as? String else { throw CommandError.invalidArguments }
            try await files.move(source: source, destination: destination)
            return ["moved": true]
        case "remove":
            guard let path = args["path"] as? String else { throw CommandError.invalidArguments }
            try await files.remove(path: path)
            return ["removed": true]
        default:
            throw CommandError.invalidArguments
        }
    }

    private func shellStart(_ arguments: DesktopControlJSONValue?) async throws -> Any {
        guard let args = Self.object(arguments), let command = args["command"] as? String,
              let cwd = args["working_directory"] as? String else { throw CommandError.invalidArguments }
        let process = try await shell.start(command: command, workingDirectory: cwd, timeout: args["timeout_seconds"] as? Double ?? 300)
        return Self.process(process)
    }

    private func shellRead(_ arguments: DesktopControlJSONValue?) async throws -> Any {
        guard let args = Self.object(arguments), let id = Self.uuid(args["execution_id"]) else { throw CommandError.invalidArguments }
        let wait = min(max(args["wait_ms"] as? Int ?? 0, 0), 10_000)
        return Self.process(try await shell.read(id: id, after: Self.uint64(args["cursor"]) ?? 0, wait: .milliseconds(wait)))
    }

    private func shellWrite(_ arguments: DesktopControlJSONValue?) async throws -> Any {
        guard let args = Self.object(arguments), let id = Self.uuid(args["execution_id"]) else { throw CommandError.invalidArguments }
        if args["close_stdin"] as? Bool == true { try await shell.write(id: id, input: .close) }
        else if args["interrupt"] as? Bool == true { try await shell.write(id: id, input: .interrupt) }
        else if let encoded = args["data_base64"] as? String, let data = Data(base64Encoded: encoded) {
            try await shell.write(id: id, input: .data(data))
        } else { throw CommandError.invalidArguments }
        return ["accepted": true]
    }

    private func shellStatus(_ arguments: DesktopControlJSONValue?) async throws -> Any {
        guard let args = Self.object(arguments), let id = Self.uuid(args["execution_id"]) else { throw CommandError.invalidArguments }
        return Self.process(try await shell.status(id: id))
    }

    private func shellCancel(_ arguments: DesktopControlJSONValue?) async throws -> Any {
        guard let args = Self.object(arguments), let id = Self.uuid(args["execution_id"]) else { throw CommandError.invalidArguments }
        try await shell.cancel(id: id)
        return ["cancelled": true]
    }

    private static func allowedTools(for operation: String) -> Set<String> {
        switch operation {
        case "desktop_control_observe": return ["get_desktop_state", "get_accessibility_tree", "get_window_state", "get_cursor_position", "get_screen_size", "list_apps", "list_windows", "get_browser_state"]
        case "desktop_control_input": return ["move_cursor", "click", "double_click", "right_click", "drag", "scroll", "type_text", "press_key", "hotkey", "set_value", "zoom"]
        case "desktop_control_application": return ["launch_app", "bring_to_front", "kill_app", "list_apps"]
        case "desktop_control_window": return ["list_windows", "get_window_state", "set_window_frame", "bring_to_front", "invoke_menu"]
        case "desktop_control_clipboard": return ["clipboard_read", "clipboard_write"]
        case "desktop_control_browser": return ["get_browser_state", "browser_navigate", "browser_click", "browser_type", "browser_pointer", "browser_dialog", "browser_download", "browser_set_input_files"]
        default: return []
        }
    }

    private static func object(_ value: DesktopControlJSONValue?) -> [String: Any]? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }
    private static func uint64(_ value: Any?) -> UInt64? { (value as? NSNumber).flatMap { $0.int64Value >= 0 ? $0.uint64Value : nil } }

    private static func entry(_ entry: DesktopFileEntry) -> [String: Any] {
        ["path": entry.path, "name": entry.name, "kind": entry.kind.rawValue, "size": entry.size,
         "modified_at": entry.modifiedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()]
    }

    private static func process(_ process: DesktopProcessRead) -> [String: Any] {
        ["execution_id": process.executionID.uuidString, "chunks": process.chunks.map {
            ["sequence": $0.sequence, "stream": $0.stream.rawValue, "data_base64": $0.data.base64EncodedString()]
        }, "next_cursor": process.nextCursor, "earliest_cursor": process.earliestCursor,
         "output_gap": process.outputGap, "state": process.state.rawValue,
         "exit_code": process.exitCode as Any? ?? NSNull(), "signal": process.signal as Any? ?? NSNull()]
    }

    private static func failure(_ frame: DesktopControlFrame, _ code: String, _ message: String) -> DesktopControlFrame {
        DesktopControlFrame(type: "failure", requestID: frame.requestID, errorCode: code, errorMessage: message)
    }
}

private enum CommandError: Error, LocalizedError {
    case invalidArguments, busy, controlRequired, configurationRevoked, commandFailed, executorUnavailable
    var code: String {
        switch self {
        case .invalidArguments: "invalid_arguments"
        case .busy: "desktop_busy"
        case .controlRequired: "desktop_control_required"
        case .configurationRevoked: "desktop_control_config_revoked"
        case .commandFailed: "desktop_command_failed"
        case .executorUnavailable: "desktop_executor_unavailable"
        }
    }
    var errorDescription: String? {
        switch self {
        case .invalidArguments: "The desktop command arguments are invalid."
        case .busy: "The desktop is controlled by another active persona."
        case .controlRequired: "Acquire desktop control before using this tool."
        case .configurationRevoked: "This Desktop Control configuration is disabled or no longer authorized."
        case .commandFailed: "The desktop command failed."
        case .executorUnavailable: "The previous desktop command is still stopping. Retry after the desktop service recovers."
        }
    }
}

private extension DesktopFileSystemError {
    var desktopControlCode: String {
        switch self {
        case .permissionDenied: "desktop_file_permission_denied"
        case .missingHandle: "desktop_file_handle_expired"
        case .invalidRange: "desktop_file_range_invalid"
        case .tooManyOpenFiles: "desktop_file_handle_limit"
        case .patchMismatch: "desktop_file_changed"
        case .searchIncomplete: "desktop_file_search_incomplete"
        case .invalidPath, .notRegularFile, .notDirectory, .contentTooLarge, .destinationExists:
            "desktop_file_operation_failed"
        }
    }

    var desktopControlMessage: String {
        switch self {
        case .permissionDenied: "macOS denied this file operation for PersonaStack Desktop. Choose a file or folder your macOS account can access."
        case .missingHandle: "This file handle expired. Open the file again before reading it."
        case .invalidRange: "The requested file range is outside the supported limit."
        case .tooManyOpenFiles: "Too many files are open for this desktop control session. Close a file handle and retry."
        case .patchMismatch: "The file changed or the expected text did not match. Read the current file before editing it again."
        case .searchIncomplete: "The file search exceeded its scan limit. Narrow the search to a smaller folder."
        case .invalidPath, .notRegularFile, .notDirectory, .contentTooLarge, .destinationExists:
            "PersonaStack Desktop could not complete this file operation. Check the path, file type, and operation limits."
        }
    }
}

private extension DesktopShellError {
    var desktopControlCode: String {
        switch self {
        case .permissionDenied: "desktop_process_permission_denied"
        case .invalidWorkingDirectory: "desktop_process_working_directory_invalid"
        case .tooManyProcesses: "desktop_process_limit"
        case .missingExecution: "desktop_process_handle_expired"
        case .invalidInput: "desktop_process_input_invalid"
        case .cancellationUnconfirmed: "desktop_process_cancel_unconfirmed"
        case .invalidCommand: "desktop_process_start_failed"
        }
    }

    var desktopControlMessage: String {
        switch self {
        case .permissionDenied:
            "macOS denied access to the command working directory or process. Choose a location or command your macOS account can access."
        case .invalidWorkingDirectory:
            "The command working directory is missing or is not an accessible directory. Choose an existing directory on the target Mac."
        case .tooManyProcesses:
            "The desktop already has the maximum number of managed commands running. Finish or cancel one before starting another."
        case .missingExecution:
            "This command session is no longer available. Start a new command and use its current execution ID."
        case .invalidInput:
            "The command input is invalid or exceeds the supported size. Send a smaller input chunk."
        case .cancellationUnconfirmed:
            "The desktop could not confirm that the command stopped. Check its status before retrying work."
        case .invalidCommand:
            "The desktop could not start the command. Check the working directory and try again."
        }
    }
}
