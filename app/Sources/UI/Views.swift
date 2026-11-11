import EverKeepCore
import SwiftUI

/// The original four-tab interface. Debug builds still open it with `-EKClassicUI YES`, because the
/// end-to-end test drives it. The shipping experience is `ExperienceRoot`.
struct ClassicRootView: View {
    var body: some View {
        TabView {
            OverviewView().tabItem { Label("Overview", systemImage: "externaldrive") }
            PreferencesView().tabItem { Label("Preferences", systemImage: "slider.horizontal.3") }
            ReviewView().tabItem { Label("Review", systemImage: "checkmark.seal") }
            ActivityView().tabItem { Label("Activity", systemImage: "list.bullet") }
        }
    }
}

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Library") {
                    LabeledContent("Photo access", value: model.authorizationText)
                    LabeledContent("Videos", value: "\(model.summary.videoCount)")
                    LabeledContent("Photos and screenshots", value: "\(model.summary.photoCount)")
                    LabeledContent("Need your choice", value: "\(model.summary.byOutcome[.askUser, default: 0])")
                    LabeledContent("Protected", value: "\(model.summary.byOutcome[.protect, default: 0])")
                    LabeledContent("Candidates", value: "\(model.summary.candidateCount) (\(Format.bytes(model.summary.candidateBytes)))")
                    LabeledContent("Ready to review", value: "\(model.summary.readyCount)")
                }
                Section("Measured so far") {
                    LabeledContent("Items replaced", value: "\(model.summary.committedCount)")
                    LabeledContent("Verified file-size reduction", value: Format.bytes(model.summary.bytesSaved))
                    Text("This is not a measurement of free device space. Originals occupy Recently Deleted until permanently removed. iCloud storage optimization can also change the local footprint.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Scan library") { Task { await model.scan() } }
                        .disabled(model.busy || !model.catalogueReady)
                        .accessibilityIdentifier("scanButton")
                    if model.busy { ProgressView(value: model.progress) }
                    Text(model.message)
                        .font(.footnote)
                        .accessibilityIdentifier("statusText")
                }
                #if DEBUG
                Section("Simulator demo") {
                    Button("Add two demo items to Photos") { Task { await model.loadDemoMedia() } }
                        .disabled(model.busy || !model.catalogueReady)
                        .accessibilityIdentifier("demoMediaButton")
                    Text("Adds synthetic media only. Each tap adds a new pair; it never replaces existing items.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                #endif
            }
            .navigationTitle("Everkeep")
        }
    }
}

private enum MediaFilter: String, CaseIterable {
    case all = "All", photos = "Photos", videos = "Videos"

    func includes(_ asset: MediaAsset) -> Bool {
        self == .all || (self == .videos && asset.kind == .video)
            || (self == .photos && (asset.kind.isImage || asset.kind == .livePhoto))
    }
}

