import AVFoundation
import EverKeepCore
import Photos
import UIKit
import UniformTypeIdentifiers

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
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )
        let result = PHAsset.fetchAssets(with: options)
        var assets: [MediaAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { phAsset, _, _ in
            assets.append(Self.snapshot(of: phAsset))
        }
        return assets
    }

    private static func snapshot(of asset: PHAsset) -> MediaAsset {
        let resources = PHAssetResource.assetResources(for: asset)
        let isVideo = asset.mediaType == .video
        let primary = resources.first(where: { $0.type == (isVideo ? .video : .photo) })
            ?? resources.first(where: { $0.type == (isVideo ? .fullSizeVideo : .fullSizePhoto) })
        // PhotoKit on the supported older OS versions has no public resource-size property.
        // Resolve size only after the user chooses a mode, rather than relying on private KVC.
        let size: Int64 = 0
        let special: PHAssetMediaSubtype = [.videoHighFrameRate, .videoTimelapse, .videoCinematic]
        let kind: MediaKind
        if isVideo {
            kind = .video
        } else if asset.mediaSubtypes.contains(.photoLive) {
            kind = .livePhoto
        } else {
            kind = asset.mediaSubtypes.contains(.photoScreenshot) ? .screenshot : .photo
        }
        let isRaw = resources.contains { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true }
        return MediaAsset(
            id: asset.localIdentifier,
            kind: kind,
            creationDate: asset.creationDate,
            duration: asset.duration,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            sizeBytes: size,
            isFavorite: asset.isFavorite,
            hasAdjustments: resources.contains(where: { $0.type == .adjustmentData }),
            isSpecialVideo: !asset.mediaSubtypes.isDisjoint(with: special),
            codec: kind.isImage ? primary?.uniformTypeIdentifier : nil,
            isHDR: !isVideo && asset.mediaSubtypes.contains(.photoHDR),
            modificationDate: asset.modificationDate,
            isSpecialPhoto: !isVideo && (isRaw || asset.mediaSubtypes.contains(.photoDepthEffect))
        )
    }

    func analyze(_ asset: MediaAsset) async throws -> MediaAsset {
        guard let current = Self.fetch(id: asset.id) else { throw AdapterError.assetMissing(asset.id) }
        var result = Self.snapshot(of: current)
        if result.kind.isImage {
            do {
                let data = try await openImageData(id: asset.id)
                let document = try ImageDocument(data: data)
                result.codec = document.typeIdentifier
                result.isHDR = result.isHDR || document.isHDR
                result.isSpecialPhoto = result.isSpecialPhoto == true || document.hasAuxiliaryData
                if result.sizeBytes == 0 { result.sizeBytes = Int64(data.count) }
                if !result.isHDR, result.isSpecialPhoto != true {
                    result.contentHints = try ImageAssessment.hints(
                        images: [document.rendered(maxSide: 1280)],
                        measureMotion: false, hasTransparency: document.hasTransparency
                    )
                }
                return result
            } catch AdapterError.notOnDevice(_) {
                result.isOnDevice = false
                return result
            }
        }
        guard result.kind == .video else { return result }
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
        guard let url = (avAsset as? AVURLAsset)?.url,
              let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > 0 else {
            throw AdapterError.readerFailed("the original video's file size could not be verified")
        }
        result.sizeBytes = Int64(bytes)
        if !result.isHDR, !result.isSpecialVideo, facts.duration.isFinite, facts.duration > 0 {
            let generator = AVAssetImageGenerator(asset: avAsset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 512, height: 512)
            var frames: [CGImage] = []
            for index in 0..<3 {
                try Task.checkCancellation()
                let time = CMTime(seconds: facts.duration * (Double(index) + 0.5) / 3, preferredTimescale: 600)
                frames.append(try await generator.image(at: time).image)
            }
            result.contentHints = try ImageAssessment.hints(images: frames, measureMotion: true)
        }
        return result
    }

    func openImageData(id: String) async throws -> Data {
        guard let asset = Self.fetch(id: id) else { throw AdapterError.assetMissing(id) }
        let options = PHImageRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: CancellationError())
                } else if let data {
                    continuation.resume(returning: data)
                } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                    continuation.resume(throwing: AdapterError.notOnDevice(id))
                } else {
                    continuation.resume(throwing: AdapterError.imageFailed("Photos returned no original image data"))
                }
            }
        }
    }

    func preview(
        id: String,
        size: CGSize = CGSize(width: 320, height: 320),
        contentMode: PHImageContentMode = .aspectFit
    ) async throws -> UIImage {
        guard let asset = Self.fetch(id: id) else { throw AdapterError.assetMissing(id) }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset, targetSize: size, contentMode: contentMode, options: options
            ) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: CancellationError())
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: AdapterError.imageFailed("Photos returned no full-quality preview"))
                }
            }
        }
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

    func assetExists(id: String) async throws -> Bool {
        if Self.fetch(id: id) != nil { return true }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw AdapterError.readerFailed("full Photos access is needed to confirm that an interrupted original was deleted")
        }
        return false
    }

    func currentAsset(id: String) async throws -> MediaAsset? {
        Self.fetch(id: id).map { Self.snapshot(of: $0) }
    }

    /// Bytes the item's resources occupy on this device, counted as they stream past and never kept.
    /// Used for items the analysis does not size, such as Live Photos. Zero when unknown or only in iCloud.
    func footprint(id: String) async -> Int64 {
        guard let asset = Self.fetch(id: id) else { return 0 }
        var total: Int64 = 0
        for resource in PHAssetResource.assetResources(for: asset) {
            if Task.isCancelled { break }
            total += await Self.countBytes(of: resource)
        }
        return total
    }

    private final class ByteCounter: @unchecked Sendable {
        var total: Int64 = 0
    }

    private static func countBytes(of resource: PHAssetResource) async -> Int64 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int64, Never>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false
            let counter = ByteCounter()
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { chunk in counter.total += Int64(chunk.count) },
                completionHandler: { error in continuation.resume(returning: error == nil ? counter.total : 0) }
            )
        }
    }

    #if DEBUG
    func importDemoMedia(_ urls: [URL]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            for url in urls {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = url.lastPathComponent
                let type: PHAssetResourceType = url.pathExtension.lowercased() == "jpg" ? .photo : .video
                request.addResource(with: type, fileURL: url, options: options)
            }
        }
    }
    #endif

    // MARK: Verification and deletion

    func verifyReplacement(
        original: MediaAsset,
        replacementId: String,
        settings: EncodingSettings
    ) async throws -> ReplacementCheck {
        guard let replacement = Self.fetch(id: replacementId) else {
            return ReplacementCheck(exists: false, durationDelta: .infinity, dimensionsMatch: false, creationDateMatches: false)
        }
        var previewsMatch = true
        for mode in [PHImageContentMode.aspectFit, .aspectFill] {
            let before = try await preview(id: original.id, contentMode: mode)
            let after = try await preview(id: replacementId, contentMode: mode)
            let similarity = try ImageAssessment.score(
                ImageAssessment.uprightImage(before), ImageAssessment.uprightImage(after), maxSide: 320
            )
            previewsMatch = previewsMatch && similarity >= QualityPolicy.previewMeanSSIM
        }
        return ReplacementCheck(
            exists: true,
            durationDelta: abs(replacement.duration - original.duration),
            dimensionsMatch: replacement.pixelWidth == settings.width && replacement.pixelHeight == settings.height,
            creationDateMatches: replacement.creationDate == original.creationDate,
            previewMatches: previewsMatch
        )
    }

    func deleteOriginals(ids: [String]) async throws -> Set<String> {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
        guard assets.count == Set(ids).count else {
            throw AdapterError.readerFailed("some originals are no longer accessible; no deletion was requested")
        }
        guard !assets.isEmpty else { return [] }
        let toDelete = assets

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSArray)
            }
        } catch {
            let nsError = error as NSError
            let declined = (nsError.domain == NSCocoaErrorDomain || nsError.domain == "PHPhotosErrorDomain") && nsError.code == 3072
            if !declined { throw error }
            return []
        }

        let remaining = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var stillThere: Set<String> = []
        remaining.enumerateObjects { asset, _, _ in stillThere.insert(asset.localIdentifier) }
        return Set(ids).subtracting(stillThere)
    }
}
