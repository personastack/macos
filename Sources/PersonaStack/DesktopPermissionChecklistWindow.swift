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
    private var isRefreshingLockedControlEvidence = false
    private let applicationURL: URL
    private let showApplicationInFinder: (URL) -> Void
    private let lockedControlVerifier: DesktopLockedControlSetupVerifier
    private let authorizeFullControl: @MainActor (DesktopLockedControlSetupVerifier) -> Bool
    private let restartApplication: @MainActor () throws -> Void
    var onCancel: (() -> Void)?
    var onStopVerification: (() -> Void)?
    var onPresent: (() -> Void)?

    init(coordinator: DesktopPermissionChecklistCoordinator,
         applicationURL: URL = Bundle.main.bundleURL,
         showApplicationInFinder: @escaping (URL) -> Void = {
             NSWorkspace.shared.activateFileViewerSelecting([$0])
         },
         lockedControlVerifier: DesktopLockedControlSetupVerifier = .shared,
         authorizeFullControl: @escaping @MainActor (DesktopLockedControlSetupVerifier) -> Bool = DesktopPermissionChecklistWindow.confirmFullControl,
         restartApplication: @escaping @MainActor () throws -> Void = { try DesktopApplicationRestart.request() }) {
        self.coordinator = coordinator
        self.applicationURL = applicationURL
        self.showApplicationInFinder = showApplicationInFinder
        self.lockedControlVerifier = lockedControlVerifier
        self.authorizeFullControl = authorizeFullControl
        self.restartApplication = restartApplication
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
        onStopVerification?()
        window?.orderOut(nil)
    }

    func failSetup(message: String) { coordinator.failSetup(message) }

    func revealCurrentApplication() {
        guard coordinator.isVisible, !coordinator.isFinishing else { return }
        showApplicationInFinder(applicationURL)
    }

    func restart() {
        guard coordinator.canRestart else { return }
        do {
            try restartApplication()
            cancel()
        } catch {
            coordinator.reportSetupPrerequisite("PersonaStack could not restart. Quit and reopen the app, then return to Desktop Control setup.")
        }
    }

    func finish() async {
        guard coordinator.canFinish, !isRefreshingLockedControlEvidence else { return }
        let generation = coordinator.operationGeneration
        isRefreshingLockedControlEvidence = true
        defer { isRefreshingLockedControlEvidence = false }
        // Read the installed candidate at the explicit Finish action. Cached
        // absence from an earlier background check must not skip consent.
        let readiness = await lockedControlVerifier.refresh().readiness
        guard isCurrentFinishAttempt(generation) else { return }
        switch readiness {
        case .absent, .mismatch:
            coordinator.reportSetupPrerequisite("Locked-screen control is included in the main PersonaStack installer. Reinstall PersonaStack using Install PersonaStack.pkg, then retry Finish Setup. " + lockedControlVerifier.snapshot.detail)
            return
        case .unsupported:
            coordinator.reportSetupPrerequisite(lockedControlVerifier.snapshot.detail)
            return
        case .ready:
            break
        }
        if !lockedControlVerifier.permitsLockedControl {
            guard authorizeFullControl(lockedControlVerifier), isCurrentFinishAttempt(generation),
                  lockedControlVerifier.recordAcknowledgement() else { return }
        }
        guard isCurrentFinishAttempt(generation) else { return }
        if coordinator.isAwaitingFinish { coordinator.finish(); onStopVerification?() }
        else { completeSetup() }
    }

    private func isCurrentFinishAttempt(_ generation: UUID) -> Bool {
        !Task.isCancelled && coordinator.operationGeneration == generation && coordinator.canFinish
    }

    private static func confirmFullControl(_ verifier: DesktopLockedControlSetupVerifier) -> Bool {
        guard !verifier.permitsLockedControl else { return true }
        let alert = NSAlert()
        alert.messageText = "Allow full Desktop Control after locking?"
        alert.informativeText = "Your authorized PersonaStack agents will be able to control apps, files, and commands while this Mac is locked. PersonaStack temporarily unlocks the session, conceals the displays, and locks it again when control ends. Local input ends remote control."
        alert.addButton(withTitle: "Allow Full Control")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return true
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
        alert.informativeText = "If PersonaStack is already enabled in System Settings → Privacy & Security → Full Disk Access, choose Check Access. Otherwise, open Settings, click + and select the running PersonaStack.app shown by Show PersonaStack in Finder. Enable its switch. Opening Settings does not add the app or approve access. Return here for an automatic protected-folder check. Quit and reopen PersonaStack if macOS requests it. Check Access authorizes a directory read in Library/Mail, or Library/Messages if Mail is absent. The same check runs automatically whenever you open this window. Entry names are discarded. No file contents are read or changed. A successful check marks this row Ready. Other folders can still have separate access restrictions."
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
        coordinator.startPresentationVerification()
        coordinator.startAutomaticSetup()
        Task { await lockedControlVerifier.refresh() }
    }

    func makeWindowIfNeeded() -> NSWindow {
        if let window { return window }
        let content = DesktopPermissionChecklistView(coordinator: coordinator,
            lockedControlVerifier: lockedControlVerifier,
            cancel: { [weak self] in self?.cancel() }, finish: { [weak self] in
                Task { @MainActor in await self?.finish() }
            },
            restart: { [weak self] in self?.restart() },
            revealApplication: { [weak self] in self?.revealCurrentApplication() })
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
    @ObservedObject var lockedControlVerifier: DesktopLockedControlSetupVerifier
    let cancel: () -> Void
    let finish: () -> Void
    let restart: () -> Void
    let revealApplication: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 40, height: 40).accessibilityHidden(true)
                Text("Allow PersonaStack to work on this Mac")
                    .font(.title2.weight(.semibold))
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: lockedControlVerifier.snapshot.readiness == .ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(lockedControlVerifier.snapshot.readiness == .ready ? Color.green : Color.secondary)
                            .frame(width: 20).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Locked-screen control").font(.headline)
                            Text(lockedControlVerifier.snapshot.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Verify Installation") {
                            Task { await lockedControlVerifier.refresh() }
                        }.disabled(lockedControlVerifier.isChecking || coordinator.isFinishing)
                        if lockedControlVerifier.isChecking { ProgressView().controlSize(.small) }
                    }.padding(.vertical, 12)
                    Divider()
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
                Button(coordinator.primaryActionTitle, action: coordinator.requiresAppRestart ? restart : finish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(coordinator.requiresAppRestart ? !coordinator.canRestart : !coordinator.canFinish)
            }
        }
        .padding(24)
    }

    private func rowView(_ row: DesktopPermissionRow, automatic: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(row.state))
                .foregroundStyle(row.state == .restartRequired ? Color.yellow : row.isComplete ? Color.green : Color.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.displayTitle).font(.headline)
                if [.fullDiskAccess, .directCapture, .automation, .safariJavaScript, .clipboard].contains(row.id) {
                    Text("Optional for setup.").font(.caption).foregroundStyle(.secondary)
                }
                Group {
                    Text(row.state.title).font(.caption.weight(.semibold))
                    Text(row.observation.detail).font(.caption).foregroundStyle(.secondary)
                    if [.localNetwork, .notifications, .launchAtLogin, .automation, .directCapture, .safariJavaScript, .clipboard].contains(row.id) && !row.isComplete && row.state != .checking {
                        Button(row.id == .safariJavaScript ? "Open Safari" : "Open Settings") { coordinator.openSettings(row.id) }
                            .accessibilityLabel(row.id == .safariJavaScript ? "Open Safari for Safari JavaScript setup" : "Open Settings for \(row.displayTitle)")
                            .buttonStyle(.link)
                            .font(.caption)
                            .disabled(coordinator.isFinishing || coordinator.busyPermission == row.id)
                    }
                    if !row.isComplete && (DesktopPermissionReset.arguments(for: row.id) != nil || row.id == .localNetwork) {
                        Button("Show PersonaStack in Finder", action: revealApplication)
                            .buttonStyle(.link)
                            .font(.caption)
                            .disabled(coordinator.isFinishing)
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button("Check") { coordinator.check(row.id) }
                    .accessibilityLabel("Check \(row.displayTitle)")
                Button("Setup") { coordinator.setup(row.id) }
                    .accessibilityLabel(row.setupTitle)
            }
            .disabled(coordinator.isFinishing || coordinator.busyPermission != nil || coordinator.verificationBusyPermission == row.id || (automatic && coordinator.automaticBusyPermission != nil))
            if coordinator.busyPermission == row.id || coordinator.automaticBusyPermission == row.id || coordinator.verificationBusyPermission == row.id { ProgressView().controlSize(.small) }
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
