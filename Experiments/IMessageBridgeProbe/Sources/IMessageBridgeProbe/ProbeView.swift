#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SwiftUI

/// Presented by the actual PersonaStack app's explicit diagnostic entrypoint.
/// The host supplies one already selected conversation and a real finite backend.
public struct IMessageBridgeProbeView: View {
    private let coordinator: ProbeCoordinator
    private var targetName: String { coordinator.approvedTargetDisplayName }
    @State private var evidence: ProbeEvidence?
    @State private var working = false
    @State private var receiptCopied = false
    @State private var actionTask: Task<Void, Never>?
    @State private var cleanupTask: Task<Void, Never>?
    @State private var pendingPhase: ProbePhase?

    public init(coordinator: ProbeCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("iMessage Provider Check").font(.title2.bold())
            LabeledContent("Conversation", value: targetName)
            HStack(spacing: 8) {
                Text(statusText).accessibilityIdentifier("imessage-probe-status")
                if working { ProgressView().controlSize(.small) }
            }
            if evidence?.phase == .readyToSend {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Send to \(targetName)").font(.headline)
                    Text(ProbeCoordinator.testText).textSelection(.enabled)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                primaryAction
                Button("Cancel") { cancelCurrent() }
                    .disabled(cleanupTask != nil || (evidence.map { [.localRecordConfirmed, .notSent, .outcomeUnknown, .cancelled].contains($0.phase) } ?? false))
                Spacer()
                Button(receiptCopied ? "Copied" : "Copy receipt") { copyReceipt() }
                    .disabled(evidence == nil || working)
            }
            Text("Local confirmation does not prove recipient delivery. Signature, lock and sleep checks need separate evidence.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 240)
        .task { evidence = await coordinator.snapshot() }
        .onDisappear { cancelCurrent() }
    }

    @ViewBuilder private var primaryAction: some View {
        switch evidence?.phase ?? .idle {
        case .idle, .needsAttention:
            Button("Verify Messages") { run(.checking) { await coordinator.checkPrerequisites() } }
                .buttonStyle(.borderedProminent)
                .disabled(working)
        case .readyToRead:
            Button("Read selected conversation") { run(.reading) { await coordinator.readSelectedConversation() } }
                .buttonStyle(.borderedProminent)
                .disabled(working)
        case .readyToSend:
            Button("Send one test message") { run(.sending) { await coordinator.sendOneConfirmedTestMessage() } }
                .buttonStyle(.borderedProminent)
                .disabled(working)
        default:
            EmptyView()
        }
    }

    private var statusText: String {
        if cleanupTask != nil { return "Cancelling…" }
        if working {
            switch pendingPhase {
            case .checking: return "Checking Messages…"
            case .reading: return "Reading the selected conversation…"
            case .sending: return "Sending…"
            default: break
            }
        }
        return switch evidence?.phase ?? .idle {
        case .idle: "Ready to check Messages."
        case .checking: "Checking Messages…"
        case .readyToRead: "Messages is ready. Approve a read of the selected conversation."
        case .reading: "Reading the selected conversation…"
        case .readyToSend: "Selected conversation verified. Review the test message before sending."
        case .sending: "Sending…"
        case .localRecordConfirmed: "Outgoing message found in Messages."
        case .notSent: "The test message was not sent."
        case .outcomeUnknown: "Outcome unknown. Check the conversation. Do not resend automatically."
        case .needsAttention:
            if evidence?.failure == .identityChanged || evidence?.failure == .continuityUnavailable {
                "Messages source continuity could not be verified. Close this check and review the connection again."
            } else {
                "Messages needs attention. Check permissions, account and adapter, then verify again."
            }
        case .cancelled: "Check cancelled."
        }
    }

    private func run(_ phase: ProbePhase, _ action: @escaping @Sendable () async -> ProbeEvidence) {
        guard actionTask == nil, cleanupTask == nil else { return }
        pendingPhase = phase
        working = true
        receiptCopied = false
        actionTask = Task { @MainActor in
            let result = await action()
            guard !Task.isCancelled else { return }
            evidence = result
            actionTask = nil
            pendingPhase = nil
            working = false
        }
    }

    private func cancelCurrent() {
        guard cleanupTask == nil else { return }
        actionTask?.cancel()
        working = true
        cleanupTask = Task { @MainActor in
            evidence = await coordinator.cancel()
            actionTask = nil
            pendingPhase = nil
            working = false
            cleanupTask = nil
        }
    }

    private func copyReceipt() {
        guard let evidence, let bytes = try? evidence.redactedJSON(),
              let text = String(data: bytes, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        receiptCopied = NSPasteboard.general.setString(text, forType: .string)
    }
}
#endif
