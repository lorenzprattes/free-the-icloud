import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FreeTheICloudCore

enum Section: String, CaseIterable, Identifiable {
    case overview = "Overview", media = "All media", similar = "Similar photos", videos = "Videos", plan = "Review plan"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .overview: return "square.grid.2x2"; case .media: return "photo.on.rectangle.angled"
        case .similar: return "square.on.square"; case .videos: return "film"; case .plan: return "checklist" }
    }
}
typealias SortOrder = MediaSort

struct ExportActivity {
    let destination: URL
    let total: Int
    var detail: String
    var fraction: Double?
    var running = true
    var saved = 0
    var current = 0
    var cancelling = false
}

@MainActor final class AppModel: ObservableObject {
    @Published var section: Section = .media
    @Published var items: [MediaItem] = []
    @Published var groups: [MediaGroup] = []
    @Published var plan = ReviewPlan()
    @Published var sourceName = "Generated demo"
    @Published var sourceID = ""
    @Published var isDemo = true
    @Published var busy = false
    @Published var canCancel = true
    @Published var progressFraction: Double?
    @Published var findingGroups = false
    @Published var exportFailures: [ExportIssue] = []
    @Published var exportActivity: ExportActivity?
    @Published var libraryFailure: String?
    @Published var savedSources: [SavedSource] = []
    @Published var showingSavedScan = false
    @Published var lastCompletedScan: Date?
    @Published var viewingExport: ExportResult?
    @Published var pendingLibraryAction: LibraryActionDraft?
    @Published var highlightedIDs: Set<String> = []
    @Published var status = "Preparing demo…"
    @Published var error: String?
    @Published var dryRun = true
    @Published var query = ""
    @Published var minMB = ""
    @Published var maxMB = ""
    @Published var minSeconds = ""
    @Published var category = "Everything"
    @Published var dateRange = "Any date"
    @Published var minPixels = 0
    @Published var availableOnly = false
    @Published var sort: SortOrder = .largest
    @Published var useTable = false
    @Published var allDates = false
    @Published var hashRadius = 8.0
    @Published var inspected: MediaItem?
    @Published var comparing: MediaGroup?
    @Published var exports: [ExportResult] = []
    @Published var photoExports: [PhotoExportResult] = []
    @Published var lastReport: URL?
    @Published var undoHistory: [ReviewPlan] = []
    let support: URL
    let store: CatalogStore?
    private var folder: URL?
    private var work: Task<Void, Never>?
    private var grouping: Task<Void, Never>?
    private var saving: Task<Void, Never>?
    private var operation = UUID()
    private var pendingItems: [MediaItem] = []
    private var deletionAfterInspection: LibraryActionDraft?
    private var itemPositions: [String: Int] = [:]
    private var lastFlush = Date.distantPast

