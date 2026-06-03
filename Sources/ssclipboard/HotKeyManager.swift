import ApplicationServices
import Carbon
import Foundation

/// CGEvent tap that intercepts Cmd+Shift+3/4.
///
/// The tap callback runs on the thread that drives the run loop it is attached to.
/// We attach it to a **dedicated background run loop** so it never touches the main
/// thread at all — no deadlock possible even if the main thread is busy.
final class HotKeyManager: @unchecked Sendable {
    private let onFullScreen: @Sendable () -> Void
    private let onRegion: @Sendable () -> Void

    // Written only from the tap thread; read only from the tap thread.
    private var isHandlingShortcut = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?

    // Optional interceptor set by RegionSelectionController while overlay is active.
    // Must be thread-safe: written on main, read on tap thread.
    var keyInterceptor: (@Sendable (CGEvent) -> Bool)?

    init(onFullScreen: @escaping @Sendable () -> Void,
         onRegion: @escaping @Sendable () -> Void) {
        self.onFullScreen = onFullScreen
        self.onRegion = onRegion
    }

    func start() {
        stop()

        let mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        )

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let mgr = Unmanaged<HotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            return mgr.handle(event: event, type: type)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        // Run the tap on a dedicated background thread — never blocks the main thread.
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "com.rishi.ssclipboard.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()

        eventTap = tap
        runLoopSource = source
        tapThread = thread
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        eventTap = nil
        runLoopSource = nil
        tapThread = nil
        isHandlingShortcut = false
    }

    // Called on the tap thread — must never block, never touch @MainActor state.
    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        // Re-enable tap if macOS disabled it due to timeout.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        // Let region overlay consume keys first.
        if type == .keyDown, let interceptor = keyInterceptor {
            if interceptor(event) { return nil }
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let required: CGEventFlags = [.maskCommand, .maskShift]
        let relevant = flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn])

        guard relevant == required else {
            if type == .keyUp { isHandlingShortcut = false }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyUp {
            if keyCode == Int64(kVK_ANSI_3) || keyCode == Int64(kVK_ANSI_4) {
                isHandlingShortcut = false
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        guard !isHandlingShortcut else { return nil }

        switch keyCode {
        case Int64(kVK_ANSI_3):
            isHandlingShortcut = true
            DispatchQueue.main.async { [onFullScreen] in onFullScreen() }
            return nil
        case Int64(kVK_ANSI_4):
            isHandlingShortcut = true
            DispatchQueue.main.async { [onRegion] in onRegion() }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
