import Foundation
import Combine
import PersonaStackCore

@MainActor
protocol DesktopPermissionChecklistAdapting {
    /// Reads current grants and refreshes explicitly authorized disk/network checks.
    /// Never records audio, captures, exercises input, or starts an initial privacy check.
    func observe(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation
    /// Called only by an explicit native Setup or Retry button.
    func setup(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation
    /// Runs only on native presentation: verifies existing core grants without
    /// requesting them, or performs the established automatic-settings policy.
    func setupAutomatically(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation
}

extension DesktopPermissionChecklistAdapting {
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
    private let adapter: any DesktopPermissionChecklistAdapting
    private var generation = UUID()
    private var refreshTask: Task<Void, Never>?
    private var observationTask: Task<DesktopPermissionObservation, Never>?
    private var setupTask: Task<Void, Never>?
    private var automaticSetupTask: Task<Void, Never>?
    private var automaticSetupStarted = false
    private var presentationVerificationTask: Task<Void, Never>?
    private var presentationOperationTask: Task<DesktopPermissionObservation, Never>?
    private var presentationVerificationStarted = false
    private var pendingPresentationRows: Set<DesktopPermissionID> = []
    private var manuallyCheckedRows: Set<DesktopPermissionID> = []
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
        isVisible && !isFinishing && !needsNewSetupRequest && busyPermission != .accessibility && verificationBusyPermission != .accessibility && rows.filter(\.isRequiredForUnlockedSetup).allSatisfy(\.isComplete)
    }
    var isAwaitingFinish: Bool { continuation != nil }
    var permissionRows: [DesktopPermissionRow] {
        DesktopPermissionID.setupPermissions.compactMap { id in
            rows.first { $0.id == id && !(id == .localNetwork && $0.state == .notNeeded) }
        }
    }
    var automaticRows: [DesktopPermissionRow] {
        DesktopPermissionID.automaticSetup.compactMap { id in rows.first { $0.id == id } }
    }

    /// One functional verification pass belongs to each native presentation.
    /// Polling and activation never start this pass again.
    func startPresentationVerification() {
        guard isVisible, !isFinishing, !presentationVerificationStarted else { return }
        presentationVerificationStarted = true
        pendingPresentationRows = Set(DesktopPermissionID.setupPermissions)
        verificationBusyPermission = .accessibility
        let expected = generation
        presentationVerificationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == expected {
                    self.verificationBusyPermission = nil
                    self.presentationOperationTask = nil
                    self.presentationVerificationTask = nil
                    self.pendingPresentationRows.removeAll()
                }
            }
            for id in DesktopPermissionID.setupPermissions {
                guard self.generation == expected, self.isVisible, !self.isFinishing, !Task.isCancelled else { return }
                guard !self.manuallyCheckedRows.contains(id), self.busyPermission != id else {
                    self.pendingPresentationRows.remove(id)
                    continue
                }
                self.verificationBusyPermission = id
                self.rowRevisions[id] = UUID()
                let revision = self.rowRevisions[id]
                self.setupFailures.removeValue(forKey: id)
                let operation = Task { await self.adapter.setupAutomatically(id) }
                self.presentationOperationTask = operation
                let value = await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
                guard self.generation == expected, self.isVisible, !self.isFinishing, !Task.isCancelled else { return }
                guard !operation.isCancelled, self.rowRevisions[id] == revision else {
                    self.pendingPresentationRows.remove(id)
                    continue
                }
                let baseline = await self.failureBaseline(value, id: id)
                guard self.generation == expected, self.isVisible, !self.isFinishing, !Task.isCancelled else { return }
                if self.rowRevisions[id] == revision { self.apply(value, id: id, explicit: true, failureBaseline: baseline) }
                self.pendingPresentationRows.remove(id)
            }
        }
    }

