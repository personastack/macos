import AppKit
import SwiftUI
import PersonaStackCore

/// One local handoff to the upstream installer and permission commands.
/// This window never requests PersonaStack desktop permissions.
@MainActor
final class CuaSetupWindow: NSObject, DesktopControlPermissionPresenting, NSWindowDelegate {
    static let shared = CuaSetupWindow()
    var onCancel: (() -> Void)?
    private var window: NSWindow?
    private let model = CuaSetupModel()
    private var completion: CheckedContinuation<Void, Error>?
    private var presentationID = UUID()
    private(set) var isFinishing = false

    func presentForSetup() async throws {
        guard completion == nil, !isFinishing, !model.busy else { throw CuaSetupError.busy }
        let requestID = UUID()
        presentationID = requestID
        isFinishing = false
        model.reset(connecting: true)
        show()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { completion = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.presentationID == requestID else { return }
                self.cancel()
            }
        }
    }

    func presentForRepair() {
        guard completion == nil, !isFinishing, !model.busy else {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        presentationID = UUID()
        isFinishing = false
        model.reset(connecting: false)
        show()
    }

    private func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Set Up CUA"
            window.isReleasedWhenClosed = false
            window.delegate = self
            let hosting = NSHostingView(rootView: CuaSetupView(model: model, finish: { [weak self] in
                self?.finish()
            }, cancel: { [weak self] in self?.userCancel() }, returnToConnection: { [weak self] in
                self?.window?.orderOut(nil)
                self?.model.cancel()
            }))
            hosting.sizingOptions = []
            window.contentView = hosting
            window.contentMinSize = NSSize(width: 440, height: 400)
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.refresh()
    }

    private func finish() {
        guard model.ready, !model.busy, !model.connectingToCloud, !isFinishing else { return }
        model.verifyForFinish { [weak self] in self?.finishVerified() }
    }

    private func finishVerified() {
        if let completion {
            isFinishing = true
            model.beginConnection()
            self.completion = nil
            completion.resume()
        } else if model.connecting {
            model.failConnection("Return to Desktop Control to check the connection result and continue setup.")
        } else {
            window?.orderOut(nil)
        }
    }

    func completeSetup() {
        presentationID = UUID()
        isFinishing = false
        model.cancel()
        window?.orderOut(nil)
    }

    func failSetup(message: String) {
        presentationID = UUID()
        isFinishing = false
        model.failConnection(message)
    }

    func cancel() {
        presentationID = UUID()
        model.cancel()
        isFinishing = false
        let pending = completion
        completion = nil
        pending?.resume(throwing: CancellationError())
        window?.orderOut(nil)
    }

    private func userCancel() {
        cancel()
        onCancel?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        userCancel()
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refresh()
    }
}

private enum CuaSetupError: LocalizedError {
    case busy
    var errorDescription: String? { "CUA setup is already open." }
}

@MainActor
final class CuaSetupModel: ObservableObject {
    struct Operations {
        var observe: () async throws -> CuaSetupReadiness
        var install: (CuaInstallProgress) async throws -> Void
        var permissions: () async throws -> Void
        static var live: Self {
            .init(observe: { try await DesktopControlRuntime.shared.observeCuaForSetup() },
                  install: { try await DesktopControlRuntime.shared.installCuaForSetup(progress: $0) },
                  permissions: { try await DesktopControlRuntime.shared.requestCuaPermissionsForSetup() })
        }
    }
    enum Feedback { case information, working, success, failure }
    enum Action: Equatable { case refresh, install, permissions, check, finish }
    enum Intent { case repair, connection, connectionRecovery }
    enum Activity: Equatable { case idle, running(Action), connecting }
    enum Outcome: Equatable { case none, failure(String, recovery: PrimaryAction? = nil) }
    enum PrimaryAction: Equatable {
        case install, start, permissions, check, finish, returnToConnection
    }

    @Published private(set) var observation = CuaSetupReadiness.unknown
    @Published private(set) var activity = Activity.idle
    @Published private(set) var outcome = Outcome.none
    @Published private(set) var intent = Intent.repair
    @Published private(set) var installStage: CuaInstallStage?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let operations: Operations

    init(operations: Operations = .live) { self.operations = operations }

