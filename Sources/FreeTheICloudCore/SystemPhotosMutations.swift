import Foundation
import Photos
import UniformTypeIdentifiers

public struct SystemPhotosMutations: PhotoMutationBackend {
    public init() {}
    private func checkedAssets(_ items: [MediaItem]) throws -> [PHAsset] {
        guard [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else {
            throw MediaError.message("Photos permission is required. Connect Photos again.")
        }
        let ids = items.map { String($0.id.dropFirst("photos:system:".count)) }
        let options = PHFetchOptions(); options.includeHiddenAssets = true
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
        let byID = Dictionary(uniqueKeysWithValues: (0..<fetched.count).map { let asset = fetched.object(at: $0); return (asset.localIdentifier, asset) })
        return try items.map { item in
            try LibraryActions.requirePhotosItem(item)
            let id = String(item.id.dropFirst("photos:system:".count))
            guard let asset = byID[id], asset.modificationDate == item.modificationDate,
                  asset.isFavorite == item.favorite, !asset.isHidden,
                  asset.canPerform(.delete), !asset.sourceType.contains(.typeCloudShared) else {
                throw MediaError.message("An item changed, disappeared, or cannot be deleted. Rescan and review again.")
            }
            return asset
        }
    }
    public func delete(_ items: [MediaItem]) async throws {
        let assets = try checkedAssets(items)
        try Task.checkCancellation()
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets as NSArray) }
    }
    public func replace(_ item: MediaItem, with verifiedFile: URL) async throws -> String {
        guard let asset = try checkedAssets([item]).first else { throw MediaError.message("Original no longer exists.") }
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.contains(where: { $0.type == .adjustmentData }),
              !asset.mediaSubtypes.contains(.spatialMedia) else { throw MediaError.message("This item cannot be replaced.") }
        let resourceType: PHAssetResourceType
        let fileExtension: String
        if item.kind == .video, asset.mediaType == .video {
            guard !asset.mediaSubtypes.contains(.videoHighFrameRate), !asset.mediaSubtypes.contains(.videoCinematic) else {
                throw MediaError.message("This video cannot be replaced.")
            }
            resourceType = .video; fileExtension = "mov"
        } else if item.kind == .photo, asset.mediaType == .image {
            guard !asset.mediaSubtypes.contains(.photoLive), !item.raw, !item.edited,
                  resources.count == 1, resources.first?.type == .photo,
                  !resources.contains(where: { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true }) else {
                throw MediaError.message("Only an unedited still photo can be replaced. RAW and Live Photos are excluded.")
            }
            resourceType = .photo; fileExtension = "heic"
        } else { throw MediaError.message("The original media type changed. Refresh and review again.") }
        let fetched = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var albums: [PHAssetCollection] = []
        for index in 0..<fetched.count {
            let album = fetched.object(at: index)
            guard album.assetCollectionSubtype == .albumRegular, album.canPerform(.addContent) else {
                throw MediaError.message("This item belongs to an album that cannot be preserved during replacement.")
            }
            albums.append(album)
        }
        var newID = ""
        try Task.checkCancellation()
        try await PHPhotoLibrary.shared().performChanges {
            // One transaction: if import or album changes fail, Photos does not commit the deletion.
            let albumRequests = albums.compactMap { PHAssetCollectionChangeRequest(for: $0) }
            guard albumRequests.count == albums.count else { return }
            let creation = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions(); options.shouldMoveFile = false
            options.originalFilename = URL(fileURLWithPath: item.name).deletingPathExtension().lastPathComponent + "." + fileExtension
            creation.addResource(with: resourceType, fileURL: verifiedFile, options: options)
            creation.creationDate = asset.creationDate; creation.location = asset.location
            creation.isFavorite = asset.isFavorite
            if let placeholder = creation.placeholderForCreatedAsset {
                newID = placeholder.localIdentifier
                for request in albumRequests { request.addAssets([placeholder] as NSArray) }
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }
        }
        // A missing placeholder never submits deletion; retain the original if Photos cannot create one.
        guard !newID.isEmpty else { throw MediaError.message("Photos did not provide a replacement identifier. The original was not deleted; rescan before retrying.") }
        return "photos:system:" + newID
    }
}
