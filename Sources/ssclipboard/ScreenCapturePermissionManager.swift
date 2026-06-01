import AppKit
import ApplicationServices
import Foundation

@MainActor
final class ScreenCapturePermissionManager {
    enum State {
        case authorized
        case pendingRestart
        case denied
    }

    private enum DefaultsKey {
        static let hasRequestedPermission = "screen_capture_permission_requested"
    }

    private let defaults = UserDefaults.standard
    private var cachedAuthorized = false

    func requestIfNeededAtLaunch() -> State {
        if cachedAuthorized || CGPreflightScreenCaptureAccess() {
            cachedAuthorized = true
            return .authorized
        }

        let hasRequestedPermission = defaults.bool(forKey: DefaultsKey.hasRequestedPermission)
        if hasRequestedPermission {
            return .denied
        }

        defaults.set(true, forKey: DefaultsKey.hasRequestedPermission)
        let granted = CGRequestScreenCaptureAccess()
        if granted {
            cachedAuthorized = true
            defaults.set(false, forKey: DefaultsKey.hasRequestedPermission)
            return .authorized
        }

        return .pendingRestart
    }

    func currentState() -> State {
        if cachedAuthorized || CGPreflightScreenCaptureAccess() {
            cachedAuthorized = true
            defaults.set(false, forKey: DefaultsKey.hasRequestedPermission)
            return .authorized
        }

        return .denied
    }
}
