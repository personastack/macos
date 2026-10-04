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
            }, requestLocalNetwork: { .init(.ready, detail: "Fixture discovery", verified: true) }, requestEndpoint: { request in
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

@Test @MainActor func permissionPresentationNeverRunsCaptureDiskNetworkOrAudioChecks() async {
    let fixture = PresentationFixture()
    fixture.open()
    defer { fixture.close() }
    await fixture.settle()
    #expect(fixture.row(.accessibility)?.isComplete == true)
    #expect(fixture.row(.screenRecording)?.isComplete == true)
    #expect(fixture.row(.fullDiskAccess)?.state == .verificationRequired)
    #expect(fixture.row(.localNetwork)?.state == .verificationRequired)
    #expect(fixture.diskChecks == 0 && fixture.voice.recordings == 0 && fixture.grantRequests.isEmpty)
    #expect(fixture.requests.isEmpty)
    for _ in 0..<3 { await fixture.service.window.coordinator.refresh() }
    fixture.service.window.coordinator.startPresentationVerification()
    #expect(fixture.diskChecks == 0 && fixture.voice.recordings == 0 && fixture.requests.isEmpty)
    fixture.close()
    fixture.document = "document-b"
    fixture.open()
    await fixture.settle()
    #expect(fixture.voice.recordings == 0 && fixture.diskChecks == 0 && fixture.requests.isEmpty)
}

@Test @MainActor func permissionPresentationDenialAndGrantChangesRemainPassive() async {
    let fixture = PresentationFixture()
    fixture.granted = false
    fixture.open()
    defer { fixture.close() }
    await fixture.settle()
    #expect(fixture.row(.accessibility)?.state == .notGranted)
    #expect(fixture.row(.screenRecording)?.state == .notGranted)
    fixture.granted = true
    await fixture.service.window.coordinator.resumeAfterActivation()
    #expect(fixture.row(.accessibility)?.state == .ready)
    #expect(fixture.row(.screenRecording)?.state == .ready)
    #expect(fixture.diskChecks == 0 && fixture.voice.recordings == 0 && fixture.requests.isEmpty)
    #expect(fixture.grantRequests.isEmpty)
    #expect(!fixture.service.window.coordinator.canFinish)
}

@Test @MainActor func permissionPresentationDoesNotInterruptAnActiveVoiceRecording() async {
    let fixture = PresentationFixture()
    fixture.voice.busy = true
    fixture.open()
    defer { fixture.close() }
    await fixture.settle()
    #expect(fixture.voice.recordings == 0 && fixture.voice.cancels == 0)
    #expect(!fixture.service.window.coordinator.permissionRows.contains { $0.id == .microphone })
}
