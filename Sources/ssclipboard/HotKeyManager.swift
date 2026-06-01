import ApplicationServices
import Carbon
import Foundation

@MainActor
final class HotKeyManager {
    private let onFullScreen: () -> Void
    private let onRegion: () -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHandlingShortcut = false

    init(onFullScreen: @escaping () -> Void, onRegion: @escaping () -> Void) {
        self.onFullScreen = onFullScreen
        self.onRegion = onRegion
    }

    func start() {
        stop()

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let manager = Unmanaged<HotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            return manager.handle(event: event, type: type)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isHandlingShortcut = false
    }

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let requiredFlags: CGEventFlags = [.maskCommand, .maskShift]
        let relevantFlags = flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn])

        guard relevantFlags == requiredFlags else {
            if type == .keyUp {
                isHandlingShortcut = false
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyUp {
            if keyCode == Int64(kVK_ANSI_3) || keyCode == Int64(kVK_ANSI_4) {
                isHandlingShortcut = false
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        guard !isHandlingShortcut else {
            return nil
        }

        switch keyCode {
        case Int64(kVK_ANSI_3):
            isHandlingShortcut = true
            DispatchQueue.main.async { [onFullScreen] in
                onFullScreen()
            }
            return nil
        case Int64(kVK_ANSI_4):
            isHandlingShortcut = true
            DispatchQueue.main.async { [onRegion] in
                onRegion()
            }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
