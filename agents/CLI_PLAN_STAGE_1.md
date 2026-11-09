# dupefix CLI plan

## Objective

Build a Swift macOS terminal application that scans user-facing folders under
HOME, identifies high-likelihood duplicate files and conservative junk
suggestions, and lets the user review every deletion decision before moving a
copy to the macOS Trash.

The default invocation must be useful immediately:

    dupefix

It performs a local-only scan unless the user explicitly opts into AI
comparison with --ai.

## Scope and safety boundary

- Scan visible, regular files in approved user folders under HOME.
- Exclude Library, hidden paths, packages, non-regular files, and symlinks
  resolving outside HOME.
- Reject custom roots that are outside HOME, hidden, or inside Library.
- Analyze files people interact with directly; do not inspect system folders.
- Move reviewed deletion targets to Trash rather than permanently unlinking
  them.
- Before applying a decision, re-check the file path, metadata, and reviewed
  SHA-256.
- Keep the review workflow reversible by supporting keep both, delete left,
  delete right, delete both, defer, and group/canonical decisions.

## Scan pipeline

1. Resolve approved roots.
2. Enumerate and persist folders first.
3. Enumerate and persist files second, including type, size, dates, normalized
   filename, and content classification.
4. Generate inexpensive candidate pairs from equal sizes, normalized names,
   and matching extensions.
5. Escalate scrutiny only for promising pairs:
   - normalized filename and metadata similarity;
   - partial SHA-256;
   - full streaming SHA-256;
   - format-specific local analysis;
   - optional AI comparison for surviving candidates.
6. Persist evidence, scores, candidate groups, and junk findings.

Format-specific analysis must remain type-aware:

- Image hashing, image previews, and image AI analysis only apply to recognized
  image formats.
- PDF text extraction and OCR for rendered pages apply only to PDFs.
- DOCX, PPTX, and XLSX extraction applies only to their respective Office
  archive formats.
- Plain-text extraction applies only to supported text formats.

## Persistence

Use the system SQLite3 library without sqlite-vec or another vector extension.
The database is created automatically, including parent directories, at:

    $HOME/.local/state/ai-dupe-fixer/dupescan.db

Each later invocation reopens that path. --db PATH is an optional diversion
to a non-default database; it does not change the default location.

Persist scans, folders, files, fingerprints, candidates, decisions, deletion
attempts, and junk findings. The database schema must be sufficient for
resuming interrupted scans and reconstructing the review UI.

## AI provider and authentication

The direct provider uses the OpenAI Responses API with:

- model gpt-5.6-luna;
- reasoning effort max;
- structured JSON output;
- store false;
- bounded extracted text and JPEG image previews.

AI is opt-in. When OPENAI_API_KEY is present, use it. When it is absent,
check codex login status and, if authenticated, invoke the locally installed
Codex CLI with:

- codex exec;
- the same model and reasoning setting;
- ephemeral mode;
- read-only sandbox;
- an isolated temporary working directory;
- a strict output schema.

Do not read, parse, copy, or export ChatGPT or Codex credential files, and do
not treat a Codex OAuth access token as a general OpenAI API key. The Codex
CLI is the local authentication bridge.

## CLI behavior

All options are optional. Supported operations are:

- no command or scan: scan immediately;
- review: interactively mark duplicate decisions;
- apply: show and confirm the complete plan, then move selected files to
  Trash;
- status: summarize the latest scan;
- junk: list conservative junk suggestions;
- --ai, --resume, repeated --root PATH, --max-ai-mb N, and --db PATH;
- --help for usage.

## Verification

- Build with Swift Package Manager.
- Run deterministic XCTest coverage where XCTest is available.
- Verify first-run database creation and subsequent reopening.
- Verify no-argument scanning with a disposable root and diverted database.
- Verify custom-root safety checks.
- Verify exact duplicate detection, review decisions, Trash moves, and
  missing-credential errors.
- Verify the source and documentation contain no sqlite-vec capability or
  legacy database path.
