import SwiftUI
import AppKit
import AVKit
import FreeTheICloudCore

@main struct FreeTheICloudApp: App {
    @StateObject private var model: AppModel
    init() {
        // Smoke runs never open the user's existing app catalog or approved sources.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-dir"), CommandLine.arguments.count > index+1 {
            let isolated = URL(fileURLWithPath: CommandLine.arguments[index+1]).appendingPathComponent("smoke-workspace")
            _model = StateObject(wrappedValue: AppModel(support: isolated))
        } else { _model = StateObject(wrappedValue: AppModel()) }
    }
    var body: some Scene {
        WindowGroup("Free the iCloud") {
            ContentView(model: model)
                .task {
                    if model.sourceID.isEmpty {
                        if CommandLine.arguments.contains("--snapshot-dir") { model.startDemo() }
                        else { await model.startup() }
                    }
                    if let index = CommandLine.arguments.firstIndex(of: "--snapshot-dir"), CommandLine.arguments.count > index+1 {
                        await makeSnapshots(at: URL(fileURLWithPath: CommandLine.arguments[index+1]))
                    }
                }
        }
        .defaultSize(width: 1280, height: 850)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open folder…", action: model.chooseFolder).keyboardShortcut("o").disabled(model.busy)
                Button("Load generated demo", action: model.startDemo).disabled(model.busy)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo review decision", action: model.undo).keyboardShortcut("z").disabled(model.undoHistory.isEmpty)
            }
        }
    }
    @MainActor private func waitForIdle() async throws {
        let deadline = Date().addingTimeInterval(120)
        while model.busy || model.findingGroups {
            guard Date() < deadline else { model.cancel(); throw MediaError.message("Demo operation timed out.") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    @MainActor private func captureWindow(at url: URL, sheet: Bool = false) throws {
        let window = NSApplication.shared.windows.first(where: { $0.isVisible && (sheet ? !$0.sheets.isEmpty : $0.contentView != nil) })
        guard let view = (sheet ? window?.sheets.first : window)?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw MediaError.message("No app window available for rendering.") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw MediaError.message("Could not render window.") }
        try png.write(to: url)
    }
    @MainActor private func checkDemoPlayback() async throws {
        func players(in view: NSView) -> [AVPlayerView] {
            (view as? AVPlayerView).map { [$0] } ?? view.subviews.flatMap { players(in: $0) }
        }
        guard let view = NSApplication.shared.windows.first(where: { !$0.sheets.isEmpty })?.sheets.first?.contentView else {
            throw MediaError.message("Video comparison did not open.")
        }
        let views = players(in: view)
        guard views.count == 2 else { throw MediaError.message("Comparison must contain two native players.") }
        let deadline = Date().addingTimeInterval(8)
        while !views.allSatisfy({ $0.isReadyForDisplay && $0.player?.status == .readyToPlay }) {
            guard Date() < deadline else { throw MediaError.message("Demo player did not become ready for display.") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let start = views.map { $0.player?.currentTime().seconds ?? 0 }
        for view in views { view.player?.isMuted = true; view.player?.play() }
        try await Task.sleep(nanoseconds: 800_000_000)
        for (index, view) in views.enumerated() {
            view.player?.pause()
            guard (view.player?.currentTime().seconds ?? 0) > start[index]+0.2 else { throw MediaError.message("Demo video playback did not advance.") }
        }
    }
    @MainActor private func makeSnapshots(at directory: URL) async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await waitForIdle()
            guard model.error == nil, !model.items.isEmpty else { throw MediaError.message(model.error ?? "Demo catalog is empty.") }
            guard model.isDemo, model.items.allSatisfy({ $0.fileURL?.path.hasPrefix(directory.appendingPathComponent("smoke-workspace").path + "/") == true }) else { throw MediaError.message("Smoke test source must be isolated generated media.") }
            guard model.dryRun else { throw MediaError.message("Demo did not start in dry-run mode.") }
            NSApplication.shared.windows.first(where: { $0.isVisible })?.setContentSize(NSSize(width: 1280, height: 850))
            let originalPlan = model.plan
            model.minMB = "9999"
            guard model.filtered.isEmpty else { throw MediaError.message("Size filter failed.") }
            model.resetFilters()
            model.minMB = "-1"
            guard !model.filtersValid else { throw MediaError.message("Invalid filter accepted.") }
            model.resetFilters()
            if let photo = model.items.first(where: { $0.kind == .photo }) {
                model.toggleSelection(photo); model.undo()
                guard model.plan.selectedIDs == originalPlan.selectedIDs else { throw MediaError.message("Review undo failed.") }
                model.toggleSelection(photo)
                model.keep(photo)
                guard model.plan.keeperIDs.contains(photo.id), !model.plan.selectedIDs.contains(photo.id) else { throw MediaError.message("Keeper decision failed.") }
                if let group = model.groups.first(where: { $0.items.contains(where: { $0.id == photo.id }) }) { model.selectAlternatives(group) }
                guard !model.plan.selectedIDs.contains(photo.id) else { throw MediaError.message("Keeper was marked as an alternative.") }
                model.toggleSelection(photo)
            }
            for video in model.items.filter({ $0.kind == .video }) { model.toggleVideo(video) }
            await model.waitForPersistence()
            guard try await model.store?.plan(source: model.sourceID).selectedIDs == model.plan.selectedIDs else { throw MediaError.message("Latest review decisions were not persisted.") }
            let destination = directory.appendingPathComponent("generated-exports")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let queued = model.queuedVideos
            model.runExports(selection: queued, destination: destination, preset: .balanced, sample: true)
            guard !model.busy else { throw MediaError.message("Dry-run allowed an export.") }
            model.dryRun = false
            model.runExports(selection: Array(queued.prefix(1)), destination: destination, preset: .balanced, sample: true)
            guard model.busy, model.exportActivity?.running == true, model.exportActivity?.detail == "Preparing export…" else {
                throw MediaError.message("Export did not show immediate feedback.")
            }
            try await Task.sleep(nanoseconds: 150_000_000)
            try captureWindow(at: directory.appendingPathComponent("export-progress.png"))
            try await waitForIdle()
            guard model.exportActivity?.running == false, model.exportActivity?.saved == 1 else {
                throw MediaError.message("Export completion feedback was lost.")
            }
            guard model.error == nil, model.exportFailures.isEmpty, let exported = model.exports.last else { throw MediaError.message("Demo export failed: " + model.exportFailures.map(\.reason).joined(separator: "; ")) }
            guard try await model.store?.exports(source: model.sourceID).last?.output == exported.output else { throw MediaError.message("Export history did not persist.") }
            model.runExports(selection: Array(queued.prefix(1)), destination: destination, preset: .balanced, sample: false)
            try await waitForIdle()
            guard model.exportFailures.isEmpty, let fullExport = model.exports.last, !fullExport.sample else { throw MediaError.message("Full demo export failed.") }
            if let photo = model.items.first(where: { $0.kind == .photo && !$0.edited && !$0.raw && !$0.livePhoto }) {
                model.runPhotoExport(photo, destination: destination, maxDimension: 1280)
                guard model.busy, model.exportActivity?.running == true else { throw MediaError.message("Photo export feedback did not start.") }
                try await waitForIdle()
                guard let resized = model.photoExports.last, FileManager.default.fileExists(atPath: resized.output.path), max(resized.width, resized.height) == 1280 else {
                    throw MediaError.message("Demo photo resize failed: " + model.status)
                }
                model.section = .plan
                try await Task.sleep(nanoseconds: 300_000_000)
                try captureWindow(at: directory.appendingPathComponent("photo-export.png"))
            }
            model.dryRun = true
            for section in Section.allCases {
                model.section = section
                try await Task.sleep(nanoseconds: 500_000_000)
                guard let view = NSApplication.shared.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw MediaError.message("No app window available for rendering.") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw MediaError.message("Could not render window.") }
                try png.write(to: directory.appendingPathComponent(section.rawValue.lowercased().replacingOccurrences(of: " ", with: "-") + ".png"))
            }
            model.section = .media; model.useTable = true
            NSApplication.shared.windows.first(where: { $0.isVisible })?.setContentSize(NSSize(width: 1060, height: 720))
            try await Task.sleep(nanoseconds: 500_000_000)
            try captureWindow(at: directory.appendingPathComponent("table-small-window.png"))
            model.useTable = false
            NSApplication.shared.windows.first(where: { $0.isVisible })?.setContentSize(NSSize(width: 1280, height: 850))
            if let group = model.groups.first {
                model.comparing = group
                try await Task.sleep(nanoseconds: 800_000_000)
                if let view = NSApplication.shared.windows.first(where: { !$0.sheets.isEmpty })?.sheets.first?.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("comparison.png"))
                }
                model.comparing = nil
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            model.viewingExport = exported
            try await Task.sleep(nanoseconds: 1_500_000_000)
            try await checkDemoPlayback()
            try captureWindow(at: directory.appendingPathComponent("video-comparison.png"), sheet: true)
            model.viewingExport = nil
            try await Task.sleep(nanoseconds: 300_000_000)
            if let photo = model.items.first(where: { $0.kind == .photo }) {
                model.inspected = photo
                try await Task.sleep(nanoseconds: 800_000_000)
                try captureWindow(at: directory.appendingPathComponent("inspector.png"), sheet: true)
                model.inspected = nil
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            // Exercise single-item draft/inspector dismissal with an isolated model, without PhotoKit.
            let isolated = AppModel(support: directory.appendingPathComponent("single-delete-model"))
            var direct = model.items.first(where: { $0.kind == .photo })!
            direct.id = "photos:system:synthetic-direct"; direct.sourceID = "photos:system"; direct.fileURL = nil
            var other = direct; other.id = "photos:system:synthetic-other"
            isolated.sourceID = "photos:system"; isolated.items = [direct, other]; isolated.plan.mark(other)
            isolated.inspected = direct
            isolated.prepareSingleDeletion(direct)
            guard isolated.inspected == nil, isolated.pendingLibraryAction == nil else { throw MediaError.message("Single deletion did not wait for inspector dismissal.") }
            isolated.finishInspection()
            guard let singleDraft = isolated.pendingLibraryAction, singleDraft.singleItemDeletion,
                  singleDraft.items.map(\.id) == [direct.id], isolated.plan.selectedIDs == [other.id] else {
                throw MediaError.message("Single deletion included other marks or changed the review selection.")
            }
            isolated.commitLibraryAction(singleDraft, reviewed: true, includeProtected: true)
            guard !isolated.busy, isolated.items.count == 2 else { throw MediaError.message("Dry run did not block single deletion.") }
            isolated.pendingLibraryAction = nil
            isolated.plan.keep(direct); isolated.prepareSingleDeletion(direct)
            guard isolated.pendingLibraryAction == nil else { throw MediaError.message("A keeper could be deleted directly.") }
            model.pendingLibraryAction = singleDraft
            try await Task.sleep(nanoseconds: 500_000_000)
            try captureWindow(at: directory.appendingPathComponent("single-delete-confirmation.png"), sheet: true)
            model.pendingLibraryAction = nil
            try await Task.sleep(nanoseconds: 300_000_000)
            var deletionItems = Array(model.items.filter { $0.kind == .photo }.prefix(2))
            deletionItems[0].favorite = true
            let deletionDraft = LibraryActionDraft(items: deletionItems, export: nil)
            model.pendingLibraryAction = deletionDraft
            model.commitLibraryAction(deletionDraft, reviewed: true, includeProtected: true)
            guard !model.busy, model.pendingLibraryAction?.id == deletionDraft.id else { throw MediaError.message("Dry run did not block deletion confirmation.") }
            model.error = nil
            try await Task.sleep(nanoseconds: 500_000_000)
            try captureWindow(at: directory.appendingPathComponent("delete-confirmation.png"), sheet: true)
            model.pendingLibraryAction = nil
            try await Task.sleep(nanoseconds: 300_000_000)
            let replacementDraft = LibraryActionDraft(items: Array(queued.prefix(1)), export: fullExport)
            model.pendingLibraryAction = replacementDraft
            model.commitLibraryAction(replacementDraft, reviewed: true, includeProtected: true)
            guard !model.busy, model.pendingLibraryAction?.id == replacementDraft.id else { throw MediaError.message("Dry run did not block replacement confirmation.") }
            model.error = nil
            try await Task.sleep(nanoseconds: 500_000_000)
            try captureWindow(at: directory.appendingPathComponent("replace-confirmation.png"), sheet: true)
            model.pendingLibraryAction = nil
            try await Task.sleep(nanoseconds: 300_000_000)
            guard let resized = model.photoExports.first, let originalPhoto = model.items.first(where: { $0.id == resized.sourceID }) else {
                throw MediaError.message("Photo export is missing from review history.")
            }
            let photoDraft = LibraryActionDraft(items: [originalPhoto], export: nil, photoExport: resized)
            model.pendingLibraryAction = photoDraft
            model.commitLibraryAction(photoDraft, reviewed: true, includeProtected: true)
            guard !model.busy, model.pendingLibraryAction?.id == photoDraft.id else { throw MediaError.message("Dry run did not block photo replacement.") }
            model.error = nil
            try await Task.sleep(nanoseconds: 500_000_000)
            try captureWindow(at: directory.appendingPathComponent("photo-replace-confirmation.png"), sheet: true)
            model.pendingLibraryAction = nil
            // Exercise a failed export and make sure the actual reason survives a fresh model.
            model.dryRun = false
            var changed = queued[0]; changed.modificationDate = .distantPast
            model.runExports(selection: [changed], destination: destination, preset: .balanced, sample: false)
            try await waitForIdle()
            guard model.exportFailures.count == 1, model.exportFailures[0].reason.contains("changed"), model.status.contains("No copy saved") else {
                throw MediaError.message("Export failure was not explained.")
            }
            guard model.exportActivity?.running == false, model.exportActivity?.detail.contains("No copy saved") == true else {
                throw MediaError.message("Export failure feedback disappeared.")
            }
            model.dryRun = true; model.section = .plan
            try await Task.sleep(nanoseconds: 500_000_000)
            try captureWindow(at: directory.appendingPathComponent("export-error.png"))
            await model.waitForPersistence()
            let demo = model.support.appendingPathComponent("Demo-v2")
            let parked = model.support.appendingPathComponent("parked-demo")
            try FileManager.default.moveItem(at: demo, to: parked)
            do {
                let reopened = AppModel(support: model.support)
                await reopened.startup()
                guard reopened.error == nil, reopened.showingSavedScan, reopened.dryRun,
                      reopened.items.count == model.items.count, reopened.plan.selectedIDs == model.plan.selectedIDs,
                      reopened.plan.videoIDs == model.plan.videoIDs, reopened.exports.count == model.exports.count,
                      reopened.photoExports.count == model.photoExports.count,
                      reopened.exportFailures.first?.reason == model.exportFailures.first?.reason,
                      reopened.libraryFailure == model.libraryFailure,
                      !FileManager.default.fileExists(atPath: demo.path) else { throw MediaError.message("Saved workspace did not reopen without originals.") }
                try FileManager.default.moveItem(at: parked, to: demo)
            } catch { try? FileManager.default.moveItem(at: parked, to: demo); throw error }
            if let saved = model.savedSources.first(where: { $0.id == model.sourceID }) {
                model.openSavedSource(saved); try await waitForIdle()
                try await Task.sleep(nanoseconds: 500_000_000)
                try captureWindow(at: directory.appendingPathComponent("saved-scan.png"))
            }
            model.plan = originalPlan
            try await model.store?.savePlan(originalPlan, source: model.sourceID)
            let summary = "Demo: \(model.items.count) items; \(model.groups.count) groups; \(model.items.filter { $0.issue != nil }.count) issues. Filters, invalid input, keepers, undo, persistence, dry-run barrier, video queue, actual sample/full exports, export history, navigation, small-window table, and photo/video comparison presentation exercised. Both native video players became ready for display and advanced during playback. Deletion and replacement confirmation sheets rendered, and dry run blocked submission. Saved scan, review decisions, export history and failures reopened with original files temporarily unavailable; no rescan occurred. Photos was not accessed.\n"
            try Data(summary.utf8).write(to: directory.appendingPathComponent("smoke.txt"))
            model.section = .overview
        } catch {
            try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("smoke-error.txt"))
        }
        NSApplication.shared.terminate(nil)
    }
}
