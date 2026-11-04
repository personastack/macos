import Foundation
import Testing
import PersonaStackCore

@Test func iMessageJSONDocumentKeepsExactIntegerTokensAndIgnoresGatewayNegotiationInHTTPMode() throws {
    try IMessageJSONDocument.validate(data: Data(#"{"generation":9223372036854775807,"nested":{"selected":true},"rows":[],"type":"imessage","imessage_protocol_version":"HTTP metadata"}"#.utf8), maximumBytes: 4096)
}

@Test(arguments: [
    #"{"generation":1,"generation":2}"#,
    #"{"generation":1,"\u0067eneration":2}"#,
    #"{"value":"\uD800"}"#,
    #"{"value":"\uDC00"}"#,
    #"{"value":"\uGGGG"}"#,
    #"{"nested":{"value":1,"value":2}}"#,
    #"{"value":null}"#,
    #"{"value":[null]}"#,
    #"{"generation":1.0}"#,
    #"{"generation":1e0}"#,
    #"{"generation":9223372036854775808}"#,
    #"{"generation":1}{}"#,
    String(repeating: "[", count: 34) + "0" + String(repeating: "]", count: 34),
]) func iMessageJSONDocumentRejectsAmbiguousOrUnboundedHTTPDocuments(raw: String) {
    #expect(throws: (any Error).self) { try IMessageJSONDocument.validate(data: Data(raw.utf8), maximumBytes: 4096) }
}

@Test func iMessageJSONDocumentHonorsCallerByteLimitAndDoesNotBroadenLegacyFrameStrictness() throws {
    for limit in [0, -1, 4] {
        #expect(throws: (any Error).self) { try IMessageJSONDocument.validate(data: Data(#"{"value":1}"#.utf8), maximumBytes: limit) }
    }
    #expect(throws: (any Error).self) { try IMessageJSONDocument.validate(data: Data([0xff]), maximumBytes: 4096) }
    let legacy = Data(#"{"version":1,"type":"result","request_id":"legacy","result":{"progress":1.5,"optional":null}}"#.utf8)
    #expect(try DesktopControlFrameCodec.decode(legacy).type == "result")
    #expect(throws: (any Error).self) { try IMessageJSONDocument.validate(data: legacy, maximumBytes: 4096) }
    let duplicateLegacy = Data(#"{"version":1,"type":"heartbeat","readiness":"unknown","readiness":"ready"}"#.utf8)
    #expect(try DesktopControlFrameCodec.decode(duplicateLegacy).type == "heartbeat")
}
