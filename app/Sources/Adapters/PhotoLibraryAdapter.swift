import AVFoundation
import EverKeepCore
import Photos

/// PhotoKit adapter. It reads in place (no copies), never edits an original, and deletes only on request.
final class PhotoLibraryAdapter: LibraryPort, @unchecked Sendable {
    // MARK: Authorization

    func authorizationState() async -> LibraryAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> LibraryAuthorization {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    private static func map(_ status: PHAuthorizationStatus) -> LibraryAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default: return .denied
        }
    }

    // MARK: Discovery

    func enumerateAssets() async throws -> [MediaAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .video, options: options)
        var assets: [MediaAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { phAsset, _, _ in
            assets.append(Self.snapshot(of: phAsset))
        }
        return assets
    }

    private static func snapshot(of asset: PHAsset) -> MediaAsset {
        let resources = PHAssetResource.assetResources(for: asset)
        let primary = resources.first(where: { $0.type == .video }) ?? resources.first(where: { $0.type == .fullSizeVideo })
        // "fileSize" is not a documented property; 0 means unknown and is handled downstream.
        let size = (primary?.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
        let special: PHAssetMediaSubtype = [.videoHighFrameRate, .videoTimelapse, .videoCinematic]
        return MediaAsset(
            id: asset.localIdentifier,
            kind: .video,
            creationDate: asset.creationDate,
            duration: asset.duration,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            sizeBytes: size,
            isFavorite: asset.isFavorite,
            hasAdjustments: resources.contains(where: { $0.type == .adjustmentData }),
            isSpecialVideo: !asset.mediaSubtypes.isDisjoint(with: special)
        )
    }

    func analyze(_ asset: MediaAsset) async throws -> MediaAsset {
        var result = asset
        let avAsset: AVAsset
        do {
            avAsset = try await openAVAsset(id: asset.id)
        } catch AdapterError.notOnDevice(_) {
            result.isOnDevice = false
            return result
        }

        let facts = try await VideoFacts.read(from: avAsset)
        result.codec = facts.codec
        result.bitrate = facts.bitrate > 0 ? facts.bitrate : nil
        result.frameRate = facts.frameRate > 0 ? facts.frameRate : nil
        result.isHDR = facts.isHDR
        result.isSpecialVideo = result.isSpecialVideo || facts.isSpatial
        result.audioTrackCount = facts.audioTrackCount
        if result.sizeBytes == 0,
           let url = (avAsset as? AVURLAsset)?.url,
           let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            result.sizeBytes = Int64(bytes)
        }
        return result
    }

    /// Opens the original in place. Network access is off: a cloud-only original is reported, not downloaded.
    func openAVAsset(id: String) async throws -> AVAsset {
        guard let asset = Self.fetch(id: id) else { throw AdapterError.assetMissing(id) }
        let options = PHVideoRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                if let avAsset {
                    continuation.resume(returning: avAsset)
                } else {
                    continuation.resume(throwing: AdapterError.notOnDevice(id))
                }
            }
        }
    }

    static func fetch(id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    func assetExists(id: String) async -> Bool {
        Self.fetch(id: id) != nil
    }

    // MARK: Verification and deletion

    func verifyReplacement(original: MediaAsset, replacementId: String) async throws -> ReplacementCheck {
        guard let replacement = Self.fetch(id: replacementId) else {
            return ReplacementCheck(exists: false, durationDelta: .infinity, dimensionsMatch: false, creationDateMatches: false)
        }
        return ReplacementCheck(
            exists: true,
            durationDelta: abs(replacement.duration - original.duration),
            dimensionsMatch: replacement.pixelWidth == original.pixelWidth && replacement.pixelHeight == original.pixelHeight,
            creationDateMatches: replacement.creationDate == original.creationDate
        )
    }

    func deleteOriginals(ids: [String]) async throws -> Set<String> {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
        guard !assets.isEmpty else { return Set(ids) }
        let toDelete = assets

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSArray)
            }
        } catch {
            let nsError = error as NSError
            let declined = (nsError.domain == NSCocoaErrorDomain || nsError.domain == "PHPhotosErrorDomain") && nsError.code == 3072
            if !declined { throw error }
        }

        let remaining = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var stillThere: Set<String> = []
        remaining.enumerateObjects { asset, _, _ in stillThere.insert(asset.localIdentifier) }
        return Set(ids).subtracting(stillThere)
    }
}
