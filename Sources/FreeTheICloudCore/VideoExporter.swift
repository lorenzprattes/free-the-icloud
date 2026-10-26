import Foundation
import AVFoundation
import CryptoKit

public typealias ExportProgress = @Sendable (String, Double?) -> Void

public enum VideoExportError: LocalizedError {
    case noSavings
    public var errorDescription: String? { "No size saving. No copy was kept." }
}

// AVFoundation exposes cancellation for use while an asynchronous export is running.
private final class ExportCancellation: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    func cancel() { session.cancelExport() }
}

public struct ExportResult: Codable, Sendable, Identifiable {
    public var id: String { output.path }
    public var sourceID: String
    public var sourceName: String
    public var output: URL
    public var originalBytes: Int64
    public var outputBytes: Int64
    public var sample: Bool
    public var sampleDuration: Double
    public var sourceDuration: Double
    public var preset: CompressionPreset
    public var notes: String
    public var sourceVersion: String?
    public var outputFingerprint: String?
    public var colorProfile: VideoColorProfile?
    public var encodingVersion: Int?
    public var savings: Int64 { originalBytes - outputBytes }
}

public enum VideoExporter {
    public static func export(item: MediaItem, destination: URL, preset: CompressionPreset,
                              sample: Bool, policy: OperationPolicy, availableBytes: Int64? = nil,
                              progress: @escaping ExportProgress = { _, _ in }) async throws -> ExportResult {
        try policy.requireExecution()
        try Task.checkCancellation()
        guard item.kind == .video, item.available, !item.livePhoto else { throw MediaError.message("This item cannot be converted.") }
        guard !destination.resolvingSymlinksInPath().pathComponents.contains(where: { $0.lowercased().hasSuffix(".photoslibrary") }) else {
            throw MediaError.message("Choose an output folder outside Photos libraries.")
        }
        progress("Preparing", nil)
        let required = max((item.bytes ?? 0) * 3, 128_000_000)
        let capacity = try destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let free = availableBytes ?? capacity, free < required {
            throw MediaError.message("Not enough free space. Allow at least \(Format.bytes(required)) for this export.")
        }
        let staging = destination.appendingPathComponent(".free-the-icloud-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let source: URL
        if var file = item.fileURL {
            file.removeAllCachedResourceValues()
            let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            guard values.isSymbolicLink != true, values.contentModificationDate == item.modificationDate,
                  values.fileSize.map(Int64.init) == item.bytes else { throw MediaError.message("The source changed since scanning. Rescan first.") }
            guard values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded else {
                throw MediaError.message("The source is no longer available locally.")
            }
            // Work on a private snapshot so a concurrent edit cannot change the encoder's input.
            let copy = staging.appendingPathComponent("original").appendingPathExtension(file.pathExtension)
            progress("Reading original", 0)
            let fingerprint = try copyAndHash(file, to: copy, total: item.bytes, progress: progress)
            guard item.fingerprint == ImageAnalyzer.digest("2:" + fingerprint) else {
                throw MediaError.message("The source content changed since scanning. Rescan first.")
            }
            source = copy
        } else { source = try await PhotosSource.originalVideo(for: item, into: staging, policy: policy, progress: progress) }
        try Task.checkCancellation()
        progress("Checking source", nil)
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else { throw MediaError.message("Only ordinary single-track video is supported.") }
        let hdr = try await asset.loadTracks(withMediaCharacteristic: .containsHDRVideo)
        let stereo = try await asset.loadTracks(withMediaCharacteristic: .containsStereoMultiviewVideo)
        let spatial = try await asset.loadTracks(withMediaCharacteristic: .carriesVideoStereoMetadata)
        guard stereo.isEmpty, spatial.isEmpty else {
            throw MediaError.message("Spatial video is not supported.")
        }
        let formatDescriptions = try await track.load(.formatDescriptions)
        guard let description = formatDescriptions.first else { throw MediaError.message("Video format information is missing.") }
        let colorProfile = VideoColorProfile(description)
        try colorProfile.requireSupported()
        guard hdr.isEmpty || colorProfile.isHDR else { throw MediaError.message("This HDR transfer function is not supported.") }
        let fps = try await track.load(.nominalFrameRate)
        guard fps <= 60 else { throw MediaError.message("High-frame-rate and slow-motion video are excluded in this prototype.") }
        for description in formatDescriptions {
            let extensions = (CMFormatDescriptionGetExtensions(description) as NSDictionary?) ?? NSDictionary()
            let text = extensions.description.lowercased()
            let codec = CMFormatDescriptionGetMediaSubType(description)
            guard codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC || codec == kCMVideoCodecType_DolbyVisionHEVC,
                  !text.contains("stereo"), !text.contains("multiview"),
                  !text.contains("disparity"), !text.contains("projectionkind") else {
                throw MediaError.message("This spatial or specialty video format is not supported.")
            }
            guard VideoColorProfile(description) == colorProfile else { throw MediaError.message("Videos with changing color formats are not supported.") }
        }
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw MediaError.message("Invalid video duration.") }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let display = natural.applying(transform)
        // Never upscale small inputs just to use the 1080p preset.
        let use1080 = preset == .compact && (max(abs(display.width), abs(display.height)) > 1920 || min(abs(display.width), abs(display.height)) > 1080)
        let presetName = use1080 ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPresetHEVCHighestQuality
        let temporary = staging.appendingPathComponent("encoded.mov")
        let sampleDuration = sample ? min(6, duration.seconds) : duration.seconds
        let range = CMTimeRange(start: CMTime(seconds: sample ? max(0, (duration.seconds-sampleDuration)/2) : 0, preferredTimescale: 600),
                                duration: CMTime(seconds: sampleDuration, preferredTimescale: 600))
        if preset == .balanced {
            try await BalancedEncoder.encode(asset: asset, track: track, output: temporary, range: range, colorProfile: colorProfile, progress: progress)
        } else {
            guard let session = AVAssetExportSession(asset: asset, presetName: presetName), session.supportedFileTypes.contains(.mov) else {
                throw MediaError.message("This video cannot be exported with the selected preset.")
            }
            session.outputURL = temporary; session.outputFileType = .mov
            session.metadata = try await asset.load(.metadata)
            session.shouldOptimizeForNetworkUse = false; session.timeRange = range
            let cancellation = ExportCancellation(session)
            let observer = Task {
                while !Task.isCancelled {
                    progress("Compressing", Double(cancellation.session.progress))
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            defer { observer.cancel() }
            try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                await session.export()
                try Task.checkCancellation()
                guard session.status == .completed else { throw session.error ?? MediaError.message("Video export did not complete.") }
            }, onCancel: { cancellation.cancel() })
        }
        progress("Checking copy", nil)
        let outputAsset = AVURLAsset(url: temporary)
        guard try await outputAsset.load(.isReadable),
              abs((try await outputAsset.load(.duration)).seconds - sampleDuration) < max(0.2, 2 / Double(max(1, fps))),
              let outputTrack = try await outputAsset.loadTracks(withMediaType: .video).first else {
            throw MediaError.message("Export failed playback or duration validation.")
        }
        let outputNatural = try await outputTrack.load(.naturalSize)
        let outputFormats = try await outputTrack.load(.formatDescriptions)
        guard !outputFormats.isEmpty else { throw MediaError.message("Export color information is missing.") }
        for format in outputFormats { try colorProfile.validatePreservation(in: VideoColorProfile(format)) }
        let outputTransform = try await outputTrack.load(.preferredTransform)
        let outputDisplay = outputNatural.applying(outputTransform)
        if !use1080 {
            guard abs(abs(outputDisplay.width)-abs(display.width)) <= 2,
                  abs(abs(outputDisplay.height)-abs(display.height)) <= 2 else {
                throw MediaError.message("Export changed the expected dimensions or orientation.")
            }
        } else {
            guard max(abs(outputDisplay.width), abs(outputDisplay.height)) <= 1920,
                  min(abs(outputDisplay.width), abs(outputDisplay.height)) <= 1080,
                  abs(abs(outputDisplay.width/outputDisplay.height) - abs(display.width/display.height)) < 0.02 else {
                throw MediaError.message("Export failed size or aspect-ratio validation.")
            }
        }
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio)
        let outputAudio = try await outputAsset.loadTracks(withMediaType: .audio)
        guard sourceAudio.count == outputAudio.count else { throw MediaError.message("Export changed the number of audio tracks.") }
        for (before, after) in zip(sourceAudio, outputAudio) {
            guard let beforeFormat = try await before.load(.formatDescriptions).first,
                  let afterFormat = try await after.load(.formatDescriptions).first,
                  let beforeAudio = CMAudioFormatDescriptionGetStreamBasicDescription(beforeFormat)?.pointee,
                  let afterAudio = CMAudioFormatDescriptionGetStreamBasicDescription(afterFormat)?.pointee,
                  beforeAudio.mChannelsPerFrame == afterAudio.mChannelsPerFrame else {
                throw MediaError.message("Export changed the audio channel count.")
            }
        }
        let outputFPS = try await outputTrack.load(.nominalFrameRate)
        guard abs(outputFPS-fps) < 0.5 else { throw MediaError.message("Export changed the frame rate.") }
        let generator = AVAssetImageGenerator(asset: outputAsset)
        _ = try await generator.image(at: .zero)
        let size = Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        if preset == .balanced && !sample && size >= (item.bytes ?? 0) { throw VideoExportError.noSavings }
        guard size > 0 else { throw MediaError.message("The encoded file is empty.") }
        let safeName = String(URL(fileURLWithPath: item.name).deletingPathExtension().lastPathComponent.prefix(100))
        let output = destination.appendingPathComponent(safeName + (sample ? "-sample-" : "-hevc-") + UUID().uuidString.prefix(8) + ".mov")
        let result = ExportResult(sourceID: item.id, sourceName: item.name, output: output,
            originalBytes: item.bytes ?? 0, outputBytes: size, sample: sample,
            sampleDuration: sampleDuration, sourceDuration: duration.seconds, preset: preset,
            notes: "Exported as a separate HEVC copy. Smaller file uses stronger video compression and may compress mono/stereo audio to AAC. Supported container metadata was copied; Photos edit history and album membership are not preserved. Sample size projections are approximate. Originals are unchanged.",
            sourceVersion: item.reviewVersion, outputFingerprint: try ImageAnalyzer.hashFile(temporary), colorProfile: VideoColorProfile(outputFormats[0]), encodingVersion: 2)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = staging.appendingPathComponent("manifest.json")
        try encoder.encode(result).write(to: manifest, options: .atomic)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: output)
        do { try FileManager.default.moveItem(at: manifest, to: output.appendingPathExtension("json")) }
        catch { try? FileManager.default.removeItem(at: output); throw MediaError.message("Could not save the export manifest: \(error.localizedDescription)") }
        progress("Finished", 1)
        return result
    }
    private static func copyAndHash(_ source: URL, to output: URL, total: Int64?, progress: ExportProgress) throws -> String {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw MediaError.message("Cannot stage the source video.") }
        let destination = try FileHandle(forWritingTo: output)
        defer { try? destination.close() }
        var hasher = SHA256()
        var count: Int64 = 0; var lastProgress = Date.distantPast
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation(); hasher.update(data: bytes); try destination.write(contentsOf: bytes)
            count += Int64(bytes.count)
            if Date().timeIntervalSince(lastProgress) >= 0.15 {
                progress("Reading original · \(Format.bytes(count))", total.flatMap { $0 > 0 ? min(1, Double(count) / Double($0)) : nil })
                lastProgress = Date()
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
