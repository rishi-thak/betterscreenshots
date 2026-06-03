import AppKit
import CoreGraphics
import Foundation

// Captures a scrolling area by recording frames while the user scrolls,
// then stitching them into a single tall image by detecting overlapping rows.
@MainActor
final class ScrollingCaptureController: NSObject {
    var onComplete: ((CGImage) -> Void)?

    private var captureTimer: Timer?
    private var frames: [CGImage] = []
    private var targetWindowID: CGWindowID?

    func begin(windowID: CGWindowID) {
        targetWindowID = windowID
        startCapturing()
    }

    private func startCapturing() {
        captureFrame()  // capture first frame immediately
        captureTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.captureFrame() }
        }
    }

    private func captureFrame() {
        guard let wid = targetWindowID else { return }
        guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, wid,
                                                [.bestResolution, .boundsIgnoreFraming]) else { return }
        // Deduplicate: skip if identical to last frame (user hasn't scrolled yet)
        if let last = frames.last, imagesLookSame(last, img) { return }
        frames.append(img)
    }

    @objc func stop() {
        captureTimer?.invalidate()
        captureTimer = nil

        guard !frames.isEmpty else { return }
        let stitched = stitch(frames)
        onComplete?(stitched ?? frames[0])
    }

    // MARK: - Stitch

    private func stitch(_ images: [CGImage]) -> CGImage? {
        guard images.count > 1 else { return images.first }

        let w = images[0].width
        var tiles: [CGImage] = [images[0]]
        var offsets: [Int] = [0]   // Y offset of each tile in the final canvas

        for i in 1 ..< images.count {
            let prev = tiles.last!
            let curr = images[i]
            guard curr.width == w else { continue }

            let overlap = findOverlapRows(bottom: prev, top: curr)
            let uniqueRows = curr.height - overlap
            guard uniqueRows > 4 else { continue }  // skip near-duplicate frame

            offsets.append(offsets.last! + prev.height - overlap)
            tiles.append(curr)
        }

        let totalH = offsets.last! + tiles.last!.height
        guard totalH > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: totalH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return images[0] }

        // Draw from bottom up (CGContext origin is bottom-left)
        for (tile, yOffset) in zip(tiles, offsets) {
            let destY = totalH - yOffset - tile.height
            ctx.draw(tile, in: CGRect(x: 0, y: destY, width: tile.width, height: tile.height))
        }

        return ctx.makeImage()
    }

    /// Returns the number of rows at the bottom of `bottom` that match the top of `top`.
    private func findOverlapRows(bottom: CGImage, top: CGImage) -> Int {
        let w = bottom.width
        guard top.width == w else { return 0 }

        // Sample every 4th pixel in the row for speed
        let step = max(1, w / 64)
        let maxOverlap = min(bottom.height, top.height) - 1
        guard maxOverlap > 0 else { return 0 }

        // Extract pixel rows from both images
        let bottomRows = pixelRows(of: bottom, count: maxOverlap, fromBottom: true)
        let topRows    = pixelRows(of: top,    count: maxOverlap, fromBottom: false)

        // Find the largest k such that the last k rows of `bottom` ≈ the first k rows of `top`
        var best = 0
        for k in Swift.stride(from: 8, through: maxOverlap, by: 1) {
            var match = true
            let checkRows = min(k, 8)  // compare up to 8 rows for speed
            for r in 0 ..< checkRows {
                let bRow = bottomRows[k - 1 - r]
                let tRow = topRows[r]
                if !rowsMatch(bRow, tRow, strideBy: step) { match = false; break }
            }
            if match { best = k }
        }
        return best
    }

    private typealias Row = [UInt32]

    private func pixelRows(of image: CGImage, count: Int, fromBottom: Bool) -> [Row] {
        let w = image.width, h = image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue),
              let data = ctx.data else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let ptr = data.bindMemory(to: UInt32.self, capacity: w * h)
        var rows: [Row] = []
        rows.reserveCapacity(count)
        for i in 0 ..< count {
            // CGContext has bottom-left origin
            let row = fromBottom ? i : (h - 1 - i)
            let start = row * w
            rows.append(Array(UnsafeBufferPointer(start: ptr + start, count: w)))
        }
        return rows
    }

    private func rowsMatch(_ a: Row, _ b: Row, strideBy s: Int) -> Bool {
        var i = 0
        while i < a.count {
            if abs(Int32(bitPattern: a[i]) - Int32(bitPattern: b[i])) > 0x0A0A0A {
                return false
            }
            i += s
        }
        return true
    }

    private func imagesLookSame(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        // Compare a few rows in the middle
        let rows = pixelRows(of: a, count: 4, fromBottom: false)
        let rows2 = pixelRows(of: b, count: 4, fromBottom: false)
        let s = max(1, a.width / 32)
        return zip(rows, rows2).allSatisfy { rowsMatch($0, $1, strideBy: s) }
    }
}
