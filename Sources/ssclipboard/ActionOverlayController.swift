import AppKit
import Foundation

@MainActor
final class ActionOverlayController: NSObject {
    private struct PendingUndoDelete {
        let screenshot: ScreenshotFile
        let trashedURL: URL
    }

    private let panel: NSPanel
    private let containerView = ClickableContainerView()
    private let previewImageView = DraggableImageView()
    private let shareButton = NSButton()
    private let deleteButton = NSButton()
    private let undoButton = NSButton()
    private let buttonStack = NSStackView()
    private let appSettings: AppSettings
    private let onDelete: (ScreenshotFile) -> Void
    private let onOpen: (ScreenshotFile, Bool) -> Void
    private var currentScreenshot: ScreenshotFile?
    private var currentIsWindowCapture = false
    private var autoHideWorkItem: DispatchWorkItem?
    private var undoDeleteWorkItem: DispatchWorkItem?
    private var pendingUndoDelete: PendingUndoDelete?
    private var isVisible = false

    init(
        appSettings: AppSettings = .shared,
        onDelete: @escaping (ScreenshotFile) -> Void = { _ in },
        onOpen: @escaping (ScreenshotFile, Bool) -> Void = { _, _ in }
    ) {
        self.appSettings = appSettings
        self.onDelete = onDelete
        self.onOpen = onOpen
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 232, height: 82),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()
        configurePanel()
        configureSubviews()
        configureInteraction()
    }

    func present(for screenshot: ScreenshotFile, previewImage: NSImage? = nil, on screen: NSScreen? = nil, isWindowCapture: Bool = false) {
        clearUndoDeleteState()
        currentScreenshot = screenshot
        currentIsWindowCapture = isWindowCapture
        previewImageView.image = previewImage ?? NSImage(contentsOf: screenshot.url)
        previewImageView.fileURL = screenshot.url
        deleteButton.isEnabled = FileManager.default.fileExists(atPath: screenshot.url.path)
        deleteButton.isHidden = false
        undoButton.isHidden = true
        SSCLog.overlay.debug("presenting overlay for \(screenshot.url.lastPathComponent, privacy: .public)")

        if let screen = screen ?? NSScreen.main ?? NSScreen.screens.first {
            let visibleFrame = screen.visibleFrame
            let origin = NSPoint(
                x: visibleFrame.maxX - panel.frame.width - 6,
                y: visibleFrame.minY + 24
            )
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()
        if !isVisible {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
            isVisible = true
        }

        scheduleHide()
    }

    @objc
    private func shareScreenshot(_ sender: NSButton) {
        guard let screenshot = currentScreenshot else {
            return
        }

        let picker = NSSharingServicePicker(items: [screenshot.url])
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        scheduleHide()
    }

    @objc
    private func deleteScreenshot(_ sender: NSButton) {
        guard let screenshot = currentScreenshot else {
            return
        }

        deleteButton.isEnabled = false
        NSWorkspace.shared.recycle([screenshot.url]) { [weak self] recycledURLs, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    SSCLog.overlay.error("failed to recycle screenshot: \(error.localizedDescription, privacy: .public)")
                    NSSound.beep()
                    self.deleteButton.isEnabled = FileManager.default.fileExists(atPath: screenshot.url.path)
                    return
                }

                self.onDelete(screenshot)
                guard let trashedURL = recycledURLs[screenshot.url] ?? recycledURLs.values.first else {
                    SSCLog.overlay.warning("recycle succeeded without returned trash URL")
                    self.currentScreenshot = nil
                    self.hideImmediately()
                    return
                }

                SSCLog.overlay.info("screenshot recycled, undo available for 8 seconds")
                self.currentScreenshot = nil
                self.beginUndoDeleteState(screenshot: screenshot, trashedURL: trashedURL)
            }
        }
    }

    @objc
    private func undoDeleteScreenshot(_ sender: NSButton) {
        guard let pendingUndoDelete else {
            return
        }

        undoDeleteWorkItem?.cancel()
        do {
            if FileManager.default.fileExists(atPath: pendingUndoDelete.screenshot.url.path) {
                try FileManager.default.removeItem(at: pendingUndoDelete.screenshot.url)
            }
            try FileManager.default.moveItem(at: pendingUndoDelete.trashedURL, to: pendingUndoDelete.screenshot.url)
            currentScreenshot = pendingUndoDelete.screenshot
            clearUndoDeleteState()
            deleteButton.isEnabled = true
            scheduleHide()
            SSCLog.overlay.info("undo restore succeeded for \(pendingUndoDelete.screenshot.url.lastPathComponent, privacy: .public)")
        } catch {
            SSCLog.overlay.error("undo restore failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            clearUndoDeleteState()
            hideImmediately()
        }
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        panel.isOpaque = false
    }

    private func configureSubviews() {
        guard let contentView = panel.contentView else {
            return
        }

        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 12
        containerView.layer?.masksToBounds = true
        containerView.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 0.94).cgColor

        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.wantsLayer = true
        previewImageView.layer?.cornerRadius = 8
        previewImageView.layer?.masksToBounds = true
        previewImageView.layer?.backgroundColor = NSColor(calibratedWhite: 0.22, alpha: 1).cgColor

        configureButton(
            shareButton,
            title: "",
            symbolName: "square.and.arrow.up",
            action: #selector(shareScreenshot(_:))
        )
        configureButton(
            deleteButton,
            title: "",
            symbolName: "trash",
            action: #selector(deleteScreenshot(_:))
        )
        configureButton(
            undoButton,
            title: "",
            symbolName: "arrow.uturn.backward",
            action: #selector(undoDeleteScreenshot(_:))
        )
        undoButton.toolTip = "Undo delete"
        undoButton.isHidden = true

        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 10
        buttonStack.addArrangedSubview(shareButton)
        buttonStack.addArrangedSubview(deleteButton)
        buttonStack.addArrangedSubview(undoButton)

        contentView.addSubview(containerView)
        containerView.addSubview(previewImageView)
        containerView.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            previewImageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            previewImageView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            previewImageView.widthAnchor.constraint(equalToConstant: 72),
            previewImageView.heightAnchor.constraint(equalToConstant: 54),

            buttonStack.leadingAnchor.constraint(equalTo: previewImageView.trailingAnchor, constant: 12),
            buttonStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            buttonStack.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            buttonStack.heightAnchor.constraint(equalToConstant: 36),

            shareButton.widthAnchor.constraint(equalToConstant: 62),
            deleteButton.widthAnchor.constraint(equalToConstant: 62),
            undoButton.widthAnchor.constraint(equalToConstant: 62)
        ])
    }

    private func configureInteraction() {
        containerView.onClickThrough = { [weak self] in
            guard let self, let screenshot = self.currentScreenshot else { return }
            self.onOpen(screenshot, self.currentIsWindowCapture)
        }
    }

    private func scheduleHide() {
        autoHideWorkItem?.cancel()
        let hideDelay = pendingUndoDelete == nil
            ? appSettings.overlayDurationSeconds
            : max(appSettings.overlayDurationSeconds, 8)

        let workItem = DispatchWorkItem { [weak self] in
            self?.hideAnimated()
        }

        autoHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: workItem)
    }

    private func beginUndoDeleteState(screenshot: ScreenshotFile, trashedURL: URL) {
        pendingUndoDelete = PendingUndoDelete(screenshot: screenshot, trashedURL: trashedURL)
        deleteButton.isHidden = true
        undoButton.isHidden = false

        undoDeleteWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.expireUndoDeleteState()
        }
        undoDeleteWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: workItem)
        scheduleHide()
    }

    private func clearUndoDeleteState() {
        undoDeleteWorkItem?.cancel()
        undoDeleteWorkItem = nil
        pendingUndoDelete = nil
        deleteButton.isHidden = false
        undoButton.isHidden = true
    }

    private func expireUndoDeleteState() {
        guard pendingUndoDelete != nil else {
            clearUndoDeleteState()
            return
        }
        SSCLog.overlay.debug("undo window expired")
        clearUndoDeleteState()
    }

    private func hideImmediately() {
        autoHideWorkItem?.cancel()
        clearUndoDeleteState()
        panel.orderOut(nil)
        panel.alphaValue = 1
        isVisible = false
    }

    private func hideAnimated() {
        guard isVisible else {
            panel.orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    self.panel.orderOut(nil)
                    self.panel.alphaValue = 1
                    self.isVisible = false
                }
            }
        )
    }

    private func configureButton(_ button: NSButton, title: String, symbolName: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: title
        )
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .regularSquare
        button.controlSize = .regular
        button.contentTintColor = .white
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 10
        button.layer?.backgroundColor = NSColor(calibratedWhite: 0.28, alpha: 1).cgColor
        button.target = self
        button.action = action
        button.toolTip = symbolName == "trash" ? "Delete screenshot file" : "Share screenshot"
    }

}

@MainActor
private final class DraggableImageView: NSImageView, NSDraggingSource {
    var fileURL: URL?

    override func mouseDragged(with event: NSEvent) {
        guard let fileURL, let image else { return }

        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        let dragImage = image
        let imageSize = NSSize(width: 72, height: 54)
        item.setDraggingFrame(NSRect(origin: .zero, size: imageSize), contents: dragImage)

        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? [.copy] : []
    }
}

@MainActor
private final class ClickableContainerView: NSView {
    var onClickThrough: (() -> Void)?

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        // Only fire if the click didn't land on a button subview
        let hitButton = subviews.flatMap { $0.subviews + [$0] }.contains {
            $0 is NSButton && $0.frame.contains(convert(pt, to: $0.superview))
        }
        if !hitButton { onClickThrough?() }
    }
}
