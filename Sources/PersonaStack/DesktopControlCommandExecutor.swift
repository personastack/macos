import Foundation
import ImageIO
import os
import PersonaStackCore
import UniformTypeIdentifiers

@MainActor
final class DesktopControlCommandExecutor {
    private let logger = Logger(subsystem: "ai.personastack.desktop", category: "desktop-control-cua")
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

    private struct BindingScope: Hashable {
        let config: ConfigScope
        let personaID: String
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
    private let powerAssertion: DesktopControlPowerAssertion
    private var lease: Lease? { didSet { leaseStateChanged?() } }
    /// Native-only lifecycle signal. This never crosses the WebView bridge.
    var leaseStateChanged: (@MainActor () -> Void)?

    struct LeaseSnapshot: Equatable, Sendable {
        let token: UUID
        let installationID: String
        let workspaceID: String
        let configID: String
        let personaID: String
        let runID: String
        let generation: Int64
        let configVersion: Int64
        let expires: ContinuousClock.Instant
        let hardExpires: ContinuousClock.Instant
    }

    var currentLease: LeaseSnapshot? {
        guard !closed, !unavailable, !cleanupInProgress, !revocationInProgress,
              let lease = validLease(), let token = UUID(uuidString: lease.token) else { return nil }
        return LeaseSnapshot(token: token, installationID: lease.owner.installationID,
            workspaceID: lease.owner.workspaceID, configID: lease.owner.configID,
            personaID: lease.owner.personaID, runID: lease.owner.runID,
            generation: lease.owner.generation, configVersion: lease.configVersion,
            expires: min(lease.started + .seconds(1800), lease.lastActivity + .seconds(90)),
            hardExpires: lease.started + .seconds(1800))
    }

    private var leaseOwnerDisplay: DesktopControlOwnerDisplay?
    private var presentedOperations: [UUID: (token: String, kind: DesktopControlActivityKind, started: ContinuousClock.Instant)] = [:]
    private var cleanupLease: Lease?
    private var cleanupInProgress = false
    private var cleanupSucceeded = false
    private var failedCleanupLease: Lease?
    private var failedCleanupWithoutLease = false
    private var cleanupFailureMayRestoreAvailability = false
    private var cleanupWaiters: [CheckedContinuation<Bool, Never>] = []
    private var leaseEpoch: UInt64 = 0
    private var activeOperations = 0
    private var nativeVerificationID: UUID?
    private var nativeVerificationInvalidated = false
    private var invalidateNativeTarget: (@MainActor () -> Void)?
    var nativeVerificationInProgress: Bool { nativeVerificationID != nil }
    private var revokedConfigVersions: [ConfigScope: Int64] = [:]
    private var revokedBindingGenerations: [BindingScope: Int64] = [:]
    private var closed = false
    private var unavailable = false
    private var activeRevocations = 0
    private var revocationInProgress: Bool { activeRevocations > 0 }
    private var expiryTask: Task<Void, Never>?
    private let now: () -> ContinuousClock.Instant
#if DEBUG
    private var activeOperationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cleanupResourceBarrierForTesting: (@Sendable () async -> Void)?
    private var cleanupFailuresForTesting = 0
    private var nativeVerificationBarrierForTesting: (@MainActor () async -> Void)?
    private var leaseGrantBarrierForTesting: (@Sendable () async -> Void)?
#endif

