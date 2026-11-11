import AppKit
import Carbon
import Foundation

struct RegionResult {
    let rect: CGRect
    let windowID: CGWindowID?
    let scrollMode: Bool
}

/// Region / window selection overlay.
///
/// One borderless panel is placed on *each* screen rather than one panel
/// spanning all of them: with "Displays have separate Spaces" (the macOS
/// default) a window is only ever shown on a single display, so a spanning
/// panel left every other monitor uncovered. All selection state lives here,
/// in global AppKit coordinates (bottom-left of the primary screen); each
/// screen's view just forwards mouse events and draws its slice of that state.
@MainActor
final class RegionSelectionController: NSObject {
    private var panels: [SelectionPanel] = []
    private var onComplete: ((RegionResult?) -> Void)?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var dragPollTimer: Timer?
    private var openedAt = Date()

    // Selection state, all in global AppKit coordinates.
    fileprivate private(set) var dragStart: CGPoint?
    fileprivate private(set) var currentPoint: CGPoint?
    fileprivate private(set) var cursorPoint: CGPoint?
    fileprivate private(set) var snapWindowID: CGWindowID?
    fileprivate private(set) var snapRect: CGRect?
    fileprivate private(set) var scrollMode = false  // toggled by Space when a window is snapped

    /// Installed into the CGEvent tap while selection is active.
    /// Returns true to suppress the event system-wide.
    private(set) var keyInterceptor: (@Sendable (CGEvent) -> Bool)?

    func beginSelection(onComplete: @escaping (RegionResult?) -> Void) {
        cancelSelection()
        self.onComplete = onComplete
        resetState()
        openedAt = Date()

        let mouseLocation = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let panel = SelectionPanel(screen: screen, controller: self)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Key status goes to the panel under the cursor so local key events
        // (Escape) land somewhere sensible; the CGEvent tap interceptor below
        // is the primary key path either way.
        let keyPanel = panels.first { $0.frame.contains(mouseLocation) } ?? panels.first
        keyPanel?.makeKeyAndOrderFront(nil)
        if let view = keyPanel?.contentView { keyPanel?.makeFirstResponder(view) }

        installEscapeMonitor()
        installMouseMonitor()
        NSCursor.hide()
        mouseMoved(to: mouseLocation)

        self.keyInterceptor = { [weak self] event in
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Int64(kVK_Escape) {
                DispatchQueue.main.async { self?.finishSelection(with: nil) }
                return true
            }
            if keyCode == Int64(kVK_Space) {
                DispatchQueue.main.async { self?.toggleScrollMode() }
                return true
            }
            return false
        }
    }

    // MARK: - Mouse handling (global AppKit coordinates)

    fileprivate func mouseMoved(to point: CGPoint) {
        cursorPoint = point
        // Only snap-highlight when not dragging.
        if dragStart == nil {
            if let win = frontmostWindowInfo(at: quartzPoint(point)) {
                if win.id != snapWindowID { scrollMode = false }
                snapWindowID = win.id
                snapRect = CoordinateConversion.quartzWindowRectToAppKitGlobal(
                    win.rect,
                    primaryScreenHeight: primaryScreenHeight
                )
            } else {
                snapWindowID = nil
                snapRect = nil
            }
        }
        redraw()
    }

    fileprivate func mouseDown(at point: CGPoint) {
        SSCLog.selection.info("mouseDown \(self.elapsedMs, privacy: .public)ms after open")
        dragStart = point
        currentPoint = point
        cursorPoint = point
        startDragPolling()
        redraw()
    }

    fileprivate func mouseDragged(to point: CGPoint) {
        guard dragStart != nil else { return }
        currentPoint = point
        cursorPoint = point
        redraw()
    }

