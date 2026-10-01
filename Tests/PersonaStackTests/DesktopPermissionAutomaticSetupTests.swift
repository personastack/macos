import Foundation
import ServiceManagement
import Testing
import UserNotifications
@testable import PersonaStack
@testable import PersonaStackCore

@MainActor
private final class AutomaticPermissionFake: DesktopPermissionChecklistAdapting {
    var values: [DesktopPermissionID: DesktopPermissionObservation] = [:]
    var requested: [DesktopPermissionID] = []
    var pending: CheckedContinuation<DesktopPermissionObservation, Never>?
    var suspend = false
    func observe(_ id: DesktopPermissionID) async -> DesktopPermissionObservation {
        values[id] ?? .init(.ready, detail: "Fixture ready")
    }
    func setup(_ id: DesktopPermissionID) async -> DesktopPermissionObservation {
        requested.append(id)
        if suspend { return await withCheckedContinuation { pending = $0 } }
        let value = DesktopPermissionObservation(id == .notifications ? .denied : .ready, detail: "Confirmed status")
        values[id] = value
        return value
    }
}

@Test @MainActor func permissionChecklistShowsOnlyReducedApprovalsAndAutomaticStatuses() async {
    let fake = AutomaticPermissionFake()
    fake.values[.localNetwork] = .init(.notNeeded, detail: "Cloud services")
    let model = DesktopPermissionChecklistCoordinator(adapter: fake)
    model.open()
    defer { model.cancel() }
    await model.refresh()
    #expect(model.permissionRows.map(\.id) == [.accessibility, .screenRecording, .fullDiskAccess, .microphone])
    #expect(model.automaticRows.map(\.id) == [.launchAtLogin, .notifications, .automaticUpdates, .awakeDuringRemoteWork])
    #expect(DesktopPermissionID.screenRecording.title == "Screen Capture")
    fake.values[.localNetwork] = .init(.verificationRequired, detail: "Selected LAN endpoints")
    await model.refresh()
    #expect(model.permissionRows.map(\.id) == DesktopPermissionID.setupPermissions)
    #expect(!model.canFinish)
    #expect(fake.requested.isEmpty)
}

@Test @MainActor func permissionAutomaticSetupRunsOncePerPresentationAndDoesNotRequestCoreGrants() async {
    let fake = AutomaticPermissionFake()
    for id in DesktopPermissionID.automaticSetup { fake.values[id] = .init(.notGranted, detail: "Needs setup") }
    let model = DesktopPermissionChecklistCoordinator(adapter: fake)
    model.open()
    await model.refresh()
    #expect(fake.requested.isEmpty)
    model.startAutomaticSetup()
    model.startAutomaticSetup()
    #expect(model.canFinish)
    while model.automaticBusyPermission != nil { await Task.yield() }
    #expect(fake.requested == DesktopPermissionID.automaticSetup)
    #expect(model.automaticRows.first { $0.id == .notifications }?.state == .denied)
    #expect(model.canFinish)
    await model.refresh()
    model.startAutomaticSetup()
    #expect(fake.requested == DesktopPermissionID.automaticSetup)
    model.cancel()
    model.open()
    model.startAutomaticSetup()
    while model.automaticBusyPermission != nil { await Task.yield() }
    #expect(fake.requested == DesktopPermissionID.automaticSetup + [.notifications])
    model.cancel()
}

@Test @MainActor func permissionAutomaticSetupCancellationFencesLateResultAndRemainingRequests() async {
    let fake = AutomaticPermissionFake()
    fake.suspend = true
    fake.values[.launchAtLogin] = .init(.notGranted, detail: "Not enabled")
    let model = DesktopPermissionChecklistCoordinator(adapter: fake)
    model.open()
    model.startAutomaticSetup()
    while fake.pending == nil { await Task.yield() }
    model.cancel()
    model.open()
    await model.refresh()
    fake.pending?.resume(returning: .init(.ready, detail: "Old success"))
    fake.pending = nil
    for _ in 0..<3 { await Task.yield() }
    #expect(fake.requested == [.launchAtLogin])
    #expect(model.automaticRows.first { $0.id == .launchAtLogin }?.state == .notGranted)
    #expect(model.busyPermission == nil)
    model.cancel()
}

@Test @MainActor func permissionNotificationAutomaticSetupReadsBackApprovalAndNeverOpensSettings() async {
    for approved in [true, false] {
        var authorization = UNAuthorizationStatus.notDetermined
        var requests = 0
        var access = DesktopPermissionSystemAccess()
        access.notificationSettings = { (authorization, .enabled, .enabled) }
        access.requestNotifications = {
            requests += 1
            authorization = approved ? .authorized : .denied
        }
        let adapter = DesktopPermissionChecklistSystemAdapter(access: access,
            openSettings: { _ in Issue.record("Automatic setup must not open Settings") })
        #expect(await adapter.observe(.notifications).state == .notGranted)
        #expect(requests == 0)
        #expect(await adapter.setupAutomatically(.notifications).state == (approved ? .ready : .denied))
        #expect(await adapter.setupAutomatically(.notifications).state == (approved ? .ready : .denied))
        #expect(requests == 1)
    }
}

