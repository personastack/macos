import Foundation
import Combine
import PersonaStackCore

@MainActor
protocol DesktopPermissionChecklistAdapting {
    /// Never prompts, captures, exercises input, or touches protected files.
    func observe(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation
    /// Called only by an explicit native Setup button.
    func setup(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation
}

@MainActor
final class DesktopPermissionChecklistCoordinator: ObservableObject {
    @Published private(set) var rows = DesktopPermissionID.allCases.map {
        DesktopPermissionRow(id: $0, observation: .init(.checking, detail: "Checking this Mac…"))
    }
    @Published private(set) var isFinishing = false
    @Published private(set) var busyPermission: DesktopPermissionID?
    @Published private(set) var completionError = ""
    @Published private(set) var needsNewSetupRequest = false
    private let adapter: any DesktopPermissionChecklistAdapting
    private var generation = UUID()
    private var refreshTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<Void, Error>?
    private var verificationKeys: [DesktopPermissionID: String] = [:]
    private var refreshing = false
    private var refreshedForCurrentPresentation = false
    private(set) var isVisible = false

    init(adapter: any DesktopPermissionChecklistAdapting) { self.adapter = adapter }

    var canFinish: Bool {
        isVisible && refreshedForCurrentPresentation && !isFinishing && !needsNewSetupRequest && busyPermission == nil && rows.allSatisfy(\.isComplete)
    }
    var isAwaitingFinish: Bool { continuation != nil }

    func open() {
        guard !isVisible else { return }
        isVisible = true
        refreshedForCurrentPresentation = false
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
            guard busyPermission != id else { continue }
            let observation = await adapter.observe(id)
            guard generation == expected, isVisible, busyPermission != id else { continue }
            apply(observation, id: id, explicit: false)
        }
        if generation == expected, isVisible, !Task.isCancelled { refreshedForCurrentPresentation = true }
    }

    func setup(_ id: DesktopPermissionID) {
        guard isVisible, !isFinishing, busyPermission == nil else { return }
        busyPermission = id
        let expected = generation
        setupTask = Task { [weak self] in
            guard let self, self.generation == expected, self.isVisible, !Task.isCancelled else { return }
            let observation = await self.adapter.setup(id)
            guard self.generation == expected, self.isVisible, !Task.isCancelled else { return }
            self.apply(observation, id: id, explicit: true)
            self.busyPermission = nil
            self.setupTask = nil
            await self.refresh()
        }
    }

    func finish() {
        guard canFinish else { return }
        isFinishing = true
        completionError = ""
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    func failSetup(_ message: String) {
        guard isVisible else { return }
        isFinishing = false
        needsNewSetupRequest = true
        completionError = "\(message) Click Set Up Permissions on the Desktop Control page to retry."
        Task { await refresh() }
    }

    func cancel() {
        generation = UUID()
        refreshTask?.cancel()
        setupTask?.cancel()
        refreshTask = nil
        setupTask = nil
        isVisible = false
        refreshing = false
        isFinishing = false
        needsNewSetupRequest = false
        busyPermission = nil
        verificationKeys.removeAll()
        refreshedForCurrentPresentation = false
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

    private func apply(_ value: DesktopPermissionObservation, id: DesktopPermissionID, explicit: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        if value.state != .ready { verificationKeys.removeValue(forKey: id) }
        if explicit, value.state == .ready, value.verified, let key = value.verificationKey {
            verificationKeys[id] = key
        }
        let verified = value.verified || (value.verificationKey != nil && verificationKeys[id] == value.verificationKey)
        rows[index].observation = .init(value.state, detail: value.detail, verificationKey: value.verificationKey,
                                        requiresVerification: value.requiresVerification, verified: verified)
    }
}
