import Darwin
import Foundation

public struct LocalRunCommandResult: Sendable {
    public var status: Int32
    public var output: Data
    public init(status: Int32, output: Data = Data()) { self.status = status; self.output = output }
}

public typealias LocalRunContainerCommand = @Sendable ([String]) async throws -> LocalRunCommandResult

public struct LocalRunContainerLayout: Sendable {
    public let root: URL
    public let workspace: URL
    public let sessionID: String
    public var name: String { "personastack-local-" + sessionID.lowercased() }
    public var socket: URL { root.appendingPathComponent("agent.sock") }
    public var home: URL { root.appendingPathComponent("home") }
    public var environment: URL { root.appendingPathComponent("environment") }
    public init(root: URL, workspace: URL, sessionID: String) {
        self.root = root; self.workspace = workspace; self.sessionID = sessionID
    }
}

public actor LocalRunContainer {
    public static let executable = "/usr/local/bin/container"
    public static let guestSocket = "/tmp/personastack-local.sock"
    public static let guestArtifacts = "/run/personastack-local-bootstrap"
    private let command: LocalRunContainerCommand
    private let networking: @Sendable (String, LocalRunContainerCommand) async throws -> Void
    private let socketReady: @Sendable (URL) async throws -> Void
    private var layout: LocalRunContainerLayout?
    private var names: [String] = []
    private var stopping = false
    private var launching = false
    private var ownsRoot = false

    public init(command: @escaping LocalRunContainerCommand = LocalRunContainer.execute,
                networking: @escaping @Sendable (String, LocalRunContainerCommand) async throws -> Void = LocalRunContainer.probeNetworking,
                socketReady: @escaping @Sendable (URL) async throws -> Void = LocalRunContainer.waitForSocket) {
        self.command = command; self.networking = networking; self.socketReady = socketReady
    }

    public static func platformSupported(majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> Bool {
        #if arch(arm64)
        return majorVersion >= 26
        #else
        return false
        #endif
    }

    public func preflight() async throws {
        guard Self.platformSupported() else { throw LocalRunError.unsupported }
        guard FileManager.default.isExecutableFile(atPath: Self.executable) else { throw LocalRunError.runtimeMissing }
        let version = try await command(["--version"])
        guard version.status == 0, Self.supportsVersion(String(decoding: version.output, as: UTF8.self)) else { throw LocalRunError.runtimeMissing }
        guard try await command(["system", "status"]).status == 0 else { throw LocalRunError.runtimeUnavailable }
    }

    public static func supportsVersion(_ output: String) -> Bool {
        guard let match = output.range(of: "[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression) else { return false }
        let parts = output[match].split(separator: ".").compactMap { Int($0) }
        return parts.count == 3 && parts[0] == 1 && (parts[1] > 4 || (parts[1] == 4 && parts[2] >= 1))
    }

    public func start(bundle: LocalRunBundle, layout: LocalRunContainerLayout, secret: String) async throws {
        guard self.layout == nil, !stopping else { throw LocalRunError.staleSession }
        self.layout = layout
        var resolved = bundle
        resolved.worker_image = try await resolveImage(bundle.worker_image)
        guard !stopping else { throw LocalRunError.staleSession }
        try Self.materialize(bundle: resolved, layout: layout, secret: secret)
        ownsRoot = true
        for var companion in resolved.companions ?? [] {
            guard !stopping else { throw LocalRunError.staleSession }
            companion.image = try await resolveImage(companion.image)
            guard !stopping else { throw LocalRunError.staleSession }
            let name = layout.name + "-" + companion.kind
            names.append(name)
            let args = try Self.companionArguments(companion, layout: layout, name: name)
            try await launch(args)
            try await socketReady(layout.root.appendingPathComponent("buildkit.sock"))
        }
        guard !stopping else { throw LocalRunError.staleSession }
        names.append(layout.name)
        try await launch(Self.arguments(bundle: resolved, layout: layout))
        guard !stopping else { throw LocalRunError.staleSession }
        try await networking(layout.name, command)
    }

    private func launch(_ arguments: [String]) async throws {
        guard !stopping else { throw LocalRunError.staleSession }
        launching = true
        defer { launching = false }
        guard try await command(arguments).status == 0 else { throw LocalRunError.startupFailed }
    }

    public static func waitForSocket(_ url: URL) async throws {
        for _ in 0..<300 {
            try Task.checkCancellation()
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            if attributes?[.type] as? FileAttributeType == .typeSocket { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LocalRunError.startupFailed
    }

    public static func probeNetworking(name: String, command: LocalRunContainerCommand) async throws {
        let probe = try LocalRunLoopbackProbe()
        probe.start()
        defer { probe.stop() }
        let response = try await command(["exec", name, "curl", "--noproxy", "*", "--fail", "--silent", "--max-time", "5", "http://host.container.internal:\(probe.port)"])
        guard response.status == 0, String(data: response.output, encoding: .utf8) == probe.nonce else { throw LocalRunError.networkingUnavailable }
    }

    private func resolveImage(_ reference: String) async throws -> String {
        guard !stopping, try await command(["image", "pull", "--platform", "linux/arm64", reference]).status == 0 else { throw LocalRunError.startupFailed }
        guard !stopping else { throw LocalRunError.staleSession }
        let result = try await command(["image", "inspect", reference])
        guard result.status == 0 else { throw LocalRunError.startupFailed }
        return try Self.resolvedDigest(reference: reference, inspection: result.output)
    }

    public static func resolvedDigest(reference: String, inspection: Data) throws -> String {
        struct Image: Decodable {
            struct Configuration: Decodable {
                struct Descriptor: Decodable { let digest: String }
                let name: String; let descriptor: Descriptor
            }
            struct Variant: Decodable {
                struct Platform: Decodable { let os: String; let architecture: String }
                let platform: Platform
            }
            let configuration: Configuration; let variants: [Variant]
        }
        let images = try JSONDecoder().decode([Image].self, from: inspection)
        guard images.count == 1, let image = images.first, image.configuration.name == reference,
              image.variants.contains(where: { $0.platform.os == "linux" && $0.platform.architecture == "arm64" }),
              image.configuration.descriptor.digest.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil else { throw LocalRunError.invalidBundle }
        let repository: String
        if let marker = reference.firstIndex(of: "@") {
            repository = String(reference[..<marker])
            guard String(reference[reference.index(after: marker)...]) == image.configuration.descriptor.digest else { throw LocalRunError.invalidBundle }
        } else if let marker = reference.lastIndex(of: ":") { repository = String(reference[..<marker]) }
        else { throw LocalRunError.invalidBundle }
        return repository + "@" + image.configuration.descriptor.digest
    }

    public func stop() async throws {
        stopping = true
        // Closing during image download cannot race a late successful run command.
        while launching { try await Task.sleep(for: .milliseconds(100)) }
        for name in names.reversed() {
            let stop = try await command(["stop", "--time", "5", name])
            if stop.status != 0 {
                _ = try await command(["kill", name])
            }
            // These names are allocated only by this session.
            let deletion = try await command(["delete", name])
            if deletion.status != 0 {
                let inventory = try await command(["list", "--all", "--quiet"])
                guard inventory.status == 0, let output = String(data: inventory.output, encoding: .utf8),
                      !output.split(whereSeparator: \.isWhitespace).contains(Substring(name)) else { throw LocalRunError.cleanupFailed }
            }
        }
        names.removeAll()
        if ownsRoot, let layout, FileManager.default.fileExists(atPath: layout.root.path) { try FileManager.default.removeItem(at: layout.root) }
        ownsRoot = false
        layout = nil
    }

    public static func materialize(bundle: LocalRunBundle, layout: LocalRunContainerLayout, secret: String) throws {
        let manager = FileManager.default
        guard UUID(uuidString: layout.sessionID) != nil, !manager.fileExists(atPath: layout.root.path) else { throw LocalRunError.invalidBundle }
        try manager.createDirectory(at: layout.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? manager.removeItem(at: layout.root) } }
        try manager.createDirectory(at: layout.home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let artifacts = layout.root.appendingPathComponent("files")
        try manager.createDirectory(at: artifacts, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for (index, file) in bundle.files.enumerated() {
            try writePrivate(Data(file.content.utf8), to: artifacts.appendingPathComponent(String(index)), executable: file.mode & 0o100 != 0)
        }
        var bootstrap = "#!/bin/sh\nset -eu\numask 077\n"
        for (index, file) in bundle.files.enumerated() {
            let parent = (file.path as NSString).deletingLastPathComponent
            bootstrap += "mkdir -p -- " + shellQuote(parent) + "\n"
            bootstrap += "cp -- " + shellQuote(guestArtifacts + "/" + String(index)) + " " + shellQuote(file.path) + "\n"
            bootstrap += "chmod " + String(file.mode, radix: 8) + " -- " + shellQuote(file.path) + "\n"
        }
        bootstrap += "exec \"$@\"\n"
        try writePrivate(Data(bootstrap.utf8), to: artifacts.appendingPathComponent("bootstrap"))
        var environment = Dictionary(uniqueKeysWithValues: bundle.environment.map { ($0.name, $0.value) })
        environment["PERSONASTACK_WORKER_EXECUTION_MODE"] = "desktop_local"
        environment["PERSONASTACK_LOCAL_SESSION_ID"] = layout.sessionID
        environment["PERSONASTACK_LOCAL_SOCKET_PATH"] = guestSocket
        environment["PERSONASTACK_LOCAL_SOCKET_SECRET"] = secret
        environment["PERSONASTACK_REGISTER_NATIVE_SESSION"] = "false"
        environment["PERSONASTACK_RESUME_REQUESTED"] = "false"
        environment["HOME"] = "/home/persona"
        if !(bundle.companions ?? []).isEmpty { environment["BUILDKIT_HOST"] = "unix:///run/personastack/buildkit.sock" }
        let lines = environment.keys.sorted().map { $0 + "=" + environment[$0]! }.joined(separator: "\n") + "\n"
        try writePrivate(Data(lines.utf8), to: layout.environment)
        completed = true
    }

    public static func arguments(bundle: LocalRunBundle, layout: LocalRunContainerLayout) -> [String] {
        var args = ["run", "--detach", "--name", layout.name, "--platform", "linux/arm64",
                    "--uid", "0", "--gid", "0", "--workdir", "/workspace",
                    "--memory", "4G", "--cpus", "2", "--env-file", layout.environment.path,
                    "--publish-socket", layout.socket.path + ":" + guestSocket,
                    "--volume", layout.home.path + ":/home/persona", "--volume", layout.workspace.path + ":/workspace",
                    "--volume", "/:/host"]
        // Apple shares directories through virtiofs. The Mac owner maps to guest
        // root, so UID 0 can read 0600 artifacts without weakening host permissions.
        args += ["--volume", layout.root.appendingPathComponent("files").path + ":" + guestArtifacts + ":ro"]
        if !(bundle.companions ?? []).isEmpty {
            args += ["--volume", layout.root.appendingPathComponent("buildkit.sock").path + ":/run/personastack/buildkit.sock"]
        }
        args += ["--entrypoint", "/bin/sh", bundle.worker_image, guestArtifacts + "/bootstrap"]
        args += bundle.command
        return args
    }

    private static func companionArguments(_ companion: LocalRunCompanion, layout: LocalRunContainerLayout, name: String) throws -> [String] {
        guard companion.kind == "buildkit", !companion.command.isEmpty else { throw LocalRunError.invalidBundle }
        let environment = layout.root.appendingPathComponent("buildkit.environment")
        try writePrivate(Data(companion.environment.map { $0.name + "=" + $0.value }.joined(separator: "\n").utf8), to: environment)
        return ["run", "--detach", "--name", name, "--platform", "linux/arm64", "--cap-add", "ALL", "--env-file", environment.path,
                "--publish-socket", layout.root.appendingPathComponent("buildkit.sock").path + ":/run/buildkit/buildkitd.sock",
                "--entrypoint", companion.command[0], companion.image] + companion.command.dropFirst()
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func writePrivate(_ data: Data, to url: URL, executable: Bool = false) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: executable ? 0o700 : 0o600]) else {
            throw LocalRunError.invalidBundle
        }
    }

    public static func execute(_ arguments: [String]) async throws -> LocalRunCommandResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let timeout = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            let seconds = arguments.prefix(2) == ["image", "pull"] ? 300 : arguments.first == "run" ? 120 : 30
            timeout.schedule(deadline: .now() + .seconds(seconds))
            timeout.setEventHandler {
                guard process.isRunning else { return }
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(2)) {
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                }
            }
            timeout.resume()
            defer { timeout.cancel() }
            var output = Data()
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                if output.count < 1024 * 1024 { output.append(chunk.prefix(1024 * 1024 - output.count)) }
            }
            process.waitUntilExit()
            return LocalRunCommandResult(status: process.terminationStatus, output: output)
        }.value
    }
}
