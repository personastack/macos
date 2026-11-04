import AppKit
import IMessageBridgeProbe
import PersonaStackCore
import SwiftUI

/// Entered only through the exact local --imessage-provider-probe argument.
/// This uses the real app identity and never starts the hosted integration runtime.
@MainActor
struct IMessageProviderProbeApp: App {
    @NSApplicationDelegateAdaptor(IMessageProbeTerminationDelegate.self) private var termination
    @StateObject private var model = IMessageProviderProbeModel()

    var body: some Scene {
        Window("iMessage Provider Check", id: "imessage-provider-probe") {
            IMessageProviderProbeRoot(model: model)
                .preferredColorScheme(.dark)
                .onAppear { termination.installShutdown { [model] in await model.shutdown() } }
        }
        .defaultSize(width: 640, height: 580)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@MainActor
final class IMessageProbeTerminationDelegate: NSObject, NSApplicationDelegate {
    private var shutdown: @MainActor () async -> Void
    private let terminate: @MainActor (NSApplication) -> Void
    private enum Phase { case idle, cleaning, admitted }
    private var phase = Phase.idle

    override convenience init() {
        self.init(shutdown: {}, terminate: { $0.terminate(nil) })
    }

    init(shutdown: @escaping @MainActor () async -> Void,
         terminate: @escaping @MainActor (NSApplication) -> Void) {
        self.shutdown = shutdown
        self.terminate = terminate
        super.init()
    }

    func installShutdown(_ shutdown: @escaping @MainActor () async -> Void) {
        guard phase == .idle else { return }
        self.shutdown = shutdown
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if phase == .admitted { return .terminateNow }
        guard phase == .idle else { return .terminateCancel }
        phase = .cleaning
        Task { @MainActor in
            await shutdown()
            phase = .admitted
            terminate(sender)
        }
        // Keep the normal run loop alive while MainActor cleanup joins the
        // provider. AppKit's terminateLater loop can starve that cleanup Task.
        return .terminateCancel
    }
}

@MainActor
private final class IMessageProviderProbeModel: ObservableObject {
    @Published var query = ""
    @Published var selectedID: String?
    @Published private(set) var conversations: [IMessageConversation] = []
    @Published private(set) var selected: IMessageConversation?
    @Published private(set) var loaded = false
    @Published private(set) var hasMore = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var coordinator: ProbeCoordinator?

    private let client = IMessageRPCClient(transport: IMessageSubprocessTransport(bundle: .main))
    private let accountReader = IMessageAccountReader()
    private var started = false
    private var next: IMessageRowID?
    private var upper: IMessageRowID?
    private var snapshotCreatedAt: Date?
    private var activeQuery = ""
    private var generation = 0
    private var work: Task<Void, Never>?

    func loadConversations(reset: Bool) {
        guard !busy, query.count <= 128 else { return }
        generation += 1
        let expectedGeneration = generation
        busy = true
        message = nil
        let requestedQuery = reset ? query : activeQuery
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == expectedGeneration { self.busy = false } }
            do {
                if !self.started {
                    try await self.accountReader.prepareProviderConnection(self.client)
                    _ = try await self.client.start()
                    self.started = true
                }
                try await self.accountReader.validateProviderConnection()
                if !reset, self.snapshotCreatedAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true {
                    self.message = "The conversation list expired. Search again."
                    return
                }
                let after: IMessageRowID
                if reset { after = try IMessageRowID(0) }
                else if let next = self.next { after = next }
                else { throw IMessageRPCError.invalidArguments }
                let page = try await self.client.conversations(
                    after: after, upper: reset ? nil : self.upper, query: requestedQuery, limit: 50
                )
                guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                self.conversations = page.chats
                self.next = page.nextChatRowID
                self.upper = page.upperChatRowID
                self.hasMore = page.hasMore
                self.loaded = true
                if reset { self.snapshotCreatedAt = Date(); self.activeQuery = requestedQuery }
                if page.chats.isEmpty { self.message = page.hasMore ? "Continue to the next page." : "No matching conversations." }
            } catch {
                if self.generation == expectedGeneration {
                    self.message = self.safeMessage(error)
                    await self.stopInvalidProvider(error)
                }
            }
        }
    }

    func select(_ id: String?) {
        guard !busy, coordinator == nil else {
            selectedID = selected?.id.rawValue
            return
        }
        if let chat = conversations.first(where: { $0.id.rawValue == id }) { selected = chat }
    }

