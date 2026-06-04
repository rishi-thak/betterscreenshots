import Foundation

final class AppSettings: @unchecked Sendable {
    enum Key {
        static let overlayDurationSeconds = "overlayDurationSeconds"
        static let copyToClipboardEnabled = "copyToClipboardEnabled"
    }

    static let shared = AppSettings()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults(suiteName: "com.rishi.ssclipboard") ?? .standard) {
        self.defaults = defaults
    }

    var overlayDurationSeconds: TimeInterval {
        get {
            let raw = defaults.object(forKey: Key.overlayDurationSeconds) as? Double
            let value = raw ?? 6
            return max(0.5, value)
        }
        set {
            defaults.set(max(0.5, newValue), forKey: Key.overlayDurationSeconds)
        }
    }

    var copyToClipboardEnabled: Bool {
        get {
            if defaults.object(forKey: Key.copyToClipboardEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Key.copyToClipboardEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.copyToClipboardEnabled)
        }
    }
}
