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
}
