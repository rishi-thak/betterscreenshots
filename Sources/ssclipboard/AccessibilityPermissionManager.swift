import ApplicationServices
import Foundation

@MainActor
final class AccessibilityPermissionManager {
    enum State {
        case authorized
        case denied
    }

    func requestAtLaunch() -> State {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        return trusted ? .authorized : .denied
    }

    func currentState() -> State {
        AXIsProcessTrusted() ? .authorized : .denied
    }
}
