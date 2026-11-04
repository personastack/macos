import Foundation
import PersonaStackCore
import Testing

private let handoffReference = String(repeating: "A", count: 43)

@Test func iMessageSetupHandoffAcceptsOnlyTheCanonicalLinkAndReference() throws {
    let url = try #require(URL(string: IMessageSetupHandoff.deepLinkPrefix + handoffReference))
    let handoff = try IMessageSetupHandoff.parseDeepLink(url)
    #expect(handoff.setupReference == handoffReference)
    let bytes = Data(repeating: 0xff, count: 32)
    let alternate = bytes.base64EncodedString().replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    #expect(try IMessageSetupHandoff(setupReference: alternate).setupReference == alternate)
}

@Test(arguments: ["", String(repeating: "A", count: 42), String(repeating: "A", count: 44),
                  String(repeating: "A", count: 42) + "B", String(repeating: "A", count: 42) + "=",
                  String(repeating: "+", count: 43), String(repeating: "é", count: 43),
                  " " + String(repeating: "A", count: 42)])
func iMessageSetupHandoffRejectsNoncanonicalReferences(_ reference: String) {
    #expect(throws: IMessageSetupHandoffError.invalidRequest) { try IMessageSetupHandoff(setupReference: reference) }
}

@Test(arguments: [
    "https://connect-imessage?setup_reference=", "personastack://other?setup_reference=",
    "personastack://connect-imessage/?setup_reference=", "personastack://connect-imessage:443?setup_reference=",
    "personastack://user@connect-imessage?setup_reference=", "personastack://connect-imessage?reference=",
    "personastack://connect-imessage?setup_reference=%41", "personastack://connect-imessage?setup_reference="
])
func iMessageSetupHandoffRejectsOtherLinkShapes(_ prefix: String) throws {
    // The last case supplies an otherwise canonical reference with a fragment.
    let suffix = prefix == IMessageSetupHandoff.deepLinkPrefix ? "#ignored" : ""
    let url = try #require(URL(string: prefix + handoffReference + suffix))
    #expect(throws: IMessageSetupHandoffError.invalidRequest) { try IMessageSetupHandoff.parseDeepLink(url) }
}

@Test(arguments: ["&setup_reference=", "&server=https://example.test", "&gateway_url=wss://example.test",
                  "&token=untrusted", "&redirect=/settings", "&workspace_id=other", "&action=send", "&"])
func iMessageSetupHandoffRejectsExtraLinkAuthority(_ suffix: String) throws {
    let url = try #require(URL(string: IMessageSetupHandoff.deepLinkPrefix + handoffReference + suffix))
    #expect(throws: IMessageSetupHandoffError.invalidRequest) { try IMessageSetupHandoff.parseDeepLink(url) }
}

@Test func iMessageSetupHandoffPageCanOnlyRequestBegin() throws {
    let valid: [String: Any] = ["version": "1", "action": "begin", "setup_reference": handoffReference]
    #expect(try IMessageSetupHandoff.parsePageCommand(valid).setupReference == handoffReference)
    for field in ["natural_user_id", "workspace_id", "installation_id", "generation", "server", "gateway_url",
                  "credential", "consent", "read_enabled", "send_enabled", "snapshot", "path", "command"] {
        var altered = valid
        altered[field] = "untrusted"
        #expect(throws: IMessageSetupHandoffError.invalidRequest) { try IMessageSetupHandoff.parsePageCommand(altered) }
    }
    for action in ["approve", "send", "read", "disconnect", "resume", "", "Begin"] {
        var altered = valid
        altered["action"] = action
        #expect(throws: IMessageSetupHandoffError.invalidRequest) { try IMessageSetupHandoff.parsePageCommand(altered) }
    }
    for field in valid.keys {
        var missing = valid
        missing.removeValue(forKey: field)
        #expect(throws: IMessageSetupHandoffError.invalidRequest) { try IMessageSetupHandoff.parsePageCommand(missing) }
        var null = valid
        null[field] = NSNull()
        #expect(throws: IMessageSetupHandoffError.invalidRequest) { try IMessageSetupHandoff.parsePageCommand(null) }
    }
    var numericVersion = valid
    numericVersion["version"] = 1
    #expect(throws: IMessageSetupHandoffError.invalidRequest) { try IMessageSetupHandoff.parsePageCommand(numericVersion) }
    #expect(throws: IMessageSetupHandoffError.invalidRequest) { try IMessageSetupHandoff.parsePageCommand([]) }
}

@Test func iMessageSetupHandoffDescriptionsRedactTheReference() throws {
    let handoff = try IMessageSetupHandoff(setupReference: handoffReference)
    #expect(!String(describing: handoff).contains(handoffReference))
    #expect(!String(reflecting: handoff).contains(handoffReference))
    #expect(!String(describing: handoff.customMirror.children.map(\.value)).contains(handoffReference))
}
