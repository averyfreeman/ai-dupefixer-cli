# Swift macOS Duplicate and Junk Scanner

## Summary

Build a Swift 6.4 SwiftPM terminal application that scans only user-facing folders under `$HOME`, identifies likely duplicates through progressively stronger local and AI-assisted evidence, presents an interactive terminal review queue, and moves confirmed selections to the macOS Trash.

The application will use SQLite for durable scan state, file metadata, hashes, similarity evidence, review decisions, and deletion records. Optional `sqlite-vec` support will provide semantic nearest-neighbor search for deep-analysis results, while exact/hash matching remains fully functional without vectors.

OpenAI deep scrutiny will use the exact model `gpt-5.6-luna` with `reasoning.effort=max`. The model supports text and image input, structured outputs, embeddings, and maximum reasoning effort. See the [GPT-5.6 Luna model documentation](https://developers.openai.com/api/docs/models/gpt-5.6-luna) and [Responses API reference](https://developers.openai.com/api/reference/cli/resources/responses/methods/create).

## Key Changes and Architecture

- Create a SwiftPM executable package with modules for filesystem discovery, path safety, SQLite persistence, staged duplicate analysis, OpenAI integration, terminal review, and Trash operations.
- Scan these roots by default:
  - `$HOME/Desktop`
  - `$HOME/Documents`
  - `$HOME/Downloads`
  - `$HOME/Pictures`
  - `$HOME/Movies`
  - `$HOME/Music`
  - visible user-created directories directly under `$HOME`
- Exclude `$HOME/Library`, hidden path components, system paths outside the resolved `$HOME` boundary, symlinks escaping approved roots, unreadable/non-regular filesystem entries, and application bundles/packages.
- Persist folders before files, then analyze incrementally so interrupted scans can resume.
- Use staged evidence:
  1. normalized filename, extension, size, parent folder, timestamps, and metadata similarity;
  2. sampled/partial hashes followed by streaming SHA-256;
  3. format-specific extraction for PDFs, DOCX, PPTX, XLSX, text, and supported images;
  4. local OCR, perceptual image comparison, and optional OpenAI semantic comparison.
- Route analysis by file type. Image analysis is limited to recognized image UTIs/extensions; document extraction/OCR is limited to eligible document formats and rendered document pages.
- Persist each evidence component separately. Exact hashes take precedence over model output; AI evidence may increase confidence but cannot override contradictory exact-hash or file-type evidence.
- Define safe user junk conservatively as recognizable temporary/editor artifacts, empty user files, and installer/archive remnants in Downloads. Unknown files, caches, stale files, system-managed files, and application-support data are not automatically classified as junk.

## Public Interfaces and Data Model

- CLI commands:
  - `dupefix scan [--ai] [--resume] [--root PATH ...] [--db PATH] [--max-ai-mb N] [--sqlite-vec PATH]`
  - `dupefix review [--db PATH]`
  - `dupefix apply [--db PATH]`
  - `dupefix status [--db PATH]`
  - `dupefix junk [--db PATH]`
- Core types include `ScanRoot`, `DiscoveredFolder`, `DiscoveredFile`, `FileFingerprint`, `AnalysisEvidence`, `DuplicateCandidate`, `DuplicateGroup`, `ReviewDecision`, `DeletionPlan`, and `DeletionResult`.
- Review decisions support keep both, delete the first file, delete the second file, delete both, defer, delete the entire group, and choose one canonical survivor while deleting the remaining group members.
- The terminal UI shows paths, file type, size, modified date, confidence, evidence, AI rationale, and recommended survivor for each group.
- Store scans, folders, files, candidates, evidence, decisions, junk findings, vector-index state, and deletion results in SQLite.
- Use `OPENAI_API_KEY` for standalone API access. Do not attempt to reuse Codex OAuth tokens or browser login state because those are not established as valid credentials for the standalone API client.

## Deletion Safety

- Move selected files to the macOS Trash using the native filesystem API.
- Never permanently unlink files in v1.
- Require a final confirmation showing every selected path and total size.
- Before moving each file, verify that it still exists, remains inside the approved roots, has the reviewed size/modification timestamp, and matches the reviewed SHA-256 when available.
- Record the original path, expected hash, Trash result, timestamp, and any error in SQLite.

## Test Plan and Acceptance Criteria

- Verify approved roots, hidden paths, `$HOME/Library`, escaping symlinks, packages, and unreadable entries.
- Verify folder-first persistence, file discovery, Unicode/copy-suffix filename normalization, partial hashing, full SHA-256 equality, and changed-file detection.
- Verify correct routing for images, PDFs, DOCX, PPTX, XLSX, unsupported files, encrypted files, and corrupt files.
- Verify `--no-ai` performs no network requests and `--ai` targets `gpt-5.6-luna` with `reasoning.effort=max` and structured output.
- Verify API timeouts, rate limits, malformed responses, missing keys, and local extractor failures degrade to explicit evidence notes instead of aborting the scan.
- Verify scan resume, persisted review decisions, pair-level actions, group-level actions, final confirmation, Trash movement, and refusal to move changed/missing files.
- Acceptance requires that a user can scan personal folders, inspect why a group was flagged, revise deletion choices interactively, resume later, and move only confirmed files to Trash.

## Assumptions and Defaults

- The repository starts as a new SwiftPM executable targeting macOS 13+ and Swift 6.4.
- SQLite is the required baseline store; sqlite-vec is optional and capability-detected.
- Deep AI analysis is opt-in. Metadata, hashing, local extraction, OCR, and perceptual image checks are local by default.
- The requested model name and maximum reasoning level are preserved exactly.
- API-key authentication is the v1 contract.
- Trash, not permanent deletion, is the only filesystem removal mechanism.
- No GUI, daemon, cloud sync, stale-file cleanup, audio/video transcription, or system-folder scanning is included in v1.
