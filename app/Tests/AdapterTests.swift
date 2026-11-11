import CoreGraphics
import EverKeepCore
@testable import EverKeep
import ImageIO
import XCTest

final class ImageAssessmentTests: XCTestCase {
    private func image(red: CGFloat, green: CGFloat, blue: CGFloat, side: Int = 64) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
        return try XCTUnwrap(context.makeImage())
    }

    func testIdenticalColourImagesScoreOne() throws {
        let source = try image(red: 0.2, green: 0.4, blue: 0.8)
        XCTAssertEqual(try ImageAssessment.score(source, source, maxSide: 320), 1, accuracy: 1e-9)
    }

    func testColourChangesCannotHideBehindIdenticalShapes() throws {
        let red = try image(red: 1, green: 0, blue: 0)
        let blue = try image(red: 0, green: 0, blue: 1)
        XCTAssertLessThan(try ImageAssessment.score(red, blue, maxSide: 320), 0.1)
    }

    func testSmallerImagesCanStillHaveFaithfulThumbnails() throws {
        let original = try image(red: 0.2, green: 0.4, blue: 0.8, side: 256)
        let smaller = try image(red: 0.2, green: 0.4, blue: 0.8, side: 64)
        XCTAssertEqual(try ImageAssessment.score(original, smaller, maxSide: 320), 1, accuracy: 1e-9)
    }

    func testSingleFramePNGIsDecodedAndOriented() throws {
        let source = try image(red: 0.2, green: 0.4, blue: 0.8)
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let document = try ImageDocument(data: data as Data)
        XCTAssertEqual(document.typeIdentifier, "public.png")
        XCTAssertFalse(document.isHDR)
        let rendered = try document.rendered(maxSide: 320)
        XCTAssertEqual(rendered.width, 64)
        XCTAssertEqual(rendered.height, 64)
    }

    func testUnrecognizableImageDataIsAnErrorNotAMissingMetric() {
        XCTAssertThrowsError(try ImageDocument(data: Data("not an image".utf8)))
    }
}

final class CataloguePreferenceTests: XCTestCase {
    func testPreferencesAndProtectionSurviveOpeningAnotherConnection() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("everkeep-\(UUID().uuidString).sqlite").path
        defer {
            for name in [path, "\(path)-wal", "\(path)-shm"] where FileManager.default.fileExists(atPath: name) {
                do {
                    try FileManager.default.removeItem(atPath: name)
                } catch {
                    XCTFail("Could not remove the test catalogue: \(error)")
                }
            }
        }
        do {
            let first = try SqliteCatalogueStore(path: path)
            try await first.setPreservationMode("photo", .protected)
            try await first.setPreservationMode("video", .spaceFirst)
            let reopened = try SqliteCatalogueStore(path: path)
            let modes = try await reopened.preservationModes()
            let protected = try await reopened.protections()
            XCTAssertEqual(modes["photo"], .protected)
            XCTAssertEqual(modes["video"], .spaceFirst)
            XCTAssertEqual(protected, ["photo"])
            try await reopened.setPreservationMode("photo", .almostIdentical)
            let unlocked = try await first.protections()
            XCTAssertFalse(unlocked.contains("photo"))
        }
    }
}
