import EverKeepCore
import Foundation
import SwiftUI

/// Wires the core to the Apple adapters and exposes what the screens need.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var authorization: LibraryAuthorization = .notDetermined
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var summary = LibrarySummary()
    @Published private(set) var activity: [AuditEntry] = []
    @Published private(set) var busy = false
    @Published private(set) var message = "Scan the library to find videos worth optimizing."
    @Published private(set) var progress: Double?
    @Published private(set) var lastResult: ApprovalSummary?

    private let library: PhotoLibraryAdapter
    private let catalogue: any CatalogueStore
    private let manager: MediaLibraryManager
    private let orchestrator: PreservationOrchestrator
    private let settings: PolicySettings

    init() {
        let library = PhotoLibraryAdapter()
        let store: any CatalogueStore
        var startupNote: String?
        do {
            let folder = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            store = try SqliteCatalogueStore(path: folder.appendingPathComponent("catalogue.sqlite").path)
        } catch {
            store = InMemoryCatalogueStore()
            startupNote = "The catalogue could not be opened, so this session is not saved."
        }

        // A launch argument such as `-EKMinBytes 100000` lowers the size gate for tests and demos.
        let minBytesOverride = UserDefaults.standard.integer(forKey: "EKMinBytes")
        self.library = library
        self.catalogue = store
        self.settings = PolicySettings(minBytes: minBytesOverride > 0 ? Int64(minBytesOverride) : 20_000_000)
        self.manager = MediaLibraryManager(library: library, catalogue: store)
        self.orchestrator = PreservationOrchestrator(
            library: library,
            codec: VideoCompressionEngine(library: library),
            validators: [IntegrityValidator(library: library), QualityAssessmentEngine(library: library)],
            storage: StorageMonitor(),
            destination: PhotosDestination(),
            catalogue: store
        )
        if let startupNote { message = startupNote }
    }

    var candidates: [LibraryItem] { items.filter(\.isPrepareable) }

    var ready: [LibraryItem] { items.filter { $0.transaction?.state == .ready } }

    var authorizationText: String {
        switch authorization {
        case .notDetermined: return "Not asked yet"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .limited: return "Limited"
        case .authorized: return "Full access"
        }
    }

    // MARK: Actions

    func start() async {
        authorization = await library.authorizationState()
        _ = try? await orchestrator.recover()
        await refresh()
    }

    func scan() async {
        await run("Scanning the library...") {
            if self.authorization == .notDetermined {
                self.authorization = await self.library.requestAuthorization()
            }
            guard self.authorization.canRead else {
                self.message = "Photo access is needed. Allow it in Settings."
                return
            }
            let result = try await self.manager.sync(settings: self.settings) { done, total in
                Task { @MainActor in self.progress = total > 0 ? Double(done) / Double(total) : nil }
            }
            self.message = "Found \(result.videoCount) videos; \(result.candidateCount) are candidates."
        }
    }

    func prepareAll() async {
        let ids = candidates.map(\.id)
        guard !ids.isEmpty else { return }
        await run("Preparing \(ids.count) candidates...") {
            let results = try await self.orchestrator.prepare(assetIds: ids) { event in
                Task { @MainActor in self.apply(event) }
            }
            let ready = results.filter { $0.state == .ready }.count
            let rejected = results.filter { $0.state == .rejected }.count
            let failed = results.filter { $0.state == .failed }.count
            self.message = "Prepared \(results.count): \(ready) ready, \(rejected) below the quality bar, \(failed) failed."
        }
    }

    func approveAll() async {
        let ids = ready.compactMap { $0.transaction?.id }
        guard !ids.isEmpty else { return }
        await run("Replacing \(ids.count) videos...") {
            let result = try await self.orchestrator.approve(transactionIds: ids) { event in
                Task { @MainActor in self.apply(event) }
            }
            self.lastResult = result
            self.message = "Replaced \(result.committed), kept both copies of \(result.duplicatesKept), "
                + "\(result.failed) failed. Measured saving: \(Format.bytes(result.bytesSaved))."
        }
    }

    func protect(_ id: String) async {
        try? await manager.setProtected(id, true, settings: settings)
        await refresh()
    }

    // MARK: Plumbing

    private func run(_ title: String, _ work: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        message = title
        do {
            try await work()
        } catch {
            message = "Failed: \(error)"
        }
        busy = false
        progress = nil
        await refresh()
    }

    private func refresh() async {
        items = (try? await manager.items()) ?? []
        summary = (try? await manager.summary()) ?? LibrarySummary()
        activity = (try? await catalogue.recentAudit(limit: 200)) ?? []
    }

    private func apply(_ event: OrchestratorEvent) {
        if let fraction = event.fraction { progress = fraction }
        switch event.kind {
        case .encoding: message = "Encoding \(Int((event.fraction ?? 0) * 100))% (\(event.detail ?? ""))"
        case .validating: message = "Checking quality and integrity..."
        case .ready: message = "A candidate is ready for review."
        case .rejected: message = "A candidate did not meet the quality bar."
        case .failed: message = "A candidate failed: \(event.detail ?? "unknown")"
        case .replacing: message = "Adding the smaller copy to Photos..."
        case .verifying: message = "Verifying the copy..."
        case .committed: message = "An original was replaced."
        case .duplicateKept: message = "Both copies were kept."
        }
    }
}
