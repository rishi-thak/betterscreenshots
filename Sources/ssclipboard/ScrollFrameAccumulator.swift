import CoreGraphics
import Foundation

/// Collects scroll-capture frames as decoded rows, sharing storage between
/// identical rows.
///
/// Consecutive scroll frames are mostly the same pixels shifted vertically,
/// and the window chrome is identical in every frame. Keeping each frame as a
/// full bitmap (~24 MB for a large Retina window) let long recordings climb
/// into gigabytes. Here every incoming row is interned: a row whose exact
/// pixels were already seen reuses that row's buffer, so memory grows with the
/// amount of *new* content rather than the number of frames. The stitcher
/// reads the same rows either way, so output is unchanged.
///
/// Not thread-safe: confine each instance to a single serial queue.
final class ScrollFrameAccumulator: @unchecked Sendable {
    static let maxFrames = 200
    /// Ceiling on distinct row storage, for content that never repeats exactly
    /// (e.g. video playing in the scrolled window).
    static let maxUniqueBytes = 1 << 30

    private(set) var frames: [[[UInt32]]] = []
    private var rowsByHash: [Int: [[UInt32]]] = [:]
    private(set) var uniqueBytes = 0

    var isFull: Bool {
        frames.count >= Self.maxFrames || uniqueBytes >= Self.maxUniqueBytes
    }

    /// Returns `true` if the frame was stored, `false` if it was skipped as a
    /// duplicate of the previous frame (user paused) or because the
    /// accumulator is full.
    @discardableResult
    func append(_ image: CGImage) -> Bool {
        guard !isFull else { return false }
        let rows = ScrollingStitcher.rows(of: image)
        guard !rows.isEmpty else { return false }
        if let last = frames.last, ScrollingStitcher.rowsAreDuplicate(last, rows) { return false }
        frames.append(rows.map(intern))
        return true
    }

    private func intern(_ row: [UInt32]) -> [UInt32] {
        var hasher = Hasher()
        row.withUnsafeBytes { hasher.combine(bytes: $0) }
        let key = hasher.finalize()
        if let existing = rowsByHash[key]?.first(where: { $0 == row }) {
            return existing
        }
        rowsByHash[key, default: []].append(row)
        uniqueBytes += row.count * MemoryLayout<UInt32>.stride
        return row
    }
}
