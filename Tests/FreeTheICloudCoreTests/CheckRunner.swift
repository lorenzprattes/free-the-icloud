import Foundation

// Dependency-free checks for Macs with Command Line Tools but no Xcode/XCTest installation.
extension CoreTests {
    func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) { failures.append("\(file):\(line): \(message)") }
    func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { if !value { fail("Expected true", file: file, line: line) } }
    func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { expectTrue(!value, file: file, line: line) }
    func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if a != b { fail("Expected \(a) == \(b)", file: file, line: line) } }
    func expectNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if a == b { fail("Expected unequal values", file: file, line: line) } }
    func expectGreater<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { expectTrue(a > b, file: file, line: line) }
    func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { expectTrue(value == nil, file: file, line: line) }
    func expectNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { expectTrue(value != nil, file: file, line: line) }
    func expectThrows(_ body: @autoclosure () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        do { try body(); fail("Expected an error", file: file, line: line) } catch {}
    }
    func expectNoThrow(_ body: @autoclosure () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        do { try body() } catch { fail(error.localizedDescription, file: file, line: line) }
    }
    func requireValue<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "CoreChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Required value was nil"]) }
        return value
    }
}

@main enum CheckRunner {
    static func main() async {
        let suite = CoreTests()
        let tests: [(String, () async throws -> Void)] = [
            ("Compression preset size separation and history migration", { try await suite.testCompressionPresetSeparation() }),
            ("Single-photo/video deletion scope and guards", { try await suite.testSingleDeletionScopeAndGuards() }),
            ("Photo replacement requires review and approval", { try await suite.testPhotoReplacementReviewAndPolicies() }),
            ("Photo replacement integrity and failed import", { try await suite.testPhotoReplacementIntegrityAndRollback() }),
            ("Photo replacement success and stale original", { try await suite.testPhotoReplacementSuccessAndStaleSource() }),
            ("HDR 1080p downscale and SDR-conversion rejection", { try await suite.testHDRDownscaleAndValidation() }),
            ("HDR and SDR still resizing, highlights, gain maps and barriers", { try await suite.testHDRPhotoResize() }),
            ("HDR video: HLG, PQ, presets, audio and originals", { try await suite.testHDRVideoExports() }),
            ("Operation diagnostics and saved Photos errors", { try await suite.testOperationDiagnostics() }),
            ("Legacy scan discovery without original files", { try await suite.testLegacySourceDiscovery() }),
            ("Saved scan progress across store reopening", { try await suite.testSavedSourceProgressAndEmptyCatalog() }),
            ("Export error persistence and underlying cause", { try await suite.testExportFailurePersistence() }),
            ("Deletion selection, keepers and protected items", { try suite.testDeletionSelectionGuards() }),
            ("Deletion policies and stale library failure", { try await suite.testDeletionPoliciesAndFailure() }),
            ("Deletion success and record-write barrier", { try await suite.testDeletionSuccessAndRecordFailure() }),
            ("Replacement eligibility and approval", { try await suite.testReplacementEligibility() }),
            ("Replacement integrity and failed import", { try await suite.testReplacementIntegrityAndRollback() }),
            ("Replacement success and missing original", { try await suite.testReplacementSuccessAndStaleSource() }),
            ("Filters, locale, sorting and video scope", { suite.testFilters() }),
            ("Review migration and stale decisions", { try await suite.testReviewVersions() }),
            ("Incremental scan, cancellation and resume", { try await suite.testIncrementalScanAndResume() }),
            ("Balanced encoding, portrait, audio, six-second sample and history", { try await suite.testBalancedVideoAndHistory() }),
            ("Low disk, in-flight cancellation and same-size content change", { try await suite.testExportFailureCleanup() }),
            ("No-saving export, Photos boundary and approval", { try await suite.testNoSavingsAndBoundaries() }),
            ("EXIF orientation and inspection preview", { try await suite.testImageOrientation() }),
            ("4K to 1080p export", { try await suite.test1080Downscale() }),
            ("Dry-run and approval barriers", { suite.testDryRunAndApprovalAreIndependentBarriers() }),
            ("Dry-run export has no side effects", { try await suite.testDryRunExportDoesNotCreateFiles() }),
            ("Dry-run album never reaches PhotoKit", { await suite.testDryRunAlbumStopsBeforePhotoKitAccess() }),
            ("Exact duplicates ignore dates", { try suite.testExactDuplicatesIgnoreCaptureDate() }),
            ("Complete original resource sets", { try suite.testDifferentResourceSetsAreNotExactDuplicates() }),
            ("No transitive similarity chains", { try suite.testAnchoredGroupingDoesNotJoinTransitiveChain() }),
            ("Date windows and missing dates", { try suite.testTimeWindowAndMissingDates() }),
            ("Metric-index recall", { suite.testMetricIndexFindsExpectedNeighbors() }),
            ("SQLite and review persistence", { try await suite.testCatalogPersistsOptionalSizesAndDecisions() }),
            ("Generated image decoding and hashing", { try suite.testGeneratedImagesDecodeAndHash() }),
            ("Folder boundaries and cache invalidation", { try await suite.testFolderScanSkipsSymlinksAndLibraryBundlesAndRevalidates() }),
            ("Corrupt image handling", { try await suite.testCorruptImageIsReportedWithoutStoppingScan() }),
            ("10,000-record grouping benchmark", { try suite.testTenThousandItemCatalogGrouping() }),
            ("Real video encode, audio, cancellation, and source preservation", { try await suite.testGeneratedVideoExportsAndPreservesOriginal() }),
            ("Unsupported high-frame-rate video", { try await suite.testHighFrameRateIsExcluded() })
        ]
        for (name, test) in tests {
            let before = suite.failures.count
            do { try await test() } catch { suite.fail("\(name): \(error.localizedDescription)") }
            print("\(suite.failures.count == before ? "PASS" : "FAIL")  \(name)")
        }
        for failure in suite.failures { print(failure) }
        print("\(tests.count) checks; \(suite.failures.count) failures. Only generated fixtures were used.")
        if !suite.failures.isEmpty { exit(1) }
    }
}
