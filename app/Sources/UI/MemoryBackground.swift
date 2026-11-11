import SwiftUI
import UIKit

/// One remembered photograph. A fresh identity lets SwiftUI dissolve from the last one to the next.
struct MemoryFrame: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Chooses which of the person's own photographs to remember next, like a slow replay.
@MainActor
final class MemoryDirector: ObservableObject {
    @Published private(set) var current: MemoryFrame?

    private var ids: [String] = []
    private var index = 0
    private var cycle: Task<Void, Never>?
    private var loader: ((String) async -> UIImage?)?

    func show(ids: [String], fallback: UIImage?, loader: @escaping (String) async -> UIImage?) {
        cycle?.cancel()
        self.ids = ids
        self.loader = loader
        index = 0
        cycle = Task { [weak self] in
            await self?.advance(fallback: fallback)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 9_000_000_000)
                if Task.isCancelled { break }
                await self?.advance(fallback: nil)
            }
        }
    }

    func stop() {
        cycle?.cancel()
    }

    /// Starts remembering with the photographs of the current category.
    func restart(using model: AppModel) {
        show(
            ids: model.memoryIds(for: model.category),
            fallback: WelcomeMemory.image,
            loader: { id in await model.thumbnail(id, side: 1200) }
        )
    }

    private func advance(fallback: UIImage?) async {
        guard let loader else { return }
        var image: UIImage?
        if !ids.isEmpty {
            // Skip photographs that cannot be opened, for example ones that live only in iCloud.
            for _ in 0..<ids.count {
                let id = ids[index % ids.count]
                index += 1
                if let loaded = await loader(id) {
                    image = loaded
                    break
                }
            }
        }
        if image == nil { image = fallback }
        guard let image, !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 1.6)) {
            current = MemoryFrame(image: image)
        }
    }
}

/// The atmosphere: a softly faded, warm photograph of an everyday memory, slowly drifting.
/// It is never an abstract gradient. With no photographs yet it falls back to flat champagne and grain.
struct MemoryBackground: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var physics: DialPhysics
    let veil: Double

    @StateObject private var director = MemoryDirector()

    private struct Key: Hashable {
        let category: LibraryCategory
        let itemCount: Int
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                EK.champagne300
                if let frame = director.current {
                    // Wider than the screen, so the parallax shift never shows an edge.
                    MemoryLayer(image: frame.image, size: CGSize(width: geo.size.width + 128, height: geo.size.height))
                        .id(frame.id)
                        .offset(x: CGFloat(-physics.position * 14))
                        .transition(.opacity)
                }
                MemoryGrade(size: geo.size)
                EK.ivory100.opacity(veil)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .compositingGroup()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: Key(category: model.category, itemCount: model.items.count)) {
            await restartMemories()
        }
        .onDisappear { director.stop() }
    }

    @MainActor
    private func restartMemories() async {
        director.restart(using: model)
    }
}

/// A public-domain photograph that ships with the app, so the first screens already feel like a memory.
enum WelcomeMemory {
    static let image: UIImage? = {
        guard let path = Bundle.main.path(forResource: "welcome-memory", ofType: "jpg") else { return nil }
        return UIImage(contentsOfFile: path)
    }()
}

private struct MemoryLayer: View {
    let image: UIImage
    let size: CGSize

    @State private var drifting = false

    private var photoHeight: CGFloat {
        let ratio = image.size.height / max(image.size.width, 1)
        return size.width * ratio
    }

    var body: some View {
        ZStack(alignment: .top) {
            // The same photograph, blurred and muted, fills the whole screen.
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .scaleEffect(1.15)
                .blur(radius: 26)
                .saturation(0.62)
                .colorMultiply(Color(hex: 0xFFF1DA))
            // The photograph itself, at its own proportions across the top, fading into the blur below it.
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: photoHeight)
                .saturation(0.74)
                .contrast(0.94)
                .colorMultiply(Color(hex: 0xFFF1DA))
                .blur(radius: 0.8)
                .mask { fade }
                .scaleEffect(drifting ? 1.14 : 1.03, anchor: .top)
                .offset(x: drifting ? -8 : 4, y: min(0, size.height * 0.2 - photoHeight / 2))
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
        .onAppear {
            withAnimation(.easeInOut(duration: 32).repeatForever(autoreverses: true)) {
                drifting = true
            }
        }
    }

    private var fade: some View {
        LinearGradient(
            stops: [
                Gradient.Stop(color: .black, location: 0),
                Gradient.Stop(color: .black, location: 0.56),
                Gradient.Stop(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Warm wash, honey tone, a soft top so the status bar stays readable, a vignette, and grain.
private struct MemoryGrade: View {
    let size: CGSize

    var body: some View {
        ZStack {
            Color(hex: 0xF4E7CC).opacity(0.2)
            Color(hex: 0xE9B866).opacity(0.45).blendMode(.softLight)
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color(hex: 0xFAF0DA).opacity(0.78), Color(hex: 0xFAF0DA).opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 150)
                Spacer(minLength: 0)
            }
            RadialGradient(
                colors: [Color.clear, Color(hex: 0x3E260A).opacity(0.34)],
                center: .center,
                startRadius: size.width * 0.5,
                endRadius: max(size.width, size.height) * 0.78
            )
            GrainOverlay()
        }
        .frame(width: size.width, height: size.height)
    }
}
