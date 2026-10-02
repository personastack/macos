import Foundation
import PersonaStackCore
import Testing

@Suite
struct DesktopDownloadDestinationTests {
    @Test func repeatedDownloadPreservesExistingFilesAndTheirExtension() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try #require(DesktopDownloadDestination.choose(suggestedFilename: "report.csv", directory: directory))
        try Data("original".utf8).write(to: first)
        let second = try #require(DesktopDownloadDestination.choose(suggestedFilename: "report.csv", directory: directory))
        try Data("second".utf8).write(to: second)
        let third = try #require(DesktopDownloadDestination.choose(suggestedFilename: "report.csv", directory: directory))

        #expect(first.lastPathComponent == "report.csv")
        #expect(second.lastPathComponent == "report (1).csv")
        #expect(third.lastPathComponent == "report (2).csv")
        #expect(try String(contentsOf: first, encoding: .utf8) == "original")
        #expect(!FileManager.default.fileExists(atPath: third.path))
    }

    @Test func webProvidedPathsStayInsideTheDownloadDirectoryAndSkipDanglingLinks() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("report.csv")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("absent"))
        for filename in ["../../report.csv", "/report.csv", "report.csv"] {
            let result = try #require(DesktopDownloadDestination.choose(suggestedFilename: filename, directory: directory))
            #expect(result.deletingLastPathComponent() == directory)
            #expect(result.lastPathComponent == "report (1).csv")
        }
        for filename in ["", ".", "..", "/", "bad\u{0}name"] {
            let result = try #require(DesktopDownloadDestination.choose(suggestedFilename: filename, directory: directory))
            #expect(result.lastPathComponent == "download")
            #expect(result.deletingLastPathComponent() == directory)
        }
    }

    @Test func collisionSuffixFitsTheFilesystemNameLimitWithoutLosingTheExtension() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let filename = String(repeating: "a", count: 251) + ".txt"
        let first = try #require(DesktopDownloadDestination.choose(suggestedFilename: filename, directory: directory))
        try Data().write(to: first)
        let second = try #require(DesktopDownloadDestination.choose(suggestedFilename: filename, directory: directory))
        #expect(first != second)
        #expect(second.lastPathComponent.utf8.count <= 255)
        #expect(second.lastPathComponent.hasSuffix(" (1).txt"))
        try Data().write(to: second)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesktopDownloadDestinationTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
