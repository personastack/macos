import CoreFoundation
import Foundation

/// Shared policy contract for explicit installation and read-only admission.
/// No method in this type reads or changes the authorization database.
public enum DesktopLockedControlPolicy {
    public static let right = "ai.personastack.locked-grant-candidate"
    public static let mechanism = "PersonaStackLockedGrantCandidate:consume-locked-grant,privileged"
    public static let bundlePath = "/Library/Security/SecurityAgentPlugins/PersonaStackLockedGrantCandidate.bundle"
    public static let receiptPath = "/Library/Application Support/PersonaStack/LockedControlPolicyBaseline.plist"
    public static let screensaverRight = "system.login.screensaver"

    public enum Failure: Error { case invalidPolicy, conflictingInstallation, changedPolicy, verificationFailed }

    public static var leaf: [String: Any] {
        ["class": "evaluate-mechanisms", "mechanisms": [mechanism], "tries": 1,
         "shared": false, "allow-root": false, "version": 1]
    }

    public static func compose(_ original: [String: Any]) throws -> [String: Any] {
        guard let rules = rules(original), rules.count < 64, !rules.contains(right),
              Set(rules).count == rules.count,
              let threshold = original["k-of-n"].map(integer) ?? 0,
              threshold == 0 || threshold == 1,
              rules.count == 1 || threshold == 1 else { throw Failure.invalidPolicy }
        var result = original
        result["rule"] = [right] + rules
        result["k-of-n"] = 1
        return result
    }

    public static func receipt(for original: [String: Any]) throws -> [String: Any] {
        _ = try compose(original)
        return ["version": 1, "right": right, "manualFallbacks": rules(original)!]
    }

    public static func matches(leaf: [String: Any], policy: [String: Any], receipt: [String: Any]) -> Bool {
        guard validLeaf(leaf), let current = rules(policy), current.first == right,
              current.filter({ $0 == right }).count == 1, integer(policy["k-of-n"]) == 1,
              integer(receipt["version"]) == 1, receipt["right"] as? String == right,
              let fallback = receipt["manualFallbacks"] as? [String], validNames(fallback),
              !fallback.contains(right), Set(fallback).count == fallback.count else { return false }
        // Any additional any-of delegate can independently unlock the session.
        // Preserve later operator changes, but do not qualify them implicitly.
        return current == [right] + fallback
    }

    public static func validLeaf(_ value: [String: Any]) -> Bool {
        value["class"] as? String == "evaluate-mechanisms"
            && value["mechanisms"] as? [String] == [mechanism]
            && integer(value["tries"]) == 1 && boolean(value["shared"]) == false
            // authd emits allow-root only for the user class. Mechanism rules
            // omit it on readback. Still reject any explicit non-false value.
            && (value["allow-root"] == nil || boolean(value["allow-root"]) == false)
            && integer(value["version"]) == 1
    }

    public static func decode(_ data: Data) -> [String: Any]? {
        guard data.count <= 1024 * 1024,
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return nil }
        return value as? [String: Any]
    }

    public static func encode(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    public static func rules(_ policy: [String: Any]) -> [String]? {
        guard policy["class"] as? String == "rule" else { return nil }
        let names = (policy["rule"] as? String).map { [$0] } ?? policy["rule"] as? [String]
        guard let names, validNames(names) else { return nil }
        return names
    }

    private static func validNames(_ names: [String]) -> Bool {
        !names.isEmpty && names.count <= 64 && names.allSatisfy { !$0.isEmpty && $0.count <= 256 }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

/// Fixed installation operations. Implementations must protect their paths and
/// authenticate the installed code before allowing any policy mutation.
public protocol DesktopLockedControlPolicyInstalling {
    func verifyPayload() throws
    func readRight(_ name: String) throws -> [String: Any]?
    func readReceipt() throws -> [String: Any]?
    func writeRight(_ name: String, value: [String: Any]) throws
    func writeReceipt(_ value: [String: Any]) throws
    func removeRight(_ name: String) throws
    func removeReceipt() throws
}

public enum DesktopLockedControlPolicyInstaller {
    /// Detach our branch before a package uninstall removes the plug-in.
    /// Unexpected policy changes require operator review.
    public static func uninstall(using system: any DesktopLockedControlPolicyInstalling) throws {
        typealias Policy = DesktopLockedControlPolicy
        try system.verifyPayload()
        guard let current = try system.readRight(Policy.screensaverRight),
              let rules = Policy.rules(current) else { throw Policy.Failure.invalidPolicy }
        if rules.contains(Policy.right) {
            guard let leaf = try system.readRight(Policy.right), let receipt = try system.readReceipt(),
                  Policy.matches(leaf: leaf, policy: current, receipt: receipt)
            else { throw Policy.Failure.conflictingInstallation }
            var restored = current
            restored["rule"] = Array(rules.dropFirst())
            restored["k-of-n"] = 1
            guard let live = try system.readRight(Policy.screensaverRight),
                  NSDictionary(dictionary: live).isEqual(to: current) else { throw Policy.Failure.changedPolicy }
            try system.writeRight(Policy.screensaverRight, value: restored)
            // authd changes modified on a successful write. All authorization
            // fields and fallback order must still match the restored policy.
            guard let live = try system.readRight(Policy.screensaverRight),
                  NSDictionary(dictionary: live.filter { $0.key != "modified" })
                    .isEqual(to: restored.filter { $0.key != "modified" })
            else { throw Policy.Failure.verificationFailed }
        }
        if let leaf = try system.readRight(Policy.right) {
            guard Policy.validLeaf(leaf) else { throw Policy.Failure.conflictingInstallation }
            try system.removeRight(Policy.right)
        }
        try system.removeReceipt()
    }

    /// Write the inert receipt and leaf first. The final policy write activates
    /// only our branch and retains every original manual-authentication delegate.
    /// A retry reuses matching inert artifacts. Conflicting state needs review.
    public static func install(using system: any DesktopLockedControlPolicyInstalling) throws {
        typealias Policy = DesktopLockedControlPolicy
        try system.verifyPayload()
        guard let original = try system.readRight(Policy.screensaverRight) else { throw Policy.Failure.invalidPolicy }
        let oldLeaf = try system.readRight(Policy.right)
        let oldReceipt = try system.readReceipt()
        if Policy.rules(original)?.contains(Policy.right) == true {
            guard let oldLeaf, let oldReceipt, Policy.matches(leaf: oldLeaf, policy: original, receipt: oldReceipt)
            else { throw Policy.Failure.conflictingInstallation }
            return
        }
        let proposed = try Policy.compose(original)
        let receipt = try Policy.receipt(for: original)
        guard oldLeaf.map(Policy.validLeaf) ?? true,
              oldReceipt.map({ NSDictionary(dictionary: $0).isEqual(to: receipt) }) ?? true
        else { throw Policy.Failure.conflictingInstallation }
        if oldReceipt == nil { try system.writeReceipt(receipt) }
        if oldLeaf == nil { try system.writeRight(Policy.right, value: Policy.leaf) }
        guard let current = try system.readRight(Policy.screensaverRight),
              NSDictionary(dictionary: current).isEqual(to: original) else { throw Policy.Failure.changedPolicy }
        try system.writeRight(Policy.screensaverRight, value: proposed)
        guard let liveLeaf = try system.readRight(Policy.right),
              let livePolicy = try system.readRight(Policy.screensaverRight),
              let liveReceipt = try system.readReceipt(),
              Policy.matches(leaf: liveLeaf, policy: livePolicy, receipt: liveReceipt)
        else { throw Policy.Failure.verificationFailed }
    }
}
