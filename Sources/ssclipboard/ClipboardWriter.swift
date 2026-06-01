import AppKit
import Foundation

final class ClipboardWriter {
    func copyImage(at url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url) else {
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    func copyImage(_ image: NSImage) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }
}
