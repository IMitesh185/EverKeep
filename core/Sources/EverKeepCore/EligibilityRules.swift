import Foundation

public enum Eligibility: Equatable, Sendable {
    case eligible
    case notEligible(ReasonCode)
    case deferred(ReasonCode)
}

/// Pure technical gate. Formats that Photos cannot store would be `notEligible` until a vault exists (ADR-0002).
public struct EligibilityRules: Sendable {
    public static let supportedCodecs: Set<String> = ["avc1", "hvc1", "hev1"]

    public init() {}

    public func evaluate(_ asset: MediaAsset) -> Eligibility {
        switch asset.kind {
        case .video: break
        case .photo, .livePhoto: return .deferred(.imagesDeferred)
        case .other: return .notEligible(.unsupportedKind)
        }
        if !asset.isOnDevice { return .notEligible(.notOnDevice) }
        if asset.hasAdjustments { return .notEligible(.edited) }
        if asset.isSpecialVideo { return .notEligible(.specialVideo) }
        guard let codec = asset.codec, asset.bitrate != nil, asset.frameRate != nil else {
            return .deferred(.analysisIncomplete)
        }
        if asset.isHDR { return .notEligible(.hdr) }
        if !Self.supportedCodecs.contains(codec) { return .notEligible(.unsupportedCodec) }
        return .eligible
    }
}
