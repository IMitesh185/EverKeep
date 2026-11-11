import EverKeepCore
import SwiftUI
import UIKit

/// The actual media Everkeep would change, one tile each. Nothing is hidden and nothing is decided for you:
/// leave any out, protect any, and look closer wherever Everkeep is unsure.
struct ReviewScreen: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        let category = model.category
        let entries = model.entries(for: category)
        let totals = model.totals(for: category)
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(category: category, totals: totals)
                    Text(totals.checked
                         ? "Tap the circle to leave one out. Items that did not pass stay as they are."
                         : "Tap a \(category.singular) to look closer. Tap its circle to leave it out.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(EK.ink600)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 12)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(entries) { entry in
                            MediaTile(entry: entry, category: category)
                        }
                    }
                    if entries.isEmpty {
                        Text("Nothing is selected for this category.")
                            .font(.system(size: 14))
                            .foregroundStyle(EK.ink600)
                            .padding(.top, 24)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 64)
                .padding(.bottom, 24)
            }
            topFade
            HStack {
                RoundGlassButton(symbol: "chevron.left", label: "Back to your library") { model.closeReview() }
                    .accessibilityIdentifier("backButton")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer(category: category, totals: totals) }
    }

    // MARK: Header

    private func title(checked: Bool) -> Text {
        if checked {
            return Text("Checked and ").font(.ekSerif(46)).foregroundColor(EK.ink900)
                + Text("ready").font(.ekSerif(46).italic()).foregroundColor(EK.honey700)
        }
        return Text("Ready to ").font(.ekSerif(46)).foregroundColor(EK.ink900)
            + Text("preserve").font(.ekSerif(46).italic()).foregroundColor(EK.honey700)
    }

    private func summary(_ totals: ReviewTotals) -> Text {
        Text(Amounts.text(totals.bytes, approximate: !totals.checked)).font(.ekSerif(30)).foregroundColor(EK.ink900)
            + Text(" smaller").font(.system(size: 17, weight: .medium)).foregroundColor(EK.ink900)
    }

    private func header(category: LibraryCategory, totals: ReviewTotals) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(totals.checked ? "Checked" : "Review") · \(category.title)").ekEyebrow()
            title(checked: totals.checked)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            summary(totals)
                .accessibilityIdentifier("reviewSummary")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(totals.checked ? EK.sage500 : EK.honey500).frame(width: 7, height: 7)
                Text(subline(totals, measuring: !(model.stats[category]?.isComplete ?? true)))
                    .font(.system(size: 13.5))
                    .foregroundStyle(EK.ink600)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 14)
    }

    private func subline(_ totals: ReviewTotals, measuring: Bool) -> String {
        if totals.checked {
            return "Measured after checking every item. \(totals.selected.formatted()) ready, \(totals.left.formatted()) stay as they are."
        }
        var text = "\(totals.selected.formatted()) of \(totals.total.formatted()) selected"
        if totals.needLook > 0 {
            text += " · \(totals.needLook) \(totals.needLook == 1 ? "needs" : "need") a look"
        }
        if measuring { text += " · still measuring" }
        return text
    }

    private var topFade: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(EK.ivory100.opacity(0.5))
            .frame(height: 104)
            .mask {
                LinearGradient(
                    stops: [Gradient.Stop(color: .black, location: 0.58), Gradient.Stop(color: .clear, location: 1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }

    // MARK: Footer: one obvious approval

    private func footer(category: LibraryCategory, totals: ReviewTotals) -> some View {
        VStack(spacing: 10) {
            Button {
                model.launch {
                    if totals.checked { await model.preserveSelection() } else { await model.prepareSelection() }
                }
            } label: {
                Text(primaryTitle(category: category, totals: totals))
            }
            .buttonStyle(HoneyButtonStyle(height: 60))
            .disabled(totals.selected == 0 || model.busy)
            .accessibilityIdentifier("reviewPrimaryButton")
            Text(totals.checked
                 ? "Originals move to Recently Deleted for 30 days. iOS will ask you once more."
                 : "Nothing changes yet. Everkeep checks every smaller copy before anything is replaced.")
                .font(.system(size: 12.5))
                .foregroundStyle(EK.ink600)
                .multilineTextAlignment(.center)
            HStack(spacing: 22) {
                LinkButton(totals.checked ? "What happens next" : "How it works") { model.sheet = .how }
                if totals.checked {
                    LinkButton("Discard results") { model.launch { await model.discardPrepared() } }
                        .accessibilityIdentifier("discardButton")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 34, style: .continuous).fill(EK.ivory100.opacity(0.74))
            }
            // The lower corners sit below the screen edge, so only the top is rounded.
            .padding(.bottom, -60)
            .shadow(color: EK.shadow.opacity(0.3), radius: 22, x: 0, y: -6)
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private func primaryTitle(category: LibraryCategory, totals: ReviewTotals) -> String {
        if totals.selected == 0 { return "Nothing selected" }
        let verb = totals.checked ? "Preserve" : "Prepare"
        return "\(verb) \(totals.selected.formatted()) \(category.noun(totals.selected))"
    }
}

/// One real photo or video. The circle leaves it out, the rest of the tile looks closer.
struct MediaTile: View {
    @EnvironmentObject private var model: AppModel
    let entry: ReviewEntry
    let category: LibraryCategory

    @State private var image: UIImage?

    private var locked: Bool { entry.state == .protected || entry.state == .failed }
    private var dimmed: Bool { entry.state == .off || entry.state == .skipped || locked }
    private var date: String { Format.date(entry.item.asset) }

    var body: some View {
        ZStack {
            Button {
                model.openLook(entry.id)
            } label: {
                face
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Look closer at \(date)")
            .accessibilityIdentifier("tile-\(entry.id)")
            badges.allowsHitTesting(false)
            if locked {
                lockChip.allowsHitTesting(false)
            } else {
                toggle
            }
        }
        .aspectRatio(category.tileRatio, contentMode: .fit)
        .task(id: entry.id) { await loadThumbnail() }
    }

    @MainActor
    private func loadThumbnail() async {
        image = await model.thumbnail(entry.id, side: 600)
    }

    private var face: some View {
        Color.clear
            .overlay { picture.saturation(dimmed ? 0.4 : 1).brightness(dimmed ? -0.12 : 0) }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(entry.look != nil ? EK.honey400 : Color.white.opacity(0.5), lineWidth: entry.look != nil ? 2 : 1)
            }
            .shadow(color: EK.shadow.opacity(0.3), radius: 12, x: 0, y: 8)
    }

    @ViewBuilder private var picture: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            EK.champagne300.overlay { ProgressView().tint(EK.ink600) }
        }
    }

    private var isOn: Bool { entry.state == .on }

    private var toggle: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    model.toggle(entry.id)
                } label: {
                    ZStack {
                        Circle().fill(isOn ? AnyShapeStyle(EK.honeyFill) : AnyShapeStyle(Color.black.opacity(0.3)))
                        Circle().strokeBorder(Color.white.opacity(isOn ? 0.7 : 0.92), lineWidth: isOn ? 1 : 2)
                        if isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(EK.ink900)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .padding(7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(entry.state == .skipped)
                .accessibilityLabel("Preserve \(date)")
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier("tileToggle-\(entry.id)")
            }
            Spacer()
        }
    }

    private var lockChip: some View {
        VStack {
            HStack {
                Spacer()
                Image(systemName: "lock")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(EK.ink900)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(EK.ivory100.opacity(0.85)))
                    .background(Circle().fill(.ultraThinMaterial))
                    .padding(9)
            }
            Spacer()
        }
    }

    private var badges: some View {
        VStack {
            HStack {
                if category == .livePhotos { chip("livephoto", "Live", tint: EK.ivory100.opacity(0.82)) }
                Spacer()
            }
            Spacer()
            HStack {
                if entry.look != nil {
                    chip("eye", "Look closer", tint: EK.honey300.opacity(0.9))
                } else if locked {
                    chip("lock", entry.state == .protected ? "Protected" : "Kept as original", tint: EK.ivory100.opacity(0.85))
                }
                Spacer()
                if category == .videos {
                    chip("play.fill", Format.clock(entry.item.asset.duration), tint: EK.ivory100.opacity(0.82))
                }
            }
        }
    }

    private func chip(_ symbol: String, _ text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(EK.ink900)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule().fill(tint))
        .background(Capsule().fill(.ultraThinMaterial))
        .padding(9)
    }
}
