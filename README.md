# dupefix

`dupefix` is a local-first macOS terminal utility for finding likely duplicate files and conservative user-junk suggestions. It scans visible, user-facing folders under `$HOME` and excludes `Library`, hidden paths, escaping symlinks, packages, and non-regular filesystem entries.

## Build and run

```sh
swift build
swift run dupefix
swift run dupefix scan
swift run dupefix scan --resume
swift run dupefix review
swift run dupefix apply
```

Running `dupefix` with no arguments immediately scans the approved user folders. On first run it creates the SQLite database and parent directories automatically at `$HOME/.local/state/ai-dupe-fixer/dupescan.db`; later runs reopen that database automatically. Use `--db PATH` only to divert a run to a non-default database. Use repeated `--root PATH` arguments to restrict a scan to approved directories inside `$HOME`.

The scan stores folders first, then files, hashes, analysis evidence, candidate groups, review decisions, and deletion results. If a process is interrupted, rerun with `--resume` to continue the latest incomplete scan record.

## Analysis and privacy

Local analysis compares normalized names and metadata, then uses sampled and streaming SHA-256 hashes. Eligible PDFs, DOCX/PPTX/XLSX archives, text files, and recognized image formats receive format-specific extraction. Vision OCR is used only on image data and rendered PDF pages.

AI analysis is opt-in:

```sh
OPENAI_API_KEY=... swift run dupefix scan --ai
```

Only surviving candidate pairs are sent for AI comparison. Document calls contain bounded extracted text and metadata; image calls contain bounded JPEG previews and metadata. The direct API client uses the OpenAI Responses API with `gpt-5.6-luna`, `reasoning.effort=max`, structured JSON output, and `store=false`. `OPENAI_API_KEY` is preferred. If it is absent, `--ai` checks for an authenticated local Codex CLI session (`codex login status`) and uses `codex exec` with an ephemeral, read-only workspace. The app never reads or exports Codex or ChatGPT credential files. Missing credentials or `--no-ai` keep the scan local-only.

## Review and removal

`dupefix review` presents one group at a time. Use:

- `l` / `r`: delete the first or second file in a two-file group;
- `b`: delete both files;
- `k`: keep all files in the group;
- `c`: choose one canonical survivor and delete the rest;
- `g`: select every file in the group;
- `d` / `n`: defer or move to the next group;
- `q`: quit while preserving decisions.

`dupefix apply` prints the complete deletion plan, requires typing `DELETE`, re-checks metadata and the reviewed SHA-256, then moves selected files to the macOS Trash. It never permanently unlinks files.

`dupefix junk` lists conservative suggestions such as empty user files, temporary/interrupted downloads, and installer/archive remnants in Downloads. Junk suggestions are informational and are not auto-deleted.

## Validation

```sh
swift build
swift test
```

The current minimal CommandLineTools image may not include XCTest; on a full Xcode installation, the XCTest target runs the deterministic normalization, scoring, deletion-plan, and CLI-option tests.
