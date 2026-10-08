import AppKit
import ApplicationServices
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A grabbed image that hasn't been written to disk yet. Grabbing is fast and
/// stays on the main thread; encoding and saving happen in `save(_:)`.
struct CapturedImage {
    let cgImage: CGImage
    let anchorScreen: NSScreen?
    let isWindowCapture: Bool
}

struct SavedCapture: Sendable {
    let screenshot: ScreenshotFile
    /// PNG bytes for the clipboard, when requested.
    let clipboardPNG: Data?
}

@MainActor
final class CaptureManager {
    private let configuration: ScreenshotConfiguration

    init(configuration: ScreenshotConfiguration) {
        self.configuration = configuration
    }

    func captureFullScreen() -> CapturedImage? {
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

        return CapturedImage(cgImage: cgImage, anchorScreen: screen, isWindowCapture: false)
    }

    func captureRegion(_ rect: CGRect) -> CapturedImage? {
        let normalizedRect = rect.standardized.integral
        guard normalizedRect.width >= 2, normalizedRect.height >= 2 else { return nil }
        return capture(rect: normalizedRect, anchorPoint: CGPoint(x: normalizedRect.midX, y: normalizedRect.midY), isWindowCapture: false)
    }

    func captureWindow(windowID: CGWindowID, rect: CGRect) -> CapturedImage? {
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
        let anchorScreen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) })
        return CapturedImage(cgImage: outputImage, anchorScreen: anchorScreen, isWindowCapture: true)
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

    private func capture(rect: CGRect, anchorPoint: CGPoint, isWindowCapture: Bool) -> CapturedImage? {
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

        let anchorScreen = NSScreen.screens.first(where: { $0.frame.contains(anchorPoint) })
        return CapturedImage(cgImage: cgImage, anchorScreen: anchorScreen, isWindowCapture: isWindowCapture)
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

    /// Encodes and writes the image off the main thread. When
    /// `includeClipboardPNG` is set, also returns PNG bytes for the clipboard
    /// (the file's own bytes when it is a PNG, so nothing is encoded twice).
    func save(_ cgImage: CGImage, includeClipboardPNG: Bool) async -> SavedCapture? {
        let configuration = configuration
        // Name the file for when it was captured, not when encoding finished.
        let capturedAt = Date()
        return await Task.detached(priority: .userInitiated) {
            Self.encodeAndWrite(
                cgImage,
                capturedAt: capturedAt,
                configuration: configuration,
                includeClipboardPNG: includeClipboardPNG
            )
        }.value
    }

    private nonisolated static func encodeAndWrite(
        _ cgImage: CGImage,
        capturedAt: Date,
        configuration: ScreenshotConfiguration,
        includeClipboardPNG: Bool
    ) -> SavedCapture? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: configuration.directoryURL, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let image = ImageCompaction.compacted(cgImage)
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            configuration.outputUTType.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            encodingProperties(for: configuration.outputUTType) as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        let baseName = CaptureNaming.baseName(date: capturedAt)
        guard let fileURL = reserveUniqueFileURL(
            baseName: baseName,
            fileExtension: configuration.outputExtension,
            directoryURL: configuration.directoryURL
        ) else {
            return nil
        }
        do {
            try (encoded as Data).write(to: fileURL)
        } catch {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }

        var clipboardPNG: Data?
        if includeClipboardPNG {
            clipboardPNG = configuration.outputUTType == .png
                ? encoded as Data
                : ClipboardWriter.pngData(for: image)
        }
        return SavedCapture(
            screenshot: ScreenshotFile(id: fileURL.path, url: fileURL, createdAt: capturedAt),
            clipboardPNG: clipboardPNG
        )
    }

    /// Lossy formats default to near-maximum quality in ImageIO, which bloats
    /// JPEG/HEIC screenshots for no visible gain; 0.85 matches what macOS's
    /// own screencapture produces.
    nonisolated static func encodingProperties(for type: UTType) -> [CFString: Any] {
        switch type {
        case .jpeg, .heic:
            return [kCGImageDestinationLossyCompressionQuality: 0.85]
        default:
            return [:]
        }
    }

    /// Atomically claims a unique filename via O_CREAT|O_EXCL instead of only
    /// check-then-write, which would leave a window for a concurrent capture
    /// to land on the same name and get silently overwritten.
    private nonisolated static func reserveUniqueFileURL(
        baseName: String,
        fileExtension: String,
        directoryURL: URL,
        maxAttempts: Int = 50
    ) -> URL? {
        for _ in 0..<maxAttempts {
            let candidate = CaptureNaming.uniqueFileURL(
                baseName: baseName,
                fileExtension: fileExtension,
                directoryURL: directoryURL,
                fileExists: FileManager.default.fileExists(atPath:)
            )
            let fd = open(candidate.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 {
                close(fd)
                return candidate
            }
            guard errno == EEXIST else { return nil }
        }
        return nil
    }
}
