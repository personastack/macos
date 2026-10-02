import CoreGraphics
import ColorSync
import Foundation

struct DesktopDisplayDescriptor: Equatable, Sendable {
    let uuid: String
    let gammaCapacity: Int
}

struct DesktopDisplayGammaTable: Equatable, Sendable {
    let red: [Float]
    let green: [Float]
    let blue: [Float]

    var sampleCount: Int { red.count }
}

enum DesktopDisplayPrivacyInvalidation: Equatable, Sendable {
    case displayConfigurationChanged
    case activationFailed
    case restorationFailed
}

enum DesktopDisplayPrivacyError: Error, Equatable {
    case invalidDisplayList
    case unsupportedDisplay(String)
    case invalidGammaTable(String)
    case operationFailed(String)
    case blackGammaReadbackFailed(String)
    case restoreReadbackFailed(String)
    case invalidated
    case sessionNotLocked
    case restorationIncomplete([String])
}

@MainActor
protocol DesktopDisplayGammaAdapting: AnyObject {
    func onlineDisplays() throws -> [DesktopDisplayDescriptor]
    func readGammaTable(displayUUID: String) throws -> DesktopDisplayGammaTable
    func setGammaTable(_ table: DesktopDisplayGammaTable, displayUUID: String) throws
    func setDisplayChangeHandler(_ handler: (@Sendable () -> Void)?) throws
}

/// Owns the in-memory gamma snapshot for one temporary privacy session.
/// The caller must relock or revoke the session from `onInvalidation`.
@MainActor
final class DesktopDisplayPrivacyController {
    static let maximumDisplayCount = 16
    static let maximumGammaSamples = 4_096

    var onInvalidation: (@MainActor (DesktopDisplayPrivacyInvalidation) -> Void)?

    private let adapter: any DesktopDisplayGammaAdapting
    private let sessionIsActuallyLocked: @MainActor () -> Bool
    private var snapshots: [String: DesktopDisplayGammaTable] = [:]
    private var expectedDisplays: Set<String> = []
    private var isActive = false
    private var gammaMayBeModified = false
    private var invalidated = false

    init(adapter: any DesktopDisplayGammaAdapting,
         sessionIsActuallyLocked: @escaping @MainActor () -> Bool,
         onInvalidation: (@MainActor (DesktopDisplayPrivacyInvalidation) -> Void)? = nil) {
        self.adapter = adapter
        self.sessionIsActuallyLocked = sessionIsActuallyLocked
        self.onInvalidation = onInvalidation
    }

    func concealAllDisplays() throws {
        guard !isActive, snapshots.isEmpty else { throw DesktopDisplayPrivacyError.invalidated }
        guard sessionIsActuallyLocked() else {
            throw DesktopDisplayPrivacyError.sessionNotLocked
        }

        do {
            try adapter.setDisplayChangeHandler { [weak self] in
                Task { @MainActor [weak self] in self?.displayConfigurationChanged() }
            }
            let displays = try validatedDisplayList()
            expectedDisplays = Set(displays.map(\.uuid))
            for display in displays {
                let table = try adapter.readGammaTable(displayUUID: display.uuid)
                try validate(table, for: display)
                snapshots[display.uuid] = table
            }

            guard Set(try validatedDisplayList().map(\.uuid)) == expectedDisplays else {
                throw DesktopDisplayPrivacyError.invalidated
            }

            for display in displays {
                guard let snapshot = snapshots[display.uuid] else {
                    throw DesktopDisplayPrivacyError.invalidGammaTable(display.uuid)
                }
                let black = DesktopDisplayGammaTable(
                    red: Array(repeating: 0, count: snapshot.sampleCount),
                    green: Array(repeating: 0, count: snapshot.sampleCount),
                    blue: Array(repeating: 0, count: snapshot.sampleCount))
                gammaMayBeModified = true
                do {
                    try adapter.setGammaTable(black, displayUUID: display.uuid)
                } catch {
                    throw DesktopDisplayPrivacyError.operationFailed(display.uuid)
                }
                let readback = try adapter.readGammaTable(displayUUID: display.uuid)
                guard isVerifiedBlack(readback, expectedSamples: snapshot.sampleCount) else {
                    throw DesktopDisplayPrivacyError.blackGammaReadbackFailed(display.uuid)
                }
            }

            guard Set(try validatedDisplayList().map(\.uuid)) == expectedDisplays else {
                throw DesktopDisplayPrivacyError.invalidated
            }
            isActive = true
        } catch {
            onInvalidation?(.activationFailed)
            guard !gammaMayBeModified || sessionIsActuallyLocked() else {
                onInvalidation?(.restorationFailed)
                throw DesktopDisplayPrivacyError.sessionNotLocked
            }
            do {
                try restoreSnapshots()
                clearSession()
            } catch {
                onInvalidation?(.restorationFailed)
                throw DesktopDisplayPrivacyError.restorationIncomplete(
                    Array(snapshots.keys).sorted())
            }
            throw error
        }
    }

