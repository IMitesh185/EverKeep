import Foundation
@testable import EverKeepCore

enum TestError: Error { case boom }

func makeAsset(
    _ id: String = "a1",
    size: Int64 = 100_000_000,
    duration: TimeInterval = 10,
    width: Int = 1920,
    height: Int = 1080,
    bitrate: Int? = 20_000_000,
    fps: Double? = 30,
    codec: String? = "hvc1",
    favorite: Bool = false
) -> MediaAsset {
    MediaAsset(
        id: id,
        kind: .video,
        creationDate: Date(timeIntervalSince1970: 1_700_000_000),
        duration: duration,
        pixelWidth: width,
        pixelHeight: height,
        sizeBytes: size,
        isFavorite: favorite,
        codec: codec,
        bitrate: bitrate,
        frameRate: fps,
        audioTrackCount: 1
    )
}

func goodFinding(candidateBytes: Int64 = 40_000_000) -> ValidationFinding {
    ValidationFinding(
        integrity: IntegrityReport(
            playable: true,
            fullyDecoded: true,
            durationDelta: 0,
            dimensionsMatch: true,
            audioTracksMatch: true,
            frameRateDelta: 0,
            colorMatches: true,
            isHDR: false,
            candidateBytes: candidateBytes
        ),
        quality: QualityMetrics(meanSSIM: 0.995, minSSIM: 0.98, framesCompared: 12)
    )
}

func lowQualityFinding(candidateBytes: Int64 = 30_000_000) -> ValidationFinding {
    var finding = goodFinding(candidateBytes: candidateBytes)
    finding.quality = QualityMetrics(meanSSIM: 0.9, minSSIM: 0.8, framesCompared: 12)
    return finding
}

actor FakeLibrary: LibraryPort {
    enum Deletion { case deleteAll, decline, fail }

    private var listed: [MediaAsset]
    private var analysis: [String: MediaAsset] = [:]
    private var existing: Set<String>
    private var check = ReplacementCheck(exists: true, durationDelta: 0, dimensionsMatch: true, creationDateMatches: true)
    private var deletion = Deletion.deleteAll
    private(set) var analyzeCalls: [String] = []
    private(set) var deleteCalls: [[String]] = []

    init(assets: [MediaAsset] = []) {
        listed = assets
        existing = Set(assets.map(\.id))
    }

    func authorizationState() async -> LibraryAuthorization { .authorized }
    func requestAuthorization() async -> LibraryAuthorization { .authorized }
    func enumerateAssets() async throws -> [MediaAsset] { listed }

    func analyze(_ asset: MediaAsset) async throws -> MediaAsset {
        analyzeCalls.append(asset.id)
        return analysis[asset.id] ?? asset
    }

    func assetExists(id: String) async -> Bool { existing.contains(id) }

    func verifyReplacement(original: MediaAsset, replacementId: String) async throws -> ReplacementCheck { check }

    func deleteOriginals(ids: [String]) async throws -> Set<String> {
        deleteCalls.append(ids)
        switch deletion {
        case .deleteAll:
            existing.subtract(ids)
            return Set(ids)
        case .decline:
            return []
        case .fail:
            throw TestError.boom
        }
    }

    func setListed(_ assets: [MediaAsset]) { listed = assets }
    func setAnalysis(_ asset: MediaAsset) { analysis[asset.id] = asset }
    func setExisting(_ ids: Set<String>) { existing = ids }
    func setCheck(_ value: ReplacementCheck) { check = value }
    func setDeletion(_ value: Deletion) { deletion = value }
}

actor FakeCodec: CodecPort {
    private let bytesPerRung: [Int64]
    private var failure: Error?
    private(set) var calls: [EncodeSettings] = []

    init(bytesPerRung: [Int64] = [40_000_000, 50_000_000, 60_000_000]) {
        self.bytesPerRung = bytesPerRung
    }

    func encode(
        assetId: String,
        settings: EncodeSettings,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> EncodeResult {
        calls.append(settings)
        progress(0.5)
        if let failure { throw failure }
        return EncodeResult(bytes: bytesPerRung[min(calls.count - 1, bytesPerRung.count - 1)])
    }

    func setFailure(_ error: Error?) { failure = error }
}

actor FakeValidator: ValidationPort {
    private let findings: [ValidationFinding]
    private(set) var calls = 0

    init(_ findings: [ValidationFinding]) {
        self.findings = findings
    }

    func validate(original: MediaAsset, candidate: URL, settings: EncodeSettings) async throws -> ValidationFinding {
        defer { calls += 1 }
        return findings[min(calls, findings.count - 1)]
    }
}

actor FakeStorage: StoragePort {
    private var available: Int64 = 10_000_000_000
    private(set) var removed: [String] = []
    private var staged: Set<String> = []

    func availableBytes() async throws -> Int64 { available }

    func stagingURL(name: String) async throws -> URL {
        staged.insert(name)
        return URL(fileURLWithPath: "/tmp/everkeep/\(name)")
    }

    func stagedFileExists(name: String) async -> Bool { staged.contains(name) }

    func removeStaged(name: String) async {
        removed.append(name)
        staged.remove(name)
    }

    func setAvailable(_ value: Int64) { available = value }
    func setStaged(_ names: Set<String>) { staged = names }
}

actor FakeDestination: DestinationPort {
    private var found: String?
    private(set) var placed: [String] = []

    func place(candidate: URL, replacing original: MediaAsset) async throws -> String {
        placed.append(original.id)
        return "new-\(original.id)"
    }

    func findReplacement(for original: MediaAsset) async throws -> String? { found }

    func setFound(_ id: String?) { found = id }
}

/// Everything the orchestrator needs, wired to fakes, with one catalogued candidate.
struct Rig {
    let library: FakeLibrary
    let codec: FakeCodec
    let validator: FakeValidator
    let storage: FakeStorage
    let destination: FakeDestination
    let catalogue: InMemoryCatalogueStore
    let orchestrator: PreservationOrchestrator

    static func make(
        asset: MediaAsset = makeAsset(),
        findings: [ValidationFinding] = [goodFinding()],
        codec: FakeCodec = FakeCodec()
    ) async throws -> Rig {
        let library = FakeLibrary(assets: [asset])
        let validator = FakeValidator(findings)
        let storage = FakeStorage()
        let destination = FakeDestination()
        let catalogue = InMemoryCatalogueStore()
        try await catalogue.upsert(assets: [asset])
        try await catalogue.save(decision: PreservationPolicyEngine().decide(asset, protectedIds: [], settings: PolicySettings()))
        let orchestrator = PreservationOrchestrator(
            library: library,
            codec: codec,
            validators: [validator],
            storage: storage,
            destination: destination,
            catalogue: catalogue,
            reserveBytes: 0
        )
        return Rig(
            library: library,
            codec: codec,
            validator: validator,
            storage: storage,
            destination: destination,
            catalogue: catalogue,
            orchestrator: orchestrator
        )
    }
}
