import Foundation

/// Validates caller data before adding a host-owned Cua session label. The label
/// is not the PersonaStack lease token and carries no transport authority.
public enum CuaRemoteToolArguments {
    public enum PolicyError: Error, Equatable { case nativeSetupRequired }
    public static func prepare(name: String, arguments: DesktopControlJSONValue,
                               session: String) throws -> DesktopControlJSONValue {
        guard !session.isEmpty, case .object(var fields) = arguments,
              fields["session"] == nil else { throw CuaToolCatalog.ValidationError.invalidArguments }
        if name == "browser_prepare" { fields = try browserPreparation(fields) }
        var validationFields = fields
        if CuaToolCatalog.acceptsSession(name) { validationFields["session"] = .string(session) }
        try CuaToolCatalog.validate(tool: name, arguments: .object(validationFields))
        if name == "check_permissions" {
            guard fields["prompt"] != .bool(true), fields["probe_direct_capture"] != .bool(true) else {
                throw CuaToolCatalog.ValidationError.invalidArguments
            }
            fields["prompt"] = .bool(false)
            fields["probe_direct_capture"] = .bool(false)
        }
        if name == "install_extension" {
            guard fields["confirm"] != .bool(true) else { throw PolicyError.nativeSetupRequired }
            fields["confirm"] = .bool(false)
        }
        if name == "set_config" {
            try validateConfig(fields)
            if case .string(let key)? = fields["key"], let value = fields["value"] {
                fields = [key: value]
            }
            if case .number(let dimension)? = fields["max_image_dimension"],
               dimension < 0 || dimension > Double(UInt32.max) {
                throw CuaToolCatalog.ValidationError.invalidArguments
            }
        }
        if name == "list_sessions" {
            if case .number(let limit)? = fields["limit"], !(1...100).contains(limit) {
                throw CuaToolCatalog.ValidationError.invalidArguments
            }
            if case .string(let cursor)? = fields["cursor"] {
                guard cursor.hasPrefix("o:"), UInt64(cursor.dropFirst(2)) != nil else {
                    throw CuaToolCatalog.ValidationError.invalidArguments
                }
            }
        }
        // Even upstream tools whose schema has no session field need the owned
        // public label here. The trusted transport derives its internal identity
        // from this field before invocation (recording/config ownership).
        fields["session"] = .string(session)
        return .object(fields)
    }

    private static func browserPreparation(_ input: [String: DesktopControlJSONValue]) throws -> [String: DesktopControlJSONValue] {
        guard input["confirm"] == .bool(true) else { throw CuaToolCatalog.ValidationError.invalidArguments }
        var fields = input
        fields.removeValue(forKey: "confirm")
        if fields.isEmpty {
            return ["allow_launch": .bool(true), "profile": .object(["mode": .string("isolated_new")])]
        }
        if fields["strategy"] != nil {
            guard fields["profile"] == nil, fields["allow_launch"] == nil,
                  positiveInteger(fields["pid"]), positiveInteger(fields["window_id"]) else {
                throw CuaToolCatalog.ValidationError.invalidArguments
            }
        } else {
            guard case .object(let profile)? = fields["profile"],
                  fields["allow_launch"] == .bool(true), fields["pid"] == nil,
                  fields["window_id"] == nil else { throw CuaToolCatalog.ValidationError.invalidArguments }
            if profile["mode"] == .string("isolated_named") {
                guard case .string(let name)? = profile["name"],
                      name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
                    throw CuaToolCatalog.ValidationError.invalidArguments
                }
            } else if profile["name"] != nil { throw CuaToolCatalog.ValidationError.invalidArguments }
        }
        return fields
    }

    private static func positiveInteger(_ value: DesktopControlJSONValue?) -> Bool {
        guard case .number(let number) = value else { return false }
        return number > 0 && number <= Double(Int32.max) && number.rounded() == number
    }

    private static func validateConfig(_ fields: [String: DesktopControlJSONValue]) throws {
        guard let key = fields["key"] else {
            guard fields["value"] == nil else { throw CuaToolCatalog.ValidationError.invalidArguments }
            return
        }
        guard case .string(let name) = key,
              ["max_image_dimension", "experimental_pip", "experimental_pip_geometry"].contains(name),
              let value = fields["value"], fields.count == 2 else { throw CuaToolCatalog.ValidationError.invalidArguments }
        try CuaToolCatalog.validate(tool: "set_config", arguments: .object([name: value]))
    }
}