    func restoreDisplays() throws {
        guard !snapshots.isEmpty else { return }
        guard sessionIsActuallyLocked() else {
            throw DesktopDisplayPrivacyError.sessionNotLocked
        }
        do {
            try restoreSnapshots()
            clearSession()
        } catch {
            onInvalidation?(.restorationFailed)
            throw error
        }
    }

    private func displayConfigurationChanged() {
        guard isActive, !invalidated else { return }
        invalidated = true
        onInvalidation?(.displayConfigurationChanged)
    }

    private func validatedDisplayList() throws -> [DesktopDisplayDescriptor] {
        let displays = try adapter.onlineDisplays()
        guard !displays.isEmpty, displays.count <= Self.maximumDisplayCount else {
            throw DesktopDisplayPrivacyError.invalidDisplayList
        }
        var seen = Set<String>()
        for display in displays {
            guard !display.uuid.isEmpty, display.uuid.utf8.count <= 128,
                  seen.insert(display.uuid).inserted,
                  display.gammaCapacity > 0,
                  display.gammaCapacity <= Self.maximumGammaSamples else {
                throw DesktopDisplayPrivacyError.unsupportedDisplay(display.uuid)
            }
        }
        return displays
    }

    private func validate(_ table: DesktopDisplayGammaTable,
                          for display: DesktopDisplayDescriptor) throws {
        let count = table.red.count
        guard count > 0, count <= display.gammaCapacity,
              count <= Self.maximumGammaSamples,
              table.green.count == count, table.blue.count == count,
              (table.red + table.green + table.blue).allSatisfy(\.isFinite) else {
            throw DesktopDisplayPrivacyError.invalidGammaTable(display.uuid)
        }
    }

    private func isVerifiedBlack(_ table: DesktopDisplayGammaTable,
                                 expectedSamples: Int) -> Bool {
        let values = table.red + table.green + table.blue
        return table.sampleCount == expectedSamples
            && table.green.count == expectedSamples
            && table.blue.count == expectedSamples
            && values.allSatisfy { $0.isFinite && abs($0) <= 0.005 }
    }

    private func restoreSnapshots() throws {
        var failures: [String] = []
        for uuid in snapshots.keys.sorted() {
            guard let table = snapshots[uuid] else { continue }
            do {
                try adapter.setGammaTable(table, displayUUID: uuid)
                let readback = try adapter.readGammaTable(displayUUID: uuid)
                guard matches(readback, table) else {
                    failures.append(uuid)
                    continue
                }
            } catch {
                failures.append(uuid)
            }
        }
        guard failures.isEmpty else {
            throw DesktopDisplayPrivacyError.restorationIncomplete(failures)
        }
    }

