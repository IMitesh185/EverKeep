import AVKit
import EverKeepCore
import SwiftUI
import UIKit

private struct SheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Shows one sheet over a dimmed screen. Tap outside, drag down, or press Close to dismiss it.
struct SheetHost: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            if let sheet = model.sheet {
                EK.scrim.opacity(0.34)
                    .ignoresSafeArea()
                    .onTapGesture { model.sheet = nil }
                    .transition(.opacity)
                    .accessibilityHidden(true)
                SheetContainer {
                    switch sheet {
                    case .look(let id): LookCloserSheet(id: id)
                    case .how: HowSheet()
                    }
                }
                .transition(.move(edge: .bottom))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: model.sheet)
    }
}

struct SheetContainer<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    private let content: Content
    @State private var contentHeight: CGFloat = 560

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let limit = UIScreen.main.bounds.height * 0.9
        VStack(spacing: 0) {
            Capsule()
                .fill(EK.ink900.opacity(0.25))
                .frame(width: 38, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture().onEnded { value in
                    if value.translation.height > 80 { model.sheet = nil }
                })
                .accessibilityHidden(true)
            ScrollView(showsIndicators: false) {
                content
                    .padding(.horizontal, 20)
                    .padding(.bottom, 34)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: SheetHeightKey.self, value: proxy.size.height)
                    })
            }
        }
        .onPreferenceChange(SheetHeightKey.self) { contentHeight = $0 }
        .frame(maxWidth: .infinity)
        .frame(height: min(limit, contentHeight + 23))
        .background(alignment: .top) {
            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 34, style: .continuous).fill(EK.ivory100.opacity(0.8))
            }
            .padding(.bottom, -80)
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(EK.glassEdge, lineWidth: 1)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityAddTraits(.isModal)
    }
}

struct SheetHeader: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.ekSerif(34))
                    .foregroundStyle(EK.ink900)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(EK.ink600)
            }
            Spacer(minLength: 8)
            RoundGlassButton(symbol: "xmark", label: "Close") { model.sheet = nil }
                .accessibilityIdentifier("sheetClose")
        }
        .padding(.bottom, 12)
    }
}

// MARK: How it works

struct HowSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "How it works", subtitle: "Careful, private, and always your call.")
            block("What happens") {
                step(1, "Everkeep makes a smaller copy of each item you approve, then checks it against the original.")
                step(2, "Only copies that pass are added to Photos, with the same date, place and albums.")
                step(3, "iOS then asks you once to move the originals to Recently Deleted, where they stay for 30 days.")
            }
            block("Private by design") {
                paragraph("Scanning and face checks run on this iPhone. Nothing is uploaded and there is no account. Face checks only tell whether a person is present, never who.")
            }
            block("Good to know") {
                paragraph("If iCloud Photos is on, the change reaches your other devices too. Once Recently Deleted is emptied, the original quality cannot be restored.")
            }
            Button {
                model.sheet = nil
            } label: {
                Text("Got it")
            }
            .buttonStyle(HoneyButtonStyle())
            .padding(.top, 14)
            .accessibilityIdentifier("howGotIt")
        }
    }

    private func block<Inner: View>(_ title: String, @ViewBuilder content: () -> Inner) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).ekEyebrow()
            content()
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(EK.ink900.opacity(0.12)).frame(height: 1) }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(EK.ink900)
                .frame(width: 22, height: 22)
                .background(Circle().fill(EK.honey400.opacity(0.55)))
            paragraph(text)
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(EK.ink800)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Look closer

/// A two-way switch in the same honey as the main action.
struct ChoiceBar: View {
    let options: [String]
    let identifiers: [String]
    let selection: Int
    let enabled: Bool
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                Button {
                    onSelect(index)
                } label: {
                    Text(options[index])
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selection == index ? EK.ink900 : EK.ink700)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background {
                            if selection == index {
                                Capsule()
                                    .fill(EK.honeyFill)
                                    .overlay { Capsule().strokeBorder(EK.honey600.opacity(0.5), lineWidth: 1) }
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == index ? .isSelected : [])
                .accessibilityIdentifier(identifiers[index])
            }
        }
        .padding(4)
        .background(Capsule().fill(EK.ink900.opacity(0.09)))
        .opacity(enabled ? 1 : 0.5)
        .disabled(!enabled)
    }
}

