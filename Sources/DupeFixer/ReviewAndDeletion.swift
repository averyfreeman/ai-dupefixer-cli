import Foundation

final class ReviewUI {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    func run(scanID: Int64) throws {
        let groups = try database.loadGroups(scanID: scanID)
        guard !groups.isEmpty else {
            print("No high-likelihood duplicate groups found.")
            return
        }
        let existing = try Set(database.decisions(scanID: scanID).map(\.groupID))
        var reviewed = existing
        var index = 0

        while index < groups.count {
            let group = groups[index]
            render(group: group, index: index, total: groups.count, reviewed: reviewed.contains(group.id))
            guard let rawCommand = readLine(prompt: "dupefix> ") else { break }
            let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if command == "q" || command == "quit" { break }
            if command == "?" || command == "help" {
                printHelp()
                continue
            }
            if command == "back" || command == "bck" {
                index = max(0, index - 1)
                continue
            }
            if command == "next" || command == "n" {
                try save(.init(groupID: group.id, decision: .deferGroup, canonicalPath: nil), scanID: scanID, reviewed: &reviewed)
                index += 1
                continue
            }

            switch command {
            case "l" where group.files.count == 2:
                try save(.init(groupID: group.id, decision: .deleteLeft, canonicalPath: nil), scanID: scanID, reviewed: &reviewed)
            case "r" where group.files.count == 2:
                try save(.init(groupID: group.id, decision: .deleteRight, canonicalPath: nil), scanID: scanID, reviewed: &reviewed)
            case "both" where group.files.count == 2, "b" where group.files.count == 2:
                try save(.init(groupID: group.id, decision: .deleteBoth, canonicalPath: nil), scanID: scanID, reviewed: &reviewed)
            case "keep", "k":
                try save(.init(groupID: group.id, decision: .keepBoth, canonicalPath: nil), scanID: scanID, reviewed: &reviewed)
            case "group", "g":
                try save(.init(groupID: group.id, decision: .deleteGroup, canonicalPath: nil), scanID: scanID, reviewed: &reviewed)
            case "canonical", "c":
                guard let selected = chooseCanonical(group.files) else { continue }
                try save(.init(groupID: group.id, decision: .keepCanonical, canonicalPath: selected.path), scanID: scanID, reviewed: &reviewed)
            case "defer", "d":
                try save(.init(groupID: group.id, decision: .deferGroup, canonicalPath: nil), scanID: scanID, reviewed: &reviewed)
            default:
                print("Unknown action for this group. Type ? for help.")
                continue
            }
            index += 1
        }
        print("Saved \(reviewed.count) review decisions. Run `dupefix apply` after checking the plan.")
    }

    private func save(_ record: ReviewRecord, scanID: Int64, reviewed: inout Set<Int64>) throws {
        try database.saveDecision(record, scanID: scanID)
        reviewed.insert(record.groupID)
    }

    private func render(group: DuplicateGroup, index: Int, total: Int, reviewed: Bool) {
        print("\u{001B}[2J\u{001B}[H", terminator: "")
        print("Duplicate group \(index + 1)/\(total)  confidence \(Int(group.score * 100))%\(reviewed ? "  [already reviewed]" : "")")
        print(String(repeating: "─", count: 78))
        for (fileIndex, file) in group.files.enumerated() {
            print("[\(fileIndex + 1)] \(file.relativePath)")
            print("    \(file.contentType)  \(FileUtilities.formatBytes(file.size))  modified \(FileUtilities.formatDate(file.modifiedAt))")
        }
        print("")
        for (candidateIndex, candidate) in group.candidates.enumerated() {
            print("Evidence \(candidateIndex + 1): \(Int(candidate.score * 100))% — \(evidenceSummary(candidate.evidence))")
        }
        print("")
        print("l delete first | r delete second | b delete both | k keep both")
        print("c choose canonical and delete the rest | g delete entire group | d defer | n next | q quit | ? help")
        if group.files.count > 2 { print("This group has more than two files; use c, g, k, or d.") }
    }

    private func evidenceSummary(_ evidence: AnalysisEvidence) -> String {
        var parts = ["name \(Int(evidence.filenameSimilarity * 100))%", "metadata \(Int(evidence.metadataSimilarity * 100))%"]
        if evidence.fullHashMatch == true { parts.append("exact SHA-256") }
        else if evidence.partialHashMatch == true { parts.append("partial hash") }
        if let text = evidence.textSimilarity { parts.append("text \(Int(text * 100))%") }
        if let image = evidence.imageSimilarity { parts.append("image \(Int(image * 100))%") }
        if let ai = evidence.aiSimilarity { parts.append("AI \(Int(ai * 100))%") }
        return parts.joined(separator: ", ")
    }

