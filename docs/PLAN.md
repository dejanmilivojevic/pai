# pai — Pi Agent for Emacs: Implementation Plan

Port of the `earendil-works/pi` agent harness to Emacs Lisp. Goal: a self-extensible
coding agent that runs entirely inside Emacs, using Emacs itself as the operating
system for tool calling (buffers, files, processes, elisp), with an Emacs-buffer UI
replacing pi's terminal TUI.

## Package identity

- Prefix: `pai-` (Pi Agent for emacs).
- Single package, multiple files under `lisp/`. Not split into npm-style packages,
  but internally layered the same way pi is (ai / agent-core / coding-agent / ui)
  and extensible via a public extension API.
- Emacs 29.1+ (native `json-parse-buffer` / `json-serialize`, `make-process`).

## Source-of-truth mapping (pi -> pai)

| pi package/module                        | pai file(s)                              |
|------------------------------------------|------------------------------------------|
| `packages/ai` types                      | `pai-core.el` (message/content/tool model)|
| `packages/ai` providers + streaming      | `pai-http.el`, `pai-provider.el`, `pai-provider-*.el` |
| `packages/ai` models catalog             | `pai-models.el`                          |
| `packages/agent` agent-loop + events     | `pai-agent.el`                           |
| `packages/agent` harness tools           | `pai-tools.el`, `pai-tools-builtin.el`  |
| `packages/coding-agent` extensions       | `pai-ext.el`                             |
| `packages/coding-agent` skills           | `pai-skills.el`                          |
| `packages/coding-agent` slash-commands   | `pai-commands.el`                        |
| `packages/coding-agent` system-prompt    | `pai-prompt.el`                          |
| `packages/coding-agent` session-manager  | `pai-session.el`                         |
| `packages/coding-agent` config           | `pai-config.el`                          |
| `packages/tui` (terminal UI)             | `pai-ui.el` (Emacs buffers)             |
| entry / CLI                              | `pai.el`                                 |

## Design principles carried over from pi

1. **Unified message model.** One normalized transcript of typed messages
   (system/user/assistant/tool-result) with typed content blocks
   (text/thinking/tool-call/tool-result/image). Providers translate to/from
   this model. This is the contract the whole system rests on.
2. **Event-driven agent loop.** The loop emits a stream of events
   (`agent_start`, `turn_start`, `message_start/update/end`,
   `tool_execution_start/end`, `turn_end`, `agent_end`). The UI and extensions
   are pure consumers of events. Loop logic never touches Emacs UI directly.
3. **Hooks around the loop.** `before-tool-call`, `after-tool-call`,
   `should-stop-after-turn`, `prepare-next-turn`, steering + follow-up message
   queues. Same contract as pi's `AgentLoopConfig`.
4. **Tool = plist with schema + executor.** Tools declare a JSON-schema for
   arguments and an executor function that returns a result
   (`:content`, `:details`, `:is-error`) and may stream incremental output.
5. **Everything is an extension point.** Built-in tools, skills, slash commands,
   and the system prompt are all registered the same way an extension registers
   them. Extensions are elisp files loaded from `.pai/extensions/` (mirroring
   pi's `.pi/extensions/`) plus in-Emacs registration functions.
6. **Emacs as the OS.** Tool calling uses Emacs facilities: `make-process`/shell
   for bash, buffers+`find-file` for read/edit/write, `xref`/`project.el`/`grep`
   for search, and a first-class `elisp-eval` tool that evaluates in the live
   Emacs image. This is the key differentiator from pi.

## Transport decision

Streaming SSE is required for a responsive UI. Emacs `url.el` does not stream
cleanly, so use `make-process` running `curl -N` and parse the SSE byte stream
incrementally in a process filter. Non-streaming fallback uses the same path with
buffered parse. `curl` is assumed present (checked at runtime).

## Phased plan

- **Phase 0 Research** — study pi, digest scout reports, write docs. (this phase)
- **Phase 1 CoreModel** — data model constructors/accessors, JSON (de)serialization,
  JSON-schema helpers, model catalog, config + API-key resolution. Tests.
- **Phase 2 Providers** — curl SSE transport; Anthropic, OpenAI, Gemini providers
  (request build + stream parse -> unified events); faux in-process provider for
  deterministic tests. Tests.
- **Phase 3 AgentLoop** — event stream primitive, agent loop, tool execution
  (sequential/parallel), hooks, steering/follow-up. Tests with faux provider.
- **Phase 4 Tools** — tool registry + tool context; built-in tools (bash, read,
  edit, write, ls, grep, find) implemented with Emacs; native tools (elisp-eval,
  buffer ops). Tests.
- **Phase 5 Extensibility** — extension loader/runner, ExtensionAPI, skills,
  slash commands, system-prompt assembly. Tests.
- **Phase 6 Session** — jsonl session persistence + resume. Tests.
- **Phase 7 UI** — chat buffer major mode, streaming render, tool-call rendering,
  input handling, keybindings, interactive commands.
- **Phase 8 Integration** — end-to-end faux-provider smoke test through the real
  UI, README + docs, final cleanup, full suite green.

## Verification policy

Every phase ships with ERT tests runnable via `make test`. Provider stream parsing
is tested against captured SSE fixtures. The agent loop and tools are tested with a
faux provider (no network, no API keys). The UI is smoke-tested by driving the real
commands in batch/headless Emacs and asserting buffer contents. No phase is "done"
until its tests pass under `make test`.
