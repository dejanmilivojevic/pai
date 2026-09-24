# pai — Pi Agent for Emacs

> [!WARNING]
> **This project was 100% vibe coded.** Every line was written by an AI agent,
> and it may contain a lot of bugs. Use at your own risk.

> Extensions live in a separate repository with its own README:
> [dejanmilivojevic/pai-extensions](https://github.com/dejanmilivojevic/pai-extensions).

`pai` is an Emacs Lisp port of the [`pi` agent harness](https://github.com/earendil-works/pi).
It is a self-extensible coding agent that runs entirely inside Emacs and uses
Emacs itself as its operating system for tool calling: shell, files, project
search, and — uniquely — live Emacs Lisp evaluation and buffer inspection.

Everything is written in Emacs Lisp with no external Elisp dependencies. The
only runtime requirement beyond Emacs 29.1+ is `curl` (for streaming HTTP).

## Features

- **Unified multi-provider LLM API** — Anthropic (Messages), OpenAI
  (Chat Completions, plus any OpenAI-compatible server), and Google Gemini,
  behind one normalized message/streaming model.
- **Streaming** responses via `curl` and process filters, rendered live into a
  chat buffer, with reasoning shown in a dim face and **markdown tables aligned
  into monospace columns** (`string-width`-aware) once a reply finalizes.
- **Event-driven agent loop** with tool calling, **parallel or sequential** tool
  execution, steering and follow-up message queues, and the full set of pi hooks
  (`before-tool-call`, `after-tool-call`, `should-stop-after-turn`,
  `prepare-next-turn`, `transform-context`).
- **Emacs-native tools**: `bash`, `read`, `write`, `edit`, `ls`, `grep`,
  `find`, plus `elisp_eval`, `list_buffers`, and `read_buffer` that expose the
  live editor to the model. File edits render as colorized unified **diffs**.
- **Model system**: persisted provider endpoints and live model discovery;
  no preconfigured hosted providers or hardcoded model catalog. Optional
  extensions add hosted providers. **Scoped models** (main/task/compact) and
  thinking levels are switchable with `/model`, `/thinking`, `/scoped-models`.
- **Context compaction**: token estimation, threshold trigger, LLM summary; auto
  between runs and on-demand via `/compact`.
- **Sessions as a tree**: append-only JSONL with entry ids/parentId; `/new`,
  `/resume`, `/fork`, `/clone`, `/tree`, `/name`, plus Markdown/HTML `/export`.
- **Layered settings** (`~/.pai/settings.json` + project `.pai/settings.json`),
  **project trust** gating, and a **credential store** (`/login` `/logout`,
  API-key + Anthropic/Copilot OAuth framework).
- **Prompt caching** (Anthropic `cache_control`, OpenAI `prompt_cache_key`) and
  provider `tool_choice`.
- **Self-extensible**: an extension API mirroring pi's — event bus (`pi.on`),
  `registerTool`/`registerCommand`/`registerProvider`/`registerModel`, message/
  entry/markdown **renderers**, autocomplete providers, keyboard shortcuts, and
  UI widgets/status/header/footer; loader for `.el` extensions from
  `~/.pai/extensions` and (trusted) `.pai/extensions`.
- **Skills** (`SKILL.md`), **prompt templates** (`.pai/prompts/*.md` → `/name`),
  **slash commands**, `!`/`!!` shell, `@file` and `*buffer` mentions, and an XML-sectioned
  system prompt assembled from tools, skills, and `AGENTS.md`/`CLAUDE.md`.
- **Full markdown rendering** (headings, emphasis, code, lists, quotes, links,
  tables) and a header line showing context usage %, cost, and model. The input
  line stays pinned to the bottom of the window (terminal-style), so output
  streams above it and you can keep typing while a run is in progress.
- **Programmatic/headless**: `pai-send-message` and `pai-oneshot` for scripts.

## Requirements

- GNU Emacs 29.1 or newer (uses native JSON and `make-process`).
- `curl` on `PATH`.
- Optionally `rg` (ripgrep) and `fd` for faster search; `grep` and Emacs
  fallbacks are used otherwise.

## Installation

Clone the repository and add both `lisp/` and the vendored `vendor/vui/`
(the [vui.el](https://github.com/d12frosted/vui.el) UI toolkit used by the
settings screen) to your `load-path`:

```elisp
(add-to-list 'load-path "/path/to/emacs-agent/lisp")
(add-to-list 'load-path "/path/to/emacs-agent/vendor/vui")
(require 'pai)
```

## Configuration

Run `M-x pai-add-provider` (or `/provider add` in chat). Enter the full API
base URL, optional port override, API type, optional fallback model name,
and provider ID. Configuration is saved in `~/.pai/settings.json`; no init-file
provider registration is needed.

For a local OpenAI-compatible server, the resulting configuration looks like:

```json
{"custom-providers":[{"id":"local","base-url":"http://localhost:8080/v1","api":"openai-completions","model":"your-model-name"}]}
```

Omit `model` to rely entirely on discovery. For WSL, enter the Windows host
address reachable from WSL instead of `localhost` when necessary. Supported
API types: `openai` (base ending `/v1`), `anthropic` (base ending `/v1`), and
`gemini` (base ending `/v1beta`). Paths are explicit; pai does not guess them.

**Settings are safe to change from anywhere.** Setting a value re-reads the file
and changes only that key, and code outside a pai buffer reads the settings from
disk first, so nothing can drop your other settings. Before a settings file is
overwritten, its previous version goes to `~/.pai/backups/settings/` (the newest
`pai-settings-backups`, default 20, per file); `M-x pai-settings-restore-backup`
puts one back (then `/reload`).

`/model` queries every registered provider that supports discovery, displays
`provider/model-id` choices, and reports failures while preserving configured
or cached fallback models. `/model local/your-model-name` selects and saves
the model for this project. Unique bare model IDs also work; qualified IDs
disambiguate models served by multiple providers. Completion and model pickers
refresh the list when opened. Discovery uses bounded synchronous HTTP requests.

No key is required for an unauthenticated local server. For authenticated
providers, use `/login PROVIDER`, `pai-api-keys`, or an `env-key` in the provider
configuration. Credentials are stored separately from endpoint settings.

Hosted services and most optional features are **extensions**, kept in a
separate repository:
[dejanmilivojevic/pai-extensions](https://github.com/dejanmilivojevic/pai-extensions).
It provides hosted providers (Anthropic, OpenRouter), interactive subagents,
learning memory, `ask_user_question`, a dashboard, a todo list, prompt snippets,
`/shake`, MCP, LSP, DAP and a browser tool, among others. Its README explains
how to install them and documents each one.

For project-only providers, put extension files in `<project>/.pai/extensions/`;
only instances for that trusted project load them. `examples/pai-hosted.el`
remains an optional all-provider example, never loaded by core. Copy and edit it
only if you want additional services. Extensions can supply `:list-models`
callbacks or explicit fallback models when discovery is unavailable. Project
settings (`.pai/settings.json`) override global `custom-providers` as a whole list.

Extensions with user-facing settings must contribute them to the settings
screen (`/menu`) via `pai-settings-ui-register-section`/`-subsection`/`-item`,
wrapped in `(with-eval-after-load 'pai-settings-ui ...)`. Registration happens
at extension load, so every new session automatically shows and edits those
settings. See `examples/pai-example-extension.el`.

**Footer position.** Extension widgets and the extension footer (for example the 🧠
memory widget and active prompt snippets) show in the mode line by default. To show
them on their own line directly above the prompt, set **Footer position** to
`above-prompt` in `/menu` → Session → Output, or add
`"footer-position": "above-prompt"` to `settings.json`. The line sits below any
running-worker or subagent lines, and it disappears when there's nothing to show.

Useful options (`M-x customize-group RET pai`): `pai-directory`,
`pai-default-model`, `pai-api-keys`, `pai-curl-program`, `pai-request-timeout`,
`pai-max-tokens`, `pai-tool-execution`.

## Editing the prompt in its own buffer

`C-c C-e` in a pai buffer opens the prompt in a buffer of its own, the way
`org-edit-special` opens a source block. Whatever you had already typed comes
along, with point where you left it. The buffer is in `pai-compose-mode`, a
small Markdown mode built on `text-mode`: markup is highlighted and fenced code
blocks are highlighted natively in their language's major mode.

| Key | In the compose buffer |
|-----|-----------------------|
| `C-c C-c` | write the text back into the prompt (it is not sent) |
| `C-c C-k` | discard the edit; the prompt is left as it was |
| `C-c C-e` | inside a fenced block: edit the block in its language's mode; elsewhere: commit |

The block editor runs the language's mode with its hooks, so your setup
applies; `C-c C-c` there puts the block back into the message. Pressing
`C-c C-e` again from the chat returns to the open editor. If the prompt was
changed in the chat meanwhile, committing asks before replacing it.
`pai-compose-major-mode` selects a different mode (e.g. `markdown-mode`).

## Syntax highlighting

Code is highlighted everywhere pai shows it -- fenced blocks in replies, in
your own messages, in `ask_user_question`/`quiz` dialogs, tool-call
arguments (JSON), and code-bearing tool results (`read` by the file's mode,
`read_buffer` by the buffer's mode, `elisp_eval` as Emacs Lisp). It is the
same machinery Org uses for source blocks: the code is fontified in a hidden
buffer running the language's major mode (mode hooks delayed, so no LSP or
linters start). The mode comes from `pai-md-lang-modes`, then `LANG-mode`,
then `auto-mode-alist`; `major-mode-remap-alist` is honoured, and a
tree-sitter mode without its grammar falls back to the classic mode.

Dialogs render the question as Markdown and keep its layout: line breaks,
lists, tables and code blocks survive, and only long prose lines are wrapped.

## Usage

- `M-x pai` — open (or switch to) the chat buffer for the current project.
- `M-x pai-new-session` — open a fresh session buffer.

In the chat buffer type at the `❯` prompt and press `RET` to send. Assistant
text streams in; tool calls render as `⚙ tool …` blocks with their results.
Typing while the agent is working queues a *steering* message.

### Keybindings (`pai-mode`)

| Key | Command | Action |
|-----|---------|--------|
| `RET` | `pai-send` | Submit the input line |
| `/` | `pai-slash` | Insert `/`, or open command completion at the start of the input |
| `C-c /` | `pai-complete-command` | Pick a slash command (Helm if installed) |
| `TAB` | completion | Complete slash commands, then their argument values (e.g. `/thinking` → levels) |
| `C-c C-c` / `C-c C-k` | `pai-interrupt` | Abort the active run |
| `C-c C-m` | `pai-set-model` | Choose the model |
| `C-c C-t` | `pai-set-thinking` | Set the reasoning/thinking level |
| `C-c C-s` | `pai-menu` | Open the settings menu (Transient) |
| `C-c C-o` / `M-.` / `mouse-2` | `pai-goto-dwim` | Jump to the file/line, buffer, or URL at point |
| `C-c C-l` | `pai-clear` | Clear the transcript display |
| `C-c C-n` | `pai-goto-input` | Jump to the input area |
| `C-c i` (any buffer) | `pai-add-to-prompt` | Add the selected lines, or else the whole buffer/file, to the prompt |
| `C-c C-e` | `pai-edit-input` | Edit the prompt in its own buffer (`C-c C-c` commit, `C-c C-k` abort) |
| `M-p` / `M-n` | `pai-history-previous` / `-next` | Previous / next prompt from the project history |

### Slash commands

Built-in commands (extensions, skills, and prompt templates add more):

| Command | Action |
|---------|--------|
| `/help` `/tools` `/skills` | List commands, tools, discovered skills |
| `/model [id]` | List or switch the model |
| `/thinking [level]` | Show/set reasoning level (off…max) |
| `/scoped-models [role id\|inherit]` | Per-role models (main/task/compact, plus extension roles); also in `/menu` → Model & Reasoning → Scoped models |
| `/settings [menu/set/get/edit …]` | View or change settings (`menu` opens the Transient UI) |
| `/compact` | Summarize + shrink the context |
| `/new` `/resume` `/session` `/name` | Session lifecycle & info |
| `/fork` `/clone` `/tree` | Branch, duplicate, rewind the session tree |
| `/export [path]` `/copy` `/share` | Export to MD/HTML, copy reply, gist |
| `/import <file>` | Load a session from a `.jsonl` file |
| `/trust [yes/no]` `/login [prov]` `/logout` | Project trust & credentials |
| `/reload` `/hotkeys` `/changelog` `/clear` `/quit` | Misc |

Also: `!cmd` runs a shell command and adds the output to the context; `!!cmd`
runs it without adding to context; `@path` mentions a file or directory.

`*` mentions a buffer the same way. Typed at the start of a word, `*` opens
Emacs' buffer picker (`read-buffer`, so your completion UI applies) and inserts
the choice: starred names as they are (`*Messages*`), others with a leading
star (`*pai-ui.el`). `TAB` after `*prefix` completes buffer names inline.
`*` in the middle of a word (`**bold**`, `a*b`) is just a star, and `C-g` in
the picker inserts a plain `*`. The chat buffer itself and internal buffers are never offered.

Mentions are **references, not attachments**: nothing is read into the
context when you send. Instead, only when you mention something, a short
note after your message names each
mentioned file, directory and buffer (buffers with their major mode and the
file they visit), so the model knows what `*todo.org` means and reads only
what it needs with `read` / `read_buffer`. Mentions that resolve to nothing
(no such file or live buffer) stay plain text.

A buffer mention can name lines: `*todo.org:3` or `*todo.org:3-5`
(`read_buffer` takes `offset`/`limit` to read just those).

**From any buffer**, `C-c i` (`pai-add-to-prompt`, key in
`pai-add-to-prompt-key`) adds a reference to that buffer to the pai prompt,
or, with a region selected, to the lines it covers (`*todo.org:3-5`). You
stay where you are, so you can collect several references before switching
to pai. The session used is the one for the buffer's
project, preferring a visible one.

**"This".** Nothing is added to your prompts for it. When you send a
prompt, pai records the buffer you were in just before pai (the line point
was on and any selected region), the last file you visited and a few other
recent buffers. The `recent_buffers` tool returns that record, so the model
looks it up only when you say "explain this", "fix this function" or "what
does the last file do". pai sessions, internal buffers and
`pai-previous-buffer-ignore-regexp` (Helm, `*Completions*`, ...) are skipped;
`pai-record-previous-buffer` turns recording off. Only prompts you send are
recorded, not programmatic sends (subagents, extensions).

Completion works three ways, each showing a short description next to every
command:

- Type `/` at an empty prompt to open a picker. If [Helm](https://github.com/emacs-helm/helm)
  is installed it uses Helm (`helm-comp-read`); otherwise it falls back to
  `completing-read` (Vertico/Ivy/default all work).
- `C-c /` opens the same picker from anywhere on the input line.
- `TAB` completes inline via `completion-at-point` (commands, `@files` and `*buffers`),
  annotated with descriptions.

Helm is entirely optional — it is loaded lazily only when present, so pai keeps
no hard dependency on it.

## Tools

| Tool | Description |
|------|-------------|
| `bash` | Run a shell command (streamed, truncated, with a timeout). |
| `read` | Read a file (offset/limit, image support). |
| `write` | Create or overwrite a file. |
| `edit` | Exact, unique multi-block text replacement. |
| `ls` / `grep` / `find` | Directory listing and search (rg/fd with fallbacks). |
| `elisp_eval` | Evaluate Emacs Lisp in the live editor and return value + output. |
| `list_buffers` / `read_buffer` | Inspect live Emacs buffers. |

`elisp_eval` is the key differentiator: the agent can drive Emacs itself —
inspect buffers, call any function, and use installed packages — using Emacs as
a general-purpose operating system.

## Extensions

An extension is an `.el` file placed in `~/.pai/extensions/` or
`<project>/.pai/extensions/`, or a form evaluated in Emacs. Home `.el` files
load automatically for every pai instance; project `.el` files load only for
instances belonging to that project and only when it is trusted. The
[pai-extensions](https://github.com/dejanmilivojevic/pai-extensions) repository
is home-wide once linked as `~/.pai/extensions` (see its README); it is
distinct from the project-specific `.pai/extensions/` directory.

Extensions are switched on and off under *Extensions* in `/menu` (globally or
per project; changes apply on `/reload`). A disabled extension disappears from
the dashboard and its own section leaves `/menu`, unless an enabled extension
`require`s it (e.g. `pai-learn` needs `pai-ask-user`): it is loaded anyway then,
so it stays visible.

Extension API registrations are isolated per instance, so a project's tools,
commands, handlers, providers, and other registered contributions do not leak
into another project's instance. This is **not a Lisp sandbox**: arbitrary
extension code can still modify global variables, advise functions, or perform
other Emacs-wide side effects. Load only extensions you trust.

After adding, editing, or removing extension files, run `/reload` in the target
chat buffer. It rebuilds that instance's extension registrations from its home
and trusted-project directories without changing other instances. Reload each
existing instance separately; new instances load the current files on startup.
Reload cannot undo arbitrary global side effects from extension code.

An extension registers via a factory that receives the API object:

```elisp
(pai-register-extension
 (lambda (pi)
   ;; React to lifecycle events.
   (pai-ext-on pi 'agent-end
               (lambda (event ctx)
                 (pai-ext-ui-notify ctx (format "%d messages"
                                                 (length (plist-get event :messages))))))
   ;; Add a tool.
   (pai-ext-register-tool
    pi (list :name "now" :description "Return the current time."
             :parameters (pai-object-schema nil)
             :execute (lambda (_args _ctx _update done)
                        (funcall done (pai-tool-ok-result (current-time-string))))))
   ;; Add a slash command.
   (pai-ext-register-command pi "greet" :description "Say hi"
                             :handler (lambda (_args _ctx) (list :message "hi")))))
```

Events include `agent-start`, `turn-start`, `message-start`, `message-update`,
`message-end`, `tool-execution-start/update/end`, `turn-end`, `agent-end`, plus
reducing hooks `context`, `tool-call`, `tool-result`, `before-agent-start`,
`input`, and `compact` (take over `/compact` and auto-compaction; see
`pai-ext-run-compact`). Extensions can add scoped-model roles with
`pai-register-model-role`. See `docs/ARCHITECTURE.md` for the full contract.

## Skills

Place markdown skills under `~/.pai/skills/` or `<project>/.pai/skills/`:

```markdown
---
name: db
description: How to work with this project's database and schema.
---
# Database
Detailed instructions the agent reads on demand…
```

Skills are advertised in the system prompt; the agent reads the file with the
`read` tool when relevant. You can also run one yourself as a slash command with
the `skill:` prefix, e.g. `/skill:db` or `/skill:db add an index on users.email`.
This sends the skill's instructions, followed by your text, to the agent. The
prefix keeps skills apart from built-in and extension commands.
`disable-model-invocation: true` hides a skill from the system prompt, so it only
runs as `/skill:db`. Skills that share `bundle: web` in their front-matter
also form `/bundle:web`, which sends all of them at once. New skills show up after `/reload` or in a new session.

## Sessions

Conversations persist to `~/.pai/sessions/<project-slug>/<uuid>.jsonl` as
append-only JSON Lines and can be reloaded with `pai-session-load`.

**Previews while choosing** (off by default; helm, vertico, icomplete or the
default minibuffer):

- `/resume` shows the session under the cursor in a side window, scrolled to the
  end of the conversation (its current branch, transcript-style: `▶ You`,
  `● pai`, tool calls as one-liners). The end stays in view when the completion
  UI resizes windows. Only the tail of the file is read, so even multi-megabyte
  sessions preview at once.
- `/tree` scrolls the transcript to the end of the turn under the cursor, right
  below its last agent message, and marks it "▶ your next prompt goes here"; a
  turn on another branch is shown in the side window instead.
- After a `/tree` jump, point is at the input, right below the chosen turn's
  last agent message (preview on or off).
- **Toggle:** `C-c C-f` while choosing turns the preview on or off (hinted in the
  prompt, like helm's follow mode); the choice is saved per picker
  (`:preview-resume`, `:preview-tree`), also under *Session → Output* in `/menu`.
- Options in the `pai-preview` group: `pai-preview-enabled` (master switch),
  `pai-preview-toggle-key`, `pai-preview-delay`, `pai-preview-max-messages`,
  `pai-preview-window-width`.

## Development

```sh
make test      # run the ERT suite (no network, no API keys)
make test-core # only the core tests, never loading an extension
make compile   # byte-compile with warnings as errors
make clean
```

The core needs no extensions: in a plain checkout `make test` runs the core
suite (470+ tests). When
[pai-extensions](https://github.com/dejanmilivojevic/pai-extensions) is cloned
into `extensions/`, `make test` also runs each extension's tests (from
`extensions/<name>/test/`) and `make compile` byte-compiles the extensions.

The core suite covers the data model and JSON, all three provider
request builders and SSE parsers (incl. prompt caching and tool_choice), the
real `curl` transport against a localhost server, the agent loop with parallel
and sequential tool execution and all hooks, every built-in tool, diff
rendering, compaction, the session tree (fork/clone/tree/resume/import),
settings, trust, auth, the full extension API, skills, prompt templates, slash
commands, `!`/`@` input, the UI, and end-to-end flows — all network-free via a
faux provider and local fixtures.

## Documentation

- `docs/PARITY.md` — the pi↔pai feature-parity checklist (all phases complete).
- `docs/PLAN.md` — implementation plan and pi→pai mapping.
- `docs/ARCHITECTURE.md` — the data model, event protocol, provider contract,
  agent loop, tool/extension contracts, and UI design.
- `docs/STATUS.md`, `docs/MEMORY.md` — progress log and design decisions.

## Credits

A port of [`earendil-works/pi`](https://github.com/earendil-works/pi) (MIT).
This project follows pi's architecture and behavior; the LLM provider APIs are
those of Anthropic, OpenAI, and Google.

## License

MIT.