    private func matches(_ actual: DesktopDisplayGammaTable,
                         _ expected: DesktopDisplayGammaTable) -> Bool {
        guard actual.red.count == expected.red.count,
              actual.green.count == expected.green.count,
              actual.blue.count == expected.blue.count else { return false }
        let pairs = zip(actual.red + actual.green + actual.blue,
                        expected.red + expected.green + expected.blue)
        return pairs.allSatisfy { lhs, rhs in
            lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= 0.0001
        }
    }

    private func clearSession() {
        snapshots.removeAll()
        expectedDisplays.removeAll()
        isActive = false
        gammaMayBeModified = false
        invalidated = false
        try? adapter.setDisplayChangeHandler(nil)
    }
}

@MainActor
final class CoreGraphicsDisplayGammaAdapter: DesktopDisplayGammaAdapting {
    static let shared = CoreGraphicsDisplayGammaAdapter()

    private var displayChangeHandler: (@Sendable () -> Void)?
    private var isObserving = false

    private init() {}

    func onlineDisplays() throws -> [DesktopDisplayDescriptor] {
        var ids = [CGDirectDisplayID](repeating: 0,
                                      count: DesktopDisplayPrivacyController.maximumDisplayCount)
        var count: UInt32 = 0
        let status = ids.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(UInt32(buffer.count), buffer.baseAddress, &count)
        }
        guard status.rawValue == 0,
              count > 0,
              Int(count) <= DesktopDisplayPrivacyController.maximumDisplayCount else {
            throw DesktopDisplayPrivacyError.invalidDisplayList
        }

