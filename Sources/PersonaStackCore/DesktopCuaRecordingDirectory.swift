import Darwin
import Foundation

/// A recording owns a newly created private directory. It never overwrites an
/// existing recording or changes the permissions of a user directory.
public actor DesktopCuaRecordingDirectory {
    public nonisolated let path: String
    private let descriptor: Int32
    public static let maximumBytes: UInt64 = 256 * 1024 * 1024
    public static let maximumEntries = 10_000

    public init(path requestedPath: String) throws {
        guard !requestedPath.isEmpty, !requestedPath.contains("\0"), requestedPath.utf8.count <= 4096,
              requestedPath.hasPrefix("/") || requestedPath.hasPrefix("~/") else { throw DesktopFileSystemError.invalidPath }
        let expanded = (requestedPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != ".." else { throw DesktopFileSystemError.invalidPath }
        let parentFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw DesktopFileSystemError.permissionDenied }
        defer { Darwin.close(parentFD) }
        guard mkdirat(parentFD, name, 0o700) == 0 else {
            throw errno == EEXIST ? DesktopFileSystemError.destinationExists : DesktopFileSystemError.permissionDenied
        }
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DesktopFileSystemError.permissionDenied }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            Darwin.close(fd)
            throw DesktopFileSystemError.permissionDenied
        }
        path = parent.appendingPathComponent(name).path
        descriptor = fd
    }

    deinit { Darwin.close(descriptor) }

    public func isWithinBudget() -> Bool {
        var current = stat()
        var owned = stat()
        guard lstat(path, &current) == 0, fstat(descriptor, &owned) == 0,
              current.st_dev == owned.st_dev, current.st_ino == owned.st_ino,
              (current.st_mode & S_IFMT) == S_IFDIR else { return false }
        var bytes: UInt64 = 0
        var entries = 0
        return Self.measure(directory: descriptor, depth: 0, bytes: &bytes, entries: &entries)
    }

    private static func measure(directory: Int32, depth: Int, bytes: inout UInt64, entries: inout Int) -> Bool {
        guard depth <= 8 else { return false }
        let copy = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard copy >= 0 else { return false }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); return false }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            entries += 1
            guard entries <= maximumEntries else { return false }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                guard info.st_size >= 0, UInt64(info.st_size) <= maximumBytes - bytes else { return false }
                bytes += UInt64(info.st_size)
            case S_IFDIR:
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard child >= 0 else { return false }
                let valid = measure(directory: child, depth: depth + 1, bytes: &bytes, entries: &entries)
                Darwin.close(child)
                guard valid else { return false }
            default: return false
            }
        }
        return true
    }
}
