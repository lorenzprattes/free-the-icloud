import Foundation

public enum MediaSort: String, CaseIterable, Sendable {
    case largest = "Largest first", smallest = "Smallest first", newest = "Newest first", name = "Name"
}

public struct MediaQuery: Sendable {
    public var search = ""
    public var minimumMB = ""
    public var maximumMB = ""
    public var minimumSeconds = ""
    public var category = "Everything"
    public var since: Date?
    public var minimumPixels = 0
    public var availableOnly = false
    public var videosOnly = false
    public var sort: MediaSort = .largest
    public init() {}

    // Accept the decimal separator shown by the app's localized byte formatter.
    public static func number(_ string: String) -> Double? {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, value >= 0, value <= Double(Int64.max) / 1_000_000 else { return nil }
        return value
    }
    public var isValid: Bool {
        for value in [minimumMB, maximumMB, minimumSeconds] where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if Self.number(value) == nil { return false }
        }
        if let a = Self.number(minimumMB), let b = Self.number(maximumMB), a > b { return false }
        return true
    }
    public func apply(to items: [MediaItem]) -> [MediaItem] {
        guard isValid else { return [] }
        let minimum = Self.number(minimumMB).map { $0 * 1_000_000 }
        let maximum = Self.number(maximumMB).map { $0 * 1_000_000 }
        let seconds = Self.number(minimumSeconds)
        return items.filter { item in
            if videosOnly && item.kind != .video { return false }
            if !search.isEmpty && !item.name.localizedCaseInsensitiveContains(search) { return false }
            if !videosOnly {
                if category == "Photos" && item.kind != .photo { return false }
                if category == "Videos" && item.kind != .video { return false }
                if category == "Screenshots" && !item.screenshot { return false }
            }
            if let minimum, !(item.bytes.map { Double($0) >= minimum } ?? false) { return false }
            if let maximum, !(item.bytes.map { Double($0) <= maximum } ?? false) { return false }
            if let seconds, !(item.duration.map { $0 >= seconds } ?? false) { return false }
            if let since, !(item.date.map { $0 >= since } ?? false) { return false }
            if Double(item.width) * Double(item.height) < Double(minimumPixels) { return false }
            if availableOnly && !item.available { return false }
            return true
        }.sorted { a, b in
            switch sort {
            case .largest: return a.bytes == b.bytes ? a.id < b.id : (a.bytes ?? -1) > (b.bytes ?? -1)
            case .smallest: return a.bytes == b.bytes ? a.id < b.id : (a.bytes ?? Int64.max) < (b.bytes ?? Int64.max)
            case .newest: return a.date == b.date ? a.id < b.id : (a.date ?? .distantPast) > (b.date ?? .distantPast)
            case .name:
                let order = a.name.localizedStandardCompare(b.name)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            }
        }
    }
}

public extension MediaItem {
    var reviewVersion: String {
        ImageAnalyzer.digest("\(id)|\(modificationDate?.timeIntervalSince1970.description ?? "unknown")|\(bytes?.description ?? "unknown")|\(fingerprint ?? "unknown")")
    }
    var canQueueVideo: Bool { kind == .video && available && !livePhoto && !edited && issue == nil }
}

public extension ReviewPlan {
    mutating func forget(_ ids: Set<String>) {
        selectedIDs.subtract(ids); videoIDs.subtract(ids); keeperIDs.subtract(ids)
        for id in ids { versions.removeValue(forKey: id) }
    }
    mutating func mark(_ item: MediaItem) {
        selectedIDs.insert(item.id); keeperIDs.remove(item.id); versions[item.id] = item.reviewVersion
    }
    mutating func keep(_ item: MediaItem) {
        keeperIDs.insert(item.id); selectedIDs.remove(item.id); versions[item.id] = item.reviewVersion
    }
    mutating func queue(_ item: MediaItem) {
        guard item.canQueueVideo else { return }
        videoIDs.insert(item.id); versions[item.id] = item.reviewVersion
    }
    /// Old plans without versions are intentionally re-reviewed instead of silently trusting changed media.
    @discardableResult mutating func reconcile(with items: [MediaItem], complete: Bool) -> Int {
        let current = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let decisions = selectedIDs.union(videoIDs).union(keeperIDs)
        var invalid: Set<String> = []
        for id in decisions {
            if let item = current[id] {
                if versions[id] != item.reviewVersion { invalid.insert(id) }
            } else if complete { invalid.insert(id) }
        }
        selectedIDs.subtract(invalid); videoIDs.subtract(invalid); keeperIDs.subtract(invalid)
        videoIDs = videoIDs.filter { current[$0]?.canQueueVideo ?? !complete }
        for id in invalid { versions.removeValue(forKey: id) }
        return invalid.count
    }
}
