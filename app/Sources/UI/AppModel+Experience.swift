import EverKeepCore
import Foundation
import SwiftUI
import UIKit

/// The memory experience on top of the engine. Nothing here touches an original: it measures, lists,
/// and asks the existing orchestrator to prepare and replace what the person approved.
extension AppModel {
    // MARK: Launch and navigation

    /// Debug builds can still open the original tab interface, which the end-to-end test drives.
    static var usesClassicInterface: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "EKClassicUI")
        #else
        return false
        #endif
    }

    /// True once a scan has run to the end. A scan that was stopped keeps what it found (spec section 10),
    /// and that must not be shown as the whole library on the next launch.
    static var libraryScanned: Bool {
        get { UserDefaults.standard.bool(forKey: "EKLibraryScanned") }
        set { UserDefaults.standard.set(newValue, forKey: "EKLibraryScanned") }
    }

    func routeAfterLaunch() {
        guard !AppModel.usesClassicInterface else { return }
        switch authorization {
        case .denied, .restricted:
            screen = .noAccess
        case .notDetermined:
            screen = .welcome
        case .authorized, .limited:
            if items.isEmpty || !AppModel.libraryScanned {
                screen = .welcome
            } else {
                screen = .dial
                startSurvey()
            }
        }
    }

    /// Picks up photos added or removed since the last visit, without leaving the dial.
    func refreshLibraryQuietly() async {
        await scan()
        if authorization.canRead { startSurvey() }
    }

    /// Runs one long task that the person can still cancel.
    func launch(_ work: @escaping @MainActor () async -> Void) {
        workTask = Task { await work() }
    }

    func cancelWork() {
        workTask?.cancel()
    }

    func select(_ next: LibraryCategory) {
        guard next != category else { return }
        withAnimation(.easeOut(duration: 0.4)) { category = next }
        startSurvey()
    }

    func openReview() {
        sheet = nil
        screen = .review
    }

    func closeReview() {
        sheet = nil
        screen = .dial
    }

    func finishDone() {
        sheet = nil
        screen = .dial
    }

    func openLook(_ id: String) {
        seen.insert(id)
        sheet = .look(id)
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    func beginScan() async {
        guard catalogueReady else { return }
        screen = .scanning
        workProgress = WorkProgress(kind: .scan, step: "Reading your library")
        await scan()
        if Task.isCancelled {
            // Stopping returns to the start. What the scan found is kept, but it does not count as a finished scan.
            AppModel.libraryScanned = false
            routeAfterLaunch()
            return
        }
        guard authorization.canRead else {
            screen = authorization == .notDetermined ? .welcome : .noAccess
            return
        }
        guard catalogueReady else {
            // The welcome card explains why scanning is switched off.
            screen = .welcome
            return
        }
        AppModel.libraryScanned = true
        screen = .dial
        startSurvey()
    }

    // MARK: Library by category

    func itemsIn(_ category: LibraryCategory) -> [LibraryItem] {
        items.filter { LibraryCategory.of($0.asset.kind) == category }
    }

    /// A handful of the person's own photographs to remember with. Screenshots borrow photos, which make better memories.
    func memoryIds(for category: LibraryCategory) -> [String] {
        let own = itemsIn(category)
        var source = own
        if category == .screenshots || own.isEmpty {
            let photos = itemsIn(.photos)
            source = photos.isEmpty ? items : photos
        }
        guard !source.isEmpty else { return [] }
        let count = min(8, source.count)
        let step = max(1, source.count / count)
        let offset = category == .screenshots ? step / 2 : 0
        return (0..<count).map { source[($0 * step + offset) % source.count].id }
    }

    func thumbnail(_ id: String, side: CGFloat) async -> UIImage? {
        let key = "\(id)|\(Int(side))" as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let image = try? await preview(id, size: CGSize(width: side, height: side)) else { return nil }
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    func candidateImage(for item: LibraryItem, side: Int) async -> UIImage? {
        guard let url = try? await candidateURL(for: item) else { return nil }
        return try? await Task.detached(priority: .userInitiated) {
            let document = try ImageDocument(data: Data(contentsOf: url))
            return UIImage(cgImage: try document.rendered(maxSide: side))
        }.value
    }

    // MARK: Survey: sizes and estimated savings, measured one item at a time

    private var settingsKey: String {
        "\(settings.minBytes)-\(settings.minPhotoBytes)-\(PreservationPolicyEngine.version)-\(QualityPolicy.version)"
    }

    func startSurvey() {
        guard !AppModel.usesClassicInterface, authorization.canRead, catalogueReady, surveyTask == nil else { return }
        surveyTask = Task { [weak self] in
            await self?.loadSurvey()
            await self?.surveyLoop()
            self?.surveyTask = nil
        }
    }

    /// A launch starts from what the last one measured.
    private func loadSurvey() async {
        guard !surveyLoaded else { return }
        survey = await SurveyStore.shared.load()
        surveyLoaded = true
        for (id, record) in survey where record.look != nil { excluded.insert(id) }
        recomputeStats()
    }

    private func isSurveyed(_ item: LibraryItem) -> Bool {
        guard let record = survey[item.id] else { return false }
        return record.settingsKey == settingsKey && record.matches(item.asset)
    }

    private func staleItems(prioritizing focus: LibraryCategory, skipping attempted: Set<String>) -> [LibraryItem] {
        let pending = items.filter { item in
            LibraryCategory.of(item.asset.kind) != nil && !attempted.contains(item.id) && !isSurveyed(item)
        }
        let first = pending.filter { LibraryCategory.of($0.asset.kind) == focus }
        let rest = pending.filter { LibraryCategory.of($0.asset.kind) != focus }
        return first + rest
    }

    private func surveyLoop() async {
        let engine = PreservationPolicyEngine()
        let planner = CompressionPlanner()
        var attempted = Set<String>()
        var focus = category
        var queue = staleItems(prioritizing: focus, skipping: attempted)
        var cursor = 0
        var sinceFlush = 0
        var lastSave = Date()
        while !Task.isCancelled {
            // The person may turn the dial meanwhile: measure what they are looking at first.
            if focus != category || cursor >= queue.count {
                focus = category
                queue = staleItems(prioritizing: focus, skipping: attempted)
                cursor = 0
                if queue.isEmpty { break }
            }
            let item = queue[cursor]
            cursor += 1
            attempted.insert(item.id)
            if isSurveyed(item) { continue }
            let record = await measure(item, engine: engine, planner: planner)
            if Task.isCancelled { break }
            survey[item.id] = record
            if record.look != nil { excluded.insert(item.id) }
            sinceFlush += 1
            if sinceFlush >= 6 {
                sinceFlush = 0
                recomputeStats()
                // A big library takes a while to measure, so do not lose it all if the app is closed meanwhile.
                if Date().timeIntervalSince(lastSave) > 20 {
                    lastSave = Date()
                    persistSurvey()
                }
            }
        }
        let liveIds = Set(items.map(\.id))
        survey = survey.filter { liveIds.contains($0.key) }
        recomputeStats()
        persistSurvey()
    }

    private func persistSurvey() {
        let snapshot = survey
        Task { await SurveyStore.shared.save(snapshot) }
    }

    private func measure(_ item: LibraryItem, engine: PreservationPolicyEngine, planner: CompressionPlanner) async -> SurveyRecord {
        var asset = item.asset
        var failure: String?
        do {
            asset = try await library.analyze(item.asset)
        } catch {
            failure = String(describing: error)
        }
        if asset.sizeBytes == 0 {
            asset.sizeBytes = await library.footprint(id: asset.id)
        }
        var candidate = false
        var saving: Int64 = 0
        var look: LookReason?
        // The question asked here is "what could Everkeep do if the person said yes", so protection is ignored.
        // Favorites are never offered.
        if failure == nil, !asset.isFavorite {
            let decision = engine.decide(asset, protectedIds: [], settings: settings, mode: .almostIdentical)
            if decision.isCandidate, let plan = planner.plan(for: asset, tier: .conservative, mode: .almostIdentical) {
                saving = SavingsEstimator.estimate(for: asset, plan: plan)
                candidate = saving > 0
            }
        }
        if candidate {
            if asset.contentHints?.containsFaces == true {
                look = .person
            } else if asset.kind == .video && asset.contentHints?.motion == .high {
                look = .motion
            }
        }
        return SurveyRecord(
            asset: asset, candidate: candidate, saving: saving, look: look, failure: failure, settingsKey: settingsKey
        )
    }

    func recomputeStats() {
        var result: [LibraryCategory: CategoryStats] = [:]
        for item in items {
            guard let kind = LibraryCategory.of(item.asset.kind) else { continue }
            var entry = result[kind] ?? CategoryStats()
            entry.itemCount += 1
            if let record = survey[item.id], record.matches(item.asset) {
                entry.measuredCount += 1
                entry.usedBytes += max(record.asset.sizeBytes, item.asset.sizeBytes)
                if record.candidate, item.mode != .protected {
                    entry.reviewableCount += 1
                    if !excluded.contains(item.id) {
                        entry.potentialBytes += record.saving
                    }
                }
            } else {
                entry.usedBytes += item.asset.sizeBytes
            }
            result[kind] = entry
        }
        stats = result
    }

    // MARK: Review

    func isChecked(_ category: LibraryCategory) -> Bool {
        checkedCategories.contains(category) || itemsIn(category).contains { $0.isReadyForReview }
    }

    func entries(for category: LibraryCategory) -> [ReviewEntry] {
        let checked = isChecked(category)
        var result: [ReviewEntry] = []
        for item in itemsIn(category) {
            guard let record = survey[item.id], record.matches(item.asset), record.candidate else { continue }
            let state: TileState
            if item.mode == .protected {
                state = .protected
            } else if checked {
                if item.isReadyForReview {
                    state = excluded.contains(item.id) ? .off : .on
                } else if preparedIds.contains(item.id) || item.transaction != nil {
                    state = .failed
                } else {
                    state = .skipped
                }
            } else {
                state = excluded.contains(item.id) ? .off : .on
            }
            let wantsLook = !checked && (state == .on || state == .off) && !seen.contains(item.id)
            result.append(ReviewEntry(item: item, record: record, state: state, look: wantsLook ? record.look : nil))
        }
        return result.sorted { $0.saving > $1.saving }
    }

    func entry(_ id: String) -> ReviewEntry? {
        entries(for: category).first { $0.id == id }
    }

    func totals(for category: LibraryCategory) -> ReviewTotals {
        let checked = isChecked(category)
        let list = entries(for: category)
        var totals = ReviewTotals()
        totals.checked = checked
        totals.total = list.count
        for entry in list {
            switch entry.state {
            case .on:
                totals.selected += 1
                totals.bytes += checked ? measuredSaving(entry.item) : entry.saving
            case .off:
                if entry.look != nil { totals.needLook += 1 }
            case .protected, .failed, .skipped:
                break
            }
        }
        totals.left = totals.total - totals.selected
        return totals
    }

    private func measuredSaving(_ item: LibraryItem) -> Int64 {
        guard let transaction = item.transaction, let bytes = transaction.candidateBytes else { return 0 }
        return max(0, transaction.originalBytes - bytes)
    }

    func setIncluded(_ id: String, _ included: Bool) {
        if included { excluded.remove(id) } else { excluded.insert(id) }
        recomputeStats()
    }

    func toggle(_ id: String) {
        setIncluded(id, excluded.contains(id))
    }

    func protectItem(_ id: String) async {
        await protect(id)
    }

    func unprotectItem(_ id: String) async {
        await setMode(id, .undecided)
    }

    // MARK: Prepare, preserve, discard

    /// Stage 1 (ADR-0003): the person opted in for these items, so they get the "Almost identical" preference
    /// and the engine makes and checks smaller copies. Nothing is replaced yet.
    func prepareSelection() async {
        let kind = category
        let chosen = entries(for: kind).filter { $0.state == .on }
        guard !chosen.isEmpty, !busy else { return }
        sheet = nil
        screen = .working
        workProgress = WorkProgress(kind: .prepare, step: "Making each smaller copy", done: 0, total: chosen.count)
        preparedIds.formUnion(chosen.map(\.id))
        await run("Preparing \(chosen.count) items; originals are untouched...") {
            self.lastResult = nil
            for entry in chosen {
                try Task.checkCancellation()
                // Hand the engine the analysis the survey already did, so it does not read the item twice.
                if let record = entry.record { try await self.catalogue.upsert(assets: [record.asset]) }
                try await self.manager.setMode(entry.id, .almostIdentical, settings: self.settings)
            }
            let results = try await self.orchestrator.prepare(assetIds: chosen.map(\.id)) { event in
                Task { @MainActor in self.apply(event) }
            }
            let ready = results.filter { $0.state == .ready }.count
            self.message = "Checked \(results.count): \(ready) ready, \(results.count - ready) stay as they are."
        }
        if Task.isCancelled {
            // Stopping means starting over. Nothing was replaced, so drop whatever was made and go back to the list.
            let ids = chosen.map(\.id)
            await Task { await self.discardPrepared() }.value
            preparedIds.subtract(ids)
            screen = .review
            return
        }
        checkedCategories.insert(kind)
        screen = .review
    }

    /// Stage 2: the person approved the checked copies. The engine adds them to Photos, verifies each there,
    /// and asks iOS once to delete the originals.
    func preserveSelection() async {
        let kind = category
        let ids = entries(for: kind).filter { $0.state == .on }.compactMap { $0.item.transaction?.id }
        guard !ids.isEmpty, !busy else { return }
        sheet = nil
        screen = .working
        workProgress = WorkProgress(kind: .apply, step: "Adding smaller copies to Photos", done: 0, total: ids.count)
        await run("Replacing \(ids.count) approved items in Photos...") {
            self.lastResult = nil
            let result = try await self.orchestrator.approve(transactionIds: ids) { event in
                Task { @MainActor in self.apply(event) }
            }
            self.lastResult = result
            _ = try await self.manager.sync(settings: self.settings)
            self.message = "Replaced \(result.committed), kept both copies of \(result.duplicatesKept), "
                + "\(result.failed) failed. Verified file-size reduction: \(Format.bytes(result.bytesSaved))."
        }
        checkedCategories.remove(kind)
        screen = .done
        startSurvey()
    }

    func discardPrepared() async {
        let kind = category
        let ids = itemsIn(kind).filter { $0.transaction?.state == .ready }.map(\.id)
        await run("Discarding prepared copies...") {
            for id in ids { try await self.orchestrator.discardCandidates(assetId: id) }
            self.message = "Prepared copies were discarded. Your originals were never touched."
        }
        checkedCategories.remove(kind)
        preparedIds.subtract(ids)
    }
}
