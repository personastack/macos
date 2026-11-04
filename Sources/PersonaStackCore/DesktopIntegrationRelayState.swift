import Foundation

/// API-owned registration state. Shared relay ownership does not grant a
/// capability's permissions, command authorization, or functional readiness.
public struct DesktopControlConfigurationState: Decodable, Sendable {
    public let hasActiveConfig: Bool
    public let hasConfig: Bool
    public let hasActiveIMessageConfig: Bool
    public let hasIMessageConfig: Bool

    public var hasActiveRelayCapability: Bool { hasActiveConfig || hasActiveIMessageConfig }

    enum CodingKeys: String, CodingKey {
        case hasActiveConfig = "has_active_config"
        case hasConfig = "has_config"
        case hasActiveIMessageConfig = "has_active_imessage_config"
        case hasIMessageConfig = "has_imessage_config"
    }

    public init(hasActiveConfig: Bool, hasConfig: Bool, hasActiveIMessageConfig: Bool = false, hasIMessageConfig: Bool = false) {
        self.hasActiveConfig = hasActiveConfig
        self.hasConfig = hasConfig
        self.hasActiveIMessageConfig = hasActiveIMessageConfig
        self.hasIMessageConfig = hasIMessageConfig
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hasActiveConfig = try values.decode(Bool.self, forKey: .hasActiveConfig)
        hasConfig = try values.decode(Bool.self, forKey: .hasConfig)
        hasActiveIMessageConfig = try values.contains(.hasActiveIMessageConfig)
            ? values.decode(Bool.self, forKey: .hasActiveIMessageConfig) : false
        hasIMessageConfig = try values.contains(.hasIMessageConfig)
            ? values.decode(Bool.self, forKey: .hasIMessageConfig) : false
        guard !hasActiveConfig || hasConfig else {
            throw DecodingError.dataCorruptedError(forKey: .hasActiveConfig, in: values, debugDescription: "An active Desktop Control registration must exist.")
        }
        guard !hasActiveIMessageConfig || hasIMessageConfig else {
            throw DecodingError.dataCorruptedError(forKey: .hasActiveIMessageConfig, in: values, debugDescription: "An active iMessage registration must exist.")
        }
    }
}
