import CryptoKit
import Darwin
import Foundation
import PersonaStackCore
import Security

/// Invoked only by the main macOS Installer or an explicit uninstall. No network, app
/// credentials, user-controlled arguments, or long-running privileged service.
final class SystemPolicyInstaller: DesktopLockedControlPolicyInstalling {
    typealias Policy = DesktopLockedControlPolicy
    private var authorization: AuthorizationRef?

    init() throws {
        guard getuid() == 0, geteuid() == 0,
              CommandLine.arguments.count == 2,
              ["--apply", "--remove"].contains(CommandLine.arguments[1]) else { throw InstallError.denied }
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess else {
            throw InstallError.denied
        }
    }

    deinit { if let authorization { AuthorizationFree(authorization, []) } }

    func verifyPayload() throws {
        let bundle = Policy.bundlePath
        for (path, directory) in [(bundle, true), (bundle + "/Contents", true),
            (bundle + "/Contents/MacOS", true), (bundle + "/Contents/Resources", true),
            (bundle + "/Contents/Info.plist", false),
            (bundle + "/Contents/MacOS/AuthorizationGrantPlugin", false),
            (bundle + "/Contents/Resources/ReleaseSigningCertificate.der", false)] {
            try protectedPath(path, directory: directory)
        }
        let tool = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        guard tool == "/Library/Application Support/PersonaStack/LockedControlInstaller" else { throw InstallError.denied }
        try protectedPath(tool, directory: false)
        let pin = try Data(contentsOf: URL(fileURLWithPath: bundle + "/Contents/Resources/ReleaseSigningCertificate.der"))
        guard !pin.isEmpty, pin.count < 32 * 1024 else { throw InstallError.denied }
        let digest = Insecure.SHA1.hash(data: pin).map { String(format: "%02x", $0) }.joined()
        try verifySignature(path: bundle, identifier: Policy.right, digest: digest)
        try verifySignature(path: tool, identifier: "ai.personastack.locked-control-installer", digest: digest)
        try protectedPath("/Library/Application Support/PersonaStack", directory: true)
    }

    func readRight(_ name: String) throws -> [String: Any]? {
        var value: CFDictionary?
        let status = AuthorizationRightGet(name, &value)
        if status == errAuthorizationDenied { return nil }
        guard status == errAuthorizationSuccess, let value else { throw InstallError.readFailed }
        return value as NSDictionary as? [String: Any]
    }

    func writeRight(_ name: String, value: [String: Any]) throws {
        guard let authorization,
              AuthorizationRightSet(authorization, name, value as CFDictionary, nil, nil, nil) == errAuthorizationSuccess
        else { throw InstallError.writeFailed }
    }

    func readReceipt() throws -> [String: Any]? {
        var metadata = stat()
        guard lstat(Policy.receiptPath, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw InstallError.readFailed
        }
        try protectedPath(Policy.receiptPath, directory: false)
        guard metadata.st_size <= 64 * 1024,
              let result = Policy.decode(try Data(contentsOf: URL(fileURLWithPath: Policy.receiptPath)))
        else { throw InstallError.readFailed }
        return result
    }

    func writeReceipt(_ value: [String: Any]) throws {
        // Root-only parent checked above. Refuse replacing existing evidence.
        let data = try Policy.encode(value)
        let fd = open(Policy.receiptPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw InstallError.writeFailed }
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw InstallError.writeFailed }
                offset += amount
            }
        }
    }

    func removeRight(_ name: String) throws {
        guard let authorization,
              AuthorizationRightRemove(authorization, name) == errAuthorizationSuccess
        else { throw InstallError.writeFailed }
    }

    func removeReceipt() throws {
        var metadata = stat()
        guard lstat(Policy.receiptPath, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw InstallError.readFailed
        }
        try protectedPath(Policy.receiptPath, directory: false)
        guard unlink(Policy.receiptPath) == 0 else { throw InstallError.writeFailed }
    }

    private func verifySignature(path: String, identifier: String, digest: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let expression = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf = H\"\(digest)\""
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess
        else { throw InstallError.untrustedSignature }
    }

    private func protectedPath(_ path: String, directory: Bool) throws {
        var current = ""
        let parts = path.split(separator: "/")
        for (index, part) in parts.enumerated() {
            current += "/" + part
            var value = stat()
            guard lstat(current, &value) == 0, value.st_uid == 0,
                  value.st_mode & 0o022 == 0,
                  value.st_mode & S_IFMT == (index < parts.count - 1 || directory ? S_IFDIR : S_IFREG)
            else { throw InstallError.denied }
        }
    }

    enum InstallError: Error { case denied, readFailed, writeFailed, untrustedSignature }
}

do {
    let system = try SystemPolicyInstaller()
    if CommandLine.arguments[1] == "--remove" {
        try DesktopLockedControlPolicyInstaller.uninstall(using: system)
        print("PersonaStack locked-control policy removed and verified.")
    } else {
        try DesktopLockedControlPolicyInstaller.install(using: system)
        print("PersonaStack locked-control policy installed and verified.")
    }
} catch {
    // No policy contents, paths from external input, or authorization material.
    let detail: String
    switch error {
    case SystemPolicyInstaller.InstallError.untrustedSignature:
        detail = "The locked-control payload must use PersonaStack's pinned Developer ID signature. Unsigned development builds cannot install it."
    case DesktopLockedControlPolicy.Failure.invalidPolicy:
        detail = "This Mac's lock-screen authorization policy is not supported. The policy was not replaced."
    case DesktopLockedControlPolicy.Failure.conflictingInstallation, DesktopLockedControlPolicy.Failure.changedPolicy:
        detail = "The installed lock-screen policy conflicts with the expected PersonaStack configuration. Review it before reinstalling."
    default:
        detail = "Verify administrator access and reinstall using the main signed PersonaStack installer."
    }
    fputs("PersonaStack locked-control setup failed. \(detail)\n", stderr)
    exit(1)
}
