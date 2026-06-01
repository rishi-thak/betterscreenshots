import Foundation

enum ScreenshotClassifier {
    static func isLikelyScreenshot(filename: String) -> Bool {
        let normalized = filename.lowercased()

        if normalized.contains("screenshot") || normalized.contains("screen shot") {
            return true
        }

        if normalized.hasPrefix("screen_shot")
            || normalized.hasPrefix("screen-shot")
            || normalized.hasPrefix("screenshot_") {
            return true
        }

        return false
    }
}