        return try ids.prefix(Int(count)).map { displayID in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID) else {
                throw DesktopDisplayPrivacyError.unsupportedDisplay(String(displayID))
            }
            let uuidString = CFUUIDCreateString(kCFAllocatorDefault, uuid.takeRetainedValue()) as String
            let capacity = Int(CGDisplayGammaTableCapacity(displayID))
            return DesktopDisplayDescriptor(uuid: uuidString, gammaCapacity: capacity)
        }
    }

    func readGammaTable(displayUUID: String) throws -> DesktopDisplayGammaTable {
        let (displayID, capacity) = try resolve(displayUUID: displayUUID)
        guard capacity > 0, capacity <= DesktopDisplayPrivacyController.maximumGammaSamples else {
            throw DesktopDisplayPrivacyError.unsupportedDisplay(displayUUID)
        }
        var red = [CGGammaValue](repeating: 0, count: capacity)
        var green = [CGGammaValue](repeating: 0, count: capacity)
        var blue = [CGGammaValue](repeating: 0, count: capacity)
        var sampleCount: UInt32 = 0
        let status = red.withUnsafeMutableBufferPointer { r in
            green.withUnsafeMutableBufferPointer { g in
                blue.withUnsafeMutableBufferPointer { b in
                    CGGetDisplayTransferByTable(displayID, UInt32(capacity), r.baseAddress,
                                                g.baseAddress, b.baseAddress, &sampleCount)
                }
            }
        }
        guard status.rawValue == 0,
              sampleCount > 0,
              sampleCount <= UInt32(capacity),
              Int(sampleCount) <= DesktopDisplayPrivacyController.maximumGammaSamples else {
            throw DesktopDisplayPrivacyError.invalidGammaTable(displayUUID)
        }
        let count = Int(sampleCount)
        return DesktopDisplayGammaTable(red: Array(red[0..<count]),
                                        green: Array(green[0..<count]),
                                        blue: Array(blue[0..<count]))
    }

    func setGammaTable(_ table: DesktopDisplayGammaTable, displayUUID: String) throws {
        let (displayID, capacity) = try resolve(displayUUID: displayUUID)
        let count = table.red.count
        guard count > 0, count <= capacity,
              table.green.count == count, table.blue.count == count,
              count <= DesktopDisplayPrivacyController.maximumGammaSamples,
              (table.red + table.green + table.blue).allSatisfy(\.isFinite) else {
            throw DesktopDisplayPrivacyError.invalidGammaTable(displayUUID)
        }
        let red = table.red
        let green = table.green
        let blue = table.blue
        let status = red.withUnsafeBufferPointer { r in
            green.withUnsafeBufferPointer { g in
                blue.withUnsafeBufferPointer { b in
                    CGSetDisplayTransferByTable(displayID, UInt32(count), r.baseAddress,
                                                g.baseAddress, b.baseAddress)
                }
            }
        }
        guard status.rawValue == 0 else {
            throw DesktopDisplayPrivacyError.operationFailed(displayUUID)
        }
    }

    func setDisplayChangeHandler(_ handler: (@Sendable () -> Void)?) throws {
        if handler != nil {
            displayChangeHandler = handler
            if !isObserving {
                let status = CGDisplayRegisterReconfigurationCallback(
                    coreGraphicsDisplayReconfigurationCallback,
                    // This adapter is process-lived so the C callback context
                    // remains valid for the entire registration lifetime.
                    Unmanaged.passUnretained(self).toOpaque())
                guard status.rawValue == 0 else {
                    displayChangeHandler = nil
                    throw DesktopDisplayPrivacyError.operationFailed("display observer")
                }
                isObserving = true
            }
        } else if isObserving {
            let status = CGDisplayRemoveReconfigurationCallback(
                coreGraphicsDisplayReconfigurationCallback,
                Unmanaged.passUnretained(self).toOpaque())
            guard status.rawValue == 0 else {
                throw DesktopDisplayPrivacyError.operationFailed("display observer removal")
            }
            isObserving = false
            displayChangeHandler = nil
        }
    }

    fileprivate func notifyDisplayChange() {
        displayChangeHandler?()
    }

    private func resolve(displayUUID: String) throws -> (CGDirectDisplayID, Int) {
        let matches = try onlineDisplays().filter { $0.uuid == displayUUID }
        guard matches.count == 1 else {
            throw DesktopDisplayPrivacyError.unsupportedDisplay(displayUUID)
        }
        var ids = [CGDirectDisplayID](repeating: 0,
                                      count: DesktopDisplayPrivacyController.maximumDisplayCount)
        var count: UInt32 = 0
        let status = ids.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(UInt32(buffer.count), buffer.baseAddress, &count)
        }
        guard status.rawValue == 0,
              Int(count) <= DesktopDisplayPrivacyController.maximumDisplayCount else {
            throw DesktopDisplayPrivacyError.invalidDisplayList
        }
        for id in ids.prefix(Int(count)) {
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id) else { continue }
            let value = CFUUIDCreateString(kCFAllocatorDefault, uuid.takeRetainedValue()) as String
            if value == displayUUID { return (id, matches[0].gammaCapacity) }
        }
        throw DesktopDisplayPrivacyError.unsupportedDisplay(displayUUID)
    }
}

/// Public, inert adapter for the app's locked-control supervisor. Constructing
/// it does not read or change display state. Call `concealAllDisplays` only
/// after an authorized locked-session transaction has been accepted.
@MainActor
public final class DesktopDisplayPrivacySession {
    public var onInvalidation: (@MainActor () -> Void)? {
        didSet { controller.onInvalidation = { [weak self] _ in self?.onInvalidation?() } }
    }

    private let controller: DesktopDisplayPrivacyController

    public init(sessionIsActuallyLocked: @escaping @MainActor () -> Bool) {
        controller = DesktopDisplayPrivacyController(
            adapter: CoreGraphicsDisplayGammaAdapter.shared,
            sessionIsActuallyLocked: sessionIsActuallyLocked)
    }

    public func concealAllDisplays() throws { try controller.concealAllDisplays() }
    public func restoreDisplays() throws { try controller.restoreDisplays() }
}

private func coreGraphicsDisplayReconfigurationCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let adapter = Unmanaged<CoreGraphicsDisplayGammaAdapter>.fromOpaque(userInfo).takeUnretainedValue()
    Task { @MainActor [weak adapter] in adapter?.notifyDisplayChange() }
}
