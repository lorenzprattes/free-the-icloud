import Foundation

public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case photo = "Photos", video = "Videos"
}

public struct MediaItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var sourceID: String
    public var name: String
    public var kind: MediaKind
    public var fileURL: URL?
    public var thumbnailURL: URL?
    public var bytes: Int64?
    public var width: Int
    public var height: Int
    public var date: Date?
    public var duration: Double?
    public var favorite = false
    public var edited = false
    public var livePhoto = false
    public var raw = false
    public var screenshot = false
    public var screenRecording = false
    public var available = true
    public var issue: String?
    public var fingerprint: String?
    public var perceptualHash: UInt64?
    public var featurePrint: Data?
    public var analysisVersion = 3
    public var modificationDate: Date?

    public init(id: String, sourceID: String, name: String, kind: MediaKind,
                fileURL: URL? = nil, thumbnailURL: URL? = nil, bytes: Int64? = nil,
                width: Int = 0, height: Int = 0, date: Date? = nil, duration: Double? = nil) {
        self.id = id; self.sourceID = sourceID; self.name = name; self.kind = kind
        self.fileURL = fileURL; self.thumbnailURL = thumbnailURL; self.bytes = bytes
        self.width = width; self.height = height; self.date = date; self.duration = duration
    }
    public var protected: Bool { favorite || edited || livePhoto || raw }
    public var megapixels: Double { Double(width * height) / 1_000_000 }
}

public struct MediaGroup: Identifiable, Sendable {
    public enum Match: String, Sendable { case exact = "Identical originals", similar = "Similar photographs" }
    public var id: String
    public var items: [MediaItem]
    public var referenceID: String
    public var match: Match
    public var explanation: String
}

public enum CompressionPreset: String, CaseIterable, Codable, Sendable {
    case balanced = "Smaller file"
    case original = "Original dimensions"
    case compact = "Fit within 1080p"
    public var title: String { self == .original ? "High quality" : rawValue }
    public var explanation: String {
        switch self {
        case .balanced: return "Stronger compression at the original resolution. Smaller copies; fine detail may soften."
        case .original: return "Prioritizes detail at the original resolution. Less predictable savings; copies can be larger."
        case .compact: return "High-quality HEVC, scaled to fit 1920 × 1080. Matches High quality when already within 1080p."
        }
    }
}

public struct ReviewPlan: Codable, Sendable {
    public var schemaVersion = 2
    public var selectedIDs: Set<String> = []
    public var videoIDs: Set<String> = []
    public var dismissedGroupIDs: Set<String> = []
    public var keeperIDs: Set<String> = []
    public var versions: [String: String] = [:]
    public var preset: CompressionPreset = .balanced
    public init() {}
    private enum CodingKeys: String, CodingKey { case schemaVersion, selectedIDs, videoIDs, dismissedGroupIDs, keeperIDs, versions, preset }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedIDs = try c.decodeIfPresent(Set<String>.self, forKey: .selectedIDs) ?? []
        videoIDs = try c.decodeIfPresent(Set<String>.self, forKey: .videoIDs) ?? []
        dismissedGroupIDs = try c.decodeIfPresent(Set<String>.self, forKey: .dismissedGroupIDs) ?? []
        keeperIDs = try c.decodeIfPresent(Set<String>.self, forKey: .keeperIDs) ?? []
        versions = try c.decodeIfPresent([String: String].self, forKey: .versions) ?? [:]
        preset = try c.decodeIfPresent(CompressionPreset.self, forKey: .preset) ?? .balanced
    }
}

public struct OperationPolicy: Sendable {
    public var dryRun: Bool
    public var approved: Bool
    public init(dryRun: Bool, approved: Bool) { self.dryRun = dryRun; self.approved = approved }
    public func requireExecution() throws {
        guard !dryRun else { throw MediaError.message("Dry-run mode blocks media exports and Photos changes.") }
        guard approved else { throw MediaError.message("This operation requires explicit approval.") }
    }
}

public enum MediaError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public enum Format {
    public static func mediaCounts(_ items: [MediaItem]) -> String {
        let photos = items.filter { $0.kind == .photo }.count
        let videos = items.filter { $0.kind == .video }.count
        return "\(photos) \(photos == 1 ? "photo" : "photos") · \(videos) \(videos == 1 ? "video" : "videos")"
    }
    public static func bytes(_ value: Int64?) -> String {
        guard let value else { return "Unknown size" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
    public static func duration(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
    }
}
