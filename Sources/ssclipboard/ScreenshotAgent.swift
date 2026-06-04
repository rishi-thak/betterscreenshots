import AppKit
import Carbon
import Foundation

@MainActor
final class ScreenshotAgent {
    private let configuration: ScreenshotConfiguration
    private let appSettings: AppSettings
    private let clipboardWriter = ClipboardWriter()
    private let accessibilityPermissionManager = AccessibilityPermissionManager()
    private let permissionManager = ScreenCapturePermissionManager()
    private let permissionStatusController = PermissionStatusController()
    private var hotKeysStarted = false
    private lazy var captureManager = CaptureManager(configuration: configuration)
    private let regionSelectionController = RegionSelectionController()
    private let scrollingCaptureController = ScrollingCaptureController()
    private lazy var viewerController = ScreenshotViewerController(
        clipboardWriter: clipboardWriter,
        onDelete: { [weak self] screenshot in
            self?.handleDeletedScreenshot(screenshot)
        }
    )
    private lazy var overlayController = ActionOverlayController(
        appSettings: appSettings,
        onDelete: { [weak self] screenshot in
            self?.handleDeletedScreenshot(screenshot)
        },
        onOpen: { [weak self] screenshot, isWindowCapture in
            self?.openScreenshot(screenshot, isWindowCapture: isWindowCapture)
        }
    )
    private lazy var hotKeyManager = HotKeyManager(
        onFullScreen: { [weak self] in
            Task { @MainActor [weak self] in self?.captureFullScreen() }
        },
        onRegion: { [weak self] in
            Task { @MainActor [weak self] in self?.beginRegionCapture() }
        }
    )

    init(configuration: ScreenshotConfiguration = ScreenshotConfiguration.current(), appSettings: AppSettings = .shared) {
        self.configuration = configuration
        self.appSettings = appSettings
    }

    func start() {
        SSCLog.app.info("starting screenshot agent")
        let screenCaptureState = permissionManager.requestIfNeededAtLaunch()
        let accessibilityState = accessibilityPermissionManager.requestAtLaunch()

        handlePermissionState(screenCaptureState)
        handleAccessibilityState(accessibilityState)

        updatePermissionStatus(screenCaptureState: screenCaptureState, accessibilityState: accessibilityState)
        pollPermissionHealth()
    }

