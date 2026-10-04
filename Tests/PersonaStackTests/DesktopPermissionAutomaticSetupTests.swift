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
    #expect(model.permissionRows.map(\.id) == [.accessibility, .screenRecording, .directCapture, .automation, .safariJavaScript, .clipboard, .fullDiskAccess, .microphone])
    #expect(model.automaticRows.map(\.id) == [.launchAtLogin, .notifications, .automaticUpdates, .awakeDuringRemoteWork])
    #expect(DesktopPermissionID.screenRecording.title == "Screen Capture")
    fake.values[.localNetwork] = .init(.verificationRequired, detail: "Selected LAN endpoints")
    await model.refresh()
    #expect(model.permissionRows.map(\.id) == DesktopPermissionID.setupPermissions)
    #expect(model.canFinish)
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
        var access = DesktopPermissionSystemAccess.permissionFixture()
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

@Test @MainActor func permissionNotificationAutomaticSetupPreservesDisabledAlertsAndManualSetupRequestsAuthorization() async {
    var settingsOpened = 0
    var requests = 0
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.notificationSettings = { (.authorized, .disabled, .disabled) }
    access.requestNotifications = { requests += 1 }
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access, openSettings: { _ in settingsOpened += 1 })
    #expect(await adapter.setupAutomatically(.notifications).state == .notGranted)
    #expect(settingsOpened == 0 && requests == 0)
    #expect(await adapter.setup(.notifications).state == .notGranted)
    #expect(settingsOpened == 1 && requests == 1)
}

@Test @MainActor func permissionLoginAutomaticSetupRequiresConfirmedEnabledStatusAndDoesNotRepeatRegistration() async {
    for (initialStatus, registeredStatus) in [
        (SMAppService.Status.notRegistered, SMAppService.Status.enabled),
        (.notRegistered, .requiresApproval), (.notFound, .enabled), (.notFound, .requiresApproval)
    ] {
        var status = initialStatus
        var registrations = 0
        var settingsOpened = 0
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.loginStatus = { status }
        access.registerLogin = { registrations += 1; status = registeredStatus }
        access.unregisterLoginForSetup = { status = .notRegistered }
        access.legacyLoginStatus = { .notRegistered }
        access.unregisterLegacyLogin = { Issue.record("Must not unregister the legacy login service") }
        access.unregisterCrashRecoveryAgent = { Issue.record("Must not unregister the fake agent") }
        access.registerLegacyLogin = { Issue.record("Must not restore the legacy login service") }
        access.openLoginSettings = { settingsOpened += 1 }
        let adapter = DesktopPermissionChecklistSystemAdapter(access: access)
        let expected: DesktopPermissionState = registeredStatus == .enabled ? .ready : .notGranted
        #expect(await adapter.observe(.launchAtLogin).state == .notGranted)
        #expect(registrations == 0)
        #expect(await adapter.setupAutomatically(.launchAtLogin).state == expected)
        #expect(await adapter.setupAutomatically(.launchAtLogin).state == expected)
        #expect(registrations == 1 && settingsOpened == 0)
        #expect(await adapter.setup(.launchAtLogin).state == expected)
        #expect(registrations == 2)
        #expect(settingsOpened == (registeredStatus == .requiresApproval ? 1 : 0))
    }
}

@Test @MainActor func permissionLoginUnconfirmedRegistrationStaysFailedAndManualRetryOpensSettings() async {
    for initialStatus in [SMAppService.Status.notFound, .notRegistered] {
        var registrations = 0
        var settingsOpened = 0
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.loginStatus = { initialStatus }
        access.registerLogin = { registrations += 1 }
        access.legacyLoginStatus = { .notRegistered }
        access.unregisterLegacyLogin = { Issue.record("Must not unregister the legacy login service") }
        access.unregisterCrashRecoveryAgent = { Issue.record("Must not unregister the fake agent") }
        access.registerLegacyLogin = { Issue.record("Must not restore the legacy login service") }
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
    var access = DesktopPermissionSystemAccess.permissionFixture()
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
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.accessibility = { false }
    access.requestAccessibility = { Issue.record("Automatic setup must not request Accessibility") }
    access.loginStatus = { .notRegistered }
    access.registerLogin = { throw CocoaError(.fileWriteNoPermission) }
    access.legacyLoginStatus = { .notRegistered }
    access.unregisterLegacyLogin = { Issue.record("Must not unregister the legacy login service") }
    access.unregisterCrashRecoveryAgent = { Issue.record("Must not unregister the fake agent") }
    access.registerLegacyLogin = { Issue.record("Must not restore the legacy login service") }
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access,
        openSettings: { _ in Issue.record("Automatic setup must not open Settings") })
    #expect(await adapter.setupAutomatically(.accessibility).state == .notGranted)
    #expect(await adapter.setupAutomatically(.launchAtLogin).state == .failed)
}

