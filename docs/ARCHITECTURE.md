# pai Architecture (pi -> Emacs mapping)

Distilled from the pi source. This is the contract the Emacs port implements.

## 1. Data model (pai-core.el)

All messages/blocks are **plists with keyword keys**, round-trippable to JSON.
Booleans: JSON `true`->`t`, JSON `false`->`:false`, JSON `null`->`:null`.
`:role`/`:type` are elisp symbols internally (`user`, `text`, ...), serialized to strings.

### Content blocks
- text:     `(:type text :text STR :text-signature STR?)`
- thinking: `(:type thinking :thinking STR :thinking-signature STR? :redacted BOOL?)`
- image:    `(:type image :data BASE64 :mime-type STR)`
- tool-call:`(:type tool-call :id STR :name STR :arguments PLIST :thought-signature STR? :namespace STR?)`

### Messages
- system:      `(:role system :content STR|BLOCKS :sections PLIST? :tools-added [TOOL]? :tools-removed [REF]? :timestamp MS)`
- user:        `(:role user :content STR|BLOCKS :timestamp MS)`
- assistant:   `(:role assistant :content BLOCKS :api STR :provider STR :model STR :usage USAGE :stop-reason SYM :error-message STR? :response-id STR? :timestamp MS ...)`
- tool-result: `(:role tool-result :tool-call-id STR :tool-name STR :content BLOCKS :details ANY? :is-error BOOL :usage USAGE? :timestamp MS)`

### Usage
`(:input N :output N :cache-read N :cache-write N :reasoning N? :total-tokens N :cost (:input F :output F :cache-read F :cache-write F :total F))`

### StopReason (symbols)
`pending stop length tool-use error aborted deferred`

### Tool declaration (for the model)
`(:name STR :description STR :parameters JSON-SCHEMA :constrained-sampling ...?)`

### Model descriptor
`(:id STR :name STR :api SYM :provider STR :base-url STR :reasoning BOOL
  :thinking-level-map PLIST? :input (text image) :cost COST
  :context-window N :max-tokens N :headers PLIST?)`

The registry keys models by `provider/id` (`pai-model-key`). `pai-model` accepts
a qualified key or a unique bare ID; `nil` when ambiguous. Requests always use
the raw `:id`. There is no built-in catalog: models come from provider
configuration (persisted `custom-providers`/`custom-models` settings),
live discovery (`pai-models-refresh`), or extensions.

## 2. Event protocol

### LLM stream events (provider -> loop), plists `(:type SYM ...)`
`start`(:partial), `text-start`/`text-delta`(:delta)/`text-end`(:content),
`thinking-start`/`thinking-delta`/`thinking-end`,
`toolcall-start`/`toolcall-delta`(:delta)/`toolcall-end`(:tool-call),
`done`(:reason :message), `error`(:reason :error).
All carry `:content-index` where relevant and a `:partial` assistant message snapshot.

### Agent loop events (loop -> UI/extensions)
`agent-start`, `turn-start`, `message-start`(:message), `message-update`(:message :event),
`message-end`(:message), `tool-execution-start`(:tool-call-id :tool-name :args),
`tool-execution-update`(:... :partial-result), `tool-execution-end`(:... :result :is-error),
`turn-end`(:message :tool-results), `agent-end`(:messages).

## 3. Provider contract (pai-provider.el, pai-providers.el, pai-provider-*.el)

Core ships API adapters only; no provider is registered automatically.
`pai-register-provider-config` registers a configured provider plist:
`(:id :api :base-url :build-request :make-parser :model? :models? :env-key?
  :list-models?)`. `:base-url` is the full API base path; discovery appends
`/models`. `:api` selects the adapter (`openai-completions`,
`anthropic-messages`, `google-generative-ai`) or may be custom when the
provider supplies `:stream`/`:list-models` itself. `:env-key` names environment
variable(s) consulted by `pai-api-key`. Configuration persists in the
`custom-providers`/`custom-models` settings keys; `pai-models-load-custom`
reloads them (no network) and removes stale settings-owned entries.
`pai-models-refresh` queries every provider supporting discovery (bounded curl,
per-API pagination), replaces that provider's discovered set on success, and
reports errors while preserving cached/explicit models.

