import Foundation
import Testing
@testable import PersonaStackCore

@Test func iMessageRowIDsUseCanonicalDecimalStringsWithoutPrecisionLoss() throws {
    for value in [Int64(0), 9_007_199_254_740_993, Int64.max] {
        let position = try IMessageRowID(value)
        let bytes = try JSONEncoder().encode(position)
        #expect(String(decoding: bytes, as: UTF8.self) == "\"\(value)\"")
        #expect(try JSONDecoder().decode(IMessageRowID.self, from: bytes).value == value)
    }
    for invalid in ["-1", "+1", "01", " 1", "1.0", "9223372036854775808", ""] {
        #expect(throws: IMessageRPCError.invalidArguments) { try IMessageRowID(decimal: invalid) }
    }
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(IMessageRowID.self, from: Data("9007199254740993".utf8))
    }
}

@Test func iMessageEnvelopesRejectUnknownFieldsNotificationsAndAmbiguousResults() throws {
    let invalid = [
        #"{"jsonrpc":"2.0","id":"1","result":{},"unexpected":true}"#,
        #"{"jsonrpc":"2.0","id":"1","result":{},"error":{"code":-1}}"#,
        #"{"jsonrpc":"2.0","method":"message","params":{}}"#,
        #"{"jsonrpc":"1.0","id":"1","result":{}}"#,
        #"{"jsonrpc":"2.0","id":1,"result":{}}"#,
        #"{"jsonrpc":"2.0","id":"1"}"#,
    ]
    for raw in invalid {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(IMessageRPCIdentity.self, from: Data(raw.utf8))
        }
    }
    let valid = try JSONDecoder().decode(IMessageRPCIdentity.self,
        from: Data(#"{"jsonrpc":"2.0","id":"1","result":{}}"#.utf8))
    #expect(valid.id == "1")
}

@Test func iMessageUnavailableCheckpointChatHasAnExplicitTypedResult() throws {
    let raw = #"{"adapter_revision":2,"source_high_water":"9007199254740993","chats":[{"chat_id":"42","guid":"","service":"","available":false,"tail_rowid":"0","tail_guid":""}],"observed_at":"2026-11-04T00:00:00Z"}"#
    let result = try JSONDecoder().decode(IMessageSourceCheckpoint.self, from: Data(raw.utf8))
    #expect(result.sourceHighWater.value == 9_007_199_254_740_993)
    #expect(result.chats.first?.available == false)
    #expect(result.chats.first?.anchorMatches == nil)
}
