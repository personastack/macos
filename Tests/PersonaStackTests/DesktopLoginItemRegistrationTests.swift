import Foundation
import PersonaStackCore
import ServiceManagement
import Testing

@Suite @MainActor
struct DesktopLoginItemRegistrationTests {
    private struct MigrationFailure: Error {}
    private let installedBundle = URL(fileURLWithPath: "/Applications/PersonaStack.app")

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
