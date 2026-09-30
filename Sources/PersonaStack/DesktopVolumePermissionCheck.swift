import Darwin
import Foundation
import PersonaStackCore

/// A mount-table identity, not a grant or remote file-access authorization.
struct DesktopVolumePermissionMount: Hashable, Sendable {
    let url: URL
    let fileSystemIDFirst: Int32
    let fileSystemIDSecond: Int32
    let fileSystemType: String
    let flags: UInt32

    var isReadOnly: Bool { flags & UInt32(MNT_RDONLY) != 0 }
    var isUnqualifiedNetworkVolume: Bool {
        applies(to: .networkVolumes) && !["smbfs", "nfs", "afpfs", "webdav"].contains(fileSystemType)
    }

    func applies(to permission: DesktopPermissionID) -> Bool {
        let local = flags & UInt32(MNT_LOCAL) != 0
        switch permission {
        case .removableVolumes: return local && flags & UInt32(MNT_REMOVABLE) != 0
        case .networkVolumes:
            return !local && !["autofs", "devfs", "volfs", "fdesc", "procfs", "tmpfs"].contains(fileSystemType)
        default: return false
        }
    }
}

enum DesktopVolumePermissionInventoryError: Error {
    case unavailable, tooLarge, invalid
}

/// Passive mount inventory and explicit, resource-scoped checks. The injected
/// executor owns every protected operation. No probe runs during observation.
@MainActor
final class DesktopVolumePermissionCheck {
    typealias Mount = DesktopVolumePermissionMount
    private let snapshot: () throws -> [Mount]
    private let choose: @MainActor (DesktopPermissionID, [Mount]) async -> Mount?
    private let verify: @MainActor (Mount) async throws -> Void
    private let contextKey: () -> String
    private var proofs: [Mount: DesktopPermissionObservation] = [:]
    private var currentContext: String?
    private var previousMounts: Set<Mount>?
    private var generation = UUID()
    private var pending: UUID?

    init(snapshot: @escaping () throws -> [Mount] = DesktopVolumePermissionCheck.passiveMountedVolumes,
         choose: @escaping @MainActor (DesktopPermissionID, [Mount]) async -> Mount?,
         verify: @escaping @MainActor (Mount) async throws -> Void,
         contextKey: @escaping () -> String) {
        self.snapshot = snapshot
        self.choose = choose
        self.verify = verify
        self.contextKey = contextKey
    }

    func invalidate() {
        generation = UUID()
        pending = nil
        proofs.removeAll()
        previousMounts = nil
    }

    func observe(_ permission: DesktopPermissionID) -> DesktopPermissionObservation {
        do { return aggregate(permission, mounts: try inventory()) }
        catch { return inventoryFailure() }
    }

    /// Chooser labels expose each resource's own result. Aggregate readiness
    /// never allows a verified mount to conceal another incomplete resource.
    func observation(for mount: Mount) -> DesktopPermissionObservation {
        do {
            guard try inventory().contains(mount) else {
                return .init(.failed, detail: "This mounted resource is no longer available. Select a current volume.")
            }
            return resourceObservation(mount)
        } catch { return inventoryFailure() }
    }

    func setup(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        let initial: [Mount]
        do { initial = try inventory().filter { $0.applies(to: permission) } }
        catch { return inventoryFailure() }
        guard !Task.isCancelled else { return cancelled() }
        guard pending == nil else { return .init(.checking, detail: "A volume check is already in progress.") }
        guard !initial.isEmpty else { return aggregate(permission, mounts: initial) }
        let request = UUID()
        let epoch = generation
        let context = contextKey()
        pending = request
        defer { if pending == request { pending = nil } }
        let selected = await choose(permission, initial)
        guard isCurrent(request, epoch: epoch, context: context) else { return cancelled() }
        guard let selected else {
            return observe(permission)
        }
        guard initial.contains(selected), selected.applies(to: permission) else {
            return .init(.failed, detail: "Select a mounted resource from the current volume list.")
        }
        return await check(selected, permission: permission, request: request, epoch: epoch, context: context)
    }

    private func check(_ selected: Mount, permission: DesktopPermissionID, request: UUID,
                       epoch: UUID, context: String) async -> DesktopPermissionObservation {
        do {
            let before = try inventory()
            guard isCurrent(request, epoch: epoch, context: context), before.contains(selected) else { return cancelled() }
            guard !selected.isUnqualifiedNetworkVolume else { return aggregate(permission, mounts: before) }
            proofs.removeValue(forKey: selected)
            let result = await verifyResource(selected)
            let after = try inventory()
            guard isCurrent(request, epoch: epoch, context: context), after.contains(selected) else { return cancelled() }
            proofs[selected] = result
            return aggregate(permission, mounts: after)
        } catch { return inventoryFailure() }
    }

    private func verifyResource(_ selected: Mount) async -> DesktopPermissionObservation {
        do {
            try await verify(selected)
            return .init(.ready,
                detail: selected.isReadOnly
                    ? "PersonaStack verified listing this read-only volume. Writes are unavailable on this volume."
                    : "PersonaStack verified listing and reading, writing and removing its disposable file on this volume.",
                verificationKey: UUID().uuidString, requiresVerification: true, verified: true)
        } catch is CancellationError { return cancelled() }
        catch DesktopFileSystemError.permissionDenied {
            return .init(.denied, detail: "Access to this volume was denied. Review Files and Folders settings and the volume's file permissions.")
        } catch {
            return .init(.failed, detail: "This volume's access check failed. Check availability and file permissions. Disposable-file cleanup must succeed on writable volumes.")
        }
    }