    init(now: @escaping () -> ContinuousClock.Instant = { .now },
         powerAssertion: DesktopControlPowerAssertion = .init()) {
        self.now = now
        self.powerAssertion = powerAssertion
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

    var presentationActivity: DesktopControlActivity? {
        guard !closed, !unavailable, !cleanupInProgress, !revocationInProgress,
              let current = validLease() else { return nil }
        let operation = presentedOperations.values.filter { $0.token == current.token }
            .max { $0.started < $1.started }?.kind
        let elapsed = current.started.duration(to: now()).components.seconds
        return DesktopControlActivity(personaName: leaseOwnerDisplay?.personaName,
                                      workspaceName: leaseOwnerDisplay?.workspaceName,
                                      operation: operation, elapsedSeconds: Int(max(0, elapsed)))
    }

    private func beginPresentation(_ frame: DesktopControlFrame, owner: Owner) -> UUID? {
        guard let current = validLease(), current.owner == owner,
              case .object(let args)? = frame.arguments,
              case .string(let token)? = args["control_token"], token == current.token,
              let kind = DesktopControlActivityKind(operation: frame.operation) else { return nil }
        let id = UUID()
        presentedOperations[id] = (token, kind, now())
        return id
    }

    /// Local permission setup must never interleave its input with remote work.
    func beginNativeVerification(onInvalidation: (@MainActor () -> Void)? = nil) async throws -> UUID {
        guard canBeginNativeVerification else { throw CommandError.executorUnavailable }
        let id = UUID()
        nativeVerificationID = id
        nativeVerificationInvalidated = false
        invalidateNativeTarget = onInvalidation
        activeOperations += 1
        do {
#if DEBUG
            if let barrier = nativeVerificationBarrierForTesting {
                nativeVerificationBarrierForTesting = nil
                await barrier()
            }
#endif
            let state = await diagnostics()
            try requireNativeVerification(id)
            try Task.checkCancellation()
            guard state.activeProcesses == 0, state.openFileHandles == 0 else { throw CommandError.executorUnavailable }
            return id
        } catch {
            endNativeVerification(id)
            throw error
        }
    }

    private var canBeginNativeVerification: Bool {
        nativeVerificationID == nil && lease == nil && activeOperations == 0 && !closed && !unavailable
            && !revocationInProgress && !cleanupInProgress && failedCleanupLease == nil && !failedCleanupWithoutLease
    }

    func requireNativeVerification(_ id: UUID) throws {
        guard nativeVerificationID == id, !nativeVerificationInvalidated, !closed, !unavailable, !revocationInProgress,
              !cleanupInProgress, lease == nil, activeOperations == 1 else { throw CancellationError() }
    }

    func endNativeVerification(_ id: UUID) {
        if nativeVerificationID == id {
            nativeVerificationID = nil
            nativeVerificationInvalidated = false
            invalidateNativeTarget = nil
            activeOperations -= 1
        }
    }

    private func invalidateNativeVerification() {
        nativeVerificationInvalidated = true
        invalidateNativeTarget?()
    }

    func probeNativeCapabilities(isCurrent: @MainActor @Sendable () throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("personastack-desktop-probe-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("read-write.txt")
        let expected = Data("personastack-filesystem-probe".utf8)
        do {
            try await files.makeDirectory(path: root.path)
            _ = try await files.write(path: file.path, content: expected, mode: .create)
            let opened = try await files.open(path: file.path)
            let read = try await files.read(id: opened.id, offset: 0)
            guard read.content == expected, read.endOfFile else { throw DesktopFileSystemError.invalidPath }
            try await files.close(id: opened.id)
            try await files.remove(path: file.path)
            try await files.remove(path: root.path)
            try isCurrent()
        } catch {
            await files.closeAll()
            try? await files.remove(path: file.path)
            try? await files.remove(path: root.path)
            _ = await shell.closeAll()
            throw error
        }

        do {
            let started = try await shell.start(
                command: "printf 'personastack-stream-start'; IFS= read -r _personastack_probe_first; printf 'personastack-stream-middle'; IFS= read -r _personastack_probe_second; printf 'personastack-stream-end'",
                workingDirectory: FileManager.default.temporaryDirectory.path,
                timeout: 5
            )
            let first = Self.output(started)
            guard started.state == .running, first.contains("personastack-stream-start") else {
                throw DesktopShellError.invalidCommand
            }
            try await shell.write(id: started.executionID, input: .data(Data("continue\n".utf8)))
            try isCurrent()
            var combined = first
            var cursor = started.nextCursor
            let middleDeadline = ContinuousClock.now + .seconds(3)
            var middleObserved = false
            while ContinuousClock.now < middleDeadline {
                let output = try await shell.read(id: started.executionID, after: cursor, wait: .milliseconds(250))
                cursor = output.nextCursor
                combined += Self.output(output)
                if combined.contains("personastack-stream-middle") {
                    middleObserved = true
                    guard output.state == .running else { throw DesktopShellError.invalidCommand }
                    break
                }
            }
            guard middleObserved else { throw DesktopShellError.invalidCommand }
            try await shell.write(id: started.executionID, input: .data(Data("finish\n".utf8)))
            let exitDeadline = ContinuousClock.now + .seconds(3)
            var finalState = started.state
            var finalExitCode = started.exitCode
            while ContinuousClock.now < exitDeadline, finalState == .running {
                let output = try await shell.read(id: started.executionID, after: cursor, wait: .milliseconds(250))
                cursor = output.nextCursor
                combined += Self.output(output)
                finalState = output.state
                finalExitCode = output.exitCode
            }
            try isCurrent()
            guard Self.nativeProbeSucceeded(state: finalState, exitCode: finalExitCode, output: combined) else {
                throw DesktopShellError.invalidCommand
            }
            guard await shell.closeAll() else { throw DesktopShellError.cancellationUnconfirmed }
        } catch {
            _ = await shell.closeAll()
            throw error
        }
    }

#if DEBUG
    func waitForActiveOperationsForTesting(_ expected: Int) async {
        guard activeOperations < expected else { return }
        await withCheckedContinuation { continuation in
            activeOperationWaiters.append((expected, continuation))
        }
    }

    func pauseCleanupBeforeResourceCloseForTesting(_ barrier: @escaping @Sendable () async -> Void) {
        cleanupResourceBarrierForTesting = barrier
    }

    func failNextCleanupForTesting() {
        cleanupFailuresForTesting += 1
    }

    func pauseNativeVerificationForTesting(_ barrier: @escaping @MainActor () async -> Void) {
        nativeVerificationBarrierForTesting = barrier
    }

    func pauseLeaseGrantAfterCleanupForTesting(_ barrier: @escaping @Sendable () async -> Void) {
        leaseGrantBarrierForTesting = barrier
    }

    private func signalActiveOperationWaiters() {
        let ready = activeOperationWaiters.filter { activeOperations >= $0.0 }
        activeOperationWaiters.removeAll { activeOperations >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
    }
#endif

    @discardableResult
    func close() async -> Bool {
        closed = true
        invalidateNativeVerification()
        expiryTask?.cancel()
        expiryTask = nil
        if cleanupInProgress { return await waitForLeaseCleanup() }
        // Keep commands fenced while a later local close retries only owned
        // resources from an earlier failed termination.
        return await clearExpiredLease()
    }

    func handle(_ frame: DesktopControlFrame, proxy: CuaMCPProxy?) async -> DesktopControlFrame {
        await handle(frame, proxy: proxy, onChunk: nil)
    }

    func handle(_ frame: DesktopControlFrame, proxy: CuaMCPProxy?,
                onChunk: (@Sendable (DesktopControlFrame) async throws -> Void)?) async -> DesktopControlFrame {
        await DesktopControlExecution.$deadline.withValue(frame.deadlineAt) {
            await execute(frame, proxy: proxy, onChunk: onChunk)
        }
    }

    private func execute(_ frame: DesktopControlFrame, proxy: CuaMCPProxy?,
                         onChunk: (@Sendable (DesktopControlFrame) async throws -> Void)?) async -> DesktopControlFrame {
        do {
            guard frame.deadlineAt != nil else { throw DesktopControlExecution.Expired() }
            try DesktopControlExecution.check()
        } catch {
            return Self.failure(frame, "desktop_command_expired", "The command expired or was cancelled before execution. No new action was started.")
        }
        guard let requestID = frame.requestID, let target = frame.target else {
            return Self.failure(frame, "desktop_executor_unavailable", "The desktop control service is paused or recovering.")
        }
        let isStatus = frame.operation == "desktop_control_status"
        if frame.operation == "desktop_control_revoke_config" {
            guard let version = target.configVersion, version > 0,
                  !target.installationID.isEmpty, !target.workspaceID.isEmpty, !target.configID.isEmpty,
                  target.personaID.isEmpty, target.runID.isEmpty, target.generation == 0 else {
                return Self.failure(frame, "invalid_arguments", "The Desktop Control revocation scope is invalid.")
            }
            return await revokeConfig(frame, scope: Self.scope(target), version: version)
        }
        if frame.operation == "desktop_control_revoke_binding" {
            guard let version = target.configVersion, version > 0,
                  !target.installationID.isEmpty, !target.workspaceID.isEmpty, !target.configID.isEmpty,
                  !target.personaID.isEmpty, target.runID.isEmpty, target.generation > 0 else {
                return Self.failure(frame, "invalid_arguments", "The Desktop Control binding revocation scope is invalid.")
            }
            return await revokeConfig(frame, scope: Self.scope(target), version: version,
                                      binding: BindingScope(config: Self.scope(target), personaID: target.personaID))
        }
        guard isStatus || !revocationInProgress else {
            return Self.failure(frame, "desktop_control_revocation_in_progress", "Another Desktop Control configuration is being cleaned up. Retry after it finishes.")
        }
        guard isStatus || (!closed && !unavailable && nativeVerificationID == nil) else {
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
        guard isBindingAuthorized(owner) else {
            return Self.failure(frame, "desktop_control_binding_revoked", "This persona no longer has access to this Desktop Control configuration.")
        }
        let commandEpoch = leaseEpoch
        let needsLease = !["desktop_control_acquire", "desktop_control_release", "desktop_control_status"].contains(frame.operation ?? "")
        let operationActive = needsLease
        if operationActive {
            activeOperations += 1
#if DEBUG
            signalActiveOperationWaiters()
#endif
        }
        defer { if operationActive { activeOperations -= 1 } }
        let presentationID = beginPresentation(frame, owner: owner)
        defer { if let presentationID { presentedOperations.removeValue(forKey: presentationID) } }
        do {
            let result: Any
            switch frame.operation {
            case "desktop_control_status":
                let ready = !closed && !unavailable && !revocationInProgress && nativeVerificationID == nil
                result = ["available": ready, "native_executor_ready": ready, "busy": validLease() != nil || nativeVerificationID != nil]
            case "desktop_control_acquire":
                result = try await acquire(owner, scope: scope, configVersion: configVersion)
                if validLease()?.owner == owner { leaseOwnerDisplay = target.ownerDisplay }
            case "desktop_control_release":
                try requireLease(owner, arguments: frame.arguments, renew: false)
                guard await clearExpiredLease() else {
                    unavailable = true
                    throw CommandError.executorUnavailable
                }
                result = ["released": true]
            case "desktop_control_observe", "desktop_control_input", "desktop_control_application",
                 "desktop_control_window", "desktop_control_clipboard", "desktop_control_browser":
                try requireLease(owner, arguments: frame.arguments)
                result = try await callCua(frame, proxy: proxy)
            case "desktop_control_file":
                try requireLease(owner, arguments: frame.arguments)
                result = try await fileOperation(frame.arguments)
            case "desktop_control_execute":
                try requireLease(owner, arguments: frame.arguments)
                result = try await shellStart(frame.arguments)
            case "desktop_control_exec_read":
                try requireLease(owner, arguments: frame.arguments)
                result = try await shellRead(frame.arguments)
            case "desktop_control_exec_write":
                try requireLease(owner, arguments: frame.arguments)
                result = try await shellWrite(frame.arguments)
            case "desktop_control_exec_status":
                try requireLease(owner, arguments: frame.arguments)
                result = try await shellStatus(frame.arguments)
            case "desktop_control_exec_cancel":
                try requireLease(owner, arguments: frame.arguments)
                result = try await shellCancel(frame.arguments)
            default:
                throw CommandError.invalidArguments
            }
            guard isBindingAuthorized(owner) else { throw CommandError.bindingRevoked }
            if needsLease && commandEpoch != leaseEpoch { throw CommandError.controlRequired }
            if let onChunk {
                try await forwardShellChunks(result, requestID: requestID, scope: scope,
                                             configVersion: configVersion, epoch: commandEpoch, onChunk: onChunk)
            }
            guard isConfigVersionAuthorized(scope, configVersion) else { throw CommandError.configurationRevoked }
            guard isBindingAuthorized(owner) else { throw CommandError.bindingRevoked }
            if needsLease && commandEpoch != leaseEpoch { throw CommandError.controlRequired }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
            let value = try JSONDecoder().decode(DesktopControlJSONValue.self, from: data)
            return DesktopControlFrame(type: "result", requestID: requestID, result: value)
        } catch is DesktopControlExecution.Expired {
            return Self.failure(frame, "desktop_command_expired", "The command deadline elapsed before its next operation. Check the current state before retrying; earlier steps may have completed.")
        } catch is CancellationError {
            return Self.failure(frame, "outcome_unknown", "The command was cancelled. Check the desktop before repeating an action.")
        } catch let error as CuaMCPProxyError where error == .timeout || error == .interrupted || error == .processExited {
            return Self.failure(frame, "outcome_unknown", "Cua stopped answering after dispatch. Check the desktop before repeating an action.")
        } catch let error as DesktopCuaFailure {
            return Self.failure(frame, error.code, error.message)
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

    private func forwardShellChunks(_ result: Any, requestID: String, scope: ConfigScope, configVersion: Int64, epoch: UInt64,
                                    onChunk: @Sendable (DesktopControlFrame) async throws -> Void) async throws {
        guard let value = result as? [String: Any],
              value["execution_id"] is String,
              let chunks = value["chunks"] as? [[String: Any]] else { return }
        for (index, chunk) in chunks.enumerated() {
            guard epoch == leaseEpoch else { throw CommandError.controlRequired }
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
        guard nativeVerificationID == nil else { throw CommandError.executorUnavailable }
        if let active = validLease() {
            guard active.owner == owner else { throw CommandError.busy }
            var renewed = active
            renewed.lastActivity = now()
            lease = renewed
            return ["control_token": active.token, "expires_in_seconds": 90]
        }
        if lease != nil {
            guard await clearExpiredLease() else { throw CommandError.executorUnavailable }
#if DEBUG
            if let barrier = leaseGrantBarrierForTesting { await barrier() }
#endif
            // Another acquisition can resume between cleanup completion and this
            // continuation. Never replace that newly granted lease.
            guard isBindingAuthorized(owner) else { throw CommandError.bindingRevoked }
            if let active = validLease() {
                guard active.owner == owner else { throw CommandError.busy }
                return ["control_token": active.token, "expires_in_seconds": 90]
            }
        }
        guard !closed, !unavailable, !revocationInProgress, nativeVerificationID == nil else { throw CommandError.executorUnavailable }
        guard isConfigVersionAuthorized(scope, configVersion) else { throw CommandError.configurationRevoked }
        try DesktopControlExecution.check()
        guard powerAssertion.acquire() else { throw CommandError.sleepPreventionUnavailable }
        let token = UUID().uuidString.lowercased()
        let now = now()
        lease = Lease(owner: owner, configVersion: configVersion, token: token, started: now, lastActivity: now)
        return ["control_token": token, "expires_in_seconds": 90]
    }

    private func revokeConfig(_ frame: DesktopControlFrame, scope: ConfigScope, version: Int64, binding: BindingScope? = nil) async -> DesktopControlFrame {
        invalidateNativeVerification()
        activeRevocations += 1
        defer { activeRevocations -= 1 }
        let cutoff = frame.target?.generation ?? 0
        if let binding {
            revokedBindingGenerations[binding] = max(revokedBindingGenerations[binding] ?? 0, cutoff)
        } else {
            revokedConfigVersions[scope] = max(revokedConfigVersions[scope] ?? 0, version)
        }
        let matches = lease.map { leaseMatchesRevocation($0, scope: scope, version: version, cutoff: cutoff, binding: binding) } ?? false
        let cleanupMatches = cleanupInProgress && cleanupLease.map {
            leaseMatchesRevocation($0, scope: scope, version: version, cutoff: cutoff, binding: binding)
        } == true
        let failedCleanupMatches = failedCleanupWithoutLease || failedCleanupLease.map {
            leaseMatchesRevocation($0, scope: scope, version: version, cutoff: cutoff, binding: binding)
        } == true
        if matches {
            guard await cleanupLeaseAndResources(lease) else {
                return Self.failure(frame, "desktop_control_revoke_incomplete", "The Mac could not confirm that every command or process stopped.")
            }
        } else if cleanupMatches {
            // Join the same cleanup used by direct revoke, release, and expiry.
            guard await waitForLeaseCleanup() else {
                unavailable = true
                return Self.failure(frame, "desktop_control_revoke_incomplete", "The Mac could not confirm that every command or process stopped.")
            }
        } else if failedCleanupMatches {
            // A prior cleanup failed. Retry that same lease before acknowledging.
            guard await cleanupLeaseAndResources(failedCleanupLease) else {
                return Self.failure(frame, "desktop_control_revoke_incomplete", "The Mac could not confirm that every command or process stopped.")
            }
        }
        return DesktopControlFrame(type: "result", requestID: frame.requestID,
                                   result: .object(["revoked": .bool(true)]))
    }

    private func isBindingAuthorized(_ owner: Owner) -> Bool {
        let scope = BindingScope(config: Self.scope(owner), personaID: owner.personaID)
        guard let cutoff = revokedBindingGenerations[scope] else { return true }
        return owner.generation > cutoff
    }

    private func leaseMatchesRevocation(_ lease: Lease, scope: ConfigScope, version: Int64, cutoff: Int64,
                                        binding: BindingScope?) -> Bool {
        guard Self.scope(lease.owner) == scope else { return false }
        return binding.map { lease.owner.personaID == $0.personaID && lease.owner.generation <= cutoff }
            ?? (lease.configVersion <= version)
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
              lease.lastActivity.duration(to: now()) < .seconds(90),
              lease.started.duration(to: now()) < .seconds(1800) else { return nil }
        return lease
    }

    private func requireLease(_ owner: Owner, arguments: DesktopControlJSONValue?, renew: Bool = true) throws {
        guard let lease = validLease(), lease.owner == owner,
              case .object(let values)? = arguments,
              case .string(let token)? = values["control_token"], token == lease.token else {
            throw CommandError.controlRequired
        }
        if renew { self.lease?.lastActivity = now() }
    }

    private func clearExpiredLease() async -> Bool {
        guard !revocationInProgress else { return false }
        activeRevocations += 1
        defer { activeRevocations -= 1 }
        return await cleanupLeaseAndResources(failedCleanupLease ?? lease)
    }

    private func cleanupLeaseAndResources(_ closingLease: Lease?) async -> Bool {
        let wasUnavailable = unavailable
        cleanupLease = closingLease
        cleanupInProgress = true
        var succeeded = false
        defer {
            cleanupSucceeded = succeeded
            if succeeded {
                failedCleanupLease = nil
                failedCleanupWithoutLease = false
                if cleanupFailureMayRestoreAvailability { unavailable = false }
                cleanupFailureMayRestoreAvailability = false
            } else if let closingLease {
                if !wasUnavailable { cleanupFailureMayRestoreAvailability = true }
                failedCleanupLease = closingLease
            } else {
                if !wasUnavailable { cleanupFailureMayRestoreAvailability = true }
                failedCleanupWithoutLease = true
            }
            if !succeeded { unavailable = true }
            cleanupLease = nil
            cleanupInProgress = false
            let waiters = cleanupWaiters
            cleanupWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: succeeded) }
        }
        // Fence the old owner before suspending. New acquisition stays unavailable
        // until callbacks, file handles, and managed processes have drained.
        leaseEpoch &+= 1
        lease = nil
        let sleepPreventionReleased = powerAssertion.relinquish()
        await shell.requestStopAll()
        guard await settleOperations() else { unavailable = true; return false }
#if DEBUG
        if let cleanupResourceBarrierForTesting {
            self.cleanupResourceBarrierForTesting = nil
            await cleanupResourceBarrierForTesting()
        }
#endif
        await files.closeAll()
        guard await shell.closeAll() else {
            unavailable = true
            return false
        }
        guard sleepPreventionReleased else { return false }
#if DEBUG
        if cleanupFailuresForTesting > 0 {
            cleanupFailuresForTesting -= 1
            unavailable = true
            return false
        }
#endif
        succeeded = true
        return true
    }

    private func waitForLeaseCleanup() async -> Bool {
        guard cleanupInProgress else { return cleanupSucceeded }
        return await withCheckedContinuation { cleanupWaiters.append($0) }
    }

    private func settleOperations() async -> Bool {
        // Cua calls have a 60-second bound. Drain admitted operations before
        // closing their resources, so a queued open/start cannot follow cleanup.
        let deadline = ContinuousClock.now + .seconds(65)
        while activeOperations > 0, ContinuousClock.now < deadline {
            await Task { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
        return activeOperations == 0
    }

    func expireLeaseIfNeeded() async {
        guard !closed, !revocationInProgress, let original = lease else { return }
        let processes = await shell.diagnostics()
        guard !closed, !revocationInProgress, lease?.token == original.token else { return }
        if processes.activeProcesses > 0, original.started.duration(to: now()) < .seconds(1800) {
            lease?.lastActivity = now()
        }
        guard validLease() == nil else { return }
        if !(await clearExpiredLease()) { unavailable = true }
    }

    private func callCua(_ frame: DesktopControlFrame, proxy: CuaMCPProxy?) async throws -> Any {
        guard let proxy, case .object(let values)? = frame.arguments,
              case .string(let name)? = values["tool"],
              CuaDriverCompatibility.exposedTools.contains(name),
              let rawArguments = values["arguments"] else { throw CommandError.invalidArguments }
        let allowed = Self.allowedTools(for: frame.operation ?? "")
        guard allowed.contains(name) else { throw CommandError.invalidArguments }
        let preparedArguments = try Self.cuaArguments(name: name, arguments: rawArguments,
                                                     controlToken: lease?.token ?? "")
        let encoded = try JSONEncoder().encode(preparedArguments)
        let response = try await proxy.callTool(name: name, argumentsJSON: encoded)
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = object["result"] as? [String: Any], object["error"] == nil else {
            logger.error("Cua tool response invalid tool=\(name, privacy: .public)")
            throw CommandError.commandFailed
        }
        guard !Self.isCuaToolError(result) else {
            logger.error("Cua tool returned an error tool=\(name, privacy: .public)")
            throw DesktopCuaFailure.from(result, tool: name)
        }
        return try Self.boundedCuaImageResult(result)
    }

    static func cuaArguments(name: String, arguments: DesktopControlJSONValue,
                             controlToken: String) throws -> DesktopControlJSONValue {
        guard name == "get_browser_state" || name.hasPrefix("browser_") else { return arguments }
        guard !controlToken.isEmpty, case .object(var fields) = arguments else { throw CommandError.invalidArguments }
        if name == "browser_prepare" {
            guard fields.count == 1, fields["confirm"] == .bool(true) else { throw CommandError.invalidArguments }
            return .object(["session": .string(controlToken), "allow_launch": .bool(true),
                            "profile": .object(["mode": .string("isolated_new")])])
        }
        if let session = fields["session"], session != .string(controlToken) { throw CommandError.invalidArguments }
        fields["session"] = .string(controlToken)
        return .object(fields)
    }

    static func isCuaToolError(_ result: [String: Any]) -> Bool {
        (result["isError"] as? Bool) == true
    }

    // The Cua proxy may receive a full-resolution screenshot larger than the
    // gateway's 8 MiB frame. Keep the image visible to the persona by sending
    // a bounded JPEG and updating the screenshot dimensions it uses for input.
    static func boundedCuaImageResult(_ result: [String: Any],
                                      maxEncodedImageBytes: Int = 5 * 1024 * 1024) throws -> [String: Any] {
        guard var content = result["content"] as? [[String: Any]] else { return result }
        let imageIndices = content.indices.filter { content[$0]["type"] as? String == "image" }
        guard !imageIndices.isEmpty, maxEncodedImageBytes > 0 else { return result }
        let perImageLimit = maxEncodedImageBytes / imageIndices.count
        var updated = result
        var screenshotScale: Double?
        var screenshotSize: (Int, Int)?
        for index in imageIndices {
            guard let encoded = content[index]["data"] as? String else { throw CommandError.commandFailed }
            guard encoded.utf8.count > perImageLimit else { continue }
            guard let sourceData = Data(base64Encoded: encoded),
                  let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 80_000_000 / height,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CommandError.commandFailed
            }
            var replacement: Data?
            var replacementScale = 1.0
            for scale in [1.0, 0.75, 0.5, 0.25, 0.125] {
                guard let scaled = Self.scaledCuaImage(image, scale: scale) else { continue }
                for quality in [0.7, 0.5, 0.3] {
                    guard let jpeg = Self.jpegData(scaled, quality: quality) else { continue }
                    if jpeg.count <= perImageLimit / 4 * 3 {
                        replacement = jpeg
                        replacementScale = Double(scaled.width) / Double(width)
                        screenshotSize = (scaled.width, scaled.height)
                        break
                    }
                }
                if replacement != nil { break }
            }
            guard let replacement else { throw CommandError.commandFailed }
            content[index]["data"] = replacement.base64EncodedString()
            content[index]["mimeType"] = "image/jpeg"
            screenshotScale = replacementScale
        }
        updated["content"] = content
        if let screenshotScale, let screenshotSize,
           var structured = updated["structuredContent"] as? [String: Any],
           structured["screenshot_width"] != nil, structured["screenshot_height"] != nil {
            structured["screenshot_width"] = screenshotSize.0
            structured["screenshot_height"] = screenshotSize.1
            structured["screenshot_mime_type"] = "image/jpeg"
            if let priorScale = structured["scale_factor"] as? Double {
                structured["scale_factor"] = priorScale * screenshotScale
            }
            updated["structuredContent"] = structured
        }
        return updated
    }

    private static func scaledCuaImage(_ image: CGImage, scale: Double) -> CGImage? {
        guard scale < 1 else { return image }
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func nativeProbeSucceeded(state: DesktopProcessState, exitCode: Int32?, output: String) -> Bool {
        state == .exited && exitCode == 0 && output.contains("personastack-stream-end")
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
            let page = try await files.search(root: root, nameContains: args["name_contains"] as? String,
                                                 nameGlob: args["name_glob"] as? String,
                                                 contentContains: args["content_contains"] as? String,
                                                 limit: args["limit"] as? Int ?? 100,
                                                 continuation: args["continuation"] as? String)
            return ["matches": page.matches.map { match in
                var entry = Self.entry(match.entry)
                entry["matched_lines"] = match.matchedLines
                entry["content_scan_truncated"] = match.contentScanTruncated
                return entry
            }, "continuation": page.continuation as Any? ?? NSNull(),
                     "incomplete_content_paths": page.incompleteContentPaths,
                     "complete": page.isComplete]
        case "open":
            guard let path = args["path"] as? String else { throw CommandError.invalidArguments }
            let opened = try await files.open(path: path)
            var result = Self.fileContent(opened.firstRead)
            result["handle"] = opened.id.uuidString
            result["size"] = opened.size
            result["modified_at"] = Self.iso8601String(opened.modifiedAt)
            result["revision"] = opened.revision
            result["changed_since_open"] = opened.firstRead.changedSinceOpen
            if Self.supportedImageMIMETypes.contains(Self.mimeType(for: opened.path)),
               opened.size <= Self.maxImageContentBytes {
                var imageBytes = opened.firstRead.content
                var offset = opened.firstRead.nextOffset
                var changed = opened.firstRead.changedSinceOpen
                while !opened.firstRead.endOfFile && offset < opened.size {
                    let page = try await files.read(id: opened.id, offset: offset)
                    if page.content.isEmpty || page.nextOffset <= offset { break }
                    imageBytes.append(page.content)
                    offset = page.nextOffset
                    changed = changed || page.changedSinceOpen
                    if page.endOfFile { break }
                }
                if !changed, offset >= opened.size, UInt64(imageBytes.count) == opened.size {
                    result["content"] = [["type": "image", "data": imageBytes.base64EncodedString(),
                                          "mimeType": Self.mimeType(for: opened.path)]]
                    result["byte_length"] = imageBytes.count
                    result["next_offset"] = imageBytes.count
                    result["end_of_file"] = true
                    result["encoding"] = "image"
                    result.removeValue(forKey: "content_base64")
                    result.removeValue(forKey: "content_text")
                    result.removeValue(forKey: "line_count")
                } else {
                    result["image_content_unavailable"] = changed ? "file_changed_during_read" : "incomplete_read"
                }
            }
            return result
        case "read":
            guard let id = Self.uuid(args["handle"]) else { throw CommandError.invalidArguments }
            let read: DesktopFileRead
            if let startLine = args["start_line"] as? Int {
                guard let lineCount = args["line_count"] as? Int, args["offset"] == nil else { throw CommandError.invalidArguments }
                read = try await files.readLines(id: id, startLine: startLine, lineCount: lineCount,
                                                length: args["length"] as? Int ?? 256 * 1024)
            } else {
                guard args["line_count"] == nil else { throw CommandError.invalidArguments }
                let offset = try Self.optionalUInt64(args["offset"]) ?? 0
                read = try await files.read(id: id, offset: offset, length: args["length"] as? Int ?? 256 * 1024)
            }
            var result = Self.fileContent(read)
            result["changed_since_open"] = read.changedSinceOpen
            return result
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
            return Self.entry(try await files.write(path: path, content: data, mode: writeMode, offset: Self.optionalUInt64(args["offset"])))
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
        guard let lease = validLease() else { throw CommandError.controlRequired }
        let remaining = now().duration(to: lease.started + .seconds(1800))
        let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
        guard seconds >= 1 else { throw CommandError.controlRequired }
        let process = try await shell.start(command: command, workingDirectory: cwd,
                                            timeout: min(args["timeout_seconds"] as? Double ?? 300, seconds))
        return Self.process(process)
    }

    private func shellRead(_ arguments: DesktopControlJSONValue?) async throws -> Any {
        guard let args = Self.object(arguments), let id = Self.uuid(args["execution_id"]) else { throw CommandError.invalidArguments }
        let wait = min(max(args["wait_ms"] as? Int ?? 0, 0), 10_000)
        return Self.process(try await shell.read(id: id, after: Self.optionalUInt64(args["cursor"]) ?? 0, wait: .milliseconds(wait)))
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
        case "desktop_control_browser": return ["browser_prepare", "get_browser_state", "browser_navigate", "browser_click", "browser_type", "browser_pointer", "browser_dialog", "browser_download", "browser_set_input_files"]
        default: return []
        }
    }

    private static func object(_ value: DesktopControlJSONValue?) -> [String: Any]? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }
    private static func optionalUInt64(_ value: Any?) throws -> UInt64? {
        guard let value else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = UInt64(exactly: number.doubleValue), integer <= UInt64(Int64.max) else {
            throw CommandError.invalidArguments
        }
        return integer
    }

    private static func entry(_ entry: DesktopFileEntry) -> [String: Any] {
        ["path": entry.path, "name": entry.name, "kind": entry.kind.rawValue, "size": entry.size,
         "modified_at": entry.modifiedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
         "symlink_target": entry.symlinkTarget as Any? ?? NSNull()]
    }

    private static func fileContent(_ read: DesktopFileRead) -> [String: Any] {
        let mimeType = Self.mimeType(for: read.path)
        var result: [String: Any] = [
            "path": read.path,
            "byte_offset": read.offset,
            "byte_length": read.content.count,
            "next_offset": read.nextOffset,
            "end_of_file": read.endOfFile,
            "line_start": NSNull(),
            "next_line": NSNull(),
            "truncated": read.truncated,
            "mime_type": mimeType,
            "encoding": "base64",
            "content_base64": read.content.base64EncodedString(),
        ]
        if read.offset == 0, read.endOfFile, Self.supportedImageMIMETypes.contains(mimeType) {
            result["content"] = [["type": "image", "data": read.content.base64EncodedString(), "mimeType": mimeType]]
        }
        if !read.content.contains(0), let text = String(data: read.content, encoding: .utf8),
           text.unicodeScalars.allSatisfy({ scalar in
               !CharacterSet.controlCharacters.contains(scalar) || scalar == "\n" || scalar == "\r" || scalar == "\t"
           }) {
            result["content_text"] = text
            result["encoding"] = "utf-8"
            result["line_count"] = text.isEmpty ? 0 : text.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            } + (text.hasSuffix("\n") ? 0 : 1)
            if let lineStart = read.lineStart {
                result["line_start"] = lineStart
                result["next_line"] = read.nextLine ?? (lineStart + (result["line_count"] as? Int ?? 0))
            }
        } else {
            result["line_count"] = NSNull()
        }
        return result
    }

    // Base64 adds one third to the source bytes. Keep the complete result below
    // the shared 8 MiB frame limit after JSON metadata is included.
    private static let maxImageContentBytes: UInt64 = 5 * 1024 * 1024
    private static let supportedImageMIMETypes: Set<String> = ["image/png", "image/jpeg", "image/webp"]

    private static func mimeType(for path: String) -> String {
        UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func process(_ process: DesktopProcessRead) -> [String: Any] {
        ["execution_id": process.executionID.uuidString, "chunks": process.chunks.map {
            ["sequence": $0.sequence, "stream": $0.stream.rawValue, "data_base64": $0.data.base64EncodedString()]
        }, "next_cursor": process.nextCursor, "earliest_cursor": process.earliestCursor,
         "output_gap": process.outputGap, "state": process.state.rawValue,
         "exit_code": process.exitCode as Any? ?? NSNull(), "signal": process.signal as Any? ?? NSNull()]
    }

    private static func output(_ read: DesktopProcessRead) -> String {
        let data = read.chunks.reduce(into: Data()) { result, chunk in result.append(chunk.data) }
        return String(decoding: data, as: UTF8.self)
    }

    private static func failure(_ frame: DesktopControlFrame, _ code: String, _ message: String) -> DesktopControlFrame {
        DesktopControlFrame(type: "failure", requestID: frame.requestID, errorCode: code, errorMessage: message)
    }
}

private enum CommandError: Error, LocalizedError {
    case invalidArguments, busy, controlRequired, configurationRevoked, bindingRevoked, commandFailed, executorUnavailable, sleepPreventionUnavailable
    var code: String {
        switch self {
        case .invalidArguments: "invalid_arguments"
        case .busy: "desktop_busy"
        case .controlRequired: "desktop_control_required"
        case .configurationRevoked: "desktop_control_config_revoked"
        case .bindingRevoked: "desktop_control_binding_revoked"
        case .commandFailed: "desktop_command_failed"
        case .executorUnavailable: "desktop_executor_unavailable"
        case .sleepPreventionUnavailable: "desktop_executor_unavailable"
        }
    }
    var errorDescription: String? {
        switch self {
        case .invalidArguments: "The desktop command arguments are invalid."
        case .busy: "The desktop is controlled by another active persona."
        case .controlRequired: "Acquire desktop control before using this tool."
        case .configurationRevoked: "This Desktop Control configuration is disabled or no longer authorized."
        case .bindingRevoked: "This persona no longer has access to this Desktop Control configuration."
        case .commandFailed: "The desktop command failed."
        case .executorUnavailable: "The previous desktop command is still stopping. Retry after the desktop service recovers."
        case .sleepPreventionUnavailable: "PersonaStack could not keep this Mac awake during remote work. Retry Setup Awake During Remote Work in Permissions and Setup."
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
        case .searchContinuationExpired: "desktop_file_search_continuation_expired"
        case .tooManySearches: "desktop_file_search_limit"
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
        case .searchContinuationExpired: "This file search continuation expired. Start the search again with a narrower folder or filter."
        case .tooManySearches: "Too many file searches are still open. Continue or restart an earlier search before starting another."
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
        case .inputOutcomeUnknown: "outcome_unknown"
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
        case .inputOutcomeUnknown:
            "Command input may have been partly delivered. Read process output and inspect its state before sending more input. Do not repeat the entire input blindly."
        case .cancellationUnconfirmed:
            "The desktop could not confirm that the command stopped. Check its status before retrying work."
        case .invalidCommand:
            "The desktop could not start the command. Check the working directory and try again."
        }
    }
}
