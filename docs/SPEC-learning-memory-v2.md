# SPEC: Learning Memory — V2

Status: **PARKED — review after V1 ships.** Nothing here is scheduled.
Builds on: `docs/SPEC-learning-memory.md` (V1, revision 2). Section references like
"V1 §5.5" point into that document.
Track D (providers) and most of track E (runtime and operations) moved to
`docs/SPEC-learning-memory-v3.md`; references like "V3 E6" point there. E3 (spend
reports) and E4 (`/shake` on resume) stay here. Item ids are unchanged.

---

## 0. How to read this

V1 builds the full loop: observations → compaction → topics → proposals → long-term
`.md` memory and skills, with presets and budgets. V2 collects everything V1
**deferred, marked "later", listed as a non-goal, or left as an open question**, plus
ideas from the Hermes and pi-om research that were outside V1's scope.

**Rules that carry over from V1 unchanged:**
- **V1 G5:** nothing becomes a persistent instruction without passing the review gate.
- **V1 G6:** the system prompt stays fixed for the session, so the prompt cache holds.
- **V1 G9:** background spend is user-controlled and capped.
- **V1 §10:** workers treat content as inert data; they get confined tools and
  redaction.

**New rules for V2 items:**
- Every item is **opt-in**, or at least can be switched off, and has its own settings
  key.
- Every item can ship **on its own**; §9 lists the few ordering constraints.
- An item that adds LLM calls must plug into the V1 cost accounting, presets, and
  budget (V1 §4.5). Items with no LLM calls say so.

