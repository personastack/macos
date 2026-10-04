import Foundation
import Testing
@testable import PersonaStackCore

struct DesktopPermissionReceiptTests {
    private let context = DesktopPermissionReceipt.Context(hostIdentity: "signed-fixture", osVersion: "fixture-os", driverIdentity: "fixture-driver")

    @Test func historicalProofNeverOverridesKnownDenialOrIdentityChange() throws {
        let receipt = DesktopPermissionReceipt(context: context, observations: [.localNetwork: .init(.ready, detail: "", verified: true)], now: Date(timeIntervalSince1970: 1))
        let decoded = try JSONDecoder().decode(DesktopPermissionReceipt.self, from: JSONEncoder().encode(receipt))
        #expect(decoded == receipt)
        let unresolved = DesktopPermissionObservation(.verificationRequired, detail: "No passive status")
        #expect(receipt.restoring(.localNetwork, current: unresolved, context: context).state == .ready)
        for state in [DesktopPermissionState.denied, .notGranted, .failed, .unsupported, .restartRequired] {
            let current = DesktopPermissionObservation(state, detail: "Current evidence")
            #expect(receipt.restoring(.localNetwork, current: current, context: context) == current)
        }
        let other = DesktopPermissionReceipt.Context(hostIdentity: "another-signer", osVersion: context.osVersion, driverIdentity: context.driverIdentity)
        #expect(receipt.restoring(.localNetwork, current: unresolved, context: other) == unresolved)
        #expect(receipt.restoring(.accessibility, current: unresolved, context: context) == unresolved)
    }

    @Test func safariProofRequiresTheSameObservedBrowserKey() {
        let receipt = DesktopPermissionReceipt(context: context, observations: [.safariJavaScript: .init(.ready, detail: "", verificationKey: "browser-generation", verified: true)], now: .distantPast)
        let same = DesktopPermissionObservation(.verificationRequired, detail: "", verificationKey: "browser-generation")
        let changed = DesktopPermissionObservation(.verificationRequired, detail: "", verificationKey: "new-browser-generation")
        #expect(receipt.restoring(.safariJavaScript, current: same, context: context).state == .ready)
        #expect(receipt.restoring(.safariJavaScript, current: changed, context: context) == changed)
    }

    @Test func observedDenialCannotResurrectHistoricalProof() {
        var receipt = DesktopPermissionReceipt(context: context, observations: [
            .localNetwork: .init(.ready, detail: "", verified: true),
            .fullDiskAccess: .init(.ready, detail: "", verified: true),
        ], now: .distantPast)
        receipt.invalidate(.localNetwork)
        let unknown = DesktopPermissionObservation(.verificationRequired, detail: "")
        #expect(receipt.restoring(.localNetwork, current: unknown, context: context) == unknown)
        #expect(receipt.restoring(.fullDiskAccess, current: unknown, context: context).state == .ready)
    }
    @Test func perceptionProofRequiresTheSameCapabilityKey() throws {
        let receipt = DesktopPermissionReceipt(context: context, observations: [
            .visualPerception: .init(.ready, detail: "", verificationKey: "qualified-model", verified: true),
        ], now: .distantPast)
        let same = DesktopPermissionObservation(.verificationRequired, detail: "", verificationKey: "qualified-model")
        #expect(receipt.restoring(.visualPerception, current: same, context: context).state == .ready)
        for key in [String?.none, "changed-model"] {
            let changed = DesktopPermissionObservation(.verificationRequired, detail: "", verificationKey: key)
            #expect(receipt.restoring(.visualPerception, current: changed, context: context) == changed)
        }
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        object.removeValue(forKey: "visualPerceptionVerificationKey")
        let old = try JSONDecoder().decode(DesktopPermissionReceipt.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.restoring(.visualPerception, current: same, context: context) == same)
    }

}
