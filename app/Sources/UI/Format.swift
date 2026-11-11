import EverKeepCore
import Foundation

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "Unknown duration" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func describe(_ asset: MediaAsset) -> String {
        var parts = [kind(asset.kind), "\(asset.pixelWidth)x\(asset.pixelHeight)"]
        if asset.kind == .video { parts.append(clock(asset.duration)) }
        if let codec = asset.codec { parts.append(codec) }
        if let bitrate = asset.bitrate { parts.append(String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)) }
        parts.append(asset.sizeBytes > 0 ? bytes(asset.sizeBytes) : "Size analyzed after your choice")
        return parts.joined(separator: " · ")
    }

    static func date(_ asset: MediaAsset) -> String {
        asset.creationDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unknown date"
    }

    static func kind(_ kind: MediaKind) -> String {
        switch kind {
        case .video: return "Video"
        case .photo: return "Photo"
        case .screenshot: return "Screenshot"
        case .livePhoto: return "Live Photo"
        case .other: return "Unsupported item"
        }
    }
}
