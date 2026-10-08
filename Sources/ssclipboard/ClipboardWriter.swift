import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes images to the pasteboard as compressed PNG bytes.
///
/// `NSPasteboard.writeObjects([NSImage])` publishes an uncompressed TIFF
/// (~24 MB for a single Retina full-screen shot, hundreds of MB for a scroll
/// capture), and that TIFF is what most apps receive on paste. Publishing
/// `public.png` instead keeps pastes the same size as the file on disk.
final class ClipboardWriter {
    /// Copies an already-encoded screenshot file. PNG files are put on the
    /// pasteboard byte-for-byte (no re-encode); other formats are re-encoded
    /// to PNG since many apps don't accept HEIC/JPEG pastes.
    func copyImage(at url: URL) -> Bool {
        if UTType(filenameExtension: url.pathExtension) == .png,
           let data = try? Data(contentsOf: url) {
            return write(pngData: data)
        }
        guard let image = NSImage(contentsOf: url) else { return false }
        return copyImage(image)
    }

    func copyImage(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = Self.pngData(for: cgImage) else {
            return false
        }
        return write(pngData: data)
    }

    private func write(pngData: Data) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setData(pngData, forType: .png)
    }

    static func pngData(for cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, ImageCompaction.compacted(cgImage), nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Size reductions that don't change how the image looks.
enum ImageCompaction {
    /// Screen captures come back as RGBA even though every pixel is opaque.
    /// Redrawing into an alpha-less sRGB context drops the alpha channel,
    /// which shrinks PNG output by ~15%. Images with real transparency (e.g.
    /// rounded-corner window captures) are returned unchanged.
    static func compacted(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        guard isFullyOpaque(image),
              let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              colorSpace.model == .rgb,
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return image
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    private static func isFullyOpaque(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
              ) else {
            return false
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data else { return false }
        let bytesPerRow = context.bytesPerRow
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let rowStart = pixels + row * bytesPerRow
            for column in 0..<width where rowStart[column] != 0xFF {
                return false
            }
        }
        return true
    }
}
