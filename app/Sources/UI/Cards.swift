import EverKeepCore
import SwiftUI

/// The glass container for the quiet screens: welcome, working, done.
struct EKCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ekGlass(RoundedRectangle(cornerRadius: 36, style: .continuous), tint: 0.74)
    }
}

/// Places a card at the bottom of the screen or in the middle of it.
struct CardScreen<Content: View>: View {
    enum Position { case middle, bottom }

    private let position: Position
    private let content: Content

    init(_ position: Position, @ViewBuilder content: () -> Content) {
        self.position = position
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content
                .padding(.horizontal, 16)
                .padding(.bottom, position == .bottom ? 22 : 0)
            if position == .middle { Spacer(minLength: 0) }
        }
    }
}

/// A quiet underlined text action.
struct LinkButton: View {
    private let title: String
    private let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .underline(true, color: EK.ink800.opacity(0.35))
                .foregroundStyle(EK.ink800)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }
}

/// A honey bead with a mark in it: a check once something is done, a cross when nothing was changed.
struct Seal: View {
    let symbol: String
    let filled: Bool

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(EK.ink900)
        }
        .frame(width: 72, height: 72)
        .overlay { Circle().strokeBorder(filled ? EK.honey600.opacity(0.4) : EK.ink900.opacity(0.16), lineWidth: 1) }
        .shadow(color: filled ? EK.honey600.opacity(0.5) : Color.clear, radius: 12, x: 0, y: 8)
        .accessibilityHidden(true)
    }

    private var fill: AnyShapeStyle {
        if filled {
            return AnyShapeStyle(RadialGradient(
                colors: [Color(hex: 0xFFF4CF), Color(hex: 0xEDC873), Color(hex: 0xD9A23B)],
                center: UnitPoint(x: 0.36, y: 0.26),
                startRadius: 0,
                endRadius: 60
            ))
        }
        return AnyShapeStyle(EK.ivory50.opacity(0.7))
    }
}

struct ProgressTrack: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(EK.ink900.opacity(0.14))
                Capsule()
                    .fill(LinearGradient(colors: [EK.honey400, EK.honey500], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * CGFloat(fraction)))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.4), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

struct WelcomeCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        EKCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("Free up space.")
                    .font(.ekSerif(44))
                    .foregroundStyle(EK.ink900)
                Text("Keep every memory.")
                    .font(.ekSerif(44).italic())
                    .foregroundStyle(EK.honey700)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Text("Everkeep makes the rest of your library smaller, and checks every copy first. Favorites and photos of people stay as they are unless you say otherwise.")
                .font(.system(size: 15))
                .foregroundStyle(EK.ink700)
                .fixedSize(horizontal: false, vertical: true)
            if !model.catalogueReady {
                Text(model.message)
                    .font(.footnote)
                    .foregroundStyle(EK.ink600)
            }
            Button {
                model.launch { await model.beginScan() }
            } label: {
                HStack(spacing: 10) {
                    Text("Scan my library")
                    Image(systemName: "arrow.right").font(.system(size: 16, weight: .semibold))
                }
            }
            .buttonStyle(HoneyButtonStyle())
            .disabled(!model.catalogueReady)
            .accessibilityIdentifier("welcomeScanButton")
            Text("Everything stays on this iPhone. Nothing changes until you approve.")
                .font(.system(size: 12.5))
                .foregroundStyle(EK.ink600)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            HStack {
                Spacer()
                LinkButton("How it works") { model.sheet = .how }
                #if DEBUG
                LinkButton("Add demo media") { model.launch { await model.loadDemoMedia() } }
                    .accessibilityIdentifier("demoMediaButton")
                #endif
                Spacer()
            }
        }
    }
}

struct NoAccessCard: View {
    @EnvironmentObject private var model: AppModel

    private var headline: Text {
        Text("Everkeep can't see your library ").font(.ekSerif(34)).foregroundColor(EK.ink900)
            + Text("yet").font(.ekSerif(34).italic()).foregroundColor(EK.honey700)
    }

    var body: some View {
        EKCard {
            Text("Photos access").ekEyebrow()
            headline
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Allow access to Photos in Settings, so Everkeep can check every copy. Nothing is read until you do.")
                .font(.system(size: 15))
                .foregroundStyle(EK.ink700)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.openSettings()
            } label: {
                Text("Open Settings")
            }
            .buttonStyle(HoneyButtonStyle())
            .accessibilityIdentifier("openSettingsButton")
            HStack {
                Spacer()
                LinkButton("Try again") { model.launch { await model.beginScan() } }
                LinkButton("How your photos are protected") { model.sheet = .how }
                Spacer()
            }
        }
    }
}

