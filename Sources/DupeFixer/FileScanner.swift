import Foundation
import CryptoKit

struct ScanOutput {
    let scanID: Int64
    let folders: [DiscoveredFolder]
    let files: [DiscoveredFile]
    let candidates: [DuplicateCandidate]
    let junkFindings: [JunkFinding]
}

final class FileScanner {
    private let fileManager = FileManager.default
    private let contentAnalyzer = LocalContentAnalyzer()
    private let aiProvider: (any AIComparisonProvider)?

    init(aiProvider: (any AIComparisonProvider)? = nil) {
        self.aiProvider = aiProvider
    }

    func scan(configuration: ScanConfiguration, database: SQLiteDatabase) async throws -> ScanOutput {
        let roots = try approvedRoots(configuration.home, requestedRoots: configuration.roots)
        let scanID = try database.startScan(mode: configuration.mode, resume: configuration.resume)

        do {
            let discovered = discover(roots: roots, home: configuration.home)
            if configuration.resume { try database.resetScanContents(scanID: scanID) }
            for folder in discovered.folders {
                try database.saveFolder(folder, scanID: scanID)
            }

            var files: [DiscoveredFile] = []
            files.reserveCapacity(discovered.files.count)
            for file in discovered.files {
                let id = try database.saveFile(file, scanID: scanID)
                files.append(file.withDatabaseID(id))
            }

            let candidates = try await analyze(files: files, scanID: scanID, configuration: configuration, database: database)
            let junkFindings = try JunkDetector().find(in: files, scanID: scanID, database: database)
            try database.finishScan(scanID, status: "completed")
            return ScanOutput(scanID: scanID, folders: discovered.folders, files: files, candidates: candidates, junkFindings: junkFindings)
        } catch {
            try? database.finishScan(scanID, status: "failed")
            throw error
        }
    }

    private func approvedRoots(_ home: URL, requestedRoots: [URL]?) throws -> [URL] {
        let resolvedHome = home.resolvingSymlinksInPath().standardizedFileURL
        if let requestedRoots {
            let roots = requestedRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
            guard !roots.isEmpty, roots.allSatisfy({ isSafeDirectory($0, within: resolvedHome) }) else {
                throw DupeFixerError.invalidRoot("custom roots must be existing non-hidden directories inside $HOME and outside Library")
            }
            return Array(Set(roots)).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        var roots: [URL] = []
        let entries = try fileManager.contentsOfDirectory(at: resolvedHome, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        for entry in entries where isSafeDirectory(entry, within: resolvedHome) {
            let name = entry.lastPathComponent
            if name == "Library" { continue }
            roots.append(entry.standardizedFileURL)
        }

        let standardRoots = FileUtilities.standardFolderNames.map { resolvedHome.appendingPathComponent($0, isDirectory: true).standardizedFileURL }
        for root in standardRoots where fileManager.fileExists(atPath: root.path) && !roots.contains(root) {
            roots.append(root)
        }
        return roots.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func discover(roots: [URL], home: URL) -> (folders: [DiscoveredFolder], files: [DiscoveredFile]) {
        let resolvedHome = home.resolvingSymlinksInPath().standardizedFileURL
        var folderURLs: Set<String> = []
        var fileURLs: Set<String> = []

        for root in roots {
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            guard FileUtilities.isDescendant(rootPath, of: resolvedHome.path), !FileUtilities.isHiddenPath(rootPath) else { continue }
            folderURLs.insert(rootPath)
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey, .creationDateKey]
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }

            for case let url as URL in enumerator {
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                guard FileUtilities.isDescendant(resolved.path, of: resolvedHome.path), !FileUtilities.isHiddenPath(resolved.path) else {
                    if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                if values.isDirectory == true {
                    folderURLs.insert(resolved.path)
                } else if values.isRegularFile == true {
                    fileURLs.insert(resolved.path)
                }
            }
        }

        let folders = folderURLs.sorted().map { path in
            DiscoveredFolder(path: path, relativePath: FileUtilities.relativePath(URL(fileURLWithPath: path), from: resolvedHome))
        }
        let files = fileURLs.sorted().compactMap { path -> DiscoveredFile? in
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .contentModificationDateKey, .creationDateKey]), let size = values.fileSize else { return nil }
            let fileExtension = FileUtilities.normalizedExtension(url)
            let contentType = FileUtilities.contentType(for: url)
            return DiscoveredFile(
                path: path,
                relativePath: FileUtilities.relativePath(url, from: resolvedHome),
                name: url.lastPathComponent,
                fileExtension: fileExtension,
                size: Int64(size),
                modifiedAt: values.contentModificationDate,
                createdAt: values.creationDate,
                contentType: contentType,
                normalizedName: FileUtilities.normalizedFilename(url.lastPathComponent),
                isImage: FileUtilities.isImage(contentType, extension: fileExtension),
                isDocument: FileUtilities.isDocument(contentType, extension: fileExtension),
                isArchiveOfficeDocument: FileUtilities.isOfficeArchive(fileExtension)
            )
        }
        return (folders, files)
    }