    func verifySelectedConversation() {
        guard !busy, coordinator == nil, let chat = selected, chat.available else { return }
        guard snapshotCreatedAt.map({ Date().timeIntervalSince($0) <= 300 }) ?? false else {
            message = "The conversation list expired. Search again."
            return
        }
        generation += 1
        let expectedGeneration = generation
        busy = true
        message = nil
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == expectedGeneration { self.busy = false } }
            do {
                let reader = self.accountReader
                let live = try await reader.observe(chatGUIDs: [chat.guid], requestAutomation: true)
                let accountID = live.accountID
                guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                let target = ProbeTarget(conversationID: chat.id.rawValue, accountID: accountID,
                                         sourceGeneration: live.sourceGeneration, displayName: Self.reviewLabel(chat))
                let backend = CoreProbeBackend(client: self.client, target: target) { request in
                    let account = try await reader.observe(chatGUIDs: [chat.guid], expectedAccountID: accountID, requestAutomation: request)
                    return ProbeLiveAccount(accountID: account.accountID, sourceGeneration: account.sourceGeneration, liveChatGUID: chat.guid)
                }
                let probe = ProbeCoordinator(backend: backend, target: target)
                _ = await probe.checkPrerequisites()
                guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                self.coordinator = probe
            } catch {
                if self.generation == expectedGeneration {
                    self.message = self.safeMessage(error)
                    await self.stopInvalidProvider(error)
                }
            }
        }
    }

    func shutdown() async {
        generation += 1
        let pendingWork = work
        pendingWork?.cancel()
        work = nil
        _ = await coordinator?.cancel()
        await client.stop()
        await pendingWork?.value
        await accountReader.clearProviderBinding()
    }

    static func label(_ chat: IMessageConversation) -> String {
        if !chat.name.isEmpty { return String(chat.name.prefix(256)) }
        let participants = chat.participants.joined(separator: ", ")
        return participants.isEmpty ? "Unnamed conversation" : String(participants.prefix(256))
    }

    static func reviewLabel(_ chat: IMessageConversation) -> String {
        guard !chat.name.isEmpty, !chat.participants.isEmpty else { return label(chat) }
        let handles = chat.participants.prefix(3).joined(separator: ", ")
        return String("\(chat.name) (\(handles))".prefix(256))
    }

    private func stopInvalidProvider(_ error: Error) async {
        let accountError = error as? IMessageAccountError
        guard error is IMessageRPCError || accountError == .sourceChanged || accountError == .sourceUnavailable else { return }
        await client.stop()
        await accountReader.clearProviderBinding()
        started = false
        if accountError == .sourceChanged {
            selected = nil
            selectedID = nil
            conversations = []
            loaded = false
            hasMore = false
            next = nil
            upper = nil
        }
    }

    private func safeMessage(_ error: Error) -> String {
        if let account = error as? IMessageAccountError { return account.safeMessage }
        if let rpc = error as? IMessageRPCError, rpc == .dependencyInvalid {
            return "The signed app needs its pinned iMessage adapter."
        }
        return "Messages could not be checked. Verify the adapter and Full Disk Access, then retry."
    }
}

@MainActor
private struct IMessageProviderProbeRoot: View {
    @ObservedObject var model: IMessageProviderProbeModel

    var body: some View {
        Group {
            if let coordinator = model.coordinator {
                IMessageBridgeProbeView(coordinator: coordinator)
            } else {
                picker
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("iMessage Provider Check").font(.title2.bold())
            Text("Choose the approved test conversation.")
            if model.loaded {
                HStack {
                    TextField("Name or participant", text: $model.query)
                        .disabled(model.busy)
                        .onSubmit { model.loadConversations(reset: true) }
                    Button("Search") { model.loadConversations(reset: true) }
                        .disabled(model.busy || model.query.count > 128)
                    Button("Next") { model.loadConversations(reset: false) }
                        .disabled(model.busy || !model.hasMore)
                }
                List(selection: $model.selectedID) {
                    ForEach(model.conversations, id: \.id.rawValue) { conversation in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(IMessageProviderProbeModel.label(conversation))
                            if !conversation.name.isEmpty {
                                Text(String(conversation.participants.prefix(3).joined(separator: ", ").prefix(256)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(conversation.isGroup ? "Group · \(conversation.participants.count) participants" : "Direct conversation")
                                .font(.caption).foregroundStyle(.secondary)
                            if !conversation.available { Text("Unavailable").font(.caption).foregroundStyle(.secondary) }
                        }
                        .tag(conversation.id.rawValue)
                    }
                }
                .disabled(model.busy)
                .onChange(of: model.selectedID) { _, value in model.select(value) }
                if let selected = model.selected {
                    Text("Selected: \(IMessageProviderProbeModel.reviewLabel(selected))")
                    Button("Verify Messages") { model.verifySelectedConversation() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || !selected.available)
                }
            } else {
                Button("Load conversations") { model.loadConversations(reset: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
            }
            if model.busy { ProgressView() }
            if let message = model.message { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("imessage-probe-feedback") }
            HStack {
                Button("Open Messages") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Messages.app")) }
                Button("Full Disk Access") { openSettings("Privacy_AllFiles") }
                Button("Automation Settings") { openSettings("Privacy_Automation") }
            }
        }
        .padding(24)
    }

    private func openSettings(_ section: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(section)") else { return }
        NSWorkspace.shared.open(url)
    }
}