    private func resourceObservation(_ mount: Mount) -> DesktopPermissionObservation {
        if mount.isUnqualifiedNetworkVolume {
            return .init(.unsupported, detail: "A mounted network filesystem has not been qualified for PersonaStack's access checks. It cannot be represented as granted.")
        }
        return proofs[mount] ?? .init(.checking, detail: "This mounted resource has not been checked.")
    }

    private func isCurrent(_ request: UUID, epoch: UUID, context: String) -> Bool {
        !Task.isCancelled && pending == request && generation == epoch && contextKey() == context
    }

    private func inventory() throws -> [Mount] {
        let context = contextKey()
        if currentContext != context {
            invalidate()
            currentContext = context
        }
        do {
            let mounts = try snapshot()
            guard Set(mounts).count == mounts.count,
                  mounts.allSatisfy({ $0.url.isFileURL && $0.url.path.hasPrefix("/") && !$0.url.path.contains("\0") }) else {
                throw DesktopVolumePermissionInventoryError.invalid
            }
            let current = Set(mounts)
            if let previousMounts, previousMounts != current {
                generation = UUID()
                pending = nil
            }
            previousMounts = current
            proofs = proofs.filter { current.contains($0.key) }
            return mounts.sorted { $0.url.path < $1.url.path }
        } catch {
            invalidate()
            throw error
        }
    }

    private func aggregate(_ permission: DesktopPermissionID, mounts: [Mount]) -> DesktopPermissionObservation {
        let applicable = mounts.filter { $0.applies(to: permission) }
        guard !applicable.isEmpty else {
            return .init(.notNeeded, detail: "No \(permission.title.lowercased()) are currently mounted. Missing media is not a granted permission.")
        }
        let checked = applicable.map(resourceObservation)
        let ready = checked.filter { $0.state == .ready && $0.verified }.count
        let count = "Verified \(ready) of \(applicable.count) mounted volumes."
        if ready == applicable.count {
            return .init(.ready, detail: "\(count) Read-only volumes allow listing only. Other volumes passed disposable-file read/write and cleanup checks.",
                         verificationKey: "\(currentContext ?? "unknown"):\(generation):\(permission.rawValue)",
                         requiresVerification: true, verified: true)
        }
        if let failure = checked.first(where: { $0.state == .denied || $0.state == .failed }) {
            return .init(failure.state, detail: "\(count) \(failure.detail) Use Setup to select an incomplete volume.")
        }
        if let unsupported = checked.first(where: { $0.state == .unsupported }) {
            return .init(.unsupported, detail: "\(count) \(unsupported.detail)")
        }
        return .init(.checking, detail: "\(count) Use Setup to select and check each mounted resource. Existing file content is not read.")
    }

    private func cancelled() -> DesktopPermissionObservation {
        .init(.checking, detail: "The selected volume or setup changed, or the check was cancelled. Retry Setup.")
    }

    private func inventoryFailure() -> DesktopPermissionObservation {
        .init(.failed, detail: "The mounted-volume list could not be read safely. Retry after the mount changes finish.")
    }

    /// MNT_NOWAIT uses retained kernel information. No directory is opened and
    /// no remote mount address or credentials are retained in this snapshot.
    nonisolated static func passiveMountedVolumes() throws -> [Mount] {
        let maximum = 4_096
        for _ in 0..<3 {
            let count = getfsstat(nil, 0, MNT_NOWAIT)
            guard count >= 0 else { throw DesktopVolumePermissionInventoryError.unavailable }
            guard count < maximum else { throw DesktopVolumePermissionInventoryError.tooLarge }
            let capacity = min(Int(count) + 16, maximum)
            var entries = Array(repeating: statfs(), count: capacity)
            let returned = entries.withUnsafeMutableBufferPointer {
                getfsstat($0.baseAddress, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT)
            }
            guard returned >= 0 else { throw DesktopVolumePermissionInventoryError.unavailable }
            guard returned < capacity else { continue }
            return try entries.prefix(Int(returned)).map { entry in
                var path = entry.f_mntonname
                var type = entry.f_fstypename
                let name = try withUnsafeBytes(of: &path, decodeMountString)
                let fileSystemType = try withUnsafeBytes(of: &type, decodeMountString)
                guard name.hasPrefix("/") else { throw DesktopVolumePermissionInventoryError.invalid }
                return Mount(url: URL(fileURLWithPath: name, isDirectory: true),
                             fileSystemIDFirst: entry.f_fsid.val.0, fileSystemIDSecond: entry.f_fsid.val.1,
                             fileSystemType: fileSystemType, flags: entry.f_flags)
            }
        }
        throw DesktopVolumePermissionInventoryError.tooLarge
    }

    nonisolated private static func decodeMountString(_ bytes: UnsafeRawBufferPointer) throws -> String {
        guard let end = bytes.firstIndex(of: 0),
              let value = String(bytes: bytes[..<end], encoding: .utf8), !value.isEmpty else {
            throw DesktopVolumePermissionInventoryError.invalid
        }
        return value
    }
}