    func startAutomaticSetup() {
        guard isVisible, !automaticSetupStarted, busyPermission == nil, !isFinishing else { return }
        automaticSetupStarted = true
        let expected = generation
        automaticBusyPermission = DesktopPermissionID.automaticSetup.first
        automaticSetupTask = Task { [weak self] in
            guard let self else { return }
            for id in DesktopPermissionID.automaticSetup {
                guard self.generation == expected, self.isVisible, !Task.isCancelled else { return }
                self.automaticBusyPermission = id
                self.rowRevisions[id] = UUID()
                let revision = self.rowRevisions[id]
                let current = await self.adapter.observe(id)
                guard self.generation == expected, self.isVisible, !Task.isCancelled else { return }
                let value = DesktopPermissionRow(id: id, observation: current).isComplete
                    ? current : await self.adapter.setupAutomatically(id)
                guard self.generation == expected, self.isVisible, !Task.isCancelled else { return }
                if self.rowRevisions[id] == revision {
                    let baseline = await self.failureBaseline(value, id: id)
                    guard self.generation == expected, self.isVisible, !Task.isCancelled else { return }
                    if self.rowRevisions[id] == revision { self.apply(value, id: id, explicit: true, failureBaseline: baseline) }
                }
            }
            self.automaticBusyPermission = nil
            self.automaticSetupTask = nil
            await self.refresh()
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
    }

    private func refreshRows(expected: UUID) async {
        for id in DesktopPermissionID.allCases {
            guard generation == expected, isVisible, !isFinishing, !Task.isCancelled else { return }
            // A check cannot race a deliberate functional verification.
            guard busyPermission != id, automaticBusyPermission != id, !pendingPresentationRows.contains(id) else { continue }
            let revision = rowRevisions[id]
            let task = Task { await adapter.observe(id) }
            observationTask = task
            let observation = await withTaskCancellationHandler {
                await task.value
            } onCancel: { task.cancel() }
            if generation == expected { observationTask = nil }
            guard generation == expected, isVisible, !isFinishing, !task.isCancelled,
                  busyPermission != id, automaticBusyPermission != id, !pendingPresentationRows.contains(id),
                  rowRevisions[id] == revision else { continue }
            apply(observation, id: id, explicit: false)
        }
    }

    func setup(_ id: DesktopPermissionID) {
        guard isVisible, !isFinishing, busyPermission == nil, verificationBusyPermission != id,
              !(DesktopPermissionID.automaticSetup.contains(id) && automaticBusyPermission != nil) else { return }
        manuallyCheckedRows.insert(id)
        pendingPresentationRows.remove(id)
        let pendingCuaCheck: Task<DesktopPermissionObservation, Never>?
        if [.accessibility, .screenRecording, .directCapture].contains(id),
           let current = verificationBusyPermission, [.accessibility, .screenRecording, .directCapture].contains(current) {
            pendingCuaCheck = presentationOperationTask
            pendingCuaCheck?.cancel()
            invalidateVerification(current)
        } else { pendingCuaCheck = nil }
        rowRevisions[id] = UUID()
        setupFailures.removeValue(forKey: id)
        busyPermission = id
        let expected = generation
        let revision = rowRevisions[id]
        setupTask = Task { [weak self] in
            guard let self, self.generation == expected, self.isVisible, !Task.isCancelled else { return }
            if let pendingCuaCheck { _ = await pendingCuaCheck.value }
            guard self.generation == expected, self.isVisible, !Task.isCancelled else { return }
            let observation = await self.adapter.setup(id)
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
        cancelPresentationVerification()
        refreshRequested = false
        refreshOperationTask?.cancel()
        observationTask?.cancel()
        observationTask = nil
        setupTask?.cancel()
        setupTask = nil
        busyPermission = nil
        automaticSetupTask?.cancel()
        automaticSetupTask = nil
        automaticBusyPermission = nil
        completionError = ""
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    func failSetup(_ message: String) {
        guard isVisible else { return }
        isFinishing = false
        needsNewSetupRequest = true
        completionError = "\(message) Return to the Desktop Control page to retry setup."
        Task { await refresh() }
    }

    func cancel() {
        generation = UUID()
        cancelPresentationVerification()
        presentationVerificationStarted = false
        manuallyCheckedRows.removeAll()
        refreshTask?.cancel()
        refreshOperationTask?.cancel()
        refreshOperationTask = nil
        refreshRequested = false
        observationTask?.cancel()
        observationTask = nil
        setupTask?.cancel()
        automaticSetupTask?.cancel()
        refreshTask = nil
        setupTask = nil
        automaticSetupTask = nil
        automaticSetupStarted = false
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

    private func cancelPresentationVerification() {
        presentationVerificationTask?.cancel()
        presentationOperationTask?.cancel()
        presentationVerificationTask = nil
        presentationOperationTask = nil
        verificationBusyPermission = nil
        pendingPresentationRows.removeAll()
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
    }
}
