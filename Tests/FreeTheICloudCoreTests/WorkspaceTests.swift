import Foundation
import FreeTheICloudCore

extension CoreTests {
    func testOperationDiagnostics() async throws {
        let root = try temporary(), database = root.appendingPathComponent("catalog.sqlite")
        let store = try CatalogStore(url: database)
        try await store.saveLibraryFailure("Selection changed", source: "photos:system")
        let reopened = try CatalogStore(url: database)
        expectEqual(try await reopened.libraryFailure(source: "photos:system"), "Selection changed")
        expectNil(try await reopened.libraryFailure(source: "other"))
        try await reopened.saveLibraryFailure(nil, source: "photos:system")
        expectNil(try await store.libraryFailure(source: "photos:system"))
        try OperationDiagnostic(action: "delete", state: "confirmation-opened", count: 2).append(in: root)
        try OperationDiagnostic(action: "delete", state: "failed", count: 2, reason: "Selection changed").append(in: root)
        let lines = try String(contentsOf: root.appendingPathComponent("operations.jsonl"), encoding: .utf8).split(separator: "\n")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let events = try lines.map { try decoder.decode(OperationDiagnostic.self, from: Data($0.utf8)) }
        expectEqual(events.map(\.state), ["confirmation-opened", "failed"])
        expectEqual(events.last?.reason, "Selection changed")
    }
    func testLegacySourceDiscovery() async throws {
        let root = try temporary(), url = root.appendingPathComponent("catalog.sqlite"), demo = root.appendingPathComponent("Demo-v2")
        let store = try CatalogStore(url: url)
        var photo = MediaItem(id: "photos:system:fake", sourceID: "photos:system", name: "cached.jpg", kind: .photo)
        try await store.save(photo)
        photo.id = "demo"; photo.sourceID = "folder:" + demo.path
        try await store.save(photo)
        let absent = root.appendingPathComponent("removed-external-drive")
        photo.id = "offline"; photo.sourceID = "folder:" + absent.path; photo.fileURL = absent.appendingPathComponent("photo.jpg")
        try await store.save(photo)
        let sources = try await store.savedSources(demoFolder: demo)
        expectEqual(sources.count, 3); expectEqual(sources.first?.id, "photos:system")
        expectEqual(sources.filter(\.isDemo).count, 1)
        expectFalse(FileManager.default.fileExists(atPath: absent.path))
        expectNil(try await store.lastSourceID())
        let offline = try requireValue(sources.first { $0.id == photo.sourceID })
        try await store.saveSource(offline)
        let reopened = try CatalogStore(url: url)
        expectEqual(try await reopened.lastSourceID(), offline.id)
        expectEqual(try await reopened.items(source: offline.id).first?.name, "cached.jpg")
    }
    func testSavedSourceProgressAndEmptyCatalog() async throws {
        let root = try temporary(), url = root.appendingPathComponent("catalog.sqlite"), store = try CatalogStore(url: url)
        var source = SavedSource(id: "photos:system", name: "System Photo Library", folder: nil, isDemo: false, scanIncomplete: true)
        try await store.saveSource(source)
        expectEqual(try await store.savedSources(demoFolder: root).first?.scanIncomplete, true)
        source.lastCompletedScan = Date(timeIntervalSince1970: 10_000); source.scanIncomplete = false
        try await store.saveSource(source)
        let reopened = try CatalogStore(url: url)
        let loaded = try requireValue(try await reopened.savedSources(demoFolder: root).first)
        expectFalse(loaded.scanIncomplete); expectEqual(loaded.lastCompletedScan, source.lastCompletedScan)
        var paused = loaded; paused.scanIncomplete = true; try await reopened.saveSource(paused)
        let saved = try requireValue(try await store.savedSources(demoFolder: root).first)
        expectTrue(saved.scanIncomplete); expectEqual(saved.lastCompletedScan, source.lastCompletedScan)
    }
    func testExportFailurePersistence() async throws {
        let root = try temporary(), url = root.appendingPathComponent("catalog.sqlite"), store = try CatalogStore(url: url)
        let video = MediaItem(id: "synthetic-video", sourceID: "folder:synthetic", name: "fixture.mov", kind: .video)
        let cause = NSError(domain: "SyntheticEncoder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Encoder unavailable"])
        let error = NSError(domain: "SyntheticExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not export", NSUnderlyingErrorKey: cause])
        let issue = ExportIssue(item: video, error: error, preset: .balanced, sample: false)
        try await store.saveExportIssues([issue], source: video.sourceID)
        let reopened = try CatalogStore(url: url)
        let failures = try await reopened.exportIssues(source: video.sourceID)
        expectEqual(failures.count, 1); expectEqual(failures[0].id, issue.id)
        expectTrue(failures[0].reason.contains("Encoder unavailable")); expectEqual(failures[0].preset, .balanced)
        expectTrue(try await reopened.exportIssues(source: "other").isEmpty)
        try await reopened.saveExportIssues([], source: video.sourceID)
        expectTrue(try await store.exportIssues(source: video.sourceID).isEmpty)
    }
}
