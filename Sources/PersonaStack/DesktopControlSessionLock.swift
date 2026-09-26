import AppKit

/// Screen-lock notifications use the public distributed notification API.
/// Their system-defined names require packaged macOS delivery validation.
@MainActor
final class DesktopControlSessionLock {
    enum State: Equatable { case unknown, locked, unlocked }
    private(set) var state: State = .unknown
    var onChange: ((State) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init(observeSystem: Bool = true,
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        guard observeSystem else { return }
        let center = DistributedNotificationCenter.default()
        for (name, state) in [("com.apple.screenIsLocked", State.locked),
                              ("com.apple.screenIsUnlocked", State.unlocked)] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.receive(state) }
            })
        }
        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.receive(.locked) }
        })
    }

    var allowsControl: Bool { state == .unlocked }

    /// A foreground native confirmation proves the user can interact with this
    /// session when no lock notification has been observed since launch.
    func confirmForegroundSetup() {
        guard state == .unknown else { return }
        receive(.unlocked)
    }

    func receive(_ value: State) {
        guard state != value else { return }
        state = value
        onChange?(value)
    }
}
