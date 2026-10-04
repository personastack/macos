import CryptoKit
import Darwin
import Foundation

public struct HarnessHookTurn: Codable, Equatable, Sendable {
    public let runID: String
    public let turnID: String?
    public let ownerPID: Int32
    public init(runID: String, turnID: String?, ownerPID: Int32) { self.runID = runID; self.turnID = turnID; self.ownerPID = ownerPID }
}

/// A file lock serializes reports from hooks and their heartbeat for one connection/session.
public final class HarnessHookState: @unchecked Sendable {
    private let root: URL
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PersonaStack/HarnessActivity")) { self.root = root }
    public func lock(connectionID: String, sessionID: String) throws -> HarnessHookLockedSession {
        guard UUID(uuidString: connectionID) != nil, HarnessHookInput.safeID(sessionID) else { throw LocalSessionError.invalidRequest }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = root.appendingPathComponent(connectionID.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for path in [root, directory] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw LocalSessionError.unsafeFiles }
        }
        let key = SHA256.hash(data: Data(sessionID.utf8)).map { String(format: "%02x", $0) }.joined()
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        // Lock files retain their inode while another hook may be waiting. Only live
        // state consumes session capacity; finished sessions must not block new ones.
        guard entries.filter({ $0.hasSuffix(".json") }).count < 128 || entries.contains(key + ".json") else { throw LocalSessionError.unsafeFiles }
        let descriptor = open(directory.appendingPathComponent(key + ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LocalSessionError.unsafeFiles }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_nlink == 1,
              metadata.st_mode & 0o777 == 0o600, metadata.st_mode & S_IFMT == S_IFREG else { close(descriptor); throw LocalSessionError.unsafeFiles }
        guard flock(descriptor, LOCK_EX) == 0 else { close(descriptor); throw LocalSessionError.unsafeFiles }
        return HarnessHookLockedSession(descriptor: descriptor, path: directory.appendingPathComponent(key + ".json"))
    }
}

public final class HarnessHookLockedSession: @unchecked Sendable {
    private let descriptor: Int32
    private var isLocked = true
    private let path: URL
    init(descriptor: Int32, path: URL) { self.descriptor = descriptor; self.path = path }
    deinit { unlock(); close(descriptor) }
    public func unlock() { if isLocked { _ = flock(descriptor, LOCK_UN); isLocked = false } }
    public func read() throws -> HarnessHookTurn? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 4096 else { throw LocalSessionError.unsafeFiles }
        return try JSONDecoder().decode(HarnessHookTurn.self, from: Data(contentsOf: path))
    }
    public func write(_ turn: HarnessHookTurn) throws {
        let descriptor = open(path.path, O_WRONLY | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LocalSessionError.unsafeFiles }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_nlink == 1,
              metadata.st_mode & 0o777 == 0o600, metadata.st_mode & S_IFMT == S_IFREG,
              ftruncate(descriptor, 0) == 0 else { throw LocalSessionError.unsafeFiles }
        let data = try JSONEncoder().encode(turn)
        try data.withUnsafeBytes { bytes in
            guard Darwin.write(descriptor, bytes.baseAddress!, bytes.count) == bytes.count else { throw LocalSessionError.unsafeFiles }
        }
    }
    public func clear() throws { if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) } }
}
