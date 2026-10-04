import Foundation
import Testing
@testable import PersonaStackCore

struct DesktopSkillFilesTests {
    private let origin = URL(string: "https://my.personastack.ai")!
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("skill-transfer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private var artifacts: [LocalSessionSkillFile] {
        [.init(relativePath: "SKILL.md", content: "---\nname: review\ndescription: Review code.\n---\nReview it.\n"), .init(relativePath: "references/checklist.md", content: "Keep original bytes.\r\n")]
    }

    @Test func roundTripAndBaselineKeepWorkspaceAndRevisionIdentity() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = DesktopSkillFiles(metadataRoot: root.appendingPathComponent("metadata"))
        let downloaded = try files.write(root: root, name: "review", files: artifacts, expectedDigest: "", overwrite: false, origin: origin)
        #expect(downloaded.files == artifacts)
        let baseline = DesktopSkillBaseline(workspaceID: "ws_11111111111111111111111111111111", skillID: "catalog-skill", configID: "config-skill", revision: 3, configVersion: 4, digest: downloaded.digest)
        try files.saveBaseline(baseline, directory: downloaded.directory, origin: origin)
        let uploaded = try #require(files.list(root, origin: origin).first)
        #expect(uploaded.baseline == baseline)
        #expect(uploaded.files == artifacts)
        #expect(try files.read(uploaded.directory, origin: URL(string: "https://other.example")!).baseline == nil)
    }

    @Test func conflictRequiresCurrentDigestAndExplicitOverwrite() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = DesktopSkillFiles(metadataRoot: root.appendingPathComponent("metadata"))
        let first = try files.write(root: root, name: "review", files: artifacts, expectedDigest: "", overwrite: false, origin: origin)
        try Data("Local edits".utf8).write(to: first.directory.appendingPathComponent("references/checklist.md"))
        #expect(throws: LocalSessionError.staleRequest) { try files.write(root: root, name: "review", files: artifacts, expectedDigest: first.digest, overwrite: true, origin: origin) }
        let changed = try files.read(first.directory, origin: origin)
        #expect(throws: LocalSessionError.unsafeFiles) { try files.write(root: root, name: "review", files: artifacts, expectedDigest: changed.digest, overwrite: false, origin: origin) }
        #expect(try files.read(first.directory, origin: origin).digest == changed.digest)
        let replaced = try files.write(root: root, name: "review", files: artifacts, expectedDigest: changed.digest, overwrite: true, origin: origin)
        #expect(replaced.digest == first.digest)
    }

    @Test func downloadPreservesUnrelatedDestinationFiles() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = DesktopSkillFiles(metadataRoot: root.appendingPathComponent("metadata"))
        let first = try files.write(root: root, name: "review", files: artifacts, expectedDigest: "", overwrite: false, origin: origin)
        try Data("User note".utf8).write(to: first.directory.appendingPathComponent("note.txt"))
        let current = try files.read(first.directory, origin: origin)
        let written = try files.write(root: root, name: "review", files: artifacts, expectedDigest: current.digest, overwrite: true, origin: origin)
        #expect(written.files.contains(.init(relativePath: "note.txt", content: "User note")))
        #expect(written.digest != first.digest)
    }

    @Test(arguments: ["bytes", "count", "collision"])
    func plannedMergeIsRejectedBeforeChangingAnyDestinationBytes(limit: String) throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = DesktopSkillFiles(metadataRoot: root.appendingPathComponent("metadata"))
        let retained: [LocalSessionSkillFile]
        let incoming: [LocalSessionSkillFile]
        switch limit {
        case "bytes":
            retained = [.init(relativePath: "retained.txt", content: String(repeating: "a", count: 300 * 1024))]
            incoming = [.init(relativePath: "SKILL.md", content: "Changed skill"), .init(relativePath: "incoming.txt", content: String(repeating: "b", count: 300 * 1024))]
        case "count":
            retained = (0..<126).map { .init(relativePath: "retained-\($0).txt", content: "Keep \($0)") }
            incoming = [.init(relativePath: "SKILL.md", content: "Changed skill"), .init(relativePath: "incoming-one.txt", content: "New"), .init(relativePath: "incoming-two.txt", content: "New")]
        default:
            retained = [.init(relativePath: "note.txt", content: "Keep")]
            incoming = [.init(relativePath: "SKILL.md", content: "Changed skill"), .init(relativePath: "note.txt/child.txt", content: "New")]
        }
        let original = [.init(relativePath: "SKILL.md", content: "Original skill")] + retained
        let first = try files.write(root: root, name: "review", files: original, expectedDigest: "", overwrite: false, origin: origin)
        let before = try Dictionary(uniqueKeysWithValues: first.files.map { ($0.relativePath, try Data(contentsOf: first.directory.appendingPathComponent($0.relativePath))) })
        #expect(throws: LocalSessionError.invalidBundle) {
            try files.write(root: root, name: "review", files: incoming, expectedDigest: first.digest, overwrite: true, origin: origin)
        }
        let after = try files.read(first.directory, origin: origin)
        #expect(after.digest == first.digest)
        #expect(after.files == first.files)
        for (path, bytes) in before { #expect(try Data(contentsOf: first.directory.appendingPathComponent(path)) == bytes) }
    }

    @Test func rejectsSymlinksTraversalBinaryAndOversizeBeforeMutation() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = DesktopSkillFiles(metadataRoot: root.appendingPathComponent("metadata"))
        for name in ["../bad", "/bad", ".hidden", "a/b"] {
            #expect(throws: LocalSessionError.invalidRequest) { try files.write(root: root, name: name, files: artifacts, expectedDigest: "", overwrite: false, origin: origin) }
        }
        let invalid = artifacts + [.init(relativePath: "../outside", content: "No")]
        #expect(throws: LocalSessionError.invalidBundle) { try files.write(root: root, name: "bad", files: invalid, expectedDigest: "", overwrite: false, origin: origin) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("bad").path))
        let skill = try files.write(root: root, name: "review", files: artifacts, expectedDigest: "", overwrite: false, origin: origin)
        let link = skill.directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: LocalSessionError.unsafeFiles) { try files.read(skill.directory, origin: origin) }
        try FileManager.default.removeItem(at: link)
        let binary = skill.directory.appendingPathComponent("binary")
        try Data([0xff, 0xfe]).write(to: binary)
        #expect(throws: LocalSessionError.unsafeFiles) { try files.read(skill.directory, origin: origin) }
        try FileManager.default.removeItem(at: binary)
        let large = artifacts + [.init(relativePath: "large", content: String(repeating: "a", count: 512 * 1024))]
        #expect(throws: LocalSessionError.invalidBundle) { try files.write(root: root, name: "oversize", files: large, expectedDigest: "", overwrite: false, origin: origin) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("oversize").path))
    }

    @Test func baselineCannotHideLaterLocalChanges() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = DesktopSkillFiles(metadataRoot: root.appendingPathComponent("metadata"))
        let first = try files.write(root: root, name: "review", files: artifacts, expectedDigest: "", overwrite: false, origin: origin)
        try Data("Changed".utf8).write(to: first.directory.appendingPathComponent("SKILL.md"))
        #expect(throws: LocalSessionError.staleRequest) {
            try files.saveBaseline(.init(workspaceID: "ws_11111111111111111111111111111111", skillID: "skill", configID: "config", revision: 1, configVersion: 1, digest: first.digest), directory: first.directory, origin: origin)
        }
    }
    @Test func unsupportedNeighborIsVisibleWithoutBlockingAValidSkill() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = DesktopSkillFiles(metadataRoot: root.appendingPathComponent("metadata"))
        _ = try files.write(root: root, name: "review", files: artifacts, expectedDigest: "", overwrite: false, origin: origin)
        let bad = root.appendingPathComponent("unsupported")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: false)
        try Data("Skill".utf8).write(to: bad.appendingPathComponent("SKILL.md"))
        try Data([0xff]).write(to: bad.appendingPathComponent("binary"))
        let listing = try files.previewList(root, origin: origin)
        #expect(listing.skills.map(\.name) == ["review"])
        #expect(listing.errors.map(\.name) == ["unsupported"])
        #expect(throws: LocalSessionError.unsafeFiles) { try files.list(root, origin: origin) }
    }

}
