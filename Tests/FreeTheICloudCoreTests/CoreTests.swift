import Foundation
import AVFoundation
import FreeTheICloudCore

final class CoreTests {
    var failures: [String] = []
    var cleanup: [URL] = []
    deinit { for url in cleanup { try? FileManager.default.removeItem(at: url) } }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("free-the-icloud-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        cleanup.append(url)
        return url
    }
    func item(_ id: String, hash: UInt64, bytes: Int64 = 100, date: Date? = Date(timeIntervalSince1970: 1000)) -> MediaItem {
        var item = MediaItem(id: id, sourceID: "test", name: id, kind: .photo, bytes: bytes, date: date)
        item.perceptualHash = hash
        return item
    }
    func testDryRunAndApprovalAreIndependentBarriers() {
        expectThrows(try OperationPolicy(dryRun: true, approved: true).requireExecution())
        expectThrows(try OperationPolicy(dryRun: false, approved: false).requireExecution())
        expectNoThrow(try OperationPolicy(dryRun: false, approved: true).requireExecution())
    }
    func testDryRunExportDoesNotCreateFiles() async throws {
        let destination = try temporary().appendingPathComponent("must-not-exist")
        let video = MediaItem(id: "missing", sourceID: "test", name: "missing.mov", kind: .video)
        do {
            _ = try await VideoExporter.export(item: video, destination: destination, preset: .original, sample: false, policy: .init(dryRun: true, approved: true))
            fail("Dry-run export succeeded")
        } catch { expectTrue(error.localizedDescription.contains("Dry-run")) }
        expectFalse(FileManager.default.fileExists(atPath: destination.path))
    }
    func testDryRunAlbumStopsBeforePhotoKitAccess() async {
        do {
            _ = try await PhotosSource.addToReviewAlbum(items: [], policy: .init(dryRun: true, approved: true))
            fail("Dry-run album operation succeeded")
        } catch { expectTrue(error.localizedDescription.contains("Dry-run")) }
    }
    func testExactDuplicatesIgnoreCaptureDate() throws {
        var a = item("a", hash: 0); a.fingerprint = "same"
        var b = item("b", hash: .max, date: Date(timeIntervalSince1970: 9_000_000)); b.fingerprint = "same"
        let groups = try SimilarityEngine.groups([a, b])
        expectEqual(groups.count, 1); expectEqual(groups.first?.match, .exact)
    }
    func testDifferentResourceSetsAreNotExactDuplicates() throws {
        var a = item("live-a", hash: 0); a.fingerprint = "still-x|motion-a"; a.livePhoto = true
        var b = item("live-b", hash: 0); b.fingerprint = "still-x|motion-b"; b.livePhoto = true
        expectTrue(try SimilarityEngine.groups([a,b]).allSatisfy { $0.match != .exact })
    }
    func testAnchoredGroupingDoesNotJoinTransitiveChain() throws {
        let a = item("a", hash: 0, bytes: 300), b = item("b", hash: 1, bytes: 200), c = item("c", hash: 3)
        let groups = try SimilarityEngine.groups([a,b,c], radius: 1)
        expectEqual(groups.count, 1); expectEqual(Set(groups[0].items.map(\.id)), ["a","b"])
    }
    func testTimeWindowAndMissingDates() throws {
        let a = item("a", hash: 0), b = item("b", hash: 1, date: Date(timeIntervalSince1970: 9_000_000))
        let c = item("c", hash: 0, date: nil)
        expectTrue(try SimilarityEngine.groups([a,b,c]).isEmpty)
        expectEqual(try SimilarityEngine.groups([a,b,c], windowHours: nil).first?.items.count, 3)
    }
    func testMetricIndexFindsExpectedNeighbors() {
        let index = HashIndex(); var values: [UInt64] = []; var random: UInt64 = 123
        for i in 0..<500 { random = random &* 6364136223846793005 &+ 1; values.append(random); index.insert(random, index: i) }
        for hash in values.prefix(20) {
            let expected = Set(values.indices.filter { (values[$0] ^ hash).nonzeroBitCount <= 12 })
            expectEqual(Set(index.neighbors(hash, radius: 12)), expected)
        }
    }
    func testCatalogPersistsOptionalSizesAndDecisions() async throws {
        let store = try CatalogStore(url: temporary().appendingPathComponent("catalog.sqlite"))
        var photo = item("a", hash: UInt64.max); photo.bytes = nil
        try await store.save(photo)
        var plan = ReviewPlan(); plan.selectedIDs = ["a"]; plan.preset = .compact
        try await store.savePlan(plan, source: "test")
        let loaded = try await store.items(source: "test")
        expectNil(loaded.first?.bytes); expectEqual(loaded.first?.perceptualHash, .max)
        let loadedPlan = try await store.plan(source: "test")
        expectEqual(loadedPlan.selectedIDs, ["a"]); expectEqual(loadedPlan.preset, .compact)
        try await store.prune(source: "test", retaining: [])
        let remaining = try await store.items(source: "test"); expectTrue(remaining.isEmpty)
    }
    func testGeneratedImagesDecodeAndHash() throws {
        let dir = try temporary()
        let image = try DemoFixtures.render(scene: 0, width: 480, height: 300)
        let file = dir.appendingPathComponent("fixture.jpg")
        try ImageAnalyzer.writeJPEG(image, to: file)
        let decoded = try ImageAnalyzer.thumbnail(file)
        let hash = try ImageAnalyzer.perceptualHash(decoded)
        expectNotEqual(hash, 0)
        let copy = dir.appendingPathComponent("copy.jpg")
        try FileManager.default.copyItem(at: file, to: copy)
        expectEqual(try ImageAnalyzer.hashFile(file), try ImageAnalyzer.hashFile(copy))
    }
    func testFolderScanSkipsSymlinksAndLibraryBundlesAndRevalidates() async throws {
        let dir = try temporary(), source = dir.appendingPathComponent("source"), cache = dir.appendingPathComponent("thumbs")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("image.jpg")
        try ImageAnalyzer.writeJPEG(DemoFixtures.render(scene: 1, width: 480, height: 300), to: file)
        let duplicate = source.appendingPathComponent("duplicate.jpg")
        try FileManager.default.copyItem(at: file, to: duplicate)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link.jpg"), withDestinationURL: file)
        let library = source.appendingPathComponent("Excluded.photoslibrary")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: library.appendingPathComponent("hidden.jpg"))
        let store = try CatalogStore(url: dir.appendingPathComponent("catalog.sqlite"))
        let adapter = FolderSource(root: source)
        let first = try await adapter.scan(store: store, cache: cache) { _, _ in }
        expectEqual(first.count, 2)
        expectEqual(try SimilarityEngine.groups(first).filter { $0.match == .exact }.count, 1)
        try ImageAnalyzer.writeJPEG(DemoFixtures.render(scene: 4, width: 640, height: 400), to: file)
        let second = try await adapter.scan(store: store, cache: cache) { _, _ in }
        expectNotEqual(first.first { $0.name == "image.jpg" }?.fingerprint, second.first { $0.name == "image.jpg" }?.fingerprint)
        try FileManager.default.removeItem(at: duplicate)
        let third = try await adapter.scan(store: store, cache: cache) { _, _ in }
        expectEqual(third.count, 1)
        let cached = try await store.items(source: adapter.id); expectEqual(cached.count, 1)
    }
    func testCorruptImageIsReportedWithoutStoppingScan() async throws {
        let dir = try temporary(), source = dir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: source.appendingPathComponent("bad.jpg"))
        let store = try CatalogStore(url: dir.appendingPathComponent("catalog.sqlite"))
        let items = try await FolderSource(root: source).scan(store: store, cache: dir.appendingPathComponent("cache")) { _, _ in }
        expectEqual(items.count, 1); expectNotNil(items.first?.issue)
    }
    func testTenThousandItemCatalogGrouping() throws {
        var random: UInt64 = 123
        let items = (0..<10_000).map { i -> MediaItem in
            random = random &* 6364136223846793005 &+ 1
            return item("\(i)", hash: random)
        }
        let start = Date()
        let groups = try SimilarityEngine.groups(items)
        print("BENCHMARK: 10,000 synthetic metadata records grouped in \(Date().timeIntervalSince(start)) seconds; \(groups.count) groups.")
        expectTrue(groups.allSatisfy { $0.items.count >= 2 })
    }
    func testGeneratedVideoExportsAndPreservesOriginal() async throws {
        let dir = try temporary(), source = dir.appendingPathComponent("source"), output = dir.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let input = source.appendingPathComponent("test.mov")
        try await DemoFixtures.video(at: input, frameCount: 24, withAudio: true)
        let originalHash = try ImageAnalyzer.hashFile(input)
        let store = try CatalogStore(url: dir.appendingPathComponent("catalog.sqlite"))
        let items = try await FolderSource(root: source).scan(store: store, cache: dir.appendingPathComponent("cache")) { _, _ in }
        let item = try requireValue(items.first)
        expectNil(item.issue)
        let result = try await VideoExporter.export(item: item, destination: output, preset: .original, sample: false, policy: .init(dryRun: false, approved: true))
        expectGreater(result.outputBytes, 0)
        expectTrue(FileManager.default.fileExists(atPath: result.output.appendingPathExtension("json").path))
        let audioTracks = try await AVURLAsset(url: result.output).loadTracks(withMediaType: .audio)
        expectEqual(audioTracks.count, 1)
        expectEqual(try ImageAnalyzer.hashFile(input), originalHash)
        let second = try await VideoExporter.export(item: item, destination: output, preset: .compact, sample: true, policy: .init(dryRun: false, approved: true))
        expectNotEqual(second.output, result.output)
        expectTrue(second.sample)
        expectEqual(try ImageAnalyzer.hashFile(input), originalHash)
        let previousFiles = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        let cancelled = Task {
            try Task.checkCancellation()
            return try await VideoExporter.export(item: item, destination: output, preset: .original, sample: false, policy: .init(dryRun: false, approved: true))
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; fail("Cancelled export succeeded") } catch is CancellationError {} catch { fail("Unexpected cancellation error: \(error)") }
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted(), previousFiles)
        try Data([0]).write(to: input)
        do {
            _ = try await VideoExporter.export(item: item, destination: output, preset: .original, sample: false, policy: .init(dryRun: false, approved: true))
            fail("Changed source was exported")
        } catch { if !error.localizedDescription.contains("changed") { fail("Unexpected source-revalidation error: \(error.localizedDescription)") } }
    }
    func testHighFrameRateIsExcluded() async throws {
        let dir = try temporary(), source = dir.appendingPathComponent("source"), output = dir.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await DemoFixtures.video(at: source.appendingPathComponent("high-fps.mov"), frameCount: 24, frameRate: 120)
        let store = try CatalogStore(url: dir.appendingPathComponent("catalog.sqlite"))
        let items = try await FolderSource(root: source).scan(store: store, cache: dir.appendingPathComponent("cache")) { _, _ in }
        let item = try requireValue(items.first)
        do {
            _ = try await VideoExporter.export(item: item, destination: output, preset: .original, sample: false, policy: .init(dryRun: false, approved: true))
            fail("High-frame-rate video was not excluded")
        } catch { if !error.localizedDescription.contains("High-frame-rate") { fail("Unexpected unsupported-format error: \(error)") } }
        expectTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }
}
