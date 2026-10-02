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
    case searchContinuationExpired
    case tooManySearches
    case permissionDenied
}

public struct DesktopFileEntry: Sendable, Equatable {
    public let path: String
    public let name: String
    public let kind: Kind
    public let size: UInt64
    public let modifiedAt: Date?
    public let symlinkTarget: String?

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

public struct DesktopFileSearchMatch: Sendable {
    public let entry: DesktopFileEntry
    public let matchedLines: [Int]
    public let contentScanTruncated: Bool
}

public struct DesktopFileSearchPage: Sendable {
    public let matches: [DesktopFileSearchMatch]
    public let continuation: String?
    public let incompleteContentPaths: [String]

    public var isComplete: Bool { continuation == nil && incompleteContentPaths.isEmpty }
}

public struct DesktopFileRead: Sendable {
    public let path: String
    public let offset: UInt64
    public let content: Data
    public let nextOffset: UInt64
    public let endOfFile: Bool
    public let changedSinceOpen: Bool
    public let lineStart: Int?
    public let nextLine: Int?
    public let truncated: Bool
}

public struct DesktopFileSystemVolumeID: Equatable, Sendable {
    public let first: Int32
    public let second: Int32

    public init(first: Int32, second: Int32) { self.first = first; self.second = second }
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
        let alignUTF8: Bool
    }

    private struct SearchState {
        let root: URL
        let nameContains: String?
        let nameGlob: String?
        let contentContains: String?
        var pendingDirectories: [URL]
        var currentEntries: [URL] = []
        var currentIndex = 0
        var currentDirectory: UnsafeMutablePointer<DIR>? = nil
        var currentDirectoryURL: URL? = nil
        var incompleteContentPaths: Set<String> = []
        var lastAccess: TimeInterval
    }

    private var openFiles: [UUID: OpenFile] = [:]
    private var searches: [UUID: SearchState] = [:]

    public init() {}

    public func openHandleCount() -> Int { openFiles.count }

