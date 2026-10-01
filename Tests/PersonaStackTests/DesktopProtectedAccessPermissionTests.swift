import AppKit
import Darwin
import Foundation
import Testing
@testable import PersonaStack
@testable import PersonaStackCore

func protectedAccessFixture() throws -> URL {
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

    @Test func protectedDirectoryChecksMessagesWhenMailIsAbsent() async throws {
        let home = try protectedAccessFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let mail = home.appendingPathComponent("Library/Mail")
        let messages = home.appendingPathComponent("Library/Messages")
        try FileManager.default.removeItem(at: mail)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: false)
        let existing = messages.appendingPathComponent("unreadable-fixture")
        try Data("Message contents must stay unread".utf8).write(to: existing)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: existing.path)
        try await DesktopFileSystem().verifyProtectedDirectoryAccess(home: home)
        #expect(!FileManager.default.fileExists(atPath: mail.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: messages.path) == ["unreadable-fixture"])
    }

    @Test(arguments: ["denied", "redirected", "non-directory"])
    func protectedDirectoryDoesNotBypassFailedMailWithReadableMessages(failure: String) async throws {
        let home = try protectedAccessFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let mail = home.appendingPathComponent("Library/Mail")
        let messages = home.appendingPathComponent("Library/Messages")
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: false)
        if failure == "denied" {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: mail.path)
        } else {
            try FileManager.default.removeItem(at: mail)
            if failure == "redirected" {
                try FileManager.default.createSymbolicLink(at: mail, withDestinationURL: messages)
            } else { try Data().write(to: mail) }
        }
        defer {
            if failure == "denied" { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mail.path) }
        }
        await #expect(throws: NSError.self) { try await DesktopFileSystem().verifyProtectedDirectoryAccess(home: home) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: messages.path).isEmpty)
    }

    @Test func protectedDirectoryRefusesRedirectedMessagesFallback() async throws {
        let home = try protectedAccessFixture()
        let target = try protectedAccessFixture()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: target) }
        try FileManager.default.removeItem(at: home.appendingPathComponent("Library/Mail"))
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Library/Messages"),
                                                  withDestinationURL: target.appendingPathComponent("Library/Mail"))
        await #expect(throws: NSError.self) { try await DesktopFileSystem().verifyProtectedDirectoryAccess(home: home) }
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
        for _ in 0..<3 { #expect(await service.adapter.observe(.fullDiskAccess).state == .verificationRequired) }
        #expect(choices == 0 && probes == 0)
    }

    @Test @MainActor func protectedAccessSuccessIsOperationEvidenceNeverUniversalApproval() async {
        var probes = 0
        let service = DesktopPermissionChecklist(selectedProfile: { .production }, protectedAccessAction: { .check },
            verifyProtectedAccess: { probes += 1 }, activationNotificationCenter: NotificationCenter())
        let result = await service.adapter.setup(.fullDiskAccess)
        #expect(result.state == .ready && result.verified && result.requiresVerification)
        #expect(DesktopPermissionRow(id: .fullDiskAccess, observation: result).isComplete)
        #expect(result.detail.contains("Protected-folder access verified") && result.detail.contains("separate access restrictions"))
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
            let expected: DesktopPermissionState = denied ? .denied : (code == ENOENT ? .verificationRequired : .failed)
            #expect(result.state == expected && !result.verified)
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
        #expect(await adapter.observe(.fullDiskAccess).state == .verificationRequired)
    }

    @Test @MainActor func protectedAccessEnvironmentChangeFencesLateProbeButOwnActivationDoesNot() async {
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
            #expect(await check.value.state == (activate ? .ready : .checking))
            #expect(await adapter.observe(.fullDiskAccess).state == (activate ? .ready : .verificationRequired))
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
        #expect(current.state == .verificationRequired && current.detail.contains("No protected Mail or Messages folder"))
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
        #expect(await service.adapter.observe(.fullDiskAccess).state == .verificationRequired)
    }

    @Test @MainActor func protectedAccessCachedOperationEvidenceRefreshesOnActivationAndExpiresOnEnvironmentChange() async {
        let notifications = NotificationCenter()
        var profile = DesktopEnvironmentConfiguration.production
        let service = DesktopPermissionChecklist(selectedProfile: { profile }, protectedAccessAction: { .check },
            verifyProtectedAccess: {}, activationNotificationCenter: notifications)
        let first = await service.adapter.setup(.fullDiskAccess)
        #expect(await service.adapter.observe(.fullDiskAccess) == first)
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(await service.adapter.observe(.fullDiskAccess).state == .ready)
        _ = await service.adapter.setup(.fullDiskAccess)
        profile = .lan
        #expect(await service.adapter.observe(.fullDiskAccess).verificationKey == nil)
        profile = .production
        #expect(await service.adapter.observe(.fullDiskAccess).verificationKey == nil)
    }

    @Test @MainActor func protectedAccessSettingsReturnRequiresExplicitCheckAndThenBecomesReady() async throws {
        let home = try protectedAccessFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        var action = DesktopProtectedAccessSetupAction.settings
        var probes = 0
        var settings: [String] = []
        let service = DesktopPermissionChecklist(selectedProfile: { .production }, protectedAccessAction: { action },
            verifyProtectedAccess: {
                probes += 1
                try await DesktopFileSystem().verifyProtectedDirectoryAccess(home: home)
            }, activationNotificationCenter: NotificationCenter())
        let model = protectedAccessCoordinator(service: service, openSettings: { settings.append($0) })
        model.open()
        defer { model.cancel(); service.cancelVerification() }
        await model.refresh()
        #expect(protectedAccessRow(model)?.state == .verificationRequired)
        model.setup(.fullDiskAccess)
        while model.busyPermission != nil { await Task.yield() }
        #expect(settings == ["com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"])
        #expect(probes == 0 && protectedAccessRow(model)?.isComplete == false)
        service.invalidateAfterActivation()
        await model.refresh()
        #expect(protectedAccessRow(model)?.state == .notGranted)
        #expect(protectedAccessRow(model)?.observation.detail.contains("Check Access") == true)
        #expect(probes == 0)
        action = .check
        model.setup(.fullDiskAccess)
        while model.busyPermission != nil { await Task.yield() }
        #expect(protectedAccessRow(model)?.state == .ready)
        #expect(protectedAccessRow(model)?.observation.verified == true)
        for _ in 0..<3 { await model.refresh() }
        #expect(protectedAccessRow(model)?.isComplete == true && probes == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Library/Mail").path).isEmpty)
    }

    @Test @MainActor func protectedAccessRevocationDiscardsReadyAndDenialCannotReuseProof() async {
        var denied = false
        var probes = 0
        var settings: [String] = []
        let service = DesktopPermissionChecklist(selectedProfile: { .production }, protectedAccessAction: { .check },
            verifyProtectedAccess: {
                probes += 1
                if denied { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
            }, activationNotificationCenter: NotificationCenter())
        let model = protectedAccessCoordinator(service: service, openSettings: { settings.append($0) })
        model.open()
        defer { model.cancel(); service.cancelVerification() }
        model.setup(.fullDiskAccess)
        while model.busyPermission != nil { await Task.yield() }
        let verified = protectedAccessRow(model)?.observation.verificationKey
        #expect(protectedAccessRow(model)?.isComplete == true)
        denied = true
        service.invalidateAfterActivation()
        await model.refresh()
        #expect(protectedAccessRow(model)?.state == .denied && probes == 2)
        #expect(settings.isEmpty)
        model.setup(.fullDiskAccess)
        while model.busyPermission != nil { await Task.yield() }
        #expect(protectedAccessRow(model)?.state == .denied)
        #expect(protectedAccessRow(model)?.observation.verified == false)
        #expect(protectedAccessRow(model)?.observation.verificationKey == verified)
        #expect(protectedAccessRow(model)?.observation.detail.contains("quit and reopen") == true)
        #expect(probes == 3 && settings.count == 1)
        await model.refresh()
        #expect(protectedAccessRow(model)?.state == .denied)
    }

    @Test @MainActor func protectedAccessReopenRefreshesReadyAndConsentCancelPreservesIt() async {
        var action = DesktopProtectedAccessSetupAction.check
        var probes = 0
        let service = DesktopPermissionChecklist(selectedProfile: { .production }, protectedAccessAction: { action },
            verifyProtectedAccess: { probes += 1 }, activationNotificationCenter: NotificationCenter())
        let model = protectedAccessCoordinator(service: service, openSettings: { _ in Issue.record("Unexpected Settings open") })
        model.open()
        defer { model.cancel(); service.cancelVerification() }
        model.setup(.fullDiskAccess)
        while model.busyPermission != nil { await Task.yield() }
        #expect(protectedAccessRow(model)?.isComplete == true)
        model.cancel()
        service.cancelVerification()
        service.window.onPresent?()
        model.open()
        await model.refresh()
        #expect(protectedAccessRow(model)?.state == .ready && probes == 2)
        action = .cancel
        model.setup(.fullDiskAccess)
        while model.busyPermission != nil { await Task.yield() }
        #expect(protectedAccessRow(model)?.isComplete == true && probes == 2)
    }
}

@MainActor
private func protectedAccessCoordinator(service: DesktopPermissionChecklist,
                                       openSettings: @escaping (String) -> Void) -> DesktopPermissionChecklistCoordinator {
    let hooks = service.adapter.hooks
    // Exercise the real native service, system adapter and coordinator for FDA.
    // Other rows must not inspect this machine's grants or start native owners.
    let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(observe: { id in
        if id == .fullDiskAccess { return await hooks.observe(id) }
        return .init(.notNeeded, detail: "Unrelated test capability")
    }, setup: { id in
        guard id == .fullDiskAccess else { Issue.record("Unexpected setup"); return nil }
        return await hooks.setup(id)
    }), openSettings: openSettings)
    return DesktopPermissionChecklistCoordinator(adapter: adapter)
}

@MainActor
private func protectedAccessRow(_ model: DesktopPermissionChecklistCoordinator) -> DesktopPermissionRow? {
    model.rows.first { $0.id == .fullDiskAccess }
}
