import EverKeepCore
import Photos

/// Carries the new asset's identifier out of a change block.
final class IdentifierBox: @unchecked Sendable {
    var value: String?
}

/// Writes the replacement back into Photos with the original's date, location, favorite flag,
/// file name and album memberships (ADR-0002). A vault destination would be a second implementation.
final class PhotosDestination: DestinationPort, @unchecked Sendable {
    func place(candidate: URL, replacing original: MediaAsset) async throws -> String {
        guard let source = PhotoLibraryAdapter.fetch(id: original.id) else {
            throw AdapterError.assetMissing(original.id)
        }
        let resourceType: PHAssetResourceType = original.kind.isImage ? .photo : .video
        let originalName = PHAssetResource.assetResources(for: source).first(where: { $0.type == resourceType })?.originalFilename
        let albums = PHAssetCollection.fetchAssetCollectionsContaining(source, with: .album, options: nil)

        let created = IdentifierBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            if let originalName {
                let base = URL(fileURLWithPath: originalName).deletingPathExtension().lastPathComponent
                options.originalFilename = "\(base).\(candidate.pathExtension)"
            }
            request.addResource(with: resourceType, fileURL: candidate, options: options)
            request.creationDate = source.creationDate
            request.location = source.location
            request.isFavorite = source.isFavorite

            guard let placeholder = request.placeholderForCreatedAsset else { return }
            created.value = placeholder.localIdentifier
            albums.enumerateObjects { collection, _, _ in
                guard collection.canPerform(.addContent),
                      let change = PHAssetCollectionChangeRequest(for: collection) else { return }
                change.addAssets([placeholder] as NSArray)
            }
        }

        guard let identifier = created.value else { throw AdapterError.placementFailed("Photos returned no identifier") }
        return identifier
    }

    /// After an interruption: a video with the original's creation date and a similar duration that is not the original.
    func findReplacement(for original: MediaAsset, settings: EncodingSettings) async throws -> String? {
        guard let date = original.creationDate else { return nil }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            date.addingTimeInterval(-0.5) as NSDate,
            date.addingTimeInterval(0.5) as NSDate
        )
        var matches: [String] = []
        let type: PHAssetMediaType = original.kind.isImage ? .image : .video
        PHAsset.fetchAssets(with: type, options: options).enumerateObjects { asset, _, _ in
            if asset.localIdentifier != original.id, abs(asset.duration - original.duration) < 0.1,
               asset.pixelWidth == settings.width, asset.pixelHeight == settings.height {
                matches.append(asset.localIdentifier)
            }
        }
        return matches.count == 1 ? matches.first : nil
    }
}
