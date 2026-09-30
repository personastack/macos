import Foundation
import Testing
import UserNotifications
@testable import PersonaStack

@Test @MainActor func desktopNotificationPermissionRequiresExactDeliveredTestAndBoundsRetry() async throws {
    let content = UNMutableNotificationContent()
    content.title = "PersonaStack"
    let request = UNNotificationRequest(identifier: "permission-test", content: content, trigger: nil)
    var submits = 0
    var reads = 0
    var waits = 0
    let delivered = try await DesktopNotificationCoordinator.probePermissionDelivery(
        request: request,
        submit: { submitted in
            #expect(submitted.identifier == "permission-test" && submitted.content.title == "PersonaStack")
            #expect(submitted.trigger == nil)
            submits += 1
        },
        deliveredIDs: { reads += 1; return reads == 2 ? ["permission-test"] : ["another-app-notification"] },
        wait: { waits += 1 }
    )
    #expect(delivered && submits == 1 && reads == 2 && waits == 1)
    reads = 0
    waits = 0
    let missing = try await DesktopNotificationCoordinator.probePermissionDelivery(
        request: request, submit: { _ in }, deliveredIDs: { reads += 1; return [] }, wait: { waits += 1 }
    )
    #expect(!missing && reads == 10 && waits == 10)
}

@Test @MainActor func desktopNotificationPermissionStopsAfterSubmissionFailure() async {
    let request = UNNotificationRequest(identifier: "permission-test", content: UNMutableNotificationContent(), trigger: nil)
    var reads = 0
    do {
        _ = try await DesktopNotificationCoordinator.probePermissionDelivery(
            request: request, submit: { _ in throw CancellationError() },
            deliveredIDs: { reads += 1; return [] }, wait: {}
        )
        Issue.record("A failed submission must fail verification.")
    } catch { #expect(error is CancellationError && reads == 0) }
}
