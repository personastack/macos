import CryptoKit
import Foundation
import PersonaStackCore

@MainActor
final class DesktopPermissionEvidence {
    static let shared = DesktopPermissionEvidence()
    private let preferences: UserDefaults
    private let context: @MainActor () -> DesktopPermissionReceipt.Context
    private static let key = "desktopControl.permissionEvidence.v2"

    init(preferences: UserDefaults = .standard,
         context: @escaping @MainActor () -> DesktopPermissionReceipt.Context = DesktopPermissionEvidence.currentContext) {
        self.preferences = preferences
        self.context = context
    }

    func record(_ observations: [DesktopPermissionID: DesktopPermissionObservation]) {
        let identity = context()
        guard !identity.hostIdentity.isEmpty,
              let data = try? JSONEncoder().encode(DesktopPermissionReceipt(context: identity, observations: observations, now: Date(), browserTargets: browserTargets(), browserJavaScriptInstances: verifiedBrowserInstances(), browserConnectionInstances: verifiedBrowserConnectionInstances())) else { return }
        preferences.set(data, forKey: Self.key)
    }

    func browserTargets() -> Set<DesktopBrowserConsentTarget> {
        guard let data = preferences.data(forKey: Self.key), data.count < 16_384,
              let receipt = try? JSONDecoder().decode(DesktopPermissionReceipt.self, from: data) else { return [] }
        return receipt.browserTargets(context: context())
    }

    func verifiedBrowserInstances() -> Set<String> {
        guard let data = preferences.data(forKey: Self.key), data.count < 16_384,
              let receipt = try? JSONDecoder().decode(DesktopPermissionReceipt.self, from: data) else { return [] }
        return receipt.verifiedBrowserInstances(context: context())
    }

    func recordVerifiedBrowserInstances(_ identities: Set<String>) {
        guard let data = preferences.data(forKey: Self.key), data.count < 16_384,
              var receipt = try? JSONDecoder().decode(DesktopPermissionReceipt.self, from: data),
              receipt.context == context(), receipt.revision == DesktopPermissionReadiness.requirementRevision else { return }
        receipt.setVerifiedBrowserInstances(identities)
        if let data = try? JSONEncoder().encode(receipt), data.count < 16_384 { preferences.set(data, forKey: Self.key) }
    }

    func verifiedBrowserConnectionInstances() -> Set<String> {
        guard let data = preferences.data(forKey: Self.key), data.count < 16_384,
              let receipt = try? JSONDecoder().decode(DesktopPermissionReceipt.self, from: data) else { return [] }
        return receipt.verifiedBrowserConnectionInstances(context: context())
    }

    func recordVerifiedBrowserConnectionInstances(_ identities: Set<String>) {
        guard let data = preferences.data(forKey: Self.key), data.count < 16_384,
              var receipt = try? JSONDecoder().decode(DesktopPermissionReceipt.self, from: data),
              receipt.context == context(), receipt.revision == DesktopPermissionReadiness.requirementRevision else { return }
        receipt.setVerifiedBrowserConnectionInstances(identities)
        if let data = try? JSONEncoder().encode(receipt), data.count < 16_384 { preferences.set(data, forKey: Self.key) }
    }

    func recordBrowserTargets(_ targets: Set<DesktopBrowserConsentTarget>) {
        let identity = context()
        guard !identity.hostIdentity.isEmpty else { return }
        var receipt = DesktopPermissionReceipt(context: identity, observations: [:], now: Date())
        if let data = preferences.data(forKey: Self.key), data.count < 16_384,
           let previous = try? JSONDecoder().decode(DesktopPermissionReceipt.self, from: data),
           previous.context == identity, previous.revision == DesktopPermissionReadiness.requirementRevision {
            receipt = previous
        }
        receipt.setBrowserTargets(targets)
        guard let data = try? JSONEncoder().encode(receipt), data.count < 16_384 else { return }
        preferences.set(data, forKey: Self.key)
    }

    func restoring(_ id: DesktopPermissionID, current: DesktopPermissionObservation) -> DesktopPermissionObservation {
        guard let data = preferences.data(forKey: Self.key), data.count < 16_384,
              let receipt = try? JSONDecoder().decode(DesktopPermissionReceipt.self, from: data) else { return current }
        return receipt.restoring(id, current: current, context: context())
    }

    func invalidate() { preferences.removeObject(forKey: Self.key) }

    func invalidate(_ id: DesktopPermissionID) {
        guard let data = preferences.data(forKey: Self.key), data.count < 16_384,
              var receipt = try? JSONDecoder().decode(DesktopPermissionReceipt.self, from: data) else { return }
        receipt.invalidate(id)
        if let updated = try? JSONEncoder().encode(receipt) { preferences.set(updated, forKey: Self.key) }
    }

    private static func currentContext() -> DesktopPermissionReceipt.Context {
        let certificate = Bundle.main.url(forResource: "ReleaseSigningCertificate", withExtension: "der")
            .flatMap { try? Data(contentsOf: $0) }
        let identity = certificate.map { data in
            "\(Bundle.main.bundleIdentifier ?? ""):\(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()):\(Bundle.main.bundleURL.standardizedFileURL.path):\((try? LaunchConfiguration.selectedEnvironment().preferenceIdentity) ?? "unconfigured")"
        } ?? ""
        return .init(hostIdentity: identity, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                     driverIdentity: CuaDriverCompatibility.executableSHA256)
    }
}
