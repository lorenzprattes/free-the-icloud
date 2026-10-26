import Foundation
import AppKit
import AVFoundation
import CryptoKit
import ImageIO
import Photos
import UniformTypeIdentifiers

public typealias ScanProgress = @Sendable (Int, String) -> Void
public typealias ScannedItem = @Sendable (MediaItem) async -> Void

public protocol MediaSource {
    var id: String { get }
    func scan(store: CatalogStore, cache: URL, onItem: @escaping ScannedItem, progress: @escaping ScanProgress) async throws -> [MediaItem]
}

public struct FolderSource: MediaSource {
    public let root: URL
    public let id: String
    public init(root: URL) {
        self.root = root.standardizedFileURL
        self.id = "folder:" + root.standardizedFileURL.path
    }
    public func scan(store: CatalogStore, cache: URL, onItem: @escaping ScannedItem = { _ in }, progress: @escaping ScanProgress) async throws -> [MediaItem] {
        guard !root.resolvingSymlinksInPath().pathComponents.contains(where: { $0.lowercased().hasSuffix(".photoslibrary") }),
              (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw MediaError.message("Choose an ordinary folder. Photos libraries and symbolic links are excluded.")
        }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey,
            .contentModificationDateKey, .creationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        var traversalError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in traversalError = error; return true }) else {
            throw MediaError.message("Cannot read the selected folder.")
        }
        let old = Dictionary(uniqueKeysWithValues: try await store.items(source: id).map { ($0.id, $0) })
        var items: [MediaItem] = []
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true || url.pathExtension.lowercased() == "photoslibrary" { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, let type = UTType(filenameExtension: url.pathExtension) else { continue }
            guard type.conforms(to: .image) || type.conforms(to: .movie) else { continue }
            let itemID = id + ":" + String(url.path.dropFirst(root.path.count))
            let kind: MediaKind = type.conforms(to: .movie) ? .video : .photo
            var item = MediaItem(id: itemID, sourceID: id, name: url.lastPathComponent, kind: kind, fileURL: url,
                bytes: values.fileSize.map(Int64.init), date: values.creationDate)
            item.modificationDate = values.contentModificationDate
            if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current && values.ubiquitousItemDownloadingStatus != .downloaded {
                item.available = false; item.bytes = nil; item.issue = "Cloud placeholder; not downloaded."
            } else if let previous = old[itemID], previous.modificationDate == item.modificationDate,
                      previous.bytes == item.bytes, previous.analysisVersion == ImageAnalyzer.version,
                      previous.fingerprint != nil, previous.thumbnailURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                item = previous
            } else {
                do {
                    let hash = try ImageAnalyzer.hashFile(url)
                    item.fingerprint = ImageAnalyzer.digest("\(kind == .photo ? 1 : 2):\(hash)")
                    let thumb = cache.appendingPathComponent(ImageAnalyzer.digest(itemID + hash) + ".jpg")
                    if kind == .photo {
                        let image = try ImageAnalyzer.thumbnail(url)
                        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                            item.width = properties[kCGImagePropertyPixelWidth] as? Int ?? image.width
                            item.height = properties[kCGImagePropertyPixelHeight] as? Int ?? image.height
                            if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
                                let width = item.width; item.width = item.height; item.height = width
                            }
                            if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
                               let timestamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                                item.date = formatter.date(from: timestamp) ?? item.date
                            }
                        }
                        item.raw = type.conforms(to: .rawImage)
                        let analysis = try ImageAnalyzer.analyze(image)
                        item.perceptualHash = analysis.0; item.featurePrint = analysis.1
                        if analysis.1 == nil { item.issue = "Vision unavailable; perceptual-hash matching is still available." }
                        try ImageAnalyzer.writeJPEG(image, to: thumb)
                        item.thumbnailURL = thumb
                    } else {
                        let asset = AVURLAsset(url: url)
                        item.duration = try await asset.load(.duration).seconds
                        if let track = try await asset.loadTracks(withMediaType: .video).first {
                            let natural = try await track.load(.naturalSize)
                            let transform = try await track.load(.preferredTransform)
                            let size = natural.applying(transform)
                            item.width = Int(abs(size.width)); item.height = Int(abs(size.height))
                        }
                        let generator = AVAssetImageGenerator(asset: asset)
                        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 1200, height: 1200)
                        let (image, _) = try await generator.image(at: .zero)
                        try ImageAnalyzer.writeJPEG(image, to: thumb); item.thumbnailURL = thumb
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { item.issue = error.localizedDescription }
            }
            var freshURL = url; freshURL.removeAllCachedResourceValues()
            let after = try freshURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if after.contentModificationDate != item.modificationDate || (item.available && after.fileSize.map(Int64.init) != item.bytes) {
                item.fingerprint = nil; item.perceptualHash = nil; item.featurePrint = nil
                item.issue = "This file changed while it was being scanned. Rescan before reviewing."
            }
            try await store.save(item); items.append(item); await onItem(item)
            progress(items.count, item.name)
        }
        if let traversalError { throw MediaError.message("The folder scan was incomplete: \(traversalError.localizedDescription). Indexed items were retained for retry.") }
        try await store.prune(source: id, retaining: Set(items.map(\.id)))
        return items
    }
}

