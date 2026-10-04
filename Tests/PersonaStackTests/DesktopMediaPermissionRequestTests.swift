import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

@Suite @MainActor
struct DesktopMediaPermissionRequestTests {
    @Test func firstAudioActionCoalescesAuthorizationAndReusesTheGrant() {
        var authorization = DesktopMicrophoneAuthorization.notDetermined
        var prompts = 0
        var resolve: (@MainActor (Bool) -> Void)?
        let permission = DesktopMediaCapturePermission(authorization: { authorization }, requestAuthorization: {
            prompts += 1; resolve = $0
        }, openSettings: { Issue.record("Unexpected Settings") })
        var replies: [Bool] = []
        for _ in 0..<2 {
            permission.request(owner: UUID(), id: UUID(), trusted: true, isCurrent: { true }) { replies.append($0) }
        }
        #expect(prompts == 1 && replies.isEmpty)
        authorization = .authorized
        resolve?(true)
        #expect(replies == [true, true])
        permission.request(owner: UUID(), id: UUID(), trusted: true, isCurrent: { true }) { replies.append($0) }
        #expect(prompts == 1 && replies == [true, true, true])
        resolve?(true)
        #expect(replies.count == 3)
    }

    @Test func cancellationAndNavigationSettleOnceWithoutDenyingAnotherChat() {
        var authorization = DesktopMicrophoneAuthorization.notDetermined
        var resolve: (@MainActor (Bool) -> Void)?
        var prompts = 0
        let permission = DesktopMediaCapturePermission(authorization: { authorization }, requestAuthorization: {
            prompts += 1; resolve = $0
        })
        let owner = UUID(), cancelled = UUID(), sibling = UUID()
        var first: [Bool] = [], second: [Bool] = [], stale: [Bool] = []
        var current = true
        permission.request(owner: owner, id: cancelled, trusted: true, isCurrent: { true }) { first.append($0) }
        permission.request(owner: owner, id: sibling, trusted: true, isCurrent: { true }) { second.append($0) }
        permission.request(owner: UUID(), id: UUID(), trusted: true, isCurrent: { current }) { stale.append($0) }
        permission.cancel(owner: owner, id: cancelled)
        permission.cancel(owner: owner, id: cancelled)
        current = false
        authorization = .authorized
        resolve?(true)
        #expect(prompts == 1 && first == [false] && second == [true] && stale == [false])
    }

    @Test func retiredDocumentCannotGrantAndFreshRequestJoinsTheExistingPrompt() {
        var authorization = DesktopMicrophoneAuthorization.notDetermined
        var resolve: (@MainActor (Bool) -> Void)?
        var prompts = 0
        let permission = DesktopMediaCapturePermission(authorization: { authorization }, requestAuthorization: {
            prompts += 1; resolve = $0
        })
        let old = UUID()
        var replies: [Bool] = []
        permission.request(owner: old, id: UUID(), trusted: true, isCurrent: { true }) { replies.append($0) }
        permission.cancel(owner: old)
        permission.request(owner: UUID(), id: UUID(), trusted: true, isCurrent: { true }) { replies.append($0) }
        #expect(prompts == 1 && replies == [false])
        authorization = .authorized
        resolve?(true)
        #expect(replies == [false, true])
    }

    @Test func deniedRestrictedForeignAndStaleRequestsNeverPrompt() {
        for authorization in [DesktopMicrophoneAuthorization.denied, .restricted, .authorized, .notDetermined] {
            let permission = DesktopMediaCapturePermission(authorization: { authorization }, requestAuthorization: { _ in
                Issue.record("Rejected request prompted")
            })
            for (trusted, current) in [(false, true), (true, false)] {
                var reply: Bool?
                permission.request(owner: UUID(), id: UUID(), trusted: trusted, isCurrent: { current }) { reply = $0 }
                #expect(reply == false)
            }
            if authorization == .denied || authorization == .restricted {
                var reply: Bool?
                permission.request(owner: UUID(), id: UUID(), trusted: true, isCurrent: { true }) { reply = $0 }
                #expect(reply == false)
            }
        }
    }

    @Test func mainCoordinatorRetirementCancelsBeforeTheOSPromptReturns() {
        var reply: Bool?
        var resolve: (@MainActor (Bool) -> Void)?
        let permission = DesktopMediaCapturePermission(authorization: { .notDetermined }, requestAuthorization: { resolve = $0 })
        let coordinator = PersonaStackWebView.Coordinator(appURL: URL(string: "https://my.personastack.ai")!,
            notificationCoordinator: nil, cancelPermissionVerification: {}, mediaPermission: permission)
        let owner = coordinator.documentGeneration
        permission.request(owner: owner, id: UUID(), trusted: true, isCurrent: { true }) { reply = $0 }
        coordinator.retire()
        #expect(reply == false && coordinator.documentGeneration != owner)
        resolve?(true)
        #expect(reply == false)
    }

    @Test func fixedBridgeRejectsForeignAndMalformedCommandsAndNeverRecords() {
        var settings = 0
        var prompts = 0
        let permission = DesktopMediaCapturePermission(authorization: { .denied }, requestAuthorization: { _ in prompts += 1 },
                                                       openSettings: { settings += 1 })
        let owner = UUID()
        for body: [String: Any] in [
            ["operation": "authorize"], ["operation": "authorize", "request_id": "invalid"],
            ["operation": "settings", "url": "https://foreign.example"], ["operation": "record"],
        ] {
            permission.handleMessage(body, owner: owner, trusted: true, isCurrent: { true }) { value, error in
                #expect(value == nil && error != nil)
            }
        }
        permission.handleMessage(["operation": "settings"], owner: owner, trusted: false, isCurrent: { true }) { _, error in
            #expect(error != nil)
        }
        permission.handleMessage(["operation": "settings"], owner: owner, trusted: true, isCurrent: { true }) { value, error in
            #expect((value as? [String: Bool]) == ["ok": true] && error == nil)
        }
        permission.handleMessage(["operation": "authorize", "request_id": UUID().uuidString],
                                 owner: owner, trusted: true, isCurrent: { true }) { value, error in
            #expect((value as? [String: Bool]) == ["authorized": false] && error == nil)
        }
        #expect(settings == 1 && prompts == 0)
    }
}
