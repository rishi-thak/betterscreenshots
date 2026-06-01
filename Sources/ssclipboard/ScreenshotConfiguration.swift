import Foundation
import UniformTypeIdentifiers

struct ScreenshotConfiguration {
    let directoryURL: URL
    let allowedExtensions: Set<String>
    let outputExtension: String
    let outputUTType: UTType

    static func current() -> ScreenshotConfiguration {
        let defaults = UserDefaults(suiteName: "com.apple.screencapture")
        let locationPath = defaults?.string(forKey: "location")

        let directoryURL: URL
        if let locationPath, !locationPath.isEmpty {
            directoryURL = URL(fileURLWithPath: NSString(string: locationPath).expandingTildeInPath)
        } else {
            directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        }

        let screenshotType = defaults?.string(forKey: "type")?.lowercased() ?? "png"
        var allowedExtensions = Set(["png", "jpg", "jpeg", "tif", "tiff", "heic", "pdf"])
        allowedExtensions.insert(screenshotType)
        let outputInfo = outputFormatInfo(for: screenshotType)

        return ScreenshotConfiguration(
            directoryURL: directoryURL,
            allowedExtensions: allowedExtensions,
            outputExtension: outputInfo.0,
            outputUTType: outputInfo.1
        )
    }

    private static func outputFormatInfo(for type: String) -> (String, UTType) {
        switch type {
        case "jpg", "jpeg":
            return ("jpg", .jpeg)
        case "tif", "tiff":
            return ("tiff", .tiff)
        case "heic":
            return ("heic", .heic)
        default:
            return ("png", .png)
        }
    }
}