- URL `POST {base}/messages`  configure base=`.../v1`
- Body `{model,max_tokens,system,messages,tools:[{name,description,input_schema}],tool_choice,stream:true,thinking?}`
- Req blocks: text, image{source:{type:base64,media_type,data}}, tool_use{id,name,input}, tool_result{tool_use_id,content,is_error}, thinking{thinking,signature}
- SSE: message_start(usage.input_tokens), content_block_start(index,content_block{type,...}),
  content_block_delta(index,delta{text_delta|input_json_delta.partial_json|thinking_delta|signature_delta}),
  content_block_stop(index), message_delta(delta.stop_reason,usage.output_tokens), message_stop.
- stop map: end_turn/stop_sequence->stop, max_tokens->length, tool_use->tool-use.
- ENV: none by default; hosted example sets ANTHROPIC_API_KEY.

### OpenAI (`openai-completions`)
- URL `POST {base}/chat/completions`  configure base=`.../v1`
- Headers `Authorization: Bearer KEY`
- Body `{model,messages,tools:[{type:function,function:{name,description,parameters}}],tool_choice,stream:true,stream_options:{include_usage:true},max_completion_tokens|max_tokens,reasoning_effort?}`
- Req roles: system, user, assistant{content,tool_calls:[{id,type:function,function:{name,arguments(JSON str)}}]}, tool{tool_call_id,content}
- SSE: `data: {choices:[{delta:{content,tool_calls:[{index,id,function:{name,arguments}}]},finish_reason}],usage}` then `data: [DONE]`.
- stop map: stop->stop, length->length, tool_calls->tool-use.
- ENV: none by default; hosted example sets OPENAI_API_KEY.

### Google Gemini (`google-generative-ai`)
- URL `POST {base}/models/{model}:streamGenerateContent?alt=sse` configure base=`.../v1beta`
- Headers `x-goog-api-key: KEY`
- Body `{contents:[{role:user|model,parts:[{text}|{inlineData:{mimeType,data}}|{functionCall:{name,args}}|{functionResponse:{name,response}}]}],systemInstruction:{parts},tools:[{functionDeclarations:[{name,description,parameters}]}],generationConfig:{maxOutputTokens,temperature,thinkingConfig?}}`
- SSE: `data: {candidates:[{content:{parts:[...]},finishReason}],usageMetadata:{promptTokenCount,candidatesTokenCount,totalTokenCount}}`
- stop map: STOP->stop, MAX_TOKENS->length, presence of functionCall->tool-use.
- ENV: none by default; hosted example sets GEMINI_API_KEY/GOOGLE_API_KEY.

### Faux provider (tests): `pai-faux` — scripted event lists, no network.

## 4. Agent loop (pai-agent.el)

Mirrors pi agent-loop.ts. `pai-agent-run(prompts context config emit)`:
- Emit agent-start, turn-start, message events for injected prompts.
- Outer loop (follow-up queue) wraps inner loop (tool calls + steering).
- Per iteration: before-turn (may pause the run, e.g. to compact, and resume
  it with replaced context messages) -> prepare-next-turn -> inject steering/prepared messages ->
  stream assistant response (via provider) -> if stop-reason error/aborted, end ->
  collect tool calls -> if stop-reason length, fail all tool calls ->
  else execute tools (sequential/parallel) -> append results -> turn-end ->
  should-stop-after-turn? -> re-poll steering.
- Async in Emacs: the loop is driven by provider stream callbacks; use a small
  state machine + continuation, not blocking. Config hooks are elisp functions.

### Config (plist) hooks
`:model :convert-to-llm :transform-context :get-api-key :should-stop-after-turn
:prepare-next-turn :get-steering-messages :get-follow-up-messages :tool-execution
:before-tool-call :after-tool-call :reasoning :max-tokens :temperature :tools
:before-turn`

