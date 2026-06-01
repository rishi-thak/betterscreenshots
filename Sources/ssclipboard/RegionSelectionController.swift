import AppKit
import Carbon
import Foundation

@MainActor
final class RegionSelectionController: NSObject {
    private var panel: NSPanel?
    private var selectionView: SelectionOverlayView?
    private var onComplete: ((CGRect?) -> Void)?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var globalMouseMonitor: Any?

    func beginSelection(onComplete: @escaping (CGRect?) -> Void) {
        cancelSelection()
        self.onComplete = onComplete

        let frame = NSScreen.screens.reduce(CGRect.null) { partialResult, screen in
            partialResult.union(screen.frame)
        }

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
        selectionView.onComplete = { [weak self] selectionRect in
            guard let self else {
                return
            }
            let globalRect = selectionRect.map { rect in
                CGRect(x: rect.origin.x + frame.origin.x, y: rect.origin.y + frame.origin.y, width: rect.width, height: rect.height)
            }
            self.finishSelection(with: globalRect)
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

    private func finishSelection(with rect: CGRect?) {
        removeEscapeMonitor()
        removeMouseMonitor()
        NSCursor.unhide()
        panel?.orderOut(nil)
        panel = nil
        selectionView = nil
        let callback = onComplete
        onComplete = nil
        callback?(rect)
    }

    private func cancelSelection() {
        guard panel != nil else {
            return
        }
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
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
    }

    private func installMouseMonitor() {
        removeMouseMonitor()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.selectionView?.updateCursorPosition(event.locationInWindow)
        }
    }

    private func removeMouseMonitor() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }
}

@MainActor
private final class SelectionOverlayView: NSView {
    var onComplete: ((CGRect?) -> Void)?

    private var dragStart: CGPoint?
    private var currentPoint: CGPoint?
    private var cursorPoint: CGPoint?
    private var trackingArea: NSTrackingArea?

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
        if let trackingArea { removeTrackingArea(trackingArea) }
        let newTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newTrackingArea)
        trackingArea = newTrackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0, alpha: 0.18).setFill()
        bounds.fill()

        if let selectionRect {
            NSColor.clear.setFill()
            __NSRectFillUsingOperation(selectionRect, .clear)

            let path = NSBezierPath(rect: selectionRect)
            NSColor.white.setStroke()
            path.lineWidth = 2
            path.stroke()
        }

        // Draw software crosshair
        if let p = cursorPoint {
            let color = NSColor(calibratedWhite: 1, alpha: 0.9)
            color.setStroke()
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
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        cursorPoint = currentPoint
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        cursorPoint = currentPoint
        needsDisplay = true
        onComplete?(selectionRect?.standardized.integral)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onComplete?(nil)
            return
        }
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
