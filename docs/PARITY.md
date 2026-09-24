# pai ↔ pi Feature Parity

Goal: implement, in Emacs Lisp, the full user-facing and architectural feature
set of the `pi` coding agent. This file is the authoritative parity checklist
and plan.

## STATUS: COMPLETE

All parity phases below are implemented and covered by the ERT suite
(`make test`, 246+ tests) with a clean `make compile`. Live end-to-end verified
against Anthropic-shaped SSE (test) and a real OpenAI-compatible server.
Constrained-sampling/strict-tool schemas are the one deliberately partial item
(see "Intentionally adapted"). Legend: [x] done · [—] adapted/omitted.

## Core (from v0.1)
- [x] Unified message/content/tool model + JSON
- [x] Providers: Anthropic Messages, OpenAI Chat Completions (+ compatible), Google Gemini; streaming over curl
- [x] Agent loop: turns, tool calling, hooks (before/after tool, should-stop, prepare-next-turn, transform-context), steering + follow-up queues, truncation handling, abort
- [x] Built-in tools: bash, read, write, edit, ls, grep, find + Emacs-native elisp_eval, list_buffers, read_buffer
- [x] Extension API: event bus, register tool/command/provider/model, reducing hooks (context/tool-call/tool-result/before-agent-start/input), `.el` loader
- [x] Skills discovery + system-prompt section
- [x] Slash commands: registry + /help /tools /skills + skill/prompt commands
- [x] System prompt assembly (XML sections)
- [x] Session persistence (JSONL, reload)
- [x] Chat UI: streaming, tool rendering, steering, read-only transcript, header line
- [x] Markdown table alignment; Helm/annotated `/`-command completion

## Parity work (this effort)

### Phase A — Settings & config
- [x] `pai-settings.el`: layered settings (global `~/.pai/settings.json` + project `.pai/settings.json` + Emacs custom), typed keys, precedence, get/set/save
- [x] `/settings` command (editable settings buffer)
- [x] resolve-config-value semantics (env/flag/project/global/default)

### Phase B — Model system
- [x] Model system beyond pi: persisted provider endpoints (`pai-add-provider`,
  `/provider`), live discovery (`/model` queries configured providers), qualified
  `provider/model` selection with unique bare-ID resolution; no hardcoded catalog —
  hosted providers ship as the opt-in `examples/pai-hosted.el` extension
- [x] Custom OpenAI-compatible/Anthropic/Gemini provider + model config from settings
- [x] Scoped models (main/task/compact roles)
- [x] Thinking levels wired end-to-end; `/thinking`, `/model`, `/scoped-models`

### Phase C — Context compaction
- [x] `pai-compaction.el`: token estimation, threshold, cut point, LLM summary, compaction entry
- [x] Auto-compaction on threshold/overflow + `/compact`; session_before_compact/session_compact events
- [x] `/shake` (`elide`/`images`/`thinking`) mechanical context reduction with recovery artifacts — `extensions/pai-shake/` (manual command; the automatic shake tiers of the upstream compaction pipeline are not ported)

### Phase D — Session tree & management
- [x] Session entry types (model_change, thinking_level_change, compaction, branch_summary, custom, custom_message, label, session_info) + parentId tree
- [x] `/new` `/resume` (list + pick) `/session` `/name` `/fork` `/clone` `/tree` navigation; session_* events

### Phase E — Full extension API
- [x] Renderers: register-message-renderer, register-entry-renderer, register-markdown-transformer
- [x] UI: setWidget (above/below editor overlays), setStatus, setHeader, setFooter, setTitle, working indicator, setToolsExpanded
- [x] register-shortcut (keys), register-flag, addAutocompleteProvider, custom UI prompts (select/confirm/input/editor/custom)
- [x] Emit all remaining events: session_start/switch/shutdown/info_changed/before_*, model_select, thinking_level_select, user_bash, resources_discover, project_trust, before_provider_request/headers, after_provider_response, agent_settled, ui_prompt_start/end, turn_start/end indices

### Phase F — Project trust
- [x] `pai-trust.el`: trust store, states (yes/no/undecided), prompt, gate extensions/skills/prompts; `/trust`

### Phase G — Auth / login / logout
- [x] `pai-auth.el`: credential store (`~/.pai/auth.json` / auth-source), `/login` `/logout`; OAuth framework (Anthropic, github-copilot) best-effort; API-key flow

### Phase H — Parallel tool execution
- [x] Parallel tool mode in the agent loop (preflight sequential, execute concurrent, order results)

### Phase I — Rich rendering
- [x] Full markdown rendering (headings, bold/italic, inline code, code blocks w/ fontlock, lists, links, blockquotes, hr) + tables
- [x] Edit/write diff rendering (unified colored diff)
- [x] Usage/cost footer (context %, tokens in/out/cache, cost) via footer/header line

### Phase J — Export / share / copy
- [x] `pai-export.el`: session → Markdown and HTML; `/export` `/copy` `/share`

### Phase K — Prompt templates & bang & mentions
- [x] Prompt templates from `.pai/prompts/*.md` (+ `~/.pai/prompts`) with `$ARGUMENTS`/placeholders → `/name`
- [x] `!cmd` / `!!cmd` shell (user_bash event; !! excludes from context)
- [x] `@file` mention autocomplete in the input

### Phase L — Remaining commands & modes
- [x] `/changelog` `/hotkeys` `/reload` `/import` `/quit` `/clear`
- [x] Non-interactive modes: `pai-run`/print mode (one-shot prompt → answer), programmatic API (`pai-send-message`)

### Phase M — Caching, tool_choice, constrained sampling
- [x] Anthropic `cache_control` markers + OpenAI `prompt_cache_key`
- [x] tool_choice (auto/none/required/specific)
- [—] Constrained sampling / strict JSON-schema tool grammars → tool_choice is
      implemented for all providers; provider-side strict/grammar constraints
      are not (rarely needed; the agent validates tool args itself).

## Intentionally adapted / out of scope (with reason)
- [—] Terminal differential renderer (`packages/tui`) → replaced by Emacs redisplay.
- [—] npm/binary distribution, shrinkwrap, build scripts → not applicable to an Elisp package.
- [—] Telemetry vendor backends / `chord` runtime / server/client RPC packages → infra, not agent features; a minimal event hook layer suffices.
- [—] AWS Bedrock / Vertex SigV4/ADC providers → heavy cloud auth; OpenAI-compatible + Anthropic/Gemini cover the same capability. May add later.
- [—] Image generation API → not core to the coding agent (can be an extension).

## Verification policy
Every phase ships ERT tests (faux provider / fixtures / temp dirs), keeps
`make compile` clean and `make test` green, and is reflected in STATUS.md.
