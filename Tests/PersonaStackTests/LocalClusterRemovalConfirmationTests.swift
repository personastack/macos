import AppKit
import Testing
@testable import PersonaStack

@MainActor
@Suite struct LocalClusterRemovalConfirmationTests {
    @Test(arguments: [nil, NSAlert.Style.warning])
    func cancelIsTheOnlyReturnAction(alertStyle: NSAlert.Style?) throws {
        let alert = LocalClusterRemovalConfirmation.makeAlert(
            messageText: "Remove local data?", informativeText: "This cannot be undone.", alertStyle: alertStyle)

        #expect(alert.buttons.map(\.title) == ["Remove Local Data", "Cancel"])
        let remove = try #require(alert.buttons.first)
        let cancel = try #require(alert.buttons.last)
        #expect(remove.keyEquivalent.isEmpty)
        #expect(cancel.keyEquivalent == "\r")
        #expect(alert.buttons.filter { $0.keyEquivalent == "\r" }.count == 1)
    }

    @Test(arguments: [nil, NSAlert.Style.warning])
    func preservesCallerCopyAndStyle(alertStyle: NSAlert.Style?) {
        let message = "Remove local data?"
        let details = "This removes this Mac's files. Cloud retirement is separate."
        let alert = LocalClusterRemovalConfirmation.makeAlert(
            messageText: message, informativeText: details, alertStyle: alertStyle)

        #expect(alert.messageText == message)
        #expect(alert.informativeText == details)
        #expect(alert.alertStyle == (alertStyle ?? NSAlert().alertStyle))
    }
}
