What I found

  There is no application log file currently. The program only writes progress to terminal stdout/stderr:

  - Scanning approved user folders...
  - final completion summary

  It does not use Logger, os_log, or a dedicated log directory.

  The useful state is in:

  $HOME/.local/state/ai-dupe-fixer/dupescan.db

  I inspected the live process and database. The scan is still marked running and has accumulated:

  - 100,422 folders
  - 756,715 files
  - 47,688 files with hashes
  - 6,689 files with extracted text
  - 12 image digests

  The fingerprint count increased during observation, so the process is not completely deadlocked. However, it is progressing extremely
  slowly.

  A process sample showed it inside:

  - FileScanner.analyze
  - SHA-256 hashing
  - SQLite fingerprint updates
  - local content extraction
  - OpenAIClient
  - CFNetwork activity

  That indicates this run is using the direct OpenAI API route rather than the Codex CLI fallback.

  The linker warnings are unrelated. The package compiled successfully.

  Why it is taking so long

  The default scan is encountering an unusually large dataset: approximately 756,000 files.

  The current implementation has several expensive characteristics:

  - It holds the discovered file list in memory.
  - It computes full hashes for candidate pairs.
  - It performs SQLite writes and follow-up queries for individual files.
  - It performs local text/image analysis serially.
  - AI calls can take up to 90 seconds per request and retry up to three times.
  - Candidate rows are not written until the full analysis phase finishes, so the database may show zero candidates even while analysis
    is underway.

  The approximately 900 MB memory usage is plausible for this workload, especially because the scanner retains large in-memory arrays
  and candidate-pair structures.

  How to monitor it now

  In another terminal, run:

  DB="$HOME/.local/state/ai-dupe-fixer/dupescan.db"

  while true; do
    date
    sqlite3 "$DB" "
      SELECT
        id,
        status,
        mode,
        datetime(started_at, 'unixepoch', 'localtime') AS started,
        datetime(finished_at, 'unixepoch', 'localtime') AS finished
      FROM scans
      ORDER BY id DESC
      LIMIT 3;
    "

    sqlite3 "$DB" "
      SELECT
        count(*) AS files,
        count(partial_sha256) AS partial_hashes,
        count(sha256) AS full_hashes,
        count(extracted_text) AS extracted_text,
        count(image_digest) AS image_digests
      FROM files
      WHERE scan_id = (
        SELECT id FROM scans ORDER BY id DESC LIMIT 1
      );
    "

    sleep 30
  done

  Stop that monitoring loop with Ctrl-C.

  To inspect the live process:

  PID=$(pgrep -x dupefix)

  ps -o pid,ppid,etime,%cpu,%mem,state,command -p "$PID"
  sample "$PID" 5

  The sample command is useful because it reveals whether the process is hashing, reading a document, waiting on SQLite, or waiting on
  the network.

  My recommendation

  I would stop this run rather than leave it unattended indefinitely.

  Press Ctrl-C in the terminal running dupefix. The scan does not delete files during scanning; deletion only occurs later through the
  review and apply commands.

  This run is not necessarily broken, but the observed throughput is too low to justify leaving it running without better progress
  reporting or workload controls. At the observed rate, the remaining work could take an impractical amount of time.

  One important behavior to know: the current --resume implementation does not provide a true incremental continuation. It reuses the
  running scan record and resets its scan contents before starting again. Therefore:

  swift run dupefix --ai --resume

  should not be interpreted as “continue exactly where it stopped.”

  Recommended next engineering changes

  Before attempting another full-home AI scan, I recommend adding:

  - periodic terminal progress such as discovery count, hash count, local-analysis count, AI-call count, and current path;
  - a persistent scan-stage field such as discovering, hashing, local_analysis, ai_analysis, or completed;
  - checkpointed candidate and analysis results instead of saving candidates only at the end;
  - a true resumable cursor or per-file completion state;
  - batched SQLite transactions instead of one transaction per file;
  - an upper bound on candidate-pair count;
  - an AI request count and configurable AI budget;
  - a default exclusion or confirmation step for extremely large roots;
  - SIGINT handling that marks the scan as cancelled;
  - structured diagnostic logging to a file under something like:
    $HOME/.local/state/ai-dupe-fixer/logs/.

  For the next run, use a small controlled root first:

  swift run dupefix \
    --ai \
    --root "$HOME/Documents" \
    --db /tmp/dupefix-documents-test.db

  That will make the workload, AI behavior, and resulting review flow much easier to validate.