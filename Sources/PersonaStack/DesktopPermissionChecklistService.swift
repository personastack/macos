import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import PersonaStackCore
import WebKit

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
    private var inputTest: DesktopInputPermissionWindow?

    func cancelVerification() {
        verificationGeneration = UUID()
        explicitObservations.removeAll()
        invalidateProtectedAccessVerification()
        window.coordinator.invalidateVerification(.microphone)
        invalidateVolumeVerification()
        inputTest?.invalidate()
        inputTest = nil
        voiceVerifier.invalidate()
    }

    init(directoryURL: @escaping (FileManager.SearchPathDirectory) -> URL? = {
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
         activationNotificationCenter: NotificationCenter = .default) {
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
        self.verifyProtectedAccess = verifyProtectedAccess ?? {
            let files = DesktopFileSystem()
            try await files.verifyProtectedDirectoryAccess(home: FileManager.default.homeDirectoryForCurrentUser)
        }
        let adapter = DesktopPermissionChecklistSystemAdapter()
        self.adapter = adapter
        window = DesktopPermissionChecklistWindow(coordinator: DesktopPermissionChecklistCoordinator(adapter: adapter))
        window.onPresent = { [weak self] in self?.cancelVerification() }
        window.onCancel = { [weak self] in self?.cancelVerification() }
        adapter.hooks = .init(
            observe: { [weak self] in await self?.observe($0) },
            setup: { [weak self] in await self?.setup($0) }
        )
        activationObserver = activationNotificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateProtectedAccessVerification() }
            Task { @MainActor in
                self?.explicitObservations.removeAll()
                self?.invalidateVolumeVerification()
                await self?.window.coordinator.refresh()
            }
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            mountObservers.append(mountNotificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateVolumeVerification() }
                Task { @MainActor in await self?.window.coordinator.refresh() }
            })
        }
    }

    private func invalidateVolumeVerification() {
        volumeCheck.invalidate()
        for id in [DesktopPermissionID.removableVolumes, .networkVolumes] {
            window.cancelPermissionSelection(permission: id)
            window.coordinator.invalidateVerification(id)
        }
    }

    private func invalidateProtectedAccessVerification() {
        protectedAccessGeneration = UUID()
        protectedAccessAttempt = nil
        explicitObservations.removeValue(forKey: .fullDiskAccess)
        window.cancelPermissionSelection(permission: .fullDiskAccess)
        window.coordinator.invalidateVerification(.fullDiskAccess)
    }

    private var profile: DesktopEnvironmentConfiguration? { selectedProfile() }
    private var ownerKey: String {
        "\(Bundle.main.bundleIdentifier ?? "unpackaged"):\(profile?.preferenceIdentity ?? "unconfigured"):\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    private func observe(_ id: DesktopPermissionID) async -> DesktopPermissionObservation? {
        switch id {
        case .accessibility, .screenRecording, .directCapture:
            return await observeCua(id)
        case .microphone: return observeMicrophone()
        case .automaticUpdates: return observeUpdates()
        case .backgroundOperation:
            return .init(.ready, detail: "PersonaStack keeps its menu bar and existing relay alive when ordinary windows close.")
        case .messagingConnection:
            guard profile != nil else { return .init(.notGranted, detail: "Choose trusted App, Gateway, and MCP URLs in Server Settings.") }
            return evidence(id, detail: "Use Setup Messaging Connection to check the selected app endpoint. Enrollment is verified after Finish.")
        case .localNetwork:
            guard let profile else { return .init(.notGranted, detail: "Configure the selected server environment first.") }
            if #available(macOS 15, *) {
                if profile == .production { return .init(.notNeeded, detail: "The selected PersonaStack cloud services do not require LAN access.") }
                return evidence(id, detail: "Use Setup Local Network to connect to the configured services. macOS requests LAN approval when needed.")
            }
            return .init(.notNeeded, detail: "This macOS version has no Local Network privacy approval.")
        case .desktopFiles, .documentsFiles, .downloadsFiles:
            return evidence(id, detail: "Use Setup \(id.title) to verify listing and read/write access with a disposable file. No existing file content is read.")
        case .removableVolumes, .networkVolumes: return volumeCheck.observe(id)
        case .fullDiskAccess:
            let key = "\(ownerKey):\(protectedAccessGeneration)"
            if let result = explicitObservations[id], result.verificationKey == key { return result }
            explicitObservations.removeValue(forKey: id)
            return DesktopPermissionChecklistSystemAdapter.unconfiguredObservation(id)
        case .awakeDuringRemoteWork:
            return evidence(id, detail: "Use Setup Awake During Remote Work to verify idle sleep prevention. PersonaStack holds it only during a remote task.")
        default: return nil
        }
    }

    private func evidence(_ id: DesktopPermissionID, detail: String) -> DesktopPermissionObservation {
        if let result = explicitObservations[id], result.verificationKey == ownerKey { return result }
        return .init(.checking, detail: detail)
    }

    private func observeCua(_ id: DesktopPermissionID) async -> DesktopPermissionObservation {
        let allowed = id == .accessibility ? AXIsProcessTrusted() : CGPreflightScreenCaptureAccess()
        guard allowed else {
            return .init(.notGranted, detail: "Allow PersonaStack in Privacy & Security → \(id == .accessibility ? "Accessibility" : "Screen & System Audio Recording").")
        }
        guard let snapshot = try? await DesktopControlRuntime.shared.cuaPermissionSnapshot(), snapshot.hostAttributionValid else {
            return .init(.checking, detail: "Use Setup \(id.title) to start PersonaStack's owned desktop runtime and verify access.")
        }
        let granted = id == .accessibility ? snapshot.accessibility : snapshot.screenRecording
        return .init(granted ? .ready : .restartRequired,
                     detail: granted ? "PersonaStack has the OS grant. Use Setup \(id.title) to verify real desktop access."
                                     : "The desktop runtime needs a restart after the permission change.",
                     verificationKey: "\(ownerKey):\(snapshot.verificationKey):\(snapshot.accessibility):\(snapshot.screenRecording)",
                     requiresVerification: true)
    }

    private func observeMicrophone() -> DesktopPermissionObservation? {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return nil }
        guard let input = AVCaptureDevice.default(for: .audio) else {
            return .init(.failed, detail: "No microphone is available. Connect an audio input and retry.")
        }
        guard let appURL = profile?.appURL,
              DesktopMediaPermissionPolicy.isSecureContext(scheme: appURL.scheme ?? "", host: appURL.host ?? "") else {
            return .init(.unsupported, detail: "Voice recording needs an HTTPS app URL or a loopback development URL. Review Server Settings.")
        }
        return .init(.ready, detail: "Microphone access is allowed. Use Setup Microphone to test WebKit recording.",
                     verificationKey: "\(ownerKey):microphone:\(input.uniqueID):\(MainWebViewHost.shared.coordinator.documentGeneration.uuidString)",
                     requiresVerification: true)
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
        switch id {
        case .accessibility, .screenRecording, .directCapture: return await setupCua(id)
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
        case .notifications:
            let result = await adapter.observe(.notifications)
            guard result.state == .ready else { return result }
            do {
                guard try await DesktopNotificationCoordinator.shared.verifyPermissionDelivery() else {
                    return .init(.failed, detail: "macOS did not confirm the test notification. Review notification settings and retry.")
                }
                return .init(.ready, detail: "macOS confirmed PersonaStack's test notification.",
                             verificationKey: result.verificationKey, requiresVerification: true, verified: true)
            } catch { return .init(.failed, detail: "The test notification could not be delivered. Review notification settings and retry.") }
        case .awakeDuringRemoteWork:
            guard DesktopControlPowerAssertion.verifyAvailability() else {
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

    private func setupCua(_ id: DesktopPermissionID) async -> DesktopPermissionObservation {
        do {
            let runtime = DesktopControlRuntime.shared
            let old = try? await runtime.cuaPermissionSnapshot()
            if let old, old.accessibility != AXIsProcessTrusted() || old.screenRecording != CGPreflightScreenCaptureAccess() {
                try await runtime.restartCuaAfterPermissionChange()
            } else { try await runtime.prepareCuaPermissions() }
            try Task.checkCancellation()
            let result = await observeCua(id)
            guard result.state == .ready else { return result }
            try await runtime.verifyCuaCapabilitiesForPermissions()
            try Task.checkCancellation()
            if id == .accessibility {
                let target = DesktopInputPermissionWindow()
                inputTest = target
                defer {
                    target.invalidate()
                    if inputTest === target { inputTest = nil }
                }
                try await runtime.verifyCuaInputForPermissions(target: target)
                try Task.checkCancellation()
            }
            let verified = await observeCua(id)
            return Self.finishCuaVerification(id, initial: result, current: verified)
        } catch is CancellationError { return .init(.checking, detail: "Setup cancelled.") }
        catch let error as DesktopInputPermissionVerificationError { return .init(.failed, detail: error.localizedDescription) }
        catch { return .init(.failed, detail: "Desktop access could not be verified. Review PersonaStack's permissions and retry. A full app relaunch may be needed.") }
    }

    static func finishCuaVerification(_ id: DesktopPermissionID, initial: DesktopPermissionObservation,
                                      current: DesktopPermissionObservation) -> DesktopPermissionObservation {
        guard current.state == .ready else { return current }
        guard initial.state == .ready, let key = initial.verificationKey, !key.isEmpty, current.verificationKey == key else {
            return .init(.checking, detail: "Desktop access changed during verification. Retry Setup \(id.title).")
        }
        return .init(.ready, detail: id == .accessibility
                     ? "PersonaStack verified clicking and text input in its own test window."
                     : "PersonaStack's desktop runtime verified screen capture and accessibility reads.",
                     verificationKey: key, requiresVerification: true, verified: true)
    }

    private func setupMicrophone() async -> DesktopPermissionObservation {
        guard let observed = observeMicrophone(), observed.state == .ready else {
            if let observation = observeMicrophone() { return observation }
            return await adapter.observe(.microphone)
        }
        let host = MainWebViewHost.shared
        let view = host.webView
        guard let url = view.url, let expected = profile?.appURL,
              (try? DesktopControlEnvironment.origin(url)) == (try? DesktopControlEnvironment.origin(expected)) else {
            return .init(.failed, detail: "Open the selected PersonaStack app before testing voice input.")
        }
        let generation = verificationGeneration
        let document = host.coordinator.documentGeneration
        do {
            let result = try await voiceVerifier.verify(page: DesktopVoicePermissionWebPage(view: view)) { [weak self, weak host, weak view] in
                guard let self, let host, let view else { return false }
                return MainWebViewHost.shared === host && host.webView === view && view.url == url &&
                    !host.coordinator.isRetired && host.coordinator.documentGeneration == document &&
                    self.verificationGeneration == generation && self.observeMicrophone()?.verificationKey == observed.verificationKey
            }
            try Task.checkCancellation()
            guard result else {
                return .init(.failed, detail: "Voice recording could not be verified. Reload the selected PersonaStack page, check the microphone, and retry.")
            }
            return .init(.ready, detail: "PersonaStack's voice-message recorder succeeded. The test audio was discarded.",
                         verificationKey: observed.verificationKey, requiresVerification: true, verified: true)
        } catch is CancellationError { return .init(.checking, detail: "Setup cancelled.") }
        catch DesktopVoicePermissionError.pageChanged { return .init(.checking, detail: "The page or microphone changed. Retry Setup Microphone.") }
        catch { return .init(.failed, detail: "Voice recording could not be verified. Reload the selected PersonaStack page, check the microphone, and retry.") }
    }

    private func setupDirectory(_ id: DesktopPermissionID) async -> DesktopPermissionObservation {
        let directory: FileManager.SearchPathDirectory
        switch id {
        case .desktopFiles: directory = .desktopDirectory
        case .documentsFiles: directory = .documentDirectory
        default: directory = .downloadsDirectory
        }
        let key = ownerKey
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

    private func setupProtectedAccess() async -> DesktopPermissionObservation {
        guard !Task.isCancelled, protectedAccessAttempt == nil else {
            return .init(.checking, detail: "The protected-access check is busy or was cancelled.")
        }
        let attempt = UUID()
        let key = "\(ownerKey):\(protectedAccessGeneration)"
        protectedAccessAttempt = attempt
        explicitObservations.removeValue(forKey: .fullDiskAccess)
        defer { if protectedAccessAttempt == attempt { protectedAccessAttempt = nil } }
        let action: DesktopProtectedAccessSetupAction
        if let protectedAccessAction { action = await protectedAccessAction() }
        else { action = await window.protectedAccessSetupAction() }
        guard protectedAccessIsCurrent(attempt, key: key) else { return protectedAccessChanged() }
        switch action {
        case .cancel: return .init(.checking, detail: "Protected-access check cancelled. Full Disk Access remains unverified.")
        case .settings:
            return protectedAccessResult(.notGranted, detail: "Add the installed PersonaStack app in Full Disk Access settings. Relaunch if macOS asks, then retry Setup Full Disk Access. The grant remains unverified.", attempt: attempt, key: key)
        case .check: break
        }
        do {
            try await verifyProtectedAccess()
            return protectedAccessResult(.unsupported, detail: "PersonaStack could list the protected Mail directory. Entry names were discarded. No file content was read. This operation succeeded, but the Full Disk Access grant remains unqualified in this release.", attempt: attempt, key: key)
        } catch {
            let failure = error as NSError
            if failure.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(failure.code) {
                return protectedAccessResult(.denied, detail: "Protected-directory access was blocked. Review Full Disk Access and folder permissions. Mac policy may also deny access. Relaunch if macOS asks, then retry.", attempt: attempt, key: key)
            }
            return protectedAccessResult(.unsupported, detail: "The protected-directory check is unavailable or inconclusive. Full Disk Access remains unverified. No missing or redirected resource is treated as approval.", attempt: attempt, key: key)
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
        let result = DesktopPermissionObservation(state, detail: detail, verificationKey: key)
        explicitObservations[.fullDiskAccess] = result
        return result
    }

    private func directoryResult(_ id: DesktopPermissionID, state: DesktopPermissionState,
                                 detail: String, key: String) -> DesktopPermissionObservation {
        guard !Task.isCancelled, key == ownerKey else {
            return .init(.checking, detail: "Setup changed or was cancelled. Retry the file access check.")
        }
        let result = DesktopPermissionObservation(state, detail: detail, verificationKey: key,
                                                 requiresVerification: state == .ready, verified: state == .ready)
        explicitObservations[id] = result
        return result
    }

    private func setupConnection(_ id: DesktopPermissionID) async -> DesktopPermissionObservation {
        guard let profile else { return .init(.notGranted, detail: "Configure the selected server environment first.") }
        let key = ownerKey
        let endpoints = id == .localNetwork ? [profile.appURL, profile.gatewayURL, profile.mcpURL] : [profile.appURL]
        do {
            for endpoint in endpoints {
                try Task.checkCancellation()
                var request = URLRequest(url: endpoint)
                request.httpMethod = "HEAD"
                request.timeoutInterval = 4
                let (_, response) = try await URLSession.shared.data(for: request)
                guard response is HTTPURLResponse else { throw URLError(.badServerResponse) }
            }
            try Task.checkCancellation()
            guard key == ownerKey else { return .init(.checking, detail: "The selected server environment changed. Retry setup.") }
            let value = DesktopPermissionObservation(.ready, detail: "The configured service endpoints responded. Account and relay authorization are verified by the existing setup flow.",
                                                     verificationKey: key, requiresVerification: true, verified: true)
            explicitObservations[id] = value
            return value
        } catch { return .init(.failed, detail: "The selected service could not be reached. Check network approval, DNS, service availability, and certificate settings. Retry after recovery.") }
    }
}
