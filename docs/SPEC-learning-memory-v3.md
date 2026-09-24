# SPEC: Learning Memory — V3

Status: **PARKED — review after V2.** Nothing here is scheduled.
Builds on: `docs/SPEC-learning-memory.md` (V1) and `docs/SPEC-learning-memory-v2.md`
(V2). Tracks D and E were moved here from V2, except E3 (spend reports) and E4
(`/shake` on resume), which stay in V2. Item ids are unchanged, so "D2" or "E6"
mean the same thing in all three documents.

The rules of V2 §0 apply: every item is opt-in or can be switched off, can ship on
its own, and plugs into V1's cost accounting, presets and budget when it calls a
model.

## 0. Inventory

| # | Item | Origin | LLM cost | Wave |
|---|---|---|---|---|
| D1 | Final provider API + versioning + conformance tests | V1 §6.2 "plugin-ready" | none | 3.0 |
| D2 | Reference providers: Honcho, mem0, local SQLite | V1 "later" row, non-goal | provider-side | 3.1 |
| D3 | Subagent memory (`on-delegation`, read-only snapshot) | Hermes `on_delegation` | none | 3.0 |
| D4 | Pre-compaction checkpoint contract for providers | Hermes checkpoint API v2 | provider-side | 3.1 |
| E1 | Subprocess worker isolation | V1 Q6 | none | 3.x |
| E2 | Cross-machine sync | V1 non-goal, "later" row | none | 3.1 |
| E5 | Import/export (Hermes, Claude Code, pi-om, AGENTS.md) | migration | optional | 3.1 |
| E6 | Snapshot backups and rollback of `~/.pai/memory` and learned skills | Hermes `curator_backup.py` | none | 3.0 |
| E7 | Skills hub: search and install from GitHub topics / agentskills.io | V2 C5 (moved 2026-09-23) | none | 3.1 |

## 1. Track D — Providers

### D1. Final provider API, versioning, conformance tests

**Origin.** V1 §6.2 defines a *provisional* plist interface.

**Design.**
- **Versioning:** add `:api-version` (V1 = 1; the forward-compat item FC2 reserves
  this key now). The manager checks capability per version. This follows Hermes'
  `pre_compress_checkpoint_api_version` approach: only call hooks a provider declares.
- **Hooks added from Hermes** (see the Honcho analysis):
  - `:on-turn-start (turn author ctx)`;
  - `:on-session-switch (new-id &key parent reset rewound)`, called on `/resume`,
    `/tree`, fork, and compaction;
  - `:on-delegation` (D3);
  - `:on-pre-compress` (D4);
  - `:config-schema`, which renders automatically into `/menu` (V1 settings policy);
  - `:backup-paths` (E6).
- **Rules carried from Hermes:**
  - the built-in provider is always on, plus at most one external provider;
  - every call is async and wrapped in `condition-case`;
  - shutdown waits for pending work, with a time limit;
  - a write never runs for a non-primary context (subagent, cron, worker).
- **Conformance suite:** `test/pai-memory-provider-conformance.el`. It is
  parameterized by provider and checks that the provider:
  - never blocks longer than N ms;
  - returns strings;
  - survives `on-session-switch` in the middle of a sync;
  - writes nothing in a non-primary context.

### D2. Reference providers

**Origin.** V1 "later" row: Honcho and mem0 adapters.

Each ships as a **separate extension** (`extensions/pai-memory-honcho/`, …) and none
is loaded by default.

- **Honcho:**
  - `sync-turn` adds messages to a Honcho session, with the user and pai as separate
    peers;
  - `prefetch` injects two layers: base context (summary, representation, card) every
    `context-cadence` turns, and dialectic answers every `dialectic-cadence` turns;
  - tools: `honcho_search`, `honcho_profile`, `honcho_reasoning`, `honcho_conclude`;
  - `on-change` copies `USER.md` adds as conclusions (Hermes behavior);
  - `recall-mode` is `context`, `tools`, or `hybrid`.
- **mem0:** server-side fact extraction. `sync-turn` sends the turn, and `prefetch`
  does a semantic search.
- **Local SQLite provider** (optional, built in): facts with trust scores stored in
  `index.sqlite`. It is a stepping stone for users who want structured memory with no
  service. It might be absorbed by B2 plus A1.
- **Budget:** provider spend happens on the provider's side. The extension must state
  its cost model in its README and in `:config-schema` (V1 §6.2).

### D3. Subagent memory

**Origin.** Hermes `on_delegation`. In V1, pai-subagents children get no memory.

**Design.**
- **Children:** they receive the parent's frozen `<memory>` snapshot, read-only (they
  have no `memory` tool), when the role frontmatter says `memory: read`. Workers from
  V1 §4.3 never receive it.
- **Results:** when a child finishes, its task and result go to `:on-delegation` for
  each provider.
- **Observation:** the observer sees the delegation result as part of the parent
  transcript, which V1 already does. No child transcripts are observed.

