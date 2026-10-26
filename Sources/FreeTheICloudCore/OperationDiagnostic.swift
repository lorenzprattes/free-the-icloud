import Foundation

/// Local operation diagnostics; excludes asset identities, filenames and media contents.
public struct OperationDiagnostic: Codable {
    public let date: Date
    public let action: String
    public let state: String
    public let count: Int
    public let reason: String?

    public init(action: String, state: String, count: Int, reason: String? = nil) {
        date = Date(); self.action = action; self.state = state; self.count = count; self.reason = reason
    }
    public func append(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("operations.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw MediaError.message("Cannot create the operation log.")
            }
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(self); data.append(0x0a)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
}
