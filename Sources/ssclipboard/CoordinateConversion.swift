import CoreGraphics

enum CoordinateConversion {
    static func localRectToGlobal(_ rect: CGRect, panelOrigin: CGPoint) -> CGRect {
        CGRect(
            x: rect.origin.x + panelOrigin.x,
            y: rect.origin.y + panelOrigin.y,
            width: rect.width,
            height: rect.height
        )
    }

    static func appKitPointToQuartz(_ point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    static func quartzWindowRectToAppKitGlobal(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryScreenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    static func quartzWindowRectToPanelLocal(_ rect: CGRect, panelOrigin: CGPoint, primaryScreenHeight: CGFloat) -> CGRect {
        let global = quartzWindowRectToAppKitGlobal(rect, primaryScreenHeight: primaryScreenHeight)
        return CGRect(
            x: global.origin.x - panelOrigin.x,
            y: global.origin.y - panelOrigin.y,
            width: global.width,
            height: global.height
        )
    }
}
