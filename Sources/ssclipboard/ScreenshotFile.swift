import Foundation

struct ScreenshotFile: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let createdAt: Date
}
