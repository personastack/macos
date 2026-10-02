import Foundation
import Testing
import UserNotifications
@testable import PersonaStack

struct DesktopNotificationCoordinatorTests {
    @Test @MainActor func explicitSetupMakesARequestDuringAnEarlierSettingsRead() async throws {
        var settingsRead: CheckedContinuation<UNAuthorizationStatus, Never>?
        var approval: CheckedContinuation<Bool, Error>?
        var requests = 0
        let authorization = DesktopNotificationAuthorization(settings: {
            await withCheckedContinuation { settingsRead = $0 }
        }, request: { _ in
            requests += 1
            return try await withCheckedThrowingContinuation { approval = $0 }
        })
        let startup = Task { try await authorization.requestIfNeeded() }
        while settingsRead == nil { await Task.yield() }
        let setup = Task { try await authorization.requestIfNeeded(explicit: true) }
        for _ in 0..<10 { await Task.yield() }
        #expect(requests == 1)
        settingsRead?.resume(returning: .denied)
        settingsRead = nil
        for _ in 0..<10 { await Task.yield() }
        approval?.resume(returning: false)
        approval = nil
        #expect(try await startup.value == false)
        #expect(try await setup.value == false)
        #expect(requests == 1)
    }

    @Test(arguments: [UNAuthorizationStatus.authorized, .denied, .notDetermined])
    @MainActor func explicitSetupAlwaysMakesTheRealAuthorizationRequest(status: UNAuthorizationStatus) async throws {
        var requests = 0
        let authorization = DesktopNotificationAuthorization(settings: { status }, request: { options in
            #expect(options == [.alert, .sound])
            requests += 1
            return status != .denied
        })
        #expect(try await authorization.requestIfNeeded(explicit: true) == (status != .denied))
        #expect(requests == 1)
    }

    @Test @MainActor func launchChecklistAndReceiverReplacementShareOneNotificationPrompt() async throws {
        var status = UNAuthorizationStatus.notDetermined
        var reads = 0
        var requests: [UNAuthorizationOptions] = []
        var response: CheckedContinuation<Bool, Error>?
        let authorization = DesktopNotificationAuthorization(settings: {
            reads += 1
            return status
        }, request: { options in
            requests.append(options)
            return try await withCheckedThrowingContinuation { response = $0 }
        })
        let launch = Task { try await authorization.requestIfNeeded() }
        while response == nil { await Task.yield() }
        var checklistStarted = false
        let checklist = Task {
            checklistStarted = true
            return try await authorization.requestIfNeeded(explicit: true)
        }
        while !checklistStarted { await Task.yield() }
        #expect(reads == 1 && requests == [[.alert, .sound]])
        // Closing setup must not cancel the app's pending startup approval.
        checklist.cancel()
        status = .authorized
        response?.resume(returning: true)
        response = nil
        #expect(try await launch.value)
        #expect(try await checklist.value)
        #expect(try await authorization.requestIfNeeded())
        #expect(reads == 2 && requests == [[.alert, .sound]])
    }

    @Test(arguments: [UNAuthorizationStatus.authorized, .provisional, .denied])
    @MainActor func existingNotificationChoiceDoesNotPromptAgain(status: UNAuthorizationStatus) async throws {
        let authorization = DesktopNotificationAuthorization(settings: { status }, request: { _ in
            Issue.record("Existing notification decisions must not be requested again")
            return false
        })
        #expect(try await authorization.requestIfNeeded() == (status != .denied))
        #expect(try await authorization.requestIfNeeded() == (status != .denied))
    }

    @Test @MainActor func deniedNotificationRequestIsNotRepeatedByTheChecklist() async throws {
        var status = UNAuthorizationStatus.notDetermined
        var requests = 0
        let authorization = DesktopNotificationAuthorization(settings: { status }, request: { _ in
            requests += 1
            status = .denied
            return false
        })
        #expect(try await authorization.requestIfNeeded() == false)
        #expect(try await authorization.requestIfNeeded() == false)
        #expect(requests == 1)
    }

    @Test @MainActor func failedNotificationRequestCanBeRetriedWithoutCachingApproval() async throws {
        var status = UNAuthorizationStatus.notDetermined
        var requests = 0
        let authorization = DesktopNotificationAuthorization(settings: { status }, request: { _ in
            requests += 1
            if requests == 1 { throw CancellationError() }
            status = .authorized
            return true
        })
        await #expect(throws: CancellationError.self) { try await authorization.requestIfNeeded() }
        #expect(try await authorization.requestIfNeeded())
        #expect(try await authorization.requestIfNeeded())
        #expect(requests == 2)
    }

    @Test @MainActor func notificationActionsRouteToTheMatchingUpdateFlow() {
        #expect(DesktopNotificationCoordinator.updateAction(
            requestIdentifier: "personastack-update-available-0.1.49",
            actionIdentifier: UNNotificationDefaultActionIdentifier
        ) == .download)
        #expect(DesktopNotificationCoordinator.updateAction(
            requestIdentifier: "personastack-update-available-0.1.49",
            actionIdentifier: "PERSONASTACK_DOWNLOAD_UPDATE"
        ) == .download)
        #expect(DesktopNotificationCoordinator.updateAction(
            requestIdentifier: "personastack-update-ready-0.1.49",
            actionIdentifier: UNNotificationDefaultActionIdentifier
        ) == .restart)
        #expect(DesktopNotificationCoordinator.updateAction(
            requestIdentifier: "personastack-update-ready-0.1.49",
            actionIdentifier: "PERSONASTACK_RESTART_UPDATE"
        ) == .restart)
    }

    @Test @MainActor func laterAndUnknownNotificationsDoNotRunUpdateActions() {
        #expect(DesktopNotificationCoordinator.updateAction(
            requestIdentifier: "personastack-update-ready-0.1.49",
            actionIdentifier: "PERSONASTACK_LATER"
        ) == nil)
        #expect(DesktopNotificationCoordinator.updateAction(
            requestIdentifier: "personastack-concern-123",
            actionIdentifier: UNNotificationDefaultActionIdentifier
        ) == nil)
    }
}
