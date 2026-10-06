import AppKit
import SwiftUI

@MainActor
final class DesktopControlDiagnosticsModel: ObservableObject {
    @Published private(set) var report: DesktopControlDiagnosticReport?
    @Published private(set) var isRepairing = false
    @Published private(set) var repairError: String?
    @Published private(set) var repairMessage: String?
    private let read: @MainActor () async -> DesktopControlDiagnosticReport
    private let repair: @MainActor () async throws -> Void
    private var refreshTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var generation = UUID()

    init(read: @escaping @MainActor () async -> DesktopControlDiagnosticReport = {
        await DesktopControlRuntime.shared.diagnosticReport()
    }, repair: @escaping @MainActor () async throws -> Void = {
        try await DesktopControlRuntime.shared.checkCuaConnectionForSetup()
    }) {
        self.read = read
        self.repair = repair
    }

    func start() {
        stop()
        let current = generation
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let next = await self.read()
                guard !Task.isCancelled, self.generation == current else { return }
                self.report = next
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    func stop() {
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        checkTask?.cancel()
        checkTask = nil
        isRepairing = false
        report = nil
        repairError = nil
        repairMessage = nil
    }

    func checkConnection() {
        guard checkTask == nil, !isRepairing else { return }
        let current = generation
        checkTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.generation == current else { return }
            await self.repairControl()
            if self.generation == current { self.checkTask = nil }
        }
    }

    func repairControl() async {
        guard !isRepairing else { return }
        isRepairing = true
        repairError = nil
        repairMessage = "Checking CUA connection…"
        let current = generation
        defer { if generation == current { isRepairing = false } }
        do {
            try await repair()
            guard generation == current else { return }
            repairMessage = "CUA is ready. PersonaStack cloud status is shown below."
        } catch is CancellationError {
            if generation == current { repairMessage = "Check canceled. Try again when setup has finished." }
        } catch {
            if generation == current {
                repairMessage = nil
                repairError = error.localizedDescription
            }
        }
        guard generation == current else { return }
        let next = await read()
        guard generation == current else { return }
        report = next
    }
}

@MainActor
final class DesktopControlDiagnosticsWindow: NSObject, NSWindowDelegate {
    static let shared = DesktopControlDiagnosticsWindow()
    private let model = DesktopControlDiagnosticsModel()
    private var window: NSWindow?

    func present(checkConnection: Bool = false) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 590),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Desktop Control Diagnostics"
            window.isReleasedWhenClosed = false
            let content = NSHostingView(rootView: DesktopControlDiagnosticsView(model: model))
            content.sizingOptions = []
            window.contentView = content
            window.contentMinSize = NSSize(width: 440, height: 400)
            window.setContentSize(NSSize(width: 580, height: 590))
            window.delegate = self
            window.center()
            self.window = window
        }
        if window?.isVisible != true { model.start() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if checkConnection { model.checkConnection() }
    }

    func windowWillClose(_ notification: Notification) { model.stop() }
}

struct DesktopControlDiagnosticsView: View {
    @ObservedObject var model: DesktopControlDiagnosticsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Desktop Control Diagnostics").font(.title2.bold())
            Text("Connection and service details for troubleshooting.")
                .foregroundStyle(.secondary)
            if let message = model.repairMessage {
                HStack {
                    if model.isRepairing { ProgressView().controlSize(.small) }
                    Text(message).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = model.repairError {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                if let report = model.report {
                    Text(report.text).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView("Reading status…").frame(maxWidth: .infinity)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { checkButton; setupButton; Spacer(); copyButton }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) {
                    HStack { checkButton; setupButton }
                    copyButton
                }
            }
            Text("Copied reports exclude account details, credentials, file paths, and command content.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var checkButton: some View {
        Button("Check CUA Connection") { model.checkConnection() }
            .buttonStyle(.borderedProminent)
            .disabled(model.isRepairing)
    }

    private var setupButton: some View {
        Button("Set Up CUA…") { CuaSetupWindow.shared.presentForRepair() }
            .disabled(model.isRepairing)
    }

    private var copyButton: some View {
        Button("Copy Diagnostics") {
            guard let report = model.report else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report.text, forType: .string)
        }
        .disabled(model.report == nil)
    }

}