    public func metadata(path: String) throws -> DesktopFileEntry {
        try DesktopControlExecution.check()
        guard let url = Self.url(path) else { throw DesktopFileSystemError.invalidPath }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw Self.operationError(errno, fallback: .invalidPath) }
        return Self.entry(url)
    }

    public func list(path: String, offset: Int = 0, limit: Int = 100) throws -> DesktopFilePage {
        try DesktopControlExecution.check()
        guard offset >= 0, (1...Self.maxPageSize).contains(limit),
              let input = Self.url(path) else { throw DesktopFileSystemError.notDirectory }
        let url = input.resolvingSymlinksInPath().standardizedFileURL
        guard try Self.kindForOperation(at: url, fallback: .notDirectory) == .directory else {
            throw DesktopFileSystemError.notDirectory
        }
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

    /// Deliberate local permission check. Only the exclusively created marker is
    /// read. Existing directory entries contribute metadata, never file content.
    public func verifyDirectoryAccess(path: String, probeID: UUID = UUID(),
                                      expectedVolumeID: DesktopFileSystemVolumeID? = nil,
                                      readOnly: Bool = false) throws {
        try Task.checkCancellation()
        guard let input = Self.url(path) else { throw DesktopFileSystemError.invalidPath }
        let directory = expectedVolumeID == nil ? input.resolvingSymlinksInPath().standardizedFileURL : input.standardizedFileURL
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.operationError(errno, fallback: .notDirectory) }
        defer { _ = Darwin.close(descriptor) }
        try Self.verifyDirectoryAccess(descriptor: descriptor, probeID: probeID,
                                       expectedVolumeID: expectedVolumeID, readOnly: readOnly)
    }

    static func verifyDirectoryAccess(descriptor directory: Int32, probeID: UUID,
                                      expectedVolumeID: DesktopFileSystemVolumeID?, readOnly: Bool) throws {
        try Task.checkCancellation()
        if let expectedVolumeID {
            var volume = statfs()
            guard fstatfs(directory, &volume) == 0 else { throw operationError(errno, fallback: .notDirectory) }
            guard DesktopFileSystemVolumeID(first: volume.f_fsid.val.0, second: volume.f_fsid.val.1) == expectedVolumeID else {
                throw DesktopFileSystemError.patchMismatch
            }
        }
        try verifyDirectoryListing(descriptor: directory)
        try Task.checkCancellation()
        if readOnly { return }
        let probe = ".personastack-permission-check-\(probeID.uuidString)"
        let descriptor = probe.withCString {
            openat(directory, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw Self.operationError(errno, fallback: .invalidPath, exists: .destinationExists)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var identity = stat()
        guard fstat(descriptor, &identity) == 0 else { throw DesktopFileSystemError.notRegularFile }
        var removed = false
        defer {
            if !removed { try? Self.removeDirectoryVerificationFile(directory: directory, name: probe, identity: identity) }
            try? handle.close()
        }
        try Task.checkCancellation()
        let marker = Data("PersonaStack permission check\n".utf8)
        try handle.write(contentsOf: marker)
        try handle.seek(toOffset: 0)
        guard try handle.read(upToCount: marker.count + 1) == marker else {
            throw DesktopFileSystemError.patchMismatch
        }
        try Task.checkCancellation()
        try Self.removeDirectoryVerificationFile(directory: directory, name: probe, identity: identity)
        removed = true
        try handle.close()
    }

    private static func verifyDirectoryListing(descriptor: Int32) throws {
        let failure = directoryListingFailure(descriptor: descriptor)
        guard failure == 0 else { throw operationError(failure, fallback: .notDirectory) }
    }

    /// Explicit protected-resource check. This proves a directory operation,
    /// never the system-wide Full Disk Access grant. No entry names are retained.
    public func verifyProtectedDirectoryAccess(home: URL) throws {
        try Task.checkCancellation()
        guard home.isFileURL, Self.url(home.path) != nil else { throw DesktopFileSystemError.invalidPath }
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        let root = Darwin.open(home.path, flags)
        guard root >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = Darwin.close(root) }
        try Self.verifyOwnedDirectory(root)
        let library = openat(root, "Library", flags)
        guard library >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = Darwin.close(library) }
        try Self.verifyOwnedDirectory(library)
        try Task.checkCancellation()
        // Both fixed locations are protected by macOS. Some users have never
        // configured Mail. Only absence permits trying Messages; never bypass a
        // denial, redirected path, unexpected owner, or failed directory read.
        var resource = openat(library, "Mail", flags)
        if resource < 0 && errno == ENOENT {
            resource = openat(library, "Messages", flags)
        }
        guard resource >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = Darwin.close(resource) }
        try Self.verifyOwnedDirectory(resource)
        try Task.checkCancellation()
        let failure = Self.directoryListingFailure(descriptor: resource)
        guard failure == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure)) }
        try Task.checkCancellation()
    }

    private static func verifyOwnedDirectory(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else {
            throw DesktopFileSystemError.invalidPath
        }
    }

    private static func directoryListingFailure(descriptor: Int32) -> Int32 {
        let copy = dup(descriptor)
        guard copy >= 0 else { return errno }
        guard let directory = fdopendir(copy) else {
            let failure = errno
            _ = Darwin.close(copy)
            return failure
        }
        defer { closedir(directory) }
        errno = 0
        _ = readdir(directory)
        return errno
    }

    /// Refuse cleanup when the selected directory's entry no longer names our inode.
    static func removeDirectoryVerificationFile(directory: Int32, name: String, identity: stat) throws {
        var current = stat()
        guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw operationError(errno, fallback: .invalidPath) }
        guard current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
              (current.st_mode & S_IFMT) == S_IFREG else { throw DesktopFileSystemError.destinationExists }
        guard unlinkat(directory, name, 0) == 0 else { throw operationError(errno, fallback: .invalidPath) }
    }

    public func search(root: String, nameContains: String? = nil, nameGlob: String? = nil,
                       contentContains: String? = nil, limit: Int = 100,
                       continuation: String? = nil, timeLimit: TimeInterval = 2) throws -> DesktopFileSearchPage {
        try DesktopControlExecution.check()
        guard (1...Self.maxPageSize).contains(limit),
              (nameContains?.isEmpty == false || nameGlob?.isEmpty == false || contentContains?.isEmpty == false),
              let inputURL = Self.url(root) else {
            throw DesktopFileSystemError.notDirectory
        }
        let rootURL = inputURL.resolvingSymlinksInPath().standardizedFileURL
        guard try Self.kindForOperation(at: rootURL, fallback: .notDirectory) == .directory else {
            throw DesktopFileSystemError.notDirectory
        }
        let deadline = ProcessInfo.processInfo.systemUptime + min(max(timeLimit, 0.05), 10)
        let now = ProcessInfo.processInfo.systemUptime
        let expiredSearches = searches.filter { now - $0.value.lastAccess >= 120 }
        for search in expiredSearches.values {
            if let directory = search.currentDirectory { closedir(directory) }
        }
        searches = searches.filter { now - $0.value.lastAccess < 120 }
        let searchID: UUID
        var state: SearchState
        if let continuation {
            guard let parsed = UUID(uuidString: continuation), let saved = searches[parsed],
                  saved.root == rootURL, saved.nameContains == nameContains,
                  saved.nameGlob == nameGlob, saved.contentContains == contentContains else {
                throw DesktopFileSystemError.searchContinuationExpired
            }
            searches.removeValue(forKey: parsed)
            searchID = parsed
            state = saved
        } else {
            guard searches.count < 32 else { throw DesktopFileSystemError.tooManySearches }
            searchID = UUID()
            state = SearchState(root: rootURL, nameContains: nameContains, nameGlob: nameGlob,
                                contentContains: contentContains, pendingDirectories: [rootURL], lastAccess: now)
        }
        state.lastAccess = now
        var retainSearchState = false
        defer {
            if !retainSearchState, let directory = state.currentDirectory { closedir(directory) }
        }
        var matches: [DesktopFileSearchMatch] = []
        while matches.count < limit, ProcessInfo.processInfo.systemUptime < deadline {
            if let directory = state.currentDirectory {
                errno = 0
                if let item = readdir(directory) {
                    let name = withUnsafePointer(to: item.pointee.d_name) { pointer in
                        pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                    }
                    if name == "." || name == ".." { continue }
                    guard state.currentEntries.count < Self.maxDirectoryScanEntries else {
                        throw DesktopFileSystemError.searchIncomplete
                    }
                    guard let directoryURL = state.currentDirectoryURL else {
                        throw DesktopFileSystemError.searchIncomplete
                    }
                    state.currentEntries.append(directoryURL.appendingPathComponent(name))
                    continue
                }
                let readError = errno
                closedir(directory)
                state.currentDirectory = nil
                state.currentDirectoryURL = nil
                guard readError == 0 else { throw Self.operationError(readError, fallback: .notDirectory) }
                state.currentEntries.sort { $0.path < $1.path }
                state.currentIndex = 0
                continue
            }
            if state.currentIndex >= state.currentEntries.count {
                guard let directory = state.pendingDirectories.popLast() else { break }
                state.currentEntries = []
                state.currentIndex = 0
                guard let openedDirectory = opendir(directory.path) else {
                    throw Self.operationError(errno, fallback: .notDirectory)
                }
                state.currentDirectory = openedDirectory
                state.currentDirectoryURL = directory
                continue
            }
            let child = state.currentEntries[state.currentIndex]
            state.currentIndex += 1
            let kind = Self.kind(at: child)
            if kind == .directory { state.pendingDirectories.append(child) }
            let nameMatches = state.nameContains.map { child.lastPathComponent.localizedCaseInsensitiveContains($0) } ?? false
            let globMatches = state.nameGlob.map { Self.matchesGlob($0, child.lastPathComponent) } ?? false
            var matchedLines: [Int] = []
            var contentScanTruncated = false
            if let contentContains, kind == .file {
                let content = try Self.fileLines(child, containing: contentContains)
                matchedLines = content.lines
                contentScanTruncated = content.truncated
                if content.truncated { state.incompleteContentPaths.insert(child.path) }
            }
            if nameMatches || globMatches || !matchedLines.isEmpty {
                matches.append(DesktopFileSearchMatch(entry: Self.entry(child), matchedLines: matchedLines,
                                                      contentScanTruncated: contentScanTruncated))
            }
        }
        let isComplete = state.currentDirectory == nil && state.currentIndex >= state.currentEntries.count && state.pendingDirectories.isEmpty
        if isComplete {
            searches.removeValue(forKey: searchID)
            return DesktopFileSearchPage(matches: matches, continuation: nil,
                                         incompleteContentPaths: state.incompleteContentPaths.sorted())
        }
        searches[searchID] = state
        retainSearchState = true
        return DesktopFileSearchPage(matches: matches, continuation: searchID.uuidString,
                                     incompleteContentPaths: state.incompleteContentPaths.sorted())
    }

    public func open(path: String) throws -> (id: UUID, path: String, size: UInt64, modifiedAt: Date,
                                               revision: String, firstRead: DesktopFileRead) {
        try DesktopControlExecution.check()
        guard openFiles.count < Self.maxOpenFiles else { throw DesktopFileSystemError.tooManyOpenFiles }
        guard let input = Self.url(path) else { throw DesktopFileSystemError.invalidPath }
        let resolved = input.resolvingSymlinksInPath().standardizedFileURL
        let descriptor = try Self.openRegularFile(resolved.path, flags: O_RDONLY)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { _ = Darwin.close(descriptor); throw DesktopFileSystemError.notRegularFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let id = UUID()
        let modifiedAt = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                              + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        let revision = "\(UInt64(info.st_size)):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
        let alignUTF8 = try Self.looksLikeUTF8Text(handle)
        openFiles[id] = OpenFile(path: resolved, handle: handle, originalSize: UInt64(info.st_size),
                                 originalModification: info.st_mtimespec, alignUTF8: alignUTF8)
        let initial = try read(id: id, offset: 0, length: Self.maxReadBytes, alignUTF8: true)
        return (id, resolved.path, UInt64(info.st_size), modifiedAt, revision, initial)
    }

    public func read(id: UUID, offset: UInt64, length: Int = 256 * 1024) throws -> DesktopFileRead {
        try DesktopControlExecution.check()
        guard let file = openFiles[id] else { throw DesktopFileSystemError.missingHandle }
        return try read(id: id, offset: offset, length: length, alignUTF8: file.alignUTF8)
    }

    private func read(id: UUID, offset: UInt64, length: Int, alignUTF8: Bool) throws -> DesktopFileRead {
        guard let file = openFiles[id] else { throw DesktopFileSystemError.missingHandle }
        guard length >= 0, length <= Self.maxReadBytes else { throw DesktopFileSystemError.invalidRange }
        try file.handle.seek(toOffset: offset)
        let rawData = try file.handle.read(upToCount: length) ?? Data()
        let alignedCount = alignUTF8 && file.alignUTF8 ? Self.utf8AlignedPrefixLength(rawData) : rawData.count
        // An invalid or truncated text-looking file must still make byte-range progress.
        let data = Data(rawData.prefix(alignedCount == 0 && !rawData.isEmpty ? rawData.count : alignedCount))
        let next = offset + UInt64(data.count)
        var info = stat()
        let hasInfo = fstat(file.handle.fileDescriptor, &info) == 0
        let currentSize = hasInfo ? UInt64(info.st_size) : nil
        let modified = hasInfo ? info.st_mtimespec : file.originalModification
        return DesktopFileRead(path: file.path.path, offset: offset, content: data, nextOffset: next,
                               endOfFile: data.isEmpty || next >= (currentSize ?? next),
                               changedSinceOpen: currentSize != file.originalSize || modified.tv_sec != file.originalModification.tv_sec || modified.tv_nsec != file.originalModification.tv_nsec,
                               lineStart: offset == 0 ? 1 : nil, nextLine: nil, truncated: false)
    }

    public func readLines(id: UUID, startLine: Int, lineCount: Int,
                          length: Int = DesktopFileSystem.maxReadBytes) throws -> DesktopFileRead {
        try DesktopControlExecution.check()
        guard openFiles[id] != nil else { throw DesktopFileSystemError.missingHandle }
        guard startLine >= 1, (1...10_000).contains(lineCount), (1...Self.maxReadBytes).contains(length) else {
            throw DesktopFileSystemError.invalidRange
        }
        let startOffset = try lineStartOffset(id: id, line: startLine)
        let byteRead = try read(id: id, offset: startOffset, length: length, alignUTF8: true)
        var newlineCount = 0
        var lineBoundary: Int?
        for (index, byte) in byteRead.content.enumerated() where byte == 10 {
            newlineCount += 1
            if newlineCount == lineCount {
                lineBoundary = index
                break
            }
        }
        let data: Data
        let nextOffset: UInt64
        let nextLine: Int
        let truncated: Bool
        let endOfFile: Bool
        if let lineBoundary {
            data = Data(byteRead.content.prefix(lineBoundary + 1))
            nextOffset = startOffset + UInt64(lineBoundary + 1)
            nextLine = startLine + lineCount
            truncated = false
            endOfFile = nextOffset >= byteRead.nextOffset && byteRead.endOfFile
        } else {
            data = byteRead.content
            nextOffset = byteRead.nextOffset
            let newlineCount = data.reduce(into: 0) { count, byte in if byte == 10 { count += 1 } }
            let finalLineCount = byteRead.endOfFile && !data.isEmpty && data.last != 10 ? 1 : 0
            let completeLines = newlineCount + finalLineCount
            nextLine = startLine + completeLines
            truncated = !byteRead.endOfFile && newlineCount < lineCount
            endOfFile = byteRead.endOfFile
        }
        return DesktopFileRead(path: byteRead.path, offset: startOffset, content: data, nextOffset: nextOffset,
                               endOfFile: endOfFile, changedSinceOpen: byteRead.changedSinceOpen,
                               lineStart: startLine, nextLine: nextLine, truncated: truncated)
    }

    private func lineStartOffset(id: UUID, line: Int) throws -> UInt64 {
        guard let file = openFiles[id] else { throw DesktopFileSystemError.missingHandle }
        try file.handle.seek(toOffset: 0)
        var currentLine = 1
        var offset: UInt64 = 0
        while currentLine < line {
            let chunk = try file.handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { return offset }
            let newlines = chunk.indices.filter { chunk[$0] == 10 }
            if !newlines.isEmpty {
                if currentLine + newlines.count >= line {
                    let target = newlines[line - currentLine - 1]
                    return offset + UInt64(target) + 1
                }
                currentLine += newlines.count
                offset += UInt64(chunk.count)
            } else {
                offset += UInt64(chunk.count)
            }
        }
        return offset
    }

    public func close(id: UUID) throws {
        try DesktopControlExecution.check()
        guard let file = openFiles.removeValue(forKey: id) else { throw DesktopFileSystemError.missingHandle }
        try file.handle.close()
    }

    public func write(path: String, content: Data, mode: DesktopFileWriteMode, offset: UInt64? = nil) throws -> DesktopFileEntry {
        try DesktopControlExecution.check()
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
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw Self.operationError(errno, fallback: .invalidPath) }
                guard (info.st_mode & S_IFMT) == S_IFREG else { throw DesktopFileSystemError.notRegularFile }
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
        try DesktopControlExecution.check()
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
        try DesktopControlExecution.check()
        guard let url = Self.url(path) else { throw DesktopFileSystemError.invalidPath }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    public func move(source: String, destination: String) throws {
        try DesktopControlExecution.check()
        guard let from = Self.url(source), let to = Self.url(destination) else { throw DesktopFileSystemError.invalidPath }
        guard !FileManager.default.fileExists(atPath: to.path) else { throw DesktopFileSystemError.destinationExists }
        try FileManager.default.moveItem(at: from, to: to)
    }

    public func remove(path: String) throws {
        try DesktopControlExecution.check()
        guard let url = Self.url(path), url.path != "/" else { throw DesktopFileSystemError.invalidPath }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw Self.operationError(errno, fallback: .invalidPath) }
        let result = (info.st_mode & S_IFMT) == S_IFDIR ? rmdir(url.path) : unlink(url.path)
        guard result == 0 else { throw Self.operationError(errno, fallback: .invalidPath) }
    }

    public func closeAll() {
        for file in openFiles.values { try? file.handle.close() }
        openFiles.removeAll()
        for search in searches.values {
            if let directory = search.currentDirectory { closedir(directory) }
        }
        searches.removeAll()
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

    private static func kindForOperation(at url: URL, fallback: DesktopFileSystemError) throws -> DesktopFileEntry.Kind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw operationError(errno, fallback: fallback) }
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
        guard fstat(descriptor, &info) == 0 else {
            let failure = errno
            _ = Darwin.close(descriptor)
            throw operationError(failure, fallback: .notRegularFile)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            _ = Darwin.close(descriptor)
            throw DesktopFileSystemError.notRegularFile
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
                                size: UInt64(values?.fileSize ?? 0), modifiedAt: values?.contentModificationDate,
                                symlinkTarget: kind == .symlink ? symlinkTarget(url) : nil)
    }

    private static func symlinkTarget(_ url: URL) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = url.path.withCString { readlink($0, &buffer, buffer.count - 1) }
        guard count > 0 else { return nil }
        let raw = String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let target = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : url.deletingLastPathComponent().appendingPathComponent(raw)
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL
        return resolved.path
    }

    private static func matchesGlob(_ pattern: String, _ name: String) -> Bool {
        pattern.withCString { patternPointer in
            name.withCString { namePointer in fnmatch(patternPointer, namePointer, 0) == 0 }
        }
    }

    private static func isReadableText(_ data: Data) -> Bool {
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) || scalar == "\n" || scalar == "\r" || scalar == "\t"
        }
    }

    private static func looksLikeUTF8Text(_ handle: FileHandle) throws -> Bool {
        try handle.seek(toOffset: 0)
        let sample = try handle.read(upToCount: Self.maxReadBytes + 3) ?? Data()
        try handle.seek(toOffset: 0)
        return isReadableText(sample)
    }

    private static func utf8AlignedPrefixLength(_ data: Data) -> Int {
        guard String(data: data, encoding: .utf8) == nil else { return data.count }
        for suffixLength in 1...min(3, data.count) {
            let prefix = data.prefix(data.count - suffixLength)
            let suffix = Data(data.suffix(suffixLength))
            guard String(data: prefix, encoding: .utf8) != nil, isIncompleteUTF8Suffix(suffix) else { continue }
            return data.count - suffixLength
        }
        return data.count
    }

    private static func isIncompleteUTF8Suffix(_ suffix: Data) -> Bool {
        guard let lead = suffix.first else { return false }
        let expectedLength: Int
        switch lead {
        case 0xC2...0xDF: expectedLength = 2
        case 0xE0...0xEF: expectedLength = 3
        case 0xF0...0xF4: expectedLength = 4
        default: return false
        }
        guard suffix.count < expectedLength,
              suffix.dropFirst().allSatisfy({ $0 >= 0x80 && $0 <= 0xBF }) else { return false }
        if suffix.count > 1 {
            let second = suffix[suffix.index(after: suffix.startIndex)]
            if lead == 0xE0 && second < 0xA0 { return false }
            if lead == 0xED && second > 0x9F { return false }
            if lead == 0xF0 && second < 0x90 { return false }
            if lead == 0xF4 && second > 0x8F { return false }
        }
        return true
    }

    private static func fileLines(_ url: URL, containing needle: String) throws -> (lines: [Int], truncated: Bool) {
        let descriptor = try openRegularFile(url.path, flags: O_RDONLY)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let maxBytes = 4 * 1024 * 1024
        let data = try readBounded(handle, limit: maxBytes + 1)
        let truncated = data.count > maxBytes
        guard let text = String(data: data.prefix(maxBytes), encoding: .utf8), !needle.isEmpty else {
            return ([], truncated)
        }
        let lines = text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            line.localizedCaseInsensitiveContains(needle) ? index + 1 : nil
        }
        return (Array(lines.prefix(100)), truncated)
    }

    private static func directoryEntries(_ url: URL, limit: Int) throws -> (entries: [URL], truncated: Bool) {
        guard let directory = opendir(url.path) else { throw operationError(errno, fallback: .notDirectory) }
        defer { closedir(directory) }
        var result: [URL] = []
        errno = 0
        while let item = readdir(directory) {
            let name = withUnsafePointer(to: item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            if result.count == limit { return (result, true) }
            result.append(url.appendingPathComponent(name))
        }
        if errno != 0 { throw operationError(errno, fallback: .notDirectory) }
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
        if expected == nil, lstat(url.path, &original) != 0 {
            throw operationError(errno, fallback: .invalidPath)
        }
        guard (original.st_mode & S_IFMT) == S_IFREG else { throw DesktopFileSystemError.notRegularFile }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".personastack-\(UUID().uuidString).tmp")
        let descriptor = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR) }
        guard descriptor >= 0 else { throw operationError(errno, fallback: .invalidPath) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: content)
            try handle.close()
            let copied = url.path.withCString { source in
                temporary.path.withCString { destination in copyfile(source, destination, nil, copyfile_flags_t(COPYFILE_METADATA)) }
            }
            guard copied == 0 else { throw operationError(errno, fallback: .invalidPath) }
            var current = stat()
            guard lstat(url.path, &current) == 0 else { throw operationError(errno, fallback: .patchMismatch) }
            guard current.st_ino == original.st_ino, current.st_dev == original.st_dev,
                  current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
                  current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec else { throw DesktopFileSystemError.patchMismatch }
            // This final identity check narrows, but cannot eliminate, a concurrent external edit race.
            let result = temporary.path.withCString { source in url.path.withCString { destination in rename(source, destination) } }
            guard result == 0 else { throw operationError(errno, fallback: .invalidPath) }
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