    var installed: Bool { observation.installed }
    var ready: Bool { observation == .ready }
    var busy: Bool { if case .running = activity { true } else { false } }
    var connecting: Bool { intent == .connection }
    var connectingToCloud: Bool { activity == .connecting }
    var feedback: Feedback {
        if activity != .idle { return .working }
        if case .failure = outcome { return .failure }
        if case .unavailable = observation { return .failure }
        return ready ? .success : .information
    }
    var operation: String? {
        if activity == .connecting { return "Connecting PersonaStack" }
        guard case .running(let action) = activity else { return nil }
        switch action {
        case .refresh, .check, .finish: return "Checking CUA"
        case .permissions: return "Requesting CUA permissions"
        case .install: return installStage?.rawValue ?? (installed ? "Starting CUA" : "Installing CUA")
        }
    }
    var message: String {
        if activity == .connecting { return "CUA is ready. Connecting this Mac to PersonaStack…" }
        if activity == .running(.refresh), case .failure(let reason, _) = outcome { return reason }
        if case .running(.permissions) = activity {
            return "Allow CUA in the macOS prompts or System Settings. This can take a few minutes. You can cancel and return later."
        }
        if case .running(.install) = activity, installStage == .downloading {
            return "Downloading the signed CUA release. This may take a few minutes."
        }
        if let operation { return operation + "…" }
        if case .failure(let reason, _) = outcome { return reason }
        return observation.message
    }
    var nextStep: String? {
        guard activity == .idle, case .failure = outcome, intent != .connectionRecovery,
              message != observation.message else { return nil }
        return observation.message
    }
    var primaryAction: PrimaryAction {
        if intent == .connectionRecovery { return .returnToConnection }
        if case .failure(_, let recovery?) = outcome { return recovery }
        switch observation {
        case .absent: return .install
        case .stopped: return .start
        case .permissions: return .permissions
        case .ready: return .finish
        case .unknown, .installed, .unavailable: return .check
        }
    }
    var primaryLabel: String {
        switch primaryAction {
        case .install: return feedback == .failure ? "Retry Install" : "Install CUA"
        case .start: return feedback == .failure ? "Retry Start" : "Start CUA"
        case .permissions: return "Grant CUA Permissions"
        case .check: return "Check Again"
        case .finish: return connecting ? "Connect PersonaStack" : "Done"
        case .returnToConnection: return "Return to Connection"
        }
    }

    func reset(connecting: Bool) {
        cancel()
        intent = connecting ? .connection : .repair
        observation = .unknown
        outcome = .none
    }
    func refresh() { run(.refresh) }
    func install() { run(.install) }
    func permissions() { run(.permissions) }
    func check() { run(.check) }
    func verifyForFinish(_ onReady: @escaping @MainActor () -> Void) { run(.finish, onReady: onReady) }

    func beginConnection() {
        activity = .connecting
        outcome = .none
    }
    func failConnection(_ message: String) {
        cancel()
        intent = .connectionRecovery
        outcome = .failure(message.isEmpty ? "Connection result could not be confirmed. Return to Desktop Control and check again." : message)
    }

    private func run(_ action: Action, onReady: (@MainActor () -> Void)? = nil) {
        guard activity == .idle, intent != .connectionRecovery else { return }
        let previousOutcome = outcome
        activity = .running(action)
        if action != .refresh { outcome = .none }
        installStage = nil
        // Readiness cannot authorize Finish again while this observation is pending.
        if observation == .ready { observation = .installed }
        let current = generation
        task = Task { @MainActor [weak self, operations] in
            var failure: Error?
            do {
                try Task.checkCancellation()
                switch action {
                case .install:
                    try await operations.install { [weak self] stage in
                        await self?.showInstallProgress(stage, generation: current)
                    }
                case .permissions: try await operations.permissions()
                default: break
                }
            } catch { failure = error }
            guard let self, self.generation == current else { return }
            // Do not use a cancelled handoff as evidence that permissions were denied.
            if Task.isCancelled {
                self.settleCancellation(generation: current)
                return
            }
            do {
                let observed = try await operations.observe()
                guard self.generation == current else { return }
                try Task.checkCancellation()
                self.observation = observed
                self.activity = .idle
                self.installStage = nil
                self.task = nil
                if let failure {
                    self.outcome = Self.failureOutcome(failure)
                } else if action == .refresh {
                    self.outcome = previousOutcome
                } else if case .unavailable(_, let reason) = observed {
                    self.outcome = .failure(reason)
                } else {
                    self.outcome = .none
                }
                if action == .finish, observed == .ready, failure == nil { onReady?() }
            } catch {
                guard self.generation == current else { return }
                self.activity = .idle
                self.installStage = nil
                self.task = nil
                let reason = error is CancellationError
                    ? "CUA check was interrupted. Check again to continue."
                    : DesktopControlRuntime.cuaSetupFailureMessage(failure ?? error)
                self.observation = .unavailable(installed: self.installed, message: reason)
                if action == .refresh, case .failure = previousOutcome {
                    self.outcome = previousOutcome
                } else {
                    self.outcome = .failure(reason)
                }
            }
        }
    }

