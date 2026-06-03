import AppKit
import ApplicationServices
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CaptureResult {
    let screenshot: ScreenshotFile
    let image: NSImage
    let anchorScreen: NSScreen?
    let isWindowCapture: Bool
}

final class CaptureManager {
    private let configuration: ScreenshotConfiguration
    private let fileManager = FileManager.default
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return formatter
    }()

    init(configuration: ScreenshotConfiguration) {
        self.configuration = configuration
    }

    func captureFullScreen() -> CaptureResult? {
        let screens = NSScreen.screens
        let captureRect = screens.reduce(CGRect.null) { partialResult, screen in
            partialResult.union(screen.frame)
        }

        guard let compositeImage = makeCompositeImage(for: screens, canvasRect: captureRect) else {
            return nil
        }

        let image = NSImage(
            cgImage: compositeImage,
            size: NSSize(width: compositeImage.width, height: compositeImage.height)
        )
        guard let screenshot = save(cgImage: compositeImage) else {
            return nil
        }

        let anchorPoint = NSEvent.mouseLocation
        let anchorScreen = screens.first(where: { $0.frame.contains(anchorPoint) })
        return CaptureResult(screenshot: screenshot, image: image, anchorScreen: anchorScreen, isWindowCapture: false)
    }

    func captureRegion(_ rect: CGRect) -> CaptureResult? {
        let normalizedRect = rect.standardized.integral
        guard normalizedRect.width >= 2, normalizedRect.height >= 2 else { return nil }
        return capture(rect: normalizedRect, anchorPoint: CGPoint(x: normalizedRect.midX, y: normalizedRect.midY), isWindowCapture: false)
    }

    func captureWindow(windowID: CGWindowID, rect: CGRect) -> CaptureResult? {
        guard let cgImage = CGWindowListCreateImage(
            CGRect.null,
            .optionIncludingWindow,
            windowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else { return nil }

        let masked = roundedMask(cgImage, radius: 12)
        let image = NSImage(cgImage: masked ?? cgImage, size: NSSize(width: (masked ?? cgImage).width, height: (masked ?? cgImage).height))
        guard let screenshot = save(cgImage: masked ?? cgImage) else { return nil }

        let anchorScreen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) })
        return CaptureResult(screenshot: screenshot, image: image, anchorScreen: anchorScreen, isWindowCapture: true)
    }

    private func roundedMask(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let w = image.width, h = image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let path = CGPath(roundedRect: rect, cornerWidth: radius * 2, cornerHeight: radius * 2, transform: nil)
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    private func capture(rect: CGRect, anchorPoint: CGPoint, isWindowCapture: Bool) -> CaptureResult? {
        guard let cgImage = CGWindowListCreateImage(
            rect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else { return nil }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let screenshot = save(cgImage: cgImage) else { return nil }

        let anchorScreen = NSScreen.screens.first(where: { $0.frame.contains(anchorPoint) })
        return CaptureResult(screenshot: screenshot, image: image, anchorScreen: anchorScreen, isWindowCapture: isWindowCapture)
    }

    func saveScrollCapture(_ cgImage: CGImage) -> CaptureResult? {
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let screenshot = save(cgImage: cgImage) else { return nil }
        return CaptureResult(screenshot: screenshot, image: image, anchorScreen: NSScreen.main, isWindowCapture: false)
    }

    private func makeCompositeImage(for screens: [NSScreen], canvasRect: CGRect) -> CGImage? {
        let width = Int(canvasRect.width.rounded(.up))
        let height = Int(canvasRect.height.rounded(.up))

        guard width > 0,
              height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.setFillColor(NSColor.clear.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for screen in screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let displayImage = CGDisplayCreateImage(displayID) else {
                continue
            }

            let frame = screen.frame
            let drawRect = CGRect(
                x: frame.minX - canvasRect.minX,
                y: frame.minY - canvasRect.minY,
                width: frame.width,
                height: frame.height
            )

            context.draw(displayImage, in: drawRect)
        }

        return context.makeImage()
    }

    private func save(cgImage: CGImage) -> ScreenshotFile? {
        do {
            try fileManager.createDirectory(at: configuration.directoryURL, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let timestamp = formatter.string(from: Date())
        let baseName = "Screenshot \(timestamp)"
        let fileExtension = configuration.outputExtension
        let fileURL = uniqueFileURL(baseName: baseName, fileExtension: fileExtension)

        guard let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL,
            configuration.outputUTType.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return ScreenshotFile(id: fileURL.path, url: fileURL, createdAt: Date())
    }

    private func uniqueFileURL(baseName: String, fileExtension: String) -> URL {
        var index = 0

        while true {
            let suffix = index == 0 ? "" : " \(index)"
            let fileURL = configuration.directoryURL.appendingPathComponent("\(baseName)\(suffix).\(fileExtension)")
            if !fileManager.fileExists(atPath: fileURL.path) {
                return fileURL
            }
            index += 1
        }
    }
}
