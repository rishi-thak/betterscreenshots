import ApplicationServices
import Foundation

@MainActor
final class AccessibilityPermissionManager {
    enum State: Equatable {
        case authorized
        case denied
    }

    func requestAtLaunch() -> State {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        SSCLog.permissions.debug("accessibility request state=\(trusted, privacy: .public)")
        return trusted ? .authorized : .denied
    }

    func currentState() -> State {
        let trusted = AXIsProcessTrusted()
        return trusted ? .authorized : .denied
    }
}
