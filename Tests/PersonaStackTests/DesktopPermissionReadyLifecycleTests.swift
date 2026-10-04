import AppKit
import AVFoundation
import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

@MainActor
private final class ReadyVoicePage: DesktopVoicePermissionPage {
    var tests = 0
    var cancels = 0
    var result: Result<Bool, Error> = .success(true)
    var pending: ((Result<Bool, Error>) -> Void)?
    var hold = false
    func test(id: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        tests += 1
        if hold { pending = completion } else { completion(result) }
    }
    func cancel(id: String) { cancels += 1 }
}

@MainActor
private func isolateReadyRows(_ service: DesktopPermissionChecklist, _ ids: Set<DesktopPermissionID>) {
    let hooks = service.adapter.hooks
    service.adapter.hooks = .init(observe: { id in
        if ids.contains(id) { return await hooks.observe(id) }
        return .init(.notNeeded, detail: "Unrelated fixture capability")
    }, setup: { id in
        guard ids.contains(id) else { Issue.record("Unexpected setup action"); return .init(.failed, detail: "Unexpected") }
        return await hooks.setup(id)
    }, verifyAutomatically: { id in
        guard ids.contains(id) else { return .init(.notNeeded, detail: "Unrelated fixture capability") }
        return await hooks.verifyAutomatically(id)
    })
}

@MainActor
private func openReadyChecklist(_ service: DesktopPermissionChecklist) async {
    service.window.onPresent?()
    service.window.coordinator.open()
    await service.window.coordinator.refresh()
}

@MainActor
private func readyRow(_ service: DesktopPermissionChecklist, _ id: DesktopPermissionID) -> DesktopPermissionRow? {
    service.window.coordinator.rows.first { $0.id == id }
}

@Test @MainActor func microphoneReadySurvivesCloseAndFinishWithoutRecordingAgain() async {
    let page = ReadyVoicePage()
    var status = AVAuthorizationStatus.authorized
    var input: String? = "input-a"
    var document = "document-a"
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.microphone = { status }
    access.hasMicrophone = { input != nil }
    access.microphoneIdentity = { input }
    let service = DesktopPermissionChecklist(access: access, selectedProfile: { .production },
        activationNotificationCenter: NotificationCenter(), voiceContext: {
            .init(identity: document, url: DesktopEnvironmentConfiguration.production.appURL, page: page)
        }, windowFactory: { coordinator in
            let verifier = DesktopLockedControlSetupVerifier(operations: .init(inspect: { .ready }))
            return DesktopPermissionChecklistWindow(coordinator: coordinator, lockedControlVerifier: verifier,
                authorizeFullControl: { _ in true })
        })
    isolateReadyRows(service, [.microphone])
    await openReadyChecklist(service)
    defer { service.window.cancel() }
    #expect(readyRow(service, .microphone)?.isComplete == false && page.tests == 0)
    service.window.coordinator.setup(.microphone)
    while service.window.coordinator.busyPermission != nil { await Task.yield() }
    #expect(readyRow(service, .microphone)?.isComplete == true && page.tests == 1)
    service.window.cancel()
    await openReadyChecklist(service)
    #expect(readyRow(service, .microphone)?.isComplete == true && page.tests == 1)
    await service.window.finish()
    await openReadyChecklist(service)
    #expect(readyRow(service, .microphone)?.isComplete == true && page.tests == 1)
    status = .denied
    await service.window.coordinator.refresh()
    #expect(readyRow(service, .microphone)?.state == .denied)
    status = .authorized
    await service.window.coordinator.refresh()
    #expect(readyRow(service, .microphone)?.isComplete == true && page.tests == 2)
    for _ in 0..<3 { await service.window.coordinator.refresh() }
    #expect(page.tests == 2)
    input = "input-b"
    #expect(await service.adapter.observe(.microphone).verified == false)
    input = "input-a"
    #expect(await service.adapter.observe(.microphone).verified == false)
    _ = await service.adapter.setup(.microphone)
    document = "document-b"
    #expect(await service.adapter.observe(.microphone).verified == false)
    #expect(page.tests == 3 && page.cancels == 3)
}