`:before-turn (context resume)` runs between turns of a run (not before the
first).  Returning non-nil pauses the run until `(funcall resume)` or
`(funcall resume (list :messages NEW))`; `pai-agent-abort` drops a pending
resume.  Tools and hooks can register cleanup with `pai-agent-on-abort`.

`:recover-error (message context resume)` is offered a turn that failed
(stop-reason error, or length with no output).  Returning non-nil pauses the
run; `(funcall resume (list :messages NEW))` streams the turn again with NEW
(the failed message stays out of the context), `(funcall resume)` ends the
run with the error.  The UI uses it for pi's compact-and-retry on context
overflow.

## 5. Tool contract (pai-tools.el)

Tool plist registered in `pai-tools--registry` (hash by name):
`(:name STR :label STR :description STR :prompt-snippet STR? :prompt-guidelines (STR...)?
  :parameters JSON-SCHEMA :execution-mode (sequential|parallel) :deferred BOOL?
  :execute (lambda (tool-call-id args ctx on-update) -> RESULT))`
RESULT: `(:content BLOCKS :details ANY? :is-error BOOL?)`.
`on-update`: `(lambda (partial-result))` for streaming.
ctx: `(:cwd :model :session :signal ...)`.

### Deferred tool schemas (context/cache optimization)
Only core tools (`pai-builtin-tool-names` + `pai-eager-tool-names`) are
declared in full.  Every other tool (i.e. extension tools) is declared as a
compact stub from `pai-tool-stub-declaration`: name, one-line summary
(`:prompt-snippet` or first sentence) and a permissive schema
(`{type: object, properties: {}, additionalProperties: true}`).

- The stub depends only on the tool, so the tools array is byte-identical on
  every request and the provider prompt cache (tools -> system -> messages)
  is never invalidated.
- The first call to a stubbed tool is **not executed** (and skips the
  before-tool-call/permission hook); its result carries the full description
  and JSON schema, tagged `:details (:deferred-schema NAME)`.  That result is
  appended to history, so the full definition is present "from then on".
- "Revealed" is derived from the message history
  (`pai-message-revealed-tools`), so it survives session resume.
- Context reducers never unload a revealed tool:
  - `/compact` carries every definition from the summarized part into the
    summary message (second text block, tagged `:deferred-schemas (NAMES)`),
    regenerated from the registry; the summarizer never sees schema text.
    Kept reveals are not duplicated; unregistered tools are dropped.
  - `/shake` skips any message where `pai-tool-schema-message-p` is true.
  - Any new reducer must do the same (see `pai-tool-carried-schemas`).
- Works identically for all providers (Gemini strips `additionalProperties`).
- Opt out per tool with `:deferred nil`, per name with `pai-eager-tool-names`,
  or globally with `pai-defer-extension-tools` / settings key `:defer-tools`.
  A tool may also force `:deferred t`.

### Built-in tools (Emacs-native)
- bash: `make-process` shell, streaming combined output, tail truncation.
- read: file/buffer read with offset/limit, image detection.
- edit: exact multi-block replacement with diff, via temp buffer.
- write: overwrite with mkdir -p.
- ls / grep / find: project.el / rg / fd with elisp fallbacks.
- elisp-eval (Emacs-native superpower): eval a form in the live image, capture value+output.
- buffer tools: list-buffers, read-buffer, eval-in-buffer.

## 6. Extensibility (pai-ext.el, pai-skills.el, pai-commands.el, pai-prompt.el)

ExtensionAPI object `pi` passed to extension factory `(lambda (pi) ...)`:
- `pai-ext-on(pi EVENT HANDLER)` — subscribe to any loop/session event.
- `pai-ext-register-tool(pi TOOL)`.
- `pai-ext-register-command(pi NAME OPTS)` — slash command.
- `pai-ext-register-provider(pi PROVIDER)`.
- `pai-settings-ui-register-section/-subsection/-item` — contribute to the
  settings screen (`section -> subsection -> item`; see policy below).
  `pai-settings-ui-register-dynamic-items` generates rows at render time for
  entries not known ahead of time (e.g. one per discovered role).
