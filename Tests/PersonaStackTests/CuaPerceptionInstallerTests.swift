import Foundation
import Darwin
import PersonaStackCore
import Testing
@testable import PersonaStack

private struct PerceptionFixtureRunner: CuaProcessRunning {
    let result: CuaProcessResult
    let expectedArguments: [String]
    func run(_ executable: URL, arguments: [String]) throws -> CuaProcessResult {
        #expect(arguments == expectedArguments)
        guard arguments == expectedArguments else { throw CuaPerceptionError.commandFailed }
        return result
    }
}

private struct PerceptionNoDownload: CuaPerceptionDownloading {
    func download(_ url: URL, to destination: URL, maximumBytes: Int64) async throws {
        Issue.record("Unexpected network staging")
        throw CuaPerceptionError.invalidArtifact
    }
}

private func perceptionDriverFixture() -> CuaDriverInstallation {
    CuaDriverInstallation(applicationURL: URL(fileURLWithPath: "/test/CuaDriver.app"),
                          executableURL: URL(fileURLWithPath: "/test/cua-driver"),
                          version: CuaDriverCompatibility.version, toolNames: [])
}

private func perceptionReviewFixture() -> [String: Any] {
    // Shape follows pinned extension_manager.rs InstallReview and install_review.
    ["extension": "perception", "id": "cua-perception", "name": "Cua Perception",
     "artifact": "cua-perception 0.2.1", "backend": "icon detection and OCR", "acceleration": "CPU",
     "version": "0.2.1", "target": "aarch64-apple-darwin",
     "trust": "publisher-verified", "evidence_class": "production-publisher-verified", "publisher_id": "cua",
     "publisher_key_id": "cua-extension-ed25519-2026-09", "publisher_signature_verified": true, "catalog_version": 2_609_260_017,
     "archive_sha256": CuaPerceptionCompatibility.archiveSHA256,
     "manifest_sha256": CuaPerceptionCompatibility.manifestSHA256,
     "download_size": CuaPerceptionCompatibility.archiveBytes, "mutation_performed": false,
     "publisher": "Cua", "publisher_name": "Cua", "signing_key_algorithm": "ed25519",
     "signing_key_status": "verified", "catalog_expires_unix": 1821917841,
     "artifact_source": "/test/staging/cua-perception-0.2.1-aarch64-apple-darwin.tar.gz",
     "source": "https://github.com/trycua/cua", "corresponding_source_uri": "source/cua-perception-source.tar.gz",
     "corresponding_source_revision": "6aa37d0751d094bfe8fdc2df331ed9eae934c832",
     "authorization": ["request": "cli-inspect", "confirmation_required": false, "confirmation_received": false,
                       "mutation_authorized": false, "mutation_performed": false],
     "installed": false, "ran": false, "destination": "/test/extensions/cua-perception", "license": "LicenseRef-Mixed", "installed_size": 900_000_000,
     "license_notices": [["component": "detector", "license": "AGPL-3.0-only"]],
     "model_licenses": [["model": "detector", "file": ["path": "LICENSE"]]]]
}

@Test func perceptionReviewPinsPublisherTargetAndArtifact() throws {
    let fixture = perceptionReviewFixture()
    let review = try CuaPerceptionInstaller.validatedReview(JSONSerialization.data(withJSONObject: fixture))
    #expect(review.license == "LicenseRef-Mixed")
    #expect(review.displayJSON.contains("AGPL-3.0-only"))
    #expect(review.installedBytes == 900_000_000)
    for (key, value) in [("trust", "developer-unsigned-local"), ("target", "x86_64-apple-darwin"),
                         ("publisher_id", "other"), ("version", "0.2.2"), ("archive_sha256", "bad")] {
        var invalid = fixture
        invalid[key] = value
        #expect(throws: CuaPerceptionError.invalidReview) {
            try CuaPerceptionInstaller.validatedReview(JSONSerialization.data(withJSONObject: invalid))
        }
    }
    var mutated = fixture
    mutated["mutation_performed"] = true
    #expect(throws: CuaPerceptionError.invalidReview) {
        try CuaPerceptionInstaller.validatedReview(JSONSerialization.data(withJSONObject: mutated))
    }
}

@Test func perceptionInstallRequiresExactLocallyPreparedReview() async throws {
    let installer = CuaPerceptionInstaller(
        processRunner: PerceptionFixtureRunner(result: CuaProcessResult(status: 0, stdout: Data(), stderr: Data()), expectedArguments: []),
        downloader: PerceptionNoDownload(), supportedArchitecture: true)
    let review = try CuaPerceptionInstaller.validatedReview(JSONSerialization.data(withJSONObject: perceptionReviewFixture()))
    await #expect(throws: CuaPerceptionError.approvalRequired) { try await installer.install(review: review) }
}

@Test func perceptionIntelRefusesBeforeStagingOrProcess() async throws {
    let installer = CuaPerceptionInstaller(
        processRunner: PerceptionFixtureRunner(result: CuaProcessResult(status: 0, stdout: Data(), stderr: Data()), expectedArguments: []),
        downloader: PerceptionNoDownload(), supportedArchitecture: false)
    await #expect(throws: CuaPerceptionError.unsupportedArchitecture) {
        try await installer.prepareReview(driver: perceptionDriverFixture())
    }
    await #expect(throws: CuaPerceptionError.unsupportedArchitecture) {
        try await installer.status(driver: perceptionDriverFixture())
    }
}

