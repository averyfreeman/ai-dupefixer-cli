import Foundation

final class JunkDetector {
    private let temporaryExtensions: Set<String> = ["tmp", "temp", "bak", "crdownload", "download", "part", "swp"]
    private let installerExtensions: Set<String> = ["dmg", "pkg", "zip", "tar", "gz", "tgz", "rar"]

    func find(in files: [DiscoveredFile], scanID: Int64, database: SQLiteDatabase) throws -> [JunkFinding] {
        var findings: [JunkFinding] = []
        for file in files {
            var reason: String?
            var confidence = 0.0
            if file.size == 0 && ![".gitkeep", ".keep", ".placeholder"].contains(file.name.lowercased()) {
                reason = "empty user file"
                confidence = 0.78
            } else if temporaryExtensions.contains(file.fileExtension) || file.name.hasPrefix("~$") {
                reason = "temporary or interrupted-download artifact"
                confidence = 0.72
            } else if file.relativePath.split(separator: "/").first == "Downloads" && installerExtensions.contains(file.fileExtension) {
                reason = "installer or archive remaining in Downloads"
                confidence = 0.60
            }
            guard let reason else { continue }
            let finding = JunkFinding(id: Int64(findings.count + 1), file: file, reason: reason, confidence: confidence)
            findings.append(finding)
            try database.saveJunkFinding(finding, scanID: scanID)
        }
        return findings
    }
}
