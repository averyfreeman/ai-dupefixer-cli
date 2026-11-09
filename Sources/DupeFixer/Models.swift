import Foundation

enum AnalysisMode: String {
    case local
    case ai
}

struct ScanConfiguration {
    let home: URL
    let mode: AnalysisMode
    let maxAIBytes: Int64
    let roots: [URL]?
    let resume: Bool
}

struct DiscoveredFolder: Codable, Hashable {
    let path: String
    let relativePath: String
}

struct DiscoveredFile: Codable, Hashable {
    let id: Int64
    let path: String
    let relativePath: String
    let name: String
    let fileExtension: String
    let size: Int64
    let modifiedAt: Date?
    let createdAt: Date?
    let contentType: String
    let normalizedName: String
    let isImage: Bool
    let isDocument: Bool
    let isArchiveOfficeDocument: Bool
    let sha256: String?

    init(id: Int64 = 0, path: String, relativePath: String, name: String, fileExtension: String, size: Int64, modifiedAt: Date?, createdAt: Date?, contentType: String, normalizedName: String, isImage: Bool, isDocument: Bool, isArchiveOfficeDocument: Bool, sha256: String? = nil) {
        self.id = id
        self.path = path
        self.relativePath = relativePath
        self.name = name
        self.fileExtension = fileExtension
        self.size = size
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.contentType = contentType
        self.normalizedName = normalizedName
        self.isImage = isImage
        self.isDocument = isDocument
        self.isArchiveOfficeDocument = isArchiveOfficeDocument
        self.sha256 = sha256
    }

    func withDatabaseID(_ value: Int64) -> DiscoveredFile {
        DiscoveredFile(id: value, path: path, relativePath: relativePath, name: name, fileExtension: fileExtension, size: size, modifiedAt: modifiedAt, createdAt: createdAt, contentType: contentType, normalizedName: normalizedName, isImage: isImage, isDocument: isDocument, isArchiveOfficeDocument: isArchiveOfficeDocument, sha256: sha256)
    }

    func withSHA256(_ value: String?) -> DiscoveredFile {
        DiscoveredFile(id: id, path: path, relativePath: relativePath, name: name, fileExtension: fileExtension, size: size, modifiedAt: modifiedAt, createdAt: createdAt, contentType: contentType, normalizedName: normalizedName, isImage: isImage, isDocument: isDocument, isArchiveOfficeDocument: isArchiveOfficeDocument, sha256: value)
    }
}

struct FileFingerprint: Codable, Hashable {
    var partialSHA256: String?
    var sha256: String?
    var imageDigest: String?
    var extractedText: String?
}

struct JunkFinding: Codable, Hashable, Identifiable {
    let id: Int64
    let file: DiscoveredFile
    let reason: String
    let confidence: Double
}

struct AnalysisEvidence: Codable, Hashable {
    var filenameSimilarity: Double
    var metadataSimilarity: Double
    var partialHashMatch: Bool?
    var fullHashMatch: Bool?
    var textSimilarity: Double?
    var imageSimilarity: Double?
    var aiSimilarity: Double?
    var aiDuplicate: Bool?
    var aiRationale: String?
    var skippedReason: String?

    var score: Double {
        if fullHashMatch == true { return 1.0 }

        var weighted = filenameSimilarity * 0.25 + metadataSimilarity * 0.15
        var totalWeight = 0.40
        if let partialHashMatch {
            weighted += (partialHashMatch ? 1.0 : 0.0) * 0.20
            totalWeight += 0.20
        }
        if let textSimilarity {
            weighted += textSimilarity * 0.20
            totalWeight += 0.20
        }
        if let imageSimilarity {
            weighted += imageSimilarity * 0.20
            totalWeight += 0.20
        }
        if let aiSimilarity {
            weighted += aiSimilarity * 0.25
            totalWeight += 0.25
        }
        var result = min(1.0, max(0.0, weighted / totalWeight))
        if aiDuplicate == true, let aiSimilarity {
            result = max(result, min(0.90, 0.50 + aiSimilarity * 0.40))
        }
        return result
    }
}

struct DuplicateCandidate: Identifiable, Codable, Hashable {
    let id: Int64
    let left: DiscoveredFile
    let right: DiscoveredFile
    let evidence: AnalysisEvidence
    let groupID: Int64

    var score: Double { evidence.score }
}

struct DuplicateGroup: Identifiable, Codable, Hashable {
    let id: Int64
    let candidates: [DuplicateCandidate]

    var files: [DiscoveredFile] {
        var result: [DiscoveredFile] = []
        for candidate in candidates {
            if !result.contains(candidate.left) { result.append(candidate.left) }
            if !result.contains(candidate.right) { result.append(candidate.right) }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var score: Double { candidates.map(\.score).max() ?? 0 }
}

enum ReviewDecision: String, Codable {
    case keepBoth
    case deleteLeft
    case deleteRight
    case deleteBoth
    case deleteGroup
    case keepCanonical
    case deferGroup
}

struct ReviewRecord: Codable {
    let groupID: Int64
    let decision: ReviewDecision
    let canonicalPath: String?
}

struct DeletionResult {
    let path: String
    let movedToTrash: Bool
    let error: String?
}

enum DupeFixerError: LocalizedError {
    case invalidRoot(String)
    case database(String)
    case api(String)
    case invalidResponse(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidRoot(let value): return "Invalid scan root: \(value)"
        case .database(let value): return "Database error: \(value)"
        case .api(let value): return "OpenAI API error: \(value)"
        case .invalidResponse(let value): return "Invalid response: \(value)"
        case .unsupported(let value): return "Unsupported operation: \(value)"
        }
    }
}
