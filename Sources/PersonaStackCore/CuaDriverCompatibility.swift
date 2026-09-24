import Foundation

public enum CuaDriverCompatibility {
    public static let version = "0.28.2"
    public static let schemaVersion = "1"
    public static let bundleIdentifier = "com.trycua.driver"
    public static let teamIdentifier = "YCK386LBJ7"
    public static let archiveSHA256 = "e273181b26709c88b1d809474deb3c592b4efae3530b11d76318f1887fc3fbb1"
    public static let archiveURL = URL(string: "https://github.com/trycua/cua/releases/download/cua-driver-rs-v0.28.2/cua-driver-rs-0.28.2-darwin-universal.tar.gz")!
    public static let managedServiceEnvironment = [
        "CUA_DRIVER_RS_TELEMETRY_ENABLED": "0",
        "CUA_DRIVER_RS_UPDATE_CHECK": "false",
    ]
    private static let inheritedEnvironmentKeys: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
    ]
    public static let licenseNotice = """
    MIT License

    Copyright (c) 2025 Cua AI, Inc.

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """

    /// PersonaStack's reviewed GUI surface. Upstream tools are never exposed automatically.
    public static let exposedTools: Set<String> = [
        "bring_to_front", "browser_click", "browser_dialog", "browser_download", "browser_navigate",
        "browser_pointer", "browser_set_input_files", "browser_type", "check_permissions", "click",
        "clipboard_read", "clipboard_write", "double_click", "drag", "get_accessibility_tree",
        "get_browser_state", "get_cursor_position", "get_desktop_state", "get_screen_size",
        "get_window_state", "hotkey", "invoke_menu", "kill_app", "launch_app", "list_apps",
        "list_windows", "move_cursor", "press_key", "right_click", "scroll", "set_value",
        "set_window_frame", "type_text", "zoom"
    ]

    public struct Manifest: Decodable, Equatable, Sendable {
        public let binaryVersion: String
        public let schemaVersion: String

        enum CodingKeys: String, CodingKey {
            case binaryVersion = "binary_version"
            case schemaVersion = "schema_version"
        }

        public init(binaryVersion: String, schemaVersion: String) {
            self.binaryVersion = binaryVersion
            self.schemaVersion = schemaVersion
        }
    }

    public enum ValidationError: Error, Equatable {
        case malformedManifest
        case unsupportedVersion
        case unsupportedSchema
        case missingRequiredTools([String])
    }

    public static let requiredTools: Set<String> = [
        "get_desktop_state", "get_accessibility_tree", "get_window_state", "move_cursor",
        "click", "type_text", "press_key", "launch_app", "list_apps", "list_windows"
    ]

    public static func processEnvironment(from environment: [String: String]) -> [String: String] {
        environment.filter { inheritedEnvironmentKeys.contains($0.key) }
            .merging(managedServiceEnvironment) { _, managed in managed }
    }

    public static func validate(manifestData: Data, toolNames: Set<String>) throws {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) else {
            throw ValidationError.malformedManifest
        }
        guard manifest.binaryVersion == version else { throw ValidationError.unsupportedVersion }
        guard manifest.schemaVersion == schemaVersion else { throw ValidationError.unsupportedSchema }
        let missing = requiredTools.subtracting(toolNames).sorted()
        guard missing.isEmpty else { throw ValidationError.missingRequiredTools(missing) }
    }

    public static func parseToolNames(_ output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        })
    }
}
