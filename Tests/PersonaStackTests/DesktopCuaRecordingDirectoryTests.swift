import Darwin
import Foundation
import Testing
import PersonaStackCore

struct DesktopCuaRecordingDirectoryTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func createsExclusivePrivateDirectoryWithoutOverwritingExistingData() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("recording")
        let recording = try DesktopCuaRecordingDirectory(path: destination.path)
        var info = stat()
        #expect(lstat(recording.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        #expect(info.st_uid == getuid())
        #expect(await recording.isWithinBudget())
        let evidence = destination.appendingPathComponent("evidence.txt")
        try Data("retain".utf8).write(to: evidence)
        #expect(throws: DesktopFileSystemError.destinationExists) {
            _ = try DesktopCuaRecordingDirectory(path: destination.path)
        }
        #expect(throws: DesktopFileSystemError.destinationExists) {
            _ = try DesktopCuaRecordingDirectory(path: evidence.path)
        }
        #expect(try Data(contentsOf: evidence) == Data("retain".utf8))
    }

    @Test func existingSymlinkIsRefusedAndNestedSymlinkFailsBudgetCheck() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let sentinel = existing.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: existing)
        #expect(throws: DesktopFileSystemError.destinationExists) {
            _ = try DesktopCuaRecordingDirectory(path: alias.path)
        }
        let recording = try DesktopCuaRecordingDirectory(path: root.appendingPathComponent("new").path)
        try FileManager.default.createSymbolicLink(atPath: recording.path + "/escape", withDestinationPath: existing.path)
        #expect(!(await recording.isWithinBudget()))
        #expect(try Data(contentsOf: sentinel) == Data("untouched".utf8))
    }

    @Test func logicalSparseFileSizeEnforcesBudgetOnEveryInspection() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = try DesktopCuaRecordingDirectory(path: root.appendingPathComponent("recording").path)
        let fd = Darwin.open(recording.path + "/sparse", O_CREAT | O_EXCL | O_WRONLY, 0o600)
        #expect(fd >= 0)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        #expect(ftruncate(fd, off_t(DesktopCuaRecordingDirectory.maximumBytes)) == 0)
        #expect(await recording.isWithinBudget())
        #expect(ftruncate(fd, off_t(DesktopCuaRecordingDirectory.maximumBytes + 1)) == 0)
        #expect(!(await recording.isWithinBudget()))
        #expect(!(await recording.isWithinBudget()))
    }
}