struct PreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter = MediaFilter.all
    @State private var bulkMode: PreservationMode?

    private var visible: [LibraryItem] { model.items.filter { filter.includes($0.asset) } }
    private var candidates: [LibraryItem] { visible.filter(\.isPrepareable) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("You choose what may change. Favorites stay protected unless you explicitly choose another preference. Nothing is replaced by choosing or preparing.")
                        .font(.footnote)
                    Picker("Media", selection: $filter) {
                        ForEach(MediaFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if visible.isEmpty {
                    Text("Scan the Photos library first, or choose another filter.").foregroundStyle(.secondary)
                }
                ForEach(visible) { item in
                    HStack(alignment: .top) {
                        NativeThumbnailView(assetId: item.id)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Format.date(item.asset))
                            Text(Format.describe(item.asset)).font(.footnote).foregroundStyle(.secondary)
                            Picker("Preservation", selection: Binding(
                                get: { item.mode },
                                set: { mode in Task { await model.setMode(item.id, mode) } }
                            )) {
                                ForEach(PreservationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("mode-\(item.id)")
                            .disabled(model.busy || !model.catalogueReady)
                            if let decision = item.decision {
                                Text(decision.explanation).font(.caption).foregroundStyle(.secondary)
                            }
                            if let error = item.asset.analysisError {
                                Text("Analysis failed: \(error)").font(.caption).foregroundStyle(.orange)
                            }
                            if let note = item.transaction?.note {
                                Text(note).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Protect") { Task { await model.protect(item.id) } }.tint(.blue)
                    }
                }
            }
            .navigationTitle("Preferences")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Menu("Apply to unassigned \(filter.rawValue.lowercased())") {
                        ForEach(PreservationMode.allCases.filter { $0 != .undecided }, id: \.self) { mode in
                            Button(mode.title) { bulkMode = mode }
                        }
                    }
                    .accessibilityIdentifier("bulkPreferenceButton")
                    .disabled(model.busy || !model.catalogueReady || !visible.contains(where: { $0.mode == .undecided }))
                    Button("Prepare \(candidates.count) candidates") {
                        Task { await model.prepareAll(assetIds: candidates.map(\.id)) }
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || !model.catalogueReady || candidates.isEmpty)
                        .accessibilityIdentifier("prepareButton")
                    if model.busy { ProgressView(value: model.progress) }
                    Text(model.message).font(.caption)
                    Text("Preparing creates temporary candidates only. Photos remains your only permanent media library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.bar)
            }
            .confirmationDialog("Apply a preference to unassigned items?", isPresented: Binding(
                get: { bulkMode != nil },
                set: { if !$0 { bulkMode = nil } }
            ), titleVisibility: .visible) {
                if let mode = bulkMode {
                    Button("Apply \(mode.title)") {
                        let ids = visible.filter { $0.mode == .undecided }.map(\.id)
                        bulkMode = nil
                        Task { await model.setModeForUnassigned(mode, ids: ids) }
                    }
                }
                Button("Cancel", role: .cancel) { bulkMode = nil }
            } message: {
                Text(bulkMode?.explanation ?? "Existing choices and protected items are not overridden.")
            }
        }
    }
}

struct ReviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var reviewing: LibraryItem?
    @State private var confirmReplacement = false

    var body: some View {
        NavigationStack {
            List {
                if model.ready.isEmpty {
                    Text("Nothing to review yet.").foregroundStyle(.secondary)
                }
                ForEach(model.ready) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Format.date(item.asset))
                        Text("\(Format.kind(item.asset.kind)) - \(item.mode.title)").font(.footnote)
                        if let transaction = item.transaction, let bytes = transaction.candidateBytes {
                            Text("\(Format.bytes(transaction.originalBytes)) to \(Format.bytes(bytes))").font(.footnote)
                            if let quality = transaction.finding?.quality {
                                Text("Similarity \(quality.meanSSIM, specifier: "%.3f") on average, \(quality.minSSIM, specifier: "%.3f") at the worst of \(quality.framesCompared) frames")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let plan = transaction.plan, plan.rungs.indices.contains(transaction.rungIndex) {
                                let settings = plan.rungs[transaction.rungIndex]
                                Text("Dimensions: \(item.asset.pixelWidth)x\(item.asset.pixelHeight) to \(settings.width)x\(settings.height)")
                                    .font(.caption)
                            }
                            if let preview = transaction.finding?.preview {
                                Text("Thumbnail similarity: \(preview.minSSIM, specifier: "%.3f") at worst")
                                    .font(.caption)
                            }
                        }
                        Button("Inspect original and candidate") { reviewing = item }
                            .disabled(model.busy)
                        Button("Protect instead") { Task { await model.protect(item.id) } }
                            .disabled(model.busy || !model.catalogueReady)
                    }
                }
                Section {
                    Text("Approving adds the smaller copy to Photos and checks Photos' own preview before requesting deletion. iCloud Photos propagates replacement and deletion to synced devices. Original quality cannot be restored after permanent deletion. Asset identifiers and system categories may change.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    if model.busy { ProgressView(value: model.progress) }
                    Text(model.message).font(.footnote)
                }
                if let result = model.lastResult {
                    Text("Done: \(result.committed) replaced, \(result.duplicatesKept) kept both copies, \(result.failed) failed.")
                        .accessibilityIdentifier("doneBanner")
                }
            }
            .navigationTitle("Review")
            .safeAreaInset(edge: .bottom) {
                Button("Approve \(model.ready.count) and replace") { confirmReplacement = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || !model.catalogueReady || model.ready.isEmpty)
                    .accessibilityIdentifier("approveButton")
                    .padding()
                    .background(.bar)
            }
            .sheet(item: $reviewing) { CandidateReviewView(item: $0).environmentObject(model) }
            .confirmationDialog("Replace approved items in Photos?", isPresented: $confirmReplacement, titleVisibility: .visible) {
                Button("Add verified copies and request deletion") { Task { await model.approveAll() } }
                    .accessibilityIdentifier("confirmReplacementButton")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This affects iCloud-synced devices too. Originals stay in Recently Deleted until permanently removed. No original is deleted if you decline the system prompt.")
            }
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List(model.activity) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.event).font(.subheadline)
                    if !entry.detail.isEmpty {
                        Text(entry.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(entry.at.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Activity")
            .overlay {
                if model.activity.isEmpty { Text("Nothing has happened yet.").foregroundStyle(.secondary) }
            }
        }
    }
}
