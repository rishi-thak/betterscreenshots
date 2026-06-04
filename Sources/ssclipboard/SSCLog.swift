import Foundation
import os

enum SSCLog {
    private static let subsystem = "com.rishi.ssclipboard"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let scroll = Logger(subsystem: subsystem, category: "scroll")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let selection = Logger(subsystem: subsystem, category: "selection")
    static let overlay = Logger(subsystem: subsystem, category: "overlay")
}
