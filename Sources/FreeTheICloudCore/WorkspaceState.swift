import Foundation

public struct SavedSource: Codable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var folder: URL?
    public var isDemo: Bool
    public var lastCompletedScan: Date?
    public var scanIncomplete: Bool
    public init(id: String, name: String, folder: URL?, isDemo: Bool,
                lastCompletedScan: Date? = nil, scanIncomplete: Bool = false) {
        self.id = id; self.name = name; self.folder = folder; self.isDemo = isDemo
        self.lastCompletedScan = lastCompletedScan; self.scanIncomplete = scanIncomplete
    }
}

public struct ExportIssue: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let itemID: String
    public let name: String
    public let reason: String
    public let preset: CompressionPreset
    public let sample: Bool
    public init(item: MediaItem, error: Error, preset: CompressionPreset, sample: Bool) {
        id = UUID(); date = Date(); itemID = item.id; name = item.name
        self.preset = preset; self.sample = sample
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        if let underlying, underlying.localizedDescription != error.localizedDescription {
            reason = error.localizedDescription + " (" + underlying.localizedDescription + ")"
        } else { reason = error.localizedDescription }
    }
}