@Test(arguments: [DesktopPermissionState.failed, .denied, .notGranted, .ready, .notNeeded])
@MainActor func localNetworkSetupTriesNetworkWithoutOpeningPrivacySettings(state: DesktopPermissionState) async {
    var openedSettings: [String] = []
    var requests = 0
    let hooks = DesktopPermissionChecklistHooks(setup: { permission in
        guard permission == .localNetwork else { return nil }
        requests += 1
        return .init(state, detail: "Endpoint result")
    })
    let adapter = DesktopPermissionChecklistSystemAdapter(hooks: hooks, access: .permissionFixture(),
        openSettings: { openedSettings.append($0) })

    let result = await adapter.setup(.localNetwork)

    #expect(result.state == state && requests == 1)
    #expect(openedSettings.isEmpty)
    adapter.openLocalNetworkSettings()
    #expect(openedSettings == ["com.apple.preference.security?Privacy_LocalNetwork"])
}

@Test @MainActor func failedManualNotificationRequestOpensNotificationSettingsButAutomaticRetryDoesNot() async {
    var openedSettings: [String] = []
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.notificationSettings = { (.notDetermined, .enabled, .enabled) }
    access.requestNotifications = { throw CocoaError(.fileWriteUnknown) }
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access,
        openSettings: { openedSettings.append($0) })

    #expect(await adapter.setup(.notifications).state == .failed)
    #expect(openedSettings == ["com.apple.Notifications-Settings.extension?id=ai.personastack.desktop"])
    #expect(await adapter.setupAutomatically(.notifications).state == .failed)
    #expect(openedSettings == ["com.apple.Notifications-Settings.extension?id=ai.personastack.desktop"])
}

@Test @MainActor func failedManualLoginRegistrationOpensLoginSettingsButAutomaticRetryDoesNot() async {
    var openedSettings = 0
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.loginStatus = { .notRegistered }
    access.registerLogin = { throw CocoaError(.fileWriteNoPermission) }
    access.legacyLoginStatus = { .notRegistered }
    access.openLoginSettings = { openedSettings += 1 }
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access)

    #expect(await adapter.setup(.launchAtLogin).state == .failed)
    #expect(openedSettings == 1)
    #expect(await adapter.setupAutomatically(.launchAtLogin).state == .failed)
    #expect(openedSettings == 1)
}

@Test @MainActor func permissionChecksNeverResetRegisterOrRequestExistingChoices() async {
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.resetPermission = { _ in Issue.record("Check must not reset TCC"); return .failed }
    access.requestNotifications = { Issue.record("Check must not request authorization") }
    access.registerLogin = { Issue.record("Check must not register") }
    access.unregisterLoginForSetup = { Issue.record("Check must not unregister") }
    access.unregisterLegacyLoginForSetup = { Issue.record("Check must not unregister") }
    access.loginStatus = { .enabled }
    access.notificationSettings = { (.authorized, .enabled, .enabled) }
    access.accessibility = { true }
    access.screenRecording = { true }
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access,
        openSettings: { _ in Issue.record("Check must not open Settings") })
    for id in [DesktopPermissionID.launchAtLogin, .notifications, .accessibility, .screenRecording] {
        #expect(await adapter.check(id).state == .ready)
    }
}

@Test @MainActor func permissionChecksRunCurrentFunctionalOwnersWithoutCallingSetup() async {
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.microphone = { .authorized }
    access.resetPermission = { _ in Issue.record("Check must not reset"); return .failed }
    var checked: [DesktopPermissionID] = []
    let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(
        setup: { _ in Issue.record("Check must not invoke explicit Setup"); return nil },
        verifyAutomatically: { id in
            checked.append(id)
            return .init(.ready, detail: "Current functional proof", verified: true)
        }
    ), access: access)
    let ids: [DesktopPermissionID] = [.microphone, .fullDiskAccess, .localNetwork, .awakeDuringRemoteWork]
    for id in ids {
        #expect(await adapter.check(id).detail == "Current functional proof")
    }
    #expect(checked == ids)
}

