import AppKit
import ApplicationServices
import Foundation

@MainActor
final class ScreenCapturePermissionManager {
    enum State: Equatable {
        case authorized
        case pendingRestart
        case denied
    }

    private enum DefaultsKey {
        static let hasRequestedPermission = "screen_capture_permission_requested"
    }

    private let defaults = UserDefaults.standard

    func requestIfNeededAtLaunch() -> State {
        if CGPreflightScreenCaptureAccess() {
            SSCLog.permissions.debug("screen capture permission already authorized")
            return .authorized
        }

        let hasRequestedPermission = defaults.bool(forKey: DefaultsKey.hasRequestedPermission)
        if hasRequestedPermission {
            return .denied
        }

        defaults.set(true, forKey: DefaultsKey.hasRequestedPermission)
        let granted = CGRequestScreenCaptureAccess()
        if granted {
            defaults.set(false, forKey: DefaultsKey.hasRequestedPermission)
            SSCLog.permissions.info("screen capture permission granted after request")
            return .authorized
        }

        SSCLog.permissions.warning("screen capture permission pending restart")
        return .pendingRestart
    }

    func currentState() -> State {
        if CGPreflightScreenCaptureAccess() {
            defaults.set(false, forKey: DefaultsKey.hasRequestedPermission)
            return .authorized
        }

        SSCLog.permissions.debug("screen capture permission currently denied")
        return .denied
    }
}
