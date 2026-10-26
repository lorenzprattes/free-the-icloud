import Foundation

/// The backend commits each request as one Photos change transaction.
public protocol PhotoMutationBackend: Sendable {
    func delete(_ items: [MediaItem]) async throws
    func replace(_ item: MediaItem, with verifiedFile: URL) async throws -> String
}

public struct DeletionRequest: Sendable {
    public let items: [MediaItem]
    /// A directly reviewed item, independent of the batch selection.
    public init(item: MediaItem, keeperIDs: Set<String>, allowProtected: Bool) throws {
        try LibraryActions.requirePhotosItem(item)
        guard !keeperIDs.contains(item.id) else { throw MediaError.message("Remove the Keep decision before deleting this item.") }
        guard allowProtected || !item.protected else { throw MediaError.message("Confirm that the protected item is included.") }
        self.items = [item]
    }
    public init(items: [MediaItem], plan: ReviewPlan, allowProtected: Bool) throws {
        guard !items.isEmpty, Set(items.map(\.id)).count == items.count else { throw MediaError.message("Choose items to delete.") }
        for item in items {
            try LibraryActions.requirePhotosItem(item)
            guard plan.selectedIDs.contains(item.id), !plan.keeperIDs.contains(item.id),
                  plan.versions[item.id] == item.reviewVersion else { throw MediaError.message("The review selection changed. Review it again before deleting.") }
            guard allowProtected || !item.protected else { throw MediaError.message("Confirm that protected items are included.") }
        }
        self.items = items
    }
}

public struct LibraryActionReceipt: Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let action: String
    public let sourceIDs: [String]
    public var state: String
    public var replacementID: String?
    public var error: String?
}

public struct LibraryActionResult: Sendable {
    public let receipt: LibraryActionReceipt
    public let recordWarning: String?
}

public enum LibraryActions {
    static func requirePhotosItem(_ item: MediaItem) throws {
        guard item.sourceID == "photos:system", item.id.hasPrefix("photos:system:"),
              item.id.count > "photos:system:".count, item.fileURL == nil else {
            throw MediaError.message("This action is available for Photos library items only.")
        }
    }
    public static func validateReplacement(item: MediaItem, export: ExportResult) throws {
        try requirePhotosItem(item)
        guard item.canQueueVideo, !export.sample, export.sourceID == item.id,
              export.sourceVersion == item.reviewVersion, export.outputFingerprint != nil,
              item.fingerprint != nil, export.savings > 0,
              export.sourceDuration.isFinite, export.sourceDuration > 0,
              abs(export.sourceDuration-export.sampleDuration) < 0.01 else {
            throw MediaError.message("Export a new full compressed copy of this unchanged video before replacing it. Samples and older exports cannot replace originals.")
        }
    }
    public static func validateReplacement(item: MediaItem, export: PhotoExportResult) throws {
        try requirePhotosItem(item)
        guard item.kind == .photo, item.available, !item.livePhoto, !item.raw, !item.edited,
              export.sourceID == item.id, export.sourceVersion == item.reviewVersion,
              item.fingerprint != nil, !export.outputFingerprint.isEmpty,
              item.bytes == export.originalBytes, export.outputBytes > 0, export.savings > 0,
              export.width > 0, export.height > 0,
              Double(export.width) * Double(export.height) < Double(item.width) * Double(item.height) else {
            throw MediaError.message("Export a new, smaller resized copy of this unchanged Photos still before replacing it. Live Photos, RAW and edited photos cannot be replaced.")
        }
    }
    public static func delete(_ request: DeletionRequest, policy: OperationPolicy, records: URL,
                              backend: any PhotoMutationBackend = SystemPhotosMutations()) async throws -> LibraryActionResult {
        try policy.requireExecution()
        try Task.checkCancellation()
        var receipt = LibraryActionReceipt(id: UUID(), date: Date(), action: "delete", sourceIDs: request.items.map(\.id), state: "pending")
        try save(receipt, in: records)
        do {
            try Task.checkCancellation()
            try await backend.delete(request.items)
        } catch {
            receipt.state = "failed"; receipt.error = error.localizedDescription; try? save(receipt, in: records)
            throw error
        }
        receipt.state = "completed"
        return finish(receipt, in: records)
    }
    public static func replace(item: MediaItem, export: ExportResult, reviewed: Bool, policy: OperationPolicy,
                               records: URL, backend: any PhotoMutationBackend = SystemPhotosMutations()) async throws -> LibraryActionResult {
        try policy.requireExecution()
        guard reviewed else { throw MediaError.message("Review the full compressed copy before replacing the original.") }
        try validateReplacement(item: item, export: export)
        return try await replaceVerified(item: item, output: export.output, bytes: export.outputBytes,
            fingerprint: export.outputFingerprint!, extension: "mov", records: records, backend: backend)
    }
    public static func replace(item: MediaItem, export: PhotoExportResult, reviewed: Bool, policy: OperationPolicy,
                               records: URL, backend: any PhotoMutationBackend = SystemPhotosMutations()) async throws -> LibraryActionResult {
        try policy.requireExecution()
        guard reviewed else { throw MediaError.message("Visually review the resized photo before replacing the original.") }
        try validateReplacement(item: item, export: export)
        return try await replaceVerified(item: item, output: export.output, bytes: export.outputBytes,
            fingerprint: export.outputFingerprint, extension: "heic", records: records, backend: backend)
    }
    private static func replaceVerified(item: MediaItem, output: URL, bytes: Int64, fingerprint: String,
                                        extension fileExtension: String, records: URL,
                                        backend: any PhotoMutationBackend) async throws -> LibraryActionResult {
        try Task.checkCancellation()
        var file = output; file.removeAllCachedResourceValues()
        guard file.isFileURL, !file.resolvingSymlinksInPath().pathComponents.contains(where: { $0.lowercased().hasSuffix(".photoslibrary") }) else { throw MediaError.message("Invalid compressed copy location.") }
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize.map(Int64.init) == bytes,
              values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded else {
            throw MediaError.message("The compressed copy changed or is unavailable locally. Export it again.")
        }
        let staging = records.appendingPathComponent("staging-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let copy = staging.appendingPathComponent("replacement").appendingPathExtension(fileExtension)
        try FileManager.default.copyItem(at: file, to: copy)
        guard try ImageAnalyzer.hashFile(copy) == fingerprint else { throw MediaError.message("The compressed copy's content changed. Export it again.") }
        var receipt = LibraryActionReceipt(id: UUID(), date: Date(), action: "replace", sourceIDs: [item.id], state: "pending")
        try save(receipt, in: records)
        do {
            try Task.checkCancellation()
            receipt.replacementID = try await backend.replace(item, with: copy)
        } catch {
            receipt.state = "failed"; receipt.error = error.localizedDescription; try? save(receipt, in: records)
            throw error
        }
        receipt.state = "completed"
        return finish(receipt, in: records)
    }
    private static func save(_ receipt: LibraryActionReceipt, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipt).write(to: directory.appendingPathComponent(receipt.id.uuidString + ".json"), options: .atomic)
    }
    private static func finish(_ receipt: LibraryActionReceipt, in directory: URL) -> LibraryActionResult {
        do { try save(receipt, in: directory); return .init(receipt: receipt, recordWarning: nil) }
        catch { return .init(receipt: receipt, recordWarning: "Photos changed successfully, but the local completion record could not be saved: " + error.localizedDescription) }
    }
}
