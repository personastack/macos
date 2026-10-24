import AppKit
import Foundation
import Testing
@testable import PersonaStack

@MainActor
struct DesktopDownloadNoticeTests {
    @Test func completedDownloadRevealsItsExactCollisionSafeFile() {
        let download = NSObject()
        let file = URL(fileURLWithPath: "/tmp/Downloads/Team (1).json")
        var revealed: [URL] = []
        var announcements: [String] = []
        let state = DesktopDownloadNotice(fileExists: { $0 == file }, revealFile: { revealed.append($0) },
                                          announce: { announcements.append($0) })
        state.track(ObjectIdentifier(download), destination: file)
        #expect(state.notice == nil)
        #expect(announcements.isEmpty)
        state.finished(ObjectIdentifier(download))
        #expect(state.notice?.title == "Download complete")
        #expect(state.notice?.detail == "Team (1).json")
        #expect(state.notice?.file == file)
        #expect(revealed.isEmpty)
        #expect(announcements == ["Download complete. Team (1).json. View File shows the file in Finder."])
        state.viewFile()
        #expect(revealed == [file])
        #expect(state.notice == nil)
    }

    @Test func failedAndUntrackedDownloadsCannotReportSuccessOrRevealFiles() {
        let download = NSObject()
        let state = DesktopDownloadNotice(fileExists: { _ in true }, revealFile: { _ in Issue.record("Failed download revealed a file") })
        let identifier = ObjectIdentifier(download)
        state.finished(identifier)
        #expect(state.notice == nil)
        state.track(identifier, destination: URL(fileURLWithPath: "/tmp/Downloads/Team.json"))
        state.failed(identifier)
        #expect(state.notice?.title == "Download failed")
        #expect(state.notice?.file == nil)
        state.viewFile()
        state.dismiss()
        state.finished(identifier)
        #expect(state.notice == nil)
    }

    @Test func missingOrMovedFilesNeverOfferAWorkingRevealAction() {
        let download = NSObject()
        var exists = true
        let file = URL(fileURLWithPath: "/tmp/Downloads/Team.json")
        let state = DesktopDownloadNotice(fileExists: { _ in exists }, revealFile: { _ in Issue.record("Missing file was revealed") })
        state.track(ObjectIdentifier(download), destination: file)
        state.finished(ObjectIdentifier(download))
        exists = false
        state.viewFile()
        #expect(state.notice?.title == "File unavailable")
        #expect(state.notice?.file == nil)
        state.track(ObjectIdentifier(download), destination: file)
        state.finished(ObjectIdentifier(download))
        #expect(state.notice?.title == "Download failed")
        #expect(state.notice?.file == nil)
    }

    @Test func overlappingDownloadsKeepTheirOwnDestination() {
        let first = NSObject()
        let second = NSObject()
        let firstFile = URL(fileURLWithPath: "/tmp/Downloads/First.json")
        let secondFile = URL(fileURLWithPath: "/tmp/Downloads/Second.json")
        var revealed: [URL] = []
        let state = DesktopDownloadNotice(fileExists: { _ in true }, revealFile: { revealed.append($0) })
        state.track(ObjectIdentifier(first), destination: firstFile)
        state.track(ObjectIdentifier(second), destination: secondFile)
        state.finished(ObjectIdentifier(second))
        state.viewFile()
        state.finished(ObjectIdentifier(first))
        state.viewFile()
        #expect(revealed == [secondFile, firstFile])
    }
}
