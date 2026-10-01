import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import PersonaStackCore
import WebKit

@MainActor
protocol DesktopPermissionCuaRuntime: AnyObject {
    func cuaPermissionSnapshot() async throws -> CuaDriverPermissionSnapshot
    func prepareCuaPermissions() async throws
    func prepareCuaPermissionsAutomatically() async throws
    func restartCuaAfterPermissionChange() async throws
    func verifyCuaCapabilitiesForPermissions() async throws
    func verifyCuaCapabilitiesAutomatically() async throws
}

extension DesktopPermissionCuaRuntime {
    func prepareCuaPermissionsAutomatically() async throws { throw DesktopPermissionAutomaticCheckError.runtimeStartRequired }
    func verifyCuaCapabilitiesAutomatically() async throws { throw DesktopPermissionAutomaticCheckError.runtimeStartRequired }
}

enum DesktopPermissionAutomaticCheckError: Error {
    case sessionConfirmationRequired, runtimeStartRequired

    var observation: DesktopPermissionObservation {
        switch self {
        case .sessionConfirmationRequired:
            .init(.verificationRequired, detail: "Unlock this Mac, then choose Setup Screen Capture to confirm the current session before the capture check can run.")
        case .runtimeStartRequired:
            .init(.verificationRequired, detail: "Choose Setup Screen Capture to start PersonaStack's desktop runtime. Screen approval is already present; capture still needs the running runtime.")
        }
    }
}

extension DesktopControlRuntime: DesktopPermissionCuaRuntime {}

/// Composes the checklist with existing app owners. Stored observations are
/// content-free evidence from explicit checks, never persisted OS grants.
@MainActor
final class DesktopPermissionChecklist {
    static let shared = DesktopPermissionChecklist()
    let window: DesktopPermissionChecklistWindow
    let adapter: DesktopPermissionChecklistSystemAdapter
    private let directoryURL: (FileManager.SearchPathDirectory) -> URL?
    private let verifyDirectory: @MainActor (URL) async throws -> Void
    private let selectedProfile: () -> DesktopEnvironmentConfiguration?
    private let volumeSnapshot: () throws -> [DesktopVolumePermissionMount]
    private let chooseVolume: (@MainActor (DesktopPermissionID, [DesktopVolumePermissionMount]) async -> DesktopVolumePermissionMount?)?
    private let verifyVolume: (@MainActor (DesktopVolumePermissionMount) async throws -> Void)?
    private let protectedAccessAction: (@MainActor () async -> DesktopProtectedAccessSetupAction)?
    private let verifyProtectedAccess: @MainActor () async throws -> Void
    private let verifyPowerAvailability: () -> Bool
    private let voiceContext: @MainActor () -> DesktopVoicePermissionContext?
    private let requestEndpoint: @MainActor (URLRequest) async throws -> HTTPURLResponse
    private var authorizedRefreshKeys: [DesktopPermissionID: String] = [:]
    private var refreshNeeded: Set<DesktopPermissionID> = []
    private var observedOwnerKey: String?
    private var connectionAttempts: [DesktopPermissionID: UUID] = [:]
    private var resourceVerificationGeneration = UUID()
    private var resourceVerificationGenerations: [DesktopPermissionID: UUID] = [:]
    private let cuaRuntime: any DesktopPermissionCuaRuntime
    private var protectedAccessGeneration = UUID()
    private var protectedAccessAttempt: UUID?
    private lazy var volumeCheck = makeVolumeCheck()

    private func makeVolumeCheck() -> DesktopVolumePermissionCheck {
        DesktopVolumePermissionCheck(
        snapshot: volumeSnapshot,
        choose: { [weak self] id, mounts in
            guard let self else { return nil }
            if let choose = self.chooseVolume { return await choose(id, mounts) }
            return await self.window.chooseVolume(id, mounts: mounts) { self.volumeCheck.observation(for: $0) }
        },
        verify: { [weak self] mount in
            guard let self else { throw CancellationError() }
            if let verify = self.verifyVolume { try await verify(mount); return }
            let files = DesktopFileSystem()
            try await files.verifyDirectoryAccess(path: mount.url.path, probeID: UUID(),
                expectedVolumeID: .init(first: mount.fileSystemIDFirst, second: mount.fileSystemIDSecond),
                readOnly: mount.isReadOnly)
        }, contextKey: { [weak self] in
            guard let self else { return "retired" }
            return "\(self.ownerKey):\(self.verificationGeneration)"
        })
    }
    private var explicitObservations: [DesktopPermissionID: DesktopPermissionObservation] = [:]
    private var activationObserver: NSObjectProtocol?
    private var mountObservers: [NSObjectProtocol] = []
    private let voiceVerifier = DesktopVoicePermissionVerifier()
    private var verificationGeneration = UUID()