@Test func perceptionStagingRejectsSpecialFileWithoutWaitingForWriter() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perception-fifo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let catalog = directory.appendingPathComponent(CuaPerceptionCompatibility.artifact + ".catalog.json")
    #expect(mkfifo(catalog.path, 0o600) == 0)
    let installer = CuaPerceptionInstaller(cacheDirectory: directory,
        processRunner: PerceptionFixtureRunner(result: CuaProcessResult(status: 0, stdout: Data(), stderr: Data()), expectedArguments: []),
        downloader: PerceptionNoDownload(), supportedArchitecture: true)
    await #expect(throws: CuaPerceptionError.invalidArtifact) {
        try await installer.prepareReview(driver: perceptionDriverFixture())
    }
}

@Test func perceptionStatusUsesHealthCommandWithoutInstallOrSelfTest() async throws {
    let data = Data(#"{"id":"cua-perception","installed":true,"healthy":true,"active_version":"0.2.1","trust":"publisher-verified","evidence_class":"production-publisher-verified","publisher_id":"cua","publisher_key_id":"cua-extension-ed25519-2026-09","catalog_version":2609260017}"#.utf8)
    let installer = CuaPerceptionInstaller(
        processRunner: PerceptionFixtureRunner(result: CuaProcessResult(status: 0, stdout: data, stderr: Data()),
                                               expectedArguments: ["extension", "status", "cua-perception", "--json"]),
        downloader: PerceptionNoDownload(), supportedArchitecture: true)
    #expect(try await installer.status(driver: perceptionDriverFixture()).ready)
}

@Test func perceptionStatusRefusesUnsignedInstalledExtension() async throws {
    let data = Data(#"{"id":"cua-perception","installed":true,"healthy":true,"active_version":"0.2.1","trust":"developer-unsigned-local"}"#.utf8)
    let installer = CuaPerceptionInstaller(
        processRunner: PerceptionFixtureRunner(result: CuaProcessResult(status: 0, stdout: data, stderr: Data()),
                                               expectedArguments: ["extension", "status", "cua-perception", "--json"]),
        downloader: PerceptionNoDownload(), supportedArchitecture: true)
    await #expect(throws: CuaPerceptionError.invalidReview) { try await installer.status(driver: perceptionDriverFixture()) }
}

private actor DeferredPerceptionFixture: CuaPerceptionInstalling {
    let review: CuaPerceptionInstallReview
    let deferStatus: Bool
    var completion: CheckedContinuation<CuaPerceptionStatus, Never>?
    var started = false
    var startedWaiter: CheckedContinuation<Void, Never>?
    init(review: CuaPerceptionInstallReview, deferStatus: Bool = false) {
        self.review = review
        self.deferStatus = deferStatus
    }
    var catalogURL: URL { URL(fileURLWithPath: "/test/catalog.json") }
    func prepareReview(driver: CuaDriverInstallation) async throws -> CuaPerceptionInstallReview { review }
    func install(review: CuaPerceptionInstallReview) async throws -> CuaPerceptionStatus { await deferred() }
    func status(driver: CuaDriverInstallation) async throws -> CuaPerceptionStatus {
        if deferStatus { return await deferred() }
        return CuaPerceptionStatus(installed: false, healthy: false, version: nil)
    }
    func cancelReview() async {}
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func finish() {
        completion?.resume(returning: CuaPerceptionStatus(installed: true, healthy: true, version: "0.2.1"))
        completion = nil
    }
    private func deferred() async -> CuaPerceptionStatus {
        await withCheckedContinuation {
            completion = $0
            started = true
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }
}

@MainActor @Test func perceptionCancelSuppressesLateInstallReadiness() async throws {
    let review = try CuaPerceptionInstaller.validatedReview(JSONSerialization.data(withJSONObject: perceptionReviewFixture()))
    let installer = DeferredPerceptionFixture(review: review)
    let controller = DesktopPerceptionSetupController(installer: installer)
    await controller.prepare(driver: perceptionDriverFixture())
    #expect(controller.review != nil)
    let task = Task { await controller.confirmInstall() }
    await installer.waitUntilStarted()
    await controller.cancel()
    await installer.finish()
    #expect(await task.value == false)
    #expect(controller.status == nil)
    #expect(controller.review == nil)
    #expect(controller.isWorking == false)
}

@MainActor @Test func perceptionCancelSuppressesLateStatusReadiness() async throws {
    let review = try CuaPerceptionInstaller.validatedReview(JSONSerialization.data(withJSONObject: perceptionReviewFixture()))
    let installer = DeferredPerceptionFixture(review: review, deferStatus: true)
    let controller = DesktopPerceptionSetupController(installer: installer)
    let task = Task { await controller.refresh(driver: perceptionDriverFixture()) }
    await installer.waitUntilStarted()
    await controller.cancel()
    await installer.finish()
    await task.value
    #expect(controller.status == nil)
    #expect(controller.failure == nil)
}
