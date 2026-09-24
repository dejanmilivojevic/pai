# Memory — decisions, gotchas, learnings

Durable notes so context survives across work sessions.

## Decisions
- **Prefix `pai-`**, single package, layered files (see PLAN.md mapping).
- **Transport: `curl -N` via `make-process`** for streaming SSE. `url.el` cannot
  stream response bodies incrementally in a usable way. Filter parses SSE lines.
- **Native JSON**: `json-parse-buffer` with `:object-type 'plist` and
  `:null-object :null`, `:false-object :false`. Serialize via `json-serialize`.
  JSON objects are plists internally; a keyword-key plist is the canonical shape.
- **Data model = plists.** Messages and content blocks are plists with a `:role`
  / `:type` discriminator, mirroring pi's tagged unions. Keeps JSON round-trip
  trivial and avoids cl-defstruct ceremony at the wire boundary.
- **Events are plists** `(:type SYMBOL ...)`; the agent loop calls an emit
  callback. The UI subscribes; extensions subscribe via the ExtensionAPI.
- **Tools are plists** `(:name :description :parameters :execute ...)` registered
  in a hash table. `:execute` is `(lambda (args ctx emit-update) -> result-plist)`.
- **Empty array vs omit**: inside an object plist, `nil` value = OMIT the key.
  An explicit empty JSON array `[]` is the empty vector `[]`; an explicit empty
  JSON object `{}` is `(pai-json-empty-object)` (a hash-table). Confirmed by tests
  in `pai-core-test.el`. Provider request builders MUST use `[]` where a
  possibly-empty array field must still be present.
- **copy-tree corrupts closures**: never `copy-tree` a plist/list holding
  `:execute` lambdas or any lexical closure; it deep-copies the captured env so
  the copy's setq no longer touches the caller's binding. `pai-agent-run`
  shallow-copies only `:messages` and keeps `:tools` by reference. (Cost me a
  debugging cycle in Phase 3.)

## Gotchas
- Emacs native `json-serialize` errors on `nil` for object values; use `:null`.
  Empty JSON object must be an empty hash-table or `(:x ...)`? Represent empty
  object as `:empty-object` via `json-serialize` arg, or a plist. Verify in Phase 1.
- `t`/`nil` vs JSON booleans: choose `:false` for false, `t` for true; configure
  parse/serialize consistently. Document the canonical booleans in pai-json.el.
- SSE frames may split across process-filter chunks; buffer until `\n\n`.

## pi facts worth remembering
- Agent loop: outer loop (follow-up queue) wraps inner loop (tool calls + steering).
  Per turn: prepareNextTurn -> inject steering -> stream assistant -> execute tools
  -> turn_end -> shouldStopAfterTurn -> re-poll steering. See PI-NOTES.md.
- Truncated (`stopReason=length`) assistant messages: all tool calls are failed,
  not executed, because streamed args may be silently incomplete.
- Extension API from examples: `pi.on(event, (event, ctx) => ...)`, `pi.exec`,
  `pi.getSessionName/setSessionName`, `ctx.hasUI`, `ctx.cwd`, `ctx.ui.notify`,
  `ctx.ui.setWidget`, `ctx.sessionManager.getEntries()`.
