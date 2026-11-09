import XCTest
@testable import DupeFixer

final class BehaviorTests: XCTestCase {
    func testFilenameNormalizationRemovesCopySuffixAndVersion() {
        XCTAssertEqual(FileUtilities.normalizedFilename("Quarterly Report (2).pdf"), "quarterly report")
        XCTAssertEqual(FileUtilities.normalizedFilename("Photo copy.jpg"), "photo")
    }

    func testExactHashEvidenceAlwaysScoresOne() {
        let evidence = AnalysisEvidence(filenameSimilarity: 0, metadataSimilarity: 0, partialHashMatch: false, fullHashMatch: true, textSimilarity: nil, imageSimilarity: nil, aiSimilarity: nil, aiDuplicate: nil, aiRationale: nil, skippedReason: nil)
        XCTAssertEqual(evidence.score, 1.0)
    }

    func testDeletionPlanCanDeleteBothSidesAndDeduplicatesPaths() {
        let left = makeFile(id: 1, path: "/tmp/a.txt", name: "a.txt")
        let right = makeFile(id: 2, path: "/tmp/b.txt", name: "b.txt")
        let evidence = AnalysisEvidence(filenameSimilarity: 1, metadataSimilarity: 1, partialHashMatch: true, fullHashMatch: true, textSimilarity: nil, imageSimilarity: nil, aiSimilarity: nil, aiDuplicate: nil, aiRationale: nil, skippedReason: nil)
        let candidate = DuplicateCandidate(id: 1, left: left, right: right, evidence: evidence, groupID: 1)
        let group = DuplicateGroup(id: 1, candidates: [candidate])
        let applier = DeletionApplier(database: try! SQLiteDatabase(path: temporaryDatabaseURL()))
        let plan = applier.buildPlan(groups: [group], decisions: [ReviewRecord(groupID: 1, decision: .deleteBoth, canonicalPath: nil)])
        XCTAssertEqual(Set(plan.map { $0.file.path }), Set([left.path, right.path]))
    }

    func testCLIOptionsRequireNoAPIForLocalScan() throws {
        let options = try CLIOptions(arguments: ["scan", "--no-ai", "--max-ai-mb", "4"])
        XCTAssertEqual(options.command, .scan)
        XCTAssertEqual(options.mode, .local)
        XCTAssertEqual(options.maxAIBytes, 4 * 1024 * 1024)
    }

    func testCLIOptionsWithoutArgumentsStartLocalScan() throws {
        let options = try CLIOptions(arguments: [])
        XCTAssertEqual(options.command, .scan)
        XCTAssertEqual(options.mode, .local)
        XCTAssertNil(options.databaseURL)
        XCTAssertNil(options.roots)
    }

    func testDefaultDatabaseURLUsesApplicationStateDirectory() {
        let home = URL(fileURLWithPath: "/Users/example")
        XCTAssertEqual(DatabaseLocator.defaultURL(home: home).path, "/Users/example/.local/state/ai-dupe-fixer/dupescan.db")
    }

    func testDatabaseParentDirectoryIsCreatedForFirstRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dupefix-state-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = root.appendingPathComponent("nested/dupescan.db")
        try DatabaseLocator.prepareParentDirectory(for: databaseURL)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.deletingLastPathComponent().path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    private func makeFile(id: Int64, path: String, name: String) -> DiscoveredFile {
        DiscoveredFile(id: id, path: path, relativePath: name, name: name, fileExtension: "txt", size: 10, modifiedAt: Date(timeIntervalSince1970: 1), createdAt: nil, contentType: "public.plain-text", normalizedName: name, isImage: false, isDocument: true, isArchiveOfficeDocument: false, sha256: "hash")
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dupefix-tests-\(UUID().uuidString).sqlite3")
    }
}
