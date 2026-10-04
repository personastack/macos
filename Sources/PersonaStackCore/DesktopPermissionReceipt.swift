import Foundation

/// Historical, content-free proof from attended setup. This never replaces a
/// public OS permission query and never changes a known denial into approval.
public struct DesktopPermissionReceipt: Codable, Equatable, Sendable {
    public struct Context: Codable, Equatable, Sendable {
        public let hostIdentity: String
        public let osVersion: String
        public let driverIdentity: String
        public init(hostIdentity: String, osVersion: String, driverIdentity: String) {
            self.hostIdentity = hostIdentity
            self.osVersion = osVersion
            self.driverIdentity = driverIdentity
        }
    }
    public static let supplemental: Set<DesktopPermissionID> = [
        .directCapture, .fullDiskAccess, .localNetwork, .safariJavaScript, .awakeDuringRemoteWork, .visualPerception,
    ]
    public let revision: Int
    public let context: Context
    public let verifiedAt: Date
    private var verified: Set<String>
    private let safariVerificationKey: String?
    private let visualPerceptionVerificationKey: String?
    private var browserJavaScriptInstances: Set<String>?
    private var browserConnectionInstances: Set<String>?
    private var approvedBrowserTargets: Set<DesktopBrowserConsentTarget>?

    public init(context: Context, observations: [DesktopPermissionID: DesktopPermissionObservation], now: Date,
                browserTargets: Set<DesktopBrowserConsentTarget> = [], browserJavaScriptInstances: Set<String> = [], browserConnectionInstances: Set<String> = []) {
        revision = DesktopPermissionReadiness.requirementRevision
        self.context = context
        approvedBrowserTargets = browserTargets.count <= 32 ? Set(browserTargets.filter(\.isSupported)) : []
        self.browserJavaScriptInstances = browserJavaScriptInstances.intersection(Set(browserTargets.map(\.instanceIdentity)))
        self.browserConnectionInstances = browserConnectionInstances.intersection(Set(browserTargets.map(\.instanceIdentity)))
        verifiedAt = now
        verified = Set(Self.supplemental.compactMap { id in
            guard let observation = observations[id],
                  DesktopPermissionRow(id: id, observation: observation).isComplete else { return nil }
            return id.rawValue
        })
        safariVerificationKey = observations[.safariJavaScript]?.verificationKey
        visualPerceptionVerificationKey = observations[.visualPerception]?.verificationKey
    }

    public func restoring(_ id: DesktopPermissionID, current: DesktopPermissionObservation,
                          context: Context) -> DesktopPermissionObservation {
        guard revision == DesktopPermissionReadiness.requirementRevision, self.context == context,
              !context.hostIdentity.isEmpty, Self.supplemental.contains(id), verified.contains(id.rawValue),
              current.state == .verificationRequired else { return current }
        if id == .safariJavaScript {
            guard let key = current.verificationKey, key == safariVerificationKey else { return current }
        }
        if id == .visualPerception {
            guard let key = current.verificationKey, key == visualPerceptionVerificationKey else { return current }
        }
        return .init(.ready, detail: "Verified during attended setup. No new permission request was made. Use setup to recheck after changing macOS permissions.",
                     verificationKey: current.verificationKey, verified: true)
    }

    public func browserTargets(context: Context) -> Set<DesktopBrowserConsentTarget> {
        guard revision == DesktopPermissionReadiness.requirementRevision, self.context == context,
              !context.hostIdentity.isEmpty, let targets = approvedBrowserTargets, targets.count <= 32 else { return [] }
        return Set(targets.filter(\.isSupported))
    }

    public func verifiedBrowserInstances(context: Context) -> Set<String> {
        let allowed = Set(browserTargets(context: context).map(\.instanceIdentity))
        return (browserJavaScriptInstances ?? []).intersection(allowed)
    }

    public mutating func setVerifiedBrowserInstances(_ identities: Set<String>) {
        browserJavaScriptInstances = identities.intersection(Set((approvedBrowserTargets ?? []).map(\.instanceIdentity)))
    }

    public func verifiedBrowserConnectionInstances(context: Context) -> Set<String> {
        (browserConnectionInstances ?? []).intersection(Set(browserTargets(context: context).map(\.instanceIdentity)))
    }

    public mutating func setVerifiedBrowserConnectionInstances(_ identities: Set<String>) {
        browserConnectionInstances = identities.intersection(Set((approvedBrowserTargets ?? []).map(\.instanceIdentity)))
    }

    public mutating func setBrowserTargets(_ targets: Set<DesktopBrowserConsentTarget>) {
        approvedBrowserTargets = targets.count <= 32 ? Set(targets.filter(\.isSupported)) : []
        browserJavaScriptInstances = (browserJavaScriptInstances ?? []).intersection(Set((approvedBrowserTargets ?? []).map(\.instanceIdentity)))
        browserConnectionInstances = (browserConnectionInstances ?? []).intersection(Set((approvedBrowserTargets ?? []).map(\.instanceIdentity)))
    }

    public mutating func invalidate(_ id: DesktopPermissionID) { verified.remove(id.rawValue) }
}
