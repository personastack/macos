import Foundation
import Combine
import PersonaStackCore

@MainActor
protocol DesktopPermissionChecklistAdapting {
    /// Never prompts, captures, exercises input, or touches protected files.
    func observe(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation
    /// Called only by an explicit native Setup or Retry button.
    func setup(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation
    /// Runs only when the user opens the native setup window.
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
    @Published private(set) var completionError = ""
    @Published private(set) var needsNewSetupRequest = false
    private let adapter: any DesktopPermissionChecklistAdapting
    private var generation = UUID()
    private var refreshTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var automaticSetupTask: Task<Void, Never>?
    private var automaticSetupStarted = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var verificationKeys: [DesktopPermissionID: String] = [:]
    private var rowRevisions: [DesktopPermissionID: UUID] = [:]
    private struct SetupFailure {
        let observation: DesktopPermissionObservation
        var passiveKey: String?
        var passiveState: DesktopPermissionState?
        var anchored = false
    }
    private var setupFailures: [DesktopPermissionID: SetupFailure] = [:]
    private var refreshing = false
    private(set) var isVisible = false

    init(adapter: any DesktopPermissionChecklistAdapting) { self.adapter = adapter }

    var canFinish: Bool {
        isVisible && !isFinishing && !needsNewSetupRequest && busyPermission != .accessibility && rows.filter(\.isRequiredForUnlockedSetup).allSatisfy(\.isComplete)
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
                if self.rowRevisions[id] == revision { self.apply(value, id: id, explicit: true) }
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
        guard isVisible, !isFinishing, !refreshing else { return }
        refreshing = true
        let expected = generation
        defer { if generation == expected { refreshing = false } }
        for id in DesktopPermissionID.allCases {
            guard generation == expected, isVisible, !Task.isCancelled else { return }
            // A check cannot race a deliberate functional verification.
            guard busyPermission != id, automaticBusyPermission != id else { continue }
            let revision = rowRevisions[id]
            let observation = await adapter.observe(id)
            guard generation == expected, isVisible, busyPermission != id, automaticBusyPermission != id,
                  rowRevisions[id] == revision else { continue }
            apply(observation, id: id, explicit: false)
        }
    }

    func setup(_ id: DesktopPermissionID) {
        guard isVisible, !isFinishing, busyPermission == nil,
              !(DesktopPermissionID.automaticSetup.contains(id) && automaticBusyPermission != nil) else { return }
        rowRevisions[id] = UUID()
        setupFailures.removeValue(forKey: id)
        busyPermission = id
        let expected = generation
        let revision = rowRevisions[id]
        setupTask = Task { [weak self] in
            guard let self, self.generation == expected, self.isVisible, !Task.isCancelled else { return }
            let observation = await self.adapter.setup(id)
            guard self.generation == expected, self.isVisible, !Task.isCancelled else { return }
            if self.rowRevisions[id] == revision {
                self.apply(observation, id: id, explicit: true)
            }
            self.busyPermission = nil
            self.setupTask = nil
            await self.refresh()
        }
    }

    func finish() {
        guard canFinish else { return }
        isFinishing = true
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
        refreshTask?.cancel()
        setupTask?.cancel()
        automaticSetupTask?.cancel()
        refreshTask = nil
        setupTask = nil
        automaticSetupTask = nil
        automaticSetupStarted = false
        isVisible = false
        refreshing = false
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

    private func retainedSetupFailure(_ value: DesktopPermissionObservation, id: DesktopPermissionID,
                                      explicit: Bool) -> DesktopPermissionObservation? {
        if explicit, [.failed, .restartRequired, .verificationRequired, .denied, .restricted, .unsupported].contains(value.state) {
            setupFailures[id] = SetupFailure(observation: value)
        } else if !explicit, var failure = setupFailures[id] {
            if !failure.anchored {
                failure.passiveKey = value.verificationKey
                failure.passiveState = value.state
                failure.anchored = true
            }
            let incomplete = !value.state.satisfiesSetup || (value.requiresVerification && !value.verified)
            if incomplete, value.state == failure.passiveState, value.verificationKey == failure.passiveKey {
                setupFailures[id] = failure
                return failure.observation
            }
            setupFailures.removeValue(forKey: id)
        }
        return nil
    }

    private func apply(_ value: DesktopPermissionObservation, id: DesktopPermissionID, explicit: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        if let failure = retainedSetupFailure(value, id: id, explicit: explicit) {
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
