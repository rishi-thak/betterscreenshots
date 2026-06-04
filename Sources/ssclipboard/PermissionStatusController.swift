import AppKit
import Foundation

@MainActor
final class PermissionStatusController {
    private enum SettingsURL {
        static let screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        static let accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    }

    private let showWhenHealthy: Bool
    private var statusItem: NSStatusItem?
    private var alertMessage: String?
    private var missingPermissions: [String] = []
    private var hasShownSessionPermissionAlert = false

    init(showWhenHealthy: Bool = false) {
        self.showWhenHealthy = showWhenHealthy
    }

    func update(screenCaptureAuthorized: Bool, accessibilityAuthorized: Bool) {
        var missing: [String] = []
        if !screenCaptureAuthorized { missing.append("Screen Recording") }
        if !accessibilityAuthorized { missing.append("Accessibility") }
        missingPermissions = missing

        if missing.isEmpty {
            alertMessage = nil
        }

        let shouldShow = showWhenHealthy || !missing.isEmpty
        guard shouldShow else {
            removeStatusItemIfNeeded()
            return
        }

        ensureStatusItem()
        configureStatusButton(hasWarnings: !missing.isEmpty)
        rebuildMenu()
    }

    func showCaptureBlockedAlert() {
        guard !missingPermissions.isEmpty else { return }
        alertMessage = "Capture blocked: grant \(missingPermissions.joined(separator: " + ")) permission."
        ensureStatusItem()
        configureStatusButton(hasWarnings: true)
        rebuildMenu()
        presentPermissionAlertOncePerSession()
    }

    private func ensureStatusItem() {
        if statusItem != nil { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }

    private func removeStatusItemIfNeeded() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func configureStatusButton(hasWarnings: Bool) {
        guard let button = statusItem?.button else { return }
        if #available(macOS 11.0, *) {
            let symbolName = hasWarnings ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ssclipboard permissions")
        } else {
            button.title = hasWarnings ? "!" : "✓"
        }
        button.toolTip = hasWarnings
            ? "ssclipboard needs permissions"
            : "ssclipboard permissions are healthy"
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if missingPermissions.isEmpty {
            let okItem = NSMenuItem(title: "Permissions OK", action: nil, keyEquivalent: "")
            okItem.isEnabled = false
            menu.addItem(okItem)
        } else {
            let missingText = "Missing: \(missingPermissions.joined(separator: ", "))"
            let missingItem = NSMenuItem(title: missingText, action: nil, keyEquivalent: "")
            missingItem.isEnabled = false
            menu.addItem(missingItem)
        }

        if let alertMessage {
            let alertItem = NSMenuItem(title: alertMessage, action: nil, keyEquivalent: "")
            alertItem.isEnabled = false
            menu.addItem(alertItem)
        }

        menu.addItem(.separator())
        menu.addItem(makeActionItem(
            title: "Open Screen Recording Settings",
            action: #selector(openScreenRecordingSettings)
        ))
        menu.addItem(makeActionItem(
            title: "Open Accessibility Settings",
            action: #selector(openAccessibilitySettings)
        ))

        statusItem?.menu = menu
    }

    private func makeActionItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc
    private func openScreenRecordingSettings() {
        openSettingsURL(SettingsURL.screenRecording)
    }

    @objc
    private func openAccessibilitySettings() {
        openSettingsURL(SettingsURL.accessibility)
    }

    private func openSettingsURL(_ rawValue: String) {
        guard let url = URL(string: rawValue) else { return }
        NSWorkspace.shared.open(url)
    }

    private func presentPermissionAlertOncePerSession() {
        guard !hasShownSessionPermissionAlert else { return }
        hasShownSessionPermissionAlert = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ssclipboard capture is blocked"
        alert.informativeText = "Grant \(missingPermissions.joined(separator: " and ")) in System Settings to enable screenshots."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        if missingPermissions.contains("Screen Recording") {
            openScreenRecordingSettings()
        } else if missingPermissions.contains("Accessibility") {
            openAccessibilitySettings()
        }
    }
}