    private func isSafeDirectory(_ url: URL, within home: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey])
        let libraryPath = home.appendingPathComponent("Library", isDirectory: true).standardizedFileURL.path
        return values?.isDirectory == true && resolved.path != home.path && FileUtilities.isDescendant(resolved.path, of: home.path) && !FileUtilities.isDescendant(resolved.path, of: libraryPath) && !FileUtilities.isHiddenPath(resolved.path)
    }

    private func analyze(files: [DiscoveredFile], scanID: Int64, configuration: ScanConfiguration, database: SQLiteDatabase) async throws -> [DuplicateCandidate] {
        let pairs = candidatePairs(files)
        var fingerprints: [Int64: FileFingerprint] = [:]
        var candidates: [DuplicateCandidate] = []
        var groupIndex = DisjointSet(count: files.count)

        for (leftIndex, rightIndex) in pairs {
            let left = files[leftIndex]
            let right = files[rightIndex]
            var evidence = metadataEvidence(left: left, right: right)
            guard let leftFingerprint = try? fingerprint(for: left, cache: &fingerprints, database: database), let rightFingerprint = try? fingerprint(for: right, cache: &fingerprints, database: database) else { continue }
            evidence.partialHashMatch = leftFingerprint.partialSHA256 != nil && leftFingerprint.partialSHA256 == rightFingerprint.partialSHA256
            evidence.fullHashMatch = leftFingerprint.sha256 != nil && leftFingerprint.sha256 == rightFingerprint.sha256

            if evidence.fullHashMatch != true && evidence.score >= 0.25 && contentAnalyzer.isEligible(left) && contentAnalyzer.isEligible(right) {
                do {
                    let leftContent = try contentAnalyzer.analyze(left)
                    let rightContent = try contentAnalyzer.analyze(right)
                    fingerprints[left.id] = merge(fingerprints[left.id], leftContent)
                    fingerprints[right.id] = merge(fingerprints[right.id], rightContent)
                    try database.updateFingerprint(fingerprints[left.id] ?? leftContent, fileID: left.id)
                    try database.updateFingerprint(fingerprints[right.id] ?? rightContent, fileID: right.id)
                    evidence.textSimilarity = textSimilarity(leftContent.extractedText, rightContent.extractedText)
                    evidence.imageSimilarity = imageSimilarity(leftContent.imageDigest, rightContent.imageDigest)

                    if configuration.mode == .ai && evidence.score >= 0.35 && left.size <= configuration.maxAIBytes && right.size <= configuration.maxAIBytes {
                        do {
                            guard let aiProvider else { throw DupeFixerError.api("no AI comparison provider is available") }
                            let aiResult = try await aiProvider.compare(left: left, right: right, leftFingerprint: fingerprints[left.id] ?? leftContent, rightFingerprint: fingerprints[right.id] ?? rightContent)
                            evidence.aiSimilarity = aiResult.similarity
                            evidence.aiDuplicate = aiResult.duplicate
                            evidence.aiRationale = aiResult.rationale
                        } catch {
                            evidence.skippedReason = "AI unavailable: \(error.localizedDescription)"
                        }
                    }
                } catch {
                    evidence.skippedReason = "local content skipped: \(error.localizedDescription)"
                }
            }

            guard evidence.score >= 0.70 || evidence.fullHashMatch == true else { continue }
            groupIndex.union(leftIndex, rightIndex)
            let candidate = DuplicateCandidate(id: Int64(candidates.count + 1), left: left.withSHA256(leftFingerprint.sha256), right: right.withSHA256(rightFingerprint.sha256), evidence: evidence, groupID: 0)
            candidates.append(candidate)
        }

        let groupIDs = Dictionary(grouping: candidates.indices) { index in
            let leftIndex = files.firstIndex { $0.id == candidates[index].left.id } ?? 0
            return groupIndex.find(leftIndex)
        }
        var nextGroupID: Int64 = 1
        var result: [DuplicateCandidate] = []
        for indexes in groupIDs.values.sorted(by: { ($0.first ?? 0) < ($1.first ?? 0) }) {
            for index in indexes {
                let original = candidates[index]
                let updated = DuplicateCandidate(id: original.id, left: original.left, right: original.right, evidence: original.evidence, groupID: nextGroupID)
                result.append(updated)
                try database.saveCandidate(updated, scanID: scanID)
            }
            nextGroupID += 1
        }
        return result.sorted { $0.score > $1.score }
    }

    private func candidatePairs(_ files: [DiscoveredFile]) -> [(Int, Int)] {
        var keys: [String: [Int]] = [:]
        for (index, file) in files.enumerated() {
            let sizeKey = "size:\(file.size)"
            let nameKey = "name:\(file.normalizedName):\(file.fileExtension)"
            keys[sizeKey, default: []].append(index)
            keys[nameKey, default: []].append(index)
        }

        var pairs: Set<String> = []
        for indexes in keys.values {
            let limited = indexes.count > 200 ? indexes.filter { files[$0].normalizedName == files[indexes[0]].normalizedName || files[$0].fileExtension == files[indexes[0]].fileExtension } : indexes
            for leftOffset in 0..<limited.count {
                for rightOffset in (leftOffset + 1)..<limited.count {
                    let left = limited[leftOffset]
                    let right = limited[rightOffset]
                    pairs.insert("\(min(left, right))-\(max(left, right))")
                }
            }
        }
        return pairs.compactMap { value in
            let pieces = value.split(separator: "-").compactMap { Int($0) }
            guard pieces.count == 2 else { return nil }
            return (pieces[0], pieces[1])
        }
    }

    private func metadataEvidence(left: DiscoveredFile, right: DiscoveredFile) -> AnalysisEvidence {
        let nameScore = left.normalizedName.levenshteinSimilarity(to: right.normalizedName)
        let sizeScore: Double
        if left.size == right.size {
            sizeScore = 1
        } else {
            sizeScore = max(0, 1 - Double(abs(left.size - right.size)) / Double(max(left.size, right.size, 1)))
        }
        let extensionScore = left.fileExtension == right.fileExtension ? 1.0 : 0.0
        let locationScore = left.relativePath.split(separator: "/").dropLast().first == right.relativePath.split(separator: "/").dropLast().first ? 1.0 : 0.0
        return AnalysisEvidence(filenameSimilarity: nameScore, metadataSimilarity: sizeScore * 0.55 + extensionScore * 0.30 + locationScore * 0.15, partialHashMatch: nil, fullHashMatch: nil, textSimilarity: nil, imageSimilarity: nil, aiSimilarity: nil, aiDuplicate: nil, aiRationale: nil, skippedReason: nil)
    }

    private func fingerprint(for file: DiscoveredFile, cache: inout [Int64: FileFingerprint], database: SQLiteDatabase) throws -> FileFingerprint {
        if let cached = cache[file.id] { return cached }
        let result = FileFingerprint(partialSHA256: try SHA256Hasher.hash(file: URL(fileURLWithPath: file.path), partial: true), sha256: try SHA256Hasher.hash(file: URL(fileURLWithPath: file.path), partial: false), imageDigest: nil, extractedText: nil)
        cache[file.id] = result
        try database.updateFingerprint(result, fileID: file.id)
        return result
    }

    private func merge(_ existing: FileFingerprint?, _ new: FileFingerprint) -> FileFingerprint {
        FileFingerprint(partialSHA256: existing?.partialSHA256 ?? new.partialSHA256, sha256: existing?.sha256 ?? new.sha256, imageDigest: new.imageDigest ?? existing?.imageDigest, extractedText: new.extractedText ?? existing?.extractedText)
    }

    private func textSimilarity(_ left: String?, _ right: String?) -> Double? {
        guard let left, let right, !left.isEmpty, !right.isEmpty else { return nil }
        let lhs = Set(left.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let rhs = Set(right.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard !lhs.isEmpty || !rhs.isEmpty else { return nil }
        return Double(lhs.intersection(rhs).count) / Double(lhs.union(rhs).count)
    }

    private func imageSimilarity(_ left: String?, _ right: String?) -> Double? {
        guard let left, let right, left.count == right.count else { return nil }
        let lhs = Array(left)
        let rhs = Array(right)
        let different = zip(lhs, rhs).filter { $0 != $1 }.count
        return 1 - Double(different) / Double(max(lhs.count, 1))
    }
}

private struct DisjointSet {
    private var parents: [Int]

    init(count: Int) { parents = Array(0..<count) }

    mutating func find(_ value: Int) -> Int {
        if parents[value] != value { parents[value] = find(parents[value]) }
        return parents[value]
    }

    mutating func union(_ left: Int, _ right: Int) {
        let leftRoot = find(left)
        let rightRoot = find(right)
        if leftRoot != rightRoot { parents[rightRoot] = leftRoot }
    }
}

enum SHA256Hasher {
    static func hash(file url: URL, partial: Bool) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        var hasher = SHA256()
        let sampleSize = 64 * 1024
        if partial {
            hasher.update(data: handle.readData(ofLength: sampleSize))
            if size > sampleSize {
                try handle.seek(toOffset: UInt64(Swift.max(Int64(0), size - Int64(sampleSize))))
                hasher.update(data: handle.readData(ofLength: sampleSize))
            }
        } else {
            while true {
                let data = handle.readData(ofLength: 1024 * 1024)
                if data.isEmpty { break }
                hasher.update(data: data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
