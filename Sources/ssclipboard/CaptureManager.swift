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

    init(configuration: ScreenshotConfiguration) {
        self.configuration = configuration
    }

    func captureFullScreen() -> CaptureResult? {
        // Capture only the display the cursor is currently on, rather than
        // compositing every screen. NSEvent.mouseLocation is in global AppKit
        // coordinates (bottom-left origin); NSScreen.frame uses the same space.
        let screens = NSScreen.screens
        let anchorPoint = NSEvent.mouseLocation
        let targetScreen = screens.first(where: { $0.frame.contains(anchorPoint) })
            ?? NSScreen.main
            ?? screens.first

        guard let screen = targetScreen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let cgImage = captureExcludingOwnWindows(rect: CGDisplayBounds(displayID)) else {
            return nil
        }

        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        guard let screenshot = save(cgImage: cgImage) else {
            return nil
        }

        return CaptureResult(screenshot: screenshot, image: image, anchorScreen: screen, isWindowCapture: false)
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

        // JPEG has no alpha; rounded corners would flatten to black without a matte.
        let outputImage: CGImage
        if configuration.outputUTType == .jpeg {
            outputImage = cgImage
        } else if let masked = roundedMask(cgImage, radius: 12) {
            outputImage = masked
        } else {
            outputImage = cgImage
        }
        let image = NSImage(cgImage: outputImage, size: NSSize(width: outputImage.width, height: outputImage.height))
        guard let screenshot = save(cgImage: outputImage) else { return nil }

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
        // CGWindowListCreateImage uses Quartz coordinates (top-left origin, Y down).
        // The incoming rect is in AppKit screen coordinates (bottom-left origin, Y up).
        // Flip Y: quartzY = primaryScreenHeight - (appKitY + height)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let quartzRect = CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        ).integral

        guard let cgImage = captureExcludingOwnWindows(rect: quartzRect) else { return nil }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let screenshot = save(cgImage: cgImage) else { return nil }

        let anchorScreen = NSScreen.screens.first(where: { $0.frame.contains(anchorPoint) })
        return CaptureResult(screenshot: screenshot, image: image, anchorScreen: anchorScreen, isWindowCapture: isWindowCapture)
    }

    /// Composites every on-screen window in the given Quartz-coordinate rect
    /// EXCEPT windows owned by this process. This keeps SSClipboard's own UI —
    /// the action-overlay card and preview, the scroll-recording HUD, the
    /// region-selection panel — out of full-screen and region captures while
    /// leaving it fully visible to the user on screen.
    ///
    /// `CGDisplayCreateImage` (raw framebuffer) and `NSWindow.sharingType` are
    /// not reliable for this: the former ignores per-window sharing entirely,
    /// the latter behaves inconsistently across macOS versions. Explicitly
    /// excluding our own window IDs is deterministic.
    private func captureExcludingOwnWindows(rect: CGRect) -> CGImage? {
        let myPID = getpid()
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // CGWindowListCopyWindowInfo returns windows front-to-back, which is the
        // order CGWindowListCreateImageFromArray composites them in.
        var windowIDs: [CGWindowID] = []
        windowIDs.reserveCapacity(infoList.count)
        for info in infoList {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            if let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == myPID {
                continue
            }
            windowIDs.append(id)
        }

        guard !windowIDs.isEmpty else { return nil }

        // The CFArray must hold the raw CGWindowID values reinterpreted as
        // pointers, not CFNumbers.
        var pointers: [UnsafeRawPointer?] = windowIDs.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let windowArray = CFArrayCreate(kCFAllocatorDefault, &pointers, pointers.count, nil) else {
            return nil
        }

        return CGImage(
            windowListFromArrayScreenBounds: rect,
            windowArray: windowArray,
            imageOption: [.bestResolution, .boundsIgnoreFraming]
        )
    }

    func saveScrollCapture(_ cgImage: CGImage) -> CaptureResult? {
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let screenshot = save(cgImage: cgImage) else { return nil }
        return CaptureResult(screenshot: screenshot, image: image, anchorScreen: NSScreen.main, isWindowCapture: false)
    }

    private func save(cgImage: CGImage) -> ScreenshotFile? {
        do {
            try fileManager.createDirectory(at: configuration.directoryURL, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let baseName = CaptureNaming.baseName(date: Date())
        let fileExtension = configuration.outputExtension
        let fileURL = CaptureNaming.uniqueFileURL(
            baseName: baseName,
            fileExtension: fileExtension,
            directoryURL: configuration.directoryURL,
            fileExists: fileManager.fileExists(atPath:)
        )

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
}
