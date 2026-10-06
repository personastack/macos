import Foundation

/// The schema exported by the pinned, hash-verified macOS artifact. Discovery
/// from a running process cannot expand this reviewed remote surface.
public enum CuaToolCatalog {
    private struct Manifest: Decodable {
        let binaryVersion: String
        let archiveSHA256: String
        let tools: [String: DesktopControlJSONValue]
        enum CodingKeys: String, CodingKey {
            case binaryVersion = "binary_version", archiveSHA256 = "archive_sha256", tools
        }
    }

    public enum ValidationError: Error, Equatable { case unavailable, invalidArguments }

    private static let manifest: Manifest? = {
        guard let url = catalogURL(),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Manifest.self, from: data),
              value.binaryVersion == CuaDriverCompatibility.version,
              value.archiveSHA256 == CuaDriverCompatibility.archiveSHA256 else { return nil }
        return value
    }()

    /// Native SwiftPM and Xcode generate different Bundle.module search paths.
    /// An installed app always uses its packaged Resources, never a build path.
    static func catalogURL(application: Bundle = .main,
                           developmentResource: () -> URL? = {
                               Bundle.module.url(forResource: "cua-tools-0.29.1", withExtension: "json")
                           }) -> URL? {
        guard application.bundleURL.pathExtension == "app" else { return developmentResource() }
        guard let location = application.resourceURL?.appendingPathComponent("PersonaStackDesktop_PersonaStackCore.bundle"),
              let resources = Bundle(url: location) else { return nil }
        return resources.url(forResource: "cua-tools-0.29.1", withExtension: "json")
    }

    public static var names: Set<String> { Set(manifest?.tools.keys.map { $0 } ?? []) }

    static func reviewedSchema(_ name: String) -> DesktopControlJSONValue? { manifest?.tools[name] }

    public static func matchesAdvertisedSchema(name: String, schema: DesktopControlJSONValue) -> Bool {
        manifest?.tools[name] == schema
    }

    public static func acceptsSession(_ tool: String) -> Bool {
        guard case .object(let schema)? = manifest?.tools[tool],
              case .object(let properties)? = schema["properties"] else { return false }
        return properties["session"] != nil
    }

    public static func validate(tool: String, arguments: DesktopControlJSONValue) throws {
        guard let schema = manifest?.tools[tool] else { throw ValidationError.unavailable }
        guard case .object = arguments,
              matches(arguments, schema: schema, depth: 0), !hasReservedFields(arguments) else {
            throw ValidationError.invalidArguments
        }
    }

    private static func hasReservedFields(_ value: DesktopControlJSONValue) -> Bool {
        switch value {
        case .object(let fields):
            return fields.contains { $0.key.hasPrefix("_") || hasReservedFields($0.value) }
        case .array(let values): return values.contains(where: hasReservedFields)
        default: return false
        }
    }

    private static func matches(_ value: DesktopControlJSONValue, schema: DesktopControlJSONValue, depth: Int) -> Bool {
        guard depth < 32, case .object(let rules) = schema else { return false }
        if case .array(let choices)? = rules["oneOf"],
           choices.filter({ matches(value, schema: $0, depth: depth + 1) }).count != 1 { return false }
        if case .array(let choices)? = rules["anyOf"],
           !choices.contains(where: { matches(value, schema: $0, depth: depth + 1) }) { return false }
        if let constant = rules["const"], value != constant { return false }
        if case .array(let choices)? = rules["enum"], !choices.contains(value) { return false }
        if let type = rules["type"], !matchesType(value, type) { return false }
        switch value {
        case .object(let fields): return matchesObject(fields, rules: rules, depth: depth)
        case .array(let values): return matchesArray(values, rules: rules, depth: depth)
        case .string(let text): return matchesString(text, rules: rules)
        case .number(let number):
            return number.isFinite && number >= numeric(rules["minimum"], default: -.infinity)
                && number <= numeric(rules["maximum"], default: .infinity)
        default: return true
        }
    }

    private static func matchesObject(_ fields: [String: DesktopControlJSONValue],
                                      rules: [String: DesktopControlJSONValue], depth: Int) -> Bool {
        if case .array(let required)? = rules["required"] {
            for case .string(let key) in required where fields[key] == nil { return false }
        }
        guard case .object(let properties)? = rules["properties"] else {
            return rules["additionalProperties"] != .bool(false) || fields.isEmpty
        }
        // Generated upstream schemas sometimes permit unknown fields. Remote
        // callers get the documented finite fields, never internal transport keys.
        for (key, value) in fields {
            guard let child = properties[key], matches(value, schema: child, depth: depth + 1) else { return false }
        }
        return true
    }

    private static func matchesArray(_ values: [DesktopControlJSONValue],
                                     rules: [String: DesktopControlJSONValue], depth: Int) -> Bool {
        guard Double(values.count) >= numeric(rules["minItems"], default: 0),
              Double(values.count) <= numeric(rules["maxItems"], default: 4096) else { return false }
        if rules["uniqueItems"] == .bool(true) {
            for index in values.indices where values[..<index].contains(values[index]) { return false }
        }
        guard let items = rules["items"] else { return true }
        return values.allSatisfy { matches($0, schema: items, depth: depth + 1) }
    }

    private static func matchesString(_ text: String, rules: [String: DesktopControlJSONValue]) -> Bool {
        guard Double(text.unicodeScalars.count) >= numeric(rules["minLength"], default: 0),
              Double(text.unicodeScalars.count) <= numeric(rules["maxLength"], default: 1_000_000) else { return false }
        if case .string(let pattern)? = rules["pattern"] {
            guard text.range(of: pattern, options: .regularExpression) != nil else { return false }
        }
        return true
    }

    private static func matchesType(_ value: DesktopControlJSONValue, _ rule: DesktopControlJSONValue) -> Bool {
        if case .array(let types) = rule { return types.contains { matchesType(value, $0) } }
        guard case .string(let type) = rule else { return false }
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null): return true
        case ("number", .number(let number)): return number.isFinite
        case ("integer", .number(let number)): return number.isFinite && number.rounded() == number
        default: return false
        }
    }

    private static func numeric(_ value: DesktopControlJSONValue?, default fallback: Double) -> Double {
        if case .number(let number) = value { return number }
        return fallback
    }
}
