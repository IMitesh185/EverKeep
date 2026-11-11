import EverKeepCore
import Foundation
import SwiftUI

/// The four things the dial can point at.
enum LibraryCategory: Int, CaseIterable, Identifiable, Hashable {
    case photos, livePhotos, videos, screenshots

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .photos: return "Photos"
        case .livePhotos: return "Live Photos"
        case .videos: return "Videos"
        case .screenshots: return "Screenshots"
        }
    }

    var singular: String {
        switch self {
        case .photos: return "photo"
        case .livePhotos: return "Live Photo"
        case .videos: return "video"
        case .screenshots: return "screenshot"
        }
    }

    var plural: String {
        switch self {
        case .photos: return "photos"
        case .livePhotos: return "Live Photos"
        case .videos: return "videos"
        case .screenshots: return "screenshots"
        }
    }

    var symbol: String {
        switch self {
        case .photos: return "photo.on.rectangle"
        case .livePhotos: return "livephoto"
        case .videos: return "video"
        case .screenshots: return "iphone"
        }
    }

    /// Tile proportions in the review grid, width over height.
    var tileRatio: CGFloat {
        switch self {
        case .photos, .livePhotos: return 4.0 / 3.0
        case .videos: return 16.0 / 10.0
        case .screenshots: return 3.0 / 4.0
        }
    }

    func noun(_ count: Int) -> String { count == 1 ? singular : plural }

    static func of(_ kind: MediaKind) -> LibraryCategory? {
        switch kind {
        case .photo: return .photos
        case .livePhoto: return .livePhotos
        case .video: return .videos
        case .screenshot: return .screenshots
        case .other: return nil
        }
    }
}

enum ExperienceScreen: Equatable {
    case launching, welcome, scanning, noAccess, dial, review, working, done
}

/// Why Everkeep is not sure about an item. Unsure items start unselected: if a check is missing, the original stays.
enum LookReason: String, Codable, Equatable, Sendable {
    case person, motion

    var explanation: String {
        switch self {
        case .person:
            return "A person may be the subject here. Photos where a person is the subject stay as they are unless you choose to preserve them."
        case .motion:
            return "There is fast movement here. Fine detail is the first thing a smaller copy can lose, so take a look."
        }
    }
}

/// What one pass over an item found. Kept on disk so a later launch does not read everything again.
struct SurveyRecord: Codable, Equatable, Sendable {
    var asset: MediaAsset
    var candidate: Bool
    /// An estimate until the copy has been made and checked.
    var saving: Int64
    var look: LookReason?
    var failure: String?
    var settingsKey: String

    func matches(_ other: MediaAsset) -> Bool {
        asset.kind == other.kind && asset.modificationDate == other.modificationDate
            && asset.pixelWidth == other.pixelWidth && asset.pixelHeight == other.pixelHeight
            && asset.duration == other.duration && asset.isFavorite == other.isFavorite
    }
}

struct CategoryStats: Equatable {
    var itemCount = 0
    var measuredCount = 0
    var usedBytes: Int64 = 0
    /// Candidates the person has not protected, whether or not they are currently left out.
    var reviewableCount = 0
    var potentialBytes: Int64 = 0

    var isComplete: Bool { measuredCount >= itemCount }
}

struct WorkProgress: Equatable {
    enum Kind: Equatable { case scan, prepare, apply }

    var kind: Kind = .scan
    var step = ""
    var done = 0
    var total = 0
    var verified = 0

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
}

enum SheetKind: Equatable, Identifiable {
    case look(String)
    case how

    var id: String {
        switch self {
        case .look(let assetId): return "look-\(assetId)"
        case .how: return "how"
        }
    }
}

/// on, off (left out), protected (never touched), failed (did not pass the checks), skipped (left out before checking).
enum TileState: Equatable {
    case on, off, protected, failed, skipped
}

struct ReviewEntry: Identifiable, Equatable {
    let item: LibraryItem
    let record: SurveyRecord?
    let state: TileState
    /// Set while the item still deserves a look, that is until the person has opened it.
    let look: LookReason?

    var id: String { item.id }
    var saving: Int64 { record?.saving ?? 0 }
}

struct ReviewTotals: Equatable {
    var selected = 0
    /// An estimate before the copies are checked, measured after.
    var bytes: Int64 = 0
    var total = 0
    var left = 0
    var needLook = 0
    var checked = false
}

/// Savings at the middle rung of the plan. The planner's bits-per-pixel and quality ladders are
/// uncalibrated until Experiment 0, so every caller shows the result as an estimate with a leading "~".
enum SavingsEstimator {
    static func estimate(for asset: MediaAsset, plan: CompressionPlan) -> Int64 {
        guard !plan.rungs.isEmpty, asset.sizeBytes > 0 else { return 0 }
        let rung = plan.rungs[plan.rungs.count / 2]
        let candidate: Double
        switch rung {
        case .video(let settings):
            candidate = Double(settings.bitrate) * asset.duration / 8
        case .image(let settings):
            candidate = Double(asset.sizeBytes) * imageRatio(settings)
        }
        guard candidate.isFinite, candidate >= 0 else { return 0 }
        let bytes = Int64(min(candidate, Double(asset.sizeBytes)))
        return max(0, asset.sizeBytes - bytes)
    }

    private static func imageRatio(_ settings: ImageEncodeSettings) -> Double {
        if settings.format == .png { return 0.85 }
        let quality = min(max(settings.quality, 0), 1)
        return 0.25 + 0.75 * pow(quality, 8)
    }
}

/// Sizes are always amounts, never percentages. Decimal units like iOS Storage: one decimal for GB, whole MB from 10 MB up.
enum Amounts {
    static func parts(_ bytes: Int64) -> (number: String, unit: String) {
        let value = Double(max(0, bytes))
        if value >= 1_000_000_000 { return (String(format: "%.1f", value / 1_000_000_000), "GB") }
        let megabytes = value / 1_000_000
        if megabytes >= 100 { return (String(Int((megabytes / 10).rounded()) * 10), "MB") }
        if megabytes >= 10 { return (String(Int(megabytes.rounded())), "MB") }
        return (String(format: "%.1f", megabytes), "MB")
    }

    static func text(_ bytes: Int64, approximate: Bool = false) -> String {
        let value = parts(bytes)
        return "\(approximate ? "~" : "")\(value.number) \(value.unit)"
    }
}

/// Survey results survive a relaunch. An actor keeps the disk work off the main thread and never lets two writes overlap.
actor SurveyStore {
    static let shared = SurveyStore()

    private var url: URL? {
        let folder = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return folder?.appendingPathComponent("survey-v1.json")
    }

    func load() -> [String: SurveyRecord] {
        guard let url, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: SurveyRecord].self, from: data)) ?? [:]
    }

    func save(_ records: [String: SurveyRecord]) {
        guard let url, let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
