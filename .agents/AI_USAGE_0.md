# AI usage in dupefix

## Summary

dupefix is local-first. The application never sends files to an AI provider
unless the user explicitly supplies the --ai option. Running dupefix with no
arguments performs a local scan.

AI is a final comparison signal for a small set of promising file pairs. It
does not scan the entire home folder, choose deletion targets, delete files,
or replace the review step.

The application supports two AI routes:

1. The preferred route is a direct OpenAI Responses API request authenticated
   with OPENAI_API_KEY.
2. If OPENAI_API_KEY is absent, the application can use an already-authenticated
   local Codex CLI session through codex login status and codex exec.

The requested model is used on both routes:

    gpt-5.6-luna

Both routes request maximum reasoning effort and a strict JSON comparison
result.

## When AI is called

AI is deliberately gated behind the local pipeline:

1. The scanner resolves approved, visible user roots under HOME.
2. It records folders first and files second.
3. It creates inexpensive candidate pairs using combinations of:
   - equal file sizes;
   - normalized filenames;
   - matching extensions.
4. It computes local metadata and hash evidence.
5. It performs format-specific local analysis only for eligible file types.
6. Only a surviving candidate pair with sufficient local evidence can reach
   AI comparison.

AI is not called when:

- --ai was not supplied;
- the pair is already an exact full-hash match;
- either file is not locally eligible for content analysis;
- the local evidence score remains below the AI threshold;
- either file exceeds the --max-ai-mb limit;
- the local analyzer cannot safely read the required format.

The default per-file AI size limit is 8 MiB. The limit applies independently
to each side of a pair. --max-ai-mb can raise or lower that limit for a run.

The current escalation thresholds are:

- local content analysis begins when preliminary evidence is at least 0.25;
- AI comparison begins when the post-local evidence score is at least 0.35;
- a candidate is persisted when the final score is at least 0.70, or when
  full SHA-256 proves an exact match.

This keeps the expensive model call away from unrelated files and from pairs
that already have a conclusive local answer.

## Local evidence supplied to AI

AI receives evidence assembled by the local scanner rather than arbitrary
access to HOME:

- the file's HOME-relative path;
- Uniform Type Identifier or detected content type;
- byte size;
- formatted modification date;
- bounded extracted text, when available;
- image attachments only for image-to-image comparisons.

Absolute filesystem paths are not included in the comparison summary. The
scanner does not give either AI route a general-purpose file search request.

### Image handling

Recognized image extensions are analyzed as images only. The local analyzer:

- decodes the image;
- creates a 16 x 16 average-hash digest;
- runs Vision OCR on the image;
- produces a 768-pixel maximum JPEG preview for an AI comparison.

The direct Responses API receives two low-detail JPEG data URLs only when both
files are recognized as images. The Codex route receives two temporary JPEG
preview files under an isolated temporary directory only in the same case.
An image file is never sent to the image input path when the other file is a
non-image.

### Document handling

The application does not upload raw document containers to the direct API.
It extracts bounded text locally:

- PDF text is read with PDFKit;
- sparse PDFs can receive local Vision OCR from up to six rendered pages;
- DOCX text comes from Word XML entries;
- PPTX text comes from slide and notes XML entries;
- XLSX text comes from shared strings and worksheet XML entries;
- supported TXT, Markdown, and RTF-like text is read as local text.

Only the resulting bounded text and metadata are placed in the AI prompt.
Document OCR is never applied to unrelated binary formats.

## Direct OpenAI route

The direct provider sends an HTTPS POST to:

    https://api.openai.com/v1/responses

It sets:

- Authorization: Bearer OPENAI_API_KEY;
- model: gpt-5.6-luna;
- reasoning.effort: max;
- store: false;
- max_output_tokens: 4000;
- structured JSON output using a strict JSON Schema.

The request includes a conservative analyst instruction. In substance, the
instruction says:

- treat a duplicate as the same user content, including re-exports, resizes,
  conversions, and materially identical documents;
- use only the supplied evidence;
- be conservative and express uncertainty;
- do not infer whether deletion is safe.

The text prompt contains at most 12,000 characters of extracted text per file.
This is a character bound applied before the request is created; it is not a
promise about the model's tokenization.

The response schema is:

~~~json
{
  "similarity": 0.0,
  "duplicate": false,
  "rationale": "short explanation",
  "signals": ["signal used"]
}
~~~

