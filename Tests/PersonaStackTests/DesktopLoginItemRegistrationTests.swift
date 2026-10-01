import Foundation
import PersonaStackCore
import ServiceManagement
import Testing

@Suite @MainActor
struct DesktopLoginItemRegistrationTests {
    private let installedBundle = URL(fileURLWithPath: "/Applications/PersonaStack.app")

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
            volumeIsReadOnly: false, status: { serviceStatus }, register: register)
        #expect(registrations == 1)
        #expect(serviceStatus == .enabled)

        let reopenedPreferences = try #require(UserDefaults(suiteName: suite))
        serviceStatus = .notRegistered
        DesktopLoginItemRegistration.enableOnFirstLaunch(preferences: reopenedPreferences, bundleURL: installedBundle,
            volumeIsReadOnly: false, status: { Issue.record("Later launches must not query or alter the login item"); return serviceStatus },
            register: register)
        #expect(registrations == 1)
        #expect(serviceStatus == .notRegistered)
    }

    @Test func successfulRegisterWithoutConfirmedStatusIsNotReportedAsEnabled() throws {
        let suite = "DesktopLoginItemRegistrationTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var registrations = 0
        DesktopLoginItemRegistration.enableOnFirstLaunch(preferences: preferences, bundleURL: installedBundle,
            volumeIsReadOnly: false, status: { .notFound }, register: { registrations += 1 })
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
            volumeIsReadOnly: false, status: { serviceStatus }, register: { Issue.record("Must not register an existing login item") })
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
            volumeIsReadOnly: false, status: { serviceStatus }, register: { serviceStatus = .requiresApproval })
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
                })
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
            register: { Issue.record("Must not register uninstalled app") })
        #expect(!preferences.bool(forKey: DesktopLoginItemRegistration.firstLaunchHandledKey))

        var registrations = 0
        var serviceStatus = SMAppService.Status.notRegistered
        DesktopLoginItemRegistration.enableOnFirstLaunch(preferences: preferences, bundleURL: installedBundle,
            volumeIsReadOnly: false, status: { serviceStatus }, register: {
                registrations += 1
                serviceStatus = .enabled
            })
        #expect(preferences.bool(forKey: DesktopLoginItemRegistration.firstLaunchHandledKey))
        #expect(registrations == 1)
        #expect(serviceStatus == .enabled)
    }
}