/// The original, and once a copy exists, the original beside the smaller copy. Drag the handle to compare.
struct StillCompare: View {
    let original: UIImage?
    let smaller: UIImage?
    let ratio: CGFloat
    let loading: Bool
    @Binding var split: CGFloat
    @Binding var zoomed: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                layers(geo.size)
                    .scaleEffect(zoomed ? 2.6 : 1, anchor: UnitPoint(x: 0.5, y: 0.4))
                    .animation(.easeOut(duration: 0.5), value: zoomed)
                if smaller != nil { handle(geo.size) }
                tags
                zoomButton
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    if smaller != nil { split = min(max(value.location.x / geo.size.width, 0), 1) }
                }
            )
        }
        .aspectRatio(ratio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: EK.shadow.opacity(0.3), radius: 14, x: 0, y: 10)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func layers(_ size: CGSize) -> some View {
        ZStack {
            if let original {
                Image(uiImage: original)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                EK.champagne300
                if loading { ProgressView().tint(EK.ink600) }
            }
            if let smaller {
                Image(uiImage: smaller)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .mask(alignment: .trailing) { Rectangle().frame(width: size.width * (1 - split)) }
            }
        }
    }

    private func handle(_ size: CGSize) -> some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.95)).frame(width: 2)
            Circle()
                .fill(EK.ivory50.opacity(0.94))
                .frame(width: 38, height: 38)
                .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 3)
                .overlay {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(EK.ink800)
                }
        }
        .frame(width: 38, height: size.height)
        .position(x: size.width * split, y: size.height / 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var tags: some View {
        VStack {
            Spacer()
            HStack {
                tag("Original")
                Spacer()
                if smaller != nil { tag("Smaller copy") }
            }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(EK.ink900)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(EK.ivory100.opacity(0.85)))
            .background(Capsule().fill(.ultraThinMaterial))
            .padding(10)
    }

    private var zoomButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    zoomed.toggle()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(EK.ink900)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(zoomed ? EK.honey400 : EK.ivory100.opacity(0.85)))
                        .background(Circle().fill(.ultraThinMaterial))
                        .padding(10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zoom in on the detail")
                .accessibilityAddTraits(zoomed ? .isSelected : [])
            }
            Spacer()
        }
    }
}

/// A video: play the original, and once a copy exists, switch to the smaller copy.
struct VideoCompare: View {
    @EnvironmentObject private var model: AppModel
    let item: LibraryItem
    let hasCopy: Bool

