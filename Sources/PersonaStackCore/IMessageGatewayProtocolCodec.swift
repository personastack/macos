import Foundation

/// Strict keys derive from each finite DTO's CodingKeys. No untyped payload is
/// retained, forwarded, or used for revisions or source cursors.
internal func gatewayContainer<K: CodingKey & CaseIterable & Hashable>(
    _ decoder: Decoder, _ keys: K.Type, optional: Set<K> = []
) throws -> KeyedDecodingContainer<K> {
    let all = try decoder.container(keyedBy: IMessageGatewayAnyKey.self)
    let seen = Set(all.allKeys.map(\.stringValue))
    let allowed = Set(K.allCases.map(\.stringValue))
    let required = allowed.subtracting(optional.map(\.stringValue))
    guard seen.isSubset(of: allowed), required.isSubset(of: seen) else { throw IMessageGatewayWireError.invalidFrame }
    for key in all.allKeys {
        guard try !all.decodeNil(forKey: key) else { throw IMessageGatewayWireError.invalidFrame }
    }
    return try decoder.container(keyedBy: keys)
}

private struct IMessageGatewayAnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// A bounded lexical check for the iMessage branch only. It remembers duplicate
/// keys and non-integer tokens without decoding a dynamic JSON object or Double.
/// Legacy frames retain their existing optional/null/duplicate decoding behavior.
internal struct IMessageGatewayJSONInspection {
    private let bytes: [UInt8]
    private var index = 0
    private var selected = false
    private var duplicate = false
    private var null = false
    private var nonInteger = false
    private var excessiveDepth = false
    private var negotiationSeen = false
    private var invalidNegotiation = false

    init(_ data: Data) throws {
        guard data.count <= DesktopControlFrameCodec.maximumFrameBytes else { throw IMessageGatewayWireError.frameTooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw IMessageGatewayWireError.invalidFrame }
        bytes = Array(data)
    }

    mutating func inspect() throws -> Bool {
        try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw IMessageGatewayWireError.invalidFrame }
        guard !invalidNegotiation else { throw IMessageGatewayWireError.invalidFrame }
        if selected && (duplicate || null || nonInteger || excessiveDepth) { throw IMessageGatewayWireError.invalidFrame }
        return selected
    }

    private mutating func value(depth: Int) throws {
        guard depth <= 512 else { throw IMessageGatewayWireError.invalidFrame }
        excessiveDepth = excessiveDepth || depth > 32
        whitespace()
        guard index < bytes.count else { throw IMessageGatewayWireError.invalidFrame }
        switch bytes[index] {
        case 0x7b: try object(depth: depth)
        case 0x5b: try array(depth: depth)
        case 0x22: _ = try string(decode: false)
        case 0x74: try literal("true")
        case 0x66: try literal("false")
        case 0x6e: null = true; try literal("null")
        case 0x2d, 0x30...0x39: try number()
        default: throw IMessageGatewayWireError.invalidFrame
        }
    }

    private mutating func object(depth: Int) throws {
        index += 1
        whitespace()
        if consume(0x7d) { return }
        var keys = Set<String>()
        while true {
            let key = try string(decode: true)
            duplicate = !keys.insert(key).inserted || duplicate
            whitespace()
            guard consume(0x3a) else { throw IMessageGatewayWireError.invalidFrame }
            whitespace()
            if depth == 0, key.lowercased() == "imessage" { selected = true }
            if depth == 0, key.lowercased() == "imessage_protocol_version" {
                let start = index
                try value(depth: depth + 1)
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                invalidNegotiation = invalidNegotiation || negotiationSeen || (token != "null" && Int64(token) == nil)
                negotiationSeen = true
            } else if depth == 0, key.lowercased() == "type", index < bytes.count, bytes[index] == 0x22 {
                if try string(decode: true) == "imessage" { selected = true }
            } else { try value(depth: depth + 1) }
            whitespace()
            if consume(0x7d) { return }
            guard consume(0x2c) else { throw IMessageGatewayWireError.invalidFrame }
            whitespace()
        }
    }

    private mutating func array(depth: Int) throws {
        index += 1
        whitespace()
        if consume(0x5d) { return }
        while true {
            try value(depth: depth + 1)
            whitespace()
            if consume(0x5d) { return }
            guard consume(0x2c) else { throw IMessageGatewayWireError.invalidFrame }
        }
    }

    private mutating func string(decode: Bool) throws -> String {
        let start = index
        guard consume(0x22) else { throw IMessageGatewayWireError.invalidFrame }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 0x22 {
                guard decode else { return "" }
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
            guard byte >= 0x20 else { throw IMessageGatewayWireError.invalidFrame }
            if byte == 0x5c { try escape() }
        }
        throw IMessageGatewayWireError.invalidFrame
    }

    private mutating func escape() throws {
        guard index < bytes.count else { throw IMessageGatewayWireError.invalidFrame }
        let escape = bytes[index]
        index += 1
        if [UInt8(0x22), 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74].contains(escape) { return }
        guard escape == 0x75, index + 4 <= bytes.count else { throw IMessageGatewayWireError.invalidFrame }
        for byte in bytes[index..<(index + 4)] {
            guard (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte) else {
                throw IMessageGatewayWireError.invalidFrame
            }
        }
        index += 4
    }

    private mutating func number() throws {
        let start = index
        _ = consume(0x2d)
        guard index < bytes.count else { throw IMessageGatewayWireError.invalidFrame }
        if !consume(0x30) {
            guard (0x31...0x39).contains(bytes[index]) else { throw IMessageGatewayWireError.invalidFrame }
            digits()
        }
        if consume(0x2e) { nonInteger = true; try requiredDigits() }
        if consume(0x65) || consume(0x45) {
            nonInteger = true
            if !consume(0x2b) { _ = consume(0x2d) }
            try requiredDigits()
        }
        if Int64(String(decoding: bytes[start..<index], as: UTF8.self)) == nil { nonInteger = true }
    }

    private mutating func digits() {
        while index < bytes.count && (0x30...0x39).contains(bytes[index]) { index += 1 }
    }

    private mutating func requiredDigits() throws {
        let start = index
        digits()
        guard index > start else { throw IMessageGatewayWireError.invalidFrame }
    }

    private mutating func literal(_ value: String) throws {
        let expected = Array(value.utf8)
        guard index + expected.count <= bytes.count, bytes[index..<(index + expected.count)].elementsEqual(expected) else {
            throw IMessageGatewayWireError.invalidFrame
        }
        index += expected.count
    }

    private mutating func whitespace() {
        while index < bytes.count && [UInt8(0x20), 0x09, 0x0a, 0x0d].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
