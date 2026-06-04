import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
    private let copyTextButton = NSButton()
    private let shareButton = NSButton()
    private let revealButton = NSButton()
    private let deleteButton = NSButton()
    private let redactButton = NSButton()
    private let zoomOutButton = NSButton()
    private let zoomInButton = NSButton()
    private let backgroundButton = NSButton()
    private let textRecognitionSpinner = NSProgressIndicator()

    private var currentScreenshot: ScreenshotFile?
    private var currentImage: NSImage?
    private var isWindowCapture = false
    private var zoomScale: CGFloat = 1
    private let imageInset: CGFloat = 24

    // Background editor
    private var backgroundEditorView: BackgroundEditorView?
    private var scrollBottomConstraint: NSLayoutConstraint?

    // Redaction editor
    private var redactionEditorView: ImageRedactionEditorView?
    private var redactionControlsView: RedactionControlsView?

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
    }

    func present(screenshot: ScreenshotFile, isWindowCapture: Bool = false) {
        currentScreenshot = screenshot
        currentImage = NSImage(contentsOf: screenshot.url)
        self.isWindowCapture = isWindowCapture
        imageView.image = currentImage
        titleLabel.stringValue = screenshot.url.lastPathComponent
        deleteButton.isEnabled = FileManager.default.fileExists(atPath: screenshot.url.path)
        backgroundButton.isEnabled = isWindowCapture
        backgroundButton.alphaValue = isWindowCapture ? 1 : 0.35
        hideBackgroundEditor()
        exitRedactionMode()
        textRecognitionSpinner.stopAnimation(nil)
        copyTextButton.isEnabled = true

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Defer so scroll view has its final size before computing fit
        DispatchQueue.main.async { [weak self] in
            guard let self, let img = self.currentImage else { return }
            self.setZoomScale(self.fitZoomScale(for: img))
        }
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

        // Frame-based — sized explicitly in setZoomScale
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true

        documentView.addSubview(imageView)
        imageScrollView.documentView = documentView

        configureToolbarButton(closeButton, symbol: "xmark", toolTip: "Close", action: #selector(closeViewer))
        configureToolbarButton(copyButton, symbol: "doc.on.doc", toolTip: "Copy", action: #selector(copyScreenshot))
        configureToolbarButton(copyTextButton, symbol: "text.viewfinder", toolTip: "Copy Text", action: #selector(copyRecognizedText))
        configureToolbarButton(shareButton, symbol: "square.and.arrow.up", toolTip: "Share", action: #selector(shareScreenshot(_:)))
        configureToolbarButton(revealButton, symbol: "folder", toolTip: "Show in Finder", action: #selector(revealInFinder))
        configureToolbarButton(deleteButton, symbol: "trash", toolTip: "Delete", action: #selector(deleteScreenshot))
        configureToolbarButton(redactButton, symbol: "eye.slash", toolTip: "Redact", action: #selector(toggleRedactionMode))
        configureToolbarButton(backgroundButton, symbol: "photo.artframe", toolTip: "Add Background", action: #selector(toggleBackgroundEditor))
        configureToolbarButton(zoomOutButton, symbol: "minus", toolTip: "Zoom Out", action: #selector(zoomOut))
        configureToolbarButton(zoomInButton, symbol: "plus", toolTip: "Zoom In", action: #selector(zoomIn))

        textRecognitionSpinner.translatesAutoresizingMaskIntoConstraints = false
        textRecognitionSpinner.style = .spinning
        textRecognitionSpinner.controlSize = .small
        textRecognitionSpinner.isDisplayedWhenStopped = false
        NSLayoutConstraint.activate([
            textRecognitionSpinner.widthAnchor.constraint(equalToConstant: 14),
            textRecognitionSpinner.heightAnchor.constraint(equalToConstant: 14)
        ])

        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        zoomLabel.textColor = NSColor(calibratedWhite: 0.86, alpha: 1)
        zoomLabel.alignment = .center

        rootView.addSubview(toolbarView)
        rootView.addSubview(imageScrollView)

        let leftStack = NSStackView(views: [closeButton, copyButton, copyTextButton, textRecognitionSpinner, shareButton, revealButton, deleteButton, redactButton, backgroundButton])
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
            toolbarView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 58),

            imageScrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            imageScrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            imageScrollView.topAnchor.constraint(equalTo: rootView.topAnchor),

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

        let scrollBottom = imageScrollView.bottomAnchor.constraint(equalTo: toolbarView.topAnchor)
        scrollBottom.isActive = true
        scrollBottomConstraint = scrollBottom
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

    private func fitZoomScale(for image: NSImage) -> CGFloat {
        let viewSize = imageScrollView.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return 1 }
        let availW = viewSize.width - imageInset * 2
        let availH = viewSize.height - imageInset * 2
        let scaleW = availW / image.size.width
        let scaleH = availH / image.size.height
        return min(min(scaleW, scaleH), 1)  // never upscale beyond 100%
    }

    private func setZoomScale(_ newValue: CGFloat) {
        let clamped = min(max(newValue, 0.25), 4)
        zoomScale = clamped
        zoomLabel.stringValue = "\(Int(clamped * 100))%"

        guard let image = currentImage else { return }

        let scaledSize = NSSize(width: image.size.width * clamped, height: image.size.height * clamped)
        let viewSize = imageScrollView.contentSize

        // Document is at least as large as the viewport so the image stays centered
        let docW = max(scaledSize.width + imageInset * 2, viewSize.width)
        let docH = max(scaledSize.height + imageInset * 2, viewSize.height)

        let imgX = (docW - scaledSize.width) / 2
        let imgY = (docH - scaledSize.height) / 2

        imageView.frame = NSRect(origin: NSPoint(x: imgX, y: imgY), size: scaledSize)
        documentView.frame = NSRect(origin: .zero, size: NSSize(width: docW, height: docH))
        imageScrollView.documentView = documentView
        redactionEditorView?.frame = imageView.frame
        redactionEditorView?.needsDisplay = true
    }

    // MARK: - Background editor

    @objc private func toggleBackgroundEditor() {
        if redactionControlsView != nil {
            exitRedactionMode()
        }
        if backgroundEditorView != nil {
            hideBackgroundEditor()
        } else {
            showBackgroundEditor()
        }
    }

    private func showBackgroundEditor() {
        guard backgroundEditorView == nil, let image = currentImage else { return }

        let editor = BackgroundEditorView(windowImage: image)
        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.onSave = { [weak self] composited in
            self?.saveComposited(composited)
        }
        editor.onCancel = { [weak self] in
            self?.hideBackgroundEditor()
        }
        editor.onPreview = { [weak self] composited in
            guard let self else { return }
            self.imageView.image = composited
            self.setZoomScale(self.fitZoomScale(for: composited))
        }

        rootView.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: toolbarView.topAnchor),
            editor.heightAnchor.constraint(equalToConstant: 160)
        ])

        scrollBottomConstraint?.isActive = false
        let newBottom = imageScrollView.bottomAnchor.constraint(equalTo: editor.topAnchor)
        newBottom.isActive = true
        scrollBottomConstraint = newBottom

        backgroundEditorView = editor
    }

    private func hideBackgroundEditor() {
        backgroundEditorView?.removeFromSuperview()
        backgroundEditorView = nil
        imageView.image = currentImage

        scrollBottomConstraint?.isActive = false
        let newBottom = imageScrollView.bottomAnchor.constraint(equalTo: toolbarView.topAnchor)
        newBottom.isActive = true
        scrollBottomConstraint = newBottom

        setZoomScale(zoomScale)
    }

    private func saveComposited(_ image: NSImage) {
        do {
            try persistEditedImage(image)
        } catch {
            showAlert(
                title: "Couldn't Save Image",
                message: "The edited screenshot couldn't be saved. Please try again."
            )
            return
        }
        hideBackgroundEditor()
        setZoomScale(fitZoomScale(for: image))
    }

    @objc private func closeViewer() { window.orderOut(nil) }

    @objc private func copyScreenshot() {
        if let image = currentImage { _ = clipboardWriter.copyImage(image) }
    }

    @objc private func copyRecognizedText() {
        guard let image = currentImage else { return }
        copyTextButton.isEnabled = false
        textRecognitionSpinner.startAnimation(nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.copyTextButton.isEnabled = true
                self.textRecognitionSpinner.stopAnimation(nil)
            }

            do {
                let text = try await ImageTextRecognizer.recognizeText(in: image)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.showAlert(
                    title: "Text Copied",
                    message: "Copied \(text.count) characters to the clipboard."
                )
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Text couldn't be recognized in this screenshot."
                self.showAlert(
                    title: "Couldn't Copy Text",
                    message: message
                )
            }
        }
    }

    @objc private func shareScreenshot(_ sender: NSButton) {
        guard let screenshot = currentScreenshot else { return }
        let picker = NSSharingServicePicker(items: [screenshot.url])
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func revealInFinder() {
        guard let screenshot = currentScreenshot else { return }
        NSWorkspace.shared.activateFileViewerSelecting([screenshot.url])
    }

    @objc private func deleteScreenshot() {
        guard let screenshot = currentScreenshot else { return }
        deleteButton.isEnabled = false
        NSWorkspace.shared.recycle([screenshot.url]) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if error != nil {
                    NSSound.beep()
                    self.deleteButton.isEnabled = FileManager.default.fileExists(atPath: screenshot.url.path)
                    return
                }
                self.onDelete(screenshot)
                self.window.orderOut(nil)
            }
        }
    }

    @objc private func zoomOut() { setZoomScale(zoomScale - 0.15) }
    @objc private func zoomIn() { setZoomScale(zoomScale + 0.15) }

    @objc private func toggleRedactionMode() {
        if redactionControlsView != nil {
            exitRedactionMode()
        } else {
            enterRedactionMode()
        }
    }

    private func enterRedactionMode() {
        guard redactionControlsView == nil, let image = currentImage else { return }

        if backgroundEditorView != nil {
            hideBackgroundEditor()
        }

        let controls = RedactionControlsView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.onApply = { [weak self] style in
            self?.applyRedactions(style: style)
        }
        controls.onCancel = { [weak self] in
            self?.exitRedactionMode()
        }
        rootView.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: toolbarView.topAnchor),
            controls.heightAnchor.constraint(equalToConstant: 52)
        ])

        let redactionOverlay = ImageRedactionEditorView(imageSize: image.size)
        redactionOverlay.frame = imageView.frame
        documentView.addSubview(redactionOverlay)

        scrollBottomConstraint?.isActive = false
        let newBottom = imageScrollView.bottomAnchor.constraint(equalTo: controls.topAnchor)
        newBottom.isActive = true
        scrollBottomConstraint = newBottom

        redactionControlsView = controls
        redactionEditorView = redactionOverlay
        redactButton.contentTintColor = NSColor.systemBlue
    }

    private func exitRedactionMode() {
        redactionEditorView?.removeFromSuperview()
        redactionEditorView = nil
        redactionControlsView?.removeFromSuperview()
        redactionControlsView = nil
        redactButton.contentTintColor = .white

        scrollBottomConstraint?.isActive = false
        let newBottom = imageScrollView.bottomAnchor.constraint(equalTo: toolbarView.topAnchor)
        newBottom.isActive = true
        scrollBottomConstraint = newBottom
    }

    private func applyRedactions(style: RedactionStyle) {
        guard let originalImage = currentImage,
              let redactionEditorView else { return }

        if redactionEditorView.regions.isEmpty {
            showAlert(
                title: "No Redactions Added",
                message: "Drag on the image to draw one or more regions first."
            )
            return
        }

        guard let redacted = ImageRedactionApplier.apply(
            to: originalImage,
            regions: redactionEditorView.regions,
            style: style
        ) else {
            showAlert(
                title: "Couldn't Apply Redactions",
                message: "Try adjusting the redaction regions and applying again."
            )
            return
        }

        do {
            try persistEditedImage(redacted)
            exitRedactionMode()
            setZoomScale(fitZoomScale(for: redacted))
        } catch {
            showAlert(
                title: "Couldn't Save Image",
                message: "The redacted screenshot couldn't be saved. Please try again."
            )
        }
    }

    private func persistEditedImage(_ image: NSImage) throws {
        guard let screenshot = currentScreenshot else { return }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        try png.write(to: screenshot.url)
        currentImage = image
        imageView.image = image
        _ = clipboardWriter.copyImage(image)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}

// MARK: - Background Editor View

@MainActor
private final class BackgroundEditorView: NSView {
    var onSave: ((NSImage) -> Void)?
    var onCancel: (() -> Void)?
    var onPreview: ((NSImage) -> Void)?

    private let windowImage: NSImage
    private var selectedBackground: Background = .gradient(0)
    private var selectedRatio: AspectRatio = .free
    private var padding: CGFloat = 40

    enum AspectRatio: String, CaseIterable {
        case free = "Free", square = "1:1", fourThree = "4:3", sixteenNine = "16:9", threeTwo = "3:2"
        var ratio: CGFloat? {
            switch self {
            case .free: return nil
            case .square: return 1
            case .fourThree: return 4/3
            case .sixteenNine: return 16/9
            case .threeTwo: return 3/2
            }
        }
    }

    enum Background {
        case gradient(Int)
        case solid(NSColor)
    }

    static let gradients: [(NSColor, NSColor)] = [
        (NSColor(red: 0.40, green: 0.20, blue: 0.90, alpha: 1), NSColor(red: 0.10, green: 0.60, blue: 1.00, alpha: 1)),
        (NSColor(red: 1.00, green: 0.30, blue: 0.50, alpha: 1), NSColor(red: 1.00, green: 0.70, blue: 0.20, alpha: 1)),
        (NSColor(red: 0.10, green: 0.80, blue: 0.60, alpha: 1), NSColor(red: 0.10, green: 0.50, blue: 0.90, alpha: 1)),
        (NSColor(red: 0.95, green: 0.40, blue: 0.10, alpha: 1), NSColor(red: 1.00, green: 0.80, blue: 0.10, alpha: 1)),
        (NSColor(red: 0.20, green: 0.20, blue: 0.25, alpha: 1), NSColor(red: 0.40, green: 0.40, blue: 0.50, alpha: 1)),
        (NSColor(red: 0.80, green: 0.20, blue: 0.80, alpha: 1), NSColor(red: 0.40, green: 0.10, blue: 0.60, alpha: 1)),
    ]

    init(windowImage: NSImage) {
        self.windowImage = windowImage
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.97).cgColor
        layer?.borderColor = NSColor(calibratedWhite: 0.25, alpha: 1).cgColor
        layer?.borderWidth = 1
        buildUI()
        updatePreview()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        // Gradient swatches
        let swatchStack = NSStackView()
        swatchStack.translatesAutoresizingMaskIntoConstraints = false
        swatchStack.orientation = .horizontal
        swatchStack.spacing = 8

        for (i, grad) in Self.gradients.enumerated() {
            let swatch = GradientSwatchButton(from: grad.0, to: grad.1, tag: i)
            swatch.target = self
            swatch.action = #selector(selectGradient(_:))
            swatchStack.addArrangedSubview(swatch)
            NSLayoutConstraint.activate([swatch.widthAnchor.constraint(equalToConstant: 32), swatch.heightAnchor.constraint(equalToConstant: 32)])
        }

        // Color wheel button
        let colorWheel = ColorWheelButton()
        colorWheel.translatesAutoresizingMaskIntoConstraints = false
        colorWheel.onColorPicked = { [weak self] color in
            self?.selectedBackground = .solid(color)
            self?.updatePreview()
        }
        NSLayoutConstraint.activate([colorWheel.widthAnchor.constraint(equalToConstant: 32), colorWheel.heightAnchor.constraint(equalToConstant: 32)])
        swatchStack.addArrangedSubview(colorWheel)

        // Aspect ratio pills
        let ratioStack = NSStackView()
        ratioStack.translatesAutoresizingMaskIntoConstraints = false
        ratioStack.orientation = .horizontal
        ratioStack.spacing = 6

        for ratio in AspectRatio.allCases {
            let btn = NSButton()
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.title = ratio.rawValue
            btn.font = .systemFont(ofSize: 11, weight: .medium)
            btn.bezelStyle = .regularSquare
            btn.isBordered = false
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 6
            btn.layer?.backgroundColor = (ratio == selectedRatio)
                ? NSColor.systemBlue.cgColor
                : NSColor(calibratedWhite: 0.25, alpha: 1).cgColor
            btn.contentTintColor = .white
            btn.target = self
            btn.action = #selector(selectRatio(_:))
            btn.identifier = NSUserInterfaceItemIdentifier(ratio.rawValue)
            NSLayoutConstraint.activate([btn.heightAnchor.constraint(equalToConstant: 26)])
            ratioStack.addArrangedSubview(btn)
        }

        // Padding slider
        let paddingLabel = NSTextField(labelWithString: "Padding")
        paddingLabel.translatesAutoresizingMaskIntoConstraints = false
        paddingLabel.font = .systemFont(ofSize: 11)
        paddingLabel.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)

        let slider = NSSlider(value: Double(padding), minValue: 0, maxValue: 120, target: self, action: #selector(paddingChanged(_:)))
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.controlSize = .small
        NSLayoutConstraint.activate([slider.widthAnchor.constraint(equalToConstant: 100)])

        let paddingRow = NSStackView(views: [paddingLabel, slider])
        paddingRow.translatesAutoresizingMaskIntoConstraints = false
        paddingRow.orientation = .horizontal
        paddingRow.spacing = 8
        paddingRow.alignment = .centerY

        // Save / Cancel
        let saveButton = NSButton()
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.title = "Save"
        saveButton.bezelStyle = .regularSquare
        saveButton.isBordered = false
        saveButton.wantsLayer = true
        saveButton.layer?.cornerRadius = 8
        saveButton.layer?.backgroundColor = NSColor.systemBlue.cgColor
        saveButton.contentTintColor = .white
        saveButton.font = .systemFont(ofSize: 13, weight: .semibold)
        saveButton.target = self
        saveButton.action = #selector(save)
        NSLayoutConstraint.activate([saveButton.widthAnchor.constraint(equalToConstant: 72), saveButton.heightAnchor.constraint(equalToConstant: 32)])

        let cancelButton = NSButton()
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .regularSquare
        cancelButton.isBordered = false
        cancelButton.wantsLayer = true
        cancelButton.layer?.cornerRadius = 8
        cancelButton.layer?.backgroundColor = NSColor(calibratedWhite: 0.25, alpha: 1).cgColor
        cancelButton.contentTintColor = .white
        cancelButton.font = .systemFont(ofSize: 13)
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        NSLayoutConstraint.activate([cancelButton.widthAnchor.constraint(equalToConstant: 72), cancelButton.heightAnchor.constraint(equalToConstant: 32)])

        let actionStack = NSStackView(views: [cancelButton, saveButton])
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.spacing = 8

        // Top row: swatches + ratio + padding
        let topRow = NSStackView(views: [swatchStack, NSView(), ratioStack, paddingRow])
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topRow.orientation = .horizontal
        topRow.spacing = 16
        topRow.alignment = .centerY
        topRow.views[1].setContentHuggingPriority(.defaultLow, for: .horizontal)

        let mainStack = NSStackView(views: [topRow, actionStack])
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.orientation = .vertical
        mainStack.spacing = 12
        mainStack.alignment = .leading
        mainStack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @objc private func selectGradient(_ sender: NSButton) {
        selectedBackground = .gradient(sender.tag)
        updatePreview()
    }

    @objc private func selectRatio(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let ratio = AspectRatio(rawValue: id) else { return }
        selectedRatio = ratio
        // Update pill highlight
        for view in sender.superview?.subviews ?? [] {
            guard let btn = view as? NSButton else { continue }
            btn.layer?.backgroundColor = (btn.identifier?.rawValue == id)
                ? NSColor.systemBlue.cgColor
                : NSColor(calibratedWhite: 0.25, alpha: 1).cgColor
        }
        updatePreview()
    }

    @objc private func paddingChanged(_ sender: NSSlider) {
        padding = CGFloat(sender.doubleValue)
        updatePreview()
    }

    @objc private func save() {
        onSave?(composite())
    }

    @objc private func cancel() {
        onCancel?()
    }

    private func updatePreview() {
        onPreview?(composite())
    }

    func composite() -> NSImage {
        let imgSize = windowImage.size
        let pad = padding

        // Determine canvas size
        let contentW = imgSize.width + pad * 2
        let contentH = imgSize.height + pad * 2

        let canvasSize: CGSize
        if let ratio = selectedRatio.ratio {
            let fromW = CGSize(width: max(contentW, contentH * ratio), height: max(contentW, contentH * ratio) / ratio)
            let fromH = CGSize(width: max(contentH * ratio, contentW), height: max(contentH, contentW / ratio))
            // Pick whichever fits the content
            canvasSize = (fromW.width >= contentW && fromW.height >= contentH) ? fromW : fromH
        } else {
            canvasSize = CGSize(width: contentW, height: contentH)
        }

        let result = NSImage(size: canvasSize)
        result.lockFocus()

        let ctx = NSGraphicsContext.current!.cgContext
        let canvasRect = CGRect(origin: .zero, size: canvasSize)

        // Draw background
        switch selectedBackground {
        case .gradient(let idx):
            let (c1, c2) = Self.gradients[idx]
            if let gradient = NSGradient(starting: c1, ending: c2) {
                gradient.draw(in: canvasRect, angle: 135)
            } else {
                c1.setFill()
                canvasRect.fill()
            }
        case .solid(let color):
            color.setFill()
            canvasRect.fill()
        }

        // Draw window image centered with rounded corners
        let imgX = (canvasSize.width - imgSize.width) / 2
        let imgY = (canvasSize.height - imgSize.height) / 2
        let imgRect = CGRect(x: imgX, y: imgY, width: imgSize.width, height: imgSize.height)

        let clipPath = CGPath(roundedRect: imgRect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.addPath(clipPath)
        ctx.clip()
        windowImage.draw(in: imgRect)

        result.unlockFocus()
        return result
    }
}

// MARK: - Gradient swatch button

private final class GradientSwatchButton: NSButton {
    private let fromColor: NSColor
    private let toColor: NSColor

    init(from: NSColor, to: NSColor, tag: Int) {
        self.fromColor = from
        self.toColor = to
        super.init(frame: .zero)
        self.tag = tag
        self.title = ""
        self.isBordered = false
        self.bezelStyle = .regularSquare
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        self.layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if let gradient = NSGradient(starting: fromColor, ending: toColor) {
            gradient.draw(in: bounds, angle: 135)
        } else {
            fromColor.setFill()
            bounds.fill()
        }
    }
}

// MARK: - Color swatch button (opens NSColorPanel)

private final class ColorWheelButton: NSView {
    var onColorPicked: ((NSColor) -> Void)?
    private var currentColor: NSColor = .white

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor(calibratedWhite: 0.5, alpha: 1).cgColor
        layer?.backgroundColor = currentColor.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        let panel = NSColorPanel.shared
        panel.mode = .wheel
        panel.color = currentColor
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        currentColor = sender.color
        layer?.backgroundColor = currentColor.cgColor
        onColorPicked?(currentColor)
    }
}

@MainActor
private final class RedactionControlsView: NSVisualEffectView {
    var onApply: ((RedactionStyle) -> Void)?
    var onCancel: (() -> Void)?

    private let styleSelector = NSSegmentedControl(labels: ["Blur", "Black"], trackingMode: .selectOne, target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .underWindowBackground
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 0.26, alpha: 1).cgColor
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        styleSelector.translatesAutoresizingMaskIntoConstraints = false
        styleSelector.selectedSegment = 0
        styleSelector.target = self
        styleSelector.action = #selector(styleChanged)

        let styleLabel = NSTextField(labelWithString: "Mode")
        styleLabel.translatesAutoresizingMaskIntoConstraints = false
        styleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        styleLabel.textColor = NSColor(calibratedWhite: 0.8, alpha: 1)

        let styleStack = NSStackView(views: [styleLabel, styleSelector])
        styleStack.translatesAutoresizingMaskIntoConstraints = false
        styleStack.orientation = .horizontal
        styleStack.spacing = 8
        styleStack.alignment = .centerY

        let applyButton = NSButton()
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        applyButton.title = "Apply"
        applyButton.isBordered = false
        applyButton.wantsLayer = true
        applyButton.layer?.cornerRadius = 8
        applyButton.layer?.backgroundColor = NSColor.systemBlue.cgColor
        applyButton.contentTintColor = .white
        applyButton.font = .systemFont(ofSize: 12, weight: .semibold)
        applyButton.target = self
        applyButton.action = #selector(applyPressed)
        NSLayoutConstraint.activate([
            applyButton.widthAnchor.constraint(equalToConstant: 76),
            applyButton.heightAnchor.constraint(equalToConstant: 30)
        ])

        let cancelButton = NSButton()
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.title = "Cancel"
        cancelButton.isBordered = false
        cancelButton.wantsLayer = true
        cancelButton.layer?.cornerRadius = 8
        cancelButton.layer?.backgroundColor = NSColor(calibratedWhite: 0.28, alpha: 1).cgColor
        cancelButton.contentTintColor = .white
        cancelButton.font = .systemFont(ofSize: 12, weight: .medium)
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        NSLayoutConstraint.activate([
            cancelButton.widthAnchor.constraint(equalToConstant: 76),
            cancelButton.heightAnchor.constraint(equalToConstant: 30)
        ])

        addSubview(styleStack)
        addSubview(cancelButton)
        addSubview(applyButton)
        NSLayoutConstraint.activate([
            styleStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            styleStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            applyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            applyButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            cancelButton.trailingAnchor.constraint(equalTo: applyButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private var selectedStyle: RedactionStyle {
        styleSelector.selectedSegment == 0 ? .blur : .solidBlack
    }

    @objc private func applyPressed() {
        onApply?(selectedStyle)
    }

    @objc private func cancelPressed() {
        onCancel?()
    }

    @objc private func styleChanged() {}
}