private final class ResourceRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelled = false
    func install(_ id: PHAssetResourceDataRequestID) {
        lock.lock(); requestID = id; let cancel = cancelled; lock.unlock()
        if cancel { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
    func cancel() {
        lock.lock(); cancelled = true; let id = requestID; lock.unlock()
        if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
}

public struct PhotosSource: MediaSource {
    public let id = "photos:system"
    public init() {}
    /// Called only when inspecting an item from an explicitly connected Photos source.
    public static func previewJPEG(for item: MediaItem) throws -> Data {
        guard item.sourceID == "photos:system", item.id.hasPrefix("photos:system:") else { throw MediaError.message("Not a Photos item.") }
        guard [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else {
            throw MediaError.message("Photos access is not granted. Reconnect Photos to review this item.")
        }
        let identifier = String(item.id.dropFirst("photos:system:".count))
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { throw MediaError.message("This item is no longer available.") }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false; options.isSynchronous = true
        options.deliveryMode = .highQualityFormat; options.resizeMode = .exact
        var lastError: Error?
        var requiresDownload = false
        // A large rendition may be absent even when Photos has a smaller local preview.
        for size in [4096, 1200, 640] {
            try Task.checkCancellation()
            var result: Data?
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: size, height: size), contentMode: .aspectFit, options: options) { image, info in
                if let error = info?[PHImageErrorKey] as? Error { lastError = error }
                requiresDownload = requiresDownload || (info?[PHImageResultIsInCloudKey] as? Bool == true)
                if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    do { result = try ImageAnalyzer.jpegData(cg) } catch { lastError = error }
                }
            }
            if let result { return result }
        }
        if let lastError { throw lastError }
        throw MediaError.message(requiresDownload ? "Photos needs an iCloud download for this preview. Downloads are off." : "Photos did not provide a local preview.")
    }
    public static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }
    public func scan(store: CatalogStore, cache: URL, onItem: @escaping ScannedItem = { _ in }, progress: @escaping ScanProgress) async throws -> [MediaItem] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw MediaError.message("Photos access has not been granted.") }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let old = Dictionary(uniqueKeysWithValues: try await store.items(source: id).map { ($0.id, $0) })
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        let fetched = PHAsset.fetchAssets(with: options)
        var items: [MediaItem] = []
        for index in 0..<fetched.count {
            try Task.checkCancellation()
            let asset = fetched.object(at: index)
            guard asset.mediaType == .image || asset.mediaType == .video else { continue }
            let allResources = PHAssetResource.assetResources(for: asset)
            let resources = allResources.filter { [.photo, .video, .pairedVideo, .alternatePhoto].contains($0.type) }
            var item = MediaItem(id: id + ":" + asset.localIdentifier, sourceID: id,
                name: resources.first?.originalFilename ?? "Untitled", kind: asset.mediaType == .video ? .video : .photo,
                width: asset.pixelWidth, height: asset.pixelHeight, date: asset.creationDate,
                duration: asset.mediaType == .video ? asset.duration : nil)
            item.favorite = asset.isFavorite; item.modificationDate = asset.modificationDate
            item.livePhoto = asset.mediaSubtypes.contains(.photoLive)
            item.screenshot = asset.mediaSubtypes.contains(.photoScreenshot)
            item.edited = allResources.contains { $0.type == .adjustmentData }
            item.raw = resources.contains { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true }
            if let previous = old[item.id], previous.modificationDate == item.modificationDate,
               previous.fingerprint != nil, previous.analysisVersion == ImageAnalyzer.version,
               previous.thumbnailURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                item.bytes = previous.bytes; item.fingerprint = previous.fingerprint
                item.perceptualHash = previous.perceptualHash; item.featurePrint = previous.featurePrint
                item.thumbnailURL = previous.thumbnailURL
            } else {
                do {
                    guard !resources.isEmpty else { throw MediaError.message("No original resources available.") }
                    var signatures: [String] = []; var total: Int64 = 0
                    for resource in resources {
                        let (bytes, hash) = try await Self.measure(resource)
                        total += bytes; signatures.append("\(resource.type.rawValue):\(hash)")
                    }
                    item.bytes = total
                    item.fingerprint = ImageAnalyzer.digest(signatures.sorted().joined(separator: "|"))
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try Task.checkCancellation(); item.available = false
                    let failure = error as NSError
                    item.issue = "Original could not be read during scan (downloads off): \(failure.localizedDescription) [\(failure.domain) \(failure.code)]"
                }
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = false; options.isSynchronous = true
                options.deliveryMode = .highQualityFormat; options.resizeMode = .fast
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1200, height: 1200),
                    contentMode: .aspectFit, options: options) { image, _ in
                    guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                    let thumb = cache.appendingPathComponent(ImageAnalyzer.digest(item.id + (item.modificationDate?.description ?? "") + (item.fingerprint ?? "")) + ".jpg")
                    do {
                        try ImageAnalyzer.writeJPEG(cg, to: thumb); item.thumbnailURL = thumb
                        if item.kind == .photo {
                            let analysis = try ImageAnalyzer.analyze(cg)
                            item.perceptualHash = analysis.0; item.featurePrint = analysis.1
                        }
                    } catch { item.issue = [item.issue, error.localizedDescription].compactMap { $0 }.joined(separator: " · ") }
                }
            }
            try await store.save(item); items.append(item); await onItem(item); progress(items.count, item.name)
        }
        try await store.prune(source: id, retaining: Set(items.map(\.id)))
        return items
    }
    private static func measure(_ resource: PHAssetResource, output: URL? = nil,
                                onBytes: @escaping @Sendable (Int64) -> Void = { _ in }) async throws -> (Int64, String) {
        let token = ResourceRequest()
        var file: FileHandle?
        if let output {
            guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw MediaError.message("Cannot create the staged original.") }
            file = try FileHandle(forWritingTo: output)
        }
        defer { try? file?.close() }
        let result: (Int64, String) = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = false
                // PhotoKit serializes these handlers for a request.
                var bytes: Int64 = 0; var hasher = SHA256(); var writeError: Error?
                var lastProgress = Date.distantPast
                let request = PHAssetResourceManager.default().requestData(for: resource, options: options,
                    dataReceivedHandler: { data in
                        bytes += Int64(data.count); hasher.update(data: data)
                        if writeError == nil { do { try file?.write(contentsOf: data) } catch { writeError = error; token.cancel() } }
                        if Date().timeIntervalSince(lastProgress) >= 0.15 { onBytes(bytes); lastProgress = Date() }
                    },
                    completionHandler: { error in
                        if let error = writeError ?? error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: (bytes, hasher.finalize().map { String(format: "%02x", $0) }.joined())) }
                    })
                token.install(request)
            }
        }, onCancel: { token.cancel() })
        try Task.checkCancellation()
        return result
    }
    public static func addToReviewAlbum(items: [MediaItem], policy: OperationPolicy) async throws -> String {
        try policy.requireExecution()
        guard !items.isEmpty, items.allSatisfy({ $0.sourceID == "photos:system" }) else {
            throw MediaError.message("Select Photos items to add to a review album.")
        }
        let ids = items.map { String($0.id.dropFirst("photos:system:".count)) }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard fetched.count == ids.count else { throw MediaError.message("Some selected items are no longer available. Rescan first.") }
        let byID = Dictionary(uniqueKeysWithValues: (0..<fetched.count).map { let asset = fetched.object(at: $0); return (asset.localIdentifier, asset) })
        for item in items {
            let identifier = String(item.id.dropFirst("photos:system:".count))
            guard let asset = byID[identifier],
                  asset.modificationDate == item.modificationDate else {
                throw MediaError.message("A selected item changed since the scan. Rescan before creating the album.")
            }
        }
        let name = "Free the iCloud · Review " + Date().formatted(date: .abbreviated, time: .shortened)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            request.addAssets(fetched)
        }
        return name
    }
    public static func originalPhoto(for item: MediaItem, into folder: URL, policy: OperationPolicy) async throws -> URL {
        try policy.requireExecution()
        guard item.sourceID == "photos:system", item.id.hasPrefix("photos:system:"), item.kind == .photo,
              !item.livePhoto, !item.raw, !item.edited,
              [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else {
            throw MediaError.message("Photos access and an unedited still photo are required.")
        }
        let identifier = String(item.id.dropFirst("photos:system:".count))
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              asset.modificationDate == item.modificationDate, !asset.mediaSubtypes.contains(.photoLive) else {
            throw MediaError.message("The photo changed or is no longer accessible. Refresh first.")
        }
        let all = PHAssetResource.assetResources(for: asset)
        let originals = all.filter { [.photo, .video, .pairedVideo, .alternatePhoto].contains($0.type) }
        guard originals.count == 1, let resource = originals.first, resource.type == .photo,
              !all.contains(where: { $0.type == .adjustmentData }) else { throw MediaError.message("Only single, unedited still-photo resources can be resized.") }
        let output = folder.appendingPathComponent("original").appendingPathExtension(URL(fileURLWithPath: resource.originalFilename).pathExtension)
        let (bytes, hash) = try await measure(resource, output: output)
        guard bytes == item.bytes, ImageAnalyzer.digest("\(resource.type.rawValue):\(hash)") == item.fingerprint else {
            throw MediaError.message("The photo content changed. Refresh before resizing.")
        }
        return output
    }
    public static func originalVideo(for item: MediaItem, into folder: URL, policy: OperationPolicy,
                                     progress: @escaping ExportProgress = { _, _ in }) async throws -> URL {
        try policy.requireExecution()
        guard [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else {
            throw MediaError.message("Photos access is not granted. Use Change source → Photos access before exporting.")
        }
        let identifier = String(item.id.dropFirst("photos:system:".count))
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw MediaError.message("Photos cannot find this video in the accessible library. Check Photos access and refresh the scan.")
        }
        guard asset.modificationDate == item.modificationDate else { throw MediaError.message("The source changed. Rescan before exporting.") }
        guard !asset.mediaSubtypes.contains(.videoHighFrameRate), !asset.mediaSubtypes.contains(.videoCinematic),
              !asset.mediaSubtypes.contains(.spatialMedia), !item.edited else {
            throw MediaError.message("Edited, slow-motion, and cinematic Photos videos are excluded in this prototype.")
        }
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .video }) else {
            throw MediaError.message("Original video resource unavailable.")
        }
        let ext = URL(fileURLWithPath: resource.originalFilename).pathExtension
        let output = folder.appendingPathComponent("source-" + UUID().uuidString).appendingPathExtension(ext)
        progress("Reading original", 0)
        let (bytes, hash) = try await measure(resource, output: output) { bytes in
            progress("Reading original · \(Format.bytes(bytes))", item.bytes.flatMap { $0 > 0 ? min(1, Double(bytes) / Double($0)) : nil })
        }
        guard bytes == item.bytes, ImageAnalyzer.digest("\(resource.type.rawValue):\(hash)") == item.fingerprint else {
            throw MediaError.message("The original video content changed or has additional resources. Rescan before exporting.")
        }
        return output
    }
}