    private static func failureOutcome(_ error: Error) -> Outcome {
        if error is CancellationError { return .failure("CUA setup was interrupted. Check again to continue.") }
        let manual: Bool
        switch error {
        case CuaStandaloneServiceError.serviceDisabled, CuaStandaloneServiceError.configurationFailed,
             CuaStandaloneServiceError.startTimedOut, CuaStandaloneServiceError.permissionTimedOut,
             CuaMCPProxyError.serviceMismatch, CuaDriverInstallError.installationNotWritable,
             CuaDriverInstallError.incompatibleRuntime, CuaDriverInstallError.invalidSignature,
             CuaDriverInstallError.invalidLayout:
            manual = true
        default: manual = false
        }
        return .failure(DesktopControlRuntime.cuaSetupFailureMessage(error), recovery: manual ? .check : nil)
    }

    private func settleCancellation(generation: UUID) {
        guard self.generation == generation else { return }
        activity = .idle
        installStage = nil
        task = nil
        outcome = .failure("CUA setup was interrupted. Check again to continue.")
    }
    private func showInstallProgress(_ stage: CuaInstallStage, generation: UUID) {
        guard self.generation == generation, activity == .running(.install), !Task.isCancelled else { return }
        installStage = stage
        if stage == .installed { observation = .installed }
    }
    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        activity = .idle
        installStage = nil
    }
    func waitForOperation() async { await task?.value }
}

private struct CuaSetupView: View {
    @ObservedObject var model: CuaSetupModel
    @Environment(\.openWindow) private var openWindow
    let finish: () -> Void
    let cancel: () -> Void
    let returnToConnection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set Up CUA").font(.title2).bold()
            Text("CUA controls this Mac. PersonaStack connects your agents to CUA.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    feedbackPanel
                    if model.installed {
                        Label("CUA is installed", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    if let nextStep = model.nextStep {
                        Text(nextStep).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.primaryLabel, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.connectingToCloud)
            }
        }
        .padding(24)
        .frame(minWidth: 392, maxWidth: .infinity, minHeight: 352, maxHeight: .infinity)
    }

    private func primaryAction() {
        switch model.primaryAction {
        case .install, .start: model.install()
        case .permissions: model.permissions()
        case .check: model.check()
        case .finish: finish()
        case .returnToConnection:
            returnToConnection()
            MainWebViewHost.showMainWindow { openWindow(id: "personastack-main") }
        }
    }

    private var feedbackPanel: some View {
        HStack(alignment: .top, spacing: 12) {
            if model.busy || model.connectingToCloud {
                ProgressView().controlSize(.small).padding(.top, 3)
            } else {
                Image(systemName: model.feedback == .success ? "checkmark.circle.fill" :
                        model.feedback == .failure ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.title2)
                    .foregroundStyle(feedbackColor)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(model.operation.map { $0 + "…" } ??
                     (model.intent == .connectionRecovery ? "Connection needs attention" :
                        model.feedback == .success ? "CUA is ready" :
                        model.feedback == .failure ? "CUA needs attention" : "Next step"))
                    .font(.headline)
                Text(model.message).font(.body).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(feedbackColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(feedbackColor.opacity(0.5)))
        .accessibilityElement(children: .combine)
    }

    private var feedbackColor: Color {
        switch model.feedback {
        case .success: .green
        case .failure: .orange
        case .working: .accentColor
        case .information: .secondary
        }
    }
}
