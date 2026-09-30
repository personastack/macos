import AppKit
import SwiftUI
import PersonaStackCore

@MainActor
final class DesktopPermissionChecklistWindow: NSObject, NSWindowDelegate {
    let coordinator: DesktopPermissionChecklistCoordinator
    private var window: NSWindow?
    private var activationObserver: NSObjectProtocol?
    private var volumeSelection: (id: UUID, window: NSWindow)?
    var onCancel: (() -> Void)?
    var onPresent: (() -> Void)?

    init(coordinator: DesktopPermissionChecklistCoordinator) {
        self.coordinator = coordinator
        super.init()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak coordinator] _ in
            Task { @MainActor in await coordinator?.refresh() }
        }
    }

    func presentForSetup() async throws {
        // A new browser request gets fresh resource checks even when a failed
        // setup or repair window is still visible.
        coordinator.cancel()
        show()
        try await coordinator.waitForFinish()
    }

    func presentForRepair() { show() }

    func completeSetup() {
        coordinator.cancel()
        window?.orderOut(nil)
    }

    func failSetup(message: String) { coordinator.failSetup(message) }

    func finish() {
        guard coordinator.canFinish else { return }
        if coordinator.isAwaitingFinish { coordinator.finish() }
        else { completeSetup() }
    }

    func cancel() {
        coordinator.cancel()
        onCancel?()
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        coordinator.cancel()
        onCancel?()
    }

    func chooseVolume(_ id: DesktopPermissionID, mounts: [DesktopVolumePermissionMount],
                      observation: (DesktopVolumePermissionMount) -> DesktopPermissionObservation) async -> DesktopVolumePermissionMount? {
        guard let window, coordinator.isVisible, !mounts.isEmpty, volumeSelection == nil, !Task.isCancelled else { return nil }
        let selectionID = UUID()
        let alert = NSAlert()
        alert.messageText = "Setup \(id.title)"
        alert.informativeText = "Choose a volume to check. PersonaStack will list its root. On writable volumes it will also create, read and remove one disposable file. Existing file contents stay unread. Read-only volumes get a listing check only."
        alert.icon = NSImage(named: NSImage.applicationIconName)
        alert.addButton(withTitle: "Check Volume")
        alert.addButton(withTitle: "Cancel")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
        for mount in mounts {
            let status = observation(mount)
            picker.addItem(withTitle: "\(mount.url.path) · \(status.state.title)\(mount.isReadOnly ? " · Read-only" : "")")
            picker.lastItem?.toolTip = "\(mount.url.path)\n\(status.detail)"
        }
        picker.setAccessibilityLabel("Mounted volume")
        alert.accessoryView = picker
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                volumeSelection = (selectionID, alert.window)
                alert.beginSheetModal(for: window) { [weak self] response in
                    if self?.volumeSelection?.id == selectionID { self?.volumeSelection = nil }
                    let index = picker.indexOfSelectedItem
                    continuation.resume(returning: response == .alertFirstButtonReturn && mounts.indices.contains(index) ? mounts[index] : nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelVolumeSelection(id: selectionID) }
        }
    }

    func cancelVolumeSelection(id: UUID? = nil) {
        guard let selected = volumeSelection, id == nil || selected.id == id else { return }
        volumeSelection = nil
        selected.window.sheetParent?.endSheet(selected.window, returnCode: .cancel)
    }

    private func show() {
        if !coordinator.isVisible { onPresent?() }
        if window == nil {
            let content = DesktopPermissionChecklistView(coordinator: coordinator,
                cancel: { [weak self] in self?.cancel() }, finish: { [weak self] in self?.finish() })
            let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 670, height: 740),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            value.title = "Set Up Desktop Control"
            value.contentViewController = NSHostingController(rootView: content)
            value.minSize = NSSize(width: 560, height: 460)
            value.isReleasedWhenClosed = false
            value.delegate = self
            value.center()
            window = value
        }
        coordinator.open()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct DesktopPermissionChecklistView: View {
    @ObservedObject var coordinator: DesktopPermissionChecklistCoordinator
    let cancel: () -> Void
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 40, height: 40).accessibilityHidden(true)
                Text("Allow PersonaStack to work on this Mac")
                    .font(.title2.weight(.semibold))
            }
            Text("Set up Desktop Control while this Mac is unlocked. Locked-screen control is unavailable in this release. Each Setup button opens approval or verifies a capability. Status updates here when you return.")
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(coordinator.rows) { row in
                        rowView(row)
                        Divider()
                    }
                }
            }
            .accessibilityLabel("Desktop Control permissions")
            if !coordinator.completionError.isEmpty {
                Text(coordinator.completionError).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                if coordinator.isFinishing { ProgressView().controlSize(.small) }
                Button(coordinator.isFinishing ? "Finishing Setup…" : "Finish Setup", action: finish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!coordinator.canFinish)
            }
        }
        .padding(24)
    }

    private func rowView(_ row: DesktopPermissionRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(row.state))
                .foregroundStyle(row.isComplete ? Color.green : Color.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.id.title).font(.headline)
                if !row.isRequiredForUnlockedSetup {
                    Text("Not required for unlocked control").font(.caption).foregroundStyle(.secondary)
                }
                Text(row.state.title).font(.caption.weight(.semibold))
                Text(row.observation.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !row.isComplete {
                Button(row.setupTitle) { coordinator.setup(row.id) }
                    .disabled(coordinator.isFinishing || coordinator.busyPermission != nil)
                    .accessibilityLabel(row.setupTitle)
            }
            if coordinator.busyPermission == row.id { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 12)
    }

    private func symbol(_ state: DesktopPermissionState) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .notNeeded: "minus.circle"
        case .checking: "clock"
        case .restricted, .unsupported: "lock.circle"
        case .restartRequired: "arrow.clockwise.circle"
        default: "exclamationmark.circle"
        }
    }
}
