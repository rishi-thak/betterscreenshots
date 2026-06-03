import AppKit
import Foundation

@MainActor
final class ScreenshotAgent {
    private let configuration: ScreenshotConfiguration
    private let clipboardWriter = ClipboardWriter()
    private let accessibilityPermissionManager = AccessibilityPermissionManager()
    private let permissionManager = ScreenCapturePermissionManager()
    private lazy var captureManager = CaptureManager(configuration: configuration)
    private let regionSelectionController = RegionSelectionController()
    private lazy var viewerController = ScreenshotViewerController(
        clipboardWriter: clipboardWriter,
        onDelete: { [weak self] screenshot in
            self?.handleDeletedScreenshot(screenshot)
        }
    )
    private lazy var overlayController = ActionOverlayController(
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

    init(configuration: ScreenshotConfiguration = ScreenshotConfiguration.current()) {
        self.configuration = configuration
    }

    func start() {
        handlePermissionState(permissionManager.requestIfNeededAtLaunch())
        _ = accessibilityPermissionManager.requestAtLaunch()
        pollAccessibility()
    }

    private func pollAccessibility() {
        if AXIsProcessTrusted() {
            hotKeyManager.start()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.pollAccessibility()
        }
    }

    private func captureFullScreen() {
        guard permissionManager.currentState() == .authorized else {
            handleUnauthorizedCaptureAttempt()
            return
        }

        guard let result = captureManager.captureFullScreen() else {
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
            guard let self, let result else { return }

            let captureResult: CaptureResult?
            if let windowID = result.windowID {
                captureResult = self.captureManager.captureWindow(windowID: windowID, rect: result.rect)
            } else {
                captureResult = self.captureManager.captureRegion(result.rect)
            }

            guard let captureResult else { return }
            self.handleCapture(captureResult)
        }
    }

    private func handleCapture(_ result: CaptureResult) {
        _ = clipboardWriter.copyImage(result.image)
        overlayController.present(for: result.screenshot, previewImage: result.image, on: result.anchorScreen, isWindowCapture: result.isWindowCapture)
    }

    private func handleDeletedScreenshot(_ screenshot: ScreenshotFile) {
        _ = screenshot
    }

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
            hotKeyManager.start()
        case .denied:
            return
        }
    }

    private func handleUnauthorizedCaptureAttempt() {
        NSSound.beep()
    }

    private func scheduleAgentRestart() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApp.terminate(nil)
        }
    }
}
