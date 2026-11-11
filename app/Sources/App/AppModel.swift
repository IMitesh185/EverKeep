import EverKeepCore
import Foundation
import SwiftUI
import AVFoundation
import UIKit

/// Wires the core to the Apple adapters and exposes what the screens need.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var authorization: LibraryAuthorization = .notDetermined
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var summary = LibrarySummary()
    @Published private(set) var activity: [AuditEntry] = []
    @Published private(set) var busy = false
    @Published var message = "Scan Photos, then choose how each item may be preserved."
    @Published private(set) var catalogueReady = true
    @Published private(set) var progress: Double?
    @Published var lastResult: ApprovalSummary?

    // The memory experience (see ExperienceRoot). The classic tabs ignore all of it.
    @Published var screen: ExperienceScreen = .launching
    @Published var category: LibraryCategory = .photos
    @Published var stats: [LibraryCategory: CategoryStats] = [:]
    @Published var excluded: Set<String> = []
    @Published var seen: Set<String> = []
    @Published var checkedCategories: Set<LibraryCategory> = []
    @Published var workProgress = WorkProgress()
    @Published var sheet: SheetKind?
    var survey: [String: SurveyRecord] = [:]
    var surveyLoaded = false
    var surveyTask: Task<Void, Never>?
    var workTask: Task<Void, Never>?
    var preparedIds: Set<String> = []
    let thumbnailCache = NSCache<NSString, UIImage>()

    let library: PhotoLibraryAdapter
    let catalogue: any CatalogueStore
    let manager: MediaLibraryManager
    let orchestrator: PreservationOrchestrator
    let settings: PolicySettings
    let storage: StorageMonitor

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
            startupNote = "The persistent catalogue could not be opened: \(error)"
        }

        // A launch argument such as `-EKMinBytes 100000` lowers the size gate for tests and demos.
        let minBytesOverride = UserDefaults.standard.integer(forKey: "EKMinBytes")
        let minPhotoBytesOverride = UserDefaults.standard.integer(forKey: "EKMinPhotoBytes")
        let storage = StorageMonitor()
        let engine = MediaProcessingEngine(library: library)
        self.library = library
        self.catalogue = store
        self.settings = PolicySettings(
            minBytes: minBytesOverride > 0 ? Int64(minBytesOverride) : 20_000_000,
            minPhotoBytes: minPhotoBytesOverride > 0 ? Int64(minPhotoBytesOverride) : 250_000
        )
        self.storage = storage
        self.manager = MediaLibraryManager(library: library, catalogue: store)
        self.orchestrator = PreservationOrchestrator(
            library: library,
            codec: engine,
            validators: [engine],
            storage: storage,
            destination: PhotosDestination(),
            catalogue: store
        )
        if let startupNote {
            catalogueReady = false
            message = "\(startupNote) Optimization is disabled to keep your preferences safe. Restart the app to retry."
        }
    }

    var candidates: [LibraryItem] { items.filter(\.isPrepareable) }

    var ready: [LibraryItem] { items.filter(\.isReadyForReview) }

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
        guard catalogueReady else {
            routeAfterLaunch()
            return
        }
        do {
            if authorization.canRead { _ = try await orchestrator.recover() }
            try await refresh()
        } catch {
            catalogueReady = false
            message = "Recovery failed; optimization is disabled. Restart to retry. \(error)"
        }
        routeAfterLaunch()
        if screen == .dial { launch { await self.refreshLibraryQuietly() } }
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
                // A big library reports thousands of times; the screen only needs about a hundred updates.
                guard done == total || done % max(1, total / 100) == 0 else { return }
                Task { @MainActor in
                    self.progress = total > 0 ? Double(done) / Double(total) : nil
                    self.workProgress.done = done
                    self.workProgress.total = total
                }
            }
            self.message = "Found \(result.photoCount) photos/screenshots and \(result.videoCount) videos; "
                + "\(result.candidateCount) candidates. \(result.analysisFailures) analysis failures; originals unchanged."
        }
    }

    #if DEBUG
    func loadDemoMedia() async {
        await run("Adding synthetic demo media to Photos...") {
            if self.authorization == .notDetermined {
                self.authorization = await self.library.requestAuthorization()
            }
            guard self.authorization.canRead else {
                self.message = "Allow Photos access in Settings before adding demo media."
                return
            }
            guard let video = Bundle.main.url(forResource: "e2e-sample", withExtension: "mp4"),
                  let photo = Bundle.main.url(forResource: "e2e-photo", withExtension: "jpg") else {
                throw AdapterError.readerFailed("demo resources are missing; build using the Codemagic workflow")
            }
            try await self.library.importDemoMedia([photo, video])
            _ = try await self.manager.sync(settings: self.settings)
            self.message = "Added two synthetic demo items. Choose their preferences before preparing."
        }
    }
    #endif

    func prepareAll(assetIds: [String]? = nil) async {
        let requested = Set(assetIds ?? candidates.map(\.id))
        let ids = candidates.filter { requested.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        await run("Preparing \(ids.count) candidates; originals are untouched...") {
            self.lastResult = nil
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
        await run("Replacing \(ids.count) approved items in Photos...") {
            self.lastResult = nil
            let result = try await self.orchestrator.approve(transactionIds: ids) { event in
                Task { @MainActor in self.apply(event) }
            }
            self.lastResult = result
            _ = try await self.manager.sync(settings: self.settings)
            self.message = "Replaced \(result.committed), kept both copies of \(result.duplicatesKept), "
                + "\(result.failed) failed. Verified file-size reduction: \(Format.bytes(result.bytesSaved)). "
                + "Device space returns after Recently Deleted releases the originals."
        }
    }

    func protect(_ id: String) async {
        await setMode(id, .protected)
    }

    func setMode(_ id: String, _ mode: PreservationMode) async {
        await run("Saving \(mode.title)...") {
            try await self.manager.setMode(id, mode, settings: self.settings)
            try await self.orchestrator.discardCandidates(assetId: id)
            self.message = "Preference saved. \(mode.explanation) No original was changed."
        }
    }

    func setModeForUnassigned(_ mode: PreservationMode, ids: [String]) async {
        let eligibleIds = Set(items.filter { $0.mode == .undecided }.map(\.id)).intersection(ids)
        await run("Applying \(mode.title) to \(eligibleIds.count) unassigned items...") {
            for (index, id) in eligibleIds.sorted().enumerated() {
                try Task.checkCancellation()
                try await self.manager.setMode(id, mode, settings: self.settings)
                self.progress = Double(index + 1) / Double(max(1, eligibleIds.count))
            }
            self.message = "Preferences saved. Protected items were not changed. Preparing and replacing still need approval."
        }
    }

    func preview(_ id: String, size: CGSize = CGSize(width: 320, height: 320)) async throws -> UIImage {
        try await library.preview(id: id, size: size)
    }

    func originalVideo(_ id: String) async throws -> AVAsset {
        try await library.openAVAsset(id: id)
    }

    func candidateURL(for item: LibraryItem) async throws -> URL {
        guard let name = item.transaction?.stagingFile, await storage.stagedFileExists(name: name) else {
            throw AdapterError.imageFailed("the candidate is no longer available; prepare again")
        }
        return try await storage.stagingURL(name: name)
    }

    // MARK: Plumbing

    func run(_ title: String, _ work: () async throws -> Void) async {
        guard !busy else { return }
        guard catalogueReady else {
            message = "The persistent catalogue is unavailable. Restart the app before optimizing."
            return
        }
        busy = true
        message = title
        do {
            try await work()
        } catch is CancellationError {
            message = "Stopped. No original was changed."
        } catch {
            message = "Failed: \(error)"
        }
        do {
            try await refresh()
        } catch {
            catalogueReady = false
            message += " The catalogue could not be refreshed; optimization is disabled. \(error)"
        }
        busy = false
        progress = nil
    }

    func refresh() async throws {
        items = try await manager.items()
        summary = try await manager.summary()
        activity = try await catalogue.recentAudit(limit: 200)
        recomputeStats()
    }

    func apply(_ event: OrchestratorEvent) {
        guard busy else { return }
        if let fraction = event.fraction { progress = fraction }
        let preparing = workProgress.kind == .prepare
        switch event.kind {
        case .encoding:
            message = "Encoding \(Int((event.fraction ?? 0) * 100))% (\(event.detail ?? ""))"
            workProgress.step = "Making each smaller copy"
        case .validating:
            message = "Checking quality and integrity..."
            workProgress.step = "Checking it against the original"
        case .ready:
            message = "A candidate is ready for review."
            if preparing { workProgress.done += 1 }
        case .rejected:
            message = "A candidate did not meet the quality bar."
            if preparing { workProgress.done += 1 }
        case .failed:
            message = "A candidate failed: \(event.detail ?? "unknown")"
            if preparing { workProgress.done += 1 }
        case .replacing:
            message = "Adding the smaller copy to Photos..."
            workProgress.step = "Adding smaller copies to Photos"
        case .verifying:
            message = "Verifying the copy..."
            workProgress.verified += 1
            workProgress.done = workProgress.verified
            workProgress.step = workProgress.verified >= workProgress.total ? "Preparing the delete request" : "Checking each copy in Photos"
        case .committed: message = "An original was replaced."
        case .duplicateKept: message = "Both copies were kept."
        }
    }
}