    private func chooseCanonical(_ files: [DiscoveredFile]) -> DiscoveredFile? {
        print("Choose the file to keep:")
        for (index, file) in files.enumerated() {
            print("  \(index + 1): \(file.relativePath)")
        }
        guard let value = readLine(prompt: "keep number> "), let index = Int(value), files.indices.contains(index - 1) else {
            print("No canonical file selected.")
            return nil
        }
        return files[index - 1]
    }

    private func printHelp() {
        print("l/r delete one side of a two-file group; b delete both; k keep all; c choose survivor; g delete group; d defer; n next; q quit")
    }

    private func readLine(prompt: String) -> String? {
        print(prompt, terminator: "")
        fflush(stdout)
        return Swift.readLine()
    }
}

struct PlannedDeletion {
    let groupID: Int64
    let file: DiscoveredFile
}

final class DeletionApplier {
    private let database: SQLiteDatabase
    private let fileManager = FileManager.default

    init(database: SQLiteDatabase) {
        self.database = database
    }

    func apply(scanID: Int64) throws {
        let groups = try database.loadGroups(scanID: scanID)
        let decisions = try database.decisions(scanID: scanID)
        let plan = buildPlan(groups: groups, decisions: decisions)
        guard !plan.isEmpty else {
            print("No files are selected for deletion.")
            return
        }

        print("The following \(plan.count) file(s) will be moved to Trash:")
        for item in plan { print("- \(item.file.relativePath) (\(FileUtilities.formatBytes(item.file.size)))") }
        let total = plan.reduce(Int64(0)) { $0 + $1.file.size }
        print("Total: \(FileUtilities.formatBytes(total))")
        print("Type DELETE to confirm: ", terminator: "")
        fflush(stdout)
        guard Swift.readLine() == "DELETE" else {
            print("No changes made.")
            return
        }

        var successCount = 0
        for item in plan {
            let result = moveToTrash(item.file)
            try database.recordDeletion(scanID: scanID, groupID: item.groupID, path: item.file.path, originalSHA256: item.file.sha256, result: result)
            if result.movedToTrash { successCount += 1; print("Trashed \(item.file.relativePath)") }
            else { print("Skipped \(item.file.relativePath): \(result.error ?? "unknown error")") }
        }
        print("Moved \(successCount)/\(plan.count) file(s) to Trash.")
    }

    func buildPlan(groups: [DuplicateGroup], decisions: [ReviewRecord]) -> [PlannedDeletion] {
        var plan: [PlannedDeletion] = []
        for decision in decisions {
            guard let group = groups.first(where: { $0.id == decision.groupID }) else { continue }
            switch decision.decision {
            case .deleteLeft:
                if let file = group.files.first { plan.append(.init(groupID: group.id, file: file)) }
            case .deleteRight:
                if group.files.count > 1 { plan.append(.init(groupID: group.id, file: group.files[1])) }
            case .deleteBoth:
                guard group.files.count > 1 else { continue }
                plan.append(.init(groupID: group.id, file: group.files[0]))
                plan.append(.init(groupID: group.id, file: group.files[1]))
            case .deleteGroup:
                plan.append(contentsOf: group.files.map { PlannedDeletion(groupID: group.id, file: $0) })
            case .keepCanonical:
                plan.append(contentsOf: group.files.filter { $0.path != decision.canonicalPath }.map { PlannedDeletion(groupID: group.id, file: $0) })
            case .keepBoth, .deferGroup:
                break
            }
        }
        var unique: [String: PlannedDeletion] = [:]
        for item in plan { unique[item.file.path] = item }
        return unique.values.sorted { $0.file.path.localizedStandardCompare($1.file.path) == .orderedAscending }
    }

    private func moveToTrash(_ file: DiscoveredFile) -> DeletionResult {
        let url = URL(fileURLWithPath: file.path)
        guard fileManager.fileExists(atPath: file.path) else { return DeletionResult(path: file.path, movedToTrash: false, error: "file no longer exists") }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return DeletionResult(path: file.path, movedToTrash: false, error: "unable to read current metadata")
        }
        let dateMatches: Bool = {
            guard let current = values.contentModificationDate, let reviewed = file.modifiedAt else { return values.contentModificationDate == file.modifiedAt }
            return abs(current.timeIntervalSince(reviewed)) < 0.01
        }()
        guard values.fileSize.map(Int64.init) == file.size, dateMatches else {
            return DeletionResult(path: file.path, movedToTrash: false, error: "file changed since review")
        }
        if let expectedHash = file.sha256, let currentHash = try? SHA256Hasher.hash(file: url, partial: false), expectedHash != currentHash {
            return DeletionResult(path: file.path, movedToTrash: false, error: "SHA-256 changed since review")
        }
        do {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
            return DeletionResult(path: file.path, movedToTrash: true, error: nil)
        } catch {
            return DeletionResult(path: file.path, movedToTrash: false, error: error.localizedDescription)
        }
    }
}
