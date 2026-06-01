import AppKit
import Foundation

@MainActor
final class ScreenshotViewerController: NSObject {
    private let clipboardWriter: ClipboardWriter
    private let onDelete: (ScreenshotFile) -> Void

    private let window: NSWindow
    private let rootView = NSView()
    private let toolbarView = NSVisualEffectView()
    private let imageScrollView = NSScrollView()
    private let imageView = NSImageView()
    private let documentView = NSView()
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let titleLabel = NSTextField(labelWithString: "Screenshot")

    private let closeButton = NSButton()
    private let copyButton = NSButton()
    private let shareButton = NSButton()
    private let revealButton = NSButton()
    private let deleteButton = NSButton()
    private let zoomOutButton = NSButton()
    private let zoomInButton = NSButton()

    private var currentScreenshot: ScreenshotFile?
    private var currentImage: NSImage?
    private var zoomScale: CGFloat = 1
    private let imageInset: CGFloat = 24

    init(clipboardWriter: ClipboardWriter, onDelete: @escaping (ScreenshotFile) -> Void) {
        self.clipboardWriter = clipboardWriter
        self.onDelete = onDelete
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()
        configureWindow()
        configureViews()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    @objc private func windowDidResignKey() {
        window.orderOut(nil)
    }

    func present(screenshot: ScreenshotFile) {
        currentScreenshot = screenshot
        currentImage = NSImage(contentsOf: screenshot.url)
        imageView.image = currentImage
        titleLabel.stringValue = screenshot.url.lastPathComponent
        deleteButton.isEnabled = FileManager.default.fileExists(atPath: screenshot.url.path)
        setZoomScale(1)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureWindow() {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        window.minSize = NSSize(width: 780, height: 520)

        guard let contentView = window.contentView else { return }
        rootView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootView)
        NSLayoutConstraint.activate([
            rootView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rootView.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func configureViews() {
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor

        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.material = .underWindowBackground
        toolbarView.blendingMode = .withinWindow
        toolbarView.state = .active

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        imageScrollView.translatesAutoresizingMaskIntoConstraints = false
        imageScrollView.drawsBackground = false
        imageScrollView.hasVerticalScroller = true
        imageScrollView.hasHorizontalScroller = true
        imageScrollView.borderType = .noBorder

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true

        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(imageView)
        imageScrollView.documentView = documentView

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: imageInset),
            imageView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: imageInset)
        ])

        configureToolbarButton(closeButton, symbol: "xmark", toolTip: "Close", action: #selector(closeViewer))
        configureToolbarButton(copyButton, symbol: "doc.on.doc", toolTip: "Copy", action: #selector(copyScreenshot))
        configureToolbarButton(shareButton, symbol: "square.and.arrow.up", toolTip: "Share", action: #selector(shareScreenshot(_:)))
        configureToolbarButton(revealButton, symbol: "folder", toolTip: "Show in Finder", action: #selector(revealInFinder))
        configureToolbarButton(deleteButton, symbol: "trash", toolTip: "Delete", action: #selector(deleteScreenshot))
        configureToolbarButton(zoomOutButton, symbol: "minus", toolTip: "Zoom Out", action: #selector(zoomOut))
        configureToolbarButton(zoomInButton, symbol: "plus", toolTip: "Zoom In", action: #selector(zoomIn))

        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        zoomLabel.textColor = NSColor(calibratedWhite: 0.86, alpha: 1)
        zoomLabel.alignment = .center

        rootView.addSubview(toolbarView)
        rootView.addSubview(imageScrollView)

        let leftStack = NSStackView(views: [closeButton, copyButton, shareButton, revealButton, deleteButton])
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        leftStack.orientation = .horizontal
        leftStack.spacing = 8
        leftStack.alignment = .centerY

        let rightStack = NSStackView(views: [zoomOutButton, zoomLabel, zoomInButton])
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.orientation = .horizontal
        rightStack.spacing = 8
        rightStack.alignment = .centerY

        toolbarView.addSubview(leftStack)
        toolbarView.addSubview(titleLabel)
        toolbarView.addSubview(rightStack)

        NSLayoutConstraint.activate([
            toolbarView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            toolbarView.topAnchor.constraint(equalTo: rootView.topAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 58),

            imageScrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            imageScrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            imageScrollView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            imageScrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            leftStack.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 16),
            leftStack.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            rightStack.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -16),
            rightStack.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -16),
            titleLabel.centerXAnchor.constraint(equalTo: toolbarView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            zoomLabel.widthAnchor.constraint(equalToConstant: 52)
        ])
    }

    private func configureToolbarButton(_ button: NSButton, symbol: String, toolTip: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = NSColor(calibratedWhite: 0.19, alpha: 1).cgColor
        button.toolTip = toolTip
        button.target = self
        button.action = action

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    private func setZoomScale(_ newValue: CGFloat) {
        let clamped = min(max(newValue, 0.25), 4)
        zoomScale = clamped
        zoomLabel.stringValue = "\(Int(clamped * 100))%"

        guard let image = currentImage else {
            return
        }

        let baseSize = image.size
        imageView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: baseSize.width * clamped, height: baseSize.height * clamped)
        )
        documentView.frame = NSRect(
            x: 0,
            y: 0,
            width: imageView.frame.width + (imageInset * 2),
            height: imageView.frame.height + (imageInset * 2)
        )
    }

    @objc
    private func closeViewer() {
        window.orderOut(nil)
    }

    @objc
    private func copyScreenshot() {
        if let image = currentImage {
            _ = clipboardWriter.copyImage(image)
        }
    }

    @objc
    private func shareScreenshot(_ sender: NSButton) {
        guard let screenshot = currentScreenshot else {
            return
        }

        let picker = NSSharingServicePicker(items: [screenshot.url])
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc
    private func revealInFinder() {
        guard let screenshot = currentScreenshot else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([screenshot.url])
    }

    @objc
    private func deleteScreenshot() {
        guard let screenshot = currentScreenshot else {
            return
        }

        do {
            try FileManager.default.removeItem(at: screenshot.url)
            onDelete(screenshot)
            window.orderOut(nil)
        } catch {
            NSSound.beep()
        }
    }

    @objc
    private func zoomOut() {
        setZoomScale(zoomScale - 0.15)
    }

    @objc
    private func zoomIn() {
        setZoomScale(zoomScale + 0.15)
    }
}
