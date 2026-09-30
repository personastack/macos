import Foundation
import PersonaStackCore
import ServiceManagement
import Testing

@Suite @MainActor
struct DesktopLoginItemRegistrationTests {
    private let installedBundle = URL(fileURLWithPath: "/Applications/PersonaStack.app")

    @Test func firstLaunchRegistersOnceAndPreservesLaterDisable() throws {
        let suite = "DesktopLoginItemRegistrationTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var serviceStatus = SMAppService.Status.notRegistered
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