    /// Closing a presentation cancels operations, not completed capability proof.
    func cancelVerification() {
        verificationGeneration = UUID()
        for id in [DesktopPermissionID.desktopFiles, .documentsFiles, .downloadsFiles] {
            resourceVerificationGenerations[id] = UUID()
            explicitObservations.removeValue(forKey: id)
            window.coordinator.invalidateVerification(id)
        }
        connectionAttempts.removeAll()
        protectedAccessAttempt = nil
        window.cancelPermissionSelection()
        voiceVerifier.invalidate()
        invalidateVolumeVerification()
    }

    private func preparePresentation() {
        cancelVerification()
        refreshNeeded.formUnion(authorizedRefreshKeys.keys)
    }

    init(access: DesktopPermissionSystemAccess = .init(),
         cuaRuntime: (any DesktopPermissionCuaRuntime)? = nil,
         directoryURL: @escaping (FileManager.SearchPathDirectory) -> URL? = {
             FileManager.default.urls(for: $0, in: .userDomainMask).first
         }, verifyDirectory: (@MainActor (URL) async throws -> Void)? = nil,
         selectedProfile: @escaping () -> DesktopEnvironmentConfiguration? = {
             try? LaunchConfiguration.selectedEnvironment()
         }, volumeSnapshot: @escaping () throws -> [DesktopVolumePermissionMount] = DesktopVolumePermissionCheck.passiveMountedVolumes,
         chooseVolume: (@MainActor (DesktopPermissionID, [DesktopVolumePermissionMount]) async -> DesktopVolumePermissionMount?)? = nil,
         verifyVolume: (@MainActor (DesktopVolumePermissionMount) async throws -> Void)? = nil,
         mountNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         protectedAccessAction: (@MainActor () async -> DesktopProtectedAccessSetupAction)? = nil,
         verifyProtectedAccess: (@MainActor () async throws -> Void)? = nil,
         verifyPowerAvailability: @escaping () -> Bool = { DesktopControlPowerAssertion.verifyAvailability() },
         activationNotificationCenter: NotificationCenter = .default,
         voiceContext: @escaping @MainActor () -> DesktopVoicePermissionContext? = DesktopVoicePermissionContext.current,
         requestEndpoint: (@MainActor (URLRequest) async throws -> HTTPURLResponse)? = nil) {
        self.voiceContext = voiceContext
        self.requestEndpoint = requestEndpoint ?? { request in
            let session = DesktopControlNetworkSession.makeWithoutRedirects()
            defer { session.invalidateAndCancel() }
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return response
        }
        self.cuaRuntime = cuaRuntime ?? DesktopControlRuntime.shared
        self.directoryURL = directoryURL
        self.verifyDirectory = verifyDirectory ?? { url in
            let files = DesktopFileSystem()
            try await files.verifyDirectoryAccess(path: url.path)
        }
        self.selectedProfile = selectedProfile
        self.volumeSnapshot = volumeSnapshot
        self.chooseVolume = chooseVolume
        self.verifyVolume = verifyVolume
        self.protectedAccessAction = protectedAccessAction
        self.verifyPowerAvailability = verifyPowerAvailability
        self.verifyProtectedAccess = verifyProtectedAccess ?? {
            let files = DesktopFileSystem()
            try await files.verifyProtectedDirectoryAccess(home: FileManager.default.homeDirectoryForCurrentUser)
        }
        let adapter = DesktopPermissionChecklistSystemAdapter(access: access)
        self.adapter = adapter
        window = DesktopPermissionChecklistWindow(coordinator: DesktopPermissionChecklistCoordinator(adapter: adapter))
        window.onPresent = { [weak self] in self?.preparePresentation() }
        window.onCancel = { [weak self] in self?.cancelVerification() }
        window.onStopVerification = { [weak self] in self?.cancelVerification() }
        adapter.hooks = .init(
            observe: { [weak self] in await self?.observe($0) },
            setup: { [weak self] in await self?.setup($0) },
            verifyAutomatically: { [weak self] in await self?.verifyAutomatically($0) }
        )
        activationObserver = activationNotificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateAfterActivation()
            }
            Task { @MainActor in await self?.window.coordinator.refresh() }
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            mountObservers.append(mountNotificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateVolumeVerification() }
                Task { @MainActor in await self?.window.coordinator.refresh() }
            })
        }
    }

    func invalidateAfterActivation() {
        let busy = window.coordinator.busyPermission ?? window.coordinator.verificationBusyPermission
        for id in [DesktopPermissionID.fullDiskAccess, .localNetwork, .messagingConnection] where id != busy {
            let running = id == .fullDiskAccess ? protectedAccessAttempt != nil : connectionAttempts[id] != nil
            if !running, authorizedRefreshKeys[id] != nil { refreshNeeded.insert(id) }
        }
        if busy != .removableVolumes && busy != .networkVolumes { invalidateVolumeVerification() }
        // A TCC prompt returns focus before its own functional operation finishes.
        // Let that operation prove its result. Invalidate other cached resources.
        for id in [DesktopPermissionID.desktopFiles, .documentsFiles, .downloadsFiles] where id != busy {
            resourceVerificationGenerations[id] = UUID()
            explicitObservations.removeValue(forKey: id)
            window.coordinator.invalidateVerification(id)
        }
    }

    private func invalidateVolumeVerification() {
        volumeCheck.invalidate()
        for id in [DesktopPermissionID.removableVolumes, .networkVolumes] {
            window.cancelPermissionSelection(permission: id)
            window.coordinator.invalidateVerification(id)
        }
    }

    private var profile: DesktopEnvironmentConfiguration? { selectedProfile() }
    private var ownerKey: String {
        "\(Bundle.main.bundleIdentifier ?? "unpackaged"):\(profile?.preferenceIdentity ?? "unconfigured"):\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    private func synchronizeOwner() {
        let current = ownerKey
        guard observedOwnerKey != current else { return }
        if observedOwnerKey != nil {
            cancelVerification()
            explicitObservations.removeAll()
            authorizedRefreshKeys.removeAll()
            refreshNeeded.removeAll()
            protectedAccessGeneration = UUID()
            resourceVerificationGeneration = UUID()
            resourceVerificationGenerations.removeAll()
        }
        observedOwnerKey = current
    }

    private func observe(_ id: DesktopPermissionID) async -> DesktopPermissionObservation? {
        synchronizeOwner()
        switch id {
        case .accessibility: return adapter.accessibilityObservation()
        case .screenRecording, .directCapture: return await observeCua(id)
        case .microphone: return observeMicrophone()
        case .automaticUpdates: return observeUpdates()
        case .backgroundOperation:
            return .init(.ready, detail: "PersonaStack keeps its menu bar and existing relay alive when ordinary windows close.")
        case .messagingConnection:
            guard profile != nil else { return .init(.notGranted, detail: "Choose trusted App, Gateway, and MCP URLs in Server Settings.") }
            return await observeConnection(id, detail: "Use Setup Messaging Connection to check the selected app endpoint. Enrollment is verified after Finish.")
        case .localNetwork:
            guard let profile else { return .init(.notGranted, detail: "Configure the selected server environment first.") }
            if #available(macOS 15, *) {
                if profile == .production { return .init(.notNeeded, detail: "The selected PersonaStack cloud services do not require LAN access.") }
                return await observeConnection(id, detail: "Use Setup Local Network to connect to the configured services. macOS requests LAN approval when needed.")
            }
            return .init(.notNeeded, detail: "This macOS version has no Local Network privacy approval.")
        case .desktopFiles, .documentsFiles, .downloadsFiles:
            return evidence(id, detail: "Use Setup \(id.title) to verify listing and read/write access with a disposable file. No existing file content is read.")
        case .removableVolumes, .networkVolumes: return volumeCheck.observe(id)
        case .fullDiskAccess:
            return await observeProtectedAccess()
        case .awakeDuringRemoteWork:
            return evidence(id, detail: "Use Setup Awake During Remote Work to verify idle sleep prevention. PersonaStack holds it only during a remote task.")
        default: return nil
        }
    }

    private func evidence(_ id: DesktopPermissionID, detail: String) -> DesktopPermissionObservation {
        let key = evidenceKey(id)
        if let result = explicitObservations[id], result.verificationKey == key { return result }
        return .init(.verificationRequired, detail: detail, verificationKey: key)
    }

    private func evidenceKey(_ id: DesktopPermissionID) -> String {
        switch id {
        case .desktopFiles, .documentsFiles, .downloadsFiles, .localNetwork, .messagingConnection:
            return "\(ownerKey):\(resourceVerificationGenerations[id] ?? resourceVerificationGeneration)"
        default: return ownerKey
        }
    }

    private func observeCua(_ id: DesktopPermissionID) async -> DesktopPermissionObservation {
        let allowed = adapter.access.screenRecording()
        guard allowed else {
            return DesktopPermissionChecklistSystemAdapter.privacyDenialObservation(id)
        }
        guard let snapshot = try? await cuaRuntime.cuaPermissionSnapshot(), snapshot.hostAttributionValid else {
            return .init(.verificationRequired, detail: "Use Setup \(id.title) to start PersonaStack's owned desktop runtime and verify access.",
                         verificationKey: "\(ownerKey):desktop-runtime-unavailable")
        }
        let granted = snapshot.screenRecording
        return .init(granted ? .ready : .restartRequired,
                     detail: granted ? "PersonaStack has the OS grant. Use Setup \(id.title) to verify real desktop access."
                                     : "The desktop runtime needs a restart after the permission change.",
                     verificationKey: "\(ownerKey):\(snapshot.verificationKey):\(granted)",
                     requiresVerification: true)
    }

    private func observeMicrophone() -> DesktopPermissionObservation? {
        guard adapter.access.microphone() == .authorized else {
            explicitObservations.removeValue(forKey: .microphone)
            return nil
        }
        guard adapter.access.hasMicrophone(), let inputID = adapter.access.microphoneIdentity() else {
            explicitObservations.removeValue(forKey: .microphone)
            return .init(.failed, detail: "No microphone is available. Connect an audio input and retry.")
        }
        guard let appURL = profile?.appURL,
              DesktopMediaPermissionPolicy.isSecureContext(scheme: appURL.scheme ?? "", host: appURL.host ?? "") else {
            explicitObservations.removeValue(forKey: .microphone)
            return .init(.unsupported, detail: "Voice recording needs an HTTPS app URL or a loopback development URL. Review Server Settings.")
        }
        guard let context = voiceContext(),
              (try? DesktopControlEnvironment.origin(context.url)) == (try? DesktopControlEnvironment.origin(appURL)) else {
            explicitObservations.removeValue(forKey: .microphone)
            return .init(.verificationRequired, detail: "Open the selected PersonaStack app before testing voice input.")
        }
        let key = "\(ownerKey):microphone:\(inputID):\(context.identity)"
        if let value = explicitObservations[.microphone], value.verificationKey == key { return value }
        explicitObservations.removeValue(forKey: .microphone)
        return .init(.ready, detail: "Microphone access is allowed. Use Setup Microphone to test WebKit recording.",
                     verificationKey: key, requiresVerification: true)
    }

    private func observeUpdates() -> DesktopPermissionObservation {
        let updater = DesktopUpdater.shared
        if let instruction = updater.applicationsInstallInstruction { return .init(.notGranted, detail: instruction) }
        guard updater.isAvailable else {
            return .init(.failed, detail: "Automatic updates require the packaged feed and verification key in the Applications copy of PersonaStack.")
        }
        guard updater.automaticallyChecksForUpdates, updater.automaticallyDownloadsUpdates else {
            return .init(.notGranted, detail: "Enable automatic checks and downloads through PersonaStack's existing updater.")
        }
        return .init(.ready, detail: "Sparkle checks for updates and downloads approved updates without forcing a restart.")
    }

    private func setup(_ id: DesktopPermissionID) async -> DesktopPermissionObservation? {
        synchronizeOwner()
        switch id {
        case .accessibility: return adapter.accessibilityObservation()
        case .screenRecording, .directCapture: return await setupCua(id)
        case .microphone: return await setupMicrophone()
        case .automaticUpdates:
            DesktopUpdater.shared.start()
            if DesktopUpdater.shared.isAvailable {
                DesktopUpdater.shared.automaticallyChecksForUpdates = true
                DesktopUpdater.shared.automaticallyDownloadsUpdates = true
            }
            return observeUpdates()
        case .desktopFiles, .documentsFiles, .downloadsFiles: return await setupDirectory(id)
        case .removableVolumes, .networkVolumes: return await volumeCheck.setup(id)
        case .fullDiskAccess: return await setupProtectedAccess()
        case .localNetwork, .messagingConnection: return await setupConnection(id)
        case .awakeDuringRemoteWork:
            guard verifyPowerAvailability() else {
                return .init(.failed, detail: "PersonaStack could not verify idle sleep prevention. Retry setup after the Mac recovers.")
            }
            let value = DesktopPermissionObservation(.ready, detail: "PersonaStack verified that it can prevent idle system sleep during remote work.",
                                                     verificationKey: ownerKey, requiresVerification: true, verified: true)
            explicitObservations[id] = value
            return value
        case .lockedScreenControl:
            let alert = NSAlert()
            alert.messageText = "Locked-Screen Control Is Not Available Yet"
            alert.informativeText = "A signed helper must first prove safe unattended access to this Mac. Current remote control remains unavailable while the screen is locked."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return await observe(id) ?? DesktopPermissionChecklistSystemAdapter.unconfiguredObservation(id)
        default: return nil
        }
    }

    private func verifyAutomatically(_ id: DesktopPermissionID) async -> DesktopPermissionObservation? {
        synchronizeOwner()
        guard !Task.isCancelled else { return .init(.checking, detail: "Check cancelled.") }
        switch id {
        case .accessibility: return adapter.accessibilityObservation()
        case .screenRecording: return await setupCua(id, automatic: true)
        case .microphone: return await setupMicrophone()
        case .fullDiskAccess: return await setupProtectedAccess(automatic: true)
        case .localNetwork: return await setupConnection(id)
        default: return await observe(id)
        }
    }

    private func setupCua(_ id: DesktopPermissionID, automatic: Bool = false) async -> DesktopPermissionObservation {
        do {
            let runtime = cuaRuntime
            let old = try? await runtime.cuaPermissionSnapshot()
            try Task.checkCancellation()
            if let old, old.accessibility != adapter.access.accessibility() || old.screenRecording != adapter.access.screenRecording() {
                if automatic {
                    return .init(.restartRequired, detail: "The desktop runtime needs a permission refresh. Choose Setup to restart its permission check.")
                }
                try await runtime.restartCuaAfterPermissionChange()
            } else if automatic { try await runtime.prepareCuaPermissionsAutomatically() }
            else { try await runtime.prepareCuaPermissions() }
            try Task.checkCancellation()
            let snapshot = try await runtime.cuaPermissionSnapshot()
            guard snapshot.hostAttributionValid else { throw CuaMCPProxyError.serviceMismatch }
            let result = await observeCua(id)
            guard result.state == .ready else { return result }
            guard adapter.access.accessibility() else {
                return .init(.verificationRequired, detail: "Screen access was requested. Set up Accessibility, then retry Setup \(id.title) to verify PersonaStack's desktop capture.")
            }
            if automatic { try await runtime.verifyCuaCapabilitiesAutomatically() }
            else { try await runtime.verifyCuaCapabilitiesForPermissions() }
            try Task.checkCancellation()
            let verified = await observeCua(id)
            return Self.finishCuaVerification(id, initial: result, current: verified)
        } catch is CancellationError { return .init(.checking, detail: "Setup cancelled.") }
        catch let error as DesktopPermissionAutomaticCheckError { return error.observation }
        catch let error as DesktopInputPermissionVerificationError { return .init(.failed, detail: error.localizedDescription) }
        catch let error as CuaMCPProxyError { return .init(.failed, detail: error.localizedDescription) }
        catch { return .init(.failed, detail: "PersonaStack's desktop runtime could not complete the \(id.title) check. Quit and reopen PersonaStack, then retry Setup \(id.title).") }
    }

    static func finishCuaVerification(_ id: DesktopPermissionID, initial: DesktopPermissionObservation,
                                      current: DesktopPermissionObservation) -> DesktopPermissionObservation {
        guard current.state == .ready else { return current }
        guard initial.state == .ready, let key = initial.verificationKey, !key.isEmpty, current.verificationKey == key else {
            return .init(.checking, detail: "Desktop access changed during verification. Retry Setup \(id.title).")
        }
        return .init(.ready, detail: "PersonaStack's desktop runtime verified screen capture and accessibility reads.",
                     verificationKey: key, requiresVerification: true, verified: true)
    }

    private func setupMicrophone() async -> DesktopPermissionObservation {
        // A failed retry must never fall back to an earlier successful recording.
        explicitObservations.removeValue(forKey: .microphone)
        guard let observed = observeMicrophone(), observed.state == .ready,
              let context = voiceContext() else { return await adapter.observe(.microphone) }
        let generation = verificationGeneration
        do {
            let result = try await voiceVerifier.verify(page: context.page) { [weak self] in
                guard let self else { return false }
                return self.verificationGeneration == generation &&
                    self.observeMicrophone()?.verificationKey == observed.verificationKey
            }
            try Task.checkCancellation()
            guard result else { throw DesktopVoicePermissionError.recordingFailed }
            let value = DesktopPermissionObservation(.ready,
                detail: "PersonaStack verified WebKit microphone recording. The test audio was discarded.",
                verificationKey: observed.verificationKey, requiresVerification: true, verified: true)
            explicitObservations[.microphone] = value
            return value
        } catch is CancellationError { return .init(.checking, detail: "Setup cancelled.") }
        catch let error as DesktopVoicePermissionError { return error.observation }
        catch { return DesktopVoicePermissionError.recordingFailed.observation }
    }

    private func setupDirectory(_ id: DesktopPermissionID) async -> DesktopPermissionObservation {
        let directory: FileManager.SearchPathDirectory
        switch id {
        case .desktopFiles: directory = .desktopDirectory
        case .documentsFiles: directory = .documentDirectory
        default: directory = .downloadsDirectory
        }
        let key = evidenceKey(id)
        explicitObservations.removeValue(forKey: id)
        guard let url = directoryURL(directory) else {
            return directoryResult(id, state: .failed, detail: "The selected directory is unavailable on this Mac.", key: key)
        }
        do {
            try await verifyDirectory(url)
            try Task.checkCancellation()
            return directoryResult(id, state: .ready,
                detail: "PersonaStack verified listing, writing, reading and removing its disposable file. No existing file content was read.", key: key)
        } catch DesktopFileSystemError.permissionDenied {
            return directoryResult(id, state: .denied,
                detail: "File access was denied. Review PersonaStack in Files and Folders settings and check this folder's permissions, then retry.", key: key)
        } catch {
            return directoryResult(id, state: .failed,
                detail: "PersonaStack could not verify read/write access and disposable-file cleanup. Check that the folder is available and writable, then retry.", key: key)
        }
    }

    private func setupProtectedAccess(automatic: Bool = false) async -> DesktopPermissionObservation {
        guard !Task.isCancelled, protectedAccessAttempt == nil else {
            return .init(.checking, detail: "The protected-access check is busy or was cancelled.")
        }
        let attempt = UUID()
        let key = "\(ownerKey):\(protectedAccessGeneration)"
        protectedAccessAttempt = attempt
        defer { if protectedAccessAttempt == attempt { protectedAccessAttempt = nil } }
        let action: DesktopProtectedAccessSetupAction
        if automatic { action = .check }
        else if let protectedAccessAction { action = await protectedAccessAction() }
        else { action = await window.protectedAccessSetupAction() }
        guard protectedAccessIsCurrent(attempt, key: key) else { return protectedAccessChanged() }
        switch action {
        case .cancel:
            return explicitObservations[.fullDiskAccess] ?? .init(.checking, detail: "Protected-access check cancelled.")
        case .settings:
            authorizedRefreshKeys.removeValue(forKey: .fullDiskAccess)
            return protectedAccessResult(.notGranted, detail: "Enable PersonaStack in Full Disk Access settings. If it is missing, click + and select PersonaStack.app from Applications. Return here and choose Setup Full Disk Access, then Check Access. Quit and reopen PersonaStack if macOS requests it.", attempt: attempt, key: key)
        case .check: break
        }
        refreshNeeded.remove(.fullDiskAccess)
        return await checkProtectedAccess(attempt: attempt, key: key)
    }

    private func observeProtectedAccess() async -> DesktopPermissionObservation {
        let key = "\(ownerKey):\(protectedAccessGeneration)"
        if authorizedRefreshKeys[.fullDiskAccess] != key {
            authorizedRefreshKeys.removeValue(forKey: .fullDiskAccess)
        }
        if explicitObservations[.fullDiskAccess]?.verificationKey != key {
            explicitObservations.removeValue(forKey: .fullDiskAccess)
        }
        if refreshNeeded.contains(.fullDiskAccess), authorizedRefreshKeys[.fullDiskAccess] == key,
           protectedAccessAttempt == nil {
            refreshNeeded.remove(.fullDiskAccess)
            let attempt = UUID()
            protectedAccessAttempt = attempt
            defer { if protectedAccessAttempt == attempt { protectedAccessAttempt = nil } }
            return await checkProtectedAccess(attempt: attempt, key: key)
        }
        return explicitObservations[.fullDiskAccess] ?? DesktopPermissionChecklistSystemAdapter.unconfiguredObservation(.fullDiskAccess)
    }

    private func checkProtectedAccess(attempt: UUID, key: String) async -> DesktopPermissionObservation {
        explicitObservations.removeValue(forKey: .fullDiskAccess)
        do {
            try await verifyProtectedAccess()
            return protectedAccessResult(.ready, detail: "Protected-folder access verified for PersonaStack. The Mail or Messages folder listing succeeded. No file contents were read or changed. Other folders can still have separate access restrictions.", attempt: attempt, key: key)
        } catch {
            let failure = error as NSError
            if failure.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(failure.code) {
                return protectedAccessResult(.denied, detail: "Protected-folder access was blocked. Enable PersonaStack in Full Disk Access settings. If it is already enabled, quit and reopen PersonaStack, then choose Check Access again. Folder permissions or Mac policy can also block access.", attempt: attempt, key: key)
            }
            if failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT) {
                return protectedAccessResult(.verificationRequired, detail: "No protected Mail or Messages folder is available to check. Full Disk Access could not be verified on this Mac. Review PersonaStack in Full Disk Access settings. This optional check does not block setup.", attempt: attempt, key: key)
            }
            return protectedAccessResult(.failed, detail: "PersonaStack could not verify protected-folder access. Check that your Library folder and its Mail or Messages folder are available and are not redirected, then retry Check Access. Full Disk Access remains unverified.", attempt: attempt, key: key)
        }
    }

    private func protectedAccessIsCurrent(_ attempt: UUID, key: String) -> Bool {
        !Task.isCancelled && protectedAccessAttempt == attempt && key == "\(ownerKey):\(protectedAccessGeneration)"
    }

    private func protectedAccessChanged() -> DesktopPermissionObservation {
        .init(.checking, detail: "Setup changed or was cancelled. Retry Setup Full Disk Access.")
    }

    private func protectedAccessResult(_ state: DesktopPermissionState, detail: String,
                                       attempt: UUID, key: String) -> DesktopPermissionObservation {
        guard protectedAccessIsCurrent(attempt, key: key) else { return protectedAccessChanged() }
        let result = DesktopPermissionObservation(state, detail: detail, verificationKey: key,
                                                 requiresVerification: state == .ready, verified: state == .ready)
        authorizedRefreshKeys[.fullDiskAccess] = state == .ready ? key : nil
        explicitObservations[.fullDiskAccess] = result
        return result
    }

    private func directoryResult(_ id: DesktopPermissionID, state: DesktopPermissionState,
                                 detail: String, key: String) -> DesktopPermissionObservation {
        guard !Task.isCancelled, key == evidenceKey(id) else {
            return .init(.checking, detail: "Setup changed or was cancelled. Retry the file access check.")
        }
        let result = DesktopPermissionObservation(state, detail: detail, verificationKey: key,
                                                 requiresVerification: state == .ready, verified: state == .ready)
        explicitObservations[id] = result
        return result
    }

    private func observeConnection(_ id: DesktopPermissionID, detail: String) async -> DesktopPermissionObservation {
        let key = evidenceKey(id)
        if authorizedRefreshKeys[id] != key { authorizedRefreshKeys.removeValue(forKey: id) }
        if explicitObservations[id]?.verificationKey != key { explicitObservations.removeValue(forKey: id) }
        if refreshNeeded.contains(id), authorizedRefreshKeys[id] == key, connectionAttempts[id] == nil {
            return await setupConnection(id)
        }
        return evidence(id, detail: detail)
    }

    private static func responseMatchesEndpoint(_ responseURL: URL?, _ endpoint: URL) -> Bool {
        guard let responseURL, responseURL.user == nil, responseURL.password == nil,
              responseURL.query == nil, responseURL.fragment == nil,
              (try? DesktopControlEnvironment.origin(responseURL)) == (try? DesktopControlEnvironment.origin(endpoint)) else { return false }
        // URLSession may canonicalize an empty root path to a slash.
        return (responseURL.path.isEmpty ? "/" : responseURL.path) == (endpoint.path.isEmpty ? "/" : endpoint.path)
    }

    private func setupConnection(_ id: DesktopPermissionID) async -> DesktopPermissionObservation {
        guard !Task.isCancelled, let profile else { return .init(.notGranted, detail: "Configure the selected server environment first.") }
        if id == .localNetwork {
            if profile == .production { return .init(.notNeeded, detail: "The selected PersonaStack cloud services do not require LAN access.") }
            if #unavailable(macOS 15) { return .init(.notNeeded, detail: "This macOS version has no Local Network privacy approval.") }
        }
        let key = evidenceKey(id)
        let attempt = UUID()
        let generation = verificationGeneration
        connectionAttempts[id] = attempt
        refreshNeeded.remove(id)
        explicitObservations.removeValue(forKey: id)
        defer { if connectionAttempts[id] == attempt { connectionAttempts.removeValue(forKey: id) } }
        let endpoints = id == .localNetwork ? [profile.appURL, profile.gatewayURL, profile.mcpURL] : [profile.appURL]
        let value: DesktopPermissionObservation
        do {
            for endpoint in endpoints {
                try Task.checkCancellation()
                guard generation == verificationGeneration, key == evidenceKey(id), connectionAttempts[id] == attempt else { throw CancellationError() }
                var request = URLRequest(url: endpoint)
                request.httpMethod = "HEAD"
                request.timeoutInterval = 4
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let response = try await requestEndpoint(request)
                guard Self.responseMatchesEndpoint(response.url, endpoint) else { throw URLError(.badServerResponse) }
            }
            value = .init(.ready, detail: "The configured service endpoints responded. Account and relay authorization are verified by the existing setup flow.",
                          verificationKey: key, requiresVerification: true, verified: true)
        } catch {
            value = .init(.failed, detail: "The selected service could not be reached directly. Check network approval, DNS, service availability, and certificate settings. Retry after recovery.", verificationKey: key)
        }
        guard !Task.isCancelled, generation == verificationGeneration, key == evidenceKey(id), connectionAttempts[id] == attempt else {
            return .init(.checking, detail: "Setup changed or was cancelled. Retry the connection check.")
        }
        authorizedRefreshKeys[id] = value.state == .ready ? key : nil
        explicitObservations[id] = value
        return value
    }
}