Each item below lists **Origin** (why it's here), **Design**, **Cost**, **Depends on**,
and **Open questions**.

---

## 1. Inventory

| # | Item | Origin | LLM cost | Wave |
|---|---|---|---|---|
| A1 | `memory_search` tool (SQLite FTS5) | V1 §5.5, "later" row | none | 2.0 |
| A2 | Automatic per-turn recall (built-in prefetch) | V1 §6.2 `:prefetch` unused by the built-in provider | none / optional | 2.0 |
| A3 | Semantic search (embeddings) | V1 non-goal | embedding calls | 2.x |
| B1 | Project topic tree (cross-session topics) | V1 Q4 | consolidator +1 step | 2.2 |
| B2 | Fact metadata: provenance, confidence, expiry, conflicts | Hermes holographic (trust scoring) | none / small | 2.2 |
| B3 | Retrieval-based LTM once the char caps are outgrown | consequence of the V1 char caps | none | 2.2 |
| B4 | Reflection tier | pi-om dropped OM's reflections tier | yes | 2.x |
| C1 | LLM skill consolidation (umbrella skills) | V1 non-goal, Hermes curator `consolidate` | yes | 2.1 |
| C2 | Skill quality gates: linter, security scan | Hermes `skill_linter`, `skills_guard` | none | 2.1 |
| C3 | `/learn` from sources (URL, directory, buffer) + large-skill layout | Hermes `learn_prompt.py` | yes (on demand) | 2.1 |
| C4 | Skill evaluation (smoke test before accepting) | G4 follow-up | yes (on demand) | 2.x |
| C5 | Skill sharing: export/import, bundles (hub install: V3 E7) | Hermes skills hub, agentskills.io | none | 2.1 |
| C6 | Project skills in git | V1 Q8 | none | 2.1 |
| E3 | Spend insights + preset recommendations | follow-up to V1 §4.5 | none | 2.0 |
| E4 | Replay `shake` entries on load | V1 §12.1 (out of scope there) | none | 2.0 |
| F1 | Memory browser buffer | UX gap | none | 2.0 |
| F2 | "Why do you know this?" provenance links | UX / trust | none | 2.2 |
| F3 | Learning graph / timeline view | Hermes `learning_graph.py` | none | 2.x |
| G1 | `/memory forget` (purge everywhere) | privacy | none | 2.0 |
| G2 | Team / shared project memory | extends C6 | none | 2.2 |
| G3 | User-defined redaction rules and private sessions | extends V1 §10 | none | 2.0 |

---

## 2. Track A — Recall and search

### A1. `memory_search` tool (SQLite FTS5)

**Origin.** V1 §5.5: "A `memory_search` tool is **not** part of v1". In V1, past
sessions can only be reached with `grep`.

**Design.**
- **Index:** `~/.pai/memory/index.sqlite`, using Emacs 29's built-in `sqlite-*`. FTS5
  with `tokenize='trigram'` was verified to work in this Emacs (29.4, SQLite 3.37.2),
  so there is no external dependency. The index is **derived data**: it can be
  deleted at any time and `/memory reindex` rebuilds it.
- **What is indexed:**

  | Source | Unit | Keys |
  |---|---|---|
  | Session JSONL `message` entries | one row per message (text only; tool results capped) | project slug, session id, entry id, branch leaf set, timestamp, role |
  | `memory.observations` entries | one row per observation | + observation id |
  | Session topic files, `JOURNEY.md` | one row per section | path |
  | LTM files | one row per `§` entry | target |
  | Skills | one row per `SKILL.md` | name, origin |

- **Incremental indexing.** Session files are append-only, so the index records the
  byte offset read so far for each file and resumes from there. It runs from an idle
  timer and on `agent-settled`, never during a turn.
- **Tool** `memory_search {query, scope?: session|project|all, kinds?, session_id?,
  around?, limit?}`. It has three modes, as Hermes `session_search` does:
  - *discover*: ranked hits, deduplicated per session;
  - *scroll*: ±N messages around one hit;
  - *read*: a whole topic or LTM file.
- **No LLM.** The tool returns real stored text, as Hermes' current `session_search`
  does (the README claim of "LLM summarization" is out of date).
- **Query handling:** each user term is wrapped in FTS5 double quotes. This is
  required: `-` and other punctuation are FTS5 syntax, and the bare query `user-te`
  returned nothing in testing.
- **Short terms:** trigram needs at least 3 characters. Terms shorter than that fall
  back to `LIKE`, limited to the current project. A CJK tokenizer, as in Hermes, is
  out of scope.
- **Branches:** hits from branches that are not ancestors of the current leaf are
  labelled `(other branch)`.
- **Deferred schema:** the tool is registered as deferred, so it adds nothing to the
  prompt until it is first used.

**Cost.** No LLM. Disk use is roughly the size of the transcript text for the
trigram index (Hermes measured about 2.6× their base index); a size cap is needed.

**Depends on.** Nothing in V1 beyond the file layout. It can ship even with both
layers off.

**Open questions.**
- Index tool-result text (large, but that's where error codes live), or only
  user/assistant text plus observations?
- Retention: prune index rows for sessions older than N days?

**✅ Implemented** (`extensions/pai-memory/pai-memory-search.el`):
- **Schema.** One FTS5 table `docs(text, kind, project, session, entry, role, ts,
  path)`, trigram tokenizer, with every column but `text` unindexed. A `files` table
  records the byte offset read so far for each session file, and size and mtime for
  each Markdown file.
- **Settings:** `:memory :search (:enabled t :max-mb 500 :tool-result-chars 2000)`.
  Search works even with both memory layers off.
- **Open questions, decided:**
  - tool-result text *is* indexed, capped at 2000 characters;
  - there is no retention pruning. The size cap stops indexing, and `/memory` flags
    it.
- **Indexing.** Idle slices of 0.2 s run after a session starts and after each run
  settles. A search also brings the index up to date first, for at most 2 s. Only
  complete lines are read. Lines that don't parse are skipped: some older sessions
  saved steering notices as bare strings.
- **Measured on real data:** 42 MB of sessions become a 20 MB index. A full index
  takes 2.1 s, later passes 0.01 s, and a query about 2 ms.
- **Search.** Discover mode returns at most 2 hits per session, or per file for
  Markdown kinds. Terms of 3+ characters go to FTS5 as quoted phrases; shorter terms
  use `LIKE`. Project scope includes global kinds (long-term memory, skills).
- **Commands:** `/memory search WORDS`, `/memory reindex`, plus a status line and
  `/menu` → Memory → Search.

### A2. Automatic per-turn recall (built-in prefetch)

**Origin.** V1 defines provider `:prefetch` (§6.2), but the built-in Markdown provider
doesn't implement it. Past sessions are only found when the agent thinks to search.

**Design.**
- On `before-agent-start`, a trivial-prompt gate runs first (the prompt has too few
  tokens, or is only a command, `yes`, or `ok`). If the prompt passes, run an A1 query
  built from the prompt's key terms.
- Inject the top `k` hits (default 3, each at most 400 chars) into the **API copy of
  the user message** in `<memory-context>` fences, with a note that this is
  background data. The saved transcript keeps the clean user text; this is the
  api-content sidecar pattern from Hermes `turn_context.py`.
- Show a recall indicator in the transcript, `🧠 recalled 3 from 2 sessions`, which
  can be expanded.
- ~~**Optional query rewrite:** one cheap LLM call to turn the prompt into search terms.~~
  **Dropped** (decision 2026-09-23): a model call per turn for a feature that works
  without it. Revisit only if recall is measured to miss relevant notes.

**Cost.** None by default.

**Depends on.** A1.

**Open question.** Precision: false positives waste context and can mislead the
model. This needs an evaluation on real sessions before it can be on by default.

**✅ Implemented, off by default** (`pai-memory-recall.el`,
`:memory :search :recall`):
- **Search.** The newest undecided user prompt of a run is searched once, with OR
  over up to 8 distinctive words (4+ letters, no stopwords). Only observations,
  topic sections, compaction summaries and messages of **other** sessions are
  considered: memory entries and skills are already in the system prompt.
- **Trivial prompts** are skipped: slash commands, yes/ok/continue, and prompts with
  fewer than 2 search words.
- **Cache safety.** The decision (a block, or an empty one) is saved as a
  `memory.recall` session entry keyed by the prompt's timestamp. The `context` hook
  re-adds the same text to that prompt on every later request and after `/resume`,
  so the provider's prompt cache stays valid. The transcript keeps the user's own
  words.
- **Indicator:** a transcript note, `🧠 recalled N from M session(s)`.
- **Dropped:** the optional model query rewrite (see above).

### A3. Semantic search (embeddings)

**Origin.** V1 non-goal.

**Design.**
- Add an optional `:embedder` to the A1 index. It embeds observations, topic sections,
  and LTM entries (not raw messages), through a provider embedding endpoint or a
  local model.
- Vectors are stored as blobs in `index.sqlite`, and search computes cosine similarity
  in Lisp over the candidates FTS returns. This hybrid approach avoids native
  extensions (`sqlite-vec` isn't bundled with Emacs).
- Ranking is reciprocal-rank fusion of the FTS and vector results.

**Cost.** Embedding calls at index time. They count against the budget as a
separate `embed` role.

**Open question.** Is this better done as an external provider (V3 D2) than built in?
The proposed answer is yes: keep the core free of embeddings.

**✅ Implemented as an opt-in, pluggable layer** (`pai-memory-embed.el`). This is
the middle ground for the open question: the core carries no model, native code or
dependency. `:search :embedder` is nil by default.
- **Embedders.** Registered with `pai-memory-register-embedder NAME FN`, where
  `(FN TEXTS CALLBACK)` calls back with `(:vectors … :tokens N)` or
  `(:error MSG)`. The built-in `openai` embedder posts asynchronously to any
  OpenAI-compatible `/v1/embeddings` (`:embed-url`, `:embed-model`, with the key taken
  from the env var named by `:embed-key-env`), so local llama.cpp or vLLM servers
  work.
- **Storage.** Emacs binds strings as text, so vectors are unit-normalized, quantized
  to int8, base64-encoded and stored in `vecs(docid, h, v)` in `index.sqlite`. `h` is
  a text hash, so a reused rowid never matches a stale vector, and orphans are pruned
  on every pass.
- **What gets vectors.** Observations, topic sections, memory entries and skills,
  but not raw messages. Embedding runs asynchronously in idle time after indexing,
  `:embed-batch` (32) texts per request, one request in flight, under
  `:embed-daily-tokens` (2M, tracked in `state.json`). It is not charged to session
  budgets.
- **Search.** `memory_search`, `/memory search` and `/memory-browse` pass
  `:semantic t`; per-turn recall stays lexical, so no turn waits on an HTTP call. The
  query is embedded, waiting at most `:embed-timeout` (5 s); on failure it falls back
  to full text.
  - Candidates are the broad any-term FTS results (≤ 200) plus the newest
    `:embed-scan` (3000) embedded rows in scope. This is a deviation from "rerank FTS
    candidates", which could never find a note sharing no word with the query.
  - Vector ranks only count at cosine ≥ `:embed-min-similarity` (0.3); a row only a
    dissimilar vector brought in is dropped.
  - Scoring is RRF (k = 60) of the FTS rank and the vector rank.
- **Cost.** Scanning 3000 × 768 dimensions takes 0.17 s byte-compiled (1.0 s
  interpreted).
- **Settings.** All in `/menu` → Memory → Search.

---

## 3. Track B — Memory structure

### B1. Project topic tree (cross-session topics)

**Origin.** V1 Q4. V1 topic files are per session; anything that spans sessions only
survives through promotion into short LTM entries.

**Design.**
- A new directory `~/.pai/memory/projects/<slug>/topics/`, holding topic files with
  the same frontmatter as session topics plus `sources: [session ids]`.
- **Merge step:** after a consolidation run (or at session end), a merge worker
  (`:memory-merger` role) folds changed session topics into the project tree.
  - Its tools are confined to the project `topics/` dir, with the session topics
    readable.
  - **Conflicts:** the merger must keep both versions and mark a
    `conflict:` block. The conflict appears in the review UI as a `topic-conflict`
    proposal. Topics are *not* instructions, so a merge that has no conflict
    applies directly.
- **Injection:** the project `INDEX.md` (one line per topic) goes into the V1
  `<memory>` snapshot, fixed at session start and capped at `project-index-chars`.
  The agent `read`s topics as needed.
- The project `MEMORY.md` from V1 stays for short, high-value facts. Topics hold the
  long-form knowledge.

**Cost.** One merge call per consolidation (roughly the size of a consolidator run).
It gets its own preset knob (`:merge`) and counts against the budget.

**Open question.** Does this make the per-session topics redundant? One option is to
consolidate straight into the project tree. The trade-off: branches and parallel
sessions writing the same files.

**✅ Implemented** (`pai-memory-topics.el`). Both layers are kept: sessions still
consolidate into their own topics, so branches and parallel sessions never write the
same files. Only the topic merger writes the project tree, one session at a time.
- **Layout.** `projects/<slug>/topics/*.md` plus a generated `INDEX.md`.
  `topics-merged.json` records, per session, the hash of each session topic merged.
  Only changed topics go to the next merge.
- **Trigger.** `pai-memory-consolidated-hook`, when `:session :topic-merge` is on (a
  preset knob: on in balanced/thorough, off in economy/off), or `/memory merge-topics`.
  It is budget-checked and runs as a background worker (`topics` role, sharing the
  `:memory-merger` model role).
- **Tools.** `read`/`grep`/`ls`/`write`/`edit` confined to the tree, with the
  session's topic directory readable. Writes outside the tree, and to `INDEX.md`, are
  refused.
- **After a completed run.** The session id is added to `sources:` in every file
  written. A run that writes nothing still counts as merged: the merger judged the
  changes not project-worthy.
- **Conflicts.** The merger keeps both versions in a `conflict:` block and calls
  `conflict(topic, summary, resolution)`. That files a `topic-conflict` proposal,
  never auto-applied. Accept writes the resolution after a staleness check and is
  undoable; reject keeps both versions. Pending conflicts are refreshed after the
  `sources:` update, so they are not stale on arrival.
- **Snapshot.** "Project topics" lists `file: summary` lines, capped at
  `:long-term :project-index-chars` (2000). Project topics are indexed for
  `memory_search`.

### B2. Fact metadata: provenance, confidence, expiry, conflicts

**Origin.** Hermes holographic provider (trust scoring). V1 LTM entries are plain
paragraphs with no metadata.

**Design.**
- Keep **sidecar metadata** in `~/.pai/memory/entries.json`, keyed by a stable entry
  id: `{id, target, created, source_session, proposal_id, confirmed_at[], confidence,
  expires?}`. The `.md` files stay clean because they are what gets injected.
- **Stable ids:** each id is a hash of the normalized entry text plus its creation
  time, and the id→text mapping is kept up to date on every apply. This requires the
  V1 forward-compat item FC1 (§10).
- **Confirmation:** when the promoter's evidence reconfirms an existing entry, it adds
  to `confirmed_at` (a new proposal kind, `memory-confirm`, which auto-applies).
- **Expiry:** entries with `expires` (e.g. "user is on vacation until …") are hidden
  from the snapshot after that date. The curator then proposes `memory-remove`.
- **Conflict detection:** the promoter is given candidate pairs (A1 lexical overlap
  over entries in the same target) and may propose `memory-replace` with both texts
  shown.

**Cost.** None (curator). The promoter's input grows slightly.

**✅ Implemented** (`pai-memory-entries.el`):
- **Sidecar.** `~/.pai/memory/entries.json` (version 1). Records are reconciled with
  the files *lazily* on every read, by text hash. As a result, hand edits,
  `/memory undo` and restored text need no special cases: a record whose `previous`
  hash reappears is re-pointed, and a removed record is revived.
- **Stable ids and history.** A `replace` keeps the record's id (the old hash moves to
  `previous`). Removed entries are only marked `removed`/`removed_by`, never deleted.
- **Migration.** Entries without a record are recovered from `log.jsonl` (FC1): the
  newest logged change that added exactly that text gives origin, time, proposal and
  session. The session comes from the proposal when the log lacks it. `USER.md` and
  `MEMORY.md` match log records by target, so a moved `~/.pai` still recovers.
  Anything unrecoverable is `manual`. Verified on real data: the one existing entry
  was recovered with its proposal and session.
- **Confidence.** By origin: manual 1.0, memory-tool 0.9, migrated 0.7, proposal 0.6.
  Each confirmation adds 0.1, up to 1.0.
- **Confirmation.** `memory-confirm` (target, old) is a promoter kind. It only
  appends to `confirmed` and is applied whatever the review policy.
- **Expiry.** `expires: YYYY-MM-DD` is accepted by the memory tool and by
  memory-add/replace proposals. Expired entries leave the snapshot, and the curator
  files one `memory-remove` proposal each.
- **Conflicts.** The promoter prompt gets "Possibly overlapping entries": word-Jaccard
  ≥ 0.35 within a target, top 8. Every entry is shown with its metadata line.
- **Open question 3 (§10), decided for now:** sidecar only. Nothing inline costs
  snapshot tokens.

### B3. Retrieval-based LTM once the char caps are outgrown

**Origin.** V1 injects all LTM under hard char caps. This stops scaling as memory
grows.

**Design.**
- A setting `:ltm-injection full|retrieval` (default `full`).
- In `retrieval` mode:
  - the snapshot contains only entries marked `pinned` (or the top N by confidence
    and recency, from B2);
  - everything else is reachable through A2 prefetch and A1 search;
  - the caps then apply only to the pinned set.

**Depends on.** A1 and A2. B2 helps with ranking but isn't required.

**✅ Implemented.**
- **Settings.** `:long-term :ltm-injection full|retrieval` (default full) and
  `:retrieval-entries` (12).
- **What the snapshot keeps.** Pinned entries plus the N best others, ranked by
  confidence ÷ (1 + age/60 days), with age counted from the last confirmation. A
  line says how many more exist and that `memory_search` finds them.
- **Caps.** In retrieval mode the file caps are not enforced on writes. Pinning is:
  a target's pinned entries must fit its limit.
- **Pinning.** `/memory-pin QUOTE` (the same command as for skills: a skill name
  pins the skill, anything else pins an entry), `/memory-unpin`, or `P` in
  `/memory-browse`.

### B4. Reflection tier

**Origin.** Original observational memory (Mastra/OM) had *reflections*, which pi-om
removed (its `ledger/types.ts` says "reflections tier removed").

**Design.**
- A reflector periodically condenses the *observations* of a long session into
  higher-level reflections: patterns and recurring problems.
- Reflections stay in the ledger (`memory.reflections`) and are rendered above the
  observations in the compaction block.

**Status.** Experimental. V1's consolidator plus `JOURNEY.md` may already cover it.
Only worth doing if measurement shows the compaction block is too long or the agent
repeats mistakes.

**✅ Implemented, off by default** (`pai-memory-reflect.el`; `:session :reflect nil`,
so it stays opt-in until measured).
- **Trigger.** After an observer run commits, once the observations since the last
  reflection reach `:reflect-every-tokens` (40000). Also `/memory reflect`.
- **Input.** The previous reflections, plus every observation committed after the
  last `memory.reflections` entry on the branch. Dropped observations are included:
  consolidation doesn't hide them from reflection.
- **Output.** `reflect([...])` rewrites the whole set, at most 12, redacted, stored as
  `memory.reflections {runId, reflections:[{id, content}]}`. The latest entry on the
  branch wins, so forks and tree navigation need nothing extra.
- **Worker.** `reflector` role on the `:memory-consolidator` model, with a budget and
  `:reflector-timeout` 300.
- **Where they show.** A "## Reflections" section after the journey and above the
  observations in the compaction block (the header mentions it), and in the promoter
  digest.

---

## 4. Track C — Skills

### C1. LLM skill consolidation (umbrella skills)

**Origin.** V1 non-goal, and Hermes curator `consolidate: true`.

**Design.**
- A curator pass with an LLM (`:memory-curator` role). It runs only when **manually**
  triggered (`/memory-curate --consolidate`) or at most every
  `consolidate-interval-days`.
- **Input:** learned skills that overlap by name, description, or lexical overlap
  (A1), and their usage statistics.
- **Output: proposals only.** Two new kinds:
  - `skill-merge {sources: [...], into, after}`: patch or create the umbrella, then
    archive the sources;
  - `skill-archive {name, reason}`.
- The prompt is adapted from Hermes' curator: prefer umbrella skills, keep specifics
  in `references/`, and never merge hand-written skills.
- **Safety:** before applying any merge, copy the skills it touches to
  `~/.pai/memory/backups/<utc-time>/` (a local snapshot; the general mechanism is
  V3 E6). A merge is reverted as
  one unit.
- **Link rewriting:** when a skill is merged, references to it (in other skills'
  frontmatter `related` fields and in `skills-usage.json`) are updated to the new
  target, following Hermes' cron-reference rewrite.

**Cost.** One LLM run per pass. It counts against the budget, and no preset turns it
on.

**✅ Implemented** (`pai-memory-merge.el`):
- **Worker role:** `merger` (model role `:memory-merger`, which falls back to `:task`),
  so it is not confused with the deterministic curator.
- **Triggers:** `/memory merge` or `/memory curate --consolidate`, or every
  `:merge-interval-days` when that is set (off by default).
- **Finding candidates, no model call.** Learned, unpinned, active skills are grouped
  (union-find) when their name-and-description word overlap reaches
  `:merge-threshold` (0.34). Sharing a distinctive name part counts as 0.5. With no
  groups, no model is called.
- **Proposals:** `skill-merge` (sources, umbrella name, full text) and
  `skill-archive`. Both are validated when filed: only learned, unpinned skills; an
  umbrella name that isn't one of the sources must be free. The C2 checks run on the
  umbrella text. Neither kind is ever auto-applied.
- **Applying** runs as one grouped log record (`:group` of write, move and usage
  operations), after the touched skill directories are copied to
  `~/.pai/memory/backups/<time>-merge/`:
  - the umbrella is written, either replacing a source or as a new learned skill;
  - the other sources move to the skill archive;
  - `related:` lines in other skills are rewritten to the umbrella;
  - the sources' views and uses are added to the umbrella, and the sources are marked
    `merged_into`.
  If any source changed after the proposal was made, it is refused and marked stale.
- **Undo.** `/memory undo` reverts the whole group, newest operation first, and only
  when every result is still as the merge left it.

### C2. Skill quality gates

**Origin.** Hermes `skill_linter.py` (advisory) and `skills_guard.py` (regex security
scan). V1 has only the risky-content banner (V1 §7.3).

**Design.**
- **Linter** (advisory; findings shown in review):
  - frontmatter present and valid;
  - `description` ≤ 1024 chars and phrased as a *when to use*;
  - body under `max-skill-chars` (larger content goes to `references/`);
  - has a "when to use" section and a "steps" section;
  - no absolute paths inside the user's home.
- **Security scan:**
  - the V1 banner patterns, plus write APIs aimed at agent config
    (`~/.pai/`, `init.el`), network fetch-and-execute patterns, encoded payloads, and
    prompt-injection phrases ("ignore previous instructions");
  - a **blocking** finding requires `A` (accept-all) to be refused and an explicit
    `y-or-n-p` per proposal.
- The gates run on **every** skill that enters: learned (V1), imported (C5, and V3 E5), and
  consolidated (C1).

**✅ Implemented** (`pai-memory-quality.el`):
- **Proposals.** Every skill proposal (create and patch) records `:lint`, `:risk`
  (every security finding) and `:block` (the blocking subset). A newer proposal for
  the same skill file replaces the pending one, so the promoter can file an improved
  version after seeing the style findings in its tool receipt.
- **Warnings:** shell or elisp blocks, `sudo`, `rm -rf`, secret names, paths outside
  home and the project, mentions of agent config.
- **Blocking:** download-and-run (`curl … | sh`, `sh <(curl …)`); `rm -rf` of `/`,
  `~` or `$HOME`; writes to `~/.pai/`, `.emacs.d/` or `init.el`; encoded payloads
  (`base64 -d | sh`, eval of base64, blobs of 200+ characters); instruction overrides
  ("ignore previous instructions", "without asking the user", "you are now").
- **How findings are handled:**
  - blocking findings never auto-apply under any review policy and never go through
    `A`;
  - accepting one needs `yes-or-no-p` with the finding named;
  - edited text (`e`) is checked again before it is accepted.
- **Lint (advisory):**
  - missing front-matter or description;
  - a description under 20 or over 1024 characters, or one that doesn't say when to
    use the skill;
  - no "When to use" part (a heading, or "when" in the description);
  - no steps (a heading, or a numbered list);
  - a body over `:max-skill-chars` (8000, in `/menu`);
  - hard-coded home paths.
- **`/memory lint [SKILL]`** runs both checks over existing skills.

**Cost.** None.

### C3. `/learn` from sources, and the large-skill layout

**Origin.** Hermes `learn_prompt.py`. V1 `/learn` only uses the current session.

**Design.**
- `/learn <description> [--from URL|DIR|BUFFER ...]`: the promoter gets read-only
  fetch/read tools, limited to the named sources.
- **Large sources** use the knowledge-base layout: a lean `SKILL.md` index plus
  `references/<chapter>.md`. The `pai-skills` loader already reads only `SKILL.md`,
  and references are loaded on demand with `read`.
- **Output** is still proposals (`skill-create` with several files). The review UI
  shows the file tree and a diff for each file.

**Cost.** On demand, and counted against the budget (like `/learn` in V1, the user
starts it explicitly).

**✅ Implemented** (`pai-memory-learn.el`):
- **Syntax:** `/learn DESCRIPTION --from SOURCE...`. Every word after `--from` is a
  source: an `http(s)://` URL, a live buffer name, a file, or a directory, relative to
  the project.
- **Sources.** URLs are fetched when the command runs, with Emacs's built-in `url`
  library (30 s timeout, HTTP errors reported). HTML becomes text through libxml and
  `shr` when available. URLs and buffers are saved, redacted and capped at 400k
  characters, under `~/.pai/memory/learn-sources/<time>/`. Files and directories are
  read in place.
- **Tools.** The promoter's read-only `read`/`grep`/`ls` roots are the snapshots, the
  named files and directories, the skill directories and `~/.pai/memory`. Its prompt
  gets a "Sources to learn from" section with knowledge-base guidance.
- **Knowledge-base skills.** `skill-create` accepts
  `references: [{path, content}]`, at most 30 files, each forced under
  `references/*.md`, with no `..`. The security scan covers the references too; lint
  covers `SKILL.md` only. Accepting writes `SKILL.md` and the references as one
  logged group, so `/memory undo` removes the whole skill. The review buffer lists
  each reference file with its diff.

### C4. Skill evaluation (smoke test before accepting)

**Origin.** Follow-up to V1 G4. V1 improves skills from outcome evidence *after* use.

**Design.**
- A `skill-create` or `skill-patch` proposal can carry an optional `check` section:
  a short task plus success criteria.
- From the review UI, `t` runs the check with a pai-subagents `worker` role in a
  **scratch copy** of the project (a git worktree or temp dir). The worker is given
  the proposed skill text.
- The result (pass/fail plus transcript link) is attached to the proposal. It never
  auto-accepts.

**Cost.** One subagent run per check, on demand and budgeted.

**Status.** Experimental. The value depends on how often learned skills turn out
wrong.

**✅ Implemented** (`pai-memory-evaluate.el`). It deviates from the design above: it
uses pai-memory's own budgeted worker runtime (role `evaluator`, model role
`:memory-evaluator`) instead of a pai-subagents `worker`. That way the run counts
against the memory budget, shows in the activity line, has a timeout
(`:evaluator-timeout` 600) and never posts into the conversation.
- **Checks.** The promoter may attach `check: {task, criteria}` to
  skill-create/patch. `t` in review asks for the task (pre-filled) and needs a yes.
  `C-u t` runs in an empty directory instead.
- **Scratch.** A detached `git worktree` of HEAD (uncommitted changes aren't in it),
  otherwise a copy of the project (refused above 5000 files), or an empty directory.
  The proposed `SKILL.md` and its references are installed at `.pai/skills/<name>/`
  there. The scratch copy is removed afterwards, including `git worktree remove`.
- **Tools.** `read`/`grep`/`ls`/`write`/`edit` are confined to the scratch copy.
  `bash` starts in it but **is not sandboxed**, which is why a run needs a yes. The
  run ends with `verdict(pass, notes)`.
- **Results.** Pass, fail, no verdict, timeout or error is saved on the proposal
  with notes, the task and the transcript path. Review shows ✓ tested /
  ✗ test failed, plus the details. A test run never accepts anything.
- **Refused:** proposals with blocking security findings, non-skill proposals, and
  proposals that aren't pending.
- **Automatic runs** (decision 2026-09-23, open question 4). `:long-term :auto-test`,
  **off by default**, is in `/menu` as *Test new skills automatically*. When on:
  - **Which.** After the promoter files proposals (`pai-memory-proposals-hook`),
    every skill proposal with a check and **no security findings at all** (not even
    warnings) is tested without asking.
  - **How.** One at a time in the pai buffer, within the memory budget.
  - **Unchanged.** Proposals with warnings, or without a check, are only run by `t`,
    which asks first. Automatic runs never accept anything.

### C5. Skill sharing: export/import, bundles, hub

**Origin.** Hermes skills hub, bundles, and agentskills.io compatibility. V1 skills
already use the standard `SKILL.md` format.

**Design.**
- `/skills-export <names|--learned> <dir|.tar.gz>` and
  `/skills-import <path|git-url>`.
  - Imports go through the C2 gates and appear as `skill-create` proposals with
    `origin: imported`.
  - A **sync manifest** records the origin hash of each skill (Hermes
    `skills_sync.py`). An upstream update is applied only if the local copy is
    unchanged; otherwise it becomes a proposal.
- **Bundles:** frontmatter `bundle: <name>`, and a `/bundle-name` slash command loads
  every skill in the bundle.
- A **hub** (search and install from GitHub topics or agentskills.io) **moved to V3**
  (item E7 in `docs/SPEC-learning-memory-v3.md`), to follow once import has been used.

**✅ Implemented** (`pai-memory-share.el`; bundles in core `pai-commands.el`):
- **`/skills-export NAME...|--learned|--all DEST`.** Copies each skill's directory
  (loose `NAME.md` skills become `NAME/SKILL.md`) plus a `pai-skills.json` manifest of
  names and hashes. DEST may end in `.tar.gz`, which uses `tar`.
- **`/skills-import DIR|FILE.tar.gz|GIT-URL`.** Git URLs are shallow-cloned. Imports
  go to `~/.pai/skills/imported/` with `origin: imported`, `imported-from` and
  `imported` front-matter. Only `SKILL.md` and `references/*.md` come in; other files
  are listed as left out.
- **Deviation from the text above:** upstream updates are **never applied
  automatically**. Imported text is third-party instructions, so an update is always
  a `skill-patch` proposal. Its rationale says whether you edited your copy; the
  manifest `~/.pai/memory/imported-skills.json` compares the installed hash to the
  file. A name already used by a non-imported skill is skipped.
- **Recording.** A new hook, `pai-memory-proposal-accepted-functions`, records an
  install in the manifest. Accepting an edited skill keeps the provenance written in
  its text; `pai-memory-normalize-skill` gained a `provenance` argument.
- **Bundles.** A skill's `bundle: NAME` (or `[a, b]`) registers `/bundle:NAME`, which
  sends every member skill followed by the arguments. Bundles are re-registered on
  `/reload` along with the skills.

### C6. Project skills in git

**Origin.** V1 Q8.

**Design.**
- When accepting a `project`-scope skill in a trusted git repo, the review UI offers
  `g` = accept + `git add`. It never commits.
- A project setting `:commit-project-skills ask|never` controls this.
- Learned project skills record `source-session`, which is meaningless to teammates.
  So when the skill is added to git, that field is replaced with `learned-by: pai` and
  a date.

**✅ Implemented.**
- **Which proposals.** A `skill-create` or `skill-patch` writing under
  `<project>/.pai/skills/` inside a git work tree. (`project` scope already needs a
  trusted project.)
- **Keys.** In `/memory-review`, `G` accepts and stages the skill directory, never
  committing. With `:commit-project-skills ask` (the default), `a` offers the same.
  `never` turns both off.
- **Front-matter for teammates.** Before writing, `source-session:` becomes
  `learned-by: pai` plus a `learned:` date.

---


## 5. Track E — Operations (E3, E4; the rest of track E is in V3)

### E3. Spend insights and preset recommendations

**Origin.** V1 §4.5 records costs. Using that data is the obvious next step (compare
Hermes `insights.py`).

**Design.**
- `/memory insights [days]` reports, from `memory.cost` entries and `state.json`:
  - spend per role, per project, and per day;
  - calls per 100k transcript tokens;
  - observation lag at compaction time;
  - share of `llm-fallback` compactions;
  - proposals accepted, rejected, and stale.
- **Recommendations** follow fixed rules, for example:
  - "84% of sessions never reached compaction → `near-compaction` would save
    $X/month";
  - "fallback compactions 30% → observers too slow: raise concurrency or use a
    faster model".
- Nothing is changed automatically.

**✅ Implemented** (`pai-memory-insights.el`, `/memory insights [DAYS]`):
- **Sources.** Sessions modified in the window. `memory.cost` entries are dated by
  their run id, since they carry no timestamp. Only cost, compaction and promotion
  lines are parsed; message lines are measured by length, so transcript tokens are
  approximate. Proposals are dated by `created`.
- **Figures:** spend per role, project and day; observer calls per 100k transcript
  tokens; compactions by strategy (`observational+summary` and `summary` count as
  lagging); how many sessions reached compaction; empty promoter runs; proposal
  outcomes.
- **Suggestion rules:**
  - ≥50% of sessions never compacted while observing continuously → the `economy`
    preset, with the observer spend it would have saved;
  - ≥25% of compactions lagging → more concurrency, a faster model, or smaller
    chunks;
  - ≥50% of proposals rejected → promote less often;
  - ≥80% of promoter runs empty → promote at session end only;
  - runs on unpriced models → dollars are not counted.
- **Real data** (2 days): 158 runs and 2.2M billable tokens, reported in 0.22 s. No
  session had reached compaction yet, so it suggested `economy`.

### E4. Replay `shake` entries on load

**Origin.** V1 §12.1 notes that `shake` entries have the same resume problem as
`compaction`, and V1 may leave them out of scope.

**Design.** Store the elided placeholder content (or the rule that recreates it
deterministically) in the `shake` entry, and apply it in
`pai-session-context-messages`, as V1 does for compaction. Needs a small change in
`extensions/pai-shake/`.

**✅ Implemented.**
- **Generic in core.** Any session entry may carry `:replacements`, a list of
  `(:entryId ID :message M)`. `pai-session-context-pairs` applies the replacements on
  the branch, oldest first, and marks usage anchors stale from the first edited
  message on. `pai-session-context-messages` is built on top of it.
- **Recording.** `pai-session-replacements` computes the edits from the live context
  before and after. Differences only in `:usage-stale` don't count. A context that
  doesn't mirror the session records nothing, as before.
- **`/shake`** stores its edits in its `shake` entry.
- **Observational compaction** compares against the edited messages, so it still
  works after a shake.
- **Limit:** a shake that changes a compaction summary message, which has no entry
  of its own, can't be replayed.

## 6. Track F — User experience

### F1. Memory browser buffer

**Design.**
- `/memory-browse` opens a tabulated buffer with the sections: LTM entries (by
  target), project topics (B1), session topics, observations on the current branch,
  learned skills (with usage and state), and pending proposals.
- **Keys:**
  - `RET` opens an item;
  - `e` edits (LTM edits go through the same logged, undoable apply path);
  - `d` removes (a `memory-remove` via the log);
  - `s` jumps to the source (the observation's session entry, via the entry id);
  - `/` runs an A1 search.

**Cost.** None. Could be the first V2 item, since it makes V1 easier to debug.

**✅ Implemented** (`pai-memory-browse.el`, `/memory-browse`):
- **Layout.** A sectioned `special-mode` buffer tied to the pai buffer it was opened
  from, rather than `tabulated-list`, which can't show sections.
- **Sections:** long-term memory, session topics and journey, observations on the
  current branch, skills (usage and state), pending proposals. Project topics wait
  for B1.
- **Removing (`d`):**
  - a memory entry is removed through the logged path;
  - an observation is hidden with `memory.redacted` on the live branch;
  - a learned skill is archived (restore with `/memory-restore-skill`);
  - a proposal is rejected;
  - hand-written skills are refused.
- **Other keys:** `s` shows the source messages of an observation's batch; `/`
  searches with A1.

### F2. "Why do you know this?" provenance

**Design.**
- A `provenance` command at point on any LTM entry or learned skill shows the chain:
  entry → proposal (rationale, evidence) → observations → session entries.
- Every step can be clicked. Sessions open read-only at the source entry.

**Depends on.** B2 (stable entry ids) and FC1.

**✅ Implemented** (`pai-memory-why.el`). Entry points: `/memory why QUOTE|SKILL`,
`w` in `/memory-browse`, and `M-x pai-memory-why-at-point` in a
`USER.md`/`MEMORY.md`/`PROJECT.md` or `SKILL.md` buffer. The `*pai-memory-why*`
buffer shows:
- the entry's metadata;
- the confirmations;
- every logged change;
- the proposal(s): rationale and evidence;
- the source session's observations matching the evidence.

Each observation has a button that opens the session file read-only at the message
the observation covers (`coversFromId`). Skills show their front-matter provenance,
usage and the changes and proposals that touched the file.

### F3. Learning graph / timeline

**Origin.** Hermes `learning_graph.py` ("learning made visible").

**Design.**
- **Nodes:** learned skills and LTM entries.
- **Edges:** explicit `related` frontmatter, lexical overlap between entries and
  skills (the top 4, as in Hermes), and shared source sessions.
- **Rendering**, in two options:
  - an Org buffer timeline, grouped by week (no dependency);
  - Graphviz SVG in an image buffer, or the xwidget browser if present.

**Status.** Nice to have; low priority.

**✅ Implemented** (`pai-memory-graph.el`, no model calls):
- **`/memory timeline [DAYS]`** opens an Org buffer with one heading per ISO week and
  day. Events come from:
  - entry metadata: learned, saved, written, confirmed, removed;
  - the change log: skills created, improved, merged or archived; topic conflicts
    resolved; forget; undo;
  - rejected proposals, with the reason given.

  A "Connections" section lists each node's edges.
- **Edges.** In priority order, one per pair: `related:` front-matter, a shared source
  session, and lexical similarity (Jaccard ≥ 0.2, top 4 per node).
- **`/memory graph`** writes `~/.pai/memory/learning-graph.dot`. When `dot` is
  installed it renders SVG (neato) and shows it.
- **Proposal timestamps.** Proposals now record `decided` when their status leaves
  pending.

---

## 7. Track G — Privacy and teams

### G1. `/memory forget`

**Design.**
- `/memory forget <text|regex> [--scope project|all] [--dry-run]` finds matches in
  LTM, project and session topics, observation ledgers, `index.sqlite`,
  `skills-usage.json`, and learned skills.
- It shows the full list, then asks for confirmation.
- **Deletion:**
  - LTM, topics, and skills are rewritten, logged, and undoable; the files touched
    are copied to `~/.pai/memory/backups/<utc-time>/` first (general backups: V3 E6);
  - the index is purged and vacuumed;
  - observations in session JSONL are masked with a `memory.redacted` ledger entry
    that the fold honors. Session files are never rewritten; they are append-only.
- ~~`--hard` also rewrites session JSONL files to remove the raw messages.~~
  **Dropped** (decision 2026-09-23, open question 5): pai never rewrites session
  files. Masking is final.

**✅ Implemented without `--hard`** (`pai-memory-privacy.el`), as
`/memory forget TEXT [--regex] [--all] [--dry-run]`. `--all` extends the default
project scope to every project.
- **Plan first.** It lists matches per file, observations per session, skill usage
  notes, and index rows, then asks for confirmation. `--dry-run` only lists.
- **Rewrites:**
  - long-term memory: whole `§` entries are removed;
  - topic, journey and archive files: matching lines are removed;
  - learned skills: matching body lines are removed; front-matter is kept;
  - skill usage notes: matching notes are removed.
  Each rewritten file is copied to `~/.pai/memory/backups/<time>/` first and logged,
  so `/memory undo` restores it.
- **Observations** are hidden with a `memory.redacted` entry appended at *every
  leaf* of the session. The ledger fold treats it like `memory.dropped`. A session
  that is open in a buffer is changed through its live object, so the buffer's
  branch stays correct.
- **The index.** Matching rows are deleted and the FTS index optimized. The
  forgotten text (or regexp) is saved to `state.json :forgotten` and becomes a
  redaction pattern, so a reindex or a later memory write can't bring it back.
- **Not rewritten, by design:** raw conversation text in session files, and existing
  compaction summaries. Session files are append-only and are never rewritten (open
  question 5).

### G2. Team and shared project memory

**Design.**
- An optional `<project>/.pai/memory/PROJECT.md`, committed to the repository and
  reviewed like code.
- It is loaded into the snapshot **before** the personal project `MEMORY.md` and
  always read-only for the promoter. The promoter can propose `team-memory-add`, which
  the review UI turns into a file edit and never commits (same as C6).
- Only loaded in trusted projects.

**✅ Implemented.**
- **Target.** `team` is a target (`<project>/.pai/memory/PROJECT.md`,
  `:team-char-limit` 4000). It is active only when the project is trusted, and comes
  before the personal project memory in the snapshot.
- **Who writes it.** The memory tool refuses it, and `memory-*` proposals can't target
  it. The promoter files `team-memory-add|replace|remove`; those are never
  auto-applied.
- **Git.** In review, `G` (and `a` with `:commit-project-skills ask`) stages
  `PROJECT.md` and never commits.
- **Not indexed** for search: it lives in the repository, and the index doesn't track
  project roots.

### G3. User-defined redaction and private sessions

**Design.**
- A setting `:redact-patterns` (a list of regexes) extends the V1 §10 filter, and
  matches are replaced with `[redacted:<name>]`.
- `/memory private` marks a session as private:
  - no observers, no promotion, no indexing (A1);
  - existing index rows for that session are dropped;
  - a `memory.state {private: true}` entry records it.

**✅ Implemented.**
- **Custom redaction.** `:memory :redact-patterns` accepts regexp strings or
  `[NAME, REGEXP]` pairs. Invalid regexps are ignored. The patterns join the built-in
  secret filter (`pai-memory-redact`), which now also runs on everything written to
  the search index. That index used to keep raw transcripts, secrets included.
- **`/memory private [on|off]`.** `pai-memory-private-p` gates the session layer,
  learning (including catch-up), and recall. The indexer decides a file's private
  state from its last `memory.state` line: a private session's rows are dropped and
  it is skipped; one made public again is re-read from the start. The whole file is
  scanned only on a first read, or when the new tail mentions `private`.
- **Indicators:** 🔒 in the widget and `/memory`.
- **Real data:** a first full index now takes 6.7 s instead of 2.1 s, because every
  row is redacted. It runs in 0.2 s idle slices; later passes take 0.014 s.

---

## 8. Waves (proposed order)

| Wave | Items | Theme | Why this order |
|---|---|---|---|
| **2.0** ✅ | A1, A2, E3, E4, F1, G1, G3 | Recall, visibility, privacy, spend | Low risk, no LLM, and it makes V1 debuggable. Search is the most requested missing feature; E4 fixes a live gap (shaken context comes back after `/resume`). |
| **2.1** ✅ | C1, C2, C3, C5 (import/export), C6 | Skills at scale | The quality gates (C2) must exist before any bulk skill operation (C1, C5). |
| **2.2** ✅ | B1, B2, B3, F2, G2 | Structure | Changes the on-disk format, so it goes last and needs a migration. |
| **2.x** ✅ | A3, B4, C4, F3 | Experimental | Only if measurements justify them. |

**Hard ordering constraints:**
- A2 needs A1.
- B3 needs A1 and A2.
- F2 needs B2.
- C1 and C5 each need C2.
- C1 and G1 back up the files they change themselves (see each item); they do not
  wait for V3 E6.

## 9. Forward-compatibility requirements for V1

These are cheap now and expensive to retrofit. The proposal is to fold them into V1
(see the pointer in V1 §16).

- **FC1. Apply log keys:** every LTM change in `log.jsonl` records `{proposal_id,
  target, before, after, entry_text_hash}`, so B2 can rebuild stable entry ids and F2
  can rebuild provenance from history.
- **FC2. Provider version:** provider plists accept, and the manager ignores, unknown
  keys, and `:api-version` is reserved (V3 D1).
- **FC3. Unknown proposal kinds:** the review UI shows unknown `kind` values as
  read-only with a "requires newer pai-memory" note, instead of erroring.
- **FC4. Ledger entry types:** the fold ignores unknown `memory.*` custom types, which
  keeps room for `memory.reflections` and `memory.redacted`.
- **FC5. `state.json` version:** it includes `"version": 1`, and loading an unknown
  newer version is read-only.
- **FC6. Session memory paths:** they go through one function (`pai-memory-dir`),
  never through hard-coded strings. This way B1 and V3 E2 can relocate them.
- **FC7. Cost roles:** `memory.cost` accepts any role symbol, so later roles fit:
  `embed`, `merger`, `curator`, `reflector`, `rewrite`.

## 10. Open questions (for the review after V1)

1. **A2:** on by default once measured, or stay opt-in? *(Decided 2026-09-23: stays
   opt-in; revisit after use.)*
2. **B1 vs per-session topics:** keep both, or consolidate directly into the project
   tree? *(2.2 keeps both; see B1.)*
3. **B2:** is sidecar metadata enough, or should entries carry inline markers (which
   cost tokens in the snapshot)? *(2.2: sidecar only.)*
4. **C4:** is sandboxed skill evaluation worth its cost, given V1's outcome-driven
   patching? *(Decided 2026-09-23: keep it on demand, plus automatic runs behind a
   setting that is off by default, only for proposals with no security findings.)*
5. **G1 `--hard`:** should pai ever rewrite session files, or should
   masking be the only option? *(Decided 2026-09-23: never; masking only.)*
6. Anything learned from running V1 that should replace items on this list.