@Test @MainActor func notificationSetupReportsRememberedDenialAndRejectedRequestWithoutResettingIdentity() async {
    var access = DesktopPermissionSystemAccess.permissionFixture()
    var requests = 0
    var reject = false
    access.notificationSettings = { (.denied, .disabled, .disabled) }
    access.resetPermission = { _ in Issue.record("Notifications has no TCC reset"); return .failed }
    access.requestNotifications = {
        requests += 1
        if reject { throw NSError(domain: UNErrorDomain, code: UNError.Code.notificationsNotAllowed.rawValue) }
    }
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access, openSettings: { _ in })
    let denied = await adapter.setup(.notifications)
    #expect(denied.state == .denied && denied.detail.contains("cannot clear"))
    reject = true
    let rejected = await adapter.setup(.notifications)
    #expect(rejected.state == .denied && rejected.detail.contains("cannot clear"))
    #expect(requests == 2)
}

@Test @MainActor func notificationSettingsRecoveryTargetsPersonaStackForEveryEntryPoint() async {
    var opened: [String] = []
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.notificationSettings = { (.denied, .disabled, .disabled) }
    access.verifyNotificationDelivery = { Issue.record("Denied notification must not be submitted"); return false }
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access, openSettings: { opened.append($0) })
    adapter.openSettings(.notifications)
    #expect(await adapter.setup(.notifications).state == .denied)
    #expect(opened == Array(repeating: "com.apple.Notifications-Settings.extension?id=ai.personastack.desktop", count: 2))
}

@Test(arguments: [true, false]) @MainActor
func notificationSetupResolvesRequestErrorsThroughFreshAuthorizationAndDelivery(delivered: Bool) async {
    var submitted = 0
    var opened: [String] = []
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.notificationSettings = { (.authorized, .enabled, .enabled) }
    access.requestNotifications = { throw NSError(domain: UNErrorDomain, code: UNError.Code.notificationsNotAllowed.rawValue) }
    access.verifyNotificationDelivery = { submitted += 1; return delivered }
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access, openSettings: { opened.append($0) })
    let result = await adapter.setup(.notifications)
    #expect(submitted == 1)
    #expect(result.state == (delivered ? .ready : .verificationRequired))
    #expect(result.verified == delivered)
    #expect(opened.count == (delivered ? 0 : 1))
}

@Test @MainActor func notificationPassiveReadsNeverDeliverAndCheckDetectsRejectedCurrentIdentity() async {
    var submitted = 0
    var reject = true
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.notificationSettings = { (.authorized, .enabled, .enabled) }
    access.requestNotifications = { Issue.record("Known authorization must not prompt during Check or automatic setup") }
    access.verifyNotificationDelivery = {
        submitted += 1
        if reject { throw NSError(domain: UNErrorDomain, code: UNError.Code.notificationsNotAllowed.rawValue) }
        return true
    }
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access,
        openSettings: { _ in Issue.record("Check/passive/automatic must not open Settings") })
    let passive = await adapter.observe(.notifications)
    #expect(passive.state == .ready && passive.requiresVerification && !passive.verified)
    #expect(submitted == 0)
    #expect(await adapter.setupAutomatically(.notifications).state == .failed)
    #expect(submitted == 1)
    let failed = await adapter.check(.notifications)
    #expect(failed.state == .failed && failed.detail.contains("allowed in Settings"))
    reject = false
    let ready = await adapter.check(.notifications)
    #expect(ready.state == .ready && ready.verified && ready.verificationKey == passive.verificationKey)
    #expect(submitted == 3)
}

@Test(arguments: [true, false]) @MainActor
func notificationCheckRechecksAuthorizationAfterDelivery(denied: Bool) async {
    var authorization = UNAuthorizationStatus.authorized
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.notificationSettings = { (authorization, .enabled, .enabled) }
    access.verifyNotificationDelivery = {
        authorization = denied ? .denied : .provisional
        return true
    }
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access)
    let result = await adapter.check(.notifications)
    #expect(result.state == (denied ? .denied : .verificationRequired))
    #expect(!result.verified)
}

