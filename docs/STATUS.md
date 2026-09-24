# Status

Living progress log. Newest entries at top.

## Legend
- [ ] not started · [~] in progress · [x] done (tests green)

## Phases
- [x] Phase 0 Research
- [x] Phase 1 CoreModel
- [x] Phase 2 Providers
- [x] Phase 3 AgentLoop
- [x] Phase 4 Tools
- [x] Phase 5 Extensibility
- [x] Phase 6 Session
- [x] Phase 7 UI
- [x] Phase 8 Integration

All phases complete. 117 ERT tests green (`make test`), clean byte-compile
(`make compile`). Package loads and `M-x pai` opens the chat buffer.

## Log

### 2026-09-17 (provider configuration refactor)
- Removed all hardcoded providers and model catalogs from core: no provider or
  model registers implicitly. API adapters (openai/anthropic/gemini) remain.
- New `pai-providers.el`: persisted provider endpoints via `pai-add-provider`
  (`/provider add`) saved to `~/.pai/settings.json` (`custom-providers`/
  `custom-models` keys); live model discovery with `pai-models-refresh` —
  `/model` queries every configured provider (OpenAI `/models`, paginated
  Anthropic/Gemini), shows `provider/id` identities, reports per-provider
  errors, and preserves configured fallbacks. Registry keys models by
  `provider/id`; unique bare IDs still select. Extension `:list-models`
  callbacks supported.
- Deleted `setup-wsl.el` (superseded by `pai-add-provider`; port override +
  discovery cover the WSL-host server flow). Hosted providers/models moved to
  the opt-in `examples/pai-hosted.el` extension; Anthropic/Copilot OAuth now
  installs via the new `pai-auth-oauth-handlers` registry instead of a core
  provider list.
- 276 ERT tests green, clean byte-compile; verified end-to-end in a real TUI
  against a live OpenAI-compatible server (add provider with port, discovery
  in `/model`, qualified selection persistence, streamed reply).

### 2026-09-17 (parity effort complete)
- Achieved 1:1 feature parity with pi's coding agent (see docs/PARITY.md, all
  phases done). Added: layered settings + `/settings`; expanded model catalog,
  OpenAI-compatible providers, custom providers/models, scoped models, thinking
  levels (`/model` `/thinking` `/scoped-models`); context compaction (`/compact`,
  auto); session tree (ids/parentId, `/new` `/resume` `/session` `/name`
  `/fork` `/clone` `/tree` `/import`); full extension API (renderers, widgets,
  status/header/footer, shortcuts, flags, autocomplete, all events); project
  trust (`/trust`); credential store + OAuth framework (`/login` `/logout`);
  parallel tool execution; full markdown renderer + edit/write diffs + usage/cost
  footer; export (`/export` `/copy` `/share`); prompt templates, `!`/`!!` shell,
  `@file` mentions; `/changelog` `/hotkeys` `/reload` `/clear` `/quit`;
  programmatic `pai-send-message` + headless `pai-oneshot`; prompt caching +
  tool_choice across providers.
- 246 ERT tests green; clean byte-compile. Verified live against a real
  OpenAI-compatible server (streaming text, tool calls, tables) and the bundled
  Anthropic-SSE curl end-to-end test.

### 2026-09-16 (completion)
- Implemented all phases 1-8; 117 ERT tests passing.
- Full stack verified end to end: real curl transport + Anthropic parser +
  agent loop; UI smoke tests drive real commands and assert buffer contents.
- Wrote README, LICENSE; docs/ planning set complete.

### 2026-09-16
- Initialized repo, Makefile, .gitignore, planning docs.
- Confirmed env: Emacs 29.4.50 (native json + make-process), curl present.
- Dispatched two scouts: pi-ai deep dive, coding-agent extension/tool deep dive.
- Studied pi agent-loop.ts, extension API examples (`pi.on`, `ctx.ui`, `pi.exec`).
