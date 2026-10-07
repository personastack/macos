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
        let cuaSession: String
        var cuaSessionNeedsStart: Bool
        let started: ContinuousClock.Instant
        var lastActivity: ContinuousClock.Instant
    }

    private var leaseCuaProxy: (any CuaToolCalling)?
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
    var needsSessionCleanup: Bool { unavailable && (lease != nil || failedCleanupLease != nil) }
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

    init(now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.now = now
        expiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await self.expireLeaseIfNeeded()
            }
        }
    }

    func diagnostics() async -> DesktopControlDiagnostics {
        DesktopControlDiagnostics(activeProcesses: 0, openFileHandles: 0,
                                  bufferedOutputBytes: 0, outputGapsTotal: 0)
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

    var permissionSetupAvailable: Bool { canBeginNativeVerification }

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

    func handle(_ frame: DesktopControlFrame, proxy: (any CuaToolCalling)?) async -> DesktopControlFrame {
        await handle(frame, proxy: proxy, onChunk: nil)
    }

    func handle(_ frame: DesktopControlFrame, proxy: (any CuaToolCalling)?,
                onChunk: (@Sendable (DesktopControlFrame) async throws -> Void)?) async -> DesktopControlFrame {
        await DesktopControlExecution.$deadline.withValue(frame.deadlineAt) {
            await execute(frame, proxy: proxy, onChunk: onChunk)
        }
    }

    private func execute(_ frame: DesktopControlFrame, proxy: (any CuaToolCalling)?,
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
        guard isStatus || (!closed && (!unavailable || frame.operation == "desktop_control_release") && nativeVerificationID == nil) else {
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
                result = try await acquire(owner, scope: scope, configVersion: configVersion, ownerDisplay: target.ownerDisplay)
                if validLease()?.owner == owner { leaseOwnerDisplay = target.ownerDisplay }
            case "desktop_control_release":
                try requireLease(owner, arguments: frame.arguments, renew: false)
                guard await clearExpiredLease() else {
                    unavailable = true
                    throw CommandError.executorUnavailable
                }
                result = ["released": true]
            case "desktop_control_observe", "desktop_control_input", "desktop_control_application",
                 "desktop_control_window", "desktop_control_clipboard", "desktop_control_browser", "desktop_control_cua":
                try requireLease(owner, arguments: frame.arguments)
                result = try await callCua(frame, proxy: proxy)
            default:
                throw CommandError.invalidArguments
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
            if leaseCuaProxy != nil { fenceUncertainSession() }
            return Self.failure(frame, "outcome_unknown", "The command was cancelled. Check the desktop before repeating an action.")
        } catch let error as CuaMCPProxyError where error == .timeout || error == .interrupted || error == .processExited {
            fenceUncertainSession()
            return Self.failure(frame, "outcome_unknown", "Cua stopped answering after dispatch. Check the desktop before repeating an action.")
        } catch let error as DesktopCuaFailure {
            return Self.failure(frame, error.code, error.message)
        } catch let error as CommandError {
            return Self.failure(frame, error.code, error.localizedDescription)
        } catch {
            return Self.failure(frame, "desktop_command_failed", "The desktop command failed.")
        }
    }

    private func fenceUncertainSession() {
        unavailable = true
        cleanupFailureMayRestoreAvailability = true
    }

    private func acquire(_ owner: Owner, scope: ConfigScope, configVersion: Int64,
                         ownerDisplay: DesktopControlOwnerDisplay?) async throws -> [String: Any] {
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
        let token = UUID().uuidString.lowercased()
        let now = now()
        let personaName = ownerDisplay?.personaName.trimmingCharacters(in: .whitespacesAndNewlines)
        // CUA reserves these session labels. Prefix only those names so they
        // still identify the persona without selecting an implicit/private session.
        let cuaSession = personaName.map {
            $0 == "default" || $0.hasPrefix("__cua_runtime_") ? "Persona: \($0)" : $0
        } ?? UUID().uuidString
        lease = Lease(owner: owner, configVersion: configVersion, token: token,
                      cuaSession: cuaSession, cuaSessionNeedsStart: personaName != nil,
                      started: now, lastActivity: now)
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
                return Self.failure(frame, "desktop_control_revoke_incomplete", "CUA could not confirm that this PersonaStack session stopped.")
            }
        } else if cleanupMatches {
            // Join the same cleanup used by direct revoke, release, and expiry.
            guard await waitForLeaseCleanup() else {
                unavailable = true
                return Self.failure(frame, "desktop_control_revoke_incomplete", "CUA could not confirm that this PersonaStack session stopped.")
            }
        } else if failedCleanupMatches {
            // A prior cleanup failed. Retry that same lease before acknowledging.
            guard await cleanupLeaseAndResources(failedCleanupLease) else {
                return Self.failure(frame, "desktop_control_revoke_incomplete", "CUA could not confirm that this PersonaStack session stopped.")
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
        // until admitted CUA calls and the owned session have drained.
        leaseEpoch &+= 1
        lease = nil
        guard await settleOperations() else { unavailable = true; return false }
#if DEBUG
        if let cleanupResourceBarrierForTesting {
            self.cleanupResourceBarrierForTesting = nil
            await cleanupResourceBarrierForTesting()
        }
#endif
        if let proxy = leaseCuaProxy, let closingLease {
            do {
                let args = try JSONEncoder().encode(DesktopControlJSONValue.object(["session": .string(closingLease.cuaSession)]))
                let response = try await DesktopControlExecution.$deadline.withValue(Date().addingTimeInterval(5)) {
                    try await proxy.callTool(name: "end_session", argumentsJSON: args, timeout: 5)
                }
                guard case .object(let envelope) = try JSONDecoder().decode(DesktopControlJSONValue.self, from: response),
                      case .object(let result)? = envelope["result"], envelope["error"] == nil,
                      result["isError"] == nil || result["isError"] == .bool(false),
                      case .object(let confirmation)? = result["structuredContent"],
                      confirmation["session"] == .string(closingLease.cuaSession),
                      confirmation["active"] == .bool(false) else { return false }
                leaseCuaProxy = nil
            } catch { return false }
        }
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
        // ending their session, so an admitted action cannot follow cleanup.
        let deadline = ContinuousClock.now + .seconds(65)
        while activeOperations > 0, ContinuousClock.now < deadline {
            await Task { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
        return activeOperations == 0
    }

    func expireLeaseIfNeeded() async {
        guard !closed, !revocationInProgress, lease != nil else { return }
        guard validLease() == nil else { return }
        if !(await clearExpiredLease()) { unavailable = true }
    }

    private func callCua(_ frame: DesktopControlFrame, proxy: (any CuaToolCalling)?) async throws -> Any {
        guard let proxy, case .object(let values)? = frame.arguments,
              case .string(let name)? = values["tool"],
              CuaDriverCompatibility.exposedTools.contains(name),
              let rawArguments = values["arguments"] else { throw CommandError.invalidArguments }
        let allowed = Self.allowedTools(for: frame.operation ?? "")
        guard allowed.contains(name) else { throw CommandError.invalidArguments }
        let preparedArguments = try Self.cuaArguments(name: name, arguments: rawArguments,
                                                     controlToken: lease?.cuaSession ?? "")
        guard let currentLease = validLease() else { throw CommandError.controlRequired }
        leaseCuaProxy = proxy
        if currentLease.cuaSessionNeedsStart {
            // Named sessions need explicit revival after a previous lease ends.
            // No capture policy, permission request, or cursor setting is supplied.
            let started = try await invokeCua(name: "start_session",
                arguments: .object(["session": .string(currentLease.cuaSession)]), proxy: proxy)
            let decoded = try JSONDecoder().decode(DesktopControlJSONValue.self,
                from: JSONSerialization.data(withJSONObject: started))
            guard case .object(let startedFields) = decoded,
                  case .object(let confirmation)? = startedFields["structuredContent"],
                  confirmation["session"] == .string(currentLease.cuaSession),
                  confirmation["active"] == .bool(true) else { throw CommandError.commandFailed }
            try requireCurrentCuaLease(currentLease)
            lease?.cuaSessionNeedsStart = false
        }
        let result = try await invokeCua(name: name, arguments: preparedArguments, proxy: proxy)
        try requireCurrentCuaLease(currentLease)
        return try Self.boundedCuaImageResult(result)
    }

    private func requireCurrentCuaLease(_ currentLease: Lease) throws {
        guard isBindingAuthorized(currentLease.owner) else { throw CommandError.bindingRevoked }
        guard isConfigVersionAuthorized(Self.scope(currentLease.owner), currentLease.configVersion) else {
            throw CommandError.configurationRevoked
        }
        guard validLease()?.token == currentLease.token else { throw CommandError.controlRequired }
    }

    private func invokeCua(name: String, arguments: DesktopControlJSONValue,
                           proxy: any CuaToolCalling) async throws -> [String: Any] {
        let encoded = try JSONEncoder().encode(arguments)
        let response = try await proxy.callTool(name: name, argumentsJSON: encoded, timeout: 60)
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = object["result"] as? [String: Any], object["error"] == nil else {
            logger.error("Cua tool response invalid tool=\(name, privacy: .public)")
            throw CommandError.commandFailed
        }
        guard !Self.isCuaToolError(result) else {
            logger.error("Cua tool returned an error tool=\(name, privacy: .public)")
            throw DesktopCuaFailure.from(result, tool: name)
        }
        return result
    }

    static func cuaArguments(name: String, arguments: DesktopControlJSONValue,
                             controlToken: String) throws -> DesktopControlJSONValue {
        do { return try CuaRemoteToolArguments.prepare(name: name, arguments: arguments, session: controlToken) }
        catch { throw CommandError.invalidArguments }
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

    private static func allowedTools(for operation: String) -> Set<String> {
        switch operation {
        case "desktop_control_cua": return CuaDriverCompatibility.exposedTools
        case "desktop_control_observe": return ["get_desktop_state", "get_accessibility_tree", "get_window_state", "get_cursor_position", "get_screen_size", "list_apps", "list_windows", "get_browser_state"]
        case "desktop_control_input": return ["move_cursor", "click", "double_click", "right_click", "drag", "scroll", "type_text", "press_key", "hotkey", "set_value", "zoom"]
        case "desktop_control_application": return ["launch_app", "bring_to_front", "kill_app", "list_apps"]
        case "desktop_control_window": return ["list_windows", "get_window_state", "set_window_frame", "bring_to_front", "invoke_menu"]
        case "desktop_control_clipboard": return ["clipboard_read", "clipboard_write"]
        case "desktop_control_browser": return ["browser_prepare", "get_browser_state", "browser_navigate", "browser_click", "browser_type", "browser_pointer", "browser_dialog", "browser_download", "browser_set_input_files"]
        default: return []
        }
    }

    private static func failure(_ frame: DesktopControlFrame, _ code: String, _ message: String) -> DesktopControlFrame {
        DesktopControlFrame(type: "failure", requestID: frame.requestID, errorCode: code, errorMessage: message)
    }
}

private enum CommandError: Error, LocalizedError {
    case invalidArguments, busy, controlRequired, configurationRevoked, bindingRevoked, commandFailed, executorUnavailable
    var code: String {
        switch self {
        case .invalidArguments: "invalid_arguments"
        case .busy: "desktop_busy"
        case .controlRequired: "desktop_control_required"
        case .configurationRevoked: "desktop_control_config_revoked"
        case .bindingRevoked: "desktop_control_binding_revoked"
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
        case .bindingRevoked: "This persona no longer has access to this Desktop Control configuration."
        case .commandFailed: "The desktop command failed."
        case .executorUnavailable: "The previous desktop command is still stopping. Retry after the desktop service recovers."
        }
    }
}
