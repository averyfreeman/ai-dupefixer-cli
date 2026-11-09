import Foundation

enum FileUtilities {
    static let standardFolderNames = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]

    static func normalizedFilename(_ name: String) -> String {
        let withoutExtension = (name as NSString).deletingPathExtension
        let normalized = withoutExtension.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let copySuffixes = [" copy", "- copy", "_copy", " (copy)"]
        var result = normalized
        for suffix in copySuffixes where result.hasSuffix(suffix) {
            result = String(result.dropLast(suffix.count))
        }
        result = result.replacingOccurrences(of: #"[\s_-]+(\([0-9]+\)|v[0-9]+|[0-9]+)$"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedExtension(_ url: URL) -> String {
        url.pathExtension.lowercased()
    }

    static func isHiddenPath(_ path: String) -> Bool {
        path.split(separator: "/").contains { component in
            component.hasPrefix(".") && component != "."
        }
    }

    static func isDescendant(_ path: String, of root: String) -> Bool {
        let rootPath = root.hasSuffix("/") ? root : root + "/"
        return path == root || path.hasPrefix(rootPath)
    }

    static func relativePath(_ url: URL, from home: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        guard isDescendant(path, of: homePath) else { return url.lastPathComponent }
        return String(path.dropFirst(homePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func contentType(for url: URL) -> String {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.identifier
        }
        return normalizedExtension(url)
    }

    static func isImage(_ type: String, extension fileExtension: String) -> Bool {
        type.hasPrefix("public.image") || ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"].contains(fileExtension)
    }

    static func isDocument(_ type: String, extension fileExtension: String) -> Bool {
        type.hasPrefix("com.adobe.pdf") || type.hasPrefix("public.text") || ["pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "rtf", "txt", "md"].contains(fileExtension)
    }

    static func isOfficeArchive(_ fileExtension: String) -> Bool {
        ["docx", "pptx", "xlsx"].contains(fileExtension)
    }

    static func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func formatDate(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension String {
    func levenshteinSimilarity(to other: String) -> Double {
        let lhs = Array(self)
        let rhs = Array(other)
        if lhs.isEmpty && rhs.isEmpty { return 1 }
        if lhs.isEmpty || rhs.isEmpty { return 0 }
        var previous = Array(0...rhs.count)
        for (i, leftCharacter) in lhs.enumerated() {
            var current = [i + 1]
            for (j, rightCharacter) in rhs.enumerated() {
                let cost = leftCharacter == rightCharacter ? 0 : 1
                current.append(Swift.min(current[j] + 1, previous[j + 1] + 1, previous[j] + cost))
            }
            previous = current
        }
        let distance = Double(previous[rhs.count])
        return max(0, 1 - distance / Double(max(lhs.count, rhs.count)))
    }
}
