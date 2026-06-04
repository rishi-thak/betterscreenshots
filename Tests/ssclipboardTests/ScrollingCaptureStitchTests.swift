import CoreGraphics
import Foundation
import Testing
@testable import ssclipboard

@Test
func scrollingStitcherStitchesFramesWithOverlap() throws {
    let width = 24
    let first = try makeStripedImage(width: width, rowValues: Array(0 ... 11))
    let second = try makeStripedImage(width: width, rowValues: Array(7 ... 18))

    let stitched = ScrollingStitcher.stitch(frames: [first, second])

    #expect(stitched != nil)
    #expect(stitched?.width == width)
    #expect(stitched!.height > first.height)
    #expect(stitched!.height >= 18)
}

private func makeStripedImage(width: Int, rowValues: [UInt8]) throws -> CGImage {
    let height = rowValues.count
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    for (row, value) in rowValues.enumerated() {
        let y = height - 1 - row
        let rowStart = y * bytesPerRow
        for column in 0 ..< width {
            let index = rowStart + (column * bytesPerPixel)
            pixels[index] = value
            pixels[index + 1] = value
            pixels[index + 2] = value
            pixels[index + 3] = 255
        }
    }

    let provider = CGDataProvider(data: Data(pixels) as CFData)
    guard let provider else {
        throw NSError(domain: "ScrollingCaptureStitchTests", code: 1)
    }

    guard let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ) else {
        throw NSError(domain: "ScrollingCaptureStitchTests", code: 2)
    }

    return image
}
