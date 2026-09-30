import AppKit
import Darwin
import Foundation
import Testing
@testable import PersonaStack
@testable import PersonaStackCore

private func protectedAccessFixture() throws -> URL {
    // Foundation preserves the /var alias on macOS. The strict probe must get
    // a real path even for these disposable test fixtures.
    guard let canonical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { free(canonical) }
    let home = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        .appendingPathComponent("personastack-protected-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Mail"),
        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return home
}

struct DesktopProtectedAccessPermissionTests {
    @Test func protectedDirectoryCheckListsWithoutReadingOrWritingFiles() async throws {
        let home = try protectedAccessFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let mail = home.appendingPathComponent("Library/Mail")
        let existing = mail.appendingPathComponent("unreadable-fixture")
        let bytes = Data("Fixture contents must stay unread during the check".utf8)
        try bytes.write(to: existing)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: existing.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: mail.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mail.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: existing.path)
        }
        try await DesktopFileSystem().verifyProtectedDirectoryAccess(home: home)
        #expect(try FileManager.default.contentsOfDirectory(atPath: mail.path) == ["unreadable-fixture"])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: existing.path)
        #expect(try Data(contentsOf: existing) == bytes)
    }

    @Test func protectedDirectoryEmptyResourceStillExercisesListing() async throws {
        let home = try protectedAccessFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        try await DesktopFileSystem().verifyProtectedDirectoryAccess(home: home)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Library/Mail").path).isEmpty)
    }

    @Test(arguments: ["", "Library", "Library/Mail"])
    func protectedDirectoryRefusesSymlinkAtEverySelectedComponent(component: String) async throws {
        let home = try protectedAccessFixture()
        let target = try protectedAccessFixture()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: target) }
        let selected = component.isEmpty ? home : home.appendingPathComponent(component)
        let destination = component.isEmpty ? target : target.appendingPathComponent(component)
        try FileManager.default.removeItem(at: selected)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: destination)
        await #expect(throws: NSError.self) { try await DesktopFileSystem().verifyProtectedDirectoryAccess(home: home) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.appendingPathComponent("Library/Mail").path).isEmpty)
    }

    @Test func protectedDirectoryMissingResourceIsNotCreatedOrGranted() async throws {
        let home = try protectedAccessFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let mail = home.appendingPathComponent("Library/Mail")
        try FileManager.default.removeItem(at: mail)
        do {
            try await DesktopFileSystem().verifyProtectedDirectoryAccess(home: home)
            Issue.record("A missing protected resource cannot prove access")
        } catch {
            let failure = error as NSError
            #expect(failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT))
        }
        #expect(!FileManager.default.fileExists(atPath: mail.path))
    }

    @Test func protectedDirectoryDeniedReadAndNonDirectoryCannotSucceed() async throws {
        let home = try protectedAccessFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let mail = home.appendingPathComponent("Library/Mail")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: mail.path)
        do {
            try await DesktopFileSystem().verifyProtectedDirectoryAccess(home: home)
            Issue.record("A directory without read access cannot be verified")
        } catch {
            let failure = error as NSError
            #expect(failure.domain == NSPOSIXErrorDomain && failure.code == Int(EACCES))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mail.path)
        try FileManager.default.removeItem(at: mail)
        try Data("ordinary file".utf8).write(to: mail)
        await #expect(throws: NSError.self) { try await DesktopFileSystem().verifyProtectedDirectoryAccess(home: home) }
    }

    @Test @MainActor func protectedDirectoryPrecancelHasNoEffects() async throws {
        let home = try protectedAccessFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let check = Task { try await DesktopFileSystem().verifyProtectedDirectoryAccess(home: home) }
        check.cancel()
        await #expect(throws: CancellationError.self) { try await check.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Library/Mail").path).isEmpty)
    }

    @Test @MainActor func protectedAccessPassiveStatusDoesNotPromptOrProbe() async {
        var choices = 0
        var probes = 0
        let service = DesktopPermissionChecklist(selectedProfile: { .production }, protectedAccessAction: {
            choices += 1; return .check
        }, verifyProtectedAccess: { probes += 1 }, activationNotificationCenter: NotificationCenter())
        for _ in 0..<3 { #expect(await service.adapter.observe(.fullDiskAccess).state == .unsupported) }
        #expect(choices == 0 && probes == 0)
    }

    @Test @MainActor func protectedAccessSuccessIsOperationEvidenceNeverUniversalApproval() async {
        var probes = 0
        let service = DesktopPermissionChecklist(selectedProfile: { .production }, protectedAccessAction: { .check },
            verifyProtectedAccess: { probes += 1 }, activationNotificationCenter: NotificationCenter())
        let result = await service.adapter.setup(.fullDiskAccess)
        #expect(result.state == .unsupported && !result.verified && !result.requiresVerification)
        #expect(!DesktopPermissionRow(id: .fullDiskAccess, observation: result).isComplete)
        #expect(result.detail.contains("operation succeeded") && result.detail.contains("unqualified"))
        #expect(await service.adapter.observe(.fullDiskAccess) == result)
        #expect(probes == 1)
    }

    @Test @MainActor func protectedAccessNativeCancelAndSettingsDoNotProbe() async {
        for action in [DesktopProtectedAccessSetupAction.cancel, .settings] {
            var probes = 0
            var settings: [String] = []
            let service = DesktopPermissionChecklist(selectedProfile: { .production }, protectedAccessAction: { action },
                verifyProtectedAccess: { probes += 1 }, activationNotificationCenter: NotificationCenter())
            let adapter = DesktopPermissionChecklistSystemAdapter(hooks: service.adapter.hooks, openSettings: { settings.append($0) })
            let result = await adapter.setup(.fullDiskAccess)
            #expect(result.state == (action == .cancel ? .checking : .notGranted))
            #expect(probes == 0)
            #expect(settings == (action == .settings ? ["com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"] : []))
        }
    }

    @Test @MainActor func protectedAccessDenialOpensOnlyFullDiskSettingsAndInconclusiveDoesNot() async {
        for code in [EPERM, EACCES, ENOENT, EIO, ELOOP] {
            var settings: [String] = []
            let service = DesktopPermissionChecklist(selectedProfile: { .production }, protectedAccessAction: { .check },
                verifyProtectedAccess: { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) },
                activationNotificationCenter: NotificationCenter())
            let adapter = DesktopPermissionChecklistSystemAdapter(hooks: service.adapter.hooks, openSettings: { settings.append($0) })
            let result = await adapter.setup(.fullDiskAccess)
            let denied = code == EPERM || code == EACCES
            #expect(result.state == (denied ? .denied : .unsupported) && !result.verified)
            #expect(settings == (denied ? ["com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"] : []))
            #expect(await adapter.observe(.fullDiskAccess) == result)
        }
    }

    @Test @MainActor func protectedAccessChangedEvidenceAfterReplyCannotOpenSettings() async {
        var settings: [String] = []
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(
            observe: { _ in .init(.unsupported, detail: "Retired evidence") },
            setup: { _ in .init(.denied, detail: "Earlier denial", verificationKey: "retired") }
        ), openSettings: { settings.append($0) })
        #expect(await adapter.setup(.fullDiskAccess).state == .checking)
        #expect(settings.isEmpty)
    }

    @Test @MainActor func protectedAccessPrecancelDoesNotDisplayConsentOrProbe() async {
        var choices = 0
        var probes = 0
        let service = DesktopPermissionChecklist(selectedProfile: { .production }, protectedAccessAction: {
            choices += 1; return .check
        }, verifyProtectedAccess: { probes += 1 }, activationNotificationCenter: NotificationCenter())
        let check = Task { await service.adapter.setup(.fullDiskAccess) }
        check.cancel()
        #expect(await check.value.state == .checking)
        #expect(choices == 0 && probes == 0)
    }

    @Test @MainActor func protectedAccessCancellationWhileConsentPendingNeverProbesOrOpensSettings() async {
        var pending: CheckedContinuation<DesktopProtectedAccessSetupAction, Never>?
        var probes = 0
        var settings: [String] = []
        let service = DesktopPermissionChecklist(selectedProfile: { .production }, protectedAccessAction: {
            await withCheckedContinuation { pending = $0 }
        }, verifyProtectedAccess: { probes += 1 }, activationNotificationCenter: NotificationCenter())
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: service.adapter.hooks, openSettings: { settings.append($0) })
        let check = Task { await adapter.setup(.fullDiskAccess) }
        while pending == nil { await Task.yield() }
        check.cancel()
        pending?.resume(returning: .check)
        #expect(await check.value.state == .checking)
        #expect(probes == 0 && settings.isEmpty)
        #expect(await adapter.observe(.fullDiskAccess).state == .unsupported)
    }

    @Test @MainActor func protectedAccessEnvironmentChangeAndActivationFenceLateProbe() async {
        for activate in [false, true] {
            var profile = DesktopEnvironmentConfiguration.production
            let notifications = NotificationCenter()
            var pending: CheckedContinuation<Void, Never>?
            var settings: [String] = []
            let service = DesktopPermissionChecklist(selectedProfile: { profile }, protectedAccessAction: { .check },
                verifyProtectedAccess: { await withCheckedContinuation { pending = $0 } },
                activationNotificationCenter: notifications)
            let adapter = DesktopPermissionChecklistSystemAdapter(hooks: service.adapter.hooks, openSettings: { settings.append($0) })
            let check = Task { await adapter.setup(.fullDiskAccess) }
            while pending == nil { await Task.yield() }
            if activate { notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil) }
            else { profile = .lan }
            pending?.resume()
            #expect(await check.value.state == .checking)
            #expect(await adapter.observe(.fullDiskAccess).state == .unsupported)
            #expect(settings.isEmpty)
        }
    }

    @Test @MainActor func protectedAccessInvalidationAndLateAttemptCannotReplaceNewResult() async {
        var pending: CheckedContinuation<Void, Never>?
        var probes = 0
        let service = DesktopPermissionChecklist(selectedProfile: { .production }, protectedAccessAction: { .check },
            verifyProtectedAccess: {
                probes += 1
                if probes == 1 { await withCheckedContinuation { pending = $0 } }
                else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) }
            }, activationNotificationCenter: NotificationCenter())
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: service.adapter.hooks, openSettings: { _ in Issue.record("No settings action expected") })
        let old = Task { await adapter.setup(.fullDiskAccess) }
        while pending == nil { await Task.yield() }
        #expect(await adapter.setup(.fullDiskAccess).state == .checking)
        #expect(probes == 1)
        service.cancelVerification()
        let current = await adapter.setup(.fullDiskAccess)
        #expect(current.state == .unsupported && current.detail.contains("inconclusive"))
        pending?.resume()
        #expect(await old.value.state == .checking)
        #expect(await adapter.observe(.fullDiskAccess) == current && probes == 2)
    }

    @Test @MainActor func protectedAccessCanceledProbeCannotStoreEvidence() async {
        var pending: CheckedContinuation<Void, Never>?
        let service = DesktopPermissionChecklist(selectedProfile: { .production }, protectedAccessAction: { .check },
            verifyProtectedAccess: { await withCheckedContinuation { pending = $0 } },
            activationNotificationCenter: NotificationCenter())
        let check = Task { await service.adapter.setup(.fullDiskAccess) }
        while pending == nil { await Task.yield() }
        check.cancel()
        pending?.resume()
        #expect(await check.value.state == .checking)
        #expect(await service.adapter.observe(.fullDiskAccess).state == .unsupported)
    }

    @Test @MainActor func protectedAccessCachedOperationEvidenceExpiresOnActivationOrEnvironmentChange() async {
        let notifications = NotificationCenter()
        var profile = DesktopEnvironmentConfiguration.production
        let service = DesktopPermissionChecklist(selectedProfile: { profile }, protectedAccessAction: { .check },
            verifyProtectedAccess: {}, activationNotificationCenter: notifications)
        let first = await service.adapter.setup(.fullDiskAccess)
        #expect(await service.adapter.observe(.fullDiskAccess) == first)
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(await service.adapter.observe(.fullDiskAccess).verificationKey == nil)
        _ = await service.adapter.setup(.fullDiskAccess)
        profile = .lan
        #expect(await service.adapter.observe(.fullDiskAccess).verificationKey == nil)
        profile = .production
        #expect(await service.adapter.observe(.fullDiskAccess).verificationKey == nil)
    }
}
