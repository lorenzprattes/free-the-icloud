import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public struct PhotoExportResult: Codable, Identifiable, Sendable {
    public var id: String { output.path }
    public var sourceID: String
    public var sourceVersion: String
    public let output: URL
    public let outputFingerprint: String
    public let originalBytes: Int64
    public var outputBytes: Int64
    public let width: Int
    public let height: Int
    public let hdr: Bool
    public let captureDate: Date?
    public let notes: String
    public var savings: Int64 { originalBytes - outputBytes }
}

public enum PhotoExporter {
    public static func export(item: MediaItem, destination: URL, maxDimension: Int, policy: OperationPolicy,
                              progress: @escaping ExportProgress = { _, _ in }) async throws -> PhotoExportResult {
        try policy.requireExecution(); try Task.checkCancellation()
        guard item.kind == .photo, item.available, !item.livePhoto, !item.raw, !item.edited else {
            throw MediaError.message("Resize supports local, unedited still photos. Live Photos and RAW pairs are excluded.")
        }
        guard (100...8192).contains(maxDimension),
              !destination.resolvingSymlinksInPath().pathComponents.contains(where: { $0.lowercased().hasSuffix(".photoslibrary") }) else {
            throw MediaError.message("Choose a valid size and an output folder outside Photos libraries.")
        }
        let capacity = try destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < max(128_000_000, (item.bytes ?? 0) * 3) { throw MediaError.message("Not enough free space for a resized copy.") }
        let staging = destination.appendingPathComponent(".photo-resize-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        progress("Reading photo", nil)
        let source: URL
        if var file = item.fileURL {
            file.removeAllCachedResourceValues()
            let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            guard values.isSymbolicLink != true, values.contentModificationDate == item.modificationDate, values.fileSize.map(Int64.init) == item.bytes,
                  values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded else {
                throw MediaError.message("The source changed or is not local. Refresh before resizing.")
            }
            source = staging.appendingPathComponent("original").appendingPathExtension(file.pathExtension)
            try FileManager.default.copyItem(at: file, to: source)
            guard try ImageAnalyzer.digest("1:" + ImageAnalyzer.hashFile(source)) == item.fingerprint else {
                throw MediaError.message("The photo changed since scanning. Refresh before resizing.")
            }
        } else { source = try await PhotosSource.originalPhoto(for: item, into: staging, policy: policy) }
        try Task.checkCancellation()
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(imageSource) == 1,
              let sourceType = CGImageSourceGetType(imageSource), let type = UTType(sourceType as String),
              [UTType.heic, .heif, .jpeg, .png, .tiff].contains(where: { type.conforms(to: $0) }),
              let image = CIImage(contentsOf: source, options: [.applyOrientationProperty: true, .expandToHDR: true]) else {
            throw MediaError.message("This still-photo format cannot be resized.")
        }
        let longEdge = max(image.extent.width, image.extent.height)
        guard longEdge > CGFloat(maxDimension), image.extent.width > 0, image.extent.height > 0, longEdge.isFinite else {
            throw MediaError.message("The photo is already within this size. No copy was created.")
        }
        var hasGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
        if #available(macOS 15, *) {
            hasGainMap = hasGainMap || CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
        }
        var hdr = hasGainMap || image.colorSpace.map { CGColorSpaceUsesITUR_2100TF($0) } == true
        if #available(macOS 15, *) { hdr = hdr || image.contentHeadroom > 1 }
        let colorSpace = hdr ? CGColorSpace(name: CGColorSpace.itur_2100_PQ)! : (image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
        let ratio = CGFloat(maxDimension) / longEdge
        let width = max(1, Int((image.extent.width * ratio).rounded()))
        let height = max(1, Int((image.extent.height * ratio).rounded()))
        var resized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: ratio, kCIInputAspectRatioKey: 1])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        var properties = image.properties
        properties[kCGImagePropertyOrientation as String] = 1
        properties[kCGImagePropertyPixelWidth as String] = width; properties[kCGImagePropertyPixelHeight as String] = height
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = width; exif[kCGImagePropertyExifPixelYDimension as String] = height
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1; properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        resized = resized.settingProperties(properties)
        progress(hdr ? "Resizing HDR photo" : "Resizing photo", nil)
        let temporary = staging.appendingPathComponent("resized.heic")
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAh])
        let options: [CIImageRepresentationOption: Any] = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.85]
        if hdr { try context.writeHEIF10Representation(of: resized, to: temporary, colorSpace: colorSpace, options: options) }
        else { try context.writeHEIFRepresentation(of: resized, to: temporary, format: .RGBA8, colorSpace: colorSpace, options: options) }
        try Task.checkCancellation(); progress("Checking photo copy", nil)
        guard let check = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(check, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary), decoded.width == width, decoded.height == height else {
            throw MediaError.message("The resized photo failed validation.")
        }
        if hdr {
            guard decoded.bitsPerComponent >= 10, decoded.colorSpace.map({ CGColorSpaceUsesITUR_2100TF($0) }) == true else {
                throw MediaError.message("The resized photo lost HDR information. No copy was kept.")
            }
        }
        let size = Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard size > 0 else { throw MediaError.message("The resized file is empty.") }
        let name = String(URL(fileURLWithPath: item.name).deletingPathExtension().lastPathComponent.prefix(100))
        let output = destination.appendingPathComponent(name + "-\(maxDimension)px-" + UUID().uuidString.prefix(8) + ".heic")
        let result = PhotoExportResult(sourceID: item.id, sourceVersion: item.reviewVersion, output: output,
            outputFingerprint: try ImageAnalyzer.hashFile(temporary), originalBytes: item.bytes ?? 0, outputBytes: size,
            width: width, height: height, hdr: hdr, captureDate: item.date,
            notes: hdr ? "Resized 10-bit PQ HDR HEIC. HDR appearance is retained; the original gain-map representation, depth data and Photos edit history are not preserved. Original unchanged." : "Resized HEIC copy. Original unchanged. Depth data and Photos edit history are not preserved.")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = staging.appendingPathComponent("manifest.json"); try encoder.encode(result).write(to: manifest)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: output)
        do { try FileManager.default.moveItem(at: manifest, to: output.appendingPathExtension("json")) }
        catch { try? FileManager.default.removeItem(at: output); throw error }
        progress("Finished", 1); return result
    }
}
