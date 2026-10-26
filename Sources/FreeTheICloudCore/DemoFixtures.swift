import Foundation
import CoreGraphics
import AVFoundation
import VideoToolbox

public enum DemoFixtures {
    public static func create(at folder: URL, includeVideos: Bool = true) async throws {
        let marker = folder.appendingPathComponent(includeVideos ? ".complete-v2" : ".images-v2")
        if FileManager.default.fileExists(atPath: marker.path) { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = ["Alpine morning", "Dunes at dusk", "Pacific coast", "Forest lake", "City after rain"]
        for scene in 0..<5 {
            for variant in 0..<3 {
                try Task.checkCancellation()
                let image = try render(scene: scene, variant: variant, width: 1600, height: 1000)
                let file = folder.appendingPathComponent("\(names[scene]) \(variant+1).jpg")
                try ImageAnalyzer.writeJPEG(image, to: file, quality: [0.96, 0.85, 0.7][variant])
            }
        }
        let first = folder.appendingPathComponent("Alpine morning 1.jpg")
        let duplicate = folder.appendingPathComponent("Alpine morning copy.jpg")
        if !FileManager.default.fileExists(atPath: duplicate.path) { try FileManager.default.copyItem(at: first, to: duplicate) }
        if includeVideos {
            try await video(at: folder.appendingPathComponent("Coast in motion.mov"), scene: 2)
            try await video(at: folder.appendingPathComponent("Evening in the dunes.mov"), scene: 1)
        }
        try Data("Generated fixtures only. No personal media.\n".utf8).write(to: marker)
    }
    public static func render(scene: Int, variant: Int = 0, width: Int = 1600, height: Int = 1000) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MediaError.message("Could not allocate the demo image.")
        }
        draw(in: context, scene: scene, variant: variant, width: width, height: height)
        guard let image = context.makeImage() else { throw MediaError.message("Cannot render the demo.") }
        return image
    }
    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: alpha)
    }
    public static func draw(in ctx: CGContext, scene: Int, variant: Int, width: Int, height: Int) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.scaleBy(x: CGFloat(width)/1600, y: CGFloat(height)/1000)
        let palettes: [[UInt32]] = [
            [0x9ab9c1, 0xe8d8b9, 0x718e95, 0x435d64, 0x253d43],
            [0x867d96, 0xf1c391, 0xc18d68, 0xa66b50, 0x774f43],
            [0x91bac2, 0xf0e5cb, 0x528f96, 0x2d727d, 0x164856],
            [0xb6c6ba, 0xe2dcc2, 0x6f8977, 0x476b60, 0x214a43],
            [0x8499aa, 0xf0b799, 0x747988, 0x535966, 0x313d4d]
        ]
        let p = palettes[scene % palettes.count]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(p[1]), color(p[0])] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 1000), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.setFillColor(color(0xffedc4, 0.85))
        ctx.fillEllipse(in: CGRect(x: 1110 + variant*4, y: 640, width: 125, height: 125))
        for layer in 0..<3 {
            ctx.beginPath(); ctx.move(to: CGPoint(x: 0, y: 0))
            let baseline = CGFloat(510-layer*115)
            for step in 0...32 {
                let x = CGFloat(step)*50
                let wave = sin(Double(step)*0.25 + Double(scene)*1.7 + Double(layer))
                let peak = scene == 0 ? abs(sin(Double(step)*0.35 + Double(layer))) * 170 : 0
                let y = baseline + CGFloat(wave*70 + peak) + CGFloat(variant)*2
                ctx.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.addLine(to: CGPoint(x: 1600, y: 0)); ctx.closePath()
            ctx.setFillColor(color(p[layer+2])); ctx.fillPath()
        }
        if scene == 2 || scene == 3 {
            ctx.setFillColor(color(p[0], 0.6)); ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 235))
            for line in 0..<18 {
                ctx.setStrokeColor(color(0xffffff, 0.08)); ctx.setLineWidth(2)
                ctx.move(to: CGPoint(x: (line*79)%400, y: line*12))
                ctx.addLine(to: CGPoint(x: 1000+(line*47)%600, y: line*12+4)); ctx.strokePath()
            }
        }
        if scene == 3 {
            for tree in 0..<15 {
                let x = CGFloat(tree*119); let h = CGFloat(120+(tree*31)%150)
                ctx.setFillColor(color(p[4])); ctx.beginPath()
                ctx.move(to: CGPoint(x: x, y: 210)); ctx.addLine(to: CGPoint(x: x+40, y: 210+h))
                ctx.addLine(to: CGPoint(x: x+80, y: 210)); ctx.closePath(); ctx.fillPath()
            }
        }
        if scene == 4 {
            for building in 0..<17 {
                let x = CGFloat(building*100); let h = CGFloat(100+(building*67)%280)
                ctx.setFillColor(color(p[4])); ctx.fill(CGRect(x: x, y: 30, width: 86, height: h))
                ctx.setFillColor(color(0xf3d8aa, 0.65))
                for row in 0..<Int(h/30) { for column in 0..<3 where (building+row+column)%3 != 0 {
                    ctx.fill(CGRect(x: x+12+CGFloat(column*23), y: 50+CGFloat(row*27), width: 9, height: 13))
                } }
            }
        }
        // Fine deterministic texture gives the codecs actual detail to encode.
        var seed = UInt64(scene+1)*7919
        for _ in 0..<16000 {
            seed = seed &* 6364136223846793005 &+ 1
            let x = CGFloat((seed >> 32)%1600)
            seed = seed &* 6364136223846793005 &+ 1
            let y = CGFloat((seed >> 32)%1000)
            ctx.setFillColor(color(seed & 1 == 0 ? 0xffffff : 0x000000, 0.045))
            ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
        }
    }
    public static func video(at url: URL, scene: Int = 2, frameCount: Int = 96, frameRate: Int32 = 24, withAudio: Bool = false, width: Int = 960, height: Int = 600,
                             transform: CGAffineTransform = .identity, bitrate: Int = 8_000_000, hdrTransfer: String? = nil) async throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [
            AVVideoCodecKey: hdrTransfer == nil ? AVVideoCodecType.h264 : AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoMaxKeyFrameIntervalKey: 24]
        ]
        if let hdrTransfer {
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020, AVVideoTransferFunctionKey: hdrTransfer, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
            settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: bitrate, AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: hdrTransfer == nil ? kCVPixelFormatType_32ARGB : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        input.transform = transform
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MediaError.message("Cannot create demo video.") }
        writer.startSession(atSourceTime: .zero)
        do {
            for frame in 0..<frameCount {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw writer.error ?? MediaError.message("Demo writer stopped.") }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                guard let pool = adaptor.pixelBufferPool else { throw MediaError.message("No demo video buffer pool.") }
                var buffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw MediaError.message("Cannot allocate video frame.") }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let hdrTransfer {
                    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
                    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, hdrTransfer as CFString, .shouldPropagate)
                    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
                    for plane in 0..<2 {
                        let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
                        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
                        let pointer = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt16.self)
                        for y in 0..<rows { for x in 0..<width {
                            let code = plane == 0 ? 64 + ((x * 7 + y * 3 + frame * 11) % width) * 876 / max(1, width - 1) : 512
                            pointer[y * stride + x] = UInt16(code << 6)
                        } }
                    }
                } else {
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
                    CVPixelBufferUnlockBaseAddress(buffer, []); throw MediaError.message("Cannot draw video frame.")
                }
                draw(in: context, scene: scene, variant: frame/12, width: width, height: height)
                context.setFillColor(color(0xf4e8cc, 0.65))
                context.fillEllipse(in: CGRect(x: CGFloat(frame)*8, y: 130, width: 30, height: 7))
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: frameRate)) else {
                    throw writer.error ?? MediaError.message("Cannot append a video frame.")
                }
            }
            input.markAsFinished(); await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? MediaError.message("Demo video creation failed.") }
            if withAudio { try await addGeneratedTone(to: url, duration: Double(frameCount) / Double(frameRate)) }
        } catch { writer.cancelWriting(); try? FileManager.default.removeItem(at: url); throw error }
    }
    private static func addGeneratedTone(to url: URL, duration: Double) async throws {
        let audio = url.deletingLastPathComponent().appendingPathComponent("tone-" + UUID().uuidString + ".wav")
        let muxed = url.deletingLastPathComponent().appendingPathComponent("mux-" + UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: audio); try? FileManager.default.removeItem(at: muxed) }
        let count = Int(duration * 48_000)
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        text("RIFF"); number(UInt32(36+count*2)); text("WAVEfmt "); number(UInt32(16))
        number(UInt16(1)); number(UInt16(1)); number(UInt32(48_000)); number(UInt32(96_000))
        number(UInt16(2)); number(UInt16(16)); text("data"); number(UInt32(count*2))
        for i in 0..<count { number(Int16(sin(Double(i) * 440 * 2 * .pi / 48_000) * 1800)) }
        try data.write(to: audio)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: url), audioAsset = AVURLAsset(url: audio)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
              let composedVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let composedAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaError.message("Could not compose the synthetic audio fixture.")
        }
        let range = CMTimeRange(start: .zero, duration: try await videoAsset.load(.duration))
        composedVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
        try composedVideo.insertTimeRange(range, of: videoTrack, at: .zero)
        try composedAudio.insertTimeRange(range, of: audioTrack, at: .zero)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw MediaError.message("Cannot mux the audio fixture.") }
        session.outputURL = muxed; session.outputFileType = .mov; await session.export()
        guard session.status == .completed else { throw session.error ?? MediaError.message("Fixture mux failed.") }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: muxed, to: url)
    }
}
