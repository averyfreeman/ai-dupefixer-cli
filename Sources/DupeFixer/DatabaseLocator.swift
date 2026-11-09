import Foundation

enum DatabaseLocator {
    static func defaultURL(home: URL) -> URL {
        home.appendingPathComponent(".local/state/ai-dupe-fixer/dupescan.db", isDirectory: false)
    }

    static func prepareParentDirectory(for databaseURL: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
}
