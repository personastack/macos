import Foundation

struct DesktopParityFixture: Decodable {
    struct Files: Decodable {
        struct UTF8Boundary: Decodable {
            let asciiPrefixBytes: Int
            let trailingBytesHex: String
            let firstPageBytes: Int
            let nextOffset: Int
            let tailText: String
        }

        struct Binary: Decodable {
            let bytesHex: String
            let encoding: String
            let base64: String
        }

        struct Image: Decodable {
            let name: String
            let bytesHex: String
            let mimeType: String
        }

        struct Search: Decodable {
            struct File: Decodable {
                let name: String
                let content: String
            }

            let nameGlob: String
            let contentContains: String
            let limit: Int
            let files: [File]
            let pages: [[String]]
        }

        struct Changed: Decodable {
            let before: String
            let after: String
        }

        struct Symlink: Decodable {
            let targetName: String
            let targetContents: String
            let linkName: String
            let kind: String
        }

        struct Permission: Decodable {
            let mode: Int
            let code: String
        }

        struct UncertainWrite: Decodable {
            let code: String
            let message: String
            let knownFailureCode: String
        }

        let utf8Boundary: UTF8Boundary
        let binary: Binary
        let image: Image
        let search: Search
        let changed: Changed
        let symlink: Symlink
        let permission: Permission
        let uncertainWrite: UncertainWrite
    }

    struct Process: Decodable {
        let outputGapBytes: Int
        let stdinText: String
        let blockedStdinWriteBytes: Int
        let blockedStdinWrites: Int
        let maxProcesses: Int
        let limitCode: String
        let blockedInputCommand: String
        let cancellationCommand: String
        let leaderChildDelaySeconds: Int
        let leaderChildMarker: String
    }

    let files: Files
    let process: Process

    static func load() throws -> DesktopParityFixture {
        guard let url = Bundle.module.url(forResource: "desktop-parity", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(DesktopParityFixture.self, from: Data(contentsOf: url))
    }
}

extension Data {
    init(hexString: String) throws {
        guard hexString.count.isMultiple(of: 2) else { throw CocoaError(.coderInvalidValue) }
        var bytes = Data()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else {
                throw CocoaError(.coderInvalidValue)
            }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}
