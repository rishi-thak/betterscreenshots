import Foundation

enum CaptureNaming {
    static func baseName(date: Date, formatter: DateFormatter = makeDefaultFormatter()) -> String {
        "Screenshot \(formatter.string(from: date))"
    }

    static func uniqueFileURL(
        baseName: String,
        fileExtension: String,
        directoryURL: URL,
        fileExists: (String) -> Bool
    ) -> URL {
        var index = 0
        while true {
            let suffix = index == 0 ? "" : " \(index)"
            let candidate = directoryURL.appendingPathComponent("\(baseName)\(suffix).\(fileExtension)")
            if !fileExists(candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    static func makeDefaultFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return formatter
    }
}
