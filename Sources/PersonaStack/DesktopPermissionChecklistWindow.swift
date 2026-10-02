import AppKit
import SwiftUI
import PersonaStackCore

enum DesktopProtectedAccessSetupAction { case check, settings, cancel }
enum DesktopLockedControlSetupPromptAction { case install, cancel }

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
    private let installerPackageURL: @MainActor () -> URL?
    private let openInstallerPackage: @MainActor (URL) -> Bool
    private let setupPromptAction: @MainActor (DesktopLockedControlSetupVerifier.Readiness) -> DesktopLockedControlSetupPromptAction
    private let showInstallerUnavailable: @MainActor (String) -> Void
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
         installerPackageURL: @escaping @MainActor () -> URL? = DesktopPermissionChecklistWindow.lockedControlInstallerPackageURL,
         openInstallerPackage: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
         setupPromptAction: @escaping @MainActor (DesktopLockedControlSetupVerifier.Readiness) -> DesktopLockedControlSetupPromptAction = DesktopPermissionChecklistWindow.promptLockedControlSetup,
         showInstallerUnavailable: @escaping @MainActor (String) -> Void = DesktopPermissionChecklistWindow.showInstallerUnavailable) {
        self.coordinator = coordinator
        self.applicationURL = applicationURL
        self.showApplicationInFinder = showApplicationInFinder
        self.lockedControlVerifier = lockedControlVerifier
        self.authorizeFullControl = authorizeFullControl
        self.installerPackageURL = installerPackageURL
        self.openInstallerPackage = openInstallerPackage
        self.setupPromptAction = setupPromptAction
        self.showInstallerUnavailable = showInstallerUnavailable
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
        guard coordinator.isVisible, !coordinator.isFinishing,
              coordinator.rows.first(where: { $0.id == .accessibility })?.state == .notGranted else { return }
        showApplicationInFinder(applicationURL)
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
            guard let packageURL = installerPackageURL() else {
                guard isCurrentFinishAttempt(generation) else { return }
                showInstallerUnavailable("This PersonaStack build does not include the locked-control installer. Update PersonaStack, then retry Finish Setup.")
                return
            }
            guard setupPromptAction(readiness) == .install else { return }
            guard isCurrentFinishAttempt(generation) else { return }
            guard openInstallerPackage(packageURL) else {
                guard isCurrentFinishAttempt(generation) else { return }
                showInstallerUnavailable("macOS could not open the locked-control installer. Check that the PersonaStack app is in Applications, then retry Finish Setup.")
                return
            }
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

    private static func lockedControlInstallerPackageURL() -> URL? {
        Bundle.main.url(forResource: "LockedControlInstaller", withExtension: "pkg")
    }

    private static func promptLockedControlSetup(_ readiness: DesktopLockedControlSetupVerifier.Readiness) -> DesktopLockedControlSetupPromptAction {
        let alert = NSAlert()
        switch readiness {
        case .absent:
            alert.messageText = "Install full Desktop Control?"
            alert.informativeText = "Full Desktop Control lets authorized PersonaStack agents continue working while this Mac is locked. The installer adds the local control component and authorization policy. macOS Installer will ask for administrator approval. Finish Setup stays open until you install it and retry verification."
            alert.addButton(withTitle: "Open Installer")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .install : .cancel
        case .mismatch:
            alert.messageText = "Retry full Desktop Control installation?"
            alert.informativeText = "PersonaStack could not verify the installed component and policy. The installer can resume an interrupted setup when its existing files match. Conflicting system state stays unchanged. Finish Setup remains open until a later verification succeeds."
            alert.addButton(withTitle: "Retry Installer")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .install : .cancel
        case .ready:
            return .cancel
        }
    }

    private static func showInstallerUnavailable(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = "Full Desktop Control setup is unavailable"
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
        alert.informativeText = "If PersonaStack is already enabled in System Settings → Privacy & Security → Full Disk Access, choose Check Access. Otherwise, open Settings, add PersonaStack.app from Applications with + and enable it. Return here to check access. Quit and reopen PersonaStack if macOS requests it. Check Access authorizes a directory read in Library/Mail, or Library/Messages if Mail is absent. The same check runs automatically whenever you open this window. Entry names are discarded. No file contents are read or changed. A successful check marks this row Ready. Other folders can still have separate access restrictions."
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
    }

    func makeWindowIfNeeded() -> NSWindow {
        if let window { return window }
        let content = DesktopPermissionChecklistView(coordinator: coordinator,
            cancel: { [weak self] in self?.cancel() }, finish: { [weak self] in
                Task { @MainActor in await self?.finish() }
            },
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
    let cancel: () -> Void
    let finish: () -> Void
    let revealApplication: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 40, height: 40).accessibilityHidden(true)
                Text("Allow PersonaStack to work on this Mac")
                    .font(.title2.weight(.semibold))
            }
            Text("Accessibility (Required) must be Ready before you finish setup. Screen Capture adds screenshot-based control. Microphone and file access are optional. " +
                 (DesktopLockedControlSetupVerifier.shared.permitsLockedControl
                    ? "Full Desktop Control can continue after this Mac locks."
                    : "Desktop Control works while this Mac is unlocked."))
                .foregroundStyle(.secondary)
            Text("Opening this window checks current access. Granted microphone access uses a short recording that is discarded. Accessibility checks macOS approval and, when needed, reads an application role without clicking, typing or reading window contents. Screen Capture reads macOS approval without taking a screenshot. The disk check reads one protected folder listing without reading file contents. Network checks contact only your selected services.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Updates from an older unsigned build can leave an enabled permission tied to the old app. Follow the recovery steps below if macOS still denies access. This window checks approval automatically.")
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
                Text(row.displayTitle).font(.headline)
                if row.id == .fullDiskAccess {
                    Text("Optional for setup.").font(.caption).foregroundStyle(.secondary)
                }
                if !automatic || !row.isComplete {
                    Text(row.state.title).font(.caption.weight(.semibold))
                    Text(row.observation.detail).font(.caption).foregroundStyle(.secondary)
                    if row.id == .accessibility && row.state == .notGranted {
                        Button("Show PersonaStack in Finder", action: revealApplication)
                            .buttonStyle(.link)
                            .font(.caption)
                            .disabled(coordinator.isFinishing)
                    }
                }
            }
            Spacer(minLength: 8)
            if !row.isComplete && (!automatic || (row.state != .checking && coordinator.automaticBusyPermission == nil)) {
                Button(automatic ? "Retry" : row.setupTitle) { coordinator.setup(row.id) }
                    .disabled(coordinator.isFinishing || coordinator.busyPermission != nil || coordinator.verificationBusyPermission == row.id)
                    .accessibilityLabel(row.setupTitle)
            }
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
