import CoreGraphics
import Foundation
import Testing
@testable import ssclipboard

private let chromeTop: UInt8 = 250
private let chromeBottom: UInt8 = 251
private let topRows = 4
private let bottomRows = 3
private let bandHeight = 20
private let documentLength = 60
private let imageWidth = 16

// MARK: - Real-world scroll simulation (the bug that was reported)

@Test
func stitchRemovesFixedChromeAndReconstructsDownwardScroll() throws {
    let frames = try downwardScrollFrames(step: 5)
    let stitched = try #require(ScrollingStitcher.stitch(frames: frames))

    #expect(stitched.width == imageWidth)
    // top chrome (once) + full document + bottom chrome (once)
    #expect(stitched.height == topRows + documentLength + bottomRows)
    let values = sampleRowValues(of: stitched)
    #expect(values.filter { $0 == chromeTop }.count == topRows)
    #expect(values.filter { $0 == chromeBottom }.count == bottomRows)
    for documentRow in 0 ..< documentLength {
        #expect(values.filter { $0 == contentValue(documentRow) }.count == 1,
                "document row \(documentRow) should appear exactly once")
    }
}

@Test
func stitchReconstructsUpwardScroll() throws {
    let frames = try downwardScrollFrames(step: 5).reversed()
    let stitched = try #require(ScrollingStitcher.stitch(frames: Array(frames)))

    #expect(stitched.height == topRows + documentLength + bottomRows)
    let values = sampleRowValues(of: stitched)
    for documentRow in 0 ..< documentLength {
        #expect(values.filter { $0 == contentValue(documentRow) }.count == 1)
    }
}

@Test
func stitchSurvivesDuplicateFrames() throws {
    // Simulate the user pausing: repeat frames in the middle of the scroll.
    var frames = try downwardScrollFrames(step: 5)
    frames.insert(frames[2], at: 3)
    frames.insert(frames[2], at: 3)

    let stitched = try #require(ScrollingStitcher.stitch(frames: frames))
    #expect(stitched.height == topRows + documentLength + bottomRows)
    let values = sampleRowValues(of: stitched)
    for documentRow in 0 ..< documentLength {
        #expect(values.filter { $0 == contentValue(documentRow) }.count == 1)
    }
}

@Test
func framesAreDuplicateDetectsIdenticalAndDistinctFrames() throws {
    let frames = try downwardScrollFrames(step: 5)
    #expect(ScrollingStitcher.framesAreDuplicate(frames[0], frames[0]))
    #expect(!ScrollingStitcher.framesAreDuplicate(frames[0], frames[1]))
}

@Test
func stitchReturnsSingleFrameWhenNothingScrolled() throws {
    let frame = try makeFrame(contentStart: 0, step: 5)
    let stitched = try #require(ScrollingStitcher.stitch(frames: [frame, frame, frame]))
    #expect(stitched.height == frame.height)
}

// MARK: - Original minimal overlap case

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

// MARK: - Fixtures

/// Distinct, high-contrast grayscale value for each document row. Spaced far
/// enough apart that consecutive frames are never mistaken for static chrome.
private func contentValue(_ documentRow: Int) -> UInt8 {
    UInt8(8 + (documentRow % documentLength) * 4)  // 8...244, all unique
}

/// A frame is: fixed top chrome + a 20-row window into a 60-row document +
/// fixed bottom chrome. `contentStart` is the first document row visible.
private func makeFrame(contentStart: Int, step: Int) throws -> CGImage {
    var rows = [UInt8](repeating: 0, count: topRows + bandHeight + bottomRows)
    for index in 0 ..< topRows { rows[index] = chromeTop }
    for offset in 0 ..< bandHeight {
        rows[topRows + offset] = contentValue(contentStart + offset)
    }
    for index in 0 ..< bottomRows { rows[topRows + bandHeight + index] = chromeBottom }
    return try makeGrayImage(width: imageWidth, rowValues: rows)
}

private func downwardScrollFrames(step: Int) throws -> [CGImage] {
    var frames: [CGImage] = []
    var start = 0
    while start + bandHeight <= documentLength {
        frames.append(try makeFrame(contentStart: start, step: step))
        start += step
    }
    return frames
}

/// Reads one representative grayscale value per visual row (top to bottom).
private func sampleRowValues(of image: CGImage) -> [UInt8] {
    let width = image.width
    let height = image.height
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ),
          let data = context.data else {
        return []
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pointer = data.bindMemory(to: UInt32.self, capacity: width * height)
    return (0 ..< height).map { visualRow in
        let memoryRow = height - 1 - visualRow
        return UInt8(pointer[memoryRow * width] & 0xFF)
    }
}

/// Builds a grayscale image where `rowValues[0]` is the top visual row.
private func makeGrayImage(width: Int, rowValues: [UInt8]) throws -> CGImage {
    let height = rowValues.count
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    for (row, value) in rowValues.enumerated() {
        let rowStart = row * bytesPerRow
        for column in 0 ..< width {
            let index = rowStart + column * 4
            pixels[index] = value
            pixels[index + 1] = value
            pixels[index + 2] = value
            pixels[index + 3] = 255
        }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
        throw NSError(domain: "ScrollingCaptureStitchTests", code: 1)
    }
    guard let image = CGImage(
        width: width, height: height,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ) else {
        throw NSError(domain: "ScrollingCaptureStitchTests", code: 2)
    }
    return image
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
