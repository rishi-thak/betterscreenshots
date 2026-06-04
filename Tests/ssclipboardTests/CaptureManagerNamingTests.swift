import Foundation
import Testing
@testable import ssclipboard

@Test
func captureNamingBuildsExpectedBaseName() {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = calendar.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 12, minute: 0, second: 0))!
    let name = CaptureNaming.baseName(date: date, formatter: formatter)

    #expect(name == "Screenshot 2024-06-01 at 12.00.00 PM")
}

@Test
func captureNamingUniqueFileURLAppendsIncrementingSuffix() {
    let directory = URL(fileURLWithPath: "/tmp/ssclipboard-tests", isDirectory: true)
    let existing: Set<String> = [
        directory.appendingPathComponent("Screenshot 2024-06-01 at 12.00.00 PM.png").path,
        directory.appendingPathComponent("Screenshot 2024-06-01 at 12.00.00 PM 1.png").path
    ]

    let candidate = CaptureNaming.uniqueFileURL(
        baseName: "Screenshot 2024-06-01 at 12.00.00 PM",
        fileExtension: "png",
        directoryURL: directory,
        fileExists: { existing.contains($0) }
    )

    #expect(candidate.lastPathComponent == "Screenshot 2024-06-01 at 12.00.00 PM 2.png")
}
