import EverKeepCore
import Foundation

final class StorageMonitor: StoragePort, @unchecked Sendable {
    private let directory: URL

    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? base.appendingPathComponent("Staging", isDirectory: true)
    }

    func availableBytes() async throws -> Int64 {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func stagingURL(name: String) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return directory.appendingPathComponent(name)
    }

    func stagedFileExists(name: String) async -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    func removeStaged(name: String) async {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}