    private func pollPermissionHealth() {
        let accessibilityState = accessibilityPermissionManager.currentState()
        let screenCaptureState = permissionManager.currentState()

        handlePermissionState(screenCaptureState)
        handleAccessibilityState(accessibilityState)
        updatePermissionStatus(screenCaptureState: screenCaptureState, accessibilityState: accessibilityState)

        let interval: TimeInterval =
            (accessibilityState == .authorized && screenCaptureState == .authorized) ? 5.0 : 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.pollPermissionHealth()
        }
    }

    private func captureFullScreen() {
        guard permissionManager.currentState() == .authorized else {
            handleUnauthorizedCaptureAttempt()
            return
        }

        guard let result = captureManager.captureFullScreen() else {
            if permissionManager.currentState() != .authorized {
                handleUnauthorizedCaptureAttempt()
                return
            }
            SSCLog.capture.error("fullscreen capture returned no result")
            NSSound.beep()
            return
        }

        handleCapture(result)
    }

    private func beginRegionCapture() {
        guard permissionManager.currentState() == .authorized else {
            handleUnauthorizedCaptureAttempt()
            return
        }

        regionSelectionController.beginSelection { [weak self] result in
            guard let self else { return }
            self.hotKeyManager.keyInterceptor = nil
            guard let result else { return }
            if result.scrollMode, let windowID = result.windowID {
                SSCLog.scroll.info("entering scroll mode, windowID=\(windowID, privacy: .public)")
                // Show recording HUD
                self.showScrollRecordingHUD()
                // Return/Escape stop capture; Space is left for the target app (page-down scroll).
                self.hotKeyManager.keyInterceptor = { [weak self] event in
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    if keyCode == Int64(kVK_Return) || keyCode == Int64(kVK_Escape) {
                        DispatchQueue.main.async { self?.scrollingCaptureController.stop() }
                        return true
                    }
                    return false
                }
                self.scrollingCaptureController.onComplete = { [weak self] cgImage in
                    guard let self else { return }
                    self.hotKeyManager.keyInterceptor = nil
                    self.hideScrollRecordingHUD()
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    guard let saved = self.captureManager.saveScrollCapture(cgImage) else { return }
                    if self.appSettings.copyToClipboardEnabled {
                        _ = self.clipboardWriter.copyImage(nsImage)
                    }
                    self.overlayController.present(for: saved.screenshot, previewImage: nsImage, on: NSScreen.main, isWindowCapture: false)
                }
                self.scrollingCaptureController.begin(windowID: windowID)
                return
            }

            let captureResult: CaptureResult?
            if let windowID = result.windowID {
                captureResult = self.captureManager.captureWindow(windowID: windowID, rect: result.rect)
            } else {
                captureResult = self.captureManager.captureRegion(result.rect)
            }
            guard let captureResult else {
                if self.permissionManager.currentState() != .authorized {
                    self.handleUnauthorizedCaptureAttempt()
                }
                return
            }
            self.handleCapture(captureResult)
        }
        // Panel is now open — install the tap-level key suppressor
        hotKeyManager.keyInterceptor = regionSelectionController.keyInterceptor
    }

    private func handleCapture(_ result: CaptureResult) {
        if appSettings.copyToClipboardEnabled {
            _ = clipboardWriter.copyImage(result.image)
        }
        overlayController.present(for: result.screenshot, previewImage: result.image, on: result.anchorScreen, isWindowCapture: result.isWindowCapture)
    }

    private var scrollHUD: NSPanel?

    private func showScrollRecordingHUD() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 290, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 36))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.92).cgColor

        let dot = NSView(frame: NSRect(x: 12, y: 11, width: 14, height: 14))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 7
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        // Pulse animation
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1; pulse.toValue = 0.3
        pulse.duration = 0.8; pulse.autoreverses = true; pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")

        let label = NSTextField(labelWithString: "Recording — Return or Esc to stop")
        label.frame = NSRect(x: 34, y: 9, width: 248, height: 18)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white

        container.addSubview(dot)
        container.addSubview(label)
        panel.contentView?.addSubview(container)

        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - 230
            let y = screen.visibleFrame.minY + 24
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()
        scrollHUD = panel
    }

    private func hideScrollRecordingHUD() {
        scrollHUD?.orderOut(nil)
        scrollHUD = nil
    }

    private func handleDeletedScreenshot(_ screenshot: ScreenshotFile) { _ = screenshot }

    private func openScreenshot(_ screenshot: ScreenshotFile, isWindowCapture: Bool) {
        viewerController.present(screenshot: screenshot, isWindowCapture: isWindowCapture)
    }

    private func handlePermissionState(_ state: ScreenCapturePermissionManager.State) {
        switch state {
        case .authorized:
            return
        case .pendingRestart:
            scheduleAgentRestart()
        case .denied:
            return
        }
    }

    private func handleAccessibilityState(_ state: AccessibilityPermissionManager.State) {
        switch state {
        case .authorized:
            guard !hotKeysStarted else { return }
            hotKeyManager.start()
            hotKeysStarted = true
        case .denied:
            guard hotKeysStarted else { return }
            hotKeyManager.stop()
            hotKeysStarted = false
            return
        }
    }

    private func handleUnauthorizedCaptureAttempt() {
        permissionStatusController.showCaptureBlockedAlert()
        updatePermissionStatus(
            screenCaptureState: permissionManager.currentState(),
            accessibilityState: accessibilityPermissionManager.currentState()
        )
    }

    private func updatePermissionStatus(
        screenCaptureState: ScreenCapturePermissionManager.State,
        accessibilityState: AccessibilityPermissionManager.State
    ) {
        permissionStatusController.update(
            screenCaptureAuthorized: screenCaptureState == .authorized,
            accessibilityAuthorized: accessibilityState == .authorized
        )
    }

    private func scheduleAgentRestart() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApp.terminate(nil)
        }
    }
}