@Test @MainActor func permissionOptionalNotificationPromptDoesNotBlockCoreSetupOrFinishAndLateResultsAreIgnored() async {
    let fake = AutomaticPermissionFake()
    fake.suspend = true
    fake.values[.notifications] = .init(.notGranted, detail: "Approval pending")
    let model = DesktopPermissionChecklistCoordinator(adapter: fake)
    model.open()
    await model.refresh()
    model.startAutomaticSetup()
    while fake.pending == nil { await Task.yield() }
    #expect(model.automaticBusyPermission == .notifications)
    fake.suspend = false
    model.setup(.accessibility)
    while model.busyPermission != nil { await Task.yield() }
    #expect(fake.requested == [.notifications, .accessibility])
    #expect(model.canFinish)
    model.finish()
    fake.pending?.resume(returning: .init(.ready, detail: "Late approval"))
    fake.pending = nil
    for _ in 0..<3 { await Task.yield() }
    #expect(model.isFinishing && model.automaticBusyPermission == nil)
    #expect(model.automaticRows.first { $0.id == .notifications }?.state == .notGranted)
    #expect(fake.requested == [.notifications, .accessibility])
    model.cancel()
}

@Test @MainActor func permissionNotificationAutomaticSetupPreservesDisabledAlertsAndManualRetryOpensSettings() async {
    var settingsOpened = 0
    var access = DesktopPermissionSystemAccess()
    access.notificationSettings = { (.authorized, .disabled, .disabled) }
    access.requestNotifications = { Issue.record("Existing notification choice must not prompt again") }
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access, openSettings: { _ in settingsOpened += 1 })
    #expect(await adapter.setupAutomatically(.notifications).state == .notGranted)
    #expect(settingsOpened == 0)
    #expect(await adapter.setup(.notifications).state == .notGranted)
    #expect(settingsOpened == 1)
}

@Test @MainActor func permissionLoginAutomaticSetupRequiresConfirmedEnabledStatusAndDoesNotRepeatRegistration() async {
    for (initialStatus, registeredStatus) in [
        (SMAppService.Status.notRegistered, SMAppService.Status.enabled),
        (.notRegistered, .requiresApproval), (.notFound, .enabled), (.notFound, .requiresApproval)
    ] {
        var status = initialStatus
        var registrations = 0
        var settingsOpened = 0
        var access = DesktopPermissionSystemAccess()
        access.loginStatus = { status }
        access.registerLogin = { registrations += 1; status = registeredStatus }
        access.openLoginSettings = { settingsOpened += 1 }
        let adapter = DesktopPermissionChecklistSystemAdapter(access: access)
        let expected: DesktopPermissionState = registeredStatus == .enabled ? .ready : .notGranted
        #expect(await adapter.observe(.launchAtLogin).state == .notGranted)
        #expect(registrations == 0)
        #expect(await adapter.setupAutomatically(.launchAtLogin).state == expected)
        #expect(await adapter.setupAutomatically(.launchAtLogin).state == expected)
        #expect(registrations == 1 && settingsOpened == 0)
        #expect(await adapter.setup(.launchAtLogin).state == expected)
        #expect(settingsOpened == (registeredStatus == .requiresApproval ? 1 : 0))
    }
}

@Test @MainActor func permissionLoginUnconfirmedRegistrationStaysFailedAndManualRetryOpensSettings() async {
    for initialStatus in [SMAppService.Status.notFound, .notRegistered] {
        var registrations = 0
        var settingsOpened = 0
        var access = DesktopPermissionSystemAccess()
        access.loginStatus = { initialStatus }
        access.registerLogin = { registrations += 1 }
        access.openLoginSettings = { settingsOpened += 1 }
        let adapter = DesktopPermissionChecklistSystemAdapter(access: access)
        let passive = await adapter.observe(.launchAtLogin)
        #expect(passive.state == .notGranted)
        #expect(!passive.detail.contains("Install"))
        let automatic = await adapter.setupAutomatically(.launchAtLogin)
        #expect(automatic.state == .failed)
        #expect(automatic.detail == DesktopLoginItemRegistration.unconfirmedMessage)
        #expect(registrations == 1 && settingsOpened == 0)
        #expect(await adapter.setup(.launchAtLogin).state == .failed)
        #expect(registrations == 2 && settingsOpened == 1)
    }
}

@Test @MainActor func permissionCancelledNotificationRetryDoesNotOpenSettingsAfterDelayedReadback() async {
    var reads = 0
    var pending: CheckedContinuation<Void, Never>?
    var access = DesktopPermissionSystemAccess()
    access.notificationSettings = {
        reads += 1
        if reads == 2 { await withCheckedContinuation { pending = $0 } }
        return (.denied, .disabled, .disabled)
    }
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access,
        openSettings: { _ in Issue.record("Cancelled Retry must not open Settings") })
    let retry = Task { await adapter.setup(.notifications) }
    while pending == nil { await Task.yield() }
    retry.cancel()
    pending?.resume()
    #expect(await retry.value.state == .checking)
}

@Test @MainActor func automaticSetupRefusesCorePermissionRequestsAndReportsRegistrationFailure() async {
    var access = DesktopPermissionSystemAccess()
    access.accessibility = { false }
    access.requestAccessibility = { Issue.record("Automatic setup must not request Accessibility") }
    access.loginStatus = { .notRegistered }
    access.registerLogin = { throw CocoaError(.fileWriteNoPermission) }
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access,
        openSettings: { _ in Issue.record("Automatic setup must not open Settings") })
    #expect(await adapter.setupAutomatically(.accessibility).state == .notGranted)
    #expect(await adapter.setupAutomatically(.launchAtLogin).state == .failed)
}
