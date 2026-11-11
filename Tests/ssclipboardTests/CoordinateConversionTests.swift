import CoreGraphics
import Testing
@testable import ssclipboard

@Test
func appKitPointToQuartzConvertsYAxisFromPrimaryHeight() {
    let point = CGPoint(x: 120, y: 220)
    let converted = CoordinateConversion.appKitPointToQuartz(point, primaryScreenHeight: 1000)

    #expect(converted == CGPoint(x: 120, y: 780))
}

@Test
func quartzWindowRectToAppKitGlobalConvertsTopLeftRect() {
    let rect = CGRect(x: 300, y: 100, width: 400, height: 250)
    let converted = CoordinateConversion.quartzWindowRectToAppKitGlobal(rect, primaryScreenHeight: 1000)

    #expect(converted == CGRect(x: 300, y: 650, width: 400, height: 250))
}
