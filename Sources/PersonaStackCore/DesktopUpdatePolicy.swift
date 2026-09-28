import Foundation

public enum DesktopUpdatePolicy {
    public enum CheckResult: Equatable {
        case upToDate
        case noCompatibleUpdate
        case unavailable
        case failed
    }

    public enum NoUpdateReason {
        case currentVersion
        case incompatible
        case unknown
    }

    public static let feedURL = "https://raw.githubusercontent.com/personastack/homebrew-tap/main/appcast.xml"

    public static func hasTrustedFeed(publicKey: String?, feed: String?) -> Bool {
        guard let publicKey, let keyData = Data(base64Encoded: publicKey), keyData.count == 32,
              let feed, feed == feedURL,
              let url = URL(string: feed), url.scheme == "https",
              url.host == "raw.githubusercontent.com", url.query == nil, url.fragment == nil else { return false }
        return true
    }

    public static func isStableVersion(_ version: String) -> Bool {
        version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
    }

    public static func shouldProjectReady(isReady: Bool, currentVersion: String?, offeredVersion: String?) -> Bool {
        !isReady || currentVersion != offeredVersion
    }

    public static func shouldPresentReminder(version: String, lastPresentedVersion: String?) -> Bool {
        lastPresentedVersion != version
    }

    public static func didCompleteRestart(targetVersion: String, runningVersion: String?) -> Bool {
        targetVersion == runningVersion
    }

    public static func shouldUseAccessoryActivation(relayEnabled: Bool, foregroundUpdateRelaunch: Bool) -> Bool {
        relayEnabled && !foregroundUpdateRelaunch
    }

    public static func requiresApplicationsInstall(bundleURL: URL, volumeIsReadOnly: Bool) -> Bool {
        volumeIsReadOnly || bundleURL.standardizedFileURL.pathComponents.contains("AppTranslocation")
    }

    public static func checkResult(errorDomain: String, errorCode: Int, noUpdateReason: NoUpdateReason?) -> CheckResult {
        guard errorDomain == "SUSparkleErrorDomain", errorCode == 1001 else { return .failed }
        switch noUpdateReason {
        case .currentVersion: return .upToDate
        case .incompatible: return .noCompatibleUpdate
        case .unknown, nil: return .unavailable
        }
    }
}
