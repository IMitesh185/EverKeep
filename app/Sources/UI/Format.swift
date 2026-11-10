import EverKeepCore
import Foundation

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func describe(_ asset: MediaAsset) -> String {
        var parts = [clock(asset.duration), "\(asset.pixelWidth)x\(asset.pixelHeight)"]
        if let codec = asset.codec { parts.append(codec) }
        if let bitrate = asset.bitrate { parts.append(String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)) }
        parts.append(bytes(asset.sizeBytes))
        return parts.joined(separator: " · ")
    }

    static func date(_ asset: MediaAsset) -> String {
        asset.creationDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unknown date"
    }
}
