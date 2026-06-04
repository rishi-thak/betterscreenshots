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
        guard let wid = targetWindowID else {
            SSCLog.scroll.warning("captureFrame skipped: missing window id")
            return
        }
        guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, wid,
                                                [.bestResolution, .boundsIgnoreFraming]) else {
            SSCLog.scroll.error("captureFrame failed: CGWindowListCreateImage returned nil")
            return
        }
        if let last = frames.last, ScrollingStitcher.imagesLookSame(last, img) { return }
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