- actions: `pai-ext-exec`, `pai-ext-send-message`, `pai-ext-set-model`, `pai-ext-notify`,
  `pai-ext-get/set-session-name`.
Extensions load per instance from `~/.pai/extensions/` (every instance) and
trusted `<project>/.pai/extensions/`.  Within each root, loose `*.el` files load
directly and every subdirectory is a self-contained extension: entry file
`<name>/<name>.el`, with the subdirectory added to `load-path` so it can
`require' its own siblings (`pai-load-extension-dir').  The repo ships one
subdirectory per extension under `extensions/`.
Each instance (`pai` buffer, `pai-oneshot`) copies the registration registries
at startup and re-copies them on `/reload`, so project registrations never leak
into other instances; async agent/provider/tool callbacks re-enter the owning
buffer. This isolates API registrations, not arbitrary Lisp side effects.
Context object mirrors pi's ExtensionContext, with `:ui` bridged to Emacs
(`notify`->message, `select/confirm/input`->completing-read/y-or-n-p/read-string, `set-widget`->header/overlay).

### Settings screen (pai-settings-ui.el)
The `/menu` command opens a vui-rendered settings screen organised as
`section -> subsection -> item`.  Built-in sections live in `pai-settings-ui.el`;
the registry is open, keyed by id/`:key`, and idempotent (re-registering updates
in place).  Items are typed (`boolean`, `choice`, `string`, `number`, `action`)
and read/write through `:get`/`:set` thunks so the screen always reflects live
settings.

POLICY: any extension that has user-facing settings MUST register them with
`pai-settings-ui-register-section/-subsection/-item`, wrapped in
`(with-eval-after-load 'pai-settings-ui ...)` so the screen stays a soft
dependency.  Registration runs at extension load, so every new session
automatically surfaces and edits the extension's settings from `/menu`.  See
`examples/pai-example-extension.el` (point 4) and `extensions/pai-subagents/`
for the pattern.

### Skills
Markdown `SKILL.md` with YAML frontmatter (name, description, disable-model-invocation).
Discovered from `~/.pai/skills/`, `.pai/skills/`. Injected into `<skills>` prompt section.

### Slash commands
Built-in (`/model /session /new /compact /resume /quit /help ...`) + extension-registered
+ skills (as `/skill-name`). Dispatched from the UI input line.

### System prompt (pai-prompt.el)
XML sections in order: preamble, tools, rules, docs, project_context (AGENTS.md),
skills, cwd, addendum. Assembled from options; extensions can mutate via before-agent-start.

## 7. Session (pai-session.el)
Append-only JSONL under `~/.pai/sessions/<project-slug>/<uuid>.jsonl`.
Header line `{type:session,version:1,id,timestamp,cwd}` then entries
`{type:message,message:...}`, `{type:model_change}`, `{type:custom,...}`.
Load = replay entries into a transcript. UUIDv7 ids for ordering.

## 8. UI (pai-ui.el) — the "tui" as Emacs
- `pai` command opens `*pai*` chat buffer in `pai-mode` (derived, read-only display
  region + editable input region at bottom, like comint/eshell).
- Rendering consumes agent events: assistant text streamed into buffer, thinking in
  a dim face, tool calls rendered as collapsible blocks with args + result.
- Input: RET on the input line submits; `/` triggers slash-command completion.
- Argument completion goes to any depth: a command's `:arg-completions` can be
  built with `pai-command-completion-tree` from a nested spec (words, words with
  a subtree, functions computing words, `(:rest FLAG...)` for free text plus
  flags). Accepting an argument that has more after it inserts a space and opens
  the next level (`pai--arg-completion-exit`). Used by `/memory`, `/settings`
  and `/mcp`; every new command or subcommand must be reachable there.
- Keybindings via a keymap (configurable). Status via header-line/mode-line.
- The UI is a pure event consumer; it registers as an extension-like subscriber.
