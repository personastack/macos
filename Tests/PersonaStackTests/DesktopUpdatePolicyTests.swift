import Foundation
import Testing
import PersonaStackCore

@Suite struct DesktopUpdatePolicyTests {
    @Test func acceptsOnlyThePinnedHTTPSFeedAndEd25519Key() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        #expect(DesktopUpdatePolicy.hasTrustedFeed(publicKey: key, feed: DesktopUpdatePolicy.feedURL))
        #expect(!DesktopUpdatePolicy.hasTrustedFeed(publicKey: nil, feed: DesktopUpdatePolicy.feedURL))
        #expect(!DesktopUpdatePolicy.hasTrustedFeed(publicKey: Data(repeating: 7, count: 31).base64EncodedString(), feed: DesktopUpdatePolicy.feedURL))
        #expect(!DesktopUpdatePolicy.hasTrustedFeed(publicKey: key, feed: "http://raw.githubusercontent.com/personastack/homebrew-tap/main/appcast.xml"))
        #expect(!DesktopUpdatePolicy.hasTrustedFeed(publicKey: key, feed: "https://evil.example/appcast.xml"))
    }

    @Test func stableFeedVersionsRequireThreeNumericComponents() {
        for version in ["0.1.48", "12.0.1"] {
            #expect(DesktopUpdatePolicy.isStableVersion(version))
        }
        for version in ["0.1", "0.1.49-beta.1", "v0.1.49", "0.1.49+build"] {
            #expect(!DesktopUpdatePolicy.isStableVersion(version))
        }
    }

    @Test func noUpdateReasonsDistinguishCurrentFromIncompatibleReleases() {
        #expect(DesktopUpdatePolicy.checkResult(errorDomain: "SUSparkleErrorDomain", errorCode: 1001, noUpdateReason: .currentVersion) == .upToDate)
        #expect(DesktopUpdatePolicy.checkResult(errorDomain: "SUSparkleErrorDomain", errorCode: 1001, noUpdateReason: .incompatible) == .noCompatibleUpdate)
        #expect(DesktopUpdatePolicy.checkResult(errorDomain: "SUSparkleErrorDomain", errorCode: 1001, noUpdateReason: .unknown) == .unavailable)
        #expect(DesktopUpdatePolicy.checkResult(errorDomain: "SUSparkleErrorDomain", errorCode: 1001, noUpdateReason: nil) == .unavailable)
        #expect(DesktopUpdatePolicy.checkResult(errorDomain: "NetworkError", errorCode: -1009, noUpdateReason: nil) == .failed)
    }

    @Test func reminderAndReadyTransitionsDeduplicateByVersion() {
        #expect(DesktopUpdatePolicy.shouldPresentReminder(version: "0.2.0", lastPresentedVersion: nil))
        #expect(!DesktopUpdatePolicy.shouldPresentReminder(version: "0.2.0", lastPresentedVersion: "0.2.0"))
        #expect(DesktopUpdatePolicy.shouldPresentReminder(version: "0.3.0", lastPresentedVersion: "0.2.0"))
        #expect(DesktopUpdatePolicy.shouldProjectReady(isReady: false, currentVersion: "0.2.0", offeredVersion: "0.2.0"))
        #expect(!DesktopUpdatePolicy.shouldProjectReady(isReady: true, currentVersion: "0.2.0", offeredVersion: "0.2.0"))
        #expect(DesktopUpdatePolicy.shouldProjectReady(isReady: true, currentVersion: "0.2.0", offeredVersion: "0.3.0"))
    }

    @Test func restartSuccessRequiresTheExpectedVersionToBeRunning() {
        #expect(DesktopUpdatePolicy.didCompleteRestart(targetVersion: "0.3.0", runningVersion: "0.3.0"))
        #expect(!DesktopUpdatePolicy.didCompleteRestart(targetVersion: "0.3.0", runningVersion: "0.2.0"))
        #expect(!DesktopUpdatePolicy.didCompleteRestart(targetVersion: "0.3.0", runningVersion: nil))
    }

    @Test func foregroundUpdateRelaunchKeepsRegularActivationWhileRelayStarts() {
        #expect(DesktopUpdatePolicy.shouldUseAccessoryActivation(relayEnabled: true, foregroundUpdateRelaunch: false))
        #expect(!DesktopUpdatePolicy.shouldUseAccessoryActivation(relayEnabled: true, foregroundUpdateRelaunch: true))
        #expect(!DesktopUpdatePolicy.shouldUseAccessoryActivation(relayEnabled: false, foregroundUpdateRelaunch: false))
    }

    @Test func readOnlyAndTranslocatedBundlesRequireAnApplicationsInstall() {
        #expect(DesktopUpdatePolicy.requiresApplicationsInstall(
            bundleURL: URL(fileURLWithPath: "/Volumes/PersonaStack/PersonaStack.app"),
            volumeIsReadOnly: true
        ))
        #expect(DesktopUpdatePolicy.requiresApplicationsInstall(
            bundleURL: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/d/PersonaStack.app"),
            volumeIsReadOnly: false
        ))
        #expect(!DesktopUpdatePolicy.requiresApplicationsInstall(
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"),
            volumeIsReadOnly: false
        ))
        #expect(!DesktopUpdatePolicy.requiresApplicationsInstall(
            bundleURL: URL(fileURLWithPath: "/Applications/AppTranslocation.app/PersonaStack.app"),
            volumeIsReadOnly: false
        ))
    }
}
