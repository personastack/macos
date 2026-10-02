import CoreGraphics
import Foundation

/// A session-scoped HID filter. It registers no keyboard shortcut. Physical
/// clicks and key presses ask the runtime to stop and return to the OS lock.
@MainActor
final class DesktopLockedControlLocalInput {
    // The C event-tap context must outlive every queued callback.
    static let shared = DesktopLockedControlLocalInput()
    enum Decision: Equatable { case allow, suppress, takeOver, invalidated }
    enum Failure: Error { case unavailable }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var ownedDriverPID: Int32 = 0
    private var invalidated = false
    var onTakeover: (@MainActor () -> Void)?
    var onFailure: (@MainActor () -> Void)?
    private init() {}

    static func decision(type: CGEventType, sourceState: Int64, sourcePID: Int64,
                         driverPID: Int32) -> Decision {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return .invalidated }
        if driverPID > 0, sourcePID == Int64(driverPID) { return .allow }
        if sourcePID > 0,
           [CGEventSourceStateID.privateState, .combinedSessionState].contains(where: { Int64($0.rawValue) == sourceState }) {
            return .allow
        }
        switch type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown: return .takeOver
        default: return .suppress
        }
    }

    func begin(driverPID: Int32) throws {
        guard tap == nil, driverPID > 0 else { throw Failure.unavailable }
        ownedDriverPID = driverPID
        invalidated = false
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
                                   .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                   .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return nil }
            let eventPointer = Unmanaged.passUnretained(event).toOpaque()
            let allowed = MainActor.assumeIsolated {
                Unmanaged<DesktopLockedControlLocalInput>.fromOpaque(context).takeUnretainedValue()
                    .receive(type, Unmanaged<CGEvent>.fromOpaque(eventPointer).takeUnretainedValue()) != nil
            }
            return allowed ? Unmanaged.passUnretained(event) : nil
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            ownedDriverPID = 0
            throw Failure.unavailable
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            ownedDriverPID = 0
            throw Failure.unavailable
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else { end(); throw Failure.unavailable }
    }

    func end() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        ownedDriverPID = 0
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let decision = Self.decision(type: type,
                                     sourceState: event.getIntegerValueField(.eventSourceStateID),
                                     sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
                                     driverPID: ownedDriverPID)
        switch decision {
        case .allow: return Unmanaged.passUnretained(event)
        case .suppress: return nil
        case .takeOver:
            if !invalidated { invalidated = true; onTakeover?() }
            return nil
        case .invalidated:
            if !invalidated { invalidated = true; onFailure?() }
            return nil
        }
    }
}