@Test @MainActor func notificationCancelledSetupCannotOpenSettingsOrPublishDelivery() async {
    var pending: CheckedContinuation<Bool, Never>?
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.notificationSettings = { (.authorized, .enabled, .enabled) }
    access.verifyNotificationDelivery = { await withCheckedContinuation { pending = $0 } }
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access,
        openSettings: { _ in Issue.record("Cancelled setup must not open Settings") })
    let task = Task { await adapter.setup(.notifications) }
    while pending == nil { await Task.yield() }
    task.cancel()
    pending?.resume(returning: true)
    let result = await task.value
    #expect(result.state == .checking && !result.verified)
}

@Test @MainActor func permissionLoginSignatureFailureShowsActualRequirement() async {
    guard #available(macOS 15, *) else { return }
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.loginStatus = { .notRegistered }
    access.legacyLoginStatus = { .notRegistered }
    access.registerLogin = { throw NSError(domain: SMAppServiceErrorDomain, code: kSMErrorInvalidSignature) }
    access.openLoginSettings = { }
    let result = await DesktopPermissionChecklistSystemAdapter(access: access).setup(.launchAtLogin)
    #expect(result.state == .failed && result.detail.contains("valid bundle signature"))
}

@Test @MainActor func permissionLoginCheckRejectsAnEnabledEntryForAnInvalidCurrentBundle() async {
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.loginStatus = { .enabled }
    access.loginSignatureIsValid = { false }
    access.registerLogin = { Issue.record("Check must not register") }
    access.unregisterLoginForSetup = { Issue.record("Check must not unregister") }
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access)
    for result in [await adapter.observe(.launchAtLogin), await adapter.check(.launchAtLogin)] {
        #expect(result.state == .failed && result.detail.contains("older installation"))
    }
    access.loginSignatureIsValid = { true }
    #expect(await DesktopPermissionChecklistSystemAdapter(access: access).check(.launchAtLogin).state == .ready)
}

@Test @MainActor func permissionLoginSetupReportsWhichRemovalMacOSRefused() async {
    guard #available(macOS 15, *) else { return }
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.loginStatus = { .enabled }
    access.unregisterLoginForSetup = { throw NSError(domain: SMAppServiceErrorDomain, code: kSMErrorInvalidSignature) }
    var legacy = SMAppService.Status.enabled
    access.legacyLoginStatus = { legacy }
    access.unregisterLegacyLoginForSetup = { legacy = .notRegistered }
    access.registerLogin = { Issue.record("No registration after failed purge") }
    access.openLoginSettings = { }
    let result = await DesktopPermissionChecklistSystemAdapter(access: access).setup(.launchAtLogin)
    #expect(result.state == .failed && result.detail.contains("refused to remove"))
    #expect(legacy == .notRegistered)
}

@Test @MainActor func notificationGrantChangeVerifiesOnceAndRevocationRemovesReady() async {
    var authorization = UNAuthorizationStatus.denied
    var deliveries = 0
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.notificationSettings = { (authorization, .enabled, .enabled) }
    access.verifyNotificationDelivery = { deliveries += 1; return true }
    let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(observe: { id in
        id == .notifications ? nil : .init(.notNeeded, detail: "Unrelated capability")
    }), access: access, openSettings: { _ in Issue.record("Automatic approval must not open Settings") })
    let model = DesktopPermissionChecklistCoordinator(adapter: adapter)
    model.open()
    defer { model.cancel() }
    await model.refresh()
    #expect(model.rows.first { $0.id == .notifications }?.state == .denied && deliveries == 0)
    authorization = .authorized
    await model.refresh()
    #expect(model.rows.first { $0.id == .notifications }?.isComplete == true && deliveries == 1)
    for _ in 0..<3 { await model.refresh() }
    #expect(deliveries == 1)
    authorization = .denied
    await model.refresh()
    #expect(model.rows.first { $0.id == .notifications }?.state == .denied)
    authorization = .authorized
    await model.refresh()
    #expect(model.rows.first { $0.id == .notifications }?.isComplete == true && deliveries == 2)
}