### D4. Pre-compaction checkpoint contract

**Origin.** Hermes checkpoint API v2: fail-closed checkpoints before compression.

**Design.**
- `:on-pre-compress (messages &key evidence require-checkpoint)` is called before any
  compaction (observational or LLM).
- A provider that declares `:checkpoint t` promises to have durably stored everything
  about to leave context.
- With `:memory :long-term :require-checkpoint t`, compaction is **delayed** (not
  failed) until the checkpoint succeeds or times out. A timeout falls back to normal
  compaction and shows a notice.

---

## 2. Track E — Runtime and operations

### E1. Subprocess worker isolation

**Origin.** V1 Q6. V1 runs workers in-process.

**Design.**
- A setting `:worker-runtime in-process|subprocess`.
- **Subprocess mode:** run `emacs --batch -l pai -f pai-memory-worker-main` with a
  JSON job file in `.runs/<run-id>.json`. The result file and cost file use the pi-om
  IPC pattern (atomic write, result read on exit).
- **When it matters:** protection against crashes or hangs in long workers, and not
  competing with the UI for CPU during heavy consolidation.
- **Cost:** Emacs startup time per worker (measure it; maybe keep a pool of one warm
  worker).

### E2. Cross-machine sync

**Origin.** V1 non-goal and "later" row.

**Design.**
- `~/.pai/memory/` and `~/.pai/skills/learned/` become a **git repository**, created
  with `/memory sync init <remote>`.
- `/memory sync` does pull (rebase), then push:
  - **Conflicts on `.md` files** go to the review UI as `sync-conflict` proposals.
  - **`skills-usage.json` and `entries.json`** are merged by field: counters are
    summed, timestamps take the maximum.
- **Excluded from sync:** `index.sqlite`, `.runs/`, `proposals/` (machine-local), and
  per-session dirs (optional).
- Syncing is always manual or on a timer; there is no background push without a
  setting.

### E5. Import and export

**Origin.** Migration and portability.

**Design.**
- **Importers**, each producing **proposals** (never direct writes):
  - Hermes: `~/.hermes/memories/MEMORY.md`, `USER.md`, and agent-created skills
    (`created_by: agent`);
  - pi-om: `<project>/.memory/<session>/` topics into the B1 project tree, or into
    the session archive;
  - Claude Code `CLAUDE.md` / project `AGENTS.md`: split into LTM entries, marked
    with an optional LLM pass (budgeted).
- **Export:** `/memory export <dir>` writes plain Markdown plus a manifest.

### E6. Snapshot backups and rollback

**Origin.** Hermes `curator_backup.py`. V1 has only undo for each change.

**Design.**
- Before any operation that changes several files, archive `~/.pai/memory/` (without
  `index.sqlite`) and the learned-skill dirs to
  `~/.pai/memory-backups/<utc-iso>.tar.gz` with a manifest. The operations are: C1
  merges (V2 C1), E2 pulls, E5 imports, and `/memory forget` (V2 G1). V2's C1 and
  G1 ship with a local copy of the files they touch; E6 replaces that with full
  snapshots and `/memory rollback`.
- `/memory rollback [snapshot]` first snapshots the **current** state, so a rollback
  can itself be rolled back, and then extracts the chosen snapshot.
- Keep `backup-keep` snapshots (default 10).

---

### E7. Skills hub

**Origin.** V2 C5 listed it as out of scope until import had been used. It was moved
here on 2026-09-23.

**Design.**
- **`/skills-search QUERY`** lists skills from configured sources: GitHub repositories
  with a `pai-skills` or `agent-skills` topic, and agentskills.io if it offers an API.
  Each result shows its name, description, source and stars or last update.
- **Installing** a result goes through V2 C5 `/skills-import`. Every skill becomes a
  proposal with the C2 gates, `origin: imported`, and update detection.
- **No auto-install and no background polling.** Updates are checked on demand
  (`/skills-import` again) or by an opt-in weekly check that only files proposals.
- **Sources** are a setting (`:skills :hub-sources`), so teams can point at an
  internal repository.

**Cost.** None (HTTP only).

**Depends on.** V2 C5.

## 3. Waves (proposed order)

| Wave | Items | Theme |
|---|---|---|
| **3.0** | D1, D3, E6 | Foundations: the final plugin interface, subagent memory, backups |
| **3.1** | D2, D4, E2, E5, E7 | Things built on them: real providers, checkpoints, sync, import |
| **3.x** | E1 | Only if in-process workers turn out to crash or stall Emacs |

**Hard ordering constraints:**
- D2 and D4 need D1.
- E2 and E5 need E6.

## 4. Open questions

1. **D2:** which external provider first? Honcho is the most featureful; mem0 is
   simpler; the local SQLite provider has no service to depend on.
2. **E2:** git-based sync as proposed, or leave sync to the user's own tools
   (Syncthing, a dotfiles repo) and only document which files are safe?
