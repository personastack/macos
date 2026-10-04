import AppKit
import Combine
import PersonaStackCore
import SwiftUI

protocol LocalRunTransport: Sendable {
    func connect(path: String, sessionID: String, secret: String) async throws -> AsyncThrowingStream<LocalRunFrame, Error>
    func send(_ frame: LocalRunFrame) throws
    func close()
}

extension LocalRunSocket: LocalRunTransport {}

struct LocalRunTranscriptItem: Identifiable {
    let id: String
    var kind: String
    var text: String
    var tool: LocalRunTool?
    var control: LocalRunControl?
    var requestID: String?
    var answered = false
    var closed = false
}

@MainActor
final class LocalRunViewModel: ObservableObject {
    @Published var personaName = "Persona"
    @Published var status = "Preparing local agent…"
    @Published var items: [LocalRunTranscriptItem] = []
    @Published var draft = ""
    @Published var ready = false
    @Published var busy = false
    @Published var closing = false
    @Published var failure: String?
    @Published var transcriptTrimmed = false
    @Published var followingOutput = true
    @Published var controlText: [String: String] = [:]
    @Published var questionText: [String: String] = [:]
    @Published var questionSelections: [String: Set<String>] = [:]
    let sessionID: String
    let workspace: URL
    private var turnID: String?
    private let runtime: LocalRunContainer
    private let socket: any LocalRunTransport
    private let host: LocalRunHostExecutor
    private let redeemBundle: @Sendable (URL, String, String, String, String) async throws -> LocalRunBundle
    private let revokeBundle: @Sendable (URL, LocalRunBundle) async throws -> Void
    private var redemption: Task<LocalRunBundle, Error>?
    private var localStopped = false
    private var bundle: LocalRunBundle?
    private var appURL: URL?
    private var task: Task<Void, Never>?
    private var hostTasks: [String: Task<Void, Never>] = [:]
    private var generation = UUID()
    private var closeTask: Task<Bool, Never>?
    private var pendingReplies: [String: String] = [:]
    private var pendingStartRequestID: String?
    private var pendingInterruptRequestID: String?

    init(sessionID: String, workspace: URL, runtime: LocalRunContainer = LocalRunContainer(),
         socket: any LocalRunTransport = LocalRunSocket(),
         redeem: @escaping @Sendable (URL, String, String, String, String) async throws -> LocalRunBundle = { try await LocalRunAPI.redeem(appURL: $0, personaID: $1, sessionID: $2, ticket: $3, verifier: $4) },
         revoke: @escaping @Sendable (URL, LocalRunBundle) async throws -> Void = { try await LocalRunAPI.revoke(appURL: $0, bundle: $1) }) {
        self.sessionID = sessionID; self.workspace = workspace; self.runtime = runtime
        self.socket = socket
        redeemBundle = redeem; revokeBundle = revoke
        host = LocalRunHostExecutor(workspace: workspace)
    }

    func start(appURL: URL, personaID: String, ticket: String, verifier: String) {
        self.appURL = appURL
        let generation = generation
        let redeem = redeemBundle
        let sessionID = sessionID
        let redemption = Task { try await redeem(appURL, personaID, sessionID, ticket, verifier) }
        self.redemption = redemption
        task = Task {
            do {
                let bundle = try await redemption.value
                // Close owns any late bundle while it awaits this same redemption.
                guard self.generation == generation else { return }
                self.redemption = nil
                self.bundle = bundle; personaName = bundle.persona_name
                status = "Starting local agent…"
                let secret = try LocalRunManager.randomSecret()
                // Darwin Unix sockets have a short path limit. UUID ownership and 0700
                // permissions keep this temporary runtime tree private.
                let layout = LocalRunContainerLayout(root: URL(fileURLWithPath: "/tmp/pslr-" + sessionID), workspace: workspace, sessionID: sessionID)
                try await runtime.start(bundle: bundle, layout: layout, secret: secret)
                guard self.generation == generation else { return }
                status = "Connecting to agent…"
                let stream = try await socket.connect(path: layout.socket.path, sessionID: sessionID, secret: secret)
                for try await event in stream {
                    guard self.generation == generation else { return }
                    receive(event)
                }
                if self.generation == generation {
                    fail(LocalRunError.connectionFailed.rawValue)
                    _ = await close()
                }
            } catch {
                guard self.generation == generation else { return }
                fail((error as? LocalRunError)?.rawValue ?? LocalRunError.startupFailed.rawValue)
                // Startup failure never leaves a running container behind an inert UI.
                _ = await close()
            }
        }
    }