    fileprivate func mouseUp(at point: CGPoint) {
        guard dragStart != nil else {
            // A release with no matching press (e.g. the press was eaten by
            // window activation) must not count as a click.
            SSCLog.selection.info("mouseUp without mouseDown ignored")
            return
        }
        // Fast drags right after the overlay opens can get a mouse-up from
        // AppKit while the button is still physically held (the overlay is
        // still taking focus). Ignore it; the poll below ends the drag when
        // the button is really released.
        if Self.isLeftButtonDown {
            SSCLog.selection.info("mouseUp ignored: button still held, \(self.elapsedMs, privacy: .public)ms after open")
            return
        }
        endDrag(at: point)
    }

    /// While the button is held, follow the real cursor and button state
    /// instead of relying only on drag/up events reaching the overlay.
    private func startDragPolling() {
        dragPollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollDrag() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragPollTimer = timer
    }

    private func pollDrag() {
        guard dragStart != nil else { stopDragPolling(); return }
        let location = NSEvent.mouseLocation
        if !Self.isLeftButtonDown {
            SSCLog.selection.info("drag ended by button release poll")
            endDrag(at: location)
        } else if location != currentPoint {
            currentPoint = location
            cursorPoint = location
            redraw()
        }
    }

    private func stopDragPolling() {
        dragPollTimer?.invalidate()
        dragPollTimer = nil
    }

    private static var isLeftButtonDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

    private var elapsedMs: Int { Int(Date().timeIntervalSince(openedAt) * 1000) }

    private func endDrag(at point: CGPoint) {
        stopDragPolling()
        guard let start = dragStart else { return }
        currentPoint = point
        cursorPoint = point
        let dragDistance = hypot(point.x - start.x, point.y - start.y)
        SSCLog.selection.info("drag ended distance=\(Int(dragDistance), privacy: .public) \(self.elapsedMs, privacy: .public)ms after open")

        if dragDistance < 5 {
            // Click: capture the window under the cursor.
            if let win = frontmostWindowInfo(at: quartzPoint(point)) {
                let globalRect = CoordinateConversion.quartzWindowRectToAppKitGlobal(
                    win.rect,
                    primaryScreenHeight: primaryScreenHeight
                )
                SSCLog.selection.info("mouseUp snap windowID=\(win.id, privacy: .public) scrollMode=\(self.scrollMode, privacy: .public)")
                finishSelection(with: RegionResult(rect: globalRect, windowID: win.id, scrollMode: scrollMode))
            } else {
                SSCLog.selection.debug("mouseUp snap had no window match")
                finishSelection(with: nil)
            }
        } else if let selection = selectionRect {
            finishSelection(with: RegionResult(rect: selection, windowID: nil, scrollMode: false))
        } else {
            finishSelection(with: nil)
        }
    }

    fileprivate func toggleScrollMode() {
        guard let wid = snapWindowID, let rect = snapRect, dragStart == nil, !scrollMode else { return }
        scrollMode = true
        redraw()
        finishSelection(with: RegionResult(rect: rect, windowID: wid, scrollMode: true))
    }

    /// The dragged rectangle in global coordinates, if it is big enough.
    fileprivate var selectionRect: CGRect? {
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

    // MARK: - Lifecycle

    fileprivate func finishSelection(with result: RegionResult?) {
        guard onComplete != nil || !panels.isEmpty else { return }
        stopDragPolling()
        removeEscapeMonitor()
        removeMouseMonitor()
        NSCursor.unhide()
        keyInterceptor = nil
        for panel in panels { panel.orderOut(nil) }
        panels = []
        resetState()
        let callback = onComplete
        onComplete = nil
        callback?(result)
    }

    private func cancelSelection() {
        guard !panels.isEmpty else { return }
        finishSelection(with: nil)
    }

    private func resetState() {
        dragStart = nil
        currentPoint = nil
        cursorPoint = nil
        snapWindowID = nil
        snapRect = nil
        scrollMode = false
    }

    private func redraw() {
        for panel in panels { panel.contentView?.needsDisplay = true }
    }

    private var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    private func quartzPoint(_ point: CGPoint) -> CGPoint {
        CoordinateConversion.appKitPointToQuartz(point, primaryScreenHeight: primaryScreenHeight)
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
        // Backup for hover tracking if mouse-moved events go to another app.
        // Global monitor events carry no window, so use the screen location.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.mouseMoved(to: NSEvent.mouseLocation)
        }
    }

