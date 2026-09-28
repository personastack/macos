import Foundation
import Testing
@testable import PersonaStackCore

struct NavigationPolicyTests {
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