    func send() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !closing, !message.isEmpty, message.utf8.count <= 256 * 1024 else { return }
        let id = turnID ?? UUID().uuidString.lowercased()
        do {
            let requestID = UUID().uuidString
            try socket.send(LocalRunFrame(type: busy ? "steer" : "send", sessionID: sessionID,
                                          requestID: requestID, turnID: id, text: message))
            if !busy { pendingStartRequestID = requestID }
            turnID = id; busy = true; status = "Working…"
            items.append(LocalRunTranscriptItem(id: UUID().uuidString, kind: "user", text: message))
            draft = ""
        } catch { fail(LocalRunError.connectionFailed.rawValue) }
    }
    func interrupt() {
        guard ready, busy, let turnID else { return }
        Task { await host.cancelActive() }
        do {
            let requestID = UUID().uuidString
            try socket.send(LocalRunFrame(type: "interrupt", sessionID: sessionID, requestID: requestID, turnID: turnID))
            pendingInterruptRequestID = requestID
            status = "Stopping turn…"
        } catch { fail(LocalRunError.connectionFailed.rawValue) }
    }
    func answer(itemID: String, optionID: String? = nil, text: String? = nil, answers: [LocalRunAnswer]? = nil) {
        guard let index = items.firstIndex(where: { $0.id == itemID }), !items[index].answered, !items[index].closed,
              let requestID = items[index].requestID, ready, !closing else { return }
        let reply = LocalRunReply(request_id: requestID, option_id: optionID, text: text, answers: answers)
        do {
            let commandID = UUID().uuidString
            try socket.send(LocalRunFrame(type: "reply", sessionID: sessionID, requestID: commandID, turnID: turnID, reply: reply))
            pendingReplies[commandID] = itemID
            items[index].answered = true
        } catch { fail(LocalRunError.connectionFailed.rawValue) }
    }

    func receive(_ event: LocalRunFrame) {
        guard event.session_id == sessionID, !closing, !localStopped else { return }
        switch event.type {
        case "ready": ready = true; status = "Ready"
        case "text", "commentary", "tool_start", "tool_update", "tool_result", "input_requested": upsert(event)
        case "turn_completed", "turn_interrupted":
            guard turnID == nil || event.turn_id == turnID else { return }
            if event.type == "turn_interrupted" { Task { await host.cancelActive() } }
            if let text = event.text, !text.isEmpty { upsert(event) }
            finishTurn(event.turn_id, status: event.type == "turn_interrupted" ? "Stopped" : "Ready")
        case "error":
            receiveError(event)
        case "host_request": executeHost(event)
        default: break
        }
    }

    private func receiveError(_ event: LocalRunFrame) {
        if let eventTurn = event.turn_id, let turnID, eventTurn != turnID { return }
        failure = event.text ?? "The agent could not complete that action."
        if let request = event.request_id {
            if let itemID = pendingReplies.removeValue(forKey: request),
               let index = items.firstIndex(where: { $0.id == itemID }) { items[index].answered = false }
            if request == pendingStartRequestID {
                finishTurn(turnID, status: "Ready")
            } else if request == pendingInterruptRequestID {
                pendingInterruptRequestID = nil
                status = busy ? "Working…" : "Ready"
            }
        } else if let failedTurn = event.turn_id {
            // The worker emits a turn failure without closing the session.
            finishTurn(failedTurn, status: "Ready")
        } else {
            finishTurn(turnID, status: "Agent unavailable")
            ready = false
        }
    }

    private func finishTurn(_ finishedTurn: String?, status: String) {
        if let finishedTurn {
            for index in items.indices where items[index].id.hasPrefix(finishedTurn + ":") && items[index].control != nil {
                items[index].closed = true
            }
        }
        pendingReplies.removeAll()
        pendingStartRequestID = nil; pendingInterruptRequestID = nil
        controlText.removeAll(); questionText.removeAll(); questionSelections.removeAll()
        busy = false; turnID = nil; self.status = status
    }

    private func upsert(_ event: LocalRunFrame) {
        let id = (event.turn_id ?? "session") + ":" + (event.event_id ?? event.request_id ?? UUID().uuidString)
        let item = LocalRunTranscriptItem(id: id, kind: event.type, text: event.text ?? "",
                                          tool: event.tool, control: event.control, requestID: event.request_id)
        if let index = items.firstIndex(where: { $0.id == id }) { items[index] = item }
        else { items.append(item) }
        var bytes = items.reduce(0) { $0 + $1.text.utf8.count + ($1.tool?.input?.utf8.count ?? 0) + ($1.tool?.output?.utf8.count ?? 0) + ($1.tool?.diff?.utf8.count ?? 0) }
        while items.count > 2000 || bytes > 16 * 1024 * 1024 {
            let removed = items.removeFirst()
            bytes -= removed.text.utf8.count + (removed.tool?.input?.utf8.count ?? 0) + (removed.tool?.output?.utf8.count ?? 0) + (removed.tool?.diff?.utf8.count ?? 0)
            transcriptTrimmed = true
        }
    }
    private func executeHost(_ event: LocalRunFrame) {
        guard let request = event.host, let requestID = event.request_id, hostTasks[requestID] == nil else { return }
        guard hostTasks.count < 4 else {
            try? socket.send(LocalRunFrame(type: "host_reply", sessionID: sessionID, requestID: UUID().uuidString,
                                          reply: LocalRunReply(request_id: requestID, stderr: "Four native commands are already running.", exit_code: 126)))
            return
        }
        let generation = generation
        hostTasks[requestID] = Task {
            let reply = await host.execute(request, requestID: requestID)
            defer { hostTasks.removeValue(forKey: requestID) }
            guard self.generation == generation else { return }
            try? socket.send(LocalRunFrame(type: "host_reply", sessionID: sessionID, requestID: UUID().uuidString, reply: reply))
        }
    }
    private func fail(_ message: String) { failure = message; ready = false; busy = false; status = "Agent unavailable" }

    func close() async -> Bool {
        if let closeTask { return await closeTask.value }
        closing = true; ready = false; generation = UUID(); status = "Stopping local agent…"
        controlText.removeAll(); questionText.removeAll(); questionSelections.removeAll(); pendingReplies.removeAll()
        let closeTask = Task { @MainActor in
            socket.close()
            for task in hostTasks.values { task.cancel() }
            let hostClosed = await host.close()
            do {
                try await runtime.stop()
                guard hostClosed else { throw LocalRunError.cleanupFailed }
                localStopped = true
            } catch {
                failure = LocalRunError.cleanupFailed.rawValue
                closing = false
                return false
            }
            // Keep the window as cleanup owner until an in-flight startup response
            // has either failed or supplied the credential we must revoke.
            if let redemption {
                if let received = try? await redemption.value { bundle = received }
                self.redemption = nil
            }
            do {
                if let bundle, let appURL { try await revokeBundle(appURL, bundle) }
                bundle = nil
                if failure == LocalRunError.revocationUnconfirmed.rawValue { failure = nil }
                status = "Closed"
                return true
            } catch {
                status = "Local agent stopped. Credential revocation unconfirmed."
                failure = LocalRunError.revocationUnconfirmed.rawValue
                closing = false
                return false
            }
        }
        self.closeTask = closeTask
        let success = await closeTask.value
        if !success { self.closeTask = nil }
        return success
    }
}

