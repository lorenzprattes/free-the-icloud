import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Vision

public enum ImageAnalyzer {
    public static let version = 3
    public static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    public static func hashFile(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func thumbnail(_ url: URL, maxSize: Int = 1200) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw MediaError.message("Cannot decode \(url.lastPathComponent).") }
        return image
    }
    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.85) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MediaError.message("Cannot create thumbnail.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaError.message("Cannot write thumbnail.") }
    }
    public static func jpegData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw MediaError.message("Cannot prepare image preview.") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaError.message("Cannot render image preview.") }
        return data as Data
    }
    public static func analyze(_ image: CGImage) throws -> (UInt64, Data?) {
        let hash = try perceptualHash(image)
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        // pHash remains usable if the local Vision runtime is unavailable.
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let data = try request.results?.first.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        return (hash, data)
    }
    /// 32x32 grayscale DCT; the low-frequency 8x8 block forms a 64-bit perceptual hash.
    public static func perceptualHash(_ image: CGImage) throws -> UInt64 {
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size)
        let success = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard success else { throw MediaError.message("Cannot allocate image-analysis buffer.") }
        var cosines = [[Double]](repeating: [Double](repeating: 0, count: size), count: 8)
        for u in 0..<8 { for x in 0..<size { cosines[u][x] = cos(Double((2*x+1)*u) * .pi / 64) } }
        var intermediate = [[Double]](repeating: [Double](repeating: 0, count: size), count: 8)
        for u in 0..<8 { for y in 0..<size {
            intermediate[u][y] = (0..<size).reduce(0) { $0 + Double(pixels[y*size+$1]) * cosines[u][$1] }
        } }
        var values: [Double] = []
        for v in 0..<8 { for u in 0..<8 {
            values.append((0..<size).reduce(0) { $0 + intermediate[u][$1] * cosines[v][$1] })
        } }
        let median = values.dropFirst().sorted()[31]
        var result: UInt64 = 0
        for index in 1..<64 where values[index] > median { result |= UInt64(1) << index }
        return result
    }
    public static func distance(_ a: Data?, _ b: Data?) -> Float? {
        guard let a, let b,
              let first = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: a),
              let second = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: b) else { return nil }
        var distance: Float = 0
        do { try first.computeDistance(&distance, to: second); return distance } catch { return nil }
    }
}

/// Metric index: no materialized all-pairs distance matrix. Degenerate inputs can still be quadratic.
public final class HashIndex {
    public init() {}
    final class Node {
        let hash: UInt64
        var indices: [Int]
        var children: [Int: Node] = [:]
        init(_ hash: UInt64, _ index: Int) { self.hash = hash; self.indices = [index] }
    }
    private var root: Node?
    public func insert(_ hash: UInt64, index: Int) {
        guard var node = root else { root = Node(hash, index); return }
        while true {
            let distance = (node.hash ^ hash).nonzeroBitCount
            if distance == 0 { node.indices.append(index); return }
            if let child = node.children[distance] { node = child }
            else { node.children[distance] = Node(hash, index); return }
        }
    }
    public func neighbors(_ hash: UInt64, radius: Int) -> [Int] {
        guard let root else { return [] }
        var stack = [root], result: [Int] = []
        while let node = stack.popLast() {
            let distance = (node.hash ^ hash).nonzeroBitCount
            if distance <= radius { result += node.indices }
            for (edge, child) in node.children where abs(edge-distance) <= radius { stack.append(child) }
        }
        return result
    }
}

public enum SimilarityEngine {
    public static func groups(_ items: [MediaItem], radius: Int = 8, windowHours: Double? = 48) throws -> [MediaGroup] {
        var result: [MediaGroup] = []
        var used: Set<String> = []
        let exact = Dictionary(grouping: items.filter { $0.fingerprint != nil }, by: { $0.fingerprint! })
        for key in exact.keys.sorted() {
            try Task.checkCancellation()
            let members = ranked(exact[key]!)
            if members.count > 1 {
                result.append(MediaGroup(id: "exact:" + key, items: members, referenceID: members[0].id,
                    match: .exact, explanation: "SHA-256 matches for the complete original-resource set. Metadata and edits may differ."))
                used.formUnion(members.map(\.id))
            }
        }
        let photos = ranked(items.filter { $0.kind == .photo && $0.perceptualHash != nil && !used.contains($0.id) })
        let index = HashIndex()
        for (i, photo) in photos.enumerated() { index.insert(photo.perceptualHash!, index: i) }
        for anchor in photos where !used.contains(anchor.id) {
            try Task.checkCancellation()
            let candidates = index.neighbors(anchor.perceptualHash!, radius: max(0, min(32, radius)))
                .map { photos[$0] }.filter { candidate in
                    guard candidate.id != anchor.id, !used.contains(candidate.id) else { return false }
                    guard let windowHours else { return true }
                    guard let a = anchor.date, let b = candidate.date else { return false }
                    return abs(a.timeIntervalSince(b)) <= windowHours * 3600
                }
            var scored: [(item: MediaItem, distance: Float)] = []
            for candidate in candidates {
                try Task.checkCancellation()
                let hamming = (anchor.perceptualHash! ^ candidate.perceptualHash!).nonzeroBitCount
                let distance = ImageAnalyzer.distance(anchor.featurePrint, candidate.featurePrint) ?? Float(hamming)
                scored.append((candidate, distance))
            }
            scored.sort { lhs, rhs in
                if lhs.distance == rhs.distance { return lhs.item.id < rhs.item.id }
                return lhs.distance < rhs.distance
            }
            let matches: [MediaItem] = scored.map { $0.item }
            if !matches.isEmpty {
                let members = [anchor] + matches
                result.append(MediaGroup(id: "similar:" + anchor.id, items: members, referenceID: anchor.id,
                    match: .similar, explanation: "Every image is within \(radius) perceptual-hash bits of the reference. Vision orders comparisons. Review visually; this is not proof of duplication."))
                used.formUnion(members.map(\.id))
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.match != rhs.match { return lhs.match == .exact }
            return lhs.id < rhs.id
        }
    }
    public static func ranked(_ items: [MediaItem]) -> [MediaItem] {
        items.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            if $0.edited != $1.edited { return $0.edited }
            if $0.megapixels != $1.megapixels { return $0.megapixels > $1.megapixels }
            if $0.bytes != $1.bytes { return ($0.bytes ?? 0) > ($1.bytes ?? 0) }
            return $0.id < $1.id
        }
    }
}
