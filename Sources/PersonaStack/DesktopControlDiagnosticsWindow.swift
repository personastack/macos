import AppKit
import SwiftUI

@MainActor
final class DesktopControlDiagnosticsModel: ObservableObject {
    @Published private(set) var report: DesktopControlDiagnosticReport?
    @Published private(set) var isRepairing = false
    @Published private(set) var repairError: String?
    private let read: @MainActor () async -> DesktopControlDiagnosticReport
    private let repair: @MainActor () async throws -> Void
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()

    init(read: @escaping @MainActor () async -> DesktopControlDiagnosticReport = {
        await DesktopControlRuntime.shared.diagnosticReport()
    }, repair: @escaping @MainActor () async throws -> Void = {
        _ = try await DesktopControlRuntime.shared.repair()
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
        report = nil
        repairError = nil
    }

    func repairControl() async {
        guard !isRepairing else { return }
        isRepairing = true
        repairError = nil
        let current = generation
        defer { isRepairing = false }
        do { try await repair() }
        catch is CancellationError { return }
        catch { if generation == current { repairError = error.localizedDescription } }
    }
}

@MainActor
final class DesktopControlDiagnosticsWindow: NSObject, NSWindowDelegate {
    static let shared = DesktopControlDiagnosticsWindow()
    private let model = DesktopControlDiagnosticsModel()
    private var window: NSWindow?

    func present() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 590),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Desktop Control Diagnostics"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: DesktopControlDiagnosticsView(model: model))
            window.contentMinSize = NSSize(width: 440, height: 400)
            window.setContentSize(NSSize(width: 580, height: 590))
            window.delegate = self
            window.center()
            self.window = window
        }
        model.start()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
            ScrollView {
                if let report = model.report {
                    Text(report.text).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView("Reading status…").frame(maxWidth: .infinity)
                }
            }
            if let error = model.repairError {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(model.isRepairing ? "Checking…" : "Check CUA Connection") {
                    Task { await model.repairControl() }
                }
                .disabled(model.isRepairing)
                Spacer()
                Button("Copy Diagnostics") {
                    guard let report = model.report else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.text, forType: .string)
                }
                .disabled(model.report == nil)
            }
            Text("Copied reports exclude account details, credentials, file paths, and command content.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
