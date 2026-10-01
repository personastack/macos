import Foundation

/// Concern banners are a local Mac preference. macOS notification authorization
/// and other PersonaStack notifications remain independent.
public enum DesktopConcernNotificationSettings {
    public static let enabledKey = "desktopConcernNotificationsEnabled"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}
