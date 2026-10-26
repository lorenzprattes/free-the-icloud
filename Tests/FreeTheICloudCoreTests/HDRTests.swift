import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import FreeTheICloudCore

extension CoreTests {
    private func hdrLumaMaximum(_ file: URL) async throws -> Int {
        let asset = AVURLAsset(url: file), reader = try AVAssetReader(asset: asset)
        let track = try requireValue(try await asset.loadTracks(withMediaType: .video).first)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, AVVideoAllowWideColorKey: true])
        reader.add(output); guard reader.startReading() else { throw reader.error! }
        defer { reader.cancelReading() }
        let sample = try requireValue(output.copyNextSampleBuffer())
        let buffer = try requireValue(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let pointer = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
        var maximum = 0
        for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 0) { for x in 0..<CVPixelBufferGetWidthOfPlane(buffer, 0) { maximum = max(maximum, Int(pointer[y * stride + x] >> 6)) } }
        return maximum
    }
    func testHDRVideoExports() async throws {
        for transfer in [AVVideoTransferFunction_ITU_R_2100_HLG, AVVideoTransferFunction_SMPTE_ST_2084_PQ] {
            let root = try temporary(), source = root.appendingPathComponent("source"), output = root.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let file = source.appendingPathComponent("HDR.mov")
            try await DemoFixtures.video(at: file, frameCount: 36, frameRate: 12, withAudio: true, width: 640, height: 360,
                transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0), hdrTransfer: transfer)
            let originalHash = try ImageAnalyzer.hashFile(file)
            let store = try CatalogStore(url: root.appendingPathComponent("catalog.sqlite"))
            let items = try await FolderSource(root: source).scan(store: store, cache: root.appendingPathComponent("cache")) { _, _ in }
            let item = try requireValue(items.first)
            let sourceTrack = try requireValue(try await AVURLAsset(url: file).loadTracks(withMediaType: .video).first)
            let profile = VideoColorProfile(try await sourceTrack.load(.formatDescriptions)[0])
            expectTrue(profile.isHDR); expectEqual(profile.bitDepth, 10)
            var sizes: [CompressionPreset: Int64] = [:]
            for preset in CompressionPreset.allCases {
                let result = try await VideoExporter.export(item: item, destination: output, preset: preset, sample: true, policy: .init(dryRun: false, approved: true))
                let exported = try requireValue(result.colorProfile)
                try profile.validatePreservation(in: exported)
                expectEqual(exported.transfer, transfer); expectEqual(exported.bitDepth, 10)
                expectEqual(try await AVURLAsset(url: result.output).loadTracks(withMediaType: .audio).count, 1)
                expectGreater(try await hdrLumaMaximum(result.output), 880)
                print("HDR: \(profile.label) → \(exported.label), \(preset.title), \(result.outputBytes) bytes")
                sizes[preset] = result.outputBytes
            }
            let ratio = Double(try requireValue(sizes[.balanced])) / Double(try requireValue(sizes[.original]))
            print("PRESETS HDR \(profile.label): Small/High \(ratio)")
            expectTrue(ratio < 0.70)
            let full = try await VideoExporter.export(item: item, destination: output, preset: .balanced, sample: false, policy: .init(dryRun: false, approved: true))
            expectGreater(full.savings, 0)
            expectEqual(try ImageAnalyzer.hashFile(file), originalHash)
        }
    }
    func testHDRPhotoResize() async throws {
        let root = try temporary(), source = root.appendingPathComponent("source"), output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        var components = [Float](repeating: 0, count: 800 * 600 * 4)
        for pixel in 0..<(800 * 600) {
            components[pixel * 4] = 4; components[pixel * 4 + 1] = 2; components[pixel * 4 + 2] = 1.5; components[pixel * 4 + 3] = 1
        }
        let data = components.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: 800 * 16, size: CGSize(width: 800, height: 600), format: .RGBAf, colorSpace: linear)
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAh])
        let file = source.appendingPathComponent("HDR.heic")
        try context.writeHEIF10Representation(of: image, to: file, colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!)
        if #available(macOS 15, *) {
            let sdr = CIImage(color: CIColor(red: 0.8, green: 0.6, blue: 0.5)).cropped(to: image.extent)
            var hdrImage = try requireValue(CIImage(contentsOf: file, options: [.expandToHDR: true]))
            if #available(macOS 26, *) { hdrImage = hdrImage.settingContentHeadroom(4) }
            try context.writeHEIFRepresentation(of: sdr, to: source.appendingPathComponent("gain-map.heic"), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [.hdrImage: hdrImage])
        }
        try ImageAnalyzer.writeJPEG(DemoFixtures.render(scene: 1, width: 800, height: 600), to: source.appendingPathComponent("SDR.jpg"))
        let oriented = source.appendingPathComponent("rotated.jpg")
        let destination = try requireValue(CGImageDestinationCreateWithURL(oriented as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try DemoFixtures.render(scene: 2, width: 800, height: 600), [kCGImagePropertyOrientation: 6] as CFDictionary)
        expectTrue(CGImageDestinationFinalize(destination))
        let store = try CatalogStore(url: root.appendingPathComponent("catalog.sqlite"))
        let items = try await FolderSource(root: source).scan(store: store, cache: root.appendingPathComponent("cache")) { _, _ in }
        for item in items {
            let original = try ImageAnalyzer.hashFile(item.fileURL!)
            let copy = try await PhotoExporter.export(item: item, destination: output, maxDimension: 400, policy: .init(dryRun: false, approved: true))
            expectEqual(copy.width, item.name == "rotated.jpg" ? 300 : 400); expectEqual(copy.height, item.name == "rotated.jpg" ? 400 : 300)
            expectEqual(copy.hdr, item.name.hasSuffix(".heic"))
            if copy.hdr {
                let result = try requireValue(CIImage(contentsOf: copy.output, options: [.expandToHDR: true]))
                var pixel = [Float](repeating: 0, count: 4)
                pixel.withUnsafeMutableBytes { context.render(result, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 100, y: 100, width: 1, height: 1), format: .RGBAf, colorSpace: linear) }
                let before = try requireValue(CIImage(contentsOf: item.fileURL!, options: [.expandToHDR: true]))
                var baseline = [Float](repeating: 0, count: 4)
                baseline.withUnsafeMutableBytes { context.render(before, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 100, y: 100, width: 1, height: 1), format: .RGBAf, colorSpace: linear) }
                print("PHOTO LEVELS: \(item.name) \(baseline) -> \(pixel)")
                expectGreater(pixel[0], 1.1)
                expectTrue(abs(pixel[0] - baseline[0]) < max(0.1, baseline[0] * 0.1))
            }
            expectEqual(try ImageAnalyzer.hashFile(item.fileURL!), original)
            try await store.savePhotoExports([copy], source: item.sourceID)
            expectEqual(try await store.photoExports(source: item.sourceID).first?.output, copy.output)
            print("PHOTO: \(item.name) → \(copy.width)×\(copy.height), HDR: \(copy.hdr)")
        }
        var fake = try requireValue(items.first); fake.sourceID = "photos:system"; fake.id = "photos:system:fake"; fake.fileURL = nil
        do { _ = try await PhotoExporter.export(item: fake, destination: output, maxDimension: 400, policy: .init(dryRun: true, approved: true)); fail("Dry-run photo export succeeded") }
        catch { expectTrue(error.localizedDescription.contains("Dry-run")) }
        var changed = try requireValue(items.first); changed.fingerprint = "stale"
        do { _ = try await PhotoExporter.export(item: changed, destination: output, maxDimension: 400, policy: .init(dryRun: false, approved: true)); fail("Changed photo was exported") }
        catch { expectTrue(error.localizedDescription.contains("changed")) }
        expectFalse(try FileManager.default.contentsOfDirectory(atPath: output.path).contains { $0.hasPrefix(".photo-resize-") })
    }
    func testHDRDownscaleAndValidation() async throws {
        let root = try temporary(), source = root.appendingPathComponent("source"), output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await DemoFixtures.video(at: source.appendingPathComponent("large-hdr.mov"), frameCount: 8, frameRate: 24, width: 2048, height: 1152, hdrTransfer: AVVideoTransferFunction_ITU_R_2100_HLG)
        let store = try CatalogStore(url: root.appendingPathComponent("catalog.sqlite"))
        let items = try await FolderSource(root: source).scan(store: store, cache: root.appendingPathComponent("cache")) { _, _ in }
        let copy = try await VideoExporter.export(item: try requireValue(items.first), destination: output, preset: .compact, sample: false, policy: .init(dryRun: false, approved: true))
        let track = try requireValue(try await AVURLAsset(url: copy.output).loadTracks(withMediaType: .video).first)
        expectEqual(try await track.load(.naturalSize), CGSize(width: 1920, height: 1080))
        expectEqual(copy.colorProfile?.bitDepth, 10); expectEqual(copy.colorProfile?.isHDR, true)
        var sdrFormat: CMFormatDescription?
        expectEqual(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_HEVC, width: 1920, height: 1080,
            extensions: [kCMFormatDescriptionExtension_BitsPerComponent: 8] as CFDictionary, formatDescriptionOut: &sdrFormat), noErr)
        let hdr = try requireValue(copy.colorProfile)
        expectThrows(try hdr.validatePreservation(in: VideoColorProfile(try requireValue(sdrFormat))))
    }
}
