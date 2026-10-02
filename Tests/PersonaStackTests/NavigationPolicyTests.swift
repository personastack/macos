import Foundation
import Testing
@testable import PersonaStackCore

struct NavigationPolicyTests {
    @Test(arguments: ["file:///Applications/Calculator.app", "ssh://example.invalid", "javascript:alert(1)", "x-man-page://ls"])
    func webLinksCannotLaunchLocalFilesOrArbitraryHandlers(_ value: String) throws {
        let url = try #require(URL(string: value))
        #expect(!NavigationPolicy.canOpenExternally(url))
        #expect(!NavigationPolicy.canLoadInWebView(url))
        #expect(!NavigationPolicy.shouldOpenInDefaultBrowser(url, linkWasUserActivated: true,
                                                            appURL: URL(string: "https://desktop.example")!))
    }

    @Test func normalLinksOAuthAndInPageResourcesKeepTheirExpectedRouting() throws {
        let app = try #require(URL(string: "https://desktop.example/user/personas"))
        for value in ["https://example.invalid/page", "http://example.invalid/page", "mailto:support@example.invalid"] {
            let url = try #require(URL(string: value))
            #expect(NavigationPolicy.canOpenExternally(url))
            #expect(NavigationPolicy.shouldOpenInDefaultBrowser(url, linkWasUserActivated: true, appURL: app))
            #expect(!NavigationPolicy.shouldOpenInDefaultBrowser(url, linkWasUserActivated: false, appURL: app))
        }
        for value in [app.absoluteString, "blob:https://desktop.example/image", "data:text/plain,preview", "about:blank"] {
            #expect(NavigationPolicy.canLoadInWebView(try #require(URL(string: value))))
        }
        #expect(!NavigationPolicy.shouldOpenInDefaultBrowser(app, linkWasUserActivated: true, appURL: app))
        #expect(NavigationPolicy.isGoogleOAuthURL(URL(string: "https://accounts.google.com/o/oauth2/auth")!))
        let credentialURL = URL(string: "https://user:password@accounts.google.com/o/oauth2/auth")!
        #expect(!NavigationPolicy.isGoogleOAuthURL(credentialURL))
        #expect(!NavigationPolicy.canOpenExternally(credentialURL))
        #expect(!NavigationPolicy.canLoadInWebView(credentialURL))
    }

    @Test(arguments: [
        "https://desktop.example/user/personas/chat/media/file?download=1",
        "blob:https://desktop.example/attachment",
        "blob:https://desktop.example:443/attachment",
    ])
    func explicitDownloadsStayInTheSelectedApp(_ rawURL: String) throws {
        let app = try #require(URL(string: "https://desktop.example/user/personas"))
        let download = try #require(URL(string: rawURL))
        #expect(NavigationPolicy.shouldDownload(download, requested: true, appURL: app))
        #expect(!NavigationPolicy.shouldDownload(download, requested: false, appURL: app))
    }

    @Test(arguments: [
        "https://foreign.example/file", "blob:https://foreign.example/file",
        "blob:http://desktop.example/file", "blob:https://desktop.example:444/file",
        "blob:null/file", "file:///tmp/file", "https://user:password@desktop.example/file",
    ])
    func downloadPolicyPreservesExternalAndInvalidOriginBoundaries(_ rawURL: String) throws {
        let app = try #require(URL(string: "https://desktop.example/user/personas"))
        let download = try #require(URL(string: rawURL))
        #expect(!NavigationPolicy.shouldDownload(download, requested: true, appURL: app))
    }

    @Test
    func usesValidatedPackagedDefaultURL() {
        let url = LaunchConfiguration.url(
            arguments: ["PersonaStack"],
            packagedDefaultURL: "https://personastack.ericgreer.info/user/personas"
        )

        #expect(url == URL(string: "https://personastack.ericgreer.info/user/personas")!)
    }

    @Test
    func fallsBackWhenPackagedDefaultURLIsInvalid() {
        let url = LaunchConfiguration.url(arguments: ["PersonaStack"], packagedDefaultURL: "file:///tmp/test")

        #expect(url == NavigationPolicy.defaultURL)
    }

    @Test
    func commandLineOverrideWinsOverPackagedDefaultURL() {
        let url = LaunchConfiguration.url(
            arguments: ["PersonaStack", "--personastack-url", "https://personastack.ericgreer.info/user/integrations"],
            packagedDefaultURL: "https://my.personastack.ai/user/personas"
        )

        #expect(url == URL(string: "https://personastack.ericgreer.info/user/integrations")!)
    }

    @Test
    func inAppNavigationRequiresTheSelectedExactOrigin() {
        let selected = URL(string: "https://desktop.example:443/user/personas")!

        #expect(NavigationPolicy.keepsInApp(URL(string: "https://desktop.example:443/user/integrations")!, appURL: selected))
        #expect(!NavigationPolicy.keepsInApp(URL(string: "http://desktop.example/user/personas")!, appURL: selected))
        #expect(!NavigationPolicy.keepsInApp(URL(string: "https://desktop.example:444/user/personas")!, appURL: selected))
        #expect(!NavigationPolicy.keepsInApp(URL(string: "https://my.personastack.ai/user/personas")!, appURL: selected))
    }
}