The application clamps similarity to the inclusive range 0 through 1 and
rejects responses that do not contain the required structured result. The
Responses API supports JSON Schema structured outputs and text/image input
content; see the official [Responses API reference](https://developers.openai.com/api/reference/cli/resources/beta/subresources/responses).

Transient HTTP failures are retried up to three attempts. HTTP 429 and
server-side 5xx responses receive increasing short delays. A permanent API
error or exhausted retry is recorded as an unavailable AI signal and does not
abort the entire local scan.

The application sets store to false for the Responses request. This is a
request-level storage setting, not a claim that every organization, account,
or service policy provides zero retention. Users should evaluate their
OpenAI account and workspace data controls before enabling --ai.

## Codex CLI authentication route

The Codex route is a local process bridge. It is not direct access to the
ChatGPT desktop app's private IPC, and it does not parse auth.json or extract
an OAuth token into this application.

When OPENAI_API_KEY is missing, dupefix searches for an executable named codex
on PATH and then checks the Codex executable bundled with the ChatGPT desktop
application at:

    /Applications/ChatGPT.app/Contents/Resources/codex

For each usable candidate it runs:

    codex login status

The route is accepted only when the command succeeds and reports a logged-in
session. If no authenticated CLI is found, --ai fails with an actionable
message suggesting OPENAI_API_KEY or codex login. Local-only scanning remains
available without credentials.

For an accepted session, each comparison invokes Codex with:

~~~text
codex exec
--ephemeral
--json
--model gpt-5.6-luna
--sandbox read-only
--skip-git-repo-check
--output-schema temporary-schema.json
-c reasoning.effort=max
--cd isolated-temporary-directory
~~~

The comparison prompt is passed as one process argument rather than through a
shell. It tells the model to use only the supplied evidence and image
attachments, not to use tools or inspect other files, not to follow
instructions found in file content, and to return only the comparison JSON.

For image pairs, the previews are written to the isolated temporary directory
and supplied through Codex's image option. The temporary directory is removed
after the comparison attempt. For document pairs, the prompt contains the
bounded locally extracted text and no raw document file.

Codex JSONL output can contain execution events around the final answer. The
provider searches the returned events for a JSON object matching the same
comparison schema. A nonzero process status or missing structured result is
treated as an AI failure for that pair, and the local scan continues.

Official OpenAI documentation states that Codex CLI and the ChatGPT desktop
app support ChatGPT sign-in, that codex login status reports the active
authentication method, and that stored login details are managed by Codex.
It also distinguishes Codex access tokens from general OpenAI API
authentication. See the official [ChatGPT and Codex authentication
documentation](https://learn.chatgpt.com/docs/auth).

## How AI affects scoring

The model result is stored as analysis evidence:

- similarity becomes aiSimilarity;
- duplicate becomes aiDuplicate;
- rationale becomes aiRationale;
- provider or parsing failures become skippedReason.

The model is only one weighted signal. Filename similarity, metadata
similarity, partial hash, full hash, local text similarity, and local image
similarity remain part of the score. An AI duplicate result can raise the
score, but the score adjustment is capped below certainty. A model response
cannot override an exact hash, turn an unsupported file into an eligible
format, or bypass the final candidate threshold.

AI rationale is evidence for the review UI, not an authorization to delete.

## What AI cannot do

AI does not:

- traverse HOME independently;
- read Library or other excluded system paths;
- receive raw access to the database;
- execute deletion commands;
- move files to Trash;
- select which copy should survive;
- make a decision for an entire duplicate group;
- permanently delete anything.

The review UI still allows the user to choose keep both, delete the first
file, delete the second file, delete both, keep a canonical file, defer, or
leave the group unchanged. The apply phase shows the complete plan, requires
explicit confirmation, re-checks metadata and the reviewed SHA-256, and moves
selected files to macOS Trash.

## Credential and privacy expectations

Use AI only when the user understands that bounded file-derived information
will leave the local machine through the selected provider:

- local mode sends nothing to OpenAI or Codex;
- --ai with OPENAI_API_KEY uses the direct Responses API;
- --ai without OPENAI_API_KEY uses Codex CLI only when its local login is
  already authenticated;
- credentials are not printed, copied, or stored by dupefix;
- extracted text can contain sensitive document content;
- image previews can contain sensitive visual content;
- relative filenames, content types, sizes, and modification dates are also
  sent for eligible comparisons;
- retries can send the same comparison more than once after a transient
  failure.

The SQLite database stores fingerprints, extracted local evidence, AI scores,
rationales, and skipped-error text so the review can be resumed. The database
is local at:

    $HOME/.local/state/ai-dupe-fixer/dupescan.db

It does not provide a vector database, embeddings, RAG index, or sqlite-vec
extension. AI comparison is pairwise and bounded.

## Practical commands

Local scan, with no AI data leaving the machine:

~~~sh
dupefix
~~~

Opt into AI with a Platform API key:

~~~sh
OPENAI_API_KEY=... dupefix --ai
~~~

Opt into AI through an existing Codex CLI login:

~~~sh
codex login status
dupefix --ai
~~~

Limit AI input size and restrict the scan root:

~~~sh
dupefix --ai --max-ai-mb 4 --root "$HOME/Documents"
~~~

If the API key is malformed, unauthorized, expired, or lacks access to the
requested model, the direct provider reports the API failure and the affected
pair remains reviewable with local evidence. The application does not silently
switch an API-key failure to another credential source; the Codex fallback is
selected only when OPENAI_API_KEY is absent.