    private func removeMouseMonitor() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
    }
}

// MARK: - Window info helpers

private func frontmostWindowInfo(at screenPoint: CGPoint) -> (id: CGWindowID, rect: CGRect)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }

    // CGWindowListCopyWindowInfo returns windows front-to-back. The selection
    // panels sit at screen-saver level, so the layer-0 filter skips them.
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

// MARK: - Per-screen panel

@MainActor
private final class SelectionPanel: NSPanel {
    init(screen: NSScreen, controller: RegionSelectionController) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isMovable = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: false)
        contentView = SelectionOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size), controller: controller)
    }

    // Borderless windows refuse key status by default, which left the overlay
    // unable to take keyboard focus.
    override var canBecomeKey: Bool { true }
}

// MARK: - Overlay view

@MainActor
private final class SelectionOverlayView: NSView {
    private weak var controller: RegionSelectionController?
    private var trackingArea: NSTrackingArea?

    init(frame: CGRect, controller: RegionSelectionController) {
        self.controller = controller
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    // The overlay belongs to a background (accessory) app, so it is never the
    // active window when the user presses the mouse. Without this, AppKit
    // spends that first press on focusing the window instead of delivering
    // it, so the drag never starts and a later click is taken as a window snap.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    /// Event location in global AppKit coordinates. Works for drags that
    /// leave this screen too: AppKit keeps sending them to the window that
    /// received the mouse-down, with locations outside its bounds.
    private func globalLocation(of event: NSEvent) -> CGPoint {
        guard let window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) { controller?.mouseMoved(to: globalLocation(of: event)) }
    override func mouseDown(with event: NSEvent) { controller?.mouseDown(at: globalLocation(of: event)) }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged(to: globalLocation(of: event)) }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp(at: globalLocation(of: event)) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { controller?.finishSelection(with: nil); return }
        super.keyDown(with: event)
    }

    /// Converts a global rect into this view's coordinates.
    private func local(_ rect: CGRect) -> CGRect {
        let origin = window?.frame.origin ?? .zero
        return rect.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    private func local(_ point: CGPoint) -> CGPoint {
        let origin = window?.frame.origin ?? .zero
        return CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller else { return }

        // Tint overlay
        NSColor(calibratedWhite: 0, alpha: 0.18).setFill()
        bounds.fill()

        // Window snap highlight
        if controller.dragStart == nil, let snap = controller.snapRect {
            let sr = local(snap)
            if sr.intersects(bounds) {
                NSColor.clear.setFill()
                __NSRectFillUsingOperation(sr, .clear)
                let path = NSBezierPath(roundedRect: sr, xRadius: 8, yRadius: 8)
                let tint = controller.scrollMode ? NSColor.systemGreen : NSColor.systemBlue
                tint.withAlphaComponent(0.35).setFill()
                path.fill()
                tint.setStroke()
                path.lineWidth = 2
                path.stroke()

                // Hint label
                let label = controller.scrollMode ? "Recording — Return or Esc to stop" : "Space to record scroll"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.white
                ]
                let size = (label as NSString).size(withAttributes: attrs)
                let labelRect = CGRect(x: sr.midX - size.width / 2, y: sr.maxY + 8, width: size.width, height: size.height)
                (label as NSString).draw(in: labelRect, withAttributes: attrs)
            }
        }

        // Manual selection rect (may span screens; each view draws its part)
        if let selection = controller.selectionRect {
            let rect = local(selection)
            if rect.intersects(bounds) {
                NSColor.clear.setFill()
                __NSRectFillUsingOperation(rect, .clear)
                let path = NSBezierPath(rect: rect)
                NSColor.white.setStroke()
                path.lineWidth = 2
                path.stroke()
            }
        }

        // Software crosshair, only on the screen the cursor is on
        if let cursor = controller.cursorPoint {
            let p = local(cursor)
            if bounds.contains(p) {
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
    }
}
