# Architectural Design Record: dupefix

## Project record

dupefix is a SwiftPM macOS terminal application that scans visible,
user-facing folders under HOME, stores scan state in SQLite, escalates
duplicate evidence from metadata through hashes and format-specific local
analysis to optional AI comparison, and moves only explicitly reviewed files
to macOS Trash.

Local analysis is the default. AI requires --ai, uses bounded file-derived
evidence, and must never choose or execute deletion. The default database is
$HOME/.local/state/ai-dupe-fixer/dupescan.db. SQLite is used without
sqlite-vec, embeddings, or RAG infrastructure.

The canonical agent-document directory is .agents/. An earlier instruction
used agents/ instead of .agents/; that was an unfortunate typo. The legacy
agents/CLI_PLAN_STAGE_1.md file is retained as historical context and must
not be silently deleted.

## Known runtime record

The previous full-home --ai run discovered approximately 100,422 folders and
756,715 files, used approximately 900 MB of memory, and advanced very slowly.
The process sample showed hashing, local extraction, SQLite I/O, and direct
OpenAI network activity. The application currently has no dedicated log file,
and its current --resume behavior resets scan contents instead of continuing
from per-file checkpoints.

## Next-session prompt

Implement the task ledger below in order. Preserve path safety, folder-first
then file persistence, local-only default behavior, type-aware analysis,
interactive review, re-checks before Trash, and no permanent deletion.

Use rg for inspection, apply_patch for file edits, and run the strongest
available build, test, and integration checks. Update task and section status
immediately after each attempt.

## Task ledger

### 1. Progress visibility and cancellation

[ Completed: false ][ Passed: ][ timestamp completed: ] Progress and cancellation

- [ Completed: false ][ Reason: ] Add periodic terminal counters for discovery, persistence, hashing, local analysis, candidates, AI calls, and elapsed time.
- [ Completed: false ][ Reason: ] Persist scan stages: discovering, persisting, hashing, local_analysis, ai_analysis, completed, failed, and cancelled.
- [ Completed: false ][ Reason: ] Handle SIGINT by marking the active scan cancelled and closing resources safely.
- [ Completed: false ][ Reason: ] Add redacted structured logs under $HOME/.local/state/ai-dupe-fixer/logs/; never log credentials, document text, or image data.

### 2. Scanner and SQLite performance

[ Completed: false ][ Passed: ][ timestamp completed: ] Scanner and database performance

- [ Completed: false ][ Reason: ] Batch SQLite writes in transactions and remove per-file insert-then-select overhead.
- [ Completed: false ][ Reason: ] Reduce retained in-memory file and candidate structures.
- [ Completed: false ][ Reason: ] Bound candidate-pair generation and report when a limit is reached.
- [ Completed: false ][ Reason: ] Measure discovery, persistence, hashing, local analysis, candidate generation, and AI time separately.

### 3. Checkpointing and resume correctness

[ Completed: false ][ Passed: ][ timestamp completed: ] Checkpointing and resume

- [ Completed: false ][ Reason: ] Persist per-file and per-stage completion state.
- [ Completed: false ][ Reason: ] Persist candidate analysis incrementally instead of only after the full analysis phase.
- [ Completed: false ][ Reason: ] Make --resume continue completed work rather than reset scan contents.
- [ Completed: false ][ Reason: ] Make cancellation and process termination recoverable, including migrations for current databases without destructive data loss.

### 4. AI workload controls

[ Completed: false ][ Passed: ][ timestamp completed: ] AI workload controls

- [ Completed: false ][ Reason: ] Persist AI request, success, failure, retry, and elapsed-time counters.
- [ Completed: false ][ Reason: ] Add a configurable AI request budget and report provider, waits, retries, and rate limits.
- [ Completed: false ][ Reason: ] Preserve bounded, type-aware inputs and OPENAI_API_KEY preference with Codex fallback only when the key is absent.
- [ Completed: false ][ Reason: ] Add request timeouts and cancellation propagation; provider failures must not hang or abort the scan.

### 5. Large-root safety and validation

[ Completed: false ][ Passed: ][ timestamp completed: ] Large-root safety and validation

- [ Completed: false ][ Reason: ] Detect unusually large roots and require confirmation or an explicit override before scanning.
- [ Completed: false ][ Reason: ] Provide practical root restriction while preserving Library, hidden-path, package, symlink, system-path, and non-regular-file exclusions.
- [ Completed: false ][ Reason: ] Add tests for progress, stages, cancellation, batching, true resume, pair limits, AI budgets, retries, redaction, and large-root confirmation.
- [ Completed: false ][ Reason: ] Re-run path safety, exact hash, type routing, review, changed-file, and Trash-safety tests.
- [ Completed: false ][ Reason: ] Run swift build and swift test where the required XCTest environment is available.

## Status protocol

For every task, set Completed true only after the change and its relevant
verification succeed. Leave Reason blank while a task has not been processed.
If an attempted task fails, keep Completed false and record a specific reason,
such as a missing file, blocked procedural or runtime constraint, unavailable
dependency, logic issue, or named test type and failure.

For every section, set Completed true only when all section tasks succeed.
Record Passed as test type names plus the number performed, and record the
completion timestamp in ISO-8601 format with timezone.

Before replacing this file, create .agents/previous/ if necessary and move
the existing file to:

    .agents/previous/AGENTS_replaced_YYYYMMDD_HHMMSS.md

Never overwrite an existing AGENTS.md without preserving that archived copy.
