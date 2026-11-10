import Photos
import XCTest
@testable import Spike

/// E1 on CI: runs the app's census inside the host app after the workflow seeds the photo library.
final class E1CensusTests: XCTestCase {
    func testCensus() async throws {
        // Seeded media is imported asynchronously, so wait up to 30 s for it.
        var count = 0
        for _ in 0..<30 {
            count = PHAsset.fetchAssets(with: nil).count
            if count > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        let report = Census.report()
        print(report)
        // Fallback in case xcodebuild hides test stdout; the workflow prints this file.
        try? report.write(toFile: "/tmp/e1_report.txt", atomically: true, encoding: .utf8)

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        XCTAssertTrue(status == .authorized || status == .limited, "photos access=\(status.rawValue)")
        XCTAssertGreaterThan(count, 0, "no assets were seeded")
    }
}
