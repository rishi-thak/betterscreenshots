import AppKit
import CoreImage
import Foundation

enum RedactionStyle {
    case blur
    case solidBlack
}

@MainActor
final class ImageRedactionEditorView: NSView {
    private let imageSize: NSSize
    private(set) var regions: [CGRect] = []

    private var dragStartPoint: CGPoint?
    private var draftRectInView: CGRect?

    init(imageSize: NSSize) {
        self.imageSize = imageSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawRegions()
        drawDraftRegion()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        dragStartPoint = point
        draftRectInView = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint else { return }
        let currentPoint = clampToBounds(convert(event.locationInWindow, from: nil))
        draftRectInView = normalizedRect(from: start, to: currentPoint)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartPoint = nil
            draftRectInView = nil
            needsDisplay = true
        }

        guard let draftRectInView else { return }

        let minDimension: CGFloat = 4
        guard draftRectInView.width >= minDimension, draftRectInView.height >= minDimension else {
            return
        }

        let imageRect = viewRectToImageRect(draftRectInView)
        guard imageRect.width > 0, imageRect.height > 0 else { return }
        regions.append(imageRect)
    }

    func clearRegions() {
        regions.removeAll()
        needsDisplay = true
    }

    private func drawRegions() {
        NSColor(calibratedRed: 1, green: 0.2, blue: 0.2, alpha: 0.2).setFill()
        NSColor(calibratedRed: 1, green: 0.35, blue: 0.35, alpha: 0.95).setStroke()

        for imageRect in regions {
            let viewRect = imageRectToViewRect(imageRect)
            let path = NSBezierPath(rect: viewRect)
            path.lineWidth = 1.5
            path.fill()
            path.stroke()
        }
    }

    private func drawDraftRegion() {
        guard let draftRectInView else { return }
        NSColor(calibratedRed: 0.9, green: 0.9, blue: 1, alpha: 0.18).setFill()
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: draftRectInView)
        path.lineWidth = 1.5
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.fill()
        path.stroke()
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func clampToBounds(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func viewRectToImageRect(_ rect: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let scaleX = imageSize.width / bounds.width
        let scaleY = imageSize.height / bounds.height
        return CGRect(
            x: rect.origin.x * scaleX,
            y: rect.origin.y * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral
    }

    private func imageRectToViewRect(_ rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scaleX = bounds.width / imageSize.width
        let scaleY = bounds.height / imageSize.height
        return CGRect(
            x: rect.origin.x * scaleX,
            y: rect.origin.y * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral
    }
}

enum ImageRedactionApplier {
    static func apply(
        to image: NSImage,
        regions: [CGRect],
        style: RedactionStyle
    ) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let extent = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let clampedRegions = regions
            .map { $0.intersection(extent) }
            .filter { !$0.isNull && !$0.isEmpty }

        guard !clampedRegions.isEmpty else { return image }

        switch style {
        case .solidBlack:
            return applySolidRedaction(cgImage: cgImage, regions: clampedRegions)
        case .blur:
            return applyBlurRedaction(cgImage: cgImage, regions: clampedRegions, extent: extent)
        }
    }

    private static func applySolidRedaction(cgImage: CGImage, regions: [CGRect]) -> NSImage? {
        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: cgImage.width,
                  height: cgImage.height,
                  bitsPerComponent: cgImage.bitsPerComponent,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: cgImage.bitmapInfo.rawValue
              ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        context.setFillColor(NSColor.black.cgColor)
        for rect in regions {
            context.fill(rect)
        }

        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: output.width, height: output.height))
    }

    private static func applyBlurRedaction(cgImage: CGImage, regions: [CGRect], extent: CGRect) -> NSImage? {
        let sourceImage = CIImage(cgImage: cgImage)
        let blurred = sourceImage
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 18.0])
            .cropped(to: extent)

        guard let maskImage = createMaskImage(size: extent.size, regions: regions) else {
            return nil
        }

        let maskCI = CIImage(cgImage: maskImage)
        let composited = blurred
            .applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: sourceImage,
                    kCIInputMaskImageKey: maskCI
                ]
            )
            .cropped(to: extent)

        let context = CIContext(options: nil)
        guard let output = context.createCGImage(composited, from: extent) else {
            return nil
        }
        return NSImage(cgImage: output, size: NSSize(width: output.width, height: output.height))
    }

    private static func createMaskImage(size: CGSize, regions: [CGRect]) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        let colorSpace = CGColorSpaceCreateDeviceGray()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.setFillColor(gray: 1, alpha: 1)
        for rect in regions {
            context.fill(rect)
        }

        return context.makeImage()
    }
}
