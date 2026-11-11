import Foundation

public enum Eligibility: Equatable, Sendable {
    case eligible
    case notEligible(ReasonCode)
    case deferred(ReasonCode)
}

/// Pure technical gate. Formats that Photos cannot store would be `notEligible` until a vault exists (ADR-0002).
public struct EligibilityRules: Sendable {
    public static let supportedCodecs: Set<String> = ["avc1", "hvc1", "hev1"]
    public static let supportedImageTypes: Set<String> = ["public.jpeg", "public.png", "public.heic"]

    public init() {}

    public func evaluate(_ asset: MediaAsset) -> Eligibility {
        switch asset.kind {
        case .video, .photo, .screenshot: break
        case .livePhoto: return .deferred(.livePhotosDeferred)
        case .other: return .notEligible(.unsupportedKind)
        }
        if !asset.isOnDevice { return .notEligible(.notOnDevice) }
        if asset.hasAdjustments { return .notEligible(.edited) }
        if asset.isSpecialVideo { return .notEligible(.specialVideo) }
        if asset.isSpecialPhoto == true { return .notEligible(.specialPhoto) }
        if asset.isHDR { return .notEligible(.hdr) }
        let supported = asset.kind.isImage ? Self.supportedImageTypes : Self.supportedCodecs
        if let codec = asset.codec, !supported.contains(codec) { return .notEligible(.unsupportedCodec) }
        if asset.analysisError != nil { return .deferred(.analysisFailed) }
        guard let codec = asset.codec, asset.isAnalyzed else {
            return .deferred(.analysisIncomplete)
        }
        if !supported.contains(codec) { return .notEligible(.unsupportedCodec) }
        if asset.sizeBytes <= 0 || asset.pixelWidth <= 0 || asset.pixelHeight <= 0 {
            return .deferred(.invalidMedia)
        }
        if asset.kind == .video,
           (!asset.duration.isFinite || asset.duration <= 0 || asset.frameRate?.isFinite != true
            || (asset.frameRate ?? 0) <= 0 || (asset.bitrate ?? 0) <= 0) {
            return .deferred(.invalidMedia)
        }
        return .eligible
    }
}
