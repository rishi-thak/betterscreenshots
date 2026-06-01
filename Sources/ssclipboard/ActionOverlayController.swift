import AppKit
import Foundation

@MainActor
final class ActionOverlayController: NSObject {
    private let panel: NSPanel
    private let containerView = NSView()
    private let previewImageView = DraggableImageView()
    private let shareButton = NSButton()
    private let deleteButton = NSButton()
    private let buttonStack = NSStackView()
    private let onDelete: (ScreenshotFile) -> Void
    private let onOpen: (ScreenshotFile) -> Void
    private var currentScreenshot: ScreenshotFile?
    private var autoHideWorkItem: DispatchWorkItem?
    private var isVisible = false

    init(
        onDelete: @escaping (ScreenshotFile) -> Void = { _ in },
        onOpen: @escaping (ScreenshotFile) -> Void = { _ in }
    ) {
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

    func present(for screenshot: ScreenshotFile, previewImage: NSImage? = nil, on screen: NSScreen? = nil) {
        currentScreenshot = screenshot
        previewImageView.image = previewImage ?? NSImage(contentsOf: screenshot.url)
        previewImageView.fileURL = screenshot.url
        deleteButton.isEnabled = FileManager.default.fileExists(atPath: screenshot.url.path)

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

        do {
            try FileManager.default.removeItem(at: screenshot.url)
            onDelete(screenshot)
            deleteButton.isEnabled = false
            currentScreenshot = nil
            hideImmediately()
        } catch {
            NSSound.beep()
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

        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 10
        buttonStack.addArrangedSubview(shareButton)
        buttonStack.addArrangedSubview(deleteButton)

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
            deleteButton.widthAnchor.constraint(equalToConstant: 62)
        ])
    }

    private func configureInteraction() {
        let clickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(openScreenshot))
        clickRecognizer.buttonMask = 0x1
        containerView.addGestureRecognizer(clickRecognizer)
    }

    private func scheduleHide() {
        autoHideWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.hideAnimated()
        }

        autoHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: workItem)
    }

    private func hideImmediately() {
        autoHideWorkItem?.cancel()
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

    @objc
    private func openScreenshot(_ recognizer: NSClickGestureRecognizer) {
        let location = recognizer.location(in: containerView)
        if buttonStack.frame.contains(location) {
            return
        }

        guard let screenshot = currentScreenshot else {
            return
        }

        onOpen(screenshot)
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
