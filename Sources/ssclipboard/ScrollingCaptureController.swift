import AppKit
import Carbon
import CoreGraphics
import Foundation

// Captures a scrolling area by recording frames while the user scrolls,
// then stitching them into a single tall image by detecting overlapping rows.
@MainActor
final class ScrollingCaptureController: NSObject {
    var onComplete: ((CGImage) -> Void)?

    // Dense sampling gives consecutive frames a large overlap, which is what
    // makes the stitch alignment reliable.
    private static let captureInterval: TimeInterval = 0.18
    // Upper bound on stored (deduplicated) frames so a long recording can't grow
    // memory without limit.
    private static let maxFrames = 200

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
        captureTimer = Timer.scheduledTimer(withTimeInterval: Self.captureInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.captureFrame() }
        }
    }

    private func captureFrame() {
        guard let wid = targetWindowID else {
            SSCLog.scroll.warning("captureFrame skipped: missing window id")
            return
        }
        guard frames.count < Self.maxFrames else { return }
        guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, wid,
                                                [.bestResolution, .boundsIgnoreFraming]) else {
            SSCLog.scroll.error("captureFrame failed: CGWindowListCreateImage returned nil")
            return
        }
        // Skip frames recorded while the window content is unchanged (paused).
        if let last = frames.last, ScrollingStitcher.framesAreDuplicate(last, img) { return }
        frames.append(img)
        SSCLog.scroll.debug("captured frame \(self.frames.count, privacy: .public) (\(img.width, privacy: .public)x\(img.height, privacy: .public))")
    }

    @objc func stop() {
        captureTimer?.invalidate()
        captureTimer = nil
        SSCLog.scroll.info("stop called with \(self.frames.count, privacy: .public) frame(s)")
        guard !frames.isEmpty else { return }
        let stitched = ScrollingStitcher.stitch(frames: frames)
        let stitchedDimensions = stitched.map { "\($0.width)x\($0.height)" } ?? "nil"
        SSCLog.scroll.info("stitch result: \(stitchedDimensions, privacy: .public)")
        onComplete?(stitched ?? frames[0])
    }
}
