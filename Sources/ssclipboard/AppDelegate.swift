import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var screenshotAgent: ScreenshotAgent?

    func applicationDidFinishLaunching(_ notification: Notification) {
        screenshotAgent = ScreenshotAgent()
        screenshotAgent?.start()
    }
}
