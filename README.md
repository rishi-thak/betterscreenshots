# SSClipboard

A lightweight, invisible macOS screenshot agent that intercepts the standard screenshot hotkeys, captures the screen directly, and immediately copies the result to your clipboard — no extra steps required.

It runs as a background login agent with no Dock icon, no menu bar icon, and no UI of its own. The only visible surface is a small transient overlay that appears after each capture with quick **Share** and **Delete** actions.

---

## Features

- **Instant clipboard copy** — every capture is written to the clipboard the moment it's taken, before you've even moved your mouse
- **Full-screen capture** — `Cmd+Shift+3` composites all connected displays into a single image
- **Region / window capture** — `Cmd+Shift+4` opens a crosshair overlay; click a window to snap it with rounded corners, or drag to select an arbitrary region
- **Saves to your screenshot folder** — respects the location and format configured in `com.apple.screencapture` (defaults to Desktop, PNG)
- **Transient action overlay** — a small panel appears in the bottom-right corner for 6 seconds with Share and Delete buttons; click the preview thumbnail to open the full viewer
- **Full-screen viewer** — zoom, copy, share, reveal in Finder, delete, and add a decorative background to window captures
- **Background editor** — for window captures, choose a gradient or solid-color background, adjust padding, and lock to a common aspect ratio (1:1, 4:3, 16:9, 3:2) before saving
- **Runs at login** — installed as a `launchd` LaunchAgent so it's always available

---

## Requirements

- macOS 13 Ventura or later
- Xcode Command Line Tools (`xcode-select --install`)
- **Screen Recording** permission (prompted on first launch)
- **Accessibility** permission (required for the global hotkey tap)

---

## Hotkeys

| Shortcut | Action |
|---|---|
| `Cmd+Shift+3` | Full-screen capture (all displays) |
| `Cmd+Shift+4` | Region / window capture |

> **Important:** these shortcuts shadow the built-in macOS screenshot shortcuts. For SSClipboard to intercept them reliably, disable or rebind the native ones in:
>
> **System Settings → Keyboard → Keyboard Shortcuts → Screenshots**

---

## Build

```bash
./scripts/build_app.sh
```

The script:
1. Runs `swift build -c release`
2. Assembles `dist/SSClipboard.app` with the correct `Info.plist`
3. Code-signs the bundle if a Developer ID or Apple Development certificate is available (auto-detected via `security find-identity`)

The finished bundle is written to:

```
dist/SSClipboard.app
```

To override the signing identity:

```bash
SSC_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build_app.sh
```

---

## Install as a Login Agent

```bash
./scripts/install_launch_agent.sh
```

This script:
1. Builds the app (calls `build_app.sh` internally)
2. Copies the bundle to `~/Applications/SSClipboard.app`
3. Writes a LaunchAgent plist to `~/Library/LaunchAgents/com.rishi.ssclipboard.plist`
4. Loads the agent with `launchctl load`

The agent is configured with `RunAtLoad = true` and `KeepAlive = true`, so it starts immediately and restarts automatically if it ever exits.

To uninstall:

```bash
launchctl unload ~/Library/LaunchAgents/com.rishi.ssclipboard.plist
rm ~/Library/LaunchAgents/com.rishi.ssclipboard.plist
rm -rf ~/Applications/SSClipboard.app
```

---

## Permissions

On first launch, SSClipboard requests two permissions:

**Screen Recording** (`ScreenCaptureKit` / `CGWindowListCreateImage`)
Required to capture screen content. Prompted automatically. If denied, captures will silently fail (the app beeps). Grant it in **System Settings → Privacy & Security → Screen Recording**.

**Accessibility** (`CGEvent.tapCreate`)
Required to intercept global keyboard events for the hotkeys. Prompted automatically. If denied, hotkeys won't fire. Grant it in **System Settings → Privacy & Security → Accessibility**.

After granting Screen Recording for the first time, the app schedules a restart (1 second delay) so the new entitlement takes effect.

---

## Architecture

SSClipboard is a Swift Package Manager executable that links AppKit, ApplicationServices, Carbon, ImageIO, and UniformTypeIdentifiers directly — no SwiftUI, no Xcode project file.

