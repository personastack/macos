import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

@Suite @MainActor struct AgentBridgeNativeAgentChoiceTests {
    private func profile(_ agents: String, selected: String = "") throws -> AgentBridgeProfile {
        let json = "{\"profile_candidate_id\":\"rt_profile\",\"account_candidate_id\":\"rt_account\",\"label\":\"Work profile\",\"runtime_kind\":\"openclaw\",\"openclaw_agents\":\(agents),\"selected_agent_candidate_id\":\"\(selected)\"}"
        return try JSONDecoder().decode(AgentBridgeProfile.self, from: Data(json.utf8))
    }
    @Test func soleNonMainAgentAndExistingChoiceDoNotPrompt() throws {
        let sole = try profile(#"[{"agent_candidate_id":"rt_research","label":"Research"}]"#)
        #expect(try AgentBridgeSetupManager.selectNativeAgent(sole, picker: { _, _ in Issue.record("Sole agent prompted"); return nil }) == "rt_research")
        let bound = try profile(#"[{"agent_candidate_id":"rt_research","label":"Research"},{"agent_candidate_id":"rt_writer","label":"Writer"}]"#, selected: "rt_writer")
        #expect(try AgentBridgeSetupManager.selectNativeAgent(bound, picker: { _, _ in Issue.record("Existing choice prompted"); return nil }) == "rt_writer")
    }
    @Test func ambiguousChoiceRequiresNativePickerAndDeniesCancelledOrForeignChoice() throws {
        let multiple = try profile(#"[{"agent_candidate_id":"rt_research","label":"Research"},{"agent_candidate_id":"rt_writer","label":"Writer"}]"#)
        #expect(try AgentBridgeSetupManager.selectNativeAgent(multiple, picker: { label, agents in
            #expect(label == "Work profile"); #expect(agents.count == 2); return "rt_writer"
        }) == "rt_writer")
        for choice in [nil, "main", "rt_other"] as [String?] {
            #expect(throws: AgentBridgeFailure.runtimeConflict) { _ = try AgentBridgeSetupManager.selectNativeAgent(multiple, picker: { _, _ in choice }) }
        }
        #expect(throws: AgentBridgeFailure.runtimeConflict) { _ = try AgentBridgeSetupManager.selectNativeAgent(try profile("[]"), picker: { _, _ in "main" }) }
    }
}
