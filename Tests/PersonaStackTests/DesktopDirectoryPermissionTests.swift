import AppKit
import Darwin
import Foundation
import Testing
@testable import PersonaStack
@testable import PersonaStackCore

private func directoryPermissionFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("personastack-directory-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
    return root
}

struct DesktopDirectoryPermissionTests {
    @Test func verifiesOwnReadWriteAndCleanupWithoutReadingExistingFileContents() async throws {
        let root = try directoryPermissionFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("existing.txt")
        let bytes = Data("existing fixture content".utf8)
        try bytes.write(to: original)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: original.path)
        let files = DesktopFileSystem()
        try await files.verifyDirectoryAccess(path: root.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["existing.txt"])
        #expect(await files.openHandleCount() == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
        #expect(try Data(contentsOf: original) == bytes)
    }

    @Test(arguments: [false, true])
    func collisionPreservesExistingFileOrSymlink(isSymlink: Bool) async throws {
        let root = try directoryPermissionFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let probe = root.appendingPathComponent(".personastack-permission-check-\(id.uuidString)")
        let target = root.appendingPathComponent("target.txt")
        let bytes = Data("never overwrite".utf8)
        if isSymlink {
            try bytes.write(to: target)
            try FileManager.default.createSymbolicLink(at: probe, withDestinationURL: target)
        } else { try bytes.write(to: probe) }
        let files = DesktopFileSystem()
        await #expect(throws: DesktopFileSystemError.destinationExists) {
            try await files.verifyDirectoryAccess(path: root.path, probeID: id)
        }
        #expect(try Data(contentsOf: isSymlink ? target : probe) == bytes)
        if isSymlink {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: probe.path) == target.path)
        }
        #expect(await files.openHandleCount() == 0)
    }

    @Test(arguments: [0o000, 0o500])
    func deniedListingOrWriteCannotSucceedOrLeaveProbeFiles(mode: Int) async throws {
        let root = try directoryPermissionFixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: root.path)
        let files = DesktopFileSystem()
        await #expect(throws: DesktopFileSystemError.permissionDenied) {
            try await files.verifyDirectoryAccess(path: root.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(await files.openHandleCount() == 0)
    }

    @Test func missingAndNonDirectoryResourcesStayIncomplete() async throws {
        let root = try directoryPermissionFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("fixture".utf8).write(to: file)
        let files = DesktopFileSystem()
        for path in [file.path, root.appendingPathComponent("missing").path] {
            await #expect(throws: DesktopFileSystemError.notDirectory) {
                try await files.verifyDirectoryAccess(path: path)
            }
        }
        for path in ["", "relative", root.path + "\0"] {
            await #expect(throws: DesktopFileSystemError.invalidPath) {
                try await files.verifyDirectoryAccess(path: path)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["file.txt"])
    }

    @Test @MainActor func canceledCheckBeforeExecutionHasNoFileSideEffects() async throws {
        let root = try directoryPermissionFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = DesktopFileSystem()
        // MainActor keeps the task from starting before this synchronous cancel.
        let check = Task { try await files.verifyDirectoryAccess(path: root.path) }
        check.cancel()
        await #expect(throws: CancellationError.self) { try await check.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(await files.openHandleCount() == 0)
    }

    @Test func cleanupPreservesAReplacementInode() throws {
        let root = try directoryPermissionFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("probe")
        try Data("owned marker".utf8).write(to: file)
        let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { _ = Darwin.close(descriptor) }
        let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(directory >= 0)
        defer { _ = Darwin.close(directory) }
        var identity = stat()
        #expect(fstat(descriptor, &identity) == 0)
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: file, to: moved)
        let replacement = Data("replacement fixture".utf8)
        try replacement.write(to: file)
        #expect(throws: DesktopFileSystemError.destinationExists) {
            try DesktopFileSystem.removeDirectoryVerificationFile(directory: directory, name: "probe", identity: identity)
        }
        #expect(try Data(contentsOf: file) == replacement)
        #expect(try Data(contentsOf: moved) == Data("owned marker".utf8))
    }

    @Test func selectedVolumeMismatchHasNoFileSideEffects() async throws {
        let root = try directoryPermissionFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(directory >= 0)
        defer { _ = Darwin.close(directory) }
        var mounted = statfs()
        #expect(fstatfs(directory, &mounted) == 0)
        let wrong = DesktopFileSystemVolumeID(first: mounted.f_fsid.val.0 &+ 1, second: mounted.f_fsid.val.1)
        let files = DesktopFileSystem()
        await #expect(throws: DesktopFileSystemError.patchMismatch) {
            try await files.verifyDirectoryAccess(path: root.path, expectedVolumeID: wrong)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func readOnlyCheckListsWithoutCreatingOrReadingExistingFiles() async throws {
        let root = try directoryPermissionFixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let existing = root.appendingPathComponent("existing")
        try Data("unchanged fixture".utf8).write(to: existing)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: existing.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        try await DesktopFileSystem().verifyDirectoryAccess(path: root.path, readOnly: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["existing"])
    }

    @Test func markerStaysInOpenedDirectoryAfterItsPathIsReplaced() throws {
        let root = try directoryPermissionFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let directory = Darwin.open(selected.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(directory >= 0)
        defer { _ = Darwin.close(directory) }
        try FileManager.default.moveItem(at: selected, to: moved)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let marker = UUID()
        let foreign = selected.appendingPathComponent(".personastack-permission-check-\(marker.uuidString)")
        let original = Data("replacement mount fixture".utf8)
        try original.write(to: foreign)
        try DesktopFileSystem.verifyDirectoryAccess(descriptor: directory, probeID: marker, expectedVolumeID: nil, readOnly: false)
        #expect(try Data(contentsOf: foreign) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }
}

@Test @MainActor func directoryPermissionPassiveRefreshDoesNotProbeOrOpenSettings() async {
    var settings: [String] = []
    var setups = 0
    let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(
        observe: { _ in .init(.checking, detail: "Use Setup") },
        setup: { _ in setups += 1; Issue.record("Passive refresh requested a probe"); return nil }
    ), openSettings: { settings.append($0) })
    for id in [DesktopPermissionID.desktopFiles, .documentsFiles, .downloadsFiles] {
        #expect(await adapter.observe(id).state == .checking)
    }
    #expect(setups == 0 && settings.isEmpty)
}

@Test @MainActor func directoryPermissionDeniedExplicitSetupOpensOnlyFilesAndFoldersSettings() async {
    for id in [DesktopPermissionID.desktopFiles, .documentsFiles, .downloadsFiles] {
        var settings: [String] = []
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(setup: { actual in
            #expect(actual == id)
            return .init(.denied, detail: "Denied")
        }), openSettings: { settings.append($0) })
        #expect(await adapter.setup(id).state == .denied)
        #expect(settings == ["com.apple.preference.security?Privacy_FilesAndFolders"])
    }
}

