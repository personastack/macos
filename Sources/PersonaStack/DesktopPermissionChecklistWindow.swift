import AppKit
import SwiftUI
import PersonaStackCore

enum DesktopProtectedAccessSetupAction { case check, settings, cancel }

@MainActor
final class DesktopPermissionChecklistWindow: NSObject, NSWindowDelegate {
    let coordinator: DesktopPermissionChecklistCoordinator
    private var window: NSWindow?
    private var activationObserver: NSObjectProtocol?
    private var permissionSelection: (id: UUID, permission: DesktopPermissionID, window: NSWindow)?
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
        guard !mounts.isEmpty else { return nil }
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
        let response = await presentPermissionAlert(alert, permission: id)
        let index = picker.indexOfSelectedItem
        return response == .alertFirstButtonReturn && mounts.indices.contains(index) ? mounts[index] : nil
    }

    func protectedAccessSetupAction() async -> DesktopProtectedAccessSetupAction {
        let alert = NSAlert()
        alert.messageText = "Setup Full Disk Access"
        alert.informativeText = "In System Settings → Privacy & Security → Full Disk Access, click + and select PersonaStack.app from Applications. PersonaStack may not appear until you add it. Turn its switch on and relaunch if macOS requests it. Check Access attempts one directory read in your Library/Mail folder. Entry names are discarded. No file contents are read or changed. A successful check proves this operation only. Full Disk Access remains unqualified in this release."
        alert.icon = NSImage(named: NSImage.applicationIconName)
        alert.addButton(withTitle: "Check Access")
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        switch await presentPermissionAlert(alert, permission: .fullDiskAccess) {
        case .alertFirstButtonReturn: return .check
        case .alertSecondButtonReturn: return .settings
        default: return .cancel
        }
    }

    private func presentPermissionAlert(_ alert: NSAlert, permission: DesktopPermissionID) async -> NSApplication.ModalResponse? {
        guard let window, coordinator.isVisible, permissionSelection == nil, !Task.isCancelled else { return nil }
        let selectionID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                permissionSelection = (selectionID, permission, alert.window)
                alert.beginSheetModal(for: window) { [weak self] response in
                    if self?.permissionSelection?.id == selectionID { self?.permissionSelection = nil }
                    continuation.resume(returning: response)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPermissionSelection(id: selectionID) }
        }
    }

    func cancelPermissionSelection(permission: DesktopPermissionID? = nil, id: UUID? = nil) {
        guard let selected = permissionSelection, id == nil || selected.id == id,
              permission == nil || selected.permission == permission else { return }
        permissionSelection = nil
        selected.window.sheetParent?.endSheet(selected.window, returnCode: .cancel)
    }

    private func show() {
        if !coordinator.isVisible { onPresent?() }
        let value = makeWindowIfNeeded()
        coordinator.open()
        NSApp.activate(ignoringOtherApps: true)
        value.makeKeyAndOrderFront(nil)
        coordinator.startAutomaticSetup()
    }

    func makeWindowIfNeeded() -> NSWindow {
        if let window { return window }
        let content = DesktopPermissionChecklistView(coordinator: coordinator,
            cancel: { [weak self] in self?.cancel() }, finish: { [weak self] in self?.finish() })
        let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 670, height: 740),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        value.title = "Set Up Desktop Control"
        let hosting = NSHostingController(rootView: content)
        // The native window owns its frame, including later user resizing.
        hosting.sizingOptions = []
        value.contentViewController = hosting
        value.contentMinSize = NSSize(width: 560, height: 460)
        value.setContentSize(NSSize(width: 670, height: 740))
        value.isReleasedWhenClosed = false
        value.delegate = self
        value.center()
        window = value
        return value
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
            Text("Allow accessibility, screen capture and microphone access. Full Disk Access replaces separate folder approvals. Desktop Control works while this Mac is unlocked.")
                .foregroundStyle(.secondary)
            Text("After an update, macOS may need you to approve access again. If a permission is already enabled in System Settings, follow its recovery steps below, then retry Setup.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(coordinator.permissionRows) { row in
                        rowView(row)
                        Divider()
                    }
                    Text("Automatic setup").font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 20)
                    Text("PersonaStack sets these up when you open this window. macOS may ask for approval. These settings do not block Desktop Control.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    ForEach(coordinator.automaticRows) { row in
                        rowView(row, automatic: true)
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

    private func rowView(_ row: DesktopPermissionRow, automatic: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(row.state))
                .foregroundStyle(row.isComplete ? Color.green : Color.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.id.title).font(.headline)
                if row.id == .fullDiskAccess {
                    Text("Optional for setup. Broad file access remains unverified.").font(.caption).foregroundStyle(.secondary)
                }
                if !automatic || !row.isComplete {
                    Text(row.state.title).font(.caption.weight(.semibold))
                    Text(row.observation.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if !row.isComplete && (!automatic || (row.state != .checking && coordinator.automaticBusyPermission == nil)) {
                Button(automatic ? "Retry" : row.setupTitle) { coordinator.setup(row.id) }
                    .disabled(coordinator.isFinishing || coordinator.busyPermission != nil)
                    .accessibilityLabel(row.setupTitle)
            }
            if coordinator.busyPermission == row.id || coordinator.automaticBusyPermission == row.id { ProgressView().controlSize(.small) }
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
