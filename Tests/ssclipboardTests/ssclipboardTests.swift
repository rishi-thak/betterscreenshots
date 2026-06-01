import Testing
@testable import ssclipboard

@Test
func screenshotClassifierRecognizesCommonNames() {
    #expect(ScreenshotClassifier.isLikelyScreenshot(filename: "Screenshot 2026-06-01 at 10.30.00 AM.png"))
    #expect(ScreenshotClassifier.isLikelyScreenshot(filename: "Screen Shot 2026-06-01 at 10.30.00 AM.png"))
    #expect(ScreenshotClassifier.isLikelyScreenshot(filename: "screen_shot_123.png"))
}

@Test
func screenshotClassifierRejectsNonScreenshotNames() {
    #expect(!ScreenshotClassifier.isLikelyScreenshot(filename: "holiday-photo.png"))
    #expect(!ScreenshotClassifier.isLikelyScreenshot(filename: "notes.pdf"))
}
