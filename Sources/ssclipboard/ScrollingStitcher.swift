import CoreGraphics
import Foundation

// Stitches a sequence of full-window frames captured while the user scrolls
// into a single tall image.
//
// The key insight that makes this robust: a scrolling window has a *static*
// top band (title bar / toolbar) and often a static bottom band (status bar /
// footer) that never move, while only the middle "content band" scrolls. We
// detect those static bands, align ONLY the content band across frames using
// full-width row correlation, and compose: top chrome (once) + stitched
// content + bottom chrome (once).
enum ScrollingStitcher {
    // Average per-channel (0...255) difference below which two sampled rows are
    // considered identical when looking for the non-scrolling chrome bands.
    private static let staticTolerance: Double = 6
    // Average per-channel difference below which a candidate band alignment is
    // accepted as a real overlap.
    private static let matchTolerance: Double = 14
    // Overlap between consecutive frames must be at least this fraction of the
    // content band (with a small absolute floor for tiny test images).
    private static let minOverlapFraction: Double = 0.1
    private static let minOverlapFloor = 2
    // Number of columns sampled per row when comparing pixels.
    private static let columnSamples = 64
    // Cap on rows compared per candidate alignment (keeps stitching well under a
    // second even for tall Retina windows).
    private static let maxRowComparisons = 400

    static func stitch(frames images: [CGImage]) -> CGImage? {
        guard let firstImage = images.first else { return nil }
        guard images.count > 1 else { return firstImage }

        // Normalize to the modal dimensions; drop frames that don't match (e.g.
        // a window resize mid-capture).
        let width = modalValue(images.map(\.width)) ?? firstImage.width
        let height = modalValue(images.filter { $0.width == width }.map(\.height)) ?? firstImage.height
        let frames = images.filter { $0.width == width && $0.height == height }
        guard frames.count > 1 else { return frames.first ?? firstImage }

        let rowsPerFrame = frames.map { allRows(of: $0) }
        guard rowsPerFrame.allSatisfy({ $0.count == height && ($0.first?.count ?? 0) == width }) else {
            return frames.first
        }

        let columnStride = max(1, width / columnSamples)

        // 1. Detect the non-scrolling top and bottom chrome bands.
        let (contentTop, contentBottom) = contentBand(
            rowsPerFrame: rowsPerFrame, height: height, columnStride: columnStride
        )
        let bandHeight = contentBottom - contentTop
        guard bandHeight > 8 else {
            // Nothing actually scrolled (or band too small) — nothing to stitch.
            return frames.first
        }

        let rowStride = max(1, bandHeight / maxRowComparisons)
        let minOverlap = max(minOverlapFloor, Int(Double(bandHeight) * minOverlapFraction))

        // 2. Compute each frame's absolute vertical offset relative to frame 0.
        //    Positive delta == content scrolled up (the common downward read).
        var offsets = [Int](repeating: 0, count: frames.count)
        var anchor = 0  // last frame we successfully aligned against
        for index in 1 ..< frames.count {
            let delta = bandDisplacement(
                prev: rowsPerFrame[anchor],
                curr: rowsPerFrame[index],
                top: contentTop,
                bottom: contentBottom,
                columnStride: columnStride,
                rowStride: rowStride,
                minOverlap: minOverlap
            )
            switch delta {
            case .some(0):
                // Duplicate band — keep the previous anchor, place at same spot.
                offsets[index] = offsets[anchor]
            case let .some(value):
                offsets[index] = offsets[anchor] + value
                anchor = index
            case .none:
                // No reliable overlap (scrolled too far between frames). Best
                // effort: continue downward, contiguous, so we never overwrite.
                offsets[index] = offsets[anchor] + bandHeight
                anchor = index
            }
        }

        // 3. Compose.
        let minOffset = offsets.min() ?? 0
        let maxOffset = offsets.map { $0 + bandHeight }.max() ?? bandHeight
        let contentHeight = maxOffset - minOffset
        let topChrome = contentTop
        let bottomChrome = height - contentBottom
        let totalHeight = topChrome + contentHeight + bottomChrome
        guard totalHeight > height else { return frames.first }

        var output = [[UInt32]](repeating: [], count: totalHeight)

        // Top chrome from the first frame.
        for row in 0 ..< topChrome {
            output[row] = rowsPerFrame[0][row]
        }
        // Bottom chrome from the last frame.
        for offset in 0 ..< bottomChrome {
            output[totalHeight - bottomChrome + offset] = rowsPerFrame[frames.count - 1][contentBottom + offset]
        }
        // Content band, written in capture order so the freshest pixels win in
        // overlapping regions.
        for (index, rows) in rowsPerFrame.enumerated() {
            let base = topChrome + (offsets[index] - minOffset)
            for local in 0 ..< bandHeight {
                output[base + local] = rows[contentTop + local]
            }
        }

        // Fill any row that somehow stayed empty (shouldn't happen — coverage is
        // contiguous — but never emit garbage).
        let blank = [UInt32](repeating: 0xFF00_0000, count: width)
        for row in 0 ..< totalHeight where output[row].count != width {
            output[row] = blank
        }

        return makeImage(visualRows: output, width: width)
    }