@Test @MainActor func microphoneFailedRetryAndCanceledLateReplyCannotRestoreReady() async {
    let page = ReadyVoicePage()
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.microphone = { .authorized }
    access.hasMicrophone = { true }
    access.microphoneIdentity = { "input" }
    let service = DesktopPermissionChecklist(access: access, selectedProfile: { .production },
        activationNotificationCenter: NotificationCenter(), voiceContext: {
            .init(identity: "document", url: DesktopEnvironmentConfiguration.production.appURL, page: page)
        })
    #expect(await service.adapter.setup(.microphone).verified)
    page.result = .failure(DesktopVoicePermissionError.emptyRecording)
    #expect(await service.adapter.setup(.microphone).state == .failed)
    #expect(await service.adapter.observe(.microphone).verified == false)
    page.hold = true
    let pending = Task { await service.adapter.setup(.microphone) }
    while page.pending == nil { await Task.yield() }
    service.window.completeSetup()
    page.pending?(.success(true))
    #expect(await pending.value.state == .checking)
    #expect(await service.adapter.observe(.microphone).verified == false)
}

@Test @MainActor func localNetworkPermissionReopenRefreshesExactEndpointsAndFreshFailureReplacesReady() async {
    var requests: [URLRequest] = []
    var fails = false
    var profile = DesktopEnvironmentConfiguration.lan
    let service = DesktopPermissionChecklist(access: .permissionFixture(), selectedProfile: { profile }, activationNotificationCenter: NotificationCenter(),
        requestEndpoint: { request in
            requests.append(request)
            #expect(request.httpMethod == "HEAD" && request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData && request.timeoutInterval == 4)
            if fails { throw URLError(.notConnectedToInternet) }
            return HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        })
    isolateReadyRows(service, [.localNetwork])
    await openReadyChecklist(service)
    defer { service.window.cancel() }
    #expect(requests.isEmpty)
    service.window.coordinator.setup(.localNetwork)
    while service.window.coordinator.busyPermission != nil { await Task.yield() }
    #expect(readyRow(service, .localNetwork)?.isComplete == true)
    #expect(requests.map(\.url) == [profile.appURL, profile.gatewayURL, profile.mcpURL])
    service.window.cancel()
    await openReadyChecklist(service)
    #expect(readyRow(service, .localNetwork)?.isComplete == true && requests.count == 6)
    for _ in 0..<3 { await service.window.coordinator.refresh() }
    #expect(requests.count == 6)
    fails = true
    service.invalidateAfterActivation()
    await service.window.coordinator.refresh()
    #expect(readyRow(service, .localNetwork)?.state == .failed && requests.count == 9)
    service.invalidateAfterActivation()
    await service.window.coordinator.refresh()
    #expect(requests.count == 12)
    fails = false
    service.invalidateAfterActivation()
    await service.window.coordinator.refresh()
    #expect(readyRow(service, .localNetwork)?.isComplete == true && requests.count == 15)
    for _ in 0..<3 { await service.window.coordinator.refresh() }
    #expect(requests.count == 15)
    profile = .production
    #expect(await service.adapter.observe(.localNetwork).state == .notNeeded)
    #expect(await service.adapter.setup(.localNetwork).state == .notNeeded)
    profile = .lan
    #expect(await service.adapter.observe(.localNetwork).state == .verificationRequired)
    #expect(requests.count == 15)
}

@Test @MainActor func localNetworkPermissionPublicEndpointFailureStillAttemptsBothLANServices() async {
    var requests: [URLRequest] = []
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.openPrivacySettings = { _ in Issue.record("Network attempts must not open Settings") }
    let profile = DesktopEnvironmentConfiguration.lan
    let service = DesktopPermissionChecklist(access: access, selectedProfile: { profile },
        activationNotificationCenter: NotificationCenter(), requestEndpoint: { request in
            requests.append(request)
            #expect(request.httpMethod == "HEAD" && request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            if request.url == profile.appURL { throw URLError(.cannotFindHost) }
            return HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        })
    let result = await service.adapter.setup(.localNetwork)
    #expect(requests.map(\.url) == [profile.appURL, profile.gatewayURL, profile.mcpURL])
    #expect(result.state == .failed && !result.verified)
    #expect(result.detail.contains("DNS") && result.detail.contains(profile.appURL.host!))
}

