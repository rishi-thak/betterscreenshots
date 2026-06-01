import Foundation
import ImageIO

final class ScreenshotMonitor: @unchecked Sendable {
    private let configuration: ScreenshotConfiguration
    private let onScreenshotReady: @Sendable (ScreenshotFile) -> Void
    private let queue = DispatchQueue(label: "ssclipboard.screenshot-monitor", qos: .utility)
    private let debounceInterval: TimeInterval = 0.08
    private let followUpInterval: TimeInterval = 0.08
    private let fileManager = FileManager.default
    private var descriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
    private var followUpScanWorkItem: DispatchWorkItem?
    private var pendingReadyChecks: [String: DispatchWorkItem] = [:]
    private var knownFiles: [String: Snapshot] = [:]
    private let startedAt = Date()

    private struct Snapshot {
        let url: URL
        let modifiedAt: Date
        let size: Int64
        let fileID: String
    }

    init(configuration: ScreenshotConfiguration, onScreenshotReady: @escaping @Sendable (ScreenshotFile) -> Void) {
        self.configuration = configuration
        self.onScreenshotReady = onScreenshotReady
    }

    func start() {
        queue.async {
            self.performScan()
            self.startMonitoringDirectory()
        }
    }

    deinit {
        debounceWorkItem?.cancel()
        followUpScanWorkItem?.cancel()
        pendingReadyChecks.values.forEach { $0.cancel() }
        if descriptor >= 0 {
            close(descriptor)
        }
    }

    private func startMonitoringDirectory() {
        descriptor = open(configuration.directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib, .link, .revoke],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.scheduleScan()
        }

        source.setCancelHandler { [descriptor] in
            if descriptor >= 0 {
                close(descriptor)
            }
        }

        self.source = source
        source.resume()
    }

    private func scheduleScan() {
        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.performScan()
        }

        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func performScan() {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .creationDateKey,
            .fileResourceIdentifierKey,
            .fileSizeKey,
            .nameKey
        ]

        guard let enumerator = fileManager.enumerator(
            at: configuration.directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
        ) else {
            return
        }

        var currentSnapshots: [String: Snapshot] = [:]
        var readyScreenshots: [ScreenshotFile] = []
        var needsFollowUpScan = false

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true,
                  let name = values.name else {
                continue
            }

            let ext = fileURL.pathExtension.lowercased()
            guard configuration.allowedExtensions.contains(ext) else {
                continue
            }

            guard ScreenshotClassifier.isLikelyScreenshot(filename: name) else {
                continue
            }

            let modifiedAt = values.contentModificationDate ?? values.creationDate ?? .distantPast
            let size = Int64(values.fileSize ?? 0)
            let fileID = fileURL.standardizedFileURL.path
            let snapshot = Snapshot(url: fileURL, modifiedAt: modifiedAt, size: size, fileID: fileID)
            currentSnapshots[fileID] = snapshot

            guard modifiedAt >= startedAt.addingTimeInterval(-2) else {
                continue
            }

            guard let previous = knownFiles[fileID] else {
                scheduleReadyCheck(for: snapshot)
                needsFollowUpScan = true
                continue
            }

            guard previous.size == snapshot.size, previous.modifiedAt == snapshot.modifiedAt else {
                scheduleReadyCheck(for: snapshot)
                needsFollowUpScan = true
                continue
            }

            if snapshot.modifiedAt.timeIntervalSinceNow > -0.1 {
                scheduleReadyCheck(for: snapshot)
                needsFollowUpScan = true
                continue
            }

            pendingReadyChecks[fileID]?.cancel()
            pendingReadyChecks.removeValue(forKey: fileID)
            readyScreenshots.append(
                ScreenshotFile(
                    id: snapshot.fileID,
                    url: snapshot.url,
                    createdAt: values.creationDate ?? snapshot.modifiedAt
                )
            )
        }

        knownFiles = currentSnapshots

        for screenshot in readyScreenshots.sorted(by: { $0.createdAt < $1.createdAt }) {
            onScreenshotReady(screenshot)
            knownFiles.removeValue(forKey: screenshot.id)
        }

        if needsFollowUpScan {
            scheduleFollowUpScan()
        }
    }

    private func scheduleReadyCheck(for snapshot: Snapshot) {
        pendingReadyChecks[snapshot.fileID]?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.attemptReadyCheck(for: snapshot)
        }

        pendingReadyChecks[snapshot.fileID] = workItem
        queue.asyncAfter(deadline: .now() + 0.03, execute: workItem)
    }

    private func attemptReadyCheck(for snapshot: Snapshot, attemptsRemaining: Int = 40) {
        guard fileManager.fileExists(atPath: snapshot.url.path) else {
            pendingReadyChecks.removeValue(forKey: snapshot.fileID)
            return
        }

        if let imageSource = CGImageSourceCreateWithURL(snapshot.url as CFURL, nil),
           CGImageSourceGetCount(imageSource) > 0 {
            pendingReadyChecks.removeValue(forKey: snapshot.fileID)
            onScreenshotReady(
                ScreenshotFile(
                    id: snapshot.fileID,
                    url: snapshot.url,
                    createdAt: snapshot.modifiedAt
                )
            )
            knownFiles.removeValue(forKey: snapshot.fileID)
            return
        }

        guard attemptsRemaining > 0 else {
            pendingReadyChecks.removeValue(forKey: snapshot.fileID)
            return
        }

        let retrySnapshot = snapshot
        let workItem = DispatchWorkItem { [weak self] in
            self?.attemptReadyCheck(for: retrySnapshot, attemptsRemaining: attemptsRemaining - 1)
        }

        pendingReadyChecks[snapshot.fileID] = workItem
        queue.asyncAfter(deadline: .now() + 0.03, execute: workItem)
    }

    private func scheduleFollowUpScan() {
        followUpScanWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.performScan()
        }

        followUpScanWorkItem = workItem
        queue.asyncAfter(deadline: .now() + followUpInterval, execute: workItem)
    }
}