/// Scanning, preparing and replacing share one calm card. Counts, never a countdown: the time is unknown.
struct ProgressCard: View {
    @EnvironmentObject private var model: AppModel

    private var title: String {
        switch model.workProgress.kind {
        case .scan: return "Looking through your library"
        case .prepare: return "Making smaller copies"
        case .apply: return "Adding the copies to Photos"
        }
    }

    private var note: String {
        switch model.workProgress.kind {
        case .scan: return "Everything stays on this iPhone."
        case .prepare: return "Your originals are untouched."
        case .apply: return "Almost there. Your originals are still untouched."
        }
    }

    private var countText: String {
        let work = model.workProgress
        guard work.total > 0 else { return "" }
        let unit = work.kind == .scan ? "items" : model.category.plural
        return "\(work.done.formatted()) of \(work.total.formatted()) \(unit)"
    }

    var body: some View {
        let work = model.workProgress
        EKCard {
            Text("Working quietly").ekEyebrow()
            Text(title)
                .font(.ekSerif(34))
                .foregroundStyle(EK.ink900)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            ProgressTrack(fraction: work.fraction)
            Text(work.step)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(EK.ink800)
            Text(countText)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(EK.ink600)
            Text(note)
                .font(.system(size: 12.5))
                .foregroundStyle(EK.ink600)
            if work.kind != .apply {
                HStack {
                    Spacer()
                    LinkButton("Cancel") { model.cancelWork() }
                    Spacer()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("progressCard")
    }
}

/// What happened after the iOS delete prompt: replaced, declined, or stopped before anything changed.
struct DoneCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let result = model.lastResult, result.committed > 0 {
            applied(result)
        } else if (model.lastResult?.duplicatesKept ?? 0) > 0 {
            declined
        } else {
            stopped
        }
    }

    private func appliedTitle(_ result: ApprovalSummary) -> Text {
        Text(Amounts.text(result.bytesSaved)).font(.ekSerif(34).italic()).foregroundColor(EK.honey700)
            + Text(" smaller").font(.ekSerif(34)).foregroundColor(EK.ink900)
    }

    private var declinedTitle: Text {
        Text("Nothing was ").font(.ekSerif(34)).foregroundColor(EK.ink900)
            + Text("deleted").font(.ekSerif(34).italic()).foregroundColor(EK.honey700)
    }

    private func applied(_ result: ApprovalSummary) -> some View {
        EKCard {
            Seal(symbol: "checkmark", filled: true)
            appliedTitle(result)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("doneTitle")
            Text("Your originals are waiting in Recently Deleted. The space comes back when you empty it in Photos, or automatically within 30 days.")
                .font(.system(size: 15))
                .foregroundStyle(EK.ink700)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.finishDone()
            } label: {
                Text("Done")
            }
            .buttonStyle(HoneyButtonStyle())
            .accessibilityIdentifier("doneButton")
            Text("Measured after checking every item.")
                .font(.system(size: 12.5))
                .foregroundStyle(EK.ink600)
                .frame(maxWidth: .infinity)
        }
    }

    private var declined: some View {
        EKCard {
            Seal(symbol: "xmark", filled: false)
            declinedTitle
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("doneTitle")
            Text("The smaller copies were added next to your originals, so they use extra space until the originals are deleted. You can finish whenever you like.")
                .font(.system(size: 15))
                .foregroundStyle(EK.ink700)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.openReview()
            } label: {
                HStack(spacing: 10) {
                    Text("Review again")
                    Image(systemName: "arrow.right").font(.system(size: 16, weight: .semibold))
                }
            }
            .buttonStyle(HoneyButtonStyle())
            .accessibilityIdentifier("reviewAgainButton")
            HStack {
                Spacer()
                LinkButton("Not now") { model.finishDone() }
                Spacer()
            }
        }
    }

    private var stopped: some View {
        EKCard {
            Seal(symbol: "xmark", filled: false)
            Text("Nothing was changed")
                .font(.ekSerif(34))
                .foregroundStyle(EK.ink900)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("doneTitle")
            Text(model.message)
                .font(.system(size: 15))
                .foregroundStyle(EK.ink700)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.finishDone()
            } label: {
                Text("Done")
            }
            .buttonStyle(HoneyButtonStyle())
            .accessibilityIdentifier("doneButton")
        }
    }
}
