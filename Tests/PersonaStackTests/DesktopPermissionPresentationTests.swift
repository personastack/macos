import AVFoundation
import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

@MainActor
private final class PresentationVoice: DesktopVoicePermissionPage {
    var recordings = 0
    var busy = false
    var pending: ((Result<Bool, Error>) -> Void)?
    var hold = false
    var cancels = 0
    func test(id: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        if busy { completion(.failure(DesktopVoicePermissionError.busy)); return }
        recordings += 1
        if hold { pending = completion } else { completion(.success(true)) }
    }
    func cancel(id: String) { cancels += 1 }
}

@MainActor
private final class PresentationFixture {
    let voice = PresentationVoice()
    var granted = true
    var accessibilityGranted: Bool?
    var grantRequests: [DesktopPermissionID] = []
    var document = "document-a"
    var diskChecks = 0
    var requests: [URL] = []
    var denyDisk = false
    var denyNetwork = false
    lazy var service = makeService()

    private func makeService() -> DesktopPermissionChecklist {
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.accessibility = { self.accessibilityGranted ?? self.granted }
        access.screenRecording = { self.granted }
        access.microphone = { self.granted ? .authorized : .notDetermined }
        access.microphoneIdentity = { "input" }
        access.hasMicrophone = { true }
        access.requestAccessibility = { self.grantRequests.append(.accessibility) }
        access.requestScreenRecording = { self.grantRequests.append(.screenRecording); return self.granted }
        access.requestMicrophone = { self.grantRequests.append(.microphone); return self.granted }
        let service = DesktopPermissionChecklist(access: access,
            selectedProfile: { .lan }, protectedAccessAction: { Issue.record("Automatic check opened consent"); return .cancel },
            verifyProtectedAccess: {
                self.diskChecks += 1
                if self.denyDisk { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
            }, activationNotificationCenter: NotificationCenter(), voiceContext: {
                .init(identity: self.document, url: DesktopEnvironmentConfiguration.lan.appURL, page: self.voice)
            }, requestEndpoint: { request in
                #expect(request.httpMethod == "HEAD" && request.httpBody == nil)
                #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                self.requests.append(request.url!)
                if self.denyNetwork { throw URLError(.notConnectedToInternet) }
                return HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
            }, windowFactory: { coordinator in
                let verifier = DesktopLockedControlSetupVerifier(operations: .init(inspect: { .ready }))
                return DesktopPermissionChecklistWindow(coordinator: coordinator, lockedControlVerifier: verifier,
                    authorizeFullControl: { _ in true })
            })
        let hooks = service.adapter.hooks
        service.adapter.hooks = .init(observe: { id in
            if DesktopPermissionID.setupPermissions.contains(id) { return await hooks.observe(id) }
            return .init(.notNeeded, detail: "Unrelated fixture row")
        }, setup: hooks.setup, verifyAutomatically: hooks.verifyAutomatically)
        return service
    }

    func open() {
        service.window.onPresent?()
        service.window.coordinator.open()
        service.window.coordinator.startPresentationVerification()
    }
    func settle() async {
        while service.window.coordinator.verificationBusyPermission != nil { await Task.yield() }
        await service.window.coordinator.refresh()
    }
    func close() { service.window.cancel() }
    func row(_ id: DesktopPermissionID) -> DesktopPermissionRow? { service.window.coordinator.rows.first { $0.id == id } }
}

@Test @MainActor func permissionPresentationColdServiceChecksEveryVisibleRowWithoutSetupClicks() async {
    let fixture = PresentationFixture()
    fixture.open()
    defer { fixture.close() }
    await fixture.settle()
    #expect(fixture.service.window.coordinator.permissionRows.filter { ![.directCapture, .automation, .safariJavaScript, .clipboard].contains($0.id) }.allSatisfy { $0.isComplete })
    #expect(fixture.diskChecks == 1 && fixture.voice.recordings == 1 && fixture.grantRequests.isEmpty)
    #expect(fixture.requests == [DesktopEnvironmentConfiguration.lan.appURL, DesktopEnvironmentConfiguration.lan.gatewayURL, DesktopEnvironmentConfiguration.lan.mcpURL])
    for _ in 0..<3 { await fixture.service.window.coordinator.refresh() }
    fixture.service.window.coordinator.startPresentationVerification()
    #expect(fixture.diskChecks == 1 && fixture.voice.recordings == 1 && fixture.requests.count == 3)
    fixture.close()
    fixture.document = "document-b"
    fixture.open()
    await fixture.settle()
    #expect(fixture.service.window.coordinator.permissionRows.filter { ![.directCapture, .automation, .safariJavaScript, .clipboard].contains($0.id) }.allSatisfy { $0.isComplete })
    #expect(fixture.voice.recordings == 2 && fixture.diskChecks == 2 && fixture.requests.count == 6)
}

@Test @MainActor func permissionPresentationDeniedGrantsDoNotPromptButDiskAndNetworkStillCheck() async {
    let fixture = PresentationFixture()
    fixture.granted = false
    fixture.denyDisk = true
    fixture.denyNetwork = true
    fixture.open()
    defer { fixture.close() }
    await fixture.settle()
    #expect(fixture.row(.accessibility)?.state == .notGranted)
    #expect(fixture.row(.screenRecording)?.state == .notGranted)
    #expect(fixture.row(.microphone)?.state == .notGranted)
    #expect(fixture.row(.fullDiskAccess)?.state == .denied)
    #expect(fixture.row(.localNetwork)?.state == .failed)
    #expect(fixture.voice.recordings == 0 && fixture.grantRequests.isEmpty)
    #expect(fixture.diskChecks == 1 && fixture.requests.count == 3)
    fixture.close()
    fixture.granted = true
    fixture.denyDisk = false
    fixture.denyNetwork = false
    fixture.open()
    await fixture.settle()
    #expect(fixture.service.window.coordinator.permissionRows.filter { ![.directCapture, .automation, .safariJavaScript, .clipboard].contains($0.id) }.allSatisfy { $0.isComplete })
}

@Test @MainActor func permissionPresentationActiveVoiceIsNotInterruptedAndFinishCancelsPendingChecks() async {
    let fixture = PresentationFixture()
    fixture.voice.busy = true
    fixture.open()
    await fixture.settle()
    #expect(fixture.row(.microphone)?.state == .verificationRequired)
    #expect(fixture.voice.recordings == 0 && fixture.service.window.coordinator.canFinish)
    fixture.close()
    fixture.voice.busy = false
    fixture.voice.hold = true
    fixture.open()
    defer { fixture.close() }
    while fixture.voice.pending == nil { await Task.yield() }
    #expect(fixture.service.window.coordinator.canFinish)
    let requests = fixture.requests.count
    await fixture.service.window.finish()
    fixture.voice.pending?(.success(true))
    for _ in 0..<10 { await Task.yield() }
    #expect(fixture.requests.count == requests)
    #expect(fixture.service.window.coordinator.verificationBusyPermission == nil)
}

@Test @MainActor func permissionPresentationScreenGrantIsReadyWithoutAccessibilityOrRuntime() async {
    let fixture = PresentationFixture()
    fixture.accessibilityGranted = false
    fixture.voice.hold = true
    fixture.open()
    defer { fixture.close() }
    while fixture.voice.pending == nil { await Task.yield() }
    #expect(fixture.row(.accessibility)?.state == .notGranted)
    #expect(fixture.row(.screenRecording)?.isComplete == true)
    #expect(!fixture.service.window.coordinator.canFinish)
    fixture.accessibilityGranted = true
    fixture.service.window.coordinator.setup(.accessibility)
    while fixture.service.window.coordinator.busyPermission != nil { await Task.yield() }
    #expect(fixture.row(.accessibility)?.isComplete == true)
    #expect(fixture.row(.screenRecording)?.isComplete == true)
    #expect(fixture.service.window.coordinator.canFinish)
    #expect(fixture.grantRequests.isEmpty)
    fixture.voice.pending?(.success(true))
    await fixture.settle()
    #expect(fixture.diskChecks == 1 && fixture.voice.recordings == 1 && fixture.requests.count == 3)
}