@Test @MainActor func directoryPermissionUnavailableResourceDoesNotPretendApprovalIsTheCause() async {
    var settings: [String] = []
    let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(setup: { _ in
        .init(.failed, detail: "Unavailable")
    }), openSettings: { settings.append($0) })
    #expect(await adapter.setup(.desktopFiles).state == .failed)
    #expect(settings.isEmpty)
}

@Test @MainActor func directoryPermissionCanceledResultCannotOpenSystemSettings() async {
    var settings: [String] = []
    var pending: CheckedContinuation<DesktopPermissionObservation, Never>?
    let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(setup: { _ in
        await withCheckedContinuation { pending = $0 }
    }), openSettings: { settings.append($0) })
    let task = Task { await adapter.setup(.documentsFiles) }
    while pending == nil { await Task.yield() }
    task.cancel()
    pending?.resume(returning: .init(.denied, detail: "Late denied result"))
    #expect(await task.value.state == .checking)
    #expect(settings.isEmpty)
}

@Test @MainActor func directoryPermissionServiceChecksEachSelectedFolderAndPollingRetainsOnlyItsResult() async throws {
    let root = try directoryPermissionFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var requested: [FileManager.SearchPathDirectory] = []
    var verified: [URL] = []
    let service = DesktopPermissionChecklist(directoryURL: { directory in
        requested.append(directory)
        return root.appendingPathComponent(String(directory.rawValue), isDirectory: true)
    }, verifyDirectory: { verified.append($0) }, selectedProfile: { .production })
    for (id, directory) in [(DesktopPermissionID.desktopFiles, FileManager.SearchPathDirectory.desktopDirectory),
                            (.documentsFiles, .documentDirectory), (.downloadsFiles, .downloadsDirectory)] {
        #expect(await service.adapter.observe(id).state == .checking)
        let result = await service.adapter.setup(id)
        #expect(result.state == .ready && result.verified)
        #expect(result.requiresVerification && result.verificationKey != nil)
        #expect(requested.last == directory)
        #expect(verified.last == root.appendingPathComponent(String(directory.rawValue), isDirectory: true))
        #expect(await service.adapter.observe(id) == result)
    }
    #expect(requested == [.desktopDirectory, .documentDirectory, .downloadsDirectory])
    #expect(verified.count == 3)
}