    @State private var showOriginal = true
    @State private var player: AVPlayer?
    @State private var poster: UIImage?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                EK.champagne300
                if let player {
                    VideoPlayer(player: player)
                } else if let poster {
                    Image(uiImage: poster).resizable().scaledToFill()
                } else if failed {
                    Text("Preview unavailable")
                        .font(.system(size: 13))
                        .foregroundStyle(EK.ink600)
                } else {
                    ProgressView().tint(EK.ink600)
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: EK.shadow.opacity(0.3), radius: 14, x: 0, y: 10)
            if hasCopy {
                ChoiceBar(
                    options: ["Original", "Smaller copy"],
                    identifiers: ["videoOriginal", "videoCopy"],
                    selection: showOriginal ? 0 : 1,
                    enabled: true
                ) { showOriginal = $0 == 0 }
            }
        }
        .task(id: showOriginal) { await load() }
        .onDisappear { player?.pause() }
    }

    @MainActor
    private func load() async {
        player?.pause()
        player = nil
        failed = false
        if poster == nil { poster = await model.thumbnail(item.id, side: 1200) }
        do {
            let asset: AVAsset
            if showOriginal || !hasCopy {
                asset = try await model.originalVideo(item.id)
            } else {
                asset = AVURLAsset(url: try await model.candidateURL(for: item))
            }
            if !Task.isCancelled { player = AVPlayer(playerItem: AVPlayerItem(asset: asset)) }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

struct LookCloserSheet: View {
    @EnvironmentObject private var model: AppModel
    let id: String

    @State private var original: UIImage?
    @State private var smaller: UIImage?
    @State private var split: CGFloat = 0.5
    @State private var zoomed = false
    @State private var loading = true

    var body: some View {
        if let entry = model.entry(id) {
            content(entry)
        } else {
            SheetHeader(title: "Not available", subtitle: "This item is no longer part of the review.")
        }
    }

    private func title(for asset: MediaAsset) -> String {
        asset.creationDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "This item"
    }

    private func subtitle(_ entry: ReviewEntry, checked: Bool) -> String {
        switch entry.state {
        case .failed: return "Kept as original"
        case .protected: return "Protected"
        case .skipped: return "Left out"
        case .on, .off:
            if checked, let transaction = entry.item.transaction, let bytes = transaction.candidateBytes {
                return "\(Amounts.text(max(0, transaction.originalBytes - bytes))) smaller, measured"
            }
            return "About \(Amounts.text(entry.saving)) smaller"
        }
    }

    private func content(_ entry: ReviewEntry) -> some View {
        let checked = model.isChecked(model.category)
        let hasCopy = checked && entry.state != .failed && entry.state != .skipped && entry.item.transaction?.state == .ready
        return VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: title(for: entry.item.asset), subtitle: subtitle(entry, checked: checked))
            media(entry, hasCopy: hasCopy)
            note(entry, checked: checked)
            ChoiceBar(
                options: ["Preserve", "Keep original"],
                identifiers: ["choosePreserve", "chooseKeep"],
                selection: entry.state == .on ? 0 : 1,
                enabled: entry.state == .on || entry.state == .off
            ) { model.setIncluded(entry.id, $0 == 0) }
            protectButton(entry)
            details(entry, checked: checked)
        }
        .task(id: "\(entry.id)-\(hasCopy)") { await load(entry, hasCopy: hasCopy) }
    }

    @ViewBuilder private func media(_ entry: ReviewEntry, hasCopy: Bool) -> some View {
        if entry.item.asset.kind == .video {
            VideoCompare(item: entry.item, hasCopy: hasCopy)
        } else {
            let size = original?.size ?? CGSize(width: 4, height: 3)
            StillCompare(
                original: original,
                smaller: smaller,
                ratio: min(max(size.width / max(size.height, 1), 0.6), 1.9),
                loading: loading,
                split: $split,
                zoomed: $zoomed
            )
        }
    }

    @ViewBuilder private func note(_ entry: ReviewEntry, checked: Bool) -> some View {
        switch entry.state {
        case .failed:
            plain("The smaller copy did not match the original closely enough, so the original stays exactly as it is.")
        case .skipped:
            plain("You left this one out before checking, so no smaller copy was made.")
        case .protected:
            plain("Protected. Everkeep will never change this one.")
        case .on, .off:
            if let look = entry.record?.look, !checked {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "eye").font(.system(size: 14, weight: .medium)).padding(.top, 2)
                    Text(look.explanation).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(EK.ink900)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(EK.honey300.opacity(0.5)))
            } else if checked {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 14, weight: .medium)).padding(.top, 2)
                    Text("Checked against the original.").font(.system(size: 14))
                }
                .foregroundStyle(EK.sage700)
            } else if entry.item.asset.kind != .video {
                plain("A real before and after appears once Everkeep has made the copy.")
            }
        }
    }

    private func plain(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(EK.ink700)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func protectButton(_ entry: ReviewEntry) -> some View {
        let isProtected = entry.state == .protected
        return Button {
            model.launch {
                if isProtected { await model.unprotectItem(entry.id) } else { await model.protectItem(entry.id) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "lock")
                Text(isProtected ? "Protected. Remove protection" : "Protect from future changes")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(EK.ink800)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("protectButton")
    }

    /// Technical information stays out of sight until it is asked for.
    private func details(_ entry: ReviewEntry, checked: Bool) -> some View {
        let asset = entry.item.asset
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                row("Kind", Format.kind(asset.kind) + (asset.kind == .video ? ", \(Format.clock(asset.duration))" : ""))
                row("Captured", Format.date(asset))
                row("Original", asset.sizeBytes > 0 ? Amounts.text(asset.sizeBytes) : "Not measured")
                row("Dimensions", "\(asset.pixelWidth) × \(asset.pixelHeight)")
                if let codec = asset.codec { row("Format", codec) }
                row(asset.kind == .video ? "Kept" : "Resolution", asset.kind == .video ? "Frame rate and sound" : "Unchanged")
            }
            .padding(.top, 8)
        } label: {
            Text("Details")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(EK.ink700)
        }
        .tint(EK.ink700)
        .accessibilityIdentifier("detailsDisclosure")
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(.system(size: 13)).foregroundStyle(EK.ink600)
            Spacer(minLength: 12)
            Text(value).font(.system(size: 13)).monospacedDigit().foregroundStyle(EK.ink800).multilineTextAlignment(.trailing)
        }
    }

    @MainActor
    private func load(_ entry: ReviewEntry, hasCopy: Bool) async {
        guard entry.item.asset.kind != .video else {
            loading = false
            return
        }
        loading = true
        original = await model.thumbnail(entry.id, side: 1600)
        if hasCopy {
            smaller = await model.candidateImage(for: entry.item, side: 1600)
        } else {
            smaller = nil
        }
        loading = false
    }
}
