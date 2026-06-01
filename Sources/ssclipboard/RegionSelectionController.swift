import AppKit
import Carbon
import Foundation

struct RegionResult {
    let rect: CGRect
    let windowID: CGWindowID?  // non-nil when user snapped to a window
}

@MainActor
final class RegionSelectionController: NSObject {
    private var panel: NSPanel?
    private var selectionView: SelectionOverlayView?
    private var onComplete: ((RegionResult?) -> Void)?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var globalMouseMonitor: Any?

    func beginSelection(onComplete: @escaping (RegionResult?) -> Void) {
        cancelSelection()
        self.onComplete = onComplete

        let frame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.setFrame(frame, display: true)

        let selectionView = SelectionOverlayView(frame: CGRect(origin: .zero, size: frame.size))
        selectionView.panelOrigin = frame.origin
        selectionView.onComplete = { [weak self] result in
            guard let self else { return }
            self.finishSelection(with: result)
        }

        panel.contentView = selectionView
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(selectionView)
        installEscapeMonitor()
        installMouseMonitor()
        NSCursor.hide()

        self.panel = panel
        self.selectionView = selectionView
    }

    private func finishSelection(with result: RegionResult?) {
        removeEscapeMonitor()
        removeMouseMonitor()
        NSCursor.unhide()
        panel?.orderOut(nil)
        panel = nil
        selectionView = nil
        let callback = onComplete
        onComplete = nil
        callback?(result)
    }

    private func cancelSelection() {
        guard panel != nil else { return }
        finishSelection(with: nil)
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.finishSelection(with: nil)
                return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                self?.finishSelection(with: nil)
            }
        }
    }

    private func removeEscapeMonitor() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
    }

    private func installMouseMonitor() {
        removeMouseMonitor()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.selectionView?.updateCursorPosition(event.locationInWindow)
        }
    }

    private func removeMouseMonitor() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
    }
}

// MARK: - Window info helpers

private func frontmostWindowInfo(at screenPoint: CGPoint) -> (id: CGWindowID, rect: CGRect)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }

    // CGWindowListCopyWindowInfo returns windows front-to-back; skip the selection panel itself
    for info in list {
        guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
              let wid = info[kCGWindowNumber as String] as? CGWindowID else { continue }

        let rect = CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0
        )
        guard rect.width > 10, rect.height > 10, rect.contains(screenPoint) else { continue }
        return (wid, rect)
    }
    return nil
}

// MARK: - Overlay view

@MainActor
private final class SelectionOverlayView: NSView {
    var onComplete: ((RegionResult?) -> Void)?
    var panelOrigin: CGPoint = .zero  // global origin of the panel frame

    private var dragStart: CGPoint?
    private var currentPoint: CGPoint?
    private var cursorPoint: CGPoint?
    private var trackingArea: NSTrackingArea?

    // Window snap state
    private var snapWindowID: CGWindowID?
    private var snapRect: CGRect?   // in view coordinates

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    func updateCursorPosition(_ point: CGPoint) {
        cursorPoint = point
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        let viewPt = convert(event.locationInWindow, from: nil)
        cursorPoint = viewPt

        // Only snap-highlight when not dragging
        guard dragStart == nil else { needsDisplay = true; return }

        // Convert view point to global screen coordinates (Quartz/CG origin = bottom-left of primary screen)
        let screenPt = CGPoint(x: viewPt.x + panelOrigin.x, y: viewPt.y + panelOrigin.y)
        // CG uses top-left origin; convert
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgPt = CGPoint(x: screenPt.x, y: primaryHeight - screenPt.y)

        if let win = frontmostWindowInfo(at: cgPt) {
            snapWindowID = win.id
            // Convert CG rect (top-left origin) back to view coordinates
            let winRectNS = CGRect(
                x: win.rect.origin.x - panelOrigin.x,
                y: primaryHeight - win.rect.origin.y - win.rect.height - panelOrigin.y,
                width: win.rect.width,
                height: win.rect.height
            )
            snapRect = winRectNS
        } else {
            snapWindowID = nil
            snapRect = nil
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Tint overlay
        NSColor(calibratedWhite: 0, alpha: 0.18).setFill()
        bounds.fill()

        // Window snap highlight
        if dragStart == nil, let sr = snapRect {
            // Clear the window area
            NSColor.clear.setFill()
            __NSRectFillUsingOperation(sr, .clear)
            // Blue highlight border
            let path = NSBezierPath(roundedRect: sr, xRadius: 8, yRadius: 8)
            NSColor.systemBlue.withAlphaComponent(0.35).setFill()
            path.fill()
            NSColor.systemBlue.setStroke()
            path.lineWidth = 2
            path.stroke()
        }

        // Manual selection rect
        if let selectionRect {
            NSColor.clear.setFill()
            __NSRectFillUsingOperation(selectionRect, .clear)
            let path = NSBezierPath(rect: selectionRect)
            NSColor.white.setStroke()
            path.lineWidth = 2
            path.stroke()
        }

        // Software crosshair
        if let p = cursorPoint {
            NSColor(calibratedWhite: 1, alpha: 0.9).setStroke()
            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: p.x, y: bounds.minY))
            cross.line(to: CGPoint(x: p.x, y: bounds.maxY))
            cross.move(to: CGPoint(x: bounds.minX, y: p.y))
            cross.line(to: CGPoint(x: bounds.maxX, y: p.y))
            cross.lineWidth = 1
            cross.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        dragStart = location
        currentPoint = location
        cursorPoint = location
        // Clear snap highlight once drag starts
        snapRect = nil
        snapWindowID = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        cursorPoint = currentPoint
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let upPoint = convert(event.locationInWindow, from: nil)
        currentPoint = upPoint
        cursorPoint = upPoint
        needsDisplay = true

        guard let start = dragStart else { return }
        let dragDistance = hypot(upPoint.x - start.x, upPoint.y - start.y)

        if dragDistance < 5 {
            // Treat as window snap click — re-query window under cursor
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let screenPt = CGPoint(x: upPoint.x + panelOrigin.x, y: upPoint.y + panelOrigin.y)
            let cgPt = CGPoint(x: screenPt.x, y: primaryHeight - screenPt.y)

            if let win = frontmostWindowInfo(at: cgPt) {
                // Convert CG window rect to global NS coordinates for capture
                let globalRect = CGRect(
                    x: win.rect.origin.x,
                    y: primaryHeight - win.rect.origin.y - win.rect.height,
                    width: win.rect.width,
                    height: win.rect.height
                )
                onComplete?(RegionResult(rect: globalRect, windowID: win.id))
            } else {
                onComplete?(nil)
            }
        } else {
            // Normal drag selection — convert to global coordinates
            guard let sel = selectionRect else { onComplete?(nil); return }
            let globalRect = CGRect(
                x: sel.origin.x + panelOrigin.x,
                y: sel.origin.y + panelOrigin.y,
                width: sel.width,
                height: sel.height
            )
            onComplete?(RegionResult(rect: globalRect, windowID: nil))
        }
        dragStart = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { onComplete?(nil); return }
        super.keyDown(with: event)
    }

    private var selectionRect: CGRect? {
        guard let dragStart, let currentPoint else { return nil }
        let rect = CGRect(
            x: min(dragStart.x, currentPoint.x),
            y: min(dragStart.y, currentPoint.y),
            width: abs(currentPoint.x - dragStart.x),
            height: abs(currentPoint.y - dragStart.y)
        )
        guard rect.width >= 2, rect.height >= 2 else { return nil }
        return rect
    }
}
