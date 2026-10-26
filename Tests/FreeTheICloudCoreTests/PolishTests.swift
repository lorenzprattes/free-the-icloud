import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import FreeTheICloudCore

private final class ExportProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(String, Double?)] = []
    func record(_ stage: String, _ fraction: Double?) {
        lock.lock(); defer { lock.unlock() }; values.append((stage, fraction))
    }
    func snapshot() -> [(String, Double?)] {
        lock.lock(); defer { lock.unlock() }; return values
    }
}

private actor ScanEvents {
    var ids: [String] = []
    func append(_ item: MediaItem) { ids.append(item.id) }
}

extension CoreTests {
    func testFilters() {
        var small = item("photo2", hash: 1, bytes: 1_500_000)
        small.width = 2000; small.height = 1000
        var large = item("photo10", hash: 2, bytes: 3_000_000); large.kind = .video; large.duration = 30
        var unknown = item("unknown", hash: 3); unknown.bytes = nil; unknown.available = false
        let items = [unknown, large, small]
        var query = MediaQuery()
        expectEqual(query.apply(to: items).map(\.id), [large.id, small.id, unknown.id])
        query.sort = .smallest
        expectEqual(query.apply(to: items).map(\.id), [small.id, large.id, unknown.id])
        query.minimumMB = " 1,5 "; query.maximumMB = "2"
        expectTrue(query.isValid); expectEqual(query.apply(to: items).map(\.id), [small.id])
        for invalid in ["-1", "NaN", "inf", "1e999", "abc", "1,2,3"] {
            query.minimumMB = invalid; expectFalse(query.isValid); expectTrue(query.apply(to: items).isEmpty)
        }
        query.minimumMB = "3"; query.maximumMB = "2"; expectFalse(query.isValid)
        query = MediaQuery(); query.category = "Photos"; query.videosOnly = true; query.minimumSeconds = "20"
        expectEqual(query.apply(to: items).map(\.id), [large.id])
        query = MediaQuery(); query.minimumPixels = 2_000_000; query.availableOnly = true
        expectEqual(query.apply(to: items).map(\.id), [small.id])
        query = MediaQuery(); query.search = "PHOTO"; query.sort = .name
        expectEqual(query.apply(to: items).map(\.id), [small.id, large.id])
    }

