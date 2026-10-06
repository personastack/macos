import Foundation

/// Validates caller data before adding a host-owned Cua session label. The label
/// is not the PersonaStack lease token and carries no transport authority.
public enum CuaRemoteToolArguments {
    public static func prepare(name: String, arguments: DesktopControlJSONValue,
                               session: String) throws -> DesktopControlJSONValue {
        guard CuaDriverCompatibility.exposedTools.contains(name), !session.isEmpty, case .object(var fields) = arguments,
              fields["session"] == nil else { throw CuaToolCatalog.ValidationError.invalidArguments }
        // The deployed MCP catalog still requires this legacy intent field.
        // Normalize its wire shape only. CUA retains all local consent and policy.
        if name == "browser_prepare", let confirm = fields.removeValue(forKey: "confirm") {
            guard confirm == .bool(true) else { throw CuaToolCatalog.ValidationError.invalidArguments }
            if fields.isEmpty {
                fields = ["allow_launch": .bool(true), "profile": .object(["mode": .string("isolated_new")])]
            }
        }
        var validationFields = fields
        if CuaToolCatalog.acceptsSession(name) { validationFields["session"] = .string(session) }
        try CuaToolCatalog.validate(tool: name, arguments: .object(validationFields))
        // Even upstream tools whose schema has no session field need the owned
        // public label here. The trusted transport derives its internal identity
        // from this field before invocation (recording/config ownership).
        fields["session"] = .string(session)
        return .object(fields)
    }

}