@Test @MainActor func directoryPermissionServiceFailureReplacesOldProofAndSurvivesPassivePolling() async {
    var shouldFail = false
    var checks = 0
    let service = DesktopPermissionChecklist(directoryURL: { _ in URL(fileURLWithPath: "/fake-directory") },
        verifyDirectory: { _ in
            checks += 1
            if shouldFail { throw DesktopFileSystemError.patchMismatch }
        }, selectedProfile: { .production })
    #expect(await service.adapter.setup(.desktopFiles).state == .ready)
    shouldFail = true
    let failure = await service.adapter.setup(.desktopFiles)
    #expect(failure.state == .failed && !failure.verified)
    #expect(await service.adapter.observe(.desktopFiles) == failure)
    #expect(checks == 2)
    #expect(await service.adapter.observe(.documentsFiles).state == .checking)
    service.cancelVerification()
    #expect(await service.adapter.observe(.desktopFiles).state == .checking)
    #expect(checks == 2)
}

@Test @MainActor func directoryPermissionServiceUnavailableDirectoryDoesNotRunAProbe() async {
    var checks = 0
    let service = DesktopPermissionChecklist(directoryURL: { _ in nil }, verifyDirectory: { _ in
        checks += 1
        Issue.record("Missing directory must not be probed")
    }, selectedProfile: { .production })
    let result = await service.adapter.setup(.documentsFiles)
    #expect(result.state == .failed && !result.verified)
    #expect(await service.adapter.observe(.documentsFiles) == result)
    #expect(checks == 0)
}

@Test @MainActor func directoryPermissionServiceEnvironmentChangeFencesLateProof() async {
    var profile = DesktopEnvironmentConfiguration.production
    var pending: CheckedContinuation<Void, Never>?
    let service = DesktopPermissionChecklist(directoryURL: { _ in URL(fileURLWithPath: "/fake-directory") },
        verifyDirectory: { _ in await withCheckedContinuation { pending = $0 } }, selectedProfile: { profile })
    let check = Task { await service.adapter.setup(.downloadsFiles) }
    while pending == nil { await Task.yield() }
    profile = .lan
    pending?.resume()
    let result = await check.value
    #expect(result.state == .checking && !result.verified)
    #expect(await service.adapter.observe(.downloadsFiles).state == .checking)
}

@Test @MainActor func directoryPermissionServiceCancellationCannotStoreProof() async {
    var pending: CheckedContinuation<Void, Never>?
    let service = DesktopPermissionChecklist(directoryURL: { _ in URL(fileURLWithPath: "/fake-directory") },
        verifyDirectory: { _ in await withCheckedContinuation { pending = $0 } }, selectedProfile: { .production })
    let check = Task { await service.adapter.setup(.desktopFiles) }
    while pending == nil { await Task.yield() }
    check.cancel()
    pending?.resume()
    #expect(await check.value.state == .checking)
    #expect(await service.adapter.observe(.desktopFiles).state == .checking)
}

@Test @MainActor func directoryPermissionVolumeServiceInvalidatesProofBeforeMountPolling() async {
    let notifications = NotificationCenter()
    let mount = DesktopVolumePermissionMount(url: URL(fileURLWithPath: "/fake-mounted-volume"),
        fileSystemIDFirst: 1, fileSystemIDSecond: 2, fileSystemType: "apfs", flags: UInt32(MNT_LOCAL | MNT_REMOVABLE))
    var selections = 0
    var checks = 0
    let service = DesktopPermissionChecklist(selectedProfile: { .production }, volumeSnapshot: { [mount] },
        chooseVolume: { id, mounts in
            #expect(id == .removableVolumes && mounts == [mount])
            selections += 1
            return mount
        }, verifyVolume: { selected in
            #expect(selected == mount)
            checks += 1
        }, mountNotificationCenter: notifications)
    let hooks = service.adapter.hooks
    service.adapter.hooks.observe = { id in
        if id == .removableVolumes || id == .networkVolumes { return await hooks.observe(id) }
        return .init(.ready, detail: "Fake independent capability")
    }
    let model = service.window.coordinator
    model.open()
    await model.refresh()
    #expect(!model.canFinish && selections == 0 && checks == 0)
    model.setup(.removableVolumes)
    while model.busyPermission != nil { await Task.yield() }
    #expect(model.canFinish && selections == 1 && checks == 1)
    notifications.post(name: NSWorkspace.didUnmountNotification, object: nil)
    #expect(!model.canFinish)
    #expect(model.rows.first { $0.id == .removableVolumes }?.state == .checking)
    await model.refresh()
    #expect(!model.canFinish && selections == 1 && checks == 1)
    #expect(await service.adapter.setup(.removableVolumes).state == .ready)
    service.cancelVerification()
    #expect(await service.adapter.observe(.removableVolumes).state == .checking)
    #expect(selections == 2 && checks == 2)
    model.cancel()
}
