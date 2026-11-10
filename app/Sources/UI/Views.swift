import EverKeepCore
import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            OverviewView().tabItem { Label("Overview", systemImage: "externaldrive") }
            CandidatesView().tabItem { Label("Candidates", systemImage: "film") }
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
                    LabeledContent("Candidates", value: "\(model.summary.candidateCount) (\(Format.bytes(model.summary.candidateBytes)))")
                    LabeledContent("Ready to review", value: "\(model.summary.readyCount)")
                }
                Section("Measured so far") {
                    LabeledContent("Videos replaced", value: "\(model.summary.committedCount)")
                    LabeledContent("Space freed", value: Format.bytes(model.summary.bytesSaved))
                    Text("Counted from replaced videos only, never estimated. iOS returns the space when Recently Deleted is emptied.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Scan library") { Task { await model.scan() } }
                        .disabled(model.busy)
                        .accessibilityIdentifier("scanButton")
                    if model.busy { ProgressView(value: model.progress) }
                    Text(model.message)
                        .font(.footnote)
                        .accessibilityIdentifier("statusText")
                }
            }
            .navigationTitle("Everkeep")
        }
    }
}

struct CandidatesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if model.candidates.isEmpty {
                    Text("No candidates yet. Scan the library first.").foregroundStyle(.secondary)
                }
                ForEach(model.candidates) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Format.date(item.asset))
                        Text(Format.describe(item.asset)).font(.footnote).foregroundStyle(.secondary)
                        if let decision = item.decision {
                            Text(decision.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                        if let note = item.transaction?.note {
                            Text(note).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .swipeActions {
                        Button("Protect") { Task { await model.protect(item.id) } }.tint(.blue)
                    }
                }
            }
            .navigationTitle("Candidates")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Button("Prepare \(model.candidates.count) candidates") { Task { await model.prepareAll() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || model.candidates.isEmpty)
                        .accessibilityIdentifier("prepareButton")
                    Text("Nothing is changed yet. Preparing only creates candidates and checks them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.bar)
            }
        }
    }
}

struct ReviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if model.ready.isEmpty {
                    Text("Nothing to review yet.").foregroundStyle(.secondary)
                }
                ForEach(model.ready) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Format.date(item.asset))
                        if let transaction = item.transaction, let bytes = transaction.candidateBytes {
                            Text("\(Format.bytes(transaction.originalBytes)) to \(Format.bytes(bytes))").font(.footnote)
                            if let quality = transaction.finding?.quality {
                                Text("Similarity \(quality.meanSSIM, specifier: "%.3f") on average, \(quality.minSSIM, specifier: "%.3f") at the worst of \(quality.framesCompared) frames")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Text("Approving adds each smaller copy to Photos and checks it. Then iOS asks once to delete the originals. Space returns only after Recently Deleted is emptied.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let result = model.lastResult {
                    Text("Done: \(result.committed) replaced, \(result.duplicatesKept) kept both copies, \(result.failed) failed.")
                        .accessibilityIdentifier("doneBanner")
                }
            }
            .navigationTitle("Review")
            .safeAreaInset(edge: .bottom) {
                Button("Approve \(model.ready.count) and replace") { Task { await model.approveAll() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.ready.isEmpty)
                    .accessibilityIdentifier("approveButton")
                    .padding()
                    .background(.bar)
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