    func testReviewVersions() async throws {
        var photo = item("photo", hash: 1); photo.fingerprint = "old"
        var video = item("video", hash: 2); video.kind = .video
        var plan = ReviewPlan(); plan.mark(photo); plan.keep(photo); plan.queue(video)
        expectFalse(plan.selectedIDs.contains(photo.id)); expectTrue(plan.keeperIDs.contains(photo.id))
        let store = try CatalogStore(url: temporary().appendingPathComponent("catalog.sqlite"))
        try await store.savePlan(plan, source: "test")
        plan = try await store.plan(source: "test")
        expectEqual(plan.reconcile(with: [photo, video], complete: true), 0)
        photo.fingerprint = "changed"
        expectEqual(plan.reconcile(with: [photo], complete: false), 1)
        expectTrue(plan.keeperIDs.isEmpty); expectTrue(plan.videoIDs.contains(video.id))
        expectEqual(plan.reconcile(with: [photo], complete: true), 1)
        expectTrue(plan.videoIDs.isEmpty)
        video.edited = true; plan.queue(video); expectTrue(plan.videoIDs.isEmpty)
        let legacy = Data(#"{"selectedIDs":["photo"],"videoIDs":[],"dismissedGroupIDs":[],"preset":"Original dimensions"}"#.utf8)
        var old = try JSONDecoder().decode(ReviewPlan.self, from: legacy)
        expectEqual(old.preset, .original); expectEqual(old.reconcile(with: [photo], complete: true), 1)
    }

    func testIncrementalScanAndResume() async throws {
        let directory = try temporary(), source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0..<8 { try ImageAnalyzer.writeJPEG(DemoFixtures.render(scene: index%5, width: 240, height: 150), to: source.appendingPathComponent("\(index).jpg")) }
        let store = try CatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
        let adapter = FolderSource(root: source), cache = directory.appendingPathComponent("cache")
        let events = ScanEvents()
        let cancelled = Task {
            try await adapter.scan(store: store, cache: cache, onItem: { item in
                await events.append(item)
                withUnsafeCurrentTask { $0?.cancel() }
            }) { _, _ in }
        }
        do { _ = try await cancelled.value; fail("Cancelled scan finished") } catch is CancellationError {}
        expectEqual(await events.ids.count, 1)
        expectEqual(try await store.items(source: adapter.id).count, 1)
        let resumed = try await adapter.scan(store: store, cache: cache, onItem: { await events.append($0) }) { _, _ in }
        expectEqual(resumed.count, 8); expectEqual(await events.ids.count, 9)
        expectEqual(try await store.items(source: adapter.id).count, 8)
    }

    func videoFixture(frames: Int = 24, fps: Int32 = 24, audio: Bool = false,
                      width: Int = 960, height: Int = 600, transform: CGAffineTransform = .identity) async throws -> (MediaItem, URL, CatalogStore) {
        let directory = try temporary(), source = directory.appendingPathComponent("source"), output = directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await DemoFixtures.video(at: source.appendingPathComponent("fixture.mov"), frameCount: frames, frameRate: fps,
                                     withAudio: audio, width: width, height: height, transform: transform)
        let store = try CatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
        let items = try await FolderSource(root: source).scan(store: store, cache: directory.appendingPathComponent("cache")) { _, _ in }
        return (try requireValue(items.first), output, store)
    }

    func testBalancedVideoAndHistory() async throws {
        let (item, output, store) = try await videoFixture(frames: 96, fps: 12, audio: true,
            transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 600, ty: 0))
        let file = try requireValue(item.fileURL), before = try ImageAnalyzer.hashFile(file)
        let updates = ExportProgressProbe()
        let full = try await VideoExporter.export(item: item, destination: output, preset: .balanced, sample: false, policy: .init(dryRun: false, approved: true)) { stage, fraction in updates.record(stage, fraction) }
        let progress = updates.snapshot()
        for stage in ["Preparing", "Reading original", "Checking source", "Compressing", "Checking copy", "Finished"] {
            expectTrue(progress.contains { $0.0 == stage })
        }
        expectTrue(progress.contains { $0.0.hasPrefix("Reading original ·") && $0.1 != nil })
        expectTrue(progress.compactMap { $0.1 }.allSatisfy { $0.isFinite && (0...1).contains($0) })
        expectGreater(full.savings, 0)
        let sample = try await VideoExporter.export(item: item, destination: output, preset: .balanced, sample: true, policy: .init(dryRun: false, approved: true))
        expectEqual(sample.sampleDuration, 6); expectEqual(sample.sourceDuration, 8)
        let asset = AVURLAsset(url: sample.output)
        expectTrue(abs((try await asset.load(.duration)).seconds-6) < 0.1)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        expectEqual(audio.count, 1)
        let originalAudio = try await AVURLAsset(url: file).loadTracks(withMediaType: .audio)
        let beforeFormat = try await originalAudio[0].load(.formatDescriptions)[0]
        let afterFormat = try await audio[0].load(.formatDescriptions)[0]
        expectEqual(CMFormatDescriptionGetMediaSubType(afterFormat), kAudioFormatMPEG4AAC)
        expectEqual(CMAudioFormatDescriptionGetStreamBasicDescription(beforeFormat)?.pointee.mChannelsPerFrame,
                    CMAudioFormatDescriptionGetStreamBasicDescription(afterFormat)?.pointee.mChannelsPerFrame)
        expectEqual(CMAudioFormatDescriptionGetStreamBasicDescription(beforeFormat)?.pointee.mSampleRate,
                    CMAudioFormatDescriptionGetStreamBasicDescription(afterFormat)?.pointee.mSampleRate)
        let track = try requireValue(try await asset.loadTracks(withMediaType: .video).first)
        expectEqual(try await track.load(.preferredTransform), CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 600, ty: 0))
        expectEqual(try ImageAnalyzer.hashFile(file), before)
        try await store.saveExports([full, sample], source: item.sourceID)
        let saved = try await store.exports(source: item.sourceID)
        expectEqual(saved.map(\.output), [full.output, sample.output])
        print("ENCODE: \(full.originalBytes) → \(full.outputBytes) bytes; portrait transform and audio preserved; middle 6-second sample validated.")
    }

    func testCompressionPresetSeparation() async throws {
        for withAudio in [false, true] {
            let (item, output, store) = try await videoFixture(frames: 72, fps: 24, audio: withAudio)
            let small = try await VideoExporter.export(item: item, destination: output, preset: .balanced, sample: false, policy: .init(dryRun: false, approved: true))
            let high = try await VideoExporter.export(item: item, destination: output, preset: .original, sample: false, policy: .init(dryRun: false, approved: true))
            let ratio = Double(small.outputBytes) / Double(high.outputBytes)
            print("PRESETS SDR audio=\(withAudio): Small \(small.outputBytes), High \(high.outputBytes), Small/High \(ratio)")
            expectTrue(ratio < 0.70)
            expectEqual(small.encodingVersion, 2)
            try await store.saveExports([small], source: item.sourceID)
            expectEqual(try await store.exports(source: item.sourceID).first?.encodingVersion, 2)
            // Old histories must still decode and be identifiable as the earlier recipe.
            let data = try JSONEncoder().encode(small)
            var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            legacy.removeValue(forKey: "encodingVersion")
            let old = try JSONDecoder().decode(ExportResult.self, from: JSONSerialization.data(withJSONObject: legacy))
            expectNil(old.encodingVersion)
        }
    }

    func testExportFailureCleanup() async throws {
        var (item, output, _) = try await videoFixture(frames: 48)
        do {
            _ = try await VideoExporter.export(item: item, destination: output, preset: .balanced, sample: false, policy: .init(dryRun: false, approved: true), availableBytes: 1)
            fail("Low disk space was accepted")
        } catch { expectTrue(error.localizedDescription.contains("free space")) }
        let cancelled = Task {
            try await VideoExporter.export(item: item, destination: output, preset: .balanced, sample: false, policy: .init(dryRun: false, approved: true)) { stage, _ in
                if stage == "Compressing" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await cancelled.value; fail("In-flight cancellation failed") } catch is CancellationError {}
        expectTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        let file = try requireValue(item.fileURL), modified = Date(timeIntervalSince1970: 1_700_000_000)
        item.modificationDate = modified
        var bytes = try Data(contentsOf: file); bytes[bytes.count-1] ^= 1
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        do {
            _ = try await VideoExporter.export(item: item, destination: output, preset: .balanced, sample: false, policy: .init(dryRun: false, approved: true))
            fail("Content change with identical size/date was accepted")
        } catch { expectTrue(error.localizedDescription.contains("content changed")) }
        expectTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    func test1080Downscale() async throws {
        let (item, output, _) = try await videoFixture(frames: 12, width: 3840, height: 2160)
        let result = try await VideoExporter.export(item: item, destination: output, preset: .compact, sample: false, policy: .init(dryRun: false, approved: true))
        let track = try requireValue(try await AVURLAsset(url: result.output).loadTracks(withMediaType: .video).first)
        expectEqual(try await track.load(.naturalSize), CGSize(width: 1920, height: 1080))
    }

    func testNoSavingsAndBoundaries() async throws {
        let (item, output, store) = try await videoFixture(frames: 1, width: 64, height: 64)
        var candidate = item, rejected = false
        // Recompression reaches the encoder's minimum bitrate; encoded sizes vary by hardware.
        for _ in 0..<10 {
            let previous = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
            do {
                let copy = try await VideoExporter.export(item: candidate, destination: output, preset: .balanced, sample: false, policy: .init(dryRun: false, approved: true))
                expectGreater(copy.savings, 0)
                let scanned = try await FolderSource(root: output).scan(store: store, cache: output.appendingPathComponent(".cache")) { _, _ in }
                candidate = try requireValue(scanned.first { $0.name == copy.output.lastPathComponent })
            } catch VideoExportError.noSavings {
                expectEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted(), previous)
                rejected = true; break
            }
        }
        expectTrue(rejected)
        let library = output.appendingPathComponent("DoNotTouch.photoslibrary")
        do {
            _ = try await VideoExporter.export(item: item, destination: library, preset: .balanced, sample: true, policy: .init(dryRun: false, approved: true))
            fail("Photos bundle accepted as destination")
        } catch { expectTrue(error.localizedDescription.contains("outside Photos")) }
        expectFalse(FileManager.default.fileExists(atPath: library.path))
        do {
            _ = try await VideoExporter.export(item: item, destination: output, preset: .balanced, sample: true, policy: .init(dryRun: false, approved: false))
            fail("Unapproved encoding succeeded")
        } catch { expectTrue(error.localizedDescription.contains("approval")) }
    }

    func testImageOrientation() async throws {
        let directory = try temporary(), source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("portrait.jpg")
        let destination = try requireValue(CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let image = try DemoFixtures.render(scene: 1, width: 480, height: 300)
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        expectTrue(CGImageDestinationFinalize(destination))
        let store = try CatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
        let items = try await FolderSource(root: source).scan(store: store, cache: directory.appendingPathComponent("cache")) { _, _ in }
        expectEqual(items.first?.width, 300); expectEqual(items.first?.height, 480)
        let preview = try ImageAnalyzer.thumbnail(file, maxSize: 4096)
        expectEqual(preview.width, 300); expectEqual(preview.height, 480)
    }
}
