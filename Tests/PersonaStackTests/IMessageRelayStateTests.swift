import Foundation
import Testing
import PersonaStackCore

@Test func iMessageRelayStateKeepsEachCapabilityIndependent() throws {
    for desktopActive in [false, true] {
        for desktopExists in [false, true] {
            for iMessageActive in [false, true] {
                for iMessageExists in [false, true] {
                    let payload = try JSONSerialization.data(withJSONObject: [
                        "has_active_config": desktopActive, "has_config": desktopExists,
                        "has_active_imessage_config": iMessageActive, "has_imessage_config": iMessageExists,
                    ])
                    if (desktopActive && !desktopExists) || (iMessageActive && !iMessageExists) {
                        #expect(throws: (any Error).self) { try JSONDecoder().decode(DesktopControlConfigurationState.self, from: payload) }
                    } else {
                        let state = try JSONDecoder().decode(DesktopControlConfigurationState.self, from: payload)
                        #expect(state.hasConfig == desktopExists && state.hasActiveConfig == desktopActive)
                        #expect(state.hasIMessageConfig == iMessageExists && state.hasActiveIMessageConfig == iMessageActive)
                        #expect(state.hasActiveRelayCapability == (desktopActive || iMessageActive))
                    }
                }
            }
        }
    }
}

@Test func iMessageRelayStateAcceptsLegacyDesktopResponsesAndInitializers() throws {
    let legacy = try JSONDecoder().decode(DesktopControlConfigurationState.self, from: Data(#"{"has_active_config":true,"has_config":true}"#.utf8))
    #expect(legacy.hasActiveRelayCapability)
    #expect(!legacy.hasIMessageConfig && !legacy.hasActiveIMessageConfig)
    let compatible = DesktopControlConfigurationState(hasActiveConfig: false, hasConfig: true)
    #expect(!compatible.hasActiveRelayCapability && !compatible.hasIMessageConfig)
}

@Test(arguments: [
    #"{}"#,
    #"{"has_active_config":false,"has_config":false,"has_active_imessage_config":true}"#,
    #"{"has_active_config":false,"has_config":false,"has_active_imessage_config":null,"has_imessage_config":true}"#,
    #"{"has_active_config":false,"has_config":false,"has_imessage_config":null}"#,
    #"{"has_active_config":false,"has_config":false,"has_active_imessage_config":"true","has_imessage_config":true}"#,
    #"{"has_active_config":false,"has_config":null}"#,
]) func iMessageRelayStateFailsClosedOnMalformedFields(payload: String) {
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(DesktopControlConfigurationState.self, from: Data(payload.utf8))
    }
}
