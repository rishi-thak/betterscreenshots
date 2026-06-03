import AppKit
import Carbon
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
        frames = []
        startCapturing()
    }

    private func startCapturing() {
        captureFrame()  // capture first frame immediately
        captureTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.captureFrame() }
        }
    }

    private func captureFrame() {
        guard let wid = targetWindowID else { NSLog("SSC: captureFrame — no windowID"); return }
        guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, wid,
                                                [.bestResolution, .boundsIgnoreFraming]) else {
            NSLog("SSC: captureFrame — CGWindowListCreateImage returned nil"); return
        }
        if let last = frames.last, imagesLookSame(last, img) { return }
        frames.append(img)
        NSLog("SSC: captured frame %d (%dx%d)", frames.count, img.width, img.height)
    }

    @objc func stop() {
        captureTimer?.invalidate()
        captureTimer = nil
        NSLog("SSC: stop called, frame count: %d", frames.count)
        guard !frames.isEmpty else { return }
        let stitched = stitch(frames)
        NSLog("SSC: stitch result: %@", stitched.map { "\($0.width)x\($0.height)" } ?? "nil")
        onComplete?(stitched ?? frames[0])
    }

    // MARK: - Stitch

    private func stitch(_ images: [CGImage]) -> CGImage? {
        guard images.count > 1 else { return images.first }
        let w = images[0].width

        // Build pixel data for all frames once
        let pixelData = images.compactMap { img -> (CGImage, [[UInt32]])? in
            guard img.width == w else { return nil }
            let rows = allRows(of: img)
            return (img, rows)
        }
        guard !pixelData.isEmpty else { return images.first }

        // For each consecutive pair, find how many rows from the top of `curr`
        // are a duplicate of the bottom of `prev` (i.e. the scroll overlap).
        var tiles: [CGImage] = [pixelData[0].0]
        var uniqueRowCounts: [Int] = [pixelData[0].0.height]

        for i in 1 ..< pixelData.count {
            let (prevImg, prevRows) = pixelData[i - 1]
            let (currImg, currRows) = pixelData[i]
            let overlap = findOverlap(prevRows: prevRows, currRows: currRows)
            let unique = currImg.height - overlap
            guard unique > 4 else { continue }
            tiles.append(currImg)
            uniqueRowCounts.append(unique)
        }

        // Total height = first frame full height + unique rows from each subsequent frame
        let totalH = pixelData[0].0.height + uniqueRowCounts.dropFirst().reduce(0, +)
        guard totalH > pixelData[0].0.height,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: totalH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return images[0] }

        // CGContext origin is bottom-left; draw from bottom to top
        var yBottom = 0
        for (i, tile) in tiles.enumerated().reversed() {
            let drawH = uniqueRowCounts[i]
            // For all but the first tile, crop to only the unique (new) bottom rows
            let srcY = i == 0 ? 0 : (tile.height - drawH)
            if let cropped = tile.cropping(to: CGRect(x: 0, y: srcY, width: w, height: drawH)) {
                ctx.draw(cropped, in: CGRect(x: 0, y: yBottom, width: w, height: drawH))
            }
            yBottom += drawH
        }

        return ctx.makeImage()
    }

    /// Find how many rows at the top of `curr` match rows at the bottom of `prev`.
    private func findOverlap(prevRows: [[UInt32]], currRows: [[UInt32]]) -> Int {
        let ph = prevRows.count, ch = currRows.count
        let maxCheck = min(ph, ch) / 2
        let step = max(1, (prevRows.first?.count ?? 1) / 32)

        for overlap in stride(from: maxCheck, through: 4, by: -1) {
            var match = true
            // Compare last `overlap` rows of prev with first `overlap` rows of curr
            for r in 0 ..< min(overlap, 8) {
                let pr = prevRows[ph - overlap + r]
                let cr = currRows[r]
                if !rowsMatch(pr, cr, strideBy: step) { match = false; break }
            }
            if match { return overlap }
        }
        return 0
    }

    /// Extract all pixel rows from an image. Row 0 = top of image.
    private func allRows(of image: CGImage) -> [[UInt32]] {
        let w = image.width, h = image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let ptr = data.bindMemory(to: UInt32.self, capacity: w * h)
        // CGContext is bottom-left origin; row 0 of the image visually = row (h-1) in memory
        return (0 ..< h).map { visualRow in
            let memRow = (h - 1 - visualRow)
            return Array(UnsafeBufferPointer(start: ptr + memRow * w, count: w))
        }
    }

    private func rowsMatch(_ a: [UInt32], _ b: [UInt32], strideBy s: Int) -> Bool {
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
        let ra = allRows(of: a), rb = allRows(of: b)
        guard ra.count >= 4, rb.count >= 4 else { return false }
        let step = max(1, a.width / 32)
        return (0 ..< 4).allSatisfy { rowsMatch(ra[$0], rb[$0], strideBy: step) }
    }
}
