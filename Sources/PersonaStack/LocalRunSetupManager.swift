import AppKit
import CryptoKit
import PersonaStackCore

@MainActor
final class LocalRunSetupManager {
    static let shared = LocalRunSetupManager()
    private var preparing = false
    private static let installerURL = URL(string: "https://github.com/apple/container/releases/download/1.4.1/container-1.4.1-installer-signed.pkg")!
    nonisolated private static let installerDigest = "c0d2716afefbb194c93fae662e9cae7cc186bcbcf746816608ec673dd648a6a4"
    nonisolated fileprivate static let maximumInstallerBytes: Int64 = 128 * 1024 * 1024

    func ensureReady(isCurrent: @escaping @MainActor () -> Bool) async throws {
        guard !preparing else { throw LocalRunError.setupInProgress }
        preparing = true
        defer { preparing = false }
        let runtime = LocalRunContainer()
        do { try await runtime.preflight(); return }
        catch LocalRunError.runtimeMissing {
            try await install(isCurrent: isCurrent)
            do { try await runtime.preflight(); return }
            catch LocalRunError.runtimeUnavailable { /* Installation completed. Start the service below. */ }
        }
        catch LocalRunError.runtimeUnavailable {
            guard confirm("Start local runs", "PersonaStack will start Apple's container runtime and download its recommended Linux kernel if needed. Mac localhost access also requires Apple's host integration setup.", action: "Start Runtime", hostSetup: true) else {
                throw LocalRunError.setupCancelled
            }
        }
        catch { showFailure(error); throw error }
        guard isCurrent() else { throw LocalRunError.staleSession }
        let progress = showProgress("Preparing local runs…")
        defer { progress.close() }
        do {
            try await runtime.startService()
            guard isCurrent() else { throw LocalRunError.staleSession }
            try await runtime.preflight()
        } catch { progress.close(); showFailure(error); throw error }
    }

    private func install(isCurrent: @escaping @MainActor () -> Bool) async throws {
        guard confirm("Set up local runs", "Install Apple's container runtime 1.4.1 to run this persona on your Mac. PersonaStack will download the verified installer and open macOS Installer. macOS will ask you to approve installation. PersonaStack will then start the runtime and download its recommended Linux kernel. Mac localhost access also requires Apple's host integration setup.", action: "Install Runtime", hostSetup: true) else {
            throw LocalRunError.setupCancelled
        }
        guard isCurrent() else { throw LocalRunError.staleSession }
        let progress = showProgress("Downloading Apple's container runtime…")
        defer { progress.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("personastack-runtime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = directory.appendingPathComponent("container-installer.pkg")
        do {
            try await Self.downloadInstaller(to: installer)
            progress.close()
            guard isCurrent() else { throw LocalRunError.staleSession }
            guard NSWorkspace.shared.open(installer) else { throw LocalRunError.setupFailed }
            while true {
                guard confirm("Finish installing the runtime", "Complete installation in macOS Installer. Then choose Continue to prepare your local agent.", action: "Continue") else {
                    throw LocalRunError.setupCancelled
                }
                guard isCurrent() else { throw LocalRunError.staleSession }
                do { try await LocalRunContainer().preflight(); return }
                catch LocalRunError.runtimeUnavailable { return }
                catch LocalRunError.runtimeMissing { showFailure(LocalRunError.runtimeMissing) }
            }
        } catch {
            progress.close()
            if error as? LocalRunError != .setupCancelled && error as? LocalRunError != .staleSession { showFailure(error) }
            throw error
        }
    }

    private static func downloadInstaller(to destination: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(from: installerURL, delegate: LocalRunInstallerDownloadDelegate())
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw LocalRunError.setupFailed }
        try await Task.detached(priority: .utility) {
            try verifyInstaller(at: temporary)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }.value
    }

    nonisolated static func verifyInstaller(at url: URL, expectedDigest: String = installerDigest) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        var bytes = 0
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            bytes += chunk.count
            guard bytes <= maximumInstallerBytes else { throw LocalRunError.setupFailed }
            hash.update(data: chunk)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expectedDigest else { throw LocalRunError.setupFailed }
    }

    private func confirm(_ title: String, _ message: String, action: String, hostSetup: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: action); alert.addButton(withTitle: "Cancel")
        if hostSetup { alert.addButton(withTitle: "Mac Localhost Setup") }
        while true {
            let response = alert.runModal()
            if hostSetup && response == .alertThirdButtonReturn {
                NSWorkspace.shared.open(URL(string: "https://github.com/apple/container/blob/1.4.1/docs/host-integration.md")!)
            } else { return response == .alertFirstButtonReturn }
        }
    }

    private func showFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Local runs need setup"
        alert.informativeText = (error as? LocalRunError)?.rawValue ?? LocalRunError.setupFailed.rawValue
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showProgress(_ title: String) -> NSWindow {
        let alert = NSAlert()
        alert.messageText = title
        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        spinner.style = .spinning; spinner.startAnimation(nil)
        alert.accessoryView = spinner
        alert.window.center(); alert.window.makeKeyAndOrderFront(nil)
        return alert.window
    }
}

private final class LocalRunInstallerDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let limit = LocalRunSetupManager.maximumInstallerBytes
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
}
