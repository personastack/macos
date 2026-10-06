import Foundation

public enum CuaDriverCompatibility {
    public static let version = "0.29.1"
    public static let schemaVersion = "1"
    public static let bundleIdentifier = "com.trycua.driver"
    public static let teamIdentifier = "YCK386LBJ7"
    public static let archiveSHA256 = "ee376d59ef37afac29a10c60c71469ac85fdc8844d1884bd317edd8def29055a"
    public static let executableSHA256 = "620ec8d215661050fad8e33a09e06cdd4573b80cef13d2952f5d27d0536ac096"
    public static let archiveURL = URL(string: "https://github.com/trycua/cua/releases/download/cua-driver-rs-v0.29.1/cua-driver-rs-0.29.1-darwin-universal.tar.gz")!
    public static let managedServiceEnvironment = [
        "CUA_DRIVER_RS_TELEMETRY_ENABLED": "0",
        "CUA_DRIVER_RS_UPDATE_CHECK": "false",
    ]
    // Status refreshes never request permission. CUA owns its own TCC identity.
    public static let permissionProbeArgumentsJSON = Data(#"{"prompt":false,"probe_direct_capture":false}"#.utf8)
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

    /// Pinned artifact schemas are the sole catalog authority.
    public static var exposedTools: Set<String> {
        CuaToolCatalog.names.subtracting(["set_config", "install_extension", "install_ffmpeg", "check_permissions",
            "start_session", "end_session", "escalate_session", "list_sessions"])
    }

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

    public static var requiredTools: Set<String> { CuaToolCatalog.names }

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
        guard !requiredTools.isEmpty else { throw ValidationError.malformedManifest }
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

public struct CuaDriverPermissionSnapshot: Equatable, Sendable {
    public let accessibility: Bool
    public let screenRecording: Bool
    public let standaloneAttributionValid: Bool
    public let directCaptureVerified: Bool
    public let verificationKey: String

    public init(accessibility: Bool, screenRecording: Bool, standaloneAttributionValid: Bool, directCaptureVerified: Bool = false, verificationKey: String = "") {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.standaloneAttributionValid = standaloneAttributionValid
        self.directCaptureVerified = directCaptureVerified
        self.verificationKey = verificationKey
    }

    public static func parseStandalone(_ structured: [String: Any], daemonPID: Int32, verificationKey: String = "") throws -> Self {
        guard let accessibility = structured["accessibility"] as? Bool,
              let screenRecording = structured["screen_recording"] as? Bool,
              let source = structured["source"] as? [String: Any] else {
            throw CuaMCPProxyError.functionalProbeFailed
        }
        let hostValid = source["attribution"] as? String == "driver-daemon"
            && source["bundle_id"] as? String == CuaDriverCompatibility.bundleIdentifier
            && source["embedded"] as? Bool != true
            && (source["pid"] as? NSNumber)?.int32Value == daemonPID
        let verification = structured["direct_capture_verification"] as? [String: Any]
        let captureVerified = verification?["bundle_id"] as? String == CuaDriverCompatibility.bundleIdentifier
            && verification?["source"] as? String == "permissions_grant"
            && !(verification?["verified_at"] as? String ?? "").isEmpty
            && (structured["direct_capture_verification_error"] == nil || structured["direct_capture_verification_error"] is NSNull)
            && structured["screen_recording_capturable"] as? Bool != false
        return Self(accessibility: accessibility, screenRecording: screenRecording, standaloneAttributionValid: hostValid, directCaptureVerified: captureVerified,
                    verificationKey: verificationKey)
    }
}
