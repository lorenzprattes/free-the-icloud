import Foundation
import AVFoundation
import VideoToolbox

/// Single video track, original dimensions/timestamps/transform; efficient audio is retained.
enum BalancedEncoder {
    static func encode(asset: AVAsset, track: AVAssetTrack, output: URL, range: CMTimeRange,
                       colorProfile: VideoColorProfile, progress: @escaping ExportProgress) async throws {
        let natural = try await track.load(.naturalSize)
        let sourceRate = Double(try await track.load(.estimatedDataRate))
        let fps = Double(try await track.load(.nominalFrameRate))
        guard sourceRate.isFinite, sourceRate > 0, natural.width > 0, natural.height > 0 else {
            throw MediaError.message("Cannot determine this video's encoding settings.")
        }
        // Stronger compression at the same resolution. HDR receives a larger detail budget.
        let bitsPerPixel = colorProfile.isHDR ? 0.035 : 0.025
        let bitrate = max(64_000, min(sourceRate * 0.25, Double(natural.width * natural.height) * max(fps, 1) * bitsPerPixel))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        writer.metadata = try await asset.load(.metadata)
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(natural.width), AVVideoHeightKey: Int(natural.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(bitrate), AVVideoExpectedSourceFrameRateKey: fps]]
        if colorProfile.isHDR {
            var compression = settings[AVVideoCompressionPropertiesKey] as! [String: Any]
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel
            compression[kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String] = true
            settings[AVVideoCompressionPropertiesKey] = compression
        }
        if let format = try await track.load(.formatDescriptions).first {
            let extensions = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? NSDictionary()
            var color: [String: Any] = [:]
            for (source, destination) in [(kCMFormatDescriptionExtension_ColorPrimaries, AVVideoColorPrimariesKey),
                                          (kCMFormatDescriptionExtension_TransferFunction, AVVideoTransferFunctionKey),
                                          (kCMFormatDescriptionExtension_YCbCrMatrix, AVVideoYCbCrMatrixKey)] {
                if let value = extensions[source] { color[destination] = value }
            }
            if !color.isEmpty { settings[AVVideoColorPropertiesKey] = color }
            if colorProfile.isHDR {
                var compression = settings[AVVideoCompressionPropertiesKey] as! [String: Any]
                for key in [kCMFormatDescriptionExtension_MasteringDisplayColorVolume, kCMFormatDescriptionExtension_ContentLightLevelInfo] {
                    if let value = extensions[key] { compression[key as String] = value }
                }
                settings[AVVideoCompressionPropertiesKey] = compression
            }
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw MediaError.message("HEVC encoding is unavailable for this video.") }
        let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: colorProfile.isHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            AVVideoAllowWideColorKey: true])
        videoOutput.alwaysCopiesSampleData = false
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.transform = try await track.load(.preferredTransform)
        var streams: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]
        for audioTrack in try await asset.loadTracks(withMediaType: .audio) {
            guard let format = try await audioTrack.load(.formatDescriptions).first,
                  let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { throw MediaError.message("Audio format is unavailable.") }
            let audioBudget = audio.mChannelsPerFrame == 1 ? 96_000 : 128_000
            let audioRate = try await audioTrack.load(.estimatedDataRate)
            // Preserve multichannel layouts; avoid re-encoding AAC that is already economical.
            let compressAudio = (1...2).contains(audio.mChannelsPerFrame) &&
                (audio.mFormatID != kAudioFormatMPEG4AAC || audioRate > Float(audioBudget) * 1.1)
            let decoded: [String: Any]? = compressAudio ? [AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false] : nil
            let encoded: [String: Any]? = compressAudio ? [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audio.mSampleRate, AVNumberOfChannelsKey: Int(audio.mChannelsPerFrame),
                AVEncoderBitRateKey: audioBudget] : nil
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: decoded)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: encoded, sourceFormatHint: compressAudio ? nil : format)
            streams.append((output, input))
        }
        for (output, input) in streams {
            guard reader.canAdd(output), writer.canAdd(input) else { throw MediaError.message("This video's track layout is unsupported.") }
            reader.add(output); writer.add(input)
        }
        try Task.checkCancellation()
        guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? MediaError.message("Could not start encoding.") }
        writer.startSession(atSourceTime: range.start)
        do {
            var finished = Set<Int>()
            var lastProgress = Date.distantPast
            while finished.count < streams.count {
                try Task.checkCancellation()
                guard writer.status == .writing, reader.status != .failed else {
                    throw writer.error ?? reader.error ?? MediaError.message("Encoding stopped unexpectedly.")
                }
                var advanced = false
                for (index, stream) in streams.enumerated() where !finished.contains(index) {
                    guard stream.1.isReadyForMoreMediaData else { continue }
                    // One sample per stream each pass preserves backpressure and bounded memory.
                    let sample = autoreleasepool { stream.0.copyNextSampleBuffer() }
                    guard let sample else { stream.1.markAsFinished(); finished.insert(index); continue }
                    guard stream.1.append(sample) else { throw writer.error ?? MediaError.message("Could not encode a media sample.") }
                    advanced = true
                    if index == 0, Date().timeIntervalSince(lastProgress) >= 0.1 {
                        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds - range.start.seconds
                        progress("Compressing", min(0.99, max(0, time / range.duration.seconds))); lastProgress = Date()
                    }
                }
                if !advanced { try await Task.sleep(nanoseconds: 2_000_000) }
            }
            guard reader.status == .completed else { throw reader.error ?? MediaError.message("The source could not be read completely.") }
            writer.endSession(atSourceTime: CMTimeRangeGetEnd(range))
            try Task.checkCancellation()
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? MediaError.message("Could not finish the encoded file.") }
        } catch {
            reader.cancelReading(); writer.cancelWriting()
            throw error
        }
    }
}
