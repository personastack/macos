import Foundation
import Darwin

public enum DesktopFileSystemError: Error, Equatable {
    case invalidPath
    case notRegularFile
    case notDirectory
    case missingHandle
    case invalidRange
    case contentTooLarge
    case tooManyOpenFiles
    case destinationExists
    case patchMismatch
    case searchIncomplete
    case permissionDenied
}

public struct DesktopFileEntry: Sendable, Equatable {
    public let path: String
    public let name: String
    public let kind: Kind
    public let size: UInt64
    public let modifiedAt: Date?

    public enum Kind: String, Sendable, Equatable {
        case file
        case directory
        case symlink
        case other
    }
}

public struct DesktopFilePage: Sendable {
    public let entries: [DesktopFileEntry]
    public let nextOffset: Int?
}

public struct DesktopFileRead: Sendable {
    public let path: String
    public let offset: UInt64
    public let content: Data
    public let nextOffset: UInt64
    public let endOfFile: Bool
    public let changedSinceOpen: Bool
}

/// Per-control-session access to files on the logged-in macOS user account.
/// The owning relay must authorize each call before forwarding it here.
public actor DesktopFileSystem {
    public static let maxReadBytes = 256 * 1024
    public static let maxPageSize = 500
    public static let maxOpenFiles = 32
    public static let maxDirectoryScanEntries = 100_000

    private struct OpenFile {
        let path: URL
        let handle: FileHandle
        let originalSize: UInt64
        let originalModification: timespec
    }

    private var openFiles: [UUID: OpenFile] = [:]

    public init() {}

    public func metadata(path: String) throws -> DesktopFileEntry {
        guard let url = Self.url(path) else { throw DesktopFileSystemError.invalidPath }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw DesktopFileSystemError.invalidPath }
        return Self.entry(url)
    }

    public func list(path: String, offset: Int = 0, limit: Int = 100) throws -> DesktopFilePage {
        guard offset >= 0, (1...Self.maxPageSize).contains(limit),
              let input = Self.url(path) else { throw DesktopFileSystemError.notDirectory }
        let url = input.resolvingSymlinksInPath().standardizedFileURL
        guard Self.kind(at: url) == .directory else { throw DesktopFileSystemError.notDirectory }
        guard offset <= Self.maxDirectoryScanEntries else { throw DesktopFileSystemError.invalidRange }
        guard let directory = opendir(url.path) else {
            throw Self.operationError(errno, fallback: .notDirectory)
        }
        defer { closedir(directory) }
        var position = 0
        var entries: [DesktopFileEntry] = []
        var hasMore = false
        while let item = readdir(directory) {
            let name = withUnsafePointer(to: item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard position < Self.maxDirectoryScanEntries else { throw DesktopFileSystemError.contentTooLarge }
            if position >= offset {
                if entries.count == limit { hasMore = true; break }
                entries.append(Self.entry(url.appendingPathComponent(name)))
            }
            position += 1
        }
        return DesktopFilePage(entries: entries, nextOffset: hasMore ? offset + entries.count : nil)
    }

    public func search(root: String, nameContains: String? = nil, contentContains: String? = nil,
                       limit: Int = 100, timeLimit: TimeInterval = 2) throws -> [DesktopFileEntry] {
        guard (1...Self.maxPageSize).contains(limit),
              (nameContains?.isEmpty == false || contentContains?.isEmpty == false),
              let inputURL = Self.url(root) else {
            throw DesktopFileSystemError.notDirectory
        }
        let rootURL = inputURL.resolvingSymlinksInPath().standardizedFileURL
        guard Self.kind(at: rootURL) == .directory else { throw DesktopFileSystemError.notDirectory }
        let deadline = ProcessInfo.processInfo.systemUptime + min(max(timeLimit, 0.05), 10)
        var pending = [rootURL]
        var found: [DesktopFileEntry] = []
        while let directory = pending.popLast(), found.count < limit,
              ProcessInfo.processInfo.systemUptime < deadline {
            guard let scan = Self.directoryEntries(directory, limit: 10_000) else { continue }
            guard !scan.truncated else { throw DesktopFileSystemError.searchIncomplete }
            let children = scan.entries
            for child in children {
                if ProcessInfo.processInfo.systemUptime >= deadline { break }
                let kind = Self.kind(at: child)
                if kind == .directory { pending.append(child) }
                if let nameContains, child.lastPathComponent.localizedCaseInsensitiveContains(nameContains) {
                    found.append(Self.entry(child))
                } else if let contentContains, kind == .file,
                          try Self.file(child, contains: contentContains) {
                    found.append(Self.entry(child))
                }
                if found.count == limit { break }
            }
        }
        return found
    }

    public func open(path: String) throws -> (id: UUID, path: String, size: UInt64, firstRead: DesktopFileRead) {
        guard openFiles.count < Self.maxOpenFiles else { throw DesktopFileSystemError.tooManyOpenFiles }
        guard let input = Self.url(path) else { throw DesktopFileSystemError.invalidPath }
        let resolved = input.resolvingSymlinksInPath().standardizedFileURL
        let descriptor = try Self.openRegularFile(resolved.path, flags: O_RDONLY)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { _ = Darwin.close(descriptor); throw DesktopFileSystemError.notRegularFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let id = UUID()
        openFiles[id] = OpenFile(path: resolved, handle: handle, originalSize: UInt64(info.st_size), originalModification: info.st_mtimespec)
        let initial = try read(id: id, offset: 0, length: Self.maxReadBytes)
        return (id, resolved.path, UInt64(info.st_size), initial)
    }

    public func read(id: UUID, offset: UInt64, length: Int = 256 * 1024) throws -> DesktopFileRead {
        guard let file = openFiles[id] else { throw DesktopFileSystemError.missingHandle }
        guard length >= 0, length <= Self.maxReadBytes else { throw DesktopFileSystemError.invalidRange }
        try file.handle.seek(toOffset: offset)
        let data = try file.handle.read(upToCount: length) ?? Data()
        let next = offset + UInt64(data.count)
        var info = stat()
        let hasInfo = fstat(file.handle.fileDescriptor, &info) == 0
        let currentSize = hasInfo ? UInt64(info.st_size) : nil
        let modified = hasInfo ? info.st_mtimespec : file.originalModification
        return DesktopFileRead(path: file.path.path, offset: offset, content: data, nextOffset: next,
                               endOfFile: data.isEmpty || next >= (currentSize ?? next),
                               changedSinceOpen: currentSize != file.originalSize || modified.tv_sec != file.originalModification.tv_sec || modified.tv_nsec != file.originalModification.tv_nsec)
    }

    public func close(id: UUID) throws {
        guard let file = openFiles.removeValue(forKey: id) else { throw DesktopFileSystemError.missingHandle }
        try file.handle.close()
    }

    public func write(path: String, content: Data, mode: DesktopFileWriteMode, offset: UInt64? = nil) throws -> DesktopFileEntry {
        guard content.count <= Self.maxReadBytes else { throw DesktopFileSystemError.contentTooLarge }
        guard let url = Self.url(path) else { throw DesktopFileSystemError.invalidPath }
        if let offset {
            guard mode == .replace else { throw DesktopFileSystemError.invalidRange }
            guard mode != .create else { throw DesktopFileSystemError.invalidRange }
            let descriptor = try Self.openRegularFile(url.path, flags: O_WRONLY)
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: content)
            try handle.close()
        } else {
            switch mode {
            case .create:
                let descriptor = url.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR) }
                guard descriptor >= 0 else { throw Self.operationError(errno, fallback: .invalidPath, exists: .destinationExists) }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                try handle.write(contentsOf: content)
                try handle.close()
            case .replace:
                guard Self.kind(at: url) == .file else { throw DesktopFileSystemError.notRegularFile }
                try Self.replacePreservingMetadata(content, at: url)
            case .append:
                let descriptor = url.path.withCString { Darwin.open($0, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR) }
                guard descriptor >= 0 else { throw Self.operationError(errno, fallback: .notRegularFile) }
                var info = stat()
                guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { _ = Darwin.close(descriptor); throw DesktopFileSystemError.notRegularFile }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                try handle.seekToEnd()
                try handle.write(contentsOf: content)
                try handle.close()
            }
        }
        return Self.entry(url)
    }

    public func patch(path: String, expected: String, replacement: String) throws -> DesktopFileEntry {
        guard let url = Self.url(path) else { throw DesktopFileSystemError.invalidPath }
        let descriptor = try Self.openRegularFile(url.path, flags: O_RDONLY)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0, openedInfo.st_size <= 4 * 1024 * 1024,
              let data = try? Self.readBounded(handle, limit: 4 * 1024 * 1024 + 1), data.count <= 4 * 1024 * 1024,
              let current = String(data: data, encoding: .utf8), current.components(separatedBy: expected).count == 2 else {
            throw DesktopFileSystemError.patchMismatch
        }
        let updatedSize = data.count - expected.utf8.count + replacement.utf8.count
        guard replacement.utf8.count <= 4 * 1024 * 1024, updatedSize <= 4 * 1024 * 1024 else {
            throw DesktopFileSystemError.contentTooLarge
        }
        let updated = Data(current.replacingOccurrences(of: expected, with: replacement).utf8)
        try Self.replacePreservingMetadata(updated, at: url, expected: openedInfo)
        return Self.entry(url)
    }

    public func makeDirectory(path: String) throws {
        guard let url = Self.url(path) else { throw DesktopFileSystemError.invalidPath }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    public func move(source: String, destination: String) throws {
        guard let from = Self.url(source), let to = Self.url(destination) else { throw DesktopFileSystemError.invalidPath }
        guard !FileManager.default.fileExists(atPath: to.path) else { throw DesktopFileSystemError.destinationExists }
        try FileManager.default.moveItem(at: from, to: to)
    }

    public func remove(path: String) throws {
        guard let url = Self.url(path), url.path != "/" else { throw DesktopFileSystemError.invalidPath }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw DesktopFileSystemError.invalidPath }
        let result = (info.st_mode & S_IFMT) == S_IFDIR ? rmdir(url.path) : unlink(url.path)
        guard result == 0 else { throw DesktopFileSystemError.invalidPath }
    }

    public func closeAll() {
        for file in openFiles.values { try? file.handle.close() }
        openFiles.removeAll()
    }

    private static func url(_ path: String) -> URL? {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0"), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func kind(at url: URL) -> DesktopFileEntry.Kind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .other }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .symlink
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        default: return .other
        }
    }

    private static func kind(_ values: URLResourceValues) -> DesktopFileEntry.Kind {
        if values.isSymbolicLink == true { return .symlink }
        if values.isDirectory == true { return .directory }
        return .other
    }

    private static func openRegularFile(_ path: String, flags: Int32) throws -> Int32 {
        let descriptor = path.withCString { Darwin.open($0, flags | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw operationError(errno, fallback: .notRegularFile) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            let failure = errno
            _ = Darwin.close(descriptor)
            throw operationError(failure, fallback: .notRegularFile)
        }
        return descriptor
    }

    private static func operationError(_ code: Int32, fallback: DesktopFileSystemError,
                                       exists: DesktopFileSystemError? = nil) -> DesktopFileSystemError {
        if code == EACCES || code == EPERM { return .permissionDenied }
        if code == EEXIST, let exists { return exists }
        return fallback
    }

    private static func entry(_ url: URL) -> DesktopFileEntry {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        let kind = kind(at: url)
        return DesktopFileEntry(path: url.standardizedFileURL.path, name: url.lastPathComponent, kind: kind,
                                size: UInt64(values?.fileSize ?? 0), modifiedAt: values?.contentModificationDate)
    }

    private static func file(_ url: URL, contains needle: String) throws -> Bool {
        let descriptor = try openRegularFile(url.path, flags: O_RDONLY)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let needleData = Data(needle.utf8)
        guard !needleData.isEmpty else { return false }
        var tail = Data()
        var remaining = 4 * 1024 * 1024
        while remaining > 0 {
            let chunk = try handle.read(upToCount: min(64 * 1024, remaining)) ?? Data()
            if chunk.isEmpty { return false }
            remaining -= chunk.count
            tail.append(chunk)
            if tail.range(of: needleData) != nil { return true }
            if tail.count > needleData.count { tail.removeFirst(tail.count - needleData.count + 1) }
        }
        return false
    }

    private static func directoryEntries(_ url: URL, limit: Int) -> (entries: [URL], truncated: Bool)? {
        guard let directory = opendir(url.path) else { return nil }
        defer { closedir(directory) }
        var result: [URL] = []
        while let item = readdir(directory) {
            let name = withUnsafePointer(to: item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            if result.count == limit { return (result, true) }
            result.append(url.appendingPathComponent(name))
        }
        return (result, false)
    }

    private static func readBounded(_ handle: FileHandle, limit: Int) throws -> Data {
        var result = Data()
        while result.count < limit {
            let chunk = try handle.read(upToCount: min(64 * 1024, limit - result.count)) ?? Data()
            if chunk.isEmpty { break }
            result.append(chunk)
        }
        return result
    }

    private static func replacePreservingMetadata(_ content: Data, at url: URL, expected: stat? = nil) throws {
        var original = expected ?? stat()
        if expected == nil, lstat(url.path, &original) != 0 { throw DesktopFileSystemError.invalidPath }
        guard (original.st_mode & S_IFMT) == S_IFREG else { throw DesktopFileSystemError.notRegularFile }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".personastack-\(UUID().uuidString).tmp")
        let descriptor = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR) }
        guard descriptor >= 0 else { throw DesktopFileSystemError.invalidPath }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: content)
            try handle.close()
            let copied = url.path.withCString { source in
                temporary.path.withCString { destination in copyfile(source, destination, nil, copyfile_flags_t(COPYFILE_METADATA)) }
            }
            guard copied == 0 else { throw DesktopFileSystemError.invalidPath }
            var current = stat()
            guard lstat(url.path, &current) == 0, current.st_ino == original.st_ino, current.st_dev == original.st_dev,
                  current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
                  current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec else { throw DesktopFileSystemError.patchMismatch }
            // This final identity check narrows, but cannot eliminate, a concurrent external edit race.
            let result = temporary.path.withCString { source in url.path.withCString { destination in rename(source, destination) } }
            guard result == 0 else { throw DesktopFileSystemError.invalidPath }
        } catch {
            try? handle.close()
            _ = temporary.path.withCString { unlink($0) }
            throw error
        }
    }
}

public enum DesktopFileWriteMode: Sendable {
    case create
    case replace
    case append
}
