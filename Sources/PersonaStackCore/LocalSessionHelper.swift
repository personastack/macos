import Darwin
import Foundation

public enum LocalSessionHelper {
    public static func invocation(sessionID: UUID, environment: [String: String], now: Date = Date()) throws -> LocalSessionInvocation {
        guard let path = environment["HOME"], path.hasPrefix("/") else { throw LocalSessionError.unsafeFiles }
        let home = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var directory = home
        for component in ["Library", "Application Support", "PersonaStack", "LocalSessions", sessionID.uuidString] {
            directory.appendPathComponent(component, isDirectory: true)
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw LocalSessionError.unsafeFiles }
        }
        let context = try JSONDecoder().decode(LocalSessionLaunchContext.self, from: readPrivate(directory.appendingPathComponent("context.json"), limit: 16 * 1024))
        guard context.home.resolvingSymlinksInPath() == home else { throw LocalSessionError.unsafeFiles }
        let bundle = try LocalSessionBundle.decode(readPrivate(directory.appendingPathComponent("bundle.json"), limit: LocalSessionBundle.maxWireBytes), appURL: context.appURL, now: now)
        let profilePath = bundle.harness == .codex ? environment["CODEX_HOME"] ?? path + "/.codex" : environment["CLAUDE_CONFIG_DIR"] ?? path + "/.claude"
        guard URL(fileURLWithPath: profilePath).resolvingSymlinksInPath().path == context.profile.path else {
            throw LocalSessionError.staleRequest
        }
        return try LocalSessionInvocation.make(bundle: bundle, sessionID: sessionID, executable: context.executable,
                                                home: context.home, sessionDirectory: directory, inheritedEnvironment: environment)
    }

    private static func readPrivate(_ url: URL, limit: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw LocalSessionError.unsafeFiles }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(), status.st_mode & 0o077 == 0,
              status.st_size >= 0, status.st_size <= limit else { throw LocalSessionError.unsafeFiles }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw LocalSessionError.unsafeFiles }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw LocalSessionError.unsafeFiles }
        }
    }

    public static func execute(_ invocation: LocalSessionInvocation) throws -> Never {
        guard FileManager.default.isExecutableFile(atPath: invocation.executable.path), chdir(invocation.workingDirectory.path) == 0 else {
            throw LocalSessionError.missingHarness
        }
        let arguments = ([invocation.executable.path] + invocation.arguments).map { strdup($0) } + [nil]
        let environment = invocation.environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer {
            arguments.forEach { free($0) }
            environment.forEach { free($0) }
        }
        guard arguments.dropLast().allSatisfy({ $0 != nil }), environment.dropLast().allSatisfy({ $0 != nil }) else {
            throw LocalSessionError.terminalUnavailable
        }
        arguments.withUnsafeBufferPointer { argv in
            environment.withUnsafeBufferPointer { env in
                _ = execve(invocation.executable.path, argv.baseAddress!, env.baseAddress!)
            }
        }
        throw LocalSessionError.terminalUnavailable
    }
}
