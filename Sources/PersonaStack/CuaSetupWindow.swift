import AppKit
import SwiftUI

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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Set Up CUA"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: CuaSetupView(model: model, finish: { [weak self] in
                self?.finish()
            }, cancel: { [weak self] in self?.userCancel() }))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.refresh()
    }

    private func finish() {
        guard model.ready, !model.busy, !model.connectingToCloud, !isFinishing else { return }
        if let completion {
            isFinishing = true
            model.connectingToCloud = true
            self.completion = nil
            completion.resume()
        } else {
            window?.orderOut(nil)
        }
    }

    func completeSetup() {
        presentationID = UUID()
        isFinishing = false
        model.connectingToCloud = false
        window?.orderOut(nil)
    }

    func failSetup(message: String) {
        presentationID = UUID()
        isFinishing = false
        model.connectingToCloud = false
        model.message = message
        model.ready = false
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
}

private enum CuaSetupError: LocalizedError {
    case busy
    var errorDescription: String? { "CUA setup is already open." }
}

@MainActor
final class CuaSetupModel: ObservableObject {
    struct Operations {
        var installed: () async throws -> Bool
        var install: () async throws -> Void
        var permissions: () async throws -> Void
        var check: () async throws -> Void
        static var live: Self {
            .init(installed: { try await DesktopControlRuntime.shared.cuaInstalledForSetup() },
                  install: { try await DesktopControlRuntime.shared.installCuaForSetup() },
                  permissions: { try await DesktopControlRuntime.shared.requestCuaPermissionsForSetup() },
                  check: { try await DesktopControlRuntime.shared.checkCuaConnectionForSetup() })
        }
    }
    @Published var installed = false
    @Published var busy = false
    @Published var ready = false
    @Published var connecting = false
    @Published var connectingToCloud = false
    @Published var message = ""
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let operations: Operations

    init(operations: Operations = .live) { self.operations = operations }

    func reset(connecting: Bool) {
        cancel()
        self.connecting = connecting
        installed = false
        ready = false
        message = ""
    }

    func refresh() {
        run { [operations] in
            let installed = try await operations.installed()
            return (installed, false, installed ? "CUA is installed. Complete its setup or check the connection." : "Install CUA to control this Mac.")
        }
    }

    func install() {
        run { [operations] in
            try await operations.install()
            return (true, false, "CUA is installed and started. Continue with CUA's permission setup.")
        }
    }

    func permissions() {
        run { [operations] in
            try await operations.permissions()
            return (true, false, "Complete CUA's macOS prompts, then check the connection.")
        }
    }

    func check() {
        run { [operations] in
            try await operations.check()
            return (true, true, "CUA is ready for PersonaStack to connect.")
        }
    }

    private func run(_ action: @escaping () async throws -> (Bool, Bool, String)) {
        guard !busy, !connectingToCloud else { return }
        busy = true
        ready = false
        let generation = self.generation
        task = Task { @MainActor [weak self] in
            do {
                let result = try await action()
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.installed = result.0
                self.ready = result.1
                self.message = result.2
                self.busy = false
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.message = (error as? LocalizedError)?.errorDescription ?? "CUA could not complete this step. Check its installation and try again."
                self.busy = false
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        busy = false
        connectingToCloud = false
    }

    func waitForOperation() async { await task?.value }
}

private struct CuaSetupView: View {
    @ObservedObject var model: CuaSetupModel
    let finish: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Desktop Control with CUA").font(.title2).bold()
            Text("CUA controls this Mac. PersonaStack connects your agents to CUA. CUA remains installed if you remove PersonaStack.")
                .foregroundStyle(.secondary)
            HStack {
                Text("1. Install CUA").fontWeight(.medium)
                Spacer()
                Button(model.installed ? "Start CUA" : "Install CUA") { model.install() }
                    .disabled(model.busy || model.connectingToCloud)
            }
            HStack {
                Text("2. Complete CUA Setup").fontWeight(.medium)
                Spacer()
                Button("Open CUA Permission Setup") { model.permissions() }.disabled(!model.installed || model.busy || model.connectingToCloud)
            }
            HStack {
                Text("3. Connect PersonaStack").fontWeight(.medium)
                Spacer()
                Button("Check CUA Connection") { model.check() }.disabled(!model.installed || model.busy || model.connectingToCloud)
            }
            Text(model.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.busy || model.connectingToCloud {
                HStack { ProgressView().controlSize(.small); Text(model.connectingToCloud ? "Connecting PersonaStack…" : "Working…") }
            }
            Spacer(minLength: 0)
            HStack {
                Button("Cancel", action: cancel)
                Spacer()
                Button(model.connecting ? "Connect PersonaStack" : "Done", action: finish)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.ready || model.busy || model.connectingToCloud)
            }
        }
        .padding(24)
        .frame(width: 480, height: 380)
    }
}
