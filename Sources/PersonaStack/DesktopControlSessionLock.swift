import AppKit
import CoreGraphics

@MainActor
final class DesktopControlSessionLock {
    enum State: Equatable { case unknown, locked, unlocked }
    enum Snapshot: Equatable { case unknown, locked, unlocked, inactive }
    private(set) var state: State = .unknown
    var onChange: ((State) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private let snapshotReader: @MainActor () -> Snapshot
    private var observedLock = false
    private var sleeping = false
    private var inactive = false
    var onLifecycleLoss: (() -> Void)?

    init(observeSystem: Bool = true,
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         activationCenter: NotificationCenter = .default,
         snapshotReader: @escaping @MainActor () -> Snapshot = DesktopControlSessionLock.currentSnapshot) {
        self.snapshotReader = snapshotReader
        guard observeSystem else { return }
        let center = DistributedNotificationCenter.default()
        for (name, state) in [("com.apple.screenIsLocked", State.locked),
                              ("com.apple.screenIsUnlocked", State.unlocked)] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.receive(state) }
            })
        }
        observe(workspaceCenter, NSWorkspace.willSleepNotification) { monitor in
            monitor.sleeping = true
            monitor.onLifecycleLoss?()
            monitor.publish(.locked)
        }
        observe(workspaceCenter, NSWorkspace.didWakeNotification) { monitor in
            monitor.sleeping = false
            monitor.reconcile()
        }
        observe(workspaceCenter, NSWorkspace.sessionDidResignActiveNotification) { monitor in
            monitor.inactive = true
            monitor.onLifecycleLoss?()
            monitor.publish(.locked)
        }
        observe(workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification) { monitor in
            monitor.inactive = false
            monitor.reconcile()
        }
        observe(activationCenter, NSApplication.didBecomeActiveNotification) { $0.reconcile() }
        reconcile()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (DesktopControlSessionLock) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }

    var isAwakeAndActive: Bool { !sleeping && !inactive }
    var readiness: String { state == .unknown ? "unknown" : "locked" }

    /// The lock key is not a documented API contract. Absence must never be
    /// interpreted as proof of unlock. CUA reports whether desktop operations
    /// are available; this monitor fences sleep and inactive user sessions.
    static func currentSnapshot() -> Snapshot {
        classify(CGSessionCopyCurrentDictionary() as? [String: Any], userID: getuid())
    }

    static func classify(_ dictionary: [String: Any]?, userID: uid_t) -> Snapshot {
        guard let dictionary,
              let uid = dictionary[kCGSessionUserIDKey as String] as? NSNumber,
              let onConsole = boolean(dictionary[kCGSessionOnConsoleKey as String]),
              let loggedIn = boolean(dictionary[kCGSessionLoginDoneKey as String]) else { return .unknown }
        guard uid.uint32Value == userID, onConsole, loggedIn else { return .inactive }
        guard let locked = boolean(dictionary["CGSSessionScreenIsLocked"]) else { return .unknown }
        return locked ? .locked : .unlocked
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    func reconcile() {
        switch snapshotReader() {
        case .locked:
            observedLock = true
            publish(.locked)
        case .inactive:
            inactive = true
            publish(.locked)
        case .unlocked:
            guard !sleeping else { return }
            observedLock = false
            inactive = false
            publish(.unlocked)
        case .unknown:
            if observedLock || sleeping || inactive { publish(.locked) }
            else if state != .unlocked { publish(.unknown) }
        }
    }

    func receive(_ value: State) {
        if value == .locked { observedLock = true }
        if value == .unlocked {
            observedLock = false
            guard !sleeping, !inactive else { return }
        }
        publish(value)
    }

    private func publish(_ value: State) {
        guard state != value else { return }
        state = value
        onChange?(value)
    }
}
