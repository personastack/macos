import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import PersonaStackCore
import WebKit

/// Composes the checklist with existing app owners. Stored observations are
/// content-free evidence from explicit checks, never persisted OS grants.
@MainActor
final class DesktopPermissionChecklist {
    static let shared = DesktopPermissionChecklist()
    let window: DesktopPermissionChecklistWindow
    private let adapter: DesktopPermissionChecklistSystemAdapter
    private var explicitObservations: [DesktopPermissionID: DesktopPermissionObservation] = [:]
    private var activationObserver: NSObjectProtocol?
    private var mediaTestID: String?
    private weak var mediaTestView: WKWebView?

    func cancelVerification() {
        explicitObservations.removeAll()
        if let id = mediaTestID { stopMediaTest(id: id) }
    }

    private func stopMediaTest(id: String) {
        guard mediaTestID == id else { return }
        let view = mediaTestView
        mediaTestID = nil
        mediaTestView = nil
        view?.callAsyncJavaScript("""
            const test = window.__personastackPermissionMicrophoneTest;
            if (test && test.id === expectedID) {
                test.cancelled = true;
                if (test.stream) test.stream.getTracks().forEach((track) => track.stop());
                if (test.abort) test.abort();
            }
            """, arguments: ["expectedID": id], in: nil, in: .page, completionHandler: nil)
    }

    private init() {
        let adapter = DesktopPermissionChecklistSystemAdapter()
        self.adapter = adapter
        window = DesktopPermissionChecklistWindow(coordinator: DesktopPermissionChecklistCoordinator(adapter: adapter))
        window.onPresent = { [weak self] in self?.cancelVerification() }
        adapter.hooks = .init(
            observe: { [weak self] in await self?.observe($0) },
            setup: { [weak self] in await self?.setup($0) }
        )
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.explicitObservations.removeAll()
                await self?.window.coordinator.refresh()
            }
        }
    }

    private var profile: DesktopEnvironmentConfiguration? { try? LaunchConfiguration.selectedEnvironment() }
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
            return evidence(id, detail: "Use Setup \(id.title) to verify directory access. No existing file content is read.")
        case .awakeDuringRemoteWork:
            return .init(.unsupported, detail: "Task-scoped sleep prevention will be enabled with the verified locked-control helper.")
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
                     verificationKey: "\(ownerKey):microphone:\(input.uniqueID)", requiresVerification: true)
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
        case .lockedScreenControl, .awakeDuringRemoteWork:
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
            let verified = await observeCua(id)
            return .init(verified.state, detail: "PersonaStack's desktop runtime verified screen capture and accessibility reads.",
                         verificationKey: verified.verificationKey, requiresVerification: true, verified: verified.state == .ready)
        } catch is CancellationError { return .init(.checking, detail: "Setup cancelled.") }
        catch { return .init(.failed, detail: "Desktop access could not be verified. Review PersonaStack's permissions and retry. A full app relaunch may be needed.") }
    }

    private func setupMicrophone() async -> DesktopPermissionObservation {
        guard let observed = observeMicrophone(), observed.state == .ready else {
            if let observation = observeMicrophone() { return observation }
            return await adapter.observe(.microphone)
        }
        let view = MainWebViewHost.shared.webView
        guard let url = view.url, let expected = profile?.appURL,
              (try? DesktopControlEnvironment.origin(url)) == (try? DesktopControlEnvironment.origin(expected)) else {
            return .init(.failed, detail: "Open the selected PersonaStack app before testing voice input.")
        }
        do {
            let id = UUID().uuidString
            mediaTestID = id
            mediaTestView = view
            defer {
                if mediaTestID == id { mediaTestID = nil; mediaTestView = nil }
            }
            let result: Bool = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    view.callAsyncJavaScript("""
                if (!window.isSecureContext || !navigator.mediaDevices || typeof MediaRecorder === 'undefined') return false;
                const test = {id: testID, cancelled: false, stream: null, abort: null};
                window.__personastackPermissionMicrophoneTest = test;
                let timeout;
                try {
                    const media = navigator.mediaDevices.getUserMedia({audio: true});
                    media.then((stream) => {
                        if (test.cancelled) stream.getTracks().forEach((track) => track.stop());
                        else test.stream = stream;
                    }, () => {});
                    const stream = await Promise.race([media, new Promise((_, reject) => {
                        timeout = setTimeout(() => reject(new Error('permission test timeout')), 10000);
                    })]);
                    if (test.cancelled) return false;
                    const recorder = new MediaRecorder(stream);
                    return await new Promise((resolve) => {
                        let hasData = false;
                        test.abort = () => { if (recorder.state !== 'inactive') recorder.stop(); resolve(false); };
                        recorder.ondataavailable = (event) => { hasData = event.data.size > 0; };
                        recorder.onstop = () => resolve(hasData);
                        recorder.onerror = () => resolve(false);
                        recorder.start();
                        setTimeout(() => { if (recorder.state !== 'inactive') recorder.stop(); }, 200);
                    });
                } finally {
                    clearTimeout(timeout);
                    test.cancelled = true;
                    if (test.stream) test.stream.getTracks().forEach((track) => track.stop());
                    if (window.__personastackPermissionMicrophoneTest === test) delete window.__personastackPermissionMicrophoneTest;
                }
                """, arguments: ["testID": id], in: nil, in: .page) { result in
                        switch result {
                        case .success(let value): continuation.resume(returning: value as? Bool == true)
                        case .failure(let error): continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor in DesktopPermissionChecklist.shared.stopMediaTest(id: id) }
            }
            try Task.checkCancellation()
            guard result, observeMicrophone()?.verificationKey == observed.verificationKey else {
                return .init(.failed, detail: "WebKit could not record microphone input. Check the input device and retry.")
            }
            return .init(.ready, detail: "PersonaStack's WebKit microphone recording succeeded. The test audio was discarded.",
                         verificationKey: observed.verificationKey, requiresVerification: true, verified: true)
        } catch { return .init(.failed, detail: "WebKit could not record microphone input. Check the input device and retry.") }
    }

    private func setupDirectory(_ id: DesktopPermissionID) async -> DesktopPermissionObservation {
        let directory: FileManager.SearchPathDirectory
        switch id {
        case .desktopFiles: directory = .desktopDirectory
        case .documentsFiles: directory = .documentDirectory
        default: directory = .downloadsDirectory
        }
        guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else {
            return .init(.failed, detail: "The selected directory is unavailable on this Mac.")
        }
        do {
            _ = try await DesktopFileSystem().list(path: url.path, limit: 1)
            try Task.checkCancellation()
            let value = DesktopPermissionObservation(.ready, detail: "PersonaStack verified directory listing without reading existing file contents.",
                                                     verificationKey: ownerKey, requiresVerification: true, verified: true)
            explicitObservations[id] = value
            return value
        } catch { return .init(.failed, detail: "Directory access failed. Review PersonaStack in Files and Folders settings and retry.") }
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
