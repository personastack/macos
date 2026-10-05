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
    let perception: DesktopPerceptionSetupController
    private var perceptionTask: Task<Void, Never>?
    var onInstallPerception: (() async -> Void)?
    let browserConsent: DesktopBrowserProfileConsentController
    let resumesPermissionSetup: Bool
    var setupActionTitle: String { resumesPermissionSetup ? "Resume setup" : "Continue" }
    private let canStartSetup: () -> Bool
    private let supportsFullControl: () -> Bool
    private let applicationURL: URL
    private let showApplicationInFinder: (URL) -> Void
    private let lockedControlVerifier: DesktopLockedControlSetupVerifier
    private let authorizeFullControl: @MainActor (DesktopLockedControlSetupVerifier) -> Bool
    private let restartApplication: @MainActor () throws -> Void
    var onCancel: (() -> Void)?
    var onStopVerification: (() -> Void)?
    var onPresent: (() -> Void)?

    init(coordinator: DesktopPermissionChecklistCoordinator,
         browserConsent: DesktopBrowserProfileConsentController = .shared,
         perception: DesktopPerceptionSetupController = .init(),
         canStartSetup: @escaping () -> Bool = { DesktopControlRuntime.shared.permissionSetupAvailable },
         supportsFullControl: @escaping () -> Bool = { if #available(macOS 15, *) { true } else { false } },
         resumesPermissionSetup: Bool = DesktopApplicationRestart.resumesPermissionSetup,
         applicationURL: URL = Bundle.main.bundleURL,
         showApplicationInFinder: @escaping (URL) -> Void = {
             NSWorkspace.shared.activateFileViewerSelecting([$0])
         },
         lockedControlVerifier: DesktopLockedControlSetupVerifier = .shared,
         authorizeFullControl: @escaping @MainActor (DesktopLockedControlSetupVerifier) -> Bool = { _ in true },
         restartApplication: @escaping @MainActor () throws -> Void = { try DesktopApplicationRestart.request() }) {
        self.resumesPermissionSetup = resumesPermissionSetup
        self.coordinator = coordinator
        self.browserConsent = browserConsent
        self.perception = perception
        self.canStartSetup = canStartSetup
        self.supportsFullControl = supportsFullControl
        self.applicationURL = applicationURL
        self.showApplicationInFinder = showApplicationInFinder
        self.lockedControlVerifier = lockedControlVerifier
        self.authorizeFullControl = authorizeFullControl
        self.restartApplication = restartApplication
        super.init()
        coordinator.onReady = { [weak self] in Task { @MainActor in await self?.finish() } }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak coordinator, weak browserConsent] _ in
            Task { @MainActor in
                browserConsent?.refresh()
                await coordinator?.refresh()
            }
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
        guard coordinator.canRestart, !isRefreshingLockedControlEvidence,
              !lockedControlVerifier.isChecking, !perception.isWorking else { return }
        guard setupIsAvailable() else { return }
        do {
            try restartApplication()
            cancel()
        } catch {
            coordinator.reportSetupPrerequisite("PersonaStack could not restart. Quit and reopen the app, then return to Desktop Control setup.")
        }
    }

    /// Continue is the affirmative local consent. Verification cannot create
    /// that consent during presentation, activation, or background polling.
    func continueSetup() async {
        guard coordinator.isVisible, !coordinator.hasStarted, !coordinator.isFinishing,
              !isRefreshingLockedControlEvidence else { return }
        guard setupIsAvailable() else { return }
        guard supportsFullControl() else {
            coordinator.reportSetupPrerequisite("Unattended control requires macOS 15 or later for the full CUA toolset. Chat remains available.")
            return
        }
        let generation = coordinator.operationGeneration
        isRefreshingLockedControlEvidence = true
        defer { isRefreshingLockedControlEvidence = false }
        let readiness = await lockedControlVerifier.refresh().readiness
        guard !Task.isCancelled, coordinator.isVisible, coordinator.operationGeneration == generation else { return }
        guard readiness == .ready else {
            coordinator.reportSetupPrerequisite("Reinstall PersonaStack using Install PersonaStack.pkg to set up locked-screen control. " + lockedControlVerifier.snapshot.detail)
            return
        }
        await coordinator.refresh()
        guard !Task.isCancelled, coordinator.isVisible, coordinator.operationGeneration == generation,
              setupIsAvailable() else { return }
        // No suspension between the lease check and consent mutation.
        guard lockedControlVerifier.permitsLockedControl ||
                (authorizeFullControl(lockedControlVerifier) && lockedControlVerifier.recordAcknowledgement()) else { return }
        browserConsent.approveSelection()
        coordinator.continueSetup()
    }

    private func setupIsAvailable() -> Bool {
        guard canStartSetup() else {
            coordinator.reportSetupPrerequisite("A remote task is using this Mac. Wait for it to finish, then try again.")
            return false
        }
        return true
    }

    func finish() async {
        guard coordinator.hasStarted, coordinator.canFinish, lockedControlVerifier.permitsLockedControl else { return }
        if coordinator.isAwaitingFinish { coordinator.finish(); onStopVerification?() }
        else { completeSetup() }
    }

    func cancelPerception() {
        perceptionTask?.cancel()
        perceptionTask = nil
        Task { await perception.cancel() }
    }

    func installPerception() {
        guard perceptionTask == nil, coordinator.isVisible, coordinator.hasStarted,
              coordinator.currentPermission == .visualPerception else { return }
        let generation = coordinator.operationGeneration
        perceptionTask = Task { [weak self] in
            guard let self else { return }
            await self.onInstallPerception?()
            guard !Task.isCancelled, self.coordinator.isVisible, self.coordinator.operationGeneration == generation else { return }
            self.perceptionTask = nil
            self.coordinator.check(.visualPerception)
        }
    }

    func cancel() {
        cancelPerception()
        coordinator.cancel()
        onCancel?()
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        cancelPerception()
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
        browserConsent.refresh()
        if !coordinator.isVisible { onPresent?() }
        let value = makeWindowIfNeeded()
        coordinator.open()
        NSApp.activate(ignoringOtherApps: true)
        value.makeKeyAndOrderFront(nil)
        Task { await lockedControlVerifier.refresh() }
    }

    func makeWindowIfNeeded() -> NSWindow {
        if let window { return window }
        let content = DesktopPermissionChecklistView(coordinator: coordinator,
            lockedControlVerifier: lockedControlVerifier, browserConsent: browserConsent, perception: perception,
            installPerception: { [weak self] in self?.installPerception() },
            resumesPermissionSetup: resumesPermissionSetup,
            cancel: { [weak self] in self?.cancel() }, finish: { [weak self] in
                Task { @MainActor in await self?.continueSetup() }
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

struct DesktopPermissionChecklistView: View {
    @ObservedObject var coordinator: DesktopPermissionChecklistCoordinator
    @ObservedObject var lockedControlVerifier: DesktopLockedControlSetupVerifier
    @ObservedObject var browserConsent: DesktopBrowserProfileConsentController
    @ObservedObject var perception: DesktopPerceptionSetupController
    let installPerception: () -> Void
    let resumesPermissionSetup: Bool
    let cancel: () -> Void
    let finish: () -> Void
    let restart: () -> Void
    let revealApplication: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up unattended remote control").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !coordinator.hasStarted { introduction; browserSelection }
                    else {
                        progress
                        if let id = coordinator.currentPermission,
                           let row = coordinator.rows.first(where: { $0.id == id }) {
                            instruction(row)
                        }
                    }
                    if coordinator.hasStarted, coordinator.currentPermission == .visualPerception {
                        if let review = perception.review {
                            DesktopPerceptionInstallReviewView(review: review, isWorking: perception.isWorking,
                                install: installPerception, cancel: cancel)
                        }
                        if let failure = perception.failure { Text(failure).font(.callout).foregroundStyle(.red) }
                    }
                    Label(lockedControlVerifier.snapshot.detail,
                          systemImage: lockedControlVerifier.snapshot.readiness == .ready ? "checkmark.shield" : "exclamationmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                    if coordinator.hasStarted {
                        ForEach(coordinator.automaticRows) { row in
                            Label("\(row.id.title): \(row.state.title)", systemImage: row.isComplete ? "checkmark.circle" : "clock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel("Unattended control setup")
            if !coordinator.completionError.isEmpty {
                Text(coordinator.completionError).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel setup", action: cancel).buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                Spacer()
                if coordinator.canSkipBrowsers {
                    Button("Skip", action: coordinator.skipBrowsers).buttonStyle(.bordered)
                        .help("Continue setup without enabling browser integration.")
                        .accessibilityHint("Skips optional browser setup and continues to the next step")
                }
                if coordinator.isFinishing {
                    ProgressView().controlSize(.small)
                    Text("Connecting this Mac…").font(.callout)
                } else if coordinator.busyPermission != nil || lockedControlVerifier.isChecking || perception.isWorking {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking setup")
                } else if coordinator.requiresAppRestart {
                    Button("Restart PersonaStack", action: restart).buttonStyle(.borderedProminent)
                        .disabled(!coordinator.canRestart)
                } else if !coordinator.hasStarted {
                    Button(resumesPermissionSetup ? "Resume setup" : "Continue", action: finish).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(coordinator.needsNewSetupRequest)
                }
            }
        }.padding(24)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            if resumesPermissionSetup {
                Text("PersonaStack restarted. Resume setup to recheck permissions. Complete the new Desktop Control setup request in the app before connecting this Mac.").fontWeight(.medium)
            }
            Text("Authorized personas can control apps, use the clipboard and local network, access files, run commands, and record or replay desktop activity when requested. Recording stays off until requested.")
            if CuaPerceptionCompatibility.supportedArchitecture {
                Text("Setup may download 426 MB of visual perception components for review. Installing the separately licensed models requires your confirmation.")
            }
            Text("Browser setup is optional. You can skip it and set it up later. Existing browser profiles need your approval. Apple and your browsers may ask for separate permissions.")
            Text("While this Mac is locked, PersonaStack temporarily unlocks the session, conceals the displays, then locks it again. Local input ends remote control.")
            Text("Continue allows bounded setup checks: a discarded screen image and clipboard read, a protected-folder check, and a local-network probe. PersonaStack also clicks and types disposable text in its own test window. If Safari has no document, setup opens a blank test tab and leaves it open. Microphone access is requested only when you record audio in chat.")
                .foregroundStyle(.secondary)
        }.font(.callout)
    }

    private var browserSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Existing browser access").font(.callout.bold())
            Text("Isolated browsers remain available without sharing your signed-in profiles. Select a running Chrome or Edge instance to also allow its windows, tabs, and authenticated profiles.")
                .font(.caption).foregroundStyle(.secondary)
            if browserConsent.targets.isEmpty {
                Text("No supported browser windows found. Open Chrome or Edge, then return to setup to select it.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(browserConsent.selectionTargets) { target in
                    Toggle("\(target.browserName) · instance \(target.pid)", isOn: Binding(
                        get: { browserConsent.selectedIDs.contains(target.id) },
                        set: { browserConsent.setSelected($0, id: target.id) }))
                        .toggleStyle(.checkbox)
                        .accessibilityHint("Approves this running browser instance, including all its authenticated profiles, when you press Continue")
                }
            }
            Text("Continue approves the selected browser instances. CUA may enable their remote-debugging setting and accept their browser connection dialog. It does not approve macOS permission dialogs. Browser restart requires local approval again. PersonaStack restarts retain approval only for the same running browser instances.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(DesktopPermissionStage.allCases) { stage in
                let done = stage.permissions.allSatisfy { id in coordinator.rows.first(where: { $0.id == id })?.isComplete == true }
                let skipped = stage == .browsers && coordinator.browsersSkipped
                let title = stage.title + (skipped ? " (Skipped)" : stage == .browsers ? " (Optional)" : "")
                Label(title, systemImage: skipped ? "arrow.right.circle" : done ? "checkmark.circle.fill" : coordinator.currentStage == stage ? "circle.inset.filled" : "circle")
                    .foregroundStyle(skipped ? Color.secondary : done ? Color.green : coordinator.currentStage == stage ? Color.primary : Color.secondary)
                    .font(.callout.weight(coordinator.currentStage == stage ? .semibold : .regular))
                    .accessibilityLabel("\(title), \(skipped ? "skipped" : done ? "complete" : coordinator.currentStage == stage ? "current step" : "waiting")")
            }
        }
    }

    private func instruction(_ row: DesktopPermissionRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(coordinator.currentStage?.title ?? row.id.title).font(.headline)
            if coordinator.currentStage == .browsers {
                Text("Optional. Choose Skip to continue without browser integration. You can return to permissions setup later.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(row.state.title).font(.caption.bold())
                .foregroundStyle(row.state == .failed || row.state == .denied ? Color.red : Color.secondary)
            if row.id == .directCapture {
                Text("Apple may ask to bypass the private window picker. This enables unattended screen capture. Setup discards a one-pixel image and does not record audio.").font(.callout)
            }
            Text(row.observation.detail).font(.callout)
            if coordinator.screenRecordingNeedsRestartRecheck {
                Text("If Screen Recording is enabled in Settings, restart PersonaStack to recheck access. Restarting does not grant permission. Setup will resume with a fresh check.")
                    .font(.callout)
            }
            if coordinator.busyPermission == nil && row.state != .checking && !perception.isWorking {
                if row.id != .visualPerception {
                    HStack {
                        Button(settingsTitle(row.id)) { coordinator.openSettings(row.id) }.buttonStyle(.bordered)
                        if [.accessibility, .fullDiskAccess].contains(row.id) {
                            Button("Show PersonaStack in Finder", action: revealApplication).buttonStyle(.bordered)
                        }
                    }
                }
                if [.failed, .denied, .restricted, .verificationRequired, .unsupported].contains(row.state),
                   row.id != .visualPerception || perception.review == nil {
                    Button("Retry") { coordinator.retryCurrentPermission() }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func settingsTitle(_ id: DesktopPermissionID) -> String {
        switch id {
        case .accessibility: "Open Accessibility Settings"
        case .screenRecording, .directCapture: "Open Screen Recording Settings"
        case .fullDiskAccess: "Open Full Disk Access Settings"
        case .safariJavaScript: "Open Browser"
        case .automation: "Open Automation Settings"
        case .clipboard: "Open Clipboard Settings"
        case .localNetwork: "Open Local Network Settings"
        case .launchAtLogin: "Open Login Items"
        default: "Open Settings"
        }
    }
}
