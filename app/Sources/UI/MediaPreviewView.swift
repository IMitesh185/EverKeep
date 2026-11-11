import AVKit
import EverKeepCore
import SwiftUI
import UIKit

struct NativeThumbnailView: View {
    @EnvironmentObject private var model: AppModel
    let assetId: String
    @State private var image: UIImage?
    @State private var error: String?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if let error {
                Image(systemName: "photo.badge.exclamationmark")
                    .accessibilityLabel("Preview unavailable: \(error)")
            } else {
                ProgressView()
            }
        }
        .frame(width: 64, height: 64)
        .task(id: assetId) {
            image = nil
            error = nil
            do {
                let preview = try await model.preview(assetId, size: CGSize(width: 256, height: 256))
                if !Task.isCancelled { image = preview }
            } catch {
                if !Task.isCancelled { self.error = String(describing: error) }
            }
        }
    }
}

struct CandidateReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: LibraryItem
    @State private var showOriginal = false
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1

    var body: some View {
        NavigationStack {
            VStack {
                Picker("Version", selection: $showOriginal) {
                    Text("Candidate").tag(false)
                    Text("Original").tag(true)
                }
                .pickerStyle(.segmented)
                .padding()
                if let error {
                    Text("Preview unavailable: \(error)").padding()
                } else if let player {
                    VideoPlayer(player: player)
                } else if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: UIScreen.main.bounds.width * max(1, min(6, zoom * pinch)))
                    }
                    .gesture(MagnificationGesture()
                        .onChanged { pinch = $0 }
                        .onEnded {
                            zoom = max(1, min(6, zoom * $0))
                            pinch = 1
                        })
                } else {
                    ProgressView("Loading preview...")
                }
                Text(item.asset.kind.isImage
                     ? "Pinch to inspect. This is a review preview, not a separate saved gallery."
                     : "Compare motion and sound before approving.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
            }
            .navigationTitle("Review candidate")
            .toolbar { Button("Done") { dismiss() } }
            .task(id: showOriginal) { await load() }
            .onDisappear { player?.pause() }
        }
    }

    @MainActor
    private func load() async {
        player?.pause()
        player = nil
        image = nil
        error = nil
        do {
            if item.asset.kind == .video {
                let asset: AVAsset
                if showOriginal {
                    asset = try await model.originalVideo(item.id)
                } else {
                    asset = AVURLAsset(url: try await model.candidateURL(for: item))
                }
                if !Task.isCancelled { player = AVPlayer(playerItem: AVPlayerItem(asset: asset)) }
            } else if showOriginal {
                let preview = try await model.preview(item.id, size: CGSize(width: 4096, height: 4096))
                if !Task.isCancelled { image = preview }
            } else {
                let url = try await model.candidateURL(for: item)
                let preview = try await Task.detached(priority: .userInitiated) {
                    let document = try ImageDocument(data: Data(contentsOf: url))
                    return UIImage(cgImage: try document.rendered(maxSide: 4096))
                }.value
                if !Task.isCancelled { image = preview }
            }
        } catch {
            if !Task.isCancelled { self.error = String(describing: error) }
        }
    }
}