@Test @MainActor func localNetworkPermissionCancellationStopsLaterRequestsWithoutOpeningSettings() async {
    var pending: CheckedContinuation<HTTPURLResponse, Error>?
    var requests = 0
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.openPrivacySettings = { _ in Issue.record("Canceled setup must not open Settings") }
    let service = DesktopPermissionChecklist(access: access, selectedProfile: { .lan },
        activationNotificationCenter: NotificationCenter(), requestEndpoint: { _ in
            requests += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        })
    let task = Task { await service.adapter.setup(.localNetwork) }
    while pending == nil { await Task.yield() }
    task.cancel()
    pending?.resume(throwing: URLError(.cancelled))
    #expect(await task.value.state == .checking)
    #expect(requests == 1)
    #expect(await service.adapter.observe(.localNetwork).verified == false)
}

@Test @MainActor func localNetworkPermissionSessionWaitsForApprovalWithABoundedDeadline() {
    let session = DesktopPermissionChecklist.makeConnectionSession()
    defer { session.invalidateAndCancel() }
    #expect(session.configuration.waitsForConnectivity)
    #expect(session.configuration.timeoutIntervalForResource == 15)
    #expect(session.configuration.urlCache == nil)
    let normal = DesktopControlNetworkSession.makeWithoutRedirects()
    defer { normal.invalidateAndCancel() }
    #expect(normal.configuration.waitsForConnectivity == false)
}

@Test @MainActor func localNetworkPermissionDirectRedirectIsReachableButFollowedResponseCannotVerify() async {
    var followed = false
    var requests = 0
    let service = DesktopPermissionChecklist(access: .permissionFixture(), selectedProfile: { .lan }, activationNotificationCenter: NotificationCenter(),
        requestEndpoint: { request in
            requests += 1
            return HTTPURLResponse(url: followed ? URL(string: "https://unselected.example")! : request.url!.appendingPathComponent("/"),
                statusCode: followed ? 200 : 302, httpVersion: nil, headerFields: ["Location": "https://unselected.example"])!
        })
    #expect(await service.adapter.setup(.localNetwork).verified && requests == 3)
    followed = true
    #expect(await service.adapter.setup(.localNetwork).state == .failed)
    #expect(await service.adapter.observe(.localNetwork).state == .failed)
    service.cancelVerification()
    #expect(await service.adapter.observe(.localNetwork).state == .failed && requests == 6)
}

