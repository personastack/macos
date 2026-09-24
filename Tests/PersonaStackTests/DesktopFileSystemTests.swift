import Foundation
import Testing
@testable import PersonaStackCore

struct DesktopFileSystemTests {
    @Test func openFileHandleLimitIsEnforcedAndHandlesCanBeReleased() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("handle-limit.txt")
        try Data("open".utf8).write(to: file)
        let fs = DesktopFileSystem()
        var handles: [UUID] = []
        for _ in 0..<DesktopFileSystem.maxOpenFiles {
            handles.append(try await fs.open(path: file.path).id)
        }

        await #expect(throws: DesktopFileSystemError.tooManyOpenFiles) {
            try await fs.open(path: file.path)
        }
        for handle in handles { try await fs.close(id: handle) }
        #expect(try await fs.open(path: file.path).firstRead.content == Data("open".utf8))
    }

    @Test func openReturnsContentAndPaginatesReads() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.txt")
        try Data("first\nsecond\n".utf8).write(to: file)

        let fs = DesktopFileSystem()
        let opened = try await fs.open(path: file.path)
        #expect(String(decoding: opened.firstRead.content, as: UTF8.self) == "first\nsecond\n")
        #expect(opened.firstRead.endOfFile)
        let second = try await fs.read(id: opened.id, offset: 6, length: 6)
        #expect(String(decoding: second.content, as: UTF8.self) == "second")
        try await fs.close(id: opened.id)
        await #expect(throws: DesktopFileSystemError.missingHandle) { try await fs.read(id: opened.id, offset: 0) }
    }

    @Test func directoryPagesReturnEveryPathWithoutMaterializingTheDirectory() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["b.txt", "a.txt", "c.txt"] { try Data().write(to: root.appendingPathComponent(name)) }

        let fs = DesktopFileSystem()
        let first = try await fs.list(path: root.path, limit: 2)
        let second = try await fs.list(path: root.path, offset: first.nextOffset ?? -1, limit: 2)
        #expect(Set(first.entries.map(\.name) + second.entries.map(\.name)) == Set(["a.txt", "b.txt", "c.txt"]))
        #expect(second.nextOffset == nil)
    }

    @Test func metadataReportsFileAndDirectoryEntries() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("details.txt")
        try Data("metadata".utf8).write(to: file)
        let fs = DesktopFileSystem()

        let fileEntry = try await fs.metadata(path: file.path)
        #expect(fileEntry.kind == .file)
        #expect(fileEntry.size == 8)
        #expect(fileEntry.name == "details.txt")
        #expect(try await fs.metadata(path: root.path).kind == .directory)
        await #expect(throws: DesktopFileSystemError.invalidPath) { try await fs.metadata(path: root.appendingPathComponent("missing").path) }
    }

    @Test func directoryPermissionDenialIsPreservedForDesktopDiagnostics() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        let fs = DesktopFileSystem()

        await #expect(throws: DesktopFileSystemError.permissionDenied) { try await fs.list(path: root.path) }
    }

    @Test func directoryOperationsResolveExplicitSymlinkRoots() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data().write(to: target.appendingPathComponent("entry"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let fs = DesktopFileSystem()
        #expect(try await fs.list(path: link.path).entries.map(\.name) == ["entry"])
        #expect(try await fs.search(root: link.path, nameContains: "entry").map(\.name) == ["entry"])
    }

    @Test func explicitOpenFollowsSymlinkAndRemoveUnlinksIt() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.txt")
        let link = root.appendingPathComponent("link.txt")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let fs = DesktopFileSystem()
        let opened = try await fs.open(path: link.path)
        #expect(opened.path == target.path)
        try await fs.close(id: opened.id)
        try await fs.remove(path: link.path)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: link.path))
    }

    @Test func writesRequireExplicitModeAndPatchRequiresExpectedText() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("edit.txt").path
        let fs = DesktopFileSystem()

        _ = try await fs.write(path: path, content: Data("alpha beta".utf8), mode: .create)
        await #expect(throws: DesktopFileSystemError.destinationExists) {
            try await fs.write(path: path, content: Data("overwrite".utf8), mode: .create)
        }
        _ = try await fs.patch(path: path, expected: "beta", replacement: "gamma")
        await #expect(throws: DesktopFileSystemError.patchMismatch) {
            try await fs.patch(path: path, expected: "missing", replacement: "ignored")
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "alpha gamma")
    }

    @Test func pagedReadsReportConcurrentSizeChanges() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("changing.txt")
        try Data("before".utf8).write(to: path)
        let fs = DesktopFileSystem()
        let opened = try await fs.open(path: path.path)
        try Data("after plus more".utf8).write(to: path)
        let read = try await fs.read(id: opened.id, offset: 0)
        #expect(read.changedSinceOpen)
        try await fs.close(id: opened.id)
    }

    @Test func pathsMustBeAbsoluteAndRangesAreBounded() async throws {
        let fs = DesktopFileSystem()
        await #expect(throws: DesktopFileSystemError.notDirectory) { try await fs.list(path: "relative") }
        await #expect(throws: DesktopFileSystemError.invalidPath) {
            try await fs.write(path: "relative", content: Data(), mode: .create)
        }
    }

    @Test func openRejectsFifoWithoutBlockingAndCreateNeverOverwrites() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let fs = DesktopFileSystem()
        await #expect(throws: DesktopFileSystemError.notRegularFile) { try await fs.open(path: fifo.path) }

        let file = root.appendingPathComponent("created")
        try Data("original".utf8).write(to: file)
        await #expect(throws: DesktopFileSystemError.destinationExists) {
            try await fs.write(path: file.path, content: Data("new".utf8), mode: .create)
        }
        #expect(try Data(contentsOf: file) == Data("original".utf8))
    }

    @Test func patchRequiresOneMatchAndEnforcesFileBound() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("patch.txt")
        try Data("same and same".utf8).write(to: path)
        let fs = DesktopFileSystem()
        await #expect(throws: DesktopFileSystemError.patchMismatch) {
            try await fs.patch(path: path.path, expected: "same", replacement: "new")
        }
        try Data(repeating: 97, count: 4 * 1024 * 1024 + 1).write(to: path)
        await #expect(throws: DesktopFileSystemError.patchMismatch) {
            try await fs.patch(path: path.path, expected: "a", replacement: "b")
        }
        try Data("marker".utf8).write(to: path)
        await #expect(throws: DesktopFileSystemError.contentTooLarge) {
            try await fs.patch(path: path.path, expected: "marker", replacement: String(repeating: "x", count: 4 * 1024 * 1024 + 1))
        }
    }

    @Test func openContinuesReadingAfterPathIsUnlinkedAndReplacePreservesMode() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.txt")
        try Data(repeating: 97, count: DesktopFileSystem.maxReadBytes + 20).write(to: file)
        let fs = DesktopFileSystem()
        let opened = try await fs.open(path: file.path)
        try FileManager.default.removeItem(at: file)
        let tail = try await fs.read(id: opened.id, offset: UInt64(DesktopFileSystem.maxReadBytes))
        #expect(tail.content.count == 20)
        #expect(tail.endOfFile)
        try await fs.close(id: opened.id)

        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: file.path)
        _ = try await fs.write(path: file.path, content: Data("new".utf8), mode: .replace)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o751)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-control-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
