import Foundation
import Combine
import PersonaStackCore

@MainActor
protocol DesktopPermissionChecklistAdapting {
    /// Reads public grants and historical proof. Never records, captures,
    /// exercises input, performs network requests, or opens protected resources.
    func observe(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation
    func check(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation
    /// Called only within the native Continue or Retry intent.
    func setup(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation
    /// Existing explicit diagnostic/automatic-settings owner. Presentation and
    /// periodic refresh must never call this method.
    func setupAutomatically(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation
    func openLocalNetworkSettings()
    func openSettings(_ permission: DesktopPermissionID)
}

extension DesktopPermissionChecklistAdapting {
    func openLocalNetworkSettings() {}
    func openSettings(_ permission: DesktopPermissionID) {
        if permission == .localNetwork { openLocalNetworkSettings() }
    }
    func check(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        await observe(permission)
    }
    func setupAutomatically(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        await setup(permission)
    }
}

@MainActor
final class DesktopPermissionChecklistCoordinator: ObservableObject {
    @Published private(set) var rows = DesktopPermissionID.allCases.map {
        DesktopPermissionRow(id: $0, observation: .init(.checking, detail: "Checking this Mac…"))
    }
    @Published private(set) var isFinishing = false
    @Published private(set) var busyPermission: DesktopPermissionID?
    @Published private(set) var automaticBusyPermission: DesktopPermissionID?
    @Published private(set) var verificationBusyPermission: DesktopPermissionID?
    @Published private(set) var completionError = ""
    @Published private(set) var needsNewSetupRequest = false
    @Published private(set) var hasStarted = false
    @Published private(set) var browsersSkipped = false
    @Published private(set) var currentPermission: DesktopPermissionID?
    var onReady: (() -> Void)?
    var onVerified: (([DesktopPermissionID: DesktopPermissionObservation]) -> Void)?
    private var completionScheduled = false
    private var guidedTask: Task<Void, Never>?
    private var attemptedPermissions: Set<DesktopPermissionID> = []
    private let adapter: any DesktopPermissionChecklistAdapting
    private var generation = UUID()
    private var refreshTask: Task<Void, Never>?
    private var observationTask: Task<DesktopPermissionObservation, Never>?
    private var setupTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<Void, Error>?
    private var verificationKeys: [DesktopPermissionID: String] = [:]
    private var rowRevisions: [DesktopPermissionID: UUID] = [:]
    private struct SetupFailure {
        let observation: DesktopPermissionObservation
        let passiveKey: String?
        let passiveState: DesktopPermissionState
    }
    private var setupFailures: [DesktopPermissionID: SetupFailure] = [:]
    private var refreshOperationTask: Task<Void, Never>?
    private var refreshRequested = false
    private(set) var isVisible = false

    init(adapter: any DesktopPermissionChecklistAdapting) { self.adapter = adapter }

    var canFinish: Bool {
        isVisible && !isFinishing && !needsNewSetupRequest && busyPermission == nil && verificationBusyPermission == nil && DesktopPermissionReadiness(rows: rows).isReady
    }
    // A denied first request can leave the process preflight stale after the
    // user enables Screen Recording in Settings. Never repeat that capture to
    // infer approval. Offer an explicit restart and reconstruct grants instead.
    var screenRecordingNeedsRestartRecheck: Bool {
        hasStarted && currentPermission == .screenRecording && attemptedPermissions.contains(.screenRecording)
            && rows.first(where: { $0.id == .screenRecording })?.state == .notGranted
    }
    var requiresAppRestart: Bool {
        screenRecordingNeedsRestartRecheck || rows.contains { $0.isRequiredForUnlockedSetup && $0.state == .restartRequired }
    }
    var canRestart: Bool {
        isVisible && !isFinishing && !needsNewSetupRequest && busyPermission == nil
            && verificationBusyPermission == nil && automaticBusyPermission == nil && requiresAppRestart
    }
    var primaryActionTitle: String {
        if isFinishing { return "Finishing Setup…" }
        return requiresAppRestart ? "Restart PersonaStack" : hasStarted ? "Retry" : "Continue"
    }
    var operationGeneration: UUID { generation }
    var isAwaitingFinish: Bool { continuation != nil }
    var permissionRows: [DesktopPermissionRow] {
        DesktopPermissionID.setupPermissions.compactMap { id in
            rows.first { $0.id == id && !([.localNetwork, .clipboard].contains(id) && $0.state == .notNeeded) }
        }
    }

    func openLocalNetworkSettings() {
        guard isVisible, !isFinishing, busyPermission != .localNetwork else { return }
        adapter.openLocalNetworkSettings()
    }

    func openSettings(_ id: DesktopPermissionID) {
        guard isVisible, !isFinishing, busyPermission != id else { return }
        adapter.openSettings(id)
    }

    var automaticRows: [DesktopPermissionRow] {
        DesktopPermissionID.automaticSetup.compactMap { id in rows.first { $0.id == id } }
    }

    /// Presentation never authorizes a functional probe or a privacy prompt.
    func startPresentationVerification() {}
    func startAutomaticSetup() {
        guard hasStarted else { return }
        advanceGuidedSetup()
    }

    var currentStage: DesktopPermissionStage? {
        DesktopPermissionStage.allCases.first { stage in
            !(stage == .browsers && browsersSkipped) &&
                stage.permissions.contains { id in rows.first { $0.id == id }?.isComplete != true }
        }
    }

    var canSkipBrowsers: Bool {
        guard hasStarted, isVisible, !isFinishing, !needsNewSetupRequest, currentStage == .browsers else { return false }
        if let busyPermission, !DesktopPermissionStage.browsers.permissions.contains(busyPermission) { return false }
        return true
    }

    func skipBrowsers() {
        guard canSkipBrowsers else { return }
        browsersSkipped = true
        guidedTask?.cancel()
        guidedTask = nil
        setupTask?.cancel()
        setupTask = nil
        busyPermission = nil
        for id in DesktopPermissionStage.browsers.permissions { rowRevisions[id] = UUID() }
        completionError = ""
        advanceGuidedSetup()
    }

    /// The window records installed locked-control consent before this call.
    func continueSetup() {
        guard isVisible, !isFinishing, !needsNewSetupRequest, !hasStarted else { return }
        hasStarted = true
        completionError = ""
        advanceGuidedSetup()
    }

    func retryCurrentPermission() {
        guard hasStarted, let id = currentPermission, guidedTask == nil, busyPermission == nil else { return }
        attemptedPermissions.remove(id)
        advanceGuidedSetup()
    }

    /// Settings activation is part of the current explicit intent. Only the
    /// current step may run a bounded check; the periodic poll stays passive.
    func resumeAfterActivation() async {
        let expected = generation
        // Returning from browser settings can race the first permission check.
        // Wait for its result before checking the newly enabled setting.
        if currentPermission == .safariJavaScript { await guidedTask?.value }
        await refresh()
        guard generation == expected, !Task.isCancelled, hasStarted, let id = currentPermission, guidedTask == nil,
              busyPermission == nil, !isFinishing, isVisible,
              [.fullDiskAccess, .safariJavaScript, .directCapture].contains(id) else { return }
        runGuidedOperation(id, checking: id != .directCapture)
    }

    private func advanceGuidedSetup() {
        guard hasStarted, isVisible, !isFinishing, !needsNewSetupRequest,
              guidedTask == nil, busyPermission == nil else { return }
        let ordered = DesktopPermissionReadiness.guidedPermissions.filter {
            !browsersSkipped || !DesktopPermissionStage.browsers.permissions.contains($0)
        }
        guard let id = ordered.first(where: { id in rows.first { $0.id == id }?.isComplete != true }) else {
            currentPermission = nil
            if canFinish, !completionScheduled, let onReady {
                completionScheduled = true
                onReady()
            }
            return
        }
        completionScheduled = false
        currentPermission = id
        guard !attemptedPermissions.contains(id), rows.first(where: { $0.id == id })?.state != .restartRequired else { return }
        attemptedPermissions.insert(id)
        runGuidedOperation(id, checking: false)
    }

    private func runGuidedOperation(_ id: DesktopPermissionID, checking: Bool) {
        let expected = generation
        busyPermission = id
        rowRevisions[id] = UUID()
        let revision = rowRevisions[id]
        setupFailures.removeValue(forKey: id)
        guidedTask = Task { [weak self] in
            guard let self else { return }
            let value = checking ? await self.adapter.check(id) : await self.adapter.setup(id)
            guard self.generation == expected, self.isVisible, !Task.isCancelled else { return }
            let baseline = await self.failureBaseline(value, id: id)
            guard self.generation == expected, self.isVisible, !Task.isCancelled else { return }
            if self.rowRevisions[id] == revision { self.apply(value, id: id, explicit: true, failureBaseline: baseline) }
            self.busyPermission = nil
            self.guidedTask = nil
            self.advanceGuidedSetup()
        }
    }

    func open() {
        guard !isVisible else { return }
        isVisible = true
        resetObservations()
        completionError = ""
        let expected = generation
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isVisible, self.generation == expected else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func waitForFinish() async throws {
        guard continuation == nil else { throw CancellationError() }
        open()
        // Only a fresh trusted browser setup request may start enrollment again.
        // A permission refresh or repair-window Finish cannot replace that request.
        needsNewSetupRequest = false
        completionError = ""
        let expected = generation
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { self.continuation = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
                self.cancel()
            }
        }
    }

    func refresh() async {
        guard isVisible, !isFinishing, !Task.isCancelled else { return }
        // Every caller waits for current readback. A request arriving mid-pass
        // also needs one subsequent pass for rows that were already observed.
        refreshRequested = true
        let task: Task<Void, Never>
        if let current = refreshOperationTask { task = current }
        else {
            let expected = generation
            task = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.generation == expected { self.refreshOperationTask = nil }
                }
                while self.generation == expected, self.isVisible, !self.isFinishing,
                      !Task.isCancelled, self.refreshRequested {
                    self.refreshRequested = false
                    await self.refreshRows(expected: expected)
                }
            }
            refreshOperationTask = task
        }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        advanceGuidedSetup()
    }

    private func refreshRows(expected: UUID) async {
        for id in DesktopPermissionID.allCases {
            guard generation == expected, isVisible, !isFinishing, !Task.isCancelled else { return }
            // A check cannot race a deliberate functional verification.
            guard busyPermission != id else { continue }
            let revision = rowRevisions[id]
            let task = Task { await adapter.observe(id) }
            observationTask = task
            let observation = await withTaskCancellationHandler {
                await task.value
            } onCancel: { task.cancel() }
            if generation == expected { observationTask = nil }
            guard generation == expected, isVisible, !isFinishing, !task.isCancelled,
                  busyPermission != id,
                  rowRevisions[id] == revision else { continue }
            apply(observation, id: id, explicit: false)

        }
    }

    func setup(_ id: DesktopPermissionID) {
        perform(id, requesting: true)
    }

    func check(_ id: DesktopPermissionID) {
        perform(id, requesting: false)
    }

    private func perform(_ id: DesktopPermissionID, requesting: Bool) {
        guard isVisible, !isFinishing, guidedTask == nil, busyPermission == nil, verificationBusyPermission != id,
              !(DesktopPermissionID.automaticSetup.contains(id) && automaticBusyPermission != nil) else { return }
        rowRevisions[id] = UUID()
        setupFailures.removeValue(forKey: id)
        busyPermission = id
        let expected = generation
        let revision = rowRevisions[id]
        setupTask = Task { [weak self] in
            guard let self, self.generation == expected, self.isVisible, !Task.isCancelled else { return }
            guard self.generation == expected, self.isVisible, !Task.isCancelled else { return }
            let observation = requesting ? await self.adapter.setup(id) : await self.adapter.check(id)
            guard self.generation == expected, self.isVisible, !Task.isCancelled else { return }
            if self.rowRevisions[id] == revision {
                let baseline = await self.failureBaseline(observation, id: id)
                guard self.generation == expected, self.isVisible, !Task.isCancelled else { return }
                if self.rowRevisions[id] == revision { self.apply(observation, id: id, explicit: true, failureBaseline: baseline) }
            }
            self.busyPermission = nil
            self.setupTask = nil
            await self.refresh()
        }
    }

    func finish() {
        guard canFinish else { return }
        isFinishing = true
        refreshRequested = false
        refreshOperationTask?.cancel()
        observationTask?.cancel()
        observationTask = nil
        setupTask?.cancel()
        setupTask = nil
        busyPermission = nil
        automaticBusyPermission = nil
        completionError = ""
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    func reportSetupPrerequisite(_ message: String) {
        guard isVisible, !isFinishing else { return }
        completionError = message
    }

    func failSetup(_ message: String) {
        guard isVisible else { return }
        isFinishing = false
        completionScheduled = false
        needsNewSetupRequest = true
        completionError = "\(message) Return to the Desktop Control page to retry setup."
        Task { await refresh() }
    }

    func cancel() {
        generation = UUID()
        guidedTask?.cancel()
        guidedTask = nil
        hasStarted = false
        browsersSkipped = false
        completionScheduled = false
        currentPermission = nil
        attemptedPermissions.removeAll()
        refreshTask?.cancel()
        refreshOperationTask?.cancel()
        refreshOperationTask = nil
        refreshRequested = false
        observationTask?.cancel()
        observationTask = nil
        setupTask?.cancel()
        refreshTask = nil
        setupTask = nil
        isVisible = false
        isFinishing = false
        needsNewSetupRequest = false
        busyPermission = nil
        automaticBusyPermission = nil
        verificationKeys.removeAll()
        setupFailures.removeAll()
        rowRevisions.removeAll()
        resetObservations()
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
    }

    private func resetObservations() {
        rows = DesktopPermissionID.allCases.map {
            .init(id: $0, observation: .init(.checking, detail: "Checking this Mac…"))
        }
    }

    func invalidateVerification(_ id: DesktopPermissionID) {
        rowRevisions[id] = UUID()
        verificationKeys.removeValue(forKey: id)
        setupFailures.removeValue(forKey: id)
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].observation = .init(.verificationRequired, detail: "Use Setup \(id.title) to verify access again.")
    }

    private static func isSetupFailure(_ value: DesktopPermissionObservation) -> Bool {
        [.failed, .restartRequired, .verificationRequired, .denied, .restricted, .unsupported].contains(value.state)
    }

    private func failureBaseline(_ value: DesktopPermissionObservation, id: DesktopPermissionID) async -> DesktopPermissionObservation? {
        guard Self.isSetupFailure(value) else { return nil }
        // Capture the grant after Setup's prompt or operation, before the busy
        // row completes. A later changed grant cannot anchor an earlier failure.
        return await adapter.observe(id)
    }

    private func retainedSetupFailure(_ value: DesktopPermissionObservation, id: DesktopPermissionID,
                                      explicit: Bool, baseline: DesktopPermissionObservation?) -> DesktopPermissionObservation? {
        if explicit, Self.isSetupFailure(value), let baseline {
            setupFailures[id] = SetupFailure(observation: value, passiveKey: baseline.verificationKey,
                                            passiveState: baseline.state)
        } else if !explicit, let failure = setupFailures[id] {
            let incomplete = !value.state.satisfiesSetup || (value.requiresVerification && !value.verified)
            if incomplete, value.state == failure.passiveState, value.verificationKey == failure.passiveKey {
                return failure.observation
            }
            setupFailures.removeValue(forKey: id)
        }
        return nil
    }

    private func apply(_ value: DesktopPermissionObservation, id: DesktopPermissionID, explicit: Bool,
                       failureBaseline: DesktopPermissionObservation? = nil) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        if let failure = retainedSetupFailure(value, id: id, explicit: explicit, baseline: failureBaseline) {
            rows[index].observation = failure
            return
        }
        if value.state != .ready || verificationKeys[id] != value.verificationKey {
            verificationKeys.removeValue(forKey: id)
        }
        if explicit, value.state == .ready, value.verified, let key = value.verificationKey {
            verificationKeys[id] = key
        }
        let verified = value.verified || (value.verificationKey != nil && verificationKeys[id] == value.verificationKey)
        let previous = rows[index].observation
        let detail = !explicit && verified && !value.verified && previous.verified &&
            previous.verificationKey == value.verificationKey ? previous.detail : value.detail
        rows[index].observation = .init(value.state, detail: detail, verificationKey: value.verificationKey,
                                        requiresVerification: value.requiresVerification, verified: verified)
        if explicit {
            onVerified?(Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.observation) }))
        }
    }
}