    /// Cheap whole-frame equality check used by the capture controller to skip
    /// frames recorded while the user has paused scrolling.
    static func framesAreDuplicate(_ lhs: CGImage, _ rhs: CGImage) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return false }
        let lhsRows = allRows(of: lhs)
        let rhsRows = allRows(of: rhs)
        guard lhsRows.count == rhsRows.count, lhsRows.count > 0 else { return false }
        let columnStride = max(1, lhs.width / columnSamples)
        let rowStride = max(1, lhsRows.count / 120)
        var row = 0
        while row < lhsRows.count {
            if averageChannelDiff(lhsRows[row], rhsRows[row], columnStride: columnStride) > staticTolerance {
                return false
            }
            row += rowStride
        }
        return true
    }

    // MARK: - Band detection

    private static func contentBand(
        rowsPerFrame: [[[UInt32]]], height: Int, columnStride: Int
    ) -> (top: Int, bottom: Int) {
        guard rowsPerFrame.count > 1 else { return (0, height) }

        func rowIsStaticAcrossAllFrames(_ row: Int) -> Bool {
            for index in 1 ..< rowsPerFrame.count {
                let diff = averageChannelDiff(
                    rowsPerFrame[index - 1][row], rowsPerFrame[index][row], columnStride: columnStride
                )
                if diff > staticTolerance { return false }
            }
            return true
        }

        var top = 0
        while top < height, rowIsStaticAcrossAllFrames(top) { top += 1 }

        var bottom = height
        while bottom > top, rowIsStaticAcrossAllFrames(bottom - 1) { bottom -= 1 }

        return (top, bottom)
    }

    /// Vertical displacement of `curr`'s content band relative to `prev`'s.
    /// Returns `nil` when no alignment is reliable, `0` for duplicates, a
    /// positive value when content scrolled up (read downward), negative when
    /// content scrolled down (read upward).
    private static func bandDisplacement(
        prev: [[UInt32]],
        curr: [[UInt32]],
        top: Int,
        bottom: Int,
        columnStride: Int,
        rowStride: Int,
        minOverlap: Int
    ) -> Int? {
        let bandHeight = bottom - top
        let maxShift = bandHeight - minOverlap
        guard maxShift >= 0 else { return nil }

        var bestDelta: Int?
        var bestError = Double.greatestFiniteMagnitude

        for delta in -maxShift ... maxShift {
            // Overlapping band-local rows q where both q and q+delta are valid.
            let qStart = max(0, -delta)
            let qEnd = min(bandHeight, bandHeight - delta)
            let overlap = qEnd - qStart
            guard overlap >= minOverlap else { continue }

            var total = 0.0
            var samples = 0
            var q = qStart
            while q < qEnd {
                total += averageChannelDiff(
                    curr[top + q], prev[top + q + delta], columnStride: columnStride
                )
                samples += 1
                q += rowStride
            }
            guard samples > 0 else { continue }
            let error = total / Double(samples)

            // Prefer the lowest error; on a tie prefer the smaller shift (larger
            // overlap), which is the safer assumption for dense capture.
            if error < bestError - 0.001 ||
                (abs(error - bestError) <= 0.001 && abs(delta) < abs(bestDelta ?? Int.max)) {
                bestError = error
                bestDelta = delta
            }
        }

        guard let bestDelta, bestError <= matchTolerance else { return nil }
        return bestDelta
    }

    // MARK: - Pixel helpers

    private static func averageChannelDiff(_ lhs: [UInt32], _ rhs: [UInt32], columnStride: Int) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return 0 }
        var total = 0
        var samples = 0
        var index = 0
        while index < count {
            let a = lhs[index]
            let b = rhs[index]
            let ar = Int(a & 0xFF), ag = Int((a >> 8) & 0xFF), ab = Int((a >> 16) & 0xFF)
            let br = Int(b & 0xFF), bg = Int((b >> 8) & 0xFF), bb = Int((b >> 16) & 0xFF)
            total += abs(ar - br) + abs(ag - bg) + abs(ab - bb)
            samples += 1
            index += columnStride
        }
        guard samples > 0 else { return 0 }
        return Double(total) / Double(samples * 3)
    }

    private static func modalValue(_ values: [Int]) -> Int? {
        var counts: [Int: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key < rhs.key
        }?.key
    }

    private static func allRows(of image: CGImage) -> [[UInt32]] {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let data = context.data else {
            return []
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pointer = data.bindMemory(to: UInt32.self, capacity: width * height)
        return (0 ..< height).map { visualRow in
            let memoryRow = height - 1 - visualRow
            return Array(UnsafeBufferPointer(start: pointer + memoryRow * width, count: width))
        }
    }

    private static func makeImage(visualRows: [[UInt32]], width: Int) -> CGImage? {
        let height = visualRows.count
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let data = context.data else {
            return nil
        }

        let pointer = data.bindMemory(to: UInt32.self, capacity: width * height)
        for visualRow in 0 ..< height {
            let row = visualRows[visualRow]
            guard row.count == width else { continue }
            let memoryRow = height - 1 - visualRow
            let destination = pointer + memoryRow * width
            row.withUnsafeBufferPointer { source in
                destination.update(from: source.baseAddress!, count: width)
            }
        }
        return context.makeImage()
    }
}