@Test @MainActor func localNetworkPermissionCanceledRefreshCannotOverwriteSuccessorOrCallNextEndpoint() async {
    var calls = 0
    var pending: CheckedContinuation<HTTPURLResponse, Error>?
    var oldURL: URL?
    let service = DesktopPermissionChecklist(access: .permissionFixture(), selectedProfile: { .lan }, activationNotificationCenter: NotificationCenter(),
        requestEndpoint: { request in
            calls += 1
            if calls == 4 {
                oldURL = request.url
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        })
    #expect(await service.adapter.setup(.localNetwork).verified)
    service.invalidateAfterActivation()
    let old = Task { await service.adapter.observe(.localNetwork) }
    while pending == nil { await Task.yield() }
    service.cancelVerification()
    #expect(await service.adapter.setup(.localNetwork).verified)
    pending?.resume(returning: HTTPURLResponse(url: oldURL!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
    #expect(await old.value.state == .checking)
    #expect(await service.adapter.observe(.localNetwork).verified)
    #expect(calls == 7)
}

@Test @MainActor func protectedAccessReadyRefreshRetriesDenialOnActivationOnly() async throws {
    let home = try protectedAccessFixture()
    let mail = home.appendingPathComponent("Library/Mail")
    defer { try? FileManager.default.removeItem(at: home) }
    var probes = 0
    let service = DesktopPermissionChecklist(access: .permissionFixture(), selectedProfile: { .production }, protectedAccessAction: { .check },
        verifyProtectedAccess: {
            probes += 1
            try await DesktopFileSystem().verifyProtectedDirectoryAccess(home: home)
        }, activationNotificationCenter: NotificationCenter())
    isolateReadyRows(service, [.fullDiskAccess])
    await openReadyChecklist(service)
    defer { service.window.cancel() }
    #expect(probes == 0)
    service.window.coordinator.setup(.fullDiskAccess)
    while service.window.coordinator.busyPermission != nil { await Task.yield() }
    #expect(readyRow(service, .fullDiskAccess)?.isComplete == true && probes == 1)
    service.window.completeSetup()
    await openReadyChecklist(service)
    #expect(readyRow(service, .fullDiskAccess)?.isComplete == true && probes == 2)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: mail.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mail.path) }
    service.invalidateAfterActivation()
    await service.window.coordinator.refresh()
    #expect(readyRow(service, .fullDiskAccess)?.state == .denied && probes == 3)
    service.invalidateAfterActivation()
    for _ in 0..<3 { await service.window.coordinator.refresh() }
    #expect(probes == 4)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mail.path)
    service.invalidateAfterActivation()
    await service.window.coordinator.refresh()
    #expect(readyRow(service, .fullDiskAccess)?.isComplete == true && probes == 5)
    for _ in 0..<3 { await service.window.coordinator.refresh() }
    #expect(probes == 5)
}

@Test @MainActor func microphonePermissionGrantedDuringSetupRetainsRecordingFailure() async {
    let page = ReadyVoicePage()
    page.result = .failure(DesktopVoicePermissionError.emptyRecording)
    var status = AVAuthorizationStatus.notDetermined
    var prompts = 0
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.microphone = { status }
    access.requestMicrophone = { prompts += 1; status = .authorized; return true }
    access.hasMicrophone = { true }
    access.microphoneIdentity = { "input" }
    let service = DesktopPermissionChecklist(access: access, selectedProfile: { .production },
        activationNotificationCenter: NotificationCenter(), voiceContext: {
            .init(identity: "document", url: DesktopEnvironmentConfiguration.production.appURL, page: page)
        })
    isolateReadyRows(service, [.microphone])
    await openReadyChecklist(service)
    defer { service.window.cancel() }
    #expect(readyRow(service, .microphone)?.state == .notGranted)
    service.window.coordinator.setup(.microphone)
    while service.window.coordinator.busyPermission != nil { await Task.yield() }
    for _ in 0..<3 { await service.window.coordinator.refresh() }
    #expect(readyRow(service, .microphone)?.state == .failed)
    #expect(readyRow(service, .microphone)?.observation.detail.contains("returned no audio data") == true)
    #expect(status == .authorized && prompts == 1 && page.tests == 1)
    status = .denied
    await service.window.coordinator.refresh()
    #expect(readyRow(service, .microphone)?.state == .denied)
    #expect(page.tests == 1)
}

@Test @MainActor func localNetworkPermissionOverlappingChecksShareOneOperationOwner() async {
    var pending: CheckedContinuation<Void, Never>?
    var requests = 0
    let service = DesktopPermissionChecklist(access: .permissionFixture(), selectedProfile: { .lan },
        activationNotificationCenter: NotificationCenter(), requestEndpoint: { request in
            requests += 1
            if requests == 1 { await withCheckedContinuation { pending = $0 } }
            return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        })
    let first = Task { await service.adapter.setup(.localNetwork) }
    while pending == nil { await Task.yield() }
    #expect(await service.adapter.setup(.localNetwork).state == .checking && requests == 1)
    pending?.resume()
    #expect(await first.value.verified && requests == 3)
    #expect(await service.adapter.observe(.localNetwork).verified)
}

@Test @MainActor func microphoneAuthorizedResourceLossDoesNotRearmAutomaticRecording() async {
    var status = AVAuthorizationStatus.authorized
    var inputAvailable = true
    var documentAvailable = true
    let page = ReadyVoicePage()
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.microphone = { status }
    access.hasMicrophone = { inputAvailable }
    access.microphoneIdentity = { "input" }
    let service = DesktopPermissionChecklist(access: access, selectedProfile: { .production },
        activationNotificationCenter: NotificationCenter(), voiceContext: {
            documentAvailable ? .init(identity: "document", url: DesktopEnvironmentConfiguration.production.appURL, page: page) : nil
        })
    isolateReadyRows(service, [.microphone])
    await openReadyChecklist(service)
    defer { service.window.cancel() }
    service.window.coordinator.setup(.microphone)
    while service.window.coordinator.busyPermission != nil { await Task.yield() }
    #expect(page.tests == 1 && readyRow(service, .microphone)?.isComplete == true)
    inputAvailable = false
    await service.window.coordinator.refresh()
    inputAvailable = true
    await service.window.coordinator.refresh()
    #expect(page.tests == 1 && readyRow(service, .microphone)?.state == .verificationRequired)
    documentAvailable = false
    await service.window.coordinator.refresh()
    documentAvailable = true
    await service.window.coordinator.refresh()
    #expect(page.tests == 1 && readyRow(service, .microphone)?.state == .verificationRequired)
    status = .denied
    await service.window.coordinator.refresh()
    status = .authorized
    await service.window.coordinator.refresh()
    #expect(page.tests == 2 && readyRow(service, .microphone)?.isComplete == true)
}
