import PersonaStackCore
import ServiceManagement

extension AgentBridgeService: AgentBridgeUpdateLifecycle {
    var hasRegisteredService: Bool { status == .enabled || status == .requiresApproval }
    var canQuiesce: Bool { status == .enabled }
}

extension AgentBridgeUpdateHandoff {
    static let shared = AgentBridgeUpdateHandoff(service: AgentBridgeService.shared)
}
