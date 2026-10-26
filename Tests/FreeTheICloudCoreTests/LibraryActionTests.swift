import Foundation
import FreeTheICloudCore

private actor SimulatedPhotos: PhotoMutationBackend {
    var assets: [String: MediaItem]
    var calls = 0
    var failImport: Bool
    var importedHash: String?
    init(_ items: [MediaItem], failImport: Bool = false) {
        assets = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }); self.failImport = failImport
    }
    func delete(_ items: [MediaItem]) async throws {
        calls += 1
        guard items.allSatisfy({ assets[$0.id]?.reviewVersion == $0.reviewVersion }) else { throw MediaError.message("Source changed or disappeared") }
        for item in items { assets.removeValue(forKey: item.id) }
    }
    func replace(_ item: MediaItem, with verifiedFile: URL) async throws -> String {
        calls += 1
        guard assets[item.id]?.reviewVersion == item.reviewVersion else { throw MediaError.message("Source changed or disappeared") }
        importedHash = try ImageAnalyzer.hashFile(verifiedFile)
        if failImport { throw MediaError.message("Simulated import failed") }
        var copy = item; copy.id = "photos:system:new-video"
        assets[copy.id] = copy; assets.removeValue(forKey: item.id)
        return copy.id
    }
}

extension CoreTests {
    private func photosItem(_ name: String = "one") -> MediaItem {
        var item = MediaItem(id: "photos:system:" + name, sourceID: "photos:system", name: name + ".jpg", kind: .photo, bytes: 100)
        item.fingerprint = "fingerprint"; item.modificationDate = Date(timeIntervalSince1970: 1_000)
        return item
    }
    private func expectFailure(_ fragment: String, _ body: () async throws -> Void) async {
        do { try await body(); fail("Expected error containing: " + fragment) }
        catch { if !error.localizedDescription.localizedCaseInsensitiveContains(fragment) { fail("Expected \(fragment); got \(error.localizedDescription)") } }
    }
    func testDeletionSelectionGuards() throws {
        var item = photosItem(), plan = ReviewPlan(); plan.mark(item)
        expectNoThrow(try { _ = try DeletionRequest(items: [item], plan: plan, allowProtected: false) }())
        expectThrows(try { _ = try DeletionRequest(items: [item, item], plan: plan, allowProtected: true) }())
        var keeper = plan; keeper.keep(item)
        expectThrows(try { _ = try DeletionRequest(items: [item], plan: keeper, allowProtected: true) }())
        var legacy = plan; legacy.versions = [:]
        expectThrows(try { _ = try DeletionRequest(items: [item], plan: legacy, allowProtected: true) }())
        item.favorite = true
        expectThrows(try { _ = try DeletionRequest(items: [item], plan: plan, allowProtected: false) }())
        expectNoThrow(try { _ = try DeletionRequest(items: [item], plan: plan, allowProtected: true) }())
        item.modificationDate = Date()
        expectThrows(try { _ = try DeletionRequest(items: [item], plan: plan, allowProtected: true) }())
        item = photosItem(); item.sourceID = "folder:test"; plan.mark(item)
        expectThrows(try { _ = try DeletionRequest(items: [item], plan: plan, allowProtected: true) }())
    }
    func testSingleDeletionScopeAndGuards() async throws {
        for kind in [MediaKind.photo, .video] {
            var target = photosItem("direct"); target.kind = kind
            let other = photosItem("marked")
            var plan = ReviewPlan(); plan.mark(other)
            let request = try DeletionRequest(item: target, keeperIDs: plan.keeperIDs, allowProtected: false)
            let backend = SimulatedPhotos([target, other]), records = try temporary().appendingPathComponent("actions")
            await expectFailure("Dry-run") { _ = try await LibraryActions.delete(request, policy: .init(dryRun: true, approved: true), records: records, backend: backend) }
            await expectFailure("approval") { _ = try await LibraryActions.delete(request, policy: .init(dryRun: false, approved: false), records: records, backend: backend) }
            expectEqual(await backend.calls, 0)
            let result = try await LibraryActions.delete(request, policy: .init(dryRun: false, approved: true), records: records, backend: backend)
            expectEqual(result.receipt.sourceIDs, [target.id])
            expectNil(await backend.assets[target.id]); expectNotNil(await backend.assets[other.id])
            expectEqual(plan.selectedIDs, [other.id])
            expectThrows(try { _ = try DeletionRequest(item: target, keeperIDs: [target.id], allowProtected: true) }())
            target.favorite = true
            expectThrows(try { _ = try DeletionRequest(item: target, keeperIDs: [], allowProtected: false) }())
            expectNoThrow(try { _ = try DeletionRequest(item: target, keeperIDs: [], allowProtected: true) }())
            target.sourceID = "folder:test"
            expectThrows(try { _ = try DeletionRequest(item: target, keeperIDs: [], allowProtected: true) }())
        }
    }
    func testDeletionPoliciesAndFailure() async throws {
        let item = photosItem(); var plan = ReviewPlan(); plan.mark(item)
        let request = try DeletionRequest(items: [item], plan: plan, allowProtected: false)
        let directory = try temporary().appendingPathComponent("actions"), backend = SimulatedPhotos([item])
        await expectFailure("Dry-run") { _ = try await LibraryActions.delete(request, policy: .init(dryRun: true, approved: true), records: directory) }
        await expectFailure("approval") { _ = try await LibraryActions.delete(request, policy: .init(dryRun: false, approved: false), records: directory, backend: backend) }
        expectEqual(await backend.calls, 0); expectFalse(FileManager.default.fileExists(atPath: directory.path))
        let missing = SimulatedPhotos([])
        await expectFailure("disappeared") { _ = try await LibraryActions.delete(request, policy: .init(dryRun: false, approved: true), records: directory, backend: missing) }
        let receipts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let data = try Data(contentsOf: requireValue(receipts.first))
        expectTrue(String(decoding: data, as: UTF8.self).contains("failed"))
    }
    func testDeletionSuccessAndRecordFailure() async throws {
        let items = [photosItem(), photosItem("two")]; var plan = ReviewPlan(); items.forEach { plan.mark($0) }
        let request = try DeletionRequest(items: items, plan: plan, allowProtected: false)
        let root = try temporary(), backend = SimulatedPhotos(items), records = root.appendingPathComponent("records")
        try Data([1]).write(to: records)
        await expectFailure("file") { _ = try await LibraryActions.delete(request, policy: .init(dryRun: false, approved: true), records: records, backend: backend) }
        expectEqual(await backend.calls, 0)
        let result = try await LibraryActions.delete(request, policy: .init(dryRun: false, approved: true), records: root.appendingPathComponent("actions"), backend: backend)
        expectEqual(await backend.calls, 1); expectTrue(await backend.assets.isEmpty)
        expectEqual(result.receipt.state, "completed"); expectEqual(Set(result.receipt.sourceIDs), Set(items.map(\.id)))
        plan.videoIDs = Set(items.map(\.id)); plan.forget(Set(items.map(\.id)))
        expectTrue(plan.selectedIDs.isEmpty); expectTrue(plan.videoIDs.isEmpty); expectTrue(plan.versions.isEmpty)
    }
    private func replacementFixture() async throws -> (MediaItem, ExportResult, URL) {
        let (original, destination, _) = try await videoFixture(frames: 24)
        var export = try await VideoExporter.export(item: original, destination: destination, preset: .balanced, sample: false, policy: .init(dryRun: false, approved: true))
        var photo = original; photo.id = "photos:system:video"; photo.sourceID = "photos:system"; photo.fileURL = nil
        export.sourceID = photo.id; export.sourceVersion = photo.reviewVersion
        return (photo, export, destination.appendingPathComponent("actions"))
    }
    func testReplacementEligibility() async throws {
        let (item, exported, records) = try await replacementFixture()
        expectNoThrow(try LibraryActions.validateReplacement(item: item, export: exported))
        for mode in 0..<5 {
            var copy = exported
            switch mode {
            case 0: copy.sample = true
            case 1: copy.sourceVersion = nil
            case 2: copy.outputFingerprint = nil
            case 3: copy.sourceID = "photos:system:other"
            default: copy.outputBytes = copy.originalBytes
            }
            expectThrows(try LibraryActions.validateReplacement(item: item, export: copy))
        }
        let backend = SimulatedPhotos([item])
        await expectFailure("Dry-run") { _ = try await LibraryActions.replace(item: item, export: exported, reviewed: true, policy: .init(dryRun: true, approved: true), records: records) }
        await expectFailure("approval") { _ = try await LibraryActions.replace(item: item, export: exported, reviewed: true, policy: .init(dryRun: false, approved: false), records: records, backend: backend) }
        await expectFailure("Review") { _ = try await LibraryActions.replace(item: item, export: exported, reviewed: false, policy: .init(dryRun: false, approved: true), records: records, backend: backend) }
        expectEqual(await backend.calls, 0); expectFalse(FileManager.default.fileExists(atPath: records.path))
    }
    func testReplacementIntegrityAndRollback() async throws {
        let (item, export, records) = try await replacementFixture()
        let failing = SimulatedPhotos([item], failImport: true)
        await expectFailure("import failed") { _ = try await LibraryActions.replace(item: item, export: export, reviewed: true, policy: .init(dryRun: false, approved: true), records: records, backend: failing) }
        expectNotNil(await failing.assets[item.id]); expectEqual(await failing.assets.count, 1)
        expectFalse(try FileManager.default.contentsOfDirectory(atPath: records.path).contains { $0.hasPrefix("staging-") })
        var bytes = try Data(contentsOf: export.output); bytes[bytes.count-1] ^= 1; try bytes.write(to: export.output)
        let backend = SimulatedPhotos([item])
        await expectFailure("content changed") { _ = try await LibraryActions.replace(item: item, export: export, reviewed: true, policy: .init(dryRun: false, approved: true), records: records, backend: backend) }
        expectEqual(await backend.calls, 0); expectNotNil(await backend.assets[item.id])
    }
    func testReplacementSuccessAndStaleSource() async throws {
        let (item, export, records) = try await replacementFixture(), backend = SimulatedPhotos([])
        await expectFailure("disappeared") { _ = try await LibraryActions.replace(item: item, export: export, reviewed: true, policy: .init(dryRun: false, approved: true), records: records, backend: backend) }
        let valid = SimulatedPhotos([item])
        let result = try await LibraryActions.replace(item: item, export: export, reviewed: true, policy: .init(dryRun: false, approved: true), records: records, backend: valid)
        expectEqual(await valid.calls, 1); expectNil(await valid.assets[item.id])
        expectEqual(result.receipt.replacementID, "photos:system:new-video")
        expectEqual(await valid.importedHash, export.outputFingerprint)
        expectTrue(FileManager.default.fileExists(atPath: export.output.path))
        expectFalse(try FileManager.default.contentsOfDirectory(atPath: records.path).contains { $0.hasPrefix("staging-") })
    }
    private func photoReplacementFixture() async throws -> (MediaItem, PhotoExportResult, URL) {
        let root = try temporary(), source = root.appendingPathComponent("source"), output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try ImageAnalyzer.writeJPEG(DemoFixtures.render(scene: 2, width: 1600, height: 1200), to: source.appendingPathComponent("original.jpg"))
        let store = try CatalogStore(url: root.appendingPathComponent("catalog.sqlite"))
        let items = try await FolderSource(root: source).scan(store: store, cache: root.appendingPathComponent("cache")) { _, _ in }
        var item = try requireValue(items.first)
        let originalHash = try ImageAnalyzer.hashFile(item.fileURL!)
        var export = try await PhotoExporter.export(item: item, destination: output, maxDimension: 400, policy: .init(dryRun: false, approved: true))
        expectEqual(try ImageAnalyzer.hashFile(item.fileURL!), originalHash)
        item.id = "photos:system:photo"; item.sourceID = "photos:system"; item.fileURL = nil
        export.sourceID = item.id; export.sourceVersion = item.reviewVersion
        return (item, export, root.appendingPathComponent("actions"))
    }
    func testPhotoReplacementReviewAndPolicies() async throws {
        let (item, export, records) = try await photoReplacementFixture()
        expectNoThrow(try LibraryActions.validateReplacement(item: item, export: export))
        for mode in 0..<7 {
            var invalid = item, copy = export
            switch mode {
            case 0: invalid.livePhoto = true
            case 1: invalid.raw = true
            case 2: invalid.edited = true
            case 3: invalid.available = false
            case 4: copy.sourceID = "photos:system:other"
            case 5: copy.sourceVersion = "stale"
            default: copy.outputBytes = copy.originalBytes
            }
            expectThrows(try LibraryActions.validateReplacement(item: invalid, export: copy))
        }
        let backend = SimulatedPhotos([item])
        await expectFailure("Dry-run") { _ = try await LibraryActions.replace(item: item, export: export, reviewed: true, policy: .init(dryRun: true, approved: true), records: records) }
        await expectFailure("approval") { _ = try await LibraryActions.replace(item: item, export: export, reviewed: true, policy: .init(dryRun: false, approved: false), records: records, backend: backend) }
        await expectFailure("Visually review") { _ = try await LibraryActions.replace(item: item, export: export, reviewed: false, policy: .init(dryRun: false, approved: true), records: records, backend: backend) }
        expectEqual(await backend.calls, 0); expectNotNil(await backend.assets[item.id])
        expectFalse(FileManager.default.fileExists(atPath: records.path))
    }
    func testPhotoReplacementIntegrityAndRollback() async throws {
        let (item, export, records) = try await photoReplacementFixture()
        let failing = SimulatedPhotos([item], failImport: true)
        await expectFailure("import failed") { _ = try await LibraryActions.replace(item: item, export: export, reviewed: true, policy: .init(dryRun: false, approved: true), records: records, backend: failing) }
        expectNotNil(await failing.assets[item.id]); expectEqual(await failing.assets.count, 1)
        expectFalse(try FileManager.default.contentsOfDirectory(atPath: records.path).contains { $0.hasPrefix("staging-") })
        var bytes = try Data(contentsOf: export.output); bytes[bytes.count - 1] ^= 1; try bytes.write(to: export.output)
        let backend = SimulatedPhotos([item])
        await expectFailure("content changed") { _ = try await LibraryActions.replace(item: item, export: export, reviewed: true, policy: .init(dryRun: false, approved: true), records: records, backend: backend) }
        expectEqual(await backend.calls, 0); expectNotNil(await backend.assets[item.id])
    }
    func testPhotoReplacementSuccessAndStaleSource() async throws {
        let (item, export, records) = try await photoReplacementFixture()
        var changed = item; changed.modificationDate = Date()
        let stale = SimulatedPhotos([changed])
        await expectFailure("changed") { _ = try await LibraryActions.replace(item: item, export: export, reviewed: true, policy: .init(dryRun: false, approved: true), records: records, backend: stale) }
        expectNotNil(await stale.assets[item.id])
        let valid = SimulatedPhotos([item])
        let result = try await LibraryActions.replace(item: item, export: export, reviewed: true, policy: .init(dryRun: false, approved: true), records: records, backend: valid)
        expectEqual(await valid.calls, 1); expectNil(await valid.assets[item.id])
        expectEqual(result.receipt.state, "completed")
        expectEqual(await valid.importedHash, export.outputFingerprint)
        expectTrue(FileManager.default.fileExists(atPath: export.output.path))
        expectFalse(try FileManager.default.contentsOfDirectory(atPath: records.path).contains { $0.hasPrefix("staging-") })
    }
}