    init(support: URL? = nil) {
        self.support = support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FreeTheICloud", isDirectory: true)
        do { store = try CatalogStore(url: self.support.appendingPathComponent("catalog.sqlite")) }
        catch { store = nil; self.error = error.localizedDescription }
    }
    var totalBytes: Int64 { items.compactMap(\.bytes).reduce(0, +) }
    var selected: [MediaItem] { items.filter { plan.selectedIDs.contains($0.id) } }
    var queuedVideos: [MediaItem] { items.filter { plan.videoIDs.contains($0.id) } }
    var visibleGroups: [MediaGroup] { groups.filter { !plan.dismissedGroupIDs.contains($0.id) } }
    var mediaQuery: MediaQuery {
        var value = MediaQuery()
        value.search = query; value.minimumMB = minMB; value.maximumMB = maxMB; value.minimumSeconds = section == .videos ? minSeconds : ""
        value.category = category; value.minimumPixels = minPixels; value.availableOnly = availableOnly
        value.videosOnly = section == .videos; value.sort = sort
        if dateRange != "Any date" { value.since = Calendar.current.date(byAdding: .day, value: dateRange == "Last 30 days" ? -30 : -365, to: Date()) }
        return value
    }
    var filtered: [MediaItem] { mediaQuery.apply(to: items) }
    var filtersValid: Bool { mediaQuery.isValid }
    func resetFilters() { query = ""; minMB = ""; maxMB = ""; minSeconds = ""; category = "Everything"; dateRange = "Any date"; minPixels = 0; availableOnly = false }
    func startup() async {
        guard sourceID.isEmpty, !busy, let store else { return }
        busy = true; canCancel = false; status = "Loading saved scan…"
        do {
            savedSources = try await store.savedSources(demoFolder: support.appendingPathComponent("Demo-v2"))
            let last = try await store.lastSourceID()
            if let saved = savedSources.first(where: { $0.id == last }) ?? savedSources.first {
                try await restore(saved)
            } else { busy = false; startDemo(); return }
        } catch { self.error = error.localizedDescription; status = "Couldn’t load the saved scan" }
        busy = false; canCancel = true
    }
    func openSavedSource(_ source: SavedSource) {
        guard !busy else { return }
        busy = true; canCancel = false; status = "Loading saved scan…"
        grouping?.cancel()
        work = Task { [self] in
            defer { busy = false; canCancel = true }
            do { await saving?.value; try await restore(source) }
            catch { self.error = error.localizedDescription; status = "Couldn’t load the saved scan" }
        }
    }
    private func restore(_ source: SavedSource) async throws {
        guard let store else { return }
        let savedItems = try await store.items(source: source.id)
        let savedPlan = try await store.plan(source: source.id)
        let savedExports = try await store.exports(source: source.id)
        let failures = try await store.exportIssues(source: source.id)
        sourceID = source.id; sourceName = source.name; folder = source.folder; isDemo = source.isDemo
        items = savedItems; plan = savedPlan; exports = savedExports; exportFailures = failures
        photoExports = try await store.photoExports(source: source.id)
        exportActivity = nil
        libraryFailure = try await store.libraryFailure(source: source.id)
        dryRun = true; showingSavedScan = true; lastCompletedScan = source.lastCompletedScan
        undoHistory = []; highlightedIDs = []; groups = []; pendingItems = []; itemPositions = [:]
        status = "\(items.count) saved items" + (source.scanIncomplete ? " · Scan paused; refresh to continue" : " · Refresh to check for changes")
        try await store.saveSource(source)
        regroup()
    }
    func startDemo() {
        guard !busy else { return }
        isDemo = true; sourceName = "Generated demo"; dryRun = true; exports = []
        folder = support.appendingPathComponent("Demo-v2", isDirectory: true)
        scan(generate: true)
    }
    func chooseFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Open folder"
        panel.message = "Read this folder locally to measure and compare its media. Originals stay unchanged. No cloud placeholders will be downloaded."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let saved = savedSources.first(where: { $0.id == FolderSource(root: url).id }) { openSavedSource(saved); return }
        folder = url; isDemo = false; sourceName = url.lastPathComponent; dryRun = true; exports = []
        scan()
    }
    func connectPhotos() {
        guard !busy else { return }
        if let saved = savedSources.first(where: { $0.id == "photos:system" }) { openSavedSource(saved); return }
        authorizePhotos()
    }
    func authorizePhotos() {
        guard !busy else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") is String else {
            error = "Open the bundled app in dist to use Photos integration. The standalone Swift executable has no Photos permission declaration."
            return
        }
        guard confirm("Allow local Photos analysis?", "This will request macOS Photos permission and read your System Photo Library, including original bytes available on this Mac, to measure sizes and compare media. It will not download from iCloud or change photos. macOS provides read/write permission; this app enforces dry-run mode separately.", action: "Approve local scan") else { return }
        busy = true; canCancel = false
        work = Task { [self] in
            let granted = await PhotosSource.requestAccess()
            busy = false; canCancel = true
            guard granted else { error = "Photos access was not granted. You can still use the generated demo or a folder."; return }
            if let saved = savedSources.first(where: { $0.id == "photos:system" }) { openSavedSource(saved); return }
            folder = nil; isDemo = false; sourceName = "System Photo Library"; dryRun = true; exports = []
            scan()
        }
    }
    func scan(generate: Bool = false) {
        guard !busy, let store else { return }
        busy = true; canCancel = true; progressFraction = nil; showingSavedScan = false
        exportActivity = nil; libraryFailure = nil
        operation = UUID(); let token = operation
        status = generate ? "Preparing demo…" : "Scanning…"
        grouping?.cancel(); undoHistory = []; resetFilters()
        let selectedFolder = folder
        let source: any MediaSource = selectedFolder.map { FolderSource(root: $0) as any MediaSource } ?? PhotosSource()
        sourceID = source.id; items = []; groups = []; plan = ReviewPlan(); pendingItems = []; itemPositions = [:]; highlightedIDs = []
        var sourceRecord = savedSources.first(where: { $0.id == source.id }) ?? SavedSource(id: source.id, name: sourceName, folder: selectedFolder, isDemo: isDemo)
        sourceRecord.scanIncomplete = true
        work = Task { [self] in
            defer { flushItems(); busy = false; progressFraction = nil }
            do {
                await saving?.value
                try await store.saveSource(sourceRecord)
                savedSources = try await store.savedSources(demoFolder: support.appendingPathComponent("Demo-v2"))
                if generate, let selectedFolder { try await DemoFixtures.create(at: selectedFolder) }
                items = try await store.items(source: source.id)
                plan = try await store.plan(source: source.id)
                exports = try await store.exports(source: source.id)
                photoExports = try await store.photoExports(source: source.id)
                exportFailures = try await store.exportIssues(source: source.id)
                libraryFailure = try await store.libraryFailure(source: source.id)
                itemPositions = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
                let cache = support.appendingPathComponent("Thumbnails", isDirectory: true)
                items = try await source.scan(store: store, cache: cache, onItem: { [weak self] item in
                    await self?.receive(item, token: token)
                }) { count, name in
                    Task { @MainActor [weak self] in
                        guard let self, self.operation == token, self.busy else { return }
                        self.status = "Scanned \(count) · \(name)"
                    }
                }
                pendingItems = []
                let invalidated = plan.reconcile(with: items, complete: true)
                try await store.savePlan(plan, source: source.id)
                sourceRecord.scanIncomplete = false; sourceRecord.lastCompletedScan = Date()
                lastCompletedScan = sourceRecord.lastCompletedScan
                try await store.saveSource(sourceRecord)
                savedSources = try await store.savedSources(demoFolder: support.appendingPathComponent("Demo-v2"))
                status = "\(items.count) items" + (invalidated > 0 ? " · \(invalidated) changed selections cleared" : "")
                regroup()
            } catch is CancellationError {
                items = (try? await store.items(source: source.id)) ?? []
                pendingItems = []; plan.reconcile(with: items, complete: false); persistPlan(); status = "Scan paused · Rescan to continue"; regroup()
            } catch {
                items = (try? await store.items(source: source.id)) ?? []
                pendingItems = []; plan.reconcile(with: items, complete: false); persistPlan(); self.error = error.localizedDescription; status = "Scan incomplete · Rescan to retry"; regroup()
            }
        }
    }
    private func receive(_ item: MediaItem, token: UUID) {
        guard operation == token else { return }
        pendingItems.append(item)
        if Date().timeIntervalSince(lastFlush) > 0.15 || pendingItems.count >= 50 { flushItems() }
    }
    private func flushItems() {
        guard !pendingItems.isEmpty else { return }
        for item in pendingItems {
            if let index = itemPositions[item.id], index < items.count { items[index] = item }
            else { itemPositions[item.id] = items.count; items.append(item) }
        }
        pendingItems = []; lastFlush = Date()
    }
    func regroup() {
        grouping?.cancel(); findingGroups = true
        let snapshot = items, radius = Int(hashRadius), window: Double? = allDates ? nil : 48
        grouping = Task {
            do {
                let job = Task.detached(priority: .userInitiated) { try SimilarityEngine.groups(snapshot, radius: radius, windowHours: window) }
                let result = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
                try Task.checkCancellation(); groups = result; findingGroups = false
            } catch is CancellationError {} catch { findingGroups = false; self.error = error.localizedDescription }
        }
    }
    func mutatePlan(_ change: (inout ReviewPlan) -> Void) {
        guard !busy else { return }
        undoHistory.append(plan); if undoHistory.count > 50 { undoHistory.removeFirst() }
        change(&plan); persistPlan()
    }
    func persistPlan() {
        let snapshot = plan, source = sourceID
        let previous = saving
        saving = Task {
            await previous?.value
            do { try await store?.savePlan(snapshot, source: source) } catch { self.error = error.localizedDescription }
        }
    }
    func waitForPersistence() async { await saving?.value }
    func toggleSelection(_ item: MediaItem) {
        mutatePlan { if $0.selectedIDs.contains(item.id) { $0.selectedIDs.remove(item.id) } else { $0.mark(item) } }
    }
    func toggleVideo(_ item: MediaItem) {
        mutatePlan { if $0.videoIDs.contains(item.id) { $0.videoIDs.remove(item.id) } else { $0.queue(item) } }
    }
    func undo() { guard !busy else { return }; if let previous = undoHistory.popLast() { plan = previous; persistPlan() } }
    func unmarkedAlternatives(_ group: MediaGroup) -> [MediaItem] {
        group.items.filter {
            $0.id != group.referenceID && !$0.protected && !plan.keeperIDs.contains($0.id) && !plan.selectedIDs.contains($0.id)
        }
    }
    func selectAlternatives(_ group: MediaGroup) {
        let alternatives = unmarkedAlternatives(group)
        guard !alternatives.isEmpty else { return }
        mutatePlan { plan in
            for item in alternatives { plan.mark(item) }
        }
    }
    func keep(_ item: MediaItem) {
        mutatePlan { if $0.keeperIDs.contains(item.id) { $0.keeperIDs.remove(item.id) } else { $0.keep(item) } }
    }
    func compareNext(_ group: MediaGroup, offset: Int) {
        guard let index = visibleGroups.firstIndex(where: { $0.id == group.id }), visibleGroups.indices.contains(index+offset) else { return }
        comparing = visibleGroups[index+offset]
    }
    func markVisible() { mutatePlan { plan in for item in filtered where !item.protected && !plan.keeperIDs.contains(item.id) { plan.mark(item) } } }
    func queueVisible() { mutatePlan { plan in for item in filtered where item.canQueueVideo { plan.queue(item) } } }
    func clearReview() { mutatePlan { $0.selectedIDs = [] } }
    func clearQueue() { mutatePlan { $0.videoIDs = [] } }
    func cancel() {
        guard canCancel else { return }
        work?.cancel(); status = "Cancelling current operation…"
        if exportActivity?.running == true { exportActivity?.cancelling = true; exportActivity?.detail = status }
    }

    private func diagnostic(_ action: String, _ state: String, count: Int, reason: String? = nil) {
        do { try OperationDiagnostic(action: action, state: state, count: count, reason: reason).append(in: support) }
        catch { self.error = "Couldn’t save operation diagnostics: " + error.localizedDescription }
    }
    private func libraryActionFailed(_ action: String, count: Int, reason: String) {
        libraryFailure = reason; error = reason
        diagnostic(action, "failed", count: count, reason: reason)
        let source = sourceID, previous = saving
        saving = Task {
            await previous?.value
            do { try await store?.saveLibraryFailure(reason, source: source) }
            catch { self.error = "Couldn’t save the Photos error: " + error.localizedDescription }
        }
    }
    func toggleDryRun() {
        guard !busy else { return }
        if !dryRun { dryRun = true; return }
        if confirm("Enable reviewed operations?", "Photo and video exports, review albums, deletion and replacement will become available. Deletion and replacement change your Photos library and can sync through iCloud. Each operation requires its own confirmation.", action: "Enable operations") { dryRun = false }
    }
    func exportReport(csv: Bool = false) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        panel.nameFieldStringValue = "free-the-icloud-review." + (csv ? "csv" : "json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard !url.resolvingSymlinksInPath().pathComponents.contains(where: { $0.lowercased().hasSuffix(".photoslibrary") }) else {
                throw MediaError.message("Save reports outside Photos library bundles.")
            }
            let data: Data
            if csv {
                func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                let lines = items.filter { plan.selectedIDs.contains($0.id) || plan.videoIDs.contains($0.id) }.map { item in
                    [item.id, item.name, item.bytes.map(String.init) ?? "", plan.selectedIDs.contains(item.id) ? "review" : "", plan.videoIDs.contains(item.id) ? "video-copy" : ""].map(quote).joined(separator: ",")
                }
                data = Data((["id,name,original_bytes,review,video_action"] + lines).joined(separator: "\n").utf8)
            } else {
                struct Report: Encodable { let generatedAt: Date; let demo: Bool; let source: String; let dryRun: Bool; let plan: ReviewPlan; let items: [MediaItem] }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                data = try encoder.encode(Report(generatedAt: Date(), demo: isDemo, source: sourceName, dryRun: dryRun, plan: plan,
                    items: items.filter { plan.selectedIDs.contains($0.id) || plan.videoIDs.contains($0.id) }))
            }
            try data.write(to: url, options: .atomic); lastReport = url; status = "Review report saved. No media changed."
        } catch { self.error = error.localizedDescription }
    }
    func createAlbum() {
        guard !busy, !dryRun, !selected.isEmpty else { return }
        let selection = selected
        guard confirm("Create a review album with \(selection.count) items?", "The selected items shown in Review plan will be added to a new Photos album. Photos may sync this album through your existing iCloud setup. Nothing will be deleted or moved out of your library.", action: "Create album") else { return }
        busy = true; canCancel = false; status = "Creating album…"
        work = Task { [self] in
            defer { busy = false; canCancel = true; progressFraction = nil }
            do { status = "Created “\(try await PhotosSource.addToReviewAlbum(items: selection, policy: .init(dryRun: dryRun, approved: true)))”. Originals unchanged." }
            catch { self.error = error.localizedDescription }
        }
    }
    func prepareDeletion() {
        guard !busy, sourceID == "photos:system", !selected.isEmpty else { return }
        diagnostic("delete", dryRun ? "confirmation-opened-dry-run" : "confirmation-opened", count: selected.count)
        pendingLibraryAction = LibraryActionDraft(items: selected, export: nil)
    }
    func prepareSingleDeletion(_ item: MediaItem) {
        guard !busy, sourceID == "photos:system", !plan.keeperIDs.contains(item.id),
              item.sourceID == sourceID, item.fileURL == nil,
              items.contains(where: { $0.id == item.id && $0.reviewVersion == item.reviewVersion }) else { return }
        let draft = LibraryActionDraft(items: [item], export: nil, singleItemDeletion: true)
        diagnostic("delete", dryRun ? "confirmation-opened-dry-run" : "confirmation-opened", count: 1)
        if inspected != nil {
            deletionAfterInspection = draft
            inspected = nil
        } else { pendingLibraryAction = draft }
    }
    func finishInspection() {
        guard let draft = deletionAfterInspection else { return }
        deletionAfterInspection = nil
        guard !busy, sourceID == "photos:system", let item = draft.items.first,
              !plan.keeperIDs.contains(item.id),
              items.contains(where: { $0.id == item.id && $0.reviewVersion == item.reviewVersion }) else { return }
        pendingLibraryAction = draft
    }
    func canReplace(_ export: ExportResult) -> Bool {
        guard let item = items.first(where: { $0.id == export.sourceID }), !plan.keeperIDs.contains(item.id) else { return false }
        do { try LibraryActions.validateReplacement(item: item, export: export); return true } catch { return false }
    }
    func prepareReplacement(_ export: ExportResult) {
        guard !busy, canReplace(export), let item = items.first(where: { $0.id == export.sourceID }) else { return }
        pendingLibraryAction = LibraryActionDraft(items: [item], export: export)
    }
    func canReplace(_ export: PhotoExportResult) -> Bool {
        guard let item = items.first(where: { $0.id == export.sourceID }), !plan.keeperIDs.contains(item.id) else { return false }
        do { try LibraryActions.validateReplacement(item: item, export: export); return true } catch { return false }
    }
    func prepareReplacement(_ export: PhotoExportResult) {
        guard !busy, canReplace(export), let item = items.first(where: { $0.id == export.sourceID }) else { return }
        pendingLibraryAction = LibraryActionDraft(items: [item], export: nil, photoExport: export)
    }
    func commitLibraryAction(_ draft: LibraryActionDraft, reviewed: Bool, includeProtected: Bool) {
        let action = draft.replacing ? "replace" : "delete"
        diagnostic(action, "confirmation-submitted", count: draft.items.count)
        guard !busy, !dryRun, pendingLibraryAction?.id == draft.id, sourceID == "photos:system" else {
            libraryActionFailed(action, count: draft.items.count, reason: dryRun ? "Dry run blocks Photos changes. Close this dialog and enable actions first." : "The operation is busy or the confirmation is no longer current. Close this dialog and try again.")
            return
        }
        // Freeze the displayed selection and verify it still describes the current catalog.
        guard draft.items.allSatisfy({ frozen in items.contains(where: { $0.id == frozen.id && $0.reviewVersion == frozen.reviewVersion }) }) else {
            libraryActionFailed(action, count: draft.items.count, reason: "The selection changed. Rescan and review again."); pendingLibraryAction = nil; return
        }
        let deletion: DeletionRequest?
        do {
            if let export = draft.export {
                guard reviewed, canReplace(export) else { throw MediaError.message("Review a current full export first.") }
                deletion = nil
            } else if let export = draft.photoExport {
                guard reviewed, canReplace(export) else { throw MediaError.message("Visually review a current resized photo first.") }
                deletion = nil
            } else if draft.singleItemDeletion {
                guard draft.items.count == 1, let item = draft.items.first else { throw MediaError.message("Review one item before deleting.") }
                deletion = try DeletionRequest(item: item, keeperIDs: plan.keeperIDs, allowProtected: includeProtected)
            } else { deletion = try DeletionRequest(items: draft.items, plan: plan, allowProtected: includeProtected) }
        } catch { libraryActionFailed(action, count: draft.items.count, reason: error.localizedDescription); pendingLibraryAction = nil; return }
        pendingLibraryAction = nil; busy = true; canCancel = false
        status = draft.replacing ? "Replacing original in Photos…" : "Deleting from Photos…"
        let records = support.appendingPathComponent("LibraryActions", isDirectory: true)
        work = Task { [self] in
            defer { busy = false; canCancel = true }
            do {
                diagnostic(action, "submitting", count: draft.items.count)
                let result: LibraryActionResult
                if let export = draft.export, let item = draft.items.first {
                    result = try await LibraryActions.replace(item: item, export: export, reviewed: reviewed,
                        policy: .init(dryRun: dryRun, approved: true), records: records)
                } else if let export = draft.photoExport, let item = draft.items.first {
                    result = try await LibraryActions.replace(item: item, export: export, reviewed: reviewed,
                        policy: .init(dryRun: dryRun, approved: true), records: records)
                } else if let deletion {
                    result = try await LibraryActions.delete(deletion, policy: .init(dryRun: dryRun, approved: true), records: records)
                } else { return }
                await waitForPersistence()
                libraryFailure = nil
                diagnostic(action, "completed", count: draft.items.count)
                let removed = Set(result.receipt.sourceIDs)
                items.removeAll { removed.contains($0.id) }
                plan.forget(removed); undoHistory = []; highlightedIDs.subtract(removed)
                regroup()
                status = draft.replacing ? "Original replaced · Refresh to see the new item" : "\(removed.count) items deleted · Check Photos → Recently Deleted for recovery"
                do {
                    try await store?.saveLibraryFailure(nil, source: sourceID)
                    try await store?.prune(source: sourceID, retaining: Set(items.map(\.id)))
                    try await store?.savePlan(plan, source: sourceID)
                    error = result.recordWarning
                } catch { self.error = "Photos changed successfully. Rescan to refresh the local catalog: " + error.localizedDescription }
            } catch {
                let failure = error as NSError
                libraryActionFailed(action, count: draft.items.count, reason: "\(failure.localizedDescription) [\(failure.domain) \(failure.code)]")
                status = "Photos action did not complete · See Review plan"
            }
        }
    }
    func exportPhoto(_ item: MediaItem, maxDimension: Int) {
        guard !busy, !dryRun else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Export resized copy"
        panel.message = "HEIC copy, up to \(maxDimension) px on the longest edge. HDR is preserved as 10-bit PQ when present. The original stays unchanged."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        inspected = nil
        runPhotoExport(item, destination: destination, maxDimension: maxDimension)
    }
    func runPhotoExport(_ item: MediaItem, destination: URL, maxDimension: Int) {
        guard !busy, !dryRun else { return }
        busy = true; canCancel = true; status = "Preparing photo export…"; operation = UUID()
        let token = operation, source = sourceID
        exportActivity = ExportActivity(destination: destination, total: 1, detail: status)
        work = Task { [self] in
            defer {
                operation = UUID(); busy = false; progressFraction = nil
                exportActivity?.running = false; exportActivity?.detail = status; exportActivity?.fraction = nil
            }
            do {
                let result = try await PhotoExporter.export(item: item, destination: destination, maxDimension: maxDimension,
                    policy: .init(dryRun: dryRun, approved: true)) { stage, fraction in
                        Task { @MainActor [weak self] in
                            guard let self, self.operation == token, self.busy, self.exportActivity?.cancelling == false else { return }
                            self.status = stage; self.exportActivity?.detail = stage; self.exportActivity?.fraction = fraction
                        }
                    }
                photoExports.append(result); exportActivity?.saved = 1
                status = "Saved \(result.width) × \(result.height) \(result.hdr ? "HDR " : "")copy · \(Format.bytes(result.outputBytes))"
                do { try await store?.savePhotoExports(photoExports, source: source) }
                catch { self.error = "Copy saved, but history could not be saved: " + error.localizedDescription }
            } catch is CancellationError { status = "Photo export cancelled" }
            catch { status = "No photo copy saved · " + error.localizedDescription; diagnostic("photo-export", "failed", count: 1, reason: error.localizedDescription) }
        }
    }
    func exportVideos(sample: Bool) {
        guard !busy, !dryRun, !queuedVideos.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Choose output folder"; panel.message = "New video copies and JSON manifests will be written here. Originals remain unchanged."
        guard panel.runModal() == .OK, let destination = panel.url else { status = "Export cancelled · No output folder chosen"; return }
        let selection = queuedVideos, preset = plan.preset
        guard confirm("Export \(selection.count) \(sample ? "samples" : "video copies")?", "Preset: \(preset.title)\nDestination: \(destination.path)\n\nThe queued items shown in Review plan will be encoded locally. No copies will be imported into Photos. This does not reclaim iCloud space.", action: "Export locally") else { status = "Export cancelled · No copies created"; return }
        runExports(selection: selection, destination: destination, preset: preset, sample: sample)
    }
    func runExports(selection: [MediaItem], destination: URL, preset: CompressionPreset, sample: Bool) {
        guard !busy, !dryRun, !selection.isEmpty else { return }
        busy = true; canCancel = true; exportFailures = []; operation = UUID()
        status = "Preparing export…"; progressFraction = nil
        exportActivity = ExportActivity(destination: destination, total: selection.count, detail: status)
        diagnostic("export", "started", count: selection.count)
        let token = operation, source = sourceID
        work = Task { [self] in
            defer {
                operation = UUID(); busy = false; canCancel = true; progressFraction = nil
                exportActivity?.running = false; exportActivity?.detail = status; exportActivity?.fraction = nil
                diagnostic("export", "finished", count: exportActivity?.saved ?? 0, reason: status)
            }
            do { try await store?.saveExportIssues([], source: source) }
            catch { self.error = error.localizedDescription; status = "Export could not start: " + error.localizedDescription; return }
            var completed = 0
            for (index, item) in selection.enumerated() {
                do {
                    try Task.checkCancellation(); status = "Preparing \(item.name)"
                    exportActivity?.current = index + 1; exportActivity?.detail = status; exportActivity?.fraction = nil
                    let result = try await VideoExporter.export(item: item, destination: destination, preset: preset,
                        sample: sample, policy: .init(dryRun: dryRun, approved: true)) { stage, fraction in
                            Task { @MainActor [weak self] in
                                guard let self, self.busy, self.operation == token,
                                      self.exportActivity?.current == index + 1, self.exportActivity?.cancelling == false else { return }
                                self.status = "\(stage) \(index+1)/\(selection.count) · \(item.name)"
                                self.progressFraction = fraction
                                self.exportActivity?.detail = self.status; self.exportActivity?.fraction = fraction
                            }
                        }
                    exports.append(result); completed += 1
                    exportActivity?.saved = completed
                    try await store?.saveExports(exports, source: source)
                } catch is CancellationError { status = "Cancelled · \(completed) copies saved"; return }
                catch {
                    if Task.isCancelled { status = "Cancelled · \(completed) copies saved"; return }
                    exportFailures.append(ExportIssue(item: item, error: error, preset: preset, sample: sample))
                    do { try await store?.saveExportIssues(exportFailures, source: source) }
                    catch { self.error = "Couldn’t save the export error: " + error.localizedDescription }
                }
            }
            operation = UUID()
            if completed == 0, let failure = exportFailures.first { status = "No copy saved · " + failure.reason }
            else { status = "\(completed) copies saved" + (exportFailures.isEmpty ? "" : " · \(exportFailures.count) not exported; see Review plan") }
        }
    }

    private func confirm(_ title: String, _ message: String, action: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: action); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
