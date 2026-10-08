import AppKit
import Carbon
import CoreGraphics
import Foundation

// Captures a scrolling area by recording frames while the user scrolls,
// then stitching them into a single tall image by detecting overlapping rows.
@MainActor
final class ScrollingCaptureController: NSObject {
    /// Called on the main actor with the stitched image, or `nil` if nothing
    /// was captured.
    var onComplete: ((CGImage?) -> Void)?

    // Dense sampling gives consecutive frames a large overlap, which is what
    // makes the stitch alignment reliable.
    private static let captureInterval: TimeInterval = 0.18

    // Grabbing, decoding, de-duplicating and stitching frames all happen on
    // this serial queue so the main thread never stalls during or after a
    // recording. The accumulator is only ever touched from here.
    private let processingQueue = DispatchQueue(label: "com.rishi.ssclipboard.scrollcapture", qos: .userInitiated)
    private var accumulator = ScrollFrameAccumulator()
    private var captureTimer: Timer?
    private var targetWindowID: CGWindowID?
    // True while a frame is being grabbed/processed; timer ticks that land
    // during that time are dropped rather than queued up behind it.
    private var frameInFlight = false

    func begin(windowID: CGWindowID) {
        targetWindowID = windowID
        accumulator = ScrollFrameAccumulator()
        frameInFlight = false
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
        guard !frameInFlight else { return }
        frameInFlight = true
        let accumulator = accumulator
        processingQueue.async { [weak self] in
            defer { Task { @MainActor [weak self] in self?.frameInFlight = false } }
            // Once full, keep the recording UI alive but ignore further frames.
            guard !accumulator.isFull else { return }
            guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, wid,
                                                    [.bestResolution, .boundsIgnoreFraming]) else {
                SSCLog.scroll.error("captureFrame failed: CGWindowListCreateImage returned nil")
                return
            }
            guard accumulator.append(img) else { return }
            SSCLog.scroll.debug("captured frame \(accumulator.frames.count, privacy: .public) (\(img.width, privacy: .public)x\(img.height, privacy: .public)), \(accumulator.uniqueBytes / 1_048_576, privacy: .public) MB unique rows")
            if accumulator.isFull {
                SSCLog.scroll.info("scroll capture reached its frame/memory limit; ignoring further frames")
            }
        }
    }

    @objc func stop() {
        guard let timer = captureTimer else { return }  // already stopped
        timer.invalidate()
        captureTimer = nil
        targetWindowID = nil

        let accumulator = accumulator
        self.accumulator = ScrollFrameAccumulator()
        // Serial queue: this runs after any frame still being processed.
        processingQueue.async { [weak self] in
            let frames = accumulator.frames
            SSCLog.scroll.info("stop called with \(frames.count, privacy: .public) frame(s)")
            let stitched = frames.isEmpty ? nil : ScrollingStitcher.stitch(rowFrames: frames)
            let stitchedDimensions = stitched.map { "\($0.width)x\($0.height)" } ?? "nil"
            SSCLog.scroll.info("stitch result: \(stitchedDimensions, privacy: .public)")
            Task { @MainActor [weak self] in self?.onComplete?(stitched) }
        }
    }
}
