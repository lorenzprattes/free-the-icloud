import AVFoundation

public struct VideoColorProfile: Codable, Equatable, Sendable {
    public let transfer: String?
    public let primaries: String?
    public let matrix: String?
    public let bitDepth: Int?
    public let dolbyProfile: Int?
    public let dolbyCompatibility: Int?
    public var isHDR: Bool {
        transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) ||
        transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
    }
    public var label: String { dolbyProfile != nil ? "Dolby Vision (HLG)" : isHDR ? (transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) ? "HLG HDR" : "PQ HDR") : "SDR" }
    public init(_ description: CMFormatDescription) {
        let values = (CMFormatDescriptionGetExtensions(description) as NSDictionary?) ?? NSDictionary()
        transfer = values[kCMFormatDescriptionExtension_TransferFunction] as? String
        primaries = values[kCMFormatDescriptionExtension_ColorPrimaries] as? String
        matrix = values[kCMFormatDescriptionExtension_YCbCrMatrix] as? String
        let atoms = values[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Data] ?? [:]
        let hevc = atoms["hvcC"]
        let explicitDepth = (values[kCMFormatDescriptionExtension_BitsPerComponent] as? NSNumber)?.intValue
        let hevcDepth: Int? = hevc.flatMap { $0.count > 18 ? 8 + Int($0[17] & 7) : nil }
        bitDepth = explicitDepth ?? hevcDepth
        let dolby = atoms["dvcC"] ?? atoms["dvvC"]
        dolbyProfile = dolby.flatMap { $0.count > 4 ? Int($0[2] >> 1) : nil }
        dolbyCompatibility = dolby.flatMap { $0.count > 4 ? Int($0[4] >> 4) : nil }
    }
    public func requireSupported() throws {
        if dolbyProfile != nil {
            guard dolbyProfile == 8, dolbyCompatibility == 4,
                  transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) else {
                throw MediaError.message("This Dolby Vision profile is unsupported. iPhone Dolby Vision 8.4, HLG and PQ HDR are supported.")
            }
        }
        if isHDR {
            guard (bitDepth ?? 0) >= 10, primaries != nil, matrix != nil else {
                throw MediaError.message("Cannot verify the HDR bit depth and color information for this video.")
            }
        }
    }
    public func validatePreservation(in output: VideoColorProfile) throws {
        guard isHDR == output.isHDR else { throw MediaError.message("Export changed the video's dynamic range. No copy was kept.") }
        guard !isHDR || (output.transfer == transfer && output.primaries == primaries && output.matrix == matrix && (output.bitDepth ?? 0) >= 10) else {
            throw MediaError.message("Export did not preserve HDR color information or 10-bit encoding. No copy was kept.")
        }
        guard dolbyProfile == nil || (output.dolbyProfile == dolbyProfile && output.dolbyCompatibility == dolbyCompatibility) else {
            throw MediaError.message("Export lost the Dolby Vision profile. No copy was kept.")
        }
    }
}
