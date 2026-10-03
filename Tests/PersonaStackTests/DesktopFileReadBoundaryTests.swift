import Foundation
import Testing
@testable import PersonaStackCore

struct DesktopFileReadBoundaryTests {
    @Test func longUTF8SampleKeepsBytePagesAligned() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("unicode.txt")
        let content = String(repeating: "😀", count: DesktopFileSystem.maxReadBytes / 4 + 2)
        try Data(content.utf8).write(to: file)
        let files = DesktopFileSystem()
        let opened = try await files.open(path: file.path)
        let page = try await files.read(id: opened.id, offset: 0, length: 5)
        #expect(String(data: page.content, encoding: .utf8) == "😀")
        #expect(page.nextOffset == 4)
        #expect(!page.endOfFile)
        await files.closeAll()
    }
}
