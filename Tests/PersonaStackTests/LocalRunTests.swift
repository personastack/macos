import Foundation
import Testing
@testable import PersonaStackCore

struct LocalRunTests {
    let session = "3e1c2ad4-1a53-4a5a-9868-1ce1bc2b19d1"
    let digest = String(repeating: "a", count: 64)

    func fixture() throws -> LocalRunBundle {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let object: [String: Any] = [
            "version": 1, "protocol_version": 1, "session_id": session,
            "persona_id": "persona-one", "persona_name": "Test", "workspace_id": "ws_test", "stack_id": "stack",
            "worker_image": "ghcr.io/personastack/codex-worker:1.2.3", "provider": "openai", "model": "model",
            "issued_at": formatter.string(from: now), "expires_at": formatter.string(from: now.addingTimeInterval(3600)),
            "mcp_url": "https://mcp.example.test/v1/mcp", "bearer_token": String(repeating: "b", count: 64),
            "persona_prompt": "Test instructions", "skills": [],
            "environment": [["name": "PERSONA_BEARER_TOKEN", "value": "secret-canary"]],
            "files": [["path": "/var/run/personastack-prompt/prompt", "content": "Test instructions", "digest": LocalRunBundle.digest("Test instructions"), "mode": 384]],
            "command": ["/opt/personastack/bin/personastack-audit-filter", "--", "/bin/sh", "-c", "worker"], "companions": []
        ]
        return try LocalRunBundle.decode(JSONSerialization.data(withJSONObject: object), sessionID: session, personaID: "persona-one", mcpURL: URL(string: "https://mcp.example.test/v1/mcp")!)
    }
    private func inspection(_ reference: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [["configuration": ["name": reference, "descriptor": ["digest": "sha256:" + digest]],
                                                   "variants": [["platform": ["os": "linux", "architecture": "arm64"]]]]])
    }

    @Test func localRunBundleRejectsTamperedFilesAndWrongPersona() throws {
        var bundle = try fixture()
        #expect(throws: LocalRunError.invalidBundle) {
            try bundle.validate(sessionID: session, personaID: "other", mcpURL: URL(string: bundle.mcp_url)!)
        }
        bundle.files[0].content = "changed"
        #expect(throws: LocalRunError.invalidBundle) {
            try bundle.validate(sessionID: session, personaID: bundle.persona_id, mcpURL: URL(string: bundle.mcp_url)!)
        }
    }

    @Test(arguments: ["/workspace", "/workspace/private", "/host", "/host/private", "/run/personastack-local-bootstrap/bootstrap"])
    func localRunArtifactsCannotWriteHostOrBootstrap(path: String) throws {
        var bundle = try fixture()
        bundle.files[0].path = path
        #expect(throws: LocalRunError.invalidBundle) {
            try bundle.validate(sessionID: session, personaID: bundle.persona_id, mcpURL: URL(string: bundle.mcp_url)!)
        }
    }

    @Test func localRunBuildKitWaitsForSocketAndUsesGuestCapabilitiesOnly() async throws {
        var bundle = try fixture()
        bundle.companions = [LocalRunCompanion(kind: "buildkit", image: "ghcr.io/personastack/buildkit:1.2.3", command: ["buildkitd", "--addr", "unix:///run/buildkit/buildkitd.sock"], environment: [])]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-run-test-" + UUID().uuidString)
        let layout = LocalRunContainerLayout(root: root, workspace: root.deletingLastPathComponent(), sessionID: session)
        let fake = LocalRunBuildKitFixture()
        let runtime = LocalRunContainer(command: { try await fake.run($0) }, networking: { _, _ in }, socketReady: { try await fake.ready($0) })
        try await runtime.start(bundle: bundle, layout: layout, secret: "secret")
        try await runtime.stop()
        let commands = await fake.commands
        let companion = try #require(commands.first(where: { $0.first == "run" && $0.contains(layout.name + "-buildkit") }))
        #expect(companion.contains("--cap-add") && companion.contains("ALL"))
        #expect(!companion.contains("--volume"))
        let worker = try #require(commands.first(where: { $0.first == "run" && $0.contains(layout.name) }))
        #expect(!worker.contains("--cap-add"))
        #expect(worker.contains(root.appendingPathComponent("buildkit.sock").path + ":/run/personastack/buildkit.sock"))
        #expect(await fake.socketReady)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func localRunFramesHandleSplitLinesAndFenceSessions() throws {
        var decoder = LocalRunFrameDecoder(sessionID: session)
        let frame = LocalRunFrame(type: "text", sessionID: session, text: "hello")
        let data = try frame.encoded()
        #expect(try decoder.append(data.prefix(8)).isEmpty)
        #expect(try decoder.append(data.dropFirst(8)) == [frame])
        let foreign = LocalRunFrame(type: "text", sessionID: "another", text: "must reject")
        #expect(throws: LocalRunError.invalidFrame) { try decoder.append(foreign.encoded()) }
    }

    @Test func localRunFramesRejectOversizeAndVersionMismatch() throws {
        var decoder = LocalRunFrameDecoder(sessionID: session)
        #expect(throws: LocalRunError.invalidFrame) { try decoder.append(Data(repeating: 65, count: LocalRunFrameDecoder.maximumFrameBytes + 1)) }
        var frame = LocalRunFrame(type: "ready", sessionID: session)
        frame.version = 2
        var other = LocalRunFrameDecoder(sessionID: session)
        #expect(throws: LocalRunError.invalidFrame) { try other.append(frame.encoded()) }
    }

    @Test func localRunImageResolutionRequiresApprovedReferenceAndARM64() throws {
        let reference = "ghcr.io/personastack/codex-worker:1.2.3"
        #expect(try LocalRunContainer.resolvedDigest(reference: reference, inspection: inspection(reference)) == "ghcr.io/personastack/codex-worker@sha256:" + digest)
        #expect(throws: LocalRunError.invalidBundle) { try LocalRunContainer.resolvedDigest(reference: reference, inspection: inspection("other/repository:1.2.3")) }
        #expect(!LocalRunBundle.validImage("ghcr.io/personastack/codex-worker:latest"))
        #expect(LocalRunBundle.validImage(reference))
    }

    @Test func localRunLaunchKeepsSecretsOffArgumentsAndPreservesHostMounts() throws {
        let bundle = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-run-test-" + UUID().uuidString)
        let layout = LocalRunContainerLayout(root: root, workspace: URL(fileURLWithPath: "/Users/Test User/project"), sessionID: session)
        try LocalRunContainer.materialize(bundle: bundle, layout: layout, secret: "socket-secret-canary")
        defer { try? FileManager.default.removeItem(at: root) }
        let args = LocalRunContainer.arguments(bundle: bundle, layout: layout)
        #expect(args.contains("/Users/Test User/project:/workspace"))
        #expect(args.contains("/:/host"))
        #expect(!args.joined().contains("secret-canary"))
        #expect(args.contains("--entrypoint"))
        #expect(args[args.firstIndex(of: "--uid")! + 1] == "0")
        #expect(args[args.firstIndex(of: "--gid")! + 1] == "0")
        #expect(args.contains(root.appendingPathComponent("files").path + ":" + LocalRunContainer.guestArtifacts + ":ro"))
        #expect(!args.contains(where: { $0.contains(":/var/run/personastack-prompt/prompt") }))
        let bootstrap = try String(contentsOf: root.appendingPathComponent("files/bootstrap"), encoding: .utf8)
        #expect(bootstrap.contains("chmod 600 -- '/var/run/personastack-prompt/prompt'"))
        #expect(bootstrap.hasSuffix("exec \"$@\"\n"))
        #expect(!bootstrap.contains("secret-canary"))
        #expect(args.suffix(3) == ["/bin/sh", "-c", "worker"])
        let attributes = try FileManager.default.attributesOfItem(atPath: layout.environment.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let environment = try String(contentsOf: layout.environment, encoding: .utf8)
        #expect(environment.contains("PERSONASTACK_WORKER_EXECUTION_MODE=desktop_local"))
        #expect(environment.contains("PERSONASTACK_REGISTER_NATIVE_SESSION=false"))
    }

    @Test func localRunSupervisorUsesOnlyOwnedContainerAndStopsBeforeDeletingFiles() async throws {
        let bundle = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-run-test-" + UUID().uuidString)
        let layout = LocalRunContainerLayout(root: root, workspace: root.deletingLastPathComponent(), sessionID: session)
        let fake = LocalRunCommandFixture(inspection: try inspection(bundle.worker_image))
        let runtime = LocalRunContainer(command: { try await fake.run($0) }, networking: { _, _ in })
        try await runtime.start(bundle: bundle, layout: layout, secret: "secret")
        try await runtime.stop()
        let commands = await fake.commands
        #expect(commands[0] == ["image", "pull", "--platform", "linux/arm64", bundle.worker_image])
        #expect(commands[2].contains("ghcr.io/personastack/codex-worker@sha256:" + digest))
        #expect(commands[3] == ["stop", "--time", "5", layout.name])
        #expect(commands[4] == ["delete", layout.name])
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func localRunCloseDuringImagePullCannotLaunchLateContainer() async throws {
        let bundle = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-run-test-" + UUID().uuidString)
        let layout = LocalRunContainerLayout(root: root, workspace: root.deletingLastPathComponent(), sessionID: session)
        let fake = LocalRunDelayedImageFixture()
        let runtime = LocalRunContainer(command: { try await fake.run($0) }, networking: { _, _ in })
        let launch = Task { try await runtime.start(bundle: bundle, layout: layout, secret: "secret") }
        await fake.waitForPull()
        try await runtime.stop()
        await fake.release()
        await #expect(throws: LocalRunError.staleSession) { try await launch.value }
        #expect(await fake.commands.count == 1)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

private actor LocalRunCommandFixture {
    let inspection: Data
    var commands: [[String]] = []
    init(inspection: Data) { self.inspection = inspection }
    func run(_ args: [String]) throws -> LocalRunCommandResult {
        commands.append(args)
        guard ["image", "run", "stop", "delete"].contains(args[0]) else { throw LocalRunError.invalidFrame }
        return LocalRunCommandResult(status: 0, output: args.prefix(2) == ["image", "inspect"] ? inspection : Data())
    }
}

private actor LocalRunDelayedImageFixture {
    var commands: [[String]] = []
    var pull: CheckedContinuation<Void, Never>?
    var observer: CheckedContinuation<Void, Never>?
    func run(_ args: [String]) async throws -> LocalRunCommandResult {
        commands.append(args)
        guard args.prefix(2) == ["image", "pull"] else { throw LocalRunError.invalidFrame }
        await withCheckedContinuation { continuation in
            pull = continuation; observer?.resume(); observer = nil
        }
        return LocalRunCommandResult(status: 0)
    }
    func waitForPull() async {
        if pull != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { pull?.resume(); pull = nil }
}

private actor LocalRunBuildKitFixture {
    var commands: [[String]] = []
    var socketReady = false
    func ready(_ path: URL) throws {
        guard path.lastPathComponent == "buildkit.sock" else { throw LocalRunError.invalidFrame }
        socketReady = true
    }
    func run(_ args: [String]) throws -> LocalRunCommandResult {
        commands.append(args)
        guard ["image", "run", "stop", "delete"].contains(args[0]) else { throw LocalRunError.invalidFrame }
        if args.first == "run", !args.contains("--cap-add"), !socketReady { throw LocalRunError.invalidFrame }
        let data: Data
        if args.prefix(2) == ["image", "inspect"] {
            data = try JSONSerialization.data(withJSONObject: [["configuration": ["name": args[2], "descriptor": ["digest": "sha256:" + String(repeating: "a", count: 64)]], "variants": [["platform": ["os": "linux", "architecture": "arm64"]]]]])
        } else { data = Data() }
        return LocalRunCommandResult(status: 0, output: data)
    }
}
