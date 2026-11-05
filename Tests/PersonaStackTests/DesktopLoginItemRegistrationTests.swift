import Foundation
import PersonaStackCore
import ServiceManagement
import Testing

@Suite @MainActor
struct DesktopLoginItemRegistrationTests {
    private struct MigrationFailure: Error {}
    private let installedBundle = URL(fileURLWithPath: "/Applications/PersonaStack.app")

    @Test(arguments: [
        ("/tmp/PersonaStack.app", false),
        ("/Users/fixture/Downloads/PersonaStack.app", false),
        ("/private/var/folders/fixture/AppTranslocation/PersonaStack.app", false),
        ("/Applications/PersonaStack.app", true),
        ("/Applications/PersonaStackUnsignedFixture.app", false),
    ])
    func unsupportedStartupCopyPreservesInstalledOwnerAndReceipt(_ path: String, _ readOnly: Bool) async throws {
        let suite = "login-preflight-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: DesktopLoginItemRegistration.firstLaunchHandledKey)
        preferences.set("installed", forKey: DesktopLoginItemRegistration.registeredExecutableKey)
        preferences.set("preserve diagnostic", forKey: DesktopLoginItemRegistration.errorKey)
        var calls: [String] = []
        var status = SMAppService.Status.enabled
        let service = DesktopLoginItemRegistration.Service(status: { calls.append("status"); return status },
            unregister: { calls.append("unregister"); status = .notRegistered },
            legacyStatus: { calls.append("legacy-status"); return .notRegistered },
            unregisterLegacy: { calls.append("unregister-legacy") }, register: { calls.append("register"); status = .enabled },
            prepareFirstLaunch: { _, _, _ in calls.append("first-launch"); return false })
        await DesktopLoginItemRegistration.reconcileAtLaunch(preferences: preferences,
            bundleURL: URL(fileURLWithPath: path), volumeIsReadOnly: readOnly,
            signatureValid: { _ in path != "/Applications/PersonaStackUnsignedFixture.app" }, identity: { _ in calls.append("identity"); return "temporary" }, service: service)
        await #expect(throws: (any Error).self) {
            try await DesktopLoginItemRegistration.registerCurrentExecutable(preferences: preferences,
                bundleURL: URL(fileURLWithPath: path), volumeIsReadOnly: readOnly,
                signatureValid: { _ in path != "/Applications/PersonaStackUnsignedFixture.app" },
                identity: { _ in calls.append("identity"); return "temporary" }, service: service)
        }
        #expect(calls.isEmpty)
        #expect(status == .enabled)
        #expect(preferences.string(forKey: DesktopLoginItemRegistration.registeredExecutableKey) == "installed")
        #expect(preferences.string(forKey: DesktopLoginItemRegistration.errorKey) == "preserve diagnostic")
    }

    @Test(arguments: [false, true])
    func registrationDrainJoinsPendingWorkAndClosesAdmission(failRegistration: Bool) async throws {
        let suite = "login-drain-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var status = SMAppService.Status.enabled
        var pending: CheckedContinuation<Void, Never>?
        var unregisters = 0
        var registrations = 0
        var shouldFail = failRegistration
        let service = DesktopLoginItemRegistration.Service(status: { status }, unregister: {
            unregisters += 1
            if unregisters == 1 { await withCheckedContinuation { pending = $0 } }
            status = .notRegistered
        }, legacyStatus: { .notRegistered }, unregisterLegacy: {}, register: {
            registrations += 1
            if shouldFail { throw MigrationFailure() }
            status = .enabled
        })
        let repair = Task { try await DesktopLoginItemRegistration.registerCurrentExecutable(preferences: preferences,
            bundleURL: installedBundle, volumeIsReadOnly: false, signatureValid: { _ in true }, identity: { _ in "current" }, service: service) }
        while pending == nil { await Task.yield() }
        #expect(service.hasPendingRegistration)
        var drainStarted = false
        var drainReturned = false
        let drain = Task {
            drainStarted = true
            await service.stopAdmissionAndDrain()
            drainReturned = true
        }
        while !drainStarted { await Task.yield() }
        #expect(!drainReturned)
        #expect(!service.isAcceptingRegistrations)
        pending?.resume()
        if failRegistration { await #expect(throws: (any Error).self) { try await repair.value } }
        else { _ = try await repair.value }
        await drain.value
        #expect(drainReturned && !service.hasPendingRegistration)
        #expect(unregisters == 1 && registrations == 1)
        let settledReceipt = preferences.string(forKey: DesktopLoginItemRegistration.registeredExecutableKey)
        shouldFail = false
        await DesktopLoginItemRegistration.reconcileAtLaunch(preferences: preferences, bundleURL: installedBundle,
            volumeIsReadOnly: false, signatureValid: { _ in true }, identity: { _ in "later" }, service: service)
        await #expect(throws: CancellationError.self) {
            try await DesktopLoginItemRegistration.registerCurrentExecutable(preferences: preferences,
                bundleURL: installedBundle, volumeIsReadOnly: false, signatureValid: { _ in true }, identity: { _ in "later" }, service: service)
        }
        #expect(unregisters == 1 && registrations == 1)
        #expect(preferences.string(forKey: DesktopLoginItemRegistration.registeredExecutableKey) == settledReceipt)
        service.resumeAdmission()
        #expect(service.isAcceptingRegistrations)
        _ = try await DesktopLoginItemRegistration.registerCurrentExecutable(preferences: preferences,
            bundleURL: installedBundle, volumeIsReadOnly: false, signatureValid: { _ in true }, identity: { _ in "later" }, service: service)
        #expect(registrations == 2)
    }

    @Test func terminalAdmissionCannotBeReopenedByCanceledReplacement() async throws {
        let suite = "login-terminal-admission-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = DesktopLoginItemRegistration.Service(status: { Issue.record("No new status check after terminal stop"); return .enabled },
            unregister: { Issue.record("No unregister after terminal stop") }, legacyStatus: { .notRegistered },
            unregisterLegacy: {}, register: { Issue.record("No register after terminal stop") },
            prepareFirstLaunch: { _, _, _ in Issue.record("No first-launch work after terminal stop"); return false })
        service.stopAdmission()
        service.stopAdmission(terminal: true)
        service.resumeAdmission()
        await service.stopAdmissionAndDrain()
        #expect(!service.isAcceptingRegistrations && !service.hasPendingRegistration)
        await DesktopLoginItemRegistration.reconcileAtLaunch(preferences: preferences, bundleURL: installedBundle,
            volumeIsReadOnly: false, signatureValid: { _ in Issue.record("Admission precedes preflight"); return true },
            identity: { _ in "current" }, service: service)
        await #expect(throws: CancellationError.self) {
            try await DesktopLoginItemRegistration.registerCurrentExecutable(preferences: preferences, bundleURL: installedBundle,
                volumeIsReadOnly: false, signatureValid: { _ in Issue.record("Admission precedes preflight"); return true },
                identity: { _ in "current" }, service: service)
        }
        service.cancelTerminalAdmission()
        #expect(service.isAcceptingRegistrations)
    }

    @Test(arguments: ["quit-fails-first", "update-cancels-first", "quit-only"])
    func admissionRollbackReleasesOnlyItsOwnClosure(order: String) async {
        let service = DesktopLoginItemRegistration.Service(status: { Issue.record("Admission rollback never observes OS status"); return .enabled },
            unregister: { Issue.record("Admission rollback never unregisters") }, legacyStatus: { .notRegistered },
            unregisterLegacy: {}, register: { Issue.record("Admission rollback never registers") })
        if order != "quit-only" { service.stopAdmission() }
        service.stopAdmission(terminal: true)
        await service.stopAdmissionAndDrain()
        #expect(!service.isAcceptingRegistrations)
        switch order {
        case "quit-fails-first":
            service.cancelTerminalAdmission()
            #expect(!service.isAcceptingRegistrations)
            service.resumeAdmission()
        case "update-cancels-first":
            service.resumeAdmission()
            #expect(!service.isAcceptingRegistrations)
            service.cancelTerminalAdmission()
        default:
            service.cancelTerminalAdmission()
        }
        #expect(service.isAcceptingRegistrations)
    }

    @Test(arguments: ["/Applications/PersonaStack.app", "/Users/fixture/Applications/PersonaStack.app"])
    func changedEnabledExecutableIsReplacedAtLaunch(path: String) async throws {
        let bundle = URL(fileURLWithPath: path)
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Users/fixture/Applications")]
        let suite = "login-updated-executable-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: DesktopLoginItemRegistration.firstLaunchHandledKey)
        preferences.set(true, forKey: DesktopLoginItemRegistration.crashRecoveryMigrationHandledKey)
        var status = SMAppService.Status.enabled
        var calls: [String] = []
        var pending: CheckedContinuation<Void, Never>?
        let service = DesktopLoginItemRegistration.Service(status: { status }, unregister: {
            calls.append("unregister-old")
            await withCheckedContinuation { pending = $0 }
            status = .notRegistered
        }, legacyStatus: { .notRegistered }, unregisterLegacy: { Issue.record("Legacy owner is absent") },
            register: { calls.append("register-current"); status = .enabled })
        let task = Task { await DesktopLoginItemRegistration.reconcileAtLaunch(preferences: preferences,
            bundleURL: bundle, volumeIsReadOnly: false, applicationDirectories: roots, signatureValid: { _ in true }, identity: { _ in "updated" }, service: service) }
        while pending == nil { await Task.yield() }
        #expect(calls == ["unregister-old"])
        pending?.resume()
        await task.value
        #expect(calls == ["unregister-old", "register-current"])
        #expect(preferences.string(forKey: DesktopLoginItemRegistration.registeredExecutableKey) == "updated")
        await DesktopLoginItemRegistration.reconcileAtLaunch(preferences: preferences,
            bundleURL: bundle, volumeIsReadOnly: false, applicationDirectories: roots, signatureValid: { _ in true }, identity: { _ in "updated" }, service: service)
        #expect(calls == ["unregister-old", "register-current"])
    }

    @Test(arguments: [SMAppService.Status.notRegistered, .notFound, .requiresApproval])
    func laterLaunchPreservesDisabledOrPendingRegistration(_ initial: SMAppService.Status) async throws {
        let suite = "login-intent-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: DesktopLoginItemRegistration.firstLaunchHandledKey)
        let service = DesktopLoginItemRegistration.Service(status: { initial },
            unregister: { Issue.record("Preserve user intent") },
            legacyStatus: { Issue.record("Do not inspect legacy service"); return .notRegistered },
            unregisterLegacy: { Issue.record("Preserve legacy service") }, register: { Issue.record("Never re-enable") })
        await DesktopLoginItemRegistration.reconcileAtLaunch(preferences: preferences, bundleURL: installedBundle,
            volumeIsReadOnly: false, signatureValid: { _ in true }, identity: { _ in "new" }, service: service)
        #expect(preferences.string(forKey: DesktopLoginItemRegistration.registeredExecutableKey) == nil)
    }

    @Test func firstLaunchAdapterStampsOnlyActualRegistrationAndApprovalDoesNotCauseRefresh() async throws {
        let suite = "login-first-adapter-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var status = SMAppService.Status.notRegistered
        var registrations = 0
        let service = DesktopLoginItemRegistration.Service(status: { status },
            unregister: { Issue.record("Do not reset a newly registered current entry") },
            legacyStatus: { .notRegistered }, unregisterLegacy: {}, register: { Issue.record("Adapter registers once") },
            prepareFirstLaunch: { preferences, bundle, readOnly in
                var registered = false
                DesktopLoginItemRegistration.enableOnFirstLaunch(preferences: preferences, bundleURL: bundle,
                    volumeIsReadOnly: readOnly, status: { status }, register: {
                        registrations += 1; status = .requiresApproval; registered = true
                    }, legacyStatus: { .notRegistered })
                return registered
            })
        await DesktopLoginItemRegistration.reconcileAtLaunch(preferences: preferences, bundleURL: installedBundle,
            volumeIsReadOnly: false, signatureValid: { _ in true }, identity: { _ in "new" }, service: service)
        #expect(registrations == 1)
        #expect(preferences.string(forKey: DesktopLoginItemRegistration.registeredExecutableKey) == "new")
        let pendingIsReady: Bool = DesktopLoginItemRegistration.isCurrentExecutableRegistered(preferences: preferences,
            bundleURL: installedBundle, identity: { _ in "new" }, status: status)
        #expect(!pendingIsReady)
        status = .enabled
        await DesktopLoginItemRegistration.reconcileAtLaunch(preferences: preferences, bundleURL: installedBundle,
            volumeIsReadOnly: false, signatureValid: { _ in true }, identity: { _ in "new" }, service: service)
        #expect(registrations == 1)
        let approvedIsReady: Bool = DesktopLoginItemRegistration.isCurrentExecutableRegistered(preferences: preferences,
            bundleURL: installedBundle, identity: { _ in "new" }, status: status)
        #expect(approvedIsReady)
    }

    @Test func failedCurrentRegistrationCannotStampStaleEnabledStatus() async throws {
        let suite = "login-refresh-failure-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("old", forKey: DesktopLoginItemRegistration.registeredExecutableKey)
        var status = SMAppService.Status.enabled
        let service = DesktopLoginItemRegistration.Service(status: { status }, unregister: { status = .notRegistered },
            legacyStatus: { .notRegistered }, unregisterLegacy: {}, register: { status = .enabled; throw MigrationFailure() })
        await DesktopLoginItemRegistration.reconcileAtLaunch(preferences: preferences, bundleURL: installedBundle,
            volumeIsReadOnly: false, signatureValid: { _ in true }, identity: { _ in "new" }, service: service)
        #expect(preferences.string(forKey: DesktopLoginItemRegistration.registeredExecutableKey) == nil)
        #expect(!(preferences.string(forKey: DesktopLoginItemRegistration.errorKey) ?? "").isEmpty)
        let failedIsReady: Bool = DesktopLoginItemRegistration.isCurrentExecutableRegistered(preferences: preferences,
            bundleURL: installedBundle, identity: { _ in "new" }, status: status)
        #expect(!failedIsReady)
    }

    @Test func executableReceiptChangesWithBytesPlistAndCanonicalLocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("login-receipt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func fixture(_ name: String) throws -> URL {
            let bundle = root.appendingPathComponent(name + ".app")
            let contents = bundle.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Library/LaunchAgents"), withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "test.personastack.receipt", "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            try Data("executable".utf8).write(to: contents.appendingPathComponent("MacOS/Fixture"))
            try Data("agent".utf8).write(to: contents.appendingPathComponent("Library/LaunchAgents/\(DesktopLoginItemRegistration.crashRecoveryAgentPlistName)"))
            return bundle
        }
        let first = try fixture("First")
        let second = try fixture("Second")
        let original = try #require(DesktopLoginItemRegistration.executableIdentity(bundleURL: first))
        #expect(original.count == 64)
        #expect(DesktopLoginItemRegistration.executableIdentity(bundleURL: first) == original)
        #expect(DesktopLoginItemRegistration.executableIdentity(bundleURL: second) != original)
        try Data("changed executable".utf8).write(to: first.appendingPathComponent("Contents/MacOS/Fixture"))
        let changed = try #require(DesktopLoginItemRegistration.executableIdentity(bundleURL: first))
        #expect(changed != original)
        try Data("changed plist".utf8).write(to: first.appendingPathComponent("Contents/Library/LaunchAgents/\(DesktopLoginItemRegistration.crashRecoveryAgentPlistName)"))
        #expect(DesktopLoginItemRegistration.executableIdentity(bundleURL: first) != changed)
    }

    @Test func signatureVerificationRejectsUnsignedBundleAndAcceptsSignedSystemApp() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("login-signature-\(UUID().uuidString).app")
        let contents = fixture.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let info: [String: String] = ["CFBundleIdentifier": "test.personastack.unsigned", "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: contents.appendingPathComponent("MacOS/Fixture"))
        #expect(!DesktopLoginItemRegistration.hasValidBundleSignature(bundleURL: fixture))
        #expect(!DesktopLoginItemRegistration.hasValidBundleSignature(bundleURL: Bundle.main.bundleURL))
        // Read-only Security-framework verification. No app is launched.
        #expect(DesktopLoginItemRegistration.hasValidBundleSignature(bundleURL: URL(fileURLWithPath: "/System/Applications/Calculator.app")))
    }

    @Test func explicitSetupWaitsForUnregisterBeforeReplacingBothOwners() async throws {
        var agent = SMAppService.Status.enabled
        var legacy = SMAppService.Status.requiresApproval
        var calls: [String] = []
        var pending: CheckedContinuation<Void, Never>?
        let task = Task { try await DesktopLoginItemRegistration.resetAndRegister(
            status: { agent }, unregister: {
                calls.append("unregister-agent")
                await withCheckedContinuation { pending = $0 }
                agent = .notRegistered
            }, legacyStatus: { legacy }, unregisterLegacy: {
                calls.append("unregister-legacy"); legacy = .notRegistered
            }, register: { calls.append("register-current"); agent = .enabled }) }
        while pending == nil { await Task.yield() }
        #expect(calls == ["unregister-agent"])
        pending?.resume()
        #expect(try await task.value == .enabled)
        #expect(calls == ["unregister-agent", "unregister-legacy", "register-current"])
    }

    @Test func cancelledSetupDoesNotRegisterAfterUnregisterCompletes() async {
        var agent = SMAppService.Status.enabled
        var pending: CheckedContinuation<Void, Never>?
        let task = Task { try await DesktopLoginItemRegistration.resetAndRegister(
            status: { agent }, unregister: {
                await withCheckedContinuation { pending = $0 }; agent = .notRegistered
            }, legacyStatus: { Issue.record("No later owner after cancellation"); return .notRegistered },
            unregisterLegacy: { Issue.record("No legacy reset") }, register: { Issue.record("No new registration") }) }
        while pending == nil { await Task.yield() }
        task.cancel()
        pending?.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func resetReadbackMustConfirmAbsenceBeforeRegistering() async {
        var legacy = SMAppService.Status.enabled
        var legacyRemoved = false
        await #expect(throws: (any Error).self) {
            try await DesktopLoginItemRegistration.resetAndRegister(
                status: { .enabled }, unregister: {},
                legacyStatus: { legacy },
                unregisterLegacy: { legacyRemoved = true; legacy = .notRegistered },
                register: { Issue.record("Do not accept stale enabled status") })
        }
        #expect(legacyRemoved)
    }

    @Test func setupStillRemovesLegacyOwnerWhenAgentRemovalFails() async {
        var legacy = SMAppService.Status.enabled
        var calls: [String] = []
        do {
            _ = try await DesktopLoginItemRegistration.resetAndRegister(
                status: { .enabled }, unregister: { calls.append("agent"); throw MigrationFailure() },
                legacyStatus: { legacy }, unregisterLegacy: { calls.append("legacy"); legacy = .notRegistered },
                register: { Issue.record("Failed removal must prevent registration") })
            Issue.record("Removal failure must be returned")
        } catch let failure as DesktopLoginItemRegistration.SetupFailure {
            #expect(failure.phase == .removeAgent && failure.underlying is MigrationFailure)
        } catch { Issue.record("Expected scoped setup failure") }
        #expect(calls == ["agent", "legacy"] && legacy == .notRegistered)
    }

    @Test func rejectedExplicitRegistrationCannotBeHiddenByStaleEnabledStatus() async {
        var status = SMAppService.Status.notRegistered
        do {
            _ = try await DesktopLoginItemRegistration.resetAndRegister(
                status: { status }, unregister: { Issue.record("Already absent") },
                legacyStatus: { .notRegistered }, unregisterLegacy: { Issue.record("Already absent") },
                register: { status = .enabled; throw MigrationFailure() })
            Issue.record("A rejected registration must fail even if status reads Enabled")
        } catch let failure as DesktopLoginItemRegistration.SetupFailure {
            #expect(failure.phase == .registerCurrent && failure.underlying is MigrationFailure)
        } catch { Issue.record("Expected scoped setup failure") }
    }

    @Test func invalidSignatureResetErrorIsNotIgnoredEvenWhenAbsent() async {
        guard #available(macOS 15, *) else { return }
        var status = SMAppService.Status.enabled
        await #expect(throws: (any Error).self) {
            try await DesktopLoginItemRegistration.resetAndRegister(
                status: { status }, unregister: { status = .notRegistered; throw NSError(domain: SMAppServiceErrorDomain, code: kSMErrorInvalidSignature) },
                legacyStatus: { .notRegistered }, unregisterLegacy: {},
                register: { Issue.record("Never register after failed reset") })
        }
    }

    @Test func uninstallUnregistersBothOwnersAndAllowsRegistrationAfterReinstall() throws {
        let suite = "login-uninstall-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DesktopLoginItemRegistration.firstLaunchHandledKey)
        defaults.set(true, forKey: DesktopLoginItemRegistration.crashRecoveryMigrationHandledKey)
        var agent = SMAppService.Status.enabled
        var legacy = SMAppService.Status.requiresApproval
        var calls: [String] = []
        try DesktopLoginItemRegistration.unregisterForUninstall(preferences: defaults,
            status: { agent }, unregister: { calls.append("agent"); agent = .notRegistered },
            legacyStatus: { legacy }, unregisterLegacy: { calls.append("legacy"); legacy = .notRegistered })
        #expect(calls == ["agent", "legacy"])
        #expect(!defaults.bool(forKey: DesktopLoginItemRegistration.firstLaunchHandledKey))
        #expect(!defaults.bool(forKey: DesktopLoginItemRegistration.crashRecoveryMigrationHandledKey))
        try DesktopLoginItemRegistration.unregisterForUninstall(preferences: defaults,
            status: { agent }, unregister: { Issue.record("already removed") },
            legacyStatus: { legacy }, unregisterLegacy: { Issue.record("already removed") })
    }

    @Test func unconfirmedUnregisterKeepsReinstallFlagsAndDoesNotRemoveNextOwner() throws {
        let suite = "login-uninstall-failure-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DesktopLoginItemRegistration.firstLaunchHandledKey)
        var unregisters = 0
        #expect(throws: (any Error).self) {
            try DesktopLoginItemRegistration.unregisterForUninstall(preferences: defaults,
                status: { .enabled }, unregister: { unregisters += 1 },
                legacyStatus: { Issue.record("must stop after failure"); return .enabled },
                unregisterLegacy: { Issue.record("must stop after failure") })
        }
        #expect(unregisters == 1)
        #expect(defaults.bool(forKey: DesktopLoginItemRegistration.firstLaunchHandledKey))
    }

    @Test(arguments: [SMAppService.Status.notRegistered, .notFound])
    func firstLaunchRegistersOnceAndPreservesLaterDisable(_ initialStatus: SMAppService.Status) throws {
        let suite = "DesktopLoginItemRegistrationTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var serviceStatus = initialStatus
        var registrations = 0
        let register = {
            registrations += 1
            serviceStatus = .enabled
        }

        DesktopLoginItemRegistration.enableOnFirstLaunch(preferences: preferences, bundleURL: installedBundle,
            volumeIsReadOnly: false, status: { serviceStatus }, register: register,
            legacyStatus: { .notRegistered }, unregisterLegacy: { Issue.record("Must preserve absent legacy item") })
        #expect(registrations == 1)
        #expect(serviceStatus == .enabled)

        let reopenedPreferences = try #require(UserDefaults(suiteName: suite))
        serviceStatus = .notRegistered
        DesktopLoginItemRegistration.enableOnFirstLaunch(preferences: reopenedPreferences, bundleURL: installedBundle,
            volumeIsReadOnly: false, status: { Issue.record("Later launches must not query or alter the login item"); return serviceStatus },
            register: register, legacyStatus: { Issue.record("Completed migration must not query legacy status"); return .enabled })
        #expect(registrations == 1)
        #expect(serviceStatus == .notRegistered)
    }

    @Test func successfulRegisterWithoutConfirmedStatusIsNotReportedAsEnabled() throws {
        let suite = "DesktopLoginItemRegistrationTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var registrations = 0
        DesktopLoginItemRegistration.enableOnFirstLaunch(preferences: preferences, bundleURL: installedBundle,
            volumeIsReadOnly: false, status: { .notFound }, register: { registrations += 1 },
            legacyStatus: { .notRegistered })
        #expect(registrations == 1)
        #expect(preferences.string(forKey: DesktopLoginItemRegistration.errorKey) == DesktopLoginItemRegistration.unconfirmedMessage)
        DesktopLoginItemRegistration.clearResolvedApprovalError(preferences: preferences, status: .notFound)
        #expect(preferences.string(forKey: DesktopLoginItemRegistration.errorKey) == DesktopLoginItemRegistration.unconfirmedMessage)
        DesktopLoginItemRegistration.clearResolvedApprovalError(preferences: preferences, status: .enabled)
        #expect(preferences.string(forKey: DesktopLoginItemRegistration.errorKey) == "")
    }

    @Test(arguments: [SMAppService.Status.enabled, .requiresApproval])
    func authoritativeStatusResolvesRegistrationRace(_ confirmedStatus: SMAppService.Status) throws {
        var status = SMAppService.Status.notFound
        let result = try DesktopLoginItemRegistration.registerIfNeeded(status: { status }, register: {
            status = confirmedStatus
            throw CocoaError(.fileWriteUnknown)
        })
        #expect(result == confirmedStatus)
    }

    @Test func registrationFailureWithoutConfirmedStatusIsPreserved() {
        let error = CocoaError(.fileWriteNoPermission)
        do {
            _ = try DesktopLoginItemRegistration.registerIfNeeded(status: { .notFound }, register: { throw error })
            Issue.record("Unconfirmed registration failure must be returned")
        } catch let actual { #expect(actual as? CocoaError == error) }
    }

    @Test func migrationReplacesOnlyAnEnabledLegacyLoginOwner() throws {
        var agent = SMAppService.Status.notRegistered
        var legacy = SMAppService.Status.enabled
        var actions: [String] = []
        let result = try DesktopLoginItemRegistration.registerAndMigrateLegacy(
            status: { agent },
            register: { actions.append("register-agent"); agent = .enabled },
            unregisterAgent: { actions.append("unregister-agent"); agent = .notRegistered },
            legacyStatus: { legacy },
            unregisterLegacy: { actions.append("unregister-legacy"); legacy = .notRegistered })

        #expect(result == .enabled)
        #expect(actions == ["register-agent", "unregister-legacy"])
        #expect(agent == .enabled)
        #expect(legacy == .notRegistered)
    }

    @Test func migrationKeepsLegacyOwnerUntilAgentApproval() throws {
        var agent = SMAppService.Status.notRegistered
        var legacy = SMAppService.Status.enabled
        var legacyUnregisters = 0
        let result = try DesktopLoginItemRegistration.registerAndMigrateLegacy(
            status: { agent }, register: { agent = .requiresApproval },
            legacyStatus: { legacy }, unregisterLegacy: { legacyUnregisters += 1; legacy = .notRegistered })

        #expect(result == .requiresApproval)
        #expect(legacy == .enabled)
        #expect(legacyUnregisters == 0)
    }

    @Test func failedLegacyRemovalRollsBackTheNewAgent() {
        var agent = SMAppService.Status.notRegistered
        var rolledBack = false
        do {
            _ = try DesktopLoginItemRegistration.registerAndMigrateLegacy(
                status: { agent }, register: { agent = .enabled },
                unregisterAgent: { rolledBack = true; agent = .notRegistered },
                legacyStatus: { .enabled }, unregisterLegacy: { throw MigrationFailure() })
            Issue.record("Legacy removal failure must roll back the new login owner")
        } catch is MigrationFailure {
            #expect(rolledBack)
            #expect(agent == .notRegistered)
        } catch { Issue.record("Unexpected migration error: \(error)") }
    }

    @Test func failedLegacyRemovalDoesNotRemoveAnAlreadyEnabledAgent() {
        var agentUnregisters = 0
        do {
            _ = try DesktopLoginItemRegistration.registerAndMigrateLegacy(
                status: { .enabled }, register: { Issue.record("Existing agent must not register again") },
                unregisterAgent: { agentUnregisters += 1 }, legacyStatus: { .enabled },
                unregisterLegacy: { throw MigrationFailure() })
            Issue.record("Legacy removal failure must be surfaced")
        } catch is MigrationFailure {
            #expect(agentUnregisters == 0)
        } catch { Issue.record("Unexpected migration error: \(error)") }
    }

    @Test func failedAgentReadbackRestoresThePreviouslyEnabledLegacyItem() {
        var agent = SMAppService.Status.notRegistered
        var legacy = SMAppService.Status.enabled
        var legacyRestored = false
        var agentRemoved = false
        do {
            _ = try DesktopLoginItemRegistration.registerAndMigrateLegacy(
                status: { agent }, register: { agent = .enabled },
                unregisterAgent: { agentRemoved = true; agent = .notRegistered },
                legacyStatus: { legacy }, unregisterLegacy: { legacy = .notRegistered; agent = .notRegistered },
                registerLegacy: { legacyRestored = true; legacy = .enabled })
            Issue.record("Failed agent readback must leave migration incomplete")
        } catch is CocoaError {
            #expect(legacyRestored)
            #expect(agentRemoved)
            #expect(legacy == .enabled)
        } catch { Issue.record("Unexpected migration error: \(error)") }
    }

    @Test func anExistingDisabledLoginItemIsNotMigrated() throws {
        let suite = "DesktopLoginItemRegistrationTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: DesktopLoginItemRegistration.firstLaunchHandledKey)
        var registrations = 0

        DesktopLoginItemRegistration.enableOnFirstLaunch(preferences: preferences, bundleURL: installedBundle,
            volumeIsReadOnly: false, status: { .notRegistered }, register: { registrations += 1 },
            legacyStatus: { .notRegistered })

        #expect(registrations == 0)
        #expect(preferences.bool(forKey: DesktopLoginItemRegistration.crashRecoveryMigrationHandledKey))
    }

    @Test func resolvedLegacyApprovalMessageIsClearedAfterUpgradeOnlyWhenEnabled() throws {
        let suite = "DesktopLoginItemRegistrationTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let oldMessage = "Allow PersonaStack in System Settings → General → Login Items."
        preferences.set(oldMessage, forKey: DesktopLoginItemRegistration.errorKey)
        for status in [SMAppService.Status.requiresApproval, .notFound, .notRegistered] {
            DesktopLoginItemRegistration.clearResolvedApprovalError(preferences: preferences, status: status)
            #expect(preferences.string(forKey: DesktopLoginItemRegistration.errorKey) == oldMessage)
        }
        DesktopLoginItemRegistration.clearResolvedApprovalError(preferences: preferences, status: .enabled)
        #expect(preferences.string(forKey: DesktopLoginItemRegistration.errorKey) == "")
    }

    @Test(arguments: [SMAppService.Status.enabled, .requiresApproval])
    func existingRegistrationIsPreserved(_ serviceStatus: SMAppService.Status) throws {
        let suite = "DesktopLoginItemRegistrationTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        DesktopLoginItemRegistration.enableOnFirstLaunch(preferences: preferences, bundleURL: installedBundle,
            volumeIsReadOnly: false, status: { serviceStatus }, register: { Issue.record("Must not register an existing login item") },
            legacyStatus: { .notRegistered })
        #expect(preferences.bool(forKey: DesktopLoginItemRegistration.firstLaunchHandledKey))
        if serviceStatus == .requiresApproval {
            #expect(preferences.string(forKey: DesktopLoginItemRegistration.errorKey)?.contains("System Settings") == true)
        }
    }

    @Test func approvalPendingAfterRegistrationIsReported() throws {
        let suite = "DesktopLoginItemRegistrationTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var serviceStatus = SMAppService.Status.notRegistered
        DesktopLoginItemRegistration.enableOnFirstLaunch(preferences: preferences, bundleURL: installedBundle,
            volumeIsReadOnly: false, status: { serviceStatus }, register: { serviceStatus = .requiresApproval },
            legacyStatus: { .notRegistered })
        #expect(preferences.string(forKey: DesktopLoginItemRegistration.errorKey)?.contains("System Settings") == true)
        DesktopLoginItemRegistration.clearResolvedApprovalError(preferences: preferences, status: .requiresApproval)
        #expect(preferences.string(forKey: DesktopLoginItemRegistration.errorKey)?.contains("System Settings") == true)
        DesktopLoginItemRegistration.clearResolvedApprovalError(preferences: preferences, status: .enabled)
        #expect(preferences.string(forKey: DesktopLoginItemRegistration.errorKey) == "")
        preferences.set("Another registration error", forKey: DesktopLoginItemRegistration.errorKey)
        DesktopLoginItemRegistration.clearResolvedApprovalError(preferences: preferences, status: .enabled)
        #expect(preferences.string(forKey: DesktopLoginItemRegistration.errorKey) == "Another registration error")
    }

    @Test func registrationFailureIsReportedWithoutRepeatedAutomaticAttempts() throws {
        struct RegistrationFailure: LocalizedError {
            var errorDescription: String? { "Login item registration failed" }
        }
        let suite = "DesktopLoginItemRegistrationTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var registrations = 0
        for _ in 0..<2 {
            DesktopLoginItemRegistration.enableOnFirstLaunch(preferences: preferences, bundleURL: installedBundle,
                volumeIsReadOnly: false, status: { .notRegistered }, register: {
                    registrations += 1
                    throw RegistrationFailure()
                }, legacyStatus: { .notRegistered })
        }
        #expect(registrations == 1)
        #expect(preferences.string(forKey: DesktopLoginItemRegistration.errorKey) == "Login item registration failed")
    }

    @Test(arguments: [
        ("/Volumes/PersonaStack/PersonaStack.app", true),
        ("/private/var/folders/test/AppTranslocation/test/PersonaStack.app", false),
        ("/tmp/PersonaStack", false),
    ])
    func uninstalledLaunchDoesNotConsumeFirstInstalledLaunch(_ path: String, _ readOnly: Bool) throws {
        let suite = "DesktopLoginItemRegistrationTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        DesktopLoginItemRegistration.enableOnFirstLaunch(preferences: preferences, bundleURL: URL(fileURLWithPath: path),
            volumeIsReadOnly: readOnly, status: { Issue.record("Must not query uninstalled login item"); return .notRegistered },
            register: { Issue.record("Must not register uninstalled app") }, legacyStatus: { .notRegistered })
        #expect(!preferences.bool(forKey: DesktopLoginItemRegistration.firstLaunchHandledKey))

        var registrations = 0
        var serviceStatus = SMAppService.Status.notRegistered
        DesktopLoginItemRegistration.enableOnFirstLaunch(preferences: preferences, bundleURL: installedBundle,
            volumeIsReadOnly: false, status: { serviceStatus }, register: {
                registrations += 1
                serviceStatus = .enabled
            }, legacyStatus: { .notRegistered })
        #expect(preferences.bool(forKey: DesktopLoginItemRegistration.firstLaunchHandledKey))
        #expect(registrations == 1)
        #expect(serviceStatus == .enabled)
    }
}