```
Sources/ssclipboard/
├── main.swift                      # NSApplication bootstrap, .prohibited activation policy
├── AppDelegate.swift               # Creates and starts ScreenshotAgent
├── ScreenshotAgent.swift           # Top-level coordinator
├── HotKeyManager.swift             # CGEvent tap for Cmd+Shift+3/4
├── CaptureManager.swift            # CGWindowListCreateImage / CGDisplayCreateImage
├── RegionSelectionController.swift # Full-screen crosshair overlay panel + window snap
├── ScreenshotMonitor.swift         # DispatchSource file-system watcher (unused in hotkey path)
├── ScreenshotViewerController.swift# Full viewer window + background editor
├── ActionOverlayController.swift   # Transient bottom-right panel
├── ClipboardWriter.swift           # NSPasteboard helper
├── ScreenshotConfiguration.swift   # Reads com.apple.screencapture defaults
├── ScreenshotClassifier.swift      # Filename heuristic for screenshot detection
├── ScreenshotFile.swift            # Value type: id, url, createdAt
├── AccessibilityPermissionManager.swift
└── ScreenCapturePermissionManager.swift
```

### Key components

**`ScreenshotAgent`** is the central coordinator. It holds all subsystems and wires them together: permission managers → hotkey manager → capture manager → overlay/viewer.

**`HotKeyManager`** installs a `CGEvent` tap at `.cgSessionEventTap` with `.headInsertEventTap` placement. It intercepts `keyDown`/`keyUp` events for `kVK_ANSI_3` and `kVK_ANSI_4` when `Cmd+Shift` is the only modifier, suppresses the original event (returns `nil`), and dispatches to the appropriate capture path. A re-enable guard handles `tapDisabledByTimeout`.

**`CaptureManager`** has three capture modes:
- `captureFullScreen()` — iterates `NSScreen.screens`, calls `CGDisplayCreateImage` per display, composites them onto a single `CGContext` canvas, saves to disk, and returns the result
- `captureRegion(_:)` — calls `CGWindowListCreateImage` with `.optionOnScreenOnly` for the selected rect
- `captureWindow(windowID:rect:)` — calls `CGWindowListCreateImage` with `.optionIncludingWindow` and `.boundsIgnoreFraming`, then applies a 12pt rounded-corner mask via a `CGContext` clip path

**`RegionSelectionController`** creates a borderless `NSPanel` at `.screenSaver` level spanning all displays. The embedded `SelectionOverlayView` draws a semi-transparent tint, a software crosshair, and a window-snap highlight. On mouse-up with drag distance < 5pt it treats the gesture as a window click and queries `CGWindowListCopyWindowInfo` for the frontmost normal-layer window under the cursor.

**`ActionOverlayController`** is a non-activating `NSPanel` at `.statusBar` level. It fades in on presentation, auto-hides after 6 seconds, and supports drag-to-share from the preview thumbnail via `NSDraggingSource`.

**`ScreenshotViewerController`** is a full `NSWindow` with a dark background, a scrollable/zoomable `NSImageView`, and a frosted-glass toolbar. The background editor (`BackgroundEditorView`) composites the window screenshot onto a gradient or solid-color canvas at a chosen aspect ratio and padding, previewing live before saving.

**`ScreenshotConfiguration`** reads `UserDefaults(suiteName: "com.apple.screencapture")` for the `location` and `type` keys so captures land in the same folder and format as native macOS screenshots.

---

## Why a custom overlay instead of the system thumbnail

macOS does not expose a public API for injecting buttons into the native screenshot preview thumbnail. SSClipboard runs as an agent (`.prohibited` activation policy, no Dock icon) and presents its own panel instead.

---

## Development

```bash
# Debug build and run
swift run

# Release build only
swift build -c release

# Tests
swift test
```

The package targets Swift 6 language mode (`swiftLanguageModes: [.v6]`). All AppKit work is isolated to `@MainActor`; background work (file I/O, image encoding) runs on dedicated `DispatchQueue`s.
