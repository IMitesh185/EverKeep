import Foundation

public enum PreservationMode: String, Codable, CaseIterable, Hashable, Sendable {
    case undecided, protected, almostIdentical, spaceFirst

    public var title: String {
        switch self {
        case .undecided: return "Choose a preference"
        case .protected: return "Protected - keep exactly"
        case .almostIdentical: return "Almost identical"
        case .spaceFirst: return "Space first"
        }
    }

    public var explanation: String {
        switch self {
        case .undecided: return "Nothing is optimized until you choose."
        case .protected: return "Keep the original exactly as captured."
        case .almostIdentical: return "Keep resolution and frame rate; require stricter similarity checks."
        case .spaceFirst: return "Videos may shrink to 720p. Keep frame rate and audio; keep photo dimensions and text readable."
        }
    }

    public var permitsOptimization: Bool { self == .almostIdentical || self == .spaceFirst }

    public var tier: QualityTier {
        self == .spaceFirst ? .spaceSaving : .conservative
    }
}