@MainActor
final class LocalRunWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: LocalRunViewModel
    private let onClose: () -> Void
    private var disposed = false
    init(sessionID: String, workspace: URL, onClose: @escaping () -> Void) {
        model = LocalRunViewModel(sessionID: sessionID, workspace: workspace)
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Local persona chat"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 390, height: 430)
        window.contentView = NSHostingView(rootView: LocalRunChatView(model: model))
        window.delegate = self
        window.center()
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x + CGFloat.random(in: -35...35), y: window.frame.origin.y + CGFloat.random(in: -35...35)))
    }
    func focus() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func start(appURL: URL, personaID: String, ticket: String, verifier: String) {
        model.start(appURL: appURL, personaID: personaID, ticket: ticket, verifier: verifier)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if disposed { return true }
        requestClose()
        return false
    }
    func requestClose() { Task { await closeSession() } }
    func closeSession() async {
        guard !disposed, await model.close(), !disposed else { return }
        disposed = true; window.close(); onClose()
    }
}

private struct LocalRunChatView: View {
    @ObservedObject var model: LocalRunViewModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "desktopcomputer")
                Text(model.personaName).font(.headline)
                Text("Local").font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule())
                Spacer()
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }.padding()
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.transcriptTrimmed { Text("Earlier output was trimmed to keep this window responsive.").font(.caption).foregroundStyle(.secondary) }
                        if model.items.isEmpty {
                            Text("Ask this persona to work on your Mac.").foregroundStyle(.secondary).padding(.top, 24)
                        }
                        ForEach(model.items) { item in
                            LocalRunTranscriptRow(item: item, model: model)
                        }
                        Color.clear.frame(height: 1).id("bottom").onAppear { model.followingOutput = true }.onDisappear { model.followingOutput = false }
                    }.padding(20)
                }
                .onChange(of: model.items.last?.text) { if model.followingOutput { reader.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: model.items.last?.tool) { if model.followingOutput { reader.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: model.items.count) { if model.followingOutput { reader.scrollTo("bottom", anchor: .bottom) } }
                .overlay(alignment: .bottomTrailing) {
                    if !model.followingOutput { Button("Latest", systemImage: "arrow.down") { model.followingOutput = true; reader.scrollTo("bottom", anchor: .bottom) }.padding() }
                }
            }
            if let failure = model.failure {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle")
                    Text(failure).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { model.failure = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss error")
                }.padding().foregroundStyle(.orange)
                if failure == LocalRunError.networkingUnavailable.rawValue {
                    Link("Host network setup", destination: URL(string: "https://github.com/apple/container/blob/1.4.1/docs/host-integration.md")!).padding(.bottom, 10)
                }
            }
            Divider()
            VStack(spacing: 8) {
                TextField("Message \(model.personaName)…", text: $model.draft, axis: .vertical)
                    .lineLimit(2...8).textFieldStyle(.plain).disabled(model.closing)
                    .onSubmit { model.send() }
                HStack {
                    Text(model.workspace.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(model.workspace.path)
                    Spacer()
                    if model.busy { Button("Stop", systemImage: "stop.fill") { model.interrupt() }.disabled(model.closing) }
                    Button(model.busy ? "Send follow-up" : "Send", systemImage: "arrow.up") { model.send() }
                        .buttonStyle(.borderedProminent).disabled(!model.ready || model.closing || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct LocalRunTranscriptRow: View {
    let item: LocalRunTranscriptItem
    @ObservedObject var model: LocalRunViewModel
    var body: some View {
        if let tool = item.tool {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    if let input = tool.input, !input.isEmpty { Text(input).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    if let path = tool.path { Text(path).font(.caption).textSelection(.enabled) }
                    if let output = tool.output, !output.isEmpty { Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    if let diff = tool.diff { Text(diff).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    if let error = tool.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    if let exit = tool.exit_code { Text("Exit status: \(exit)").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            } label: {
                Label(tool.title ?? tool.name ?? "Tool", systemImage: tool.status == "running" ? "gearshape" : tool.status == "failed" ? "xmark.circle" : "checkmark.circle")
                    .font(.callout).foregroundStyle(tool.status == "failed" ? Color.orange : Color.secondary)
            }.padding(12).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        } else if let control = item.control {
            LocalRunInputCard(item: item, control: control, model: model)
        } else if !item.text.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.kind == "user" ? "You" : model.personaName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(.init(item.text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(item.kind == "user" ? 12 : 0)
                .background(item.kind == "user" ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct LocalRunInputCard: View {
    let item: LocalRunTranscriptItem
    let control: LocalRunControl
    @ObservedObject var model: LocalRunViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(control.prompt ?? "The agent needs your input.").font(.callout.weight(.semibold))
            if let questions = control.questions, !questions.isEmpty {
                ForEach(questions, id: \.id) { question in
                    Text(question.prompt).font(.callout)
                    ForEach(question.options ?? [], id: \.id) { option in
                        Toggle(option.label, isOn: Binding(get: { model.questionSelections[key(question.id), default: []].contains(option.id) }, set: { checked in
                            if checked {
                                if question.multiple != true { model.questionSelections[key(question.id)] = [] }
                                model.questionSelections[key(question.id), default: []].insert(option.id)
                            } else { model.questionSelections[key(question.id), default: []].remove(option.id) }
                        }))
                    }
                    if question.allow_text == true {
                        if question.secret == true { SecureField("Answer", text: answerBinding(question.id)) }
                        else { TextField("Answer", text: answerBinding(question.id)) }
                    }
                }
                Button("Submit") {
                    model.answer(itemID: item.id, answers: questions.map { LocalRunAnswer(question_id: $0.id, option_ids: Array(model.questionSelections[key($0.id), default: []]).sorted(), text: model.questionText[key($0.id)]) })
                    for question in questions { model.questionText.removeValue(forKey: key(question.id)) }
                }.disabled(!questions.allSatisfy { !(model.questionSelections[key($0.id)] ?? []).isEmpty || !(model.questionText[key($0.id)] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            } else {
                ForEach(control.options ?? [], id: \.id) { option in
                    Button(option.label) { model.answer(itemID: item.id, optionID: option.id) }
                }
                if control.allow_text == true {
                    TextField("Answer", text: Binding(get: { model.controlText[item.id] ?? "" }, set: { model.controlText[item.id] = $0 }))
                    Button("Submit") { model.answer(itemID: item.id, text: model.controlText[item.id]); model.controlText.removeValue(forKey: item.id) }
                        .disabled((model.controlText[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if item.closed { Text("Turn finished").font(.caption).foregroundStyle(.secondary) }
            else if item.answered { Text("Response sent").font(.caption).foregroundStyle(.secondary) }
        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .disabled(item.answered || item.closed || !model.ready || model.closing)
    }
    private func key(_ question: String) -> String { item.id + ":" + question }
    private func answerBinding(_ question: String) -> Binding<String> {
        Binding(get: { model.questionText[key(question)] ?? "" }, set: { model.questionText[key(question)] = $0 })
    }
}
