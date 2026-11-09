import Foundation

@main
struct DupeFixerMain {
    static func main() async {
        do {
            let options = try CLIOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            try await run(options)
        } catch {
            fputs("dupefix: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run(_ options: CLIOptions) async throws {
        if options.command == .help {
            print(CLIOptions.usage)
            return
        }

        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL
        let databaseURL = options.databaseURL ?? DatabaseLocator.defaultURL(home: home)
        try DatabaseLocator.prepareParentDirectory(for: databaseURL)
        let database = try SQLiteDatabase(path: databaseURL)

        switch options.command {
        case .scan:
            let aiProvider: (any AIComparisonProvider)?
            if options.mode == .ai {
                aiProvider = try AIProviderResolver.resolve()
            } else {
                aiProvider = nil
            }
            let configuration = ScanConfiguration(home: home, mode: options.mode, maxAIBytes: options.maxAIBytes, roots: options.roots, resume: options.resume)
            print("Scanning approved user folders. This can take time for large files.")
            let output = try await FileScanner(aiProvider: aiProvider).scan(configuration: configuration, database: database)
            let summary = try database.scanSummary(scanID: output.scanID)
            print("Scan complete: \(summary.files) files, \(output.folders.count) folders, \(summary.candidates) high-likelihood candidate pairs, \(summary.junk) conservative junk suggestions.")
            print("Run `dupefix review` to inspect decisions, then `dupefix apply` to move confirmed files to Trash.")
            if !output.junkFindings.isEmpty { print("Run `dupefix junk` to list conservative junk suggestions.") }
        case .review:
            guard let scanID = try database.latestScan() else { print("No scan exists yet. Run `dupefix scan` first."); return }
            try ReviewUI(database: database).run(scanID: scanID)
        case .apply:
            guard let scanID = try database.latestScan() else { print("No scan exists yet. Run `dupefix scan` first."); return }
            try DeletionApplier(database: database).apply(scanID: scanID)
        case .status:
            guard let scanID = try database.latestScan() else { print("No scan exists yet."); return }
            let summary = try database.scanSummary(scanID: scanID)
            print("Latest scan #\(scanID): \(summary.files) files, \(summary.candidates) candidate pairs, \(summary.junk) junk suggestions, \(summary.decisions) review decisions, \(summary.deletions) deletion attempts.")
        case .junk:
            guard let scanID = try database.latestScan() else { print("No scan exists yet. Run `dupefix scan` first."); return }
            let findings = try database.junkFindings(scanID: scanID)
            if findings.isEmpty { print("No conservative junk suggestions found.") }
            else {
                print("Conservative junk suggestions (review manually; not auto-deleted):")
                for finding in findings { print("- \(finding.path) — \(finding.reason) (\(Int(finding.confidence * 100))%)") }
            }
        case .help:
            break
        }
    }
}

struct CLIOptions {
    enum Command: String {
        case scan, review, apply, status, junk, help
    }

    let command: Command
    let mode: AnalysisMode
    let databaseURL: URL?
    let roots: [URL]?
    let maxAIBytes: Int64
    let resume: Bool

    init(arguments: [String]) throws {
        var command: Command = .scan
        var mode: AnalysisMode = .local
        var databaseURL: URL?
        var roots: [URL] = []
        var maxAIBytes: Int64 = 8 * 1024 * 1024
        var resume = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "scan", "review", "apply", "status", "junk", "help":
                guard let parsed = Command(rawValue: argument) else { throw DupeFixerError.unsupported(argument) }
                command = parsed
            case "--ai":
                mode = .ai
            case "--no-ai":
                mode = .local
            case "--resume":
                resume = true
            case "--db":
                index += 1
                guard index < arguments.count else { throw DupeFixerError.unsupported("--db requires a path") }
                databaseURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            case "--root":
                index += 1
                guard index < arguments.count else { throw DupeFixerError.unsupported("--root requires a path") }
                roots.append(URL(fileURLWithPath: arguments[index]).standardizedFileURL)
            case "--max-ai-mb":
                index += 1
                guard index < arguments.count, let value = Int64(arguments[index]), value > 0 else { throw DupeFixerError.unsupported("--max-ai-mb requires a positive integer") }
                maxAIBytes = value * 1024 * 1024
            case "-h", "--help":
                command = .help
            default:
                throw DupeFixerError.unsupported("unknown argument \(argument)")
            }
            index += 1
        }
        self.command = command
        self.mode = mode
        self.databaseURL = databaseURL
        self.roots = roots.isEmpty ? nil : roots
        self.maxAIBytes = maxAIBytes
        self.resume = resume
    }

    static let usage = """
    dupefix — local-first duplicate and safe-junk review for macOS user folders

    Usage:
      dupefix [OPTIONS]
      dupefix scan [OPTIONS]
      dupefix review [--db PATH]
      dupefix apply [--db PATH]
      dupefix status [--db PATH]
      dupefix junk [--db PATH]

    Running `dupefix` with no arguments scans the approved user folders immediately.
    The database is created automatically at $HOME/.local/state/ai-dupe-fixer/dupescan.db.
    Use `--db PATH` only when you want to divert this run to another database.

    Scanning includes visible folders directly under $HOME plus Desktop, Documents,
    Downloads, Pictures, Movies, and Music. Library, hidden paths, escaping
    symlinks, packages, and non-regular files are excluded.

    `--ai` opts into sending eligible extracted text or image previews for AI comparison.
    It uses gpt-5.6-luna with reasoning effort max. OPENAI_API_KEY is preferred;
    when absent, an existing authenticated Codex CLI session is used if available.
    Without `--ai`, all analysis is local.
    """
}
