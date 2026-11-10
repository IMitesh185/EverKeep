import Photos

/// E1: read-only census of what the Photos framework exposes. Writes nothing to the library.
enum Census {
    static func report() -> String {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let total = PHAsset.fetchAssets(with: nil).count
        var lines = ["E1: access=\(describe(status)) (\(status.rawValue)) assets=\(total)"]
        let kinds: [(String, PHAssetMediaType)] = [("image", .image), ("video", .video)]
        for (name, type) in kinds {
            lines.append("E1: \(name)=\(PHAsset.fetchAssets(with: type, options: nil).count)")
        }
        let albums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
        albums.enumerateObjects { album, _, _ in
            let count = PHAsset.fetchAssets(in: album, options: nil).count
            lines.append("E1: smart [\(album.assetCollectionSubtype.rawValue)] \(album.localizedTitle ?? "?") = \(count)")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "unknown"
        }
    }
}
