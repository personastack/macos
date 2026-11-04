import Foundation

public enum IMessageSetupHandoffError: Error, Equatable, Sendable {
    case invalidRequest
}

/// An untrusted request to open setup. It conveys no user, environment,
/// installation, consent or runtime authority. The native coordinator must
/// authenticate against its configured server before resolving the reference.
public struct IMessageSetupHandoff: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let deepLinkPrefix = "personastack://connect-imessage?setup_reference="
    public let setupReference: String

    public init(setupReference: String) throws {
        guard Self.validReference(setupReference) else { throw IMessageSetupHandoffError.invalidRequest }
        self.setupReference = setupReference
    }

    public static func parseDeepLink(_ url: URL) throws -> Self {
        let raw = url.absoluteString
        guard raw.utf8.count == deepLinkPrefix.utf8.count + 43,
              raw.hasPrefix(deepLinkPrefix) else { throw IMessageSetupHandoffError.invalidRequest }
        return try Self(setupReference: String(raw.dropFirst(deepLinkPrefix.count)))
    }

    /// Call only after the owning WebView has checked the configured origin,
    /// current main frame and document. Pages may request setup, never approve it.
    public static func parsePageCommand(_ body: Any) throws -> Self {
        guard let object = body as? [String: Any],
              Set(object.keys) == ["version", "action", "setup_reference"],
              object["version"] as? String == "1", object["action"] as? String == "begin",
              let reference = object["setup_reference"] as? String else {
            throw IMessageSetupHandoffError.invalidRequest
        }
        return try Self(setupReference: reference)
    }

    public var description: String { "IMessageSetupHandoff(reference: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["reference": "<redacted>"]) }

    private static func validReference(_ value: String) -> Bool {
        guard value.utf8.count == 43,
              value.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) ||
                  (48...57).contains(byte) || byte == 45 || byte == 95
              }) else { return false }
        let standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let bytes = Data(base64Encoded: standard), bytes.count == 32 else { return false }
        let canonical = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return canonical == value
    }
}
