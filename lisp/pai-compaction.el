;;; pai-compaction.el --- Context compaction -*- lexical-binding: t; -*-

;;; Commentary:

;; Context compaction: when the transcript approaches the model's context
;; window, summarize the older portion into a structured summary and keep only
;; recent turns, so the conversation can continue.  Port of
;; packages/agent/src/harness/compaction/compaction.ts.
;;
;; Token estimation follows pi: provider-reported usage for the settled prefix
;; plus a chars-per-token heuristic for trailing messages.  The reported count
;; is only believed while it still describes the current context (see
;; `pai-invalidate-usage-anchors') and only when it exceeds our own estimate of
;; the same messages.  The summary is produced by an LLM call (the `compact'
;; scoped model) using pi's summarization prompt.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-core)
(require 'pai-settings)
(require 'pai-provider)
(require 'pai-tools)

(declare-function pai-tool-declaration "pai-tools" (tool))

(defconst pai-compaction-image-chars 4800
  "Character weight assigned to an image block for token estimation.")

;;;; Settings

(defun pai-compaction-enabled-p ()
  "Return non-nil when auto-compaction is enabled."
  (pai-truthy (pai-settings-get :auto-compact t)))

(defconst pai-compaction-default-reserve-tokens 16384
  "Absolute reserve floor applied when `:compact-reserve-tokens' is unset.")

(defconst pai-compaction-proportional-reserve 0.15
  "Reserve floor as a fraction of the context window.
A flat absolute reserve is wrong at both ends of the range: 16k is 41% of a
40k window but 1.6% of a 1M one.  Taking the larger of the absolute floor and
this fraction keeps the headroom meaningful on small models and generous on
large ones.")

(defun pai-compaction-reserve-tokens ()
  "Return the configured absolute reserve floor.
This is the window-independent floor; `pai-compaction-effective-reserve-tokens'
applies the proportional rule on top of it."
  (or (pai-settings-get :compact-reserve-tokens)
      pai-compaction-default-reserve-tokens))

(defun pai-compaction-effective-reserve-tokens (context-window)
  "Return the effective reserve for CONTEXT-WINDOW.
At least `pai-compaction-proportional-reserve' of the window, never below the
configured absolute floor."
  (max (floor (* context-window pai-compaction-proportional-reserve))
       (pai-compaction-reserve-tokens)))

(defun pai-compaction-budget-reserve-tokens (context-window)
  "Return the reserve used to derive the compaction threshold for CONTEXT-WINDOW.
The default absolute reserve can equal or exceed a small window, leaving no
usable prompt budget.  When the reserve was defaulted (never configured) and is
impossible for this window, fall back to the purely proportional reserve.  An
explicitly configured reserve is always honored, even if it happens to equal
the default -- provenance is carried by the setting being unset, never by
comparing values."
  (let* ((reserve (pai-compaction-effective-reserve-tokens context-window))
         (proportional (max 1 (floor (* context-window
                                        pai-compaction-proportional-reserve))))
         (defaulted (null (pai-settings-get :compact-reserve-tokens))))
    (if (or (and defaulted (>= reserve (- context-window proportional)))
            (>= reserve context-window))
        proportional
      reserve)))

(defun pai-compaction-threshold-tokens (context-window)
  "Return the token count above which compaction should trigger.
A configured `:compact-threshold' fraction takes priority; otherwise the
threshold is CONTEXT-WINDOW minus the budget reserve.  Always clamped strictly
below CONTEXT-WINDOW so there is room to act on the trigger."
  (if (<= context-window 0)
      0
    (let ((fraction (pai-settings-get :compact-threshold)))
      (if (and (numberp fraction) (> fraction 0) (< fraction 1))
          (min (1- context-window)
               (max 1 (floor (* context-window fraction))))
        (max 0 (min (1- context-window)
                    (- context-window
                       (pai-compaction-budget-reserve-tokens context-window))))))))

(defun pai-compaction-keep-recent-tokens ()
  "Return the approximate tokens of recent context to keep after compaction."
  (or (pai-settings-get :compact-keep-recent-tokens) 20000))

;;;; Token estimation

(defcustom pai-estimate-chars-per-token 3
  "Characters per token assumed by the context estimator.

pi upstream uses 4, which suits English prose.  Agent traffic is not prose:
it is source code, JSON tool arguments and base64 blobs, which tokenize far
denser.  Measured against the provider's own count on a real coding session,
305,634 characters of payload came back as 109,785 tokens -- 2.78 chars per
token -- so 4 under-reported the context by nearly 3x.

3 keeps a little headroom without being wildly pessimistic on prose-heavy
sessions.  Erring low risks overflowing the window; erring high only compacts
a touch early."
  :type 'integer
  :group 'pai)

(defun pai-estimate-tokens-from-chars (chars)
  "Return the estimated tokens of CHARS characters of payload."
  (ceiling chars (max 1 pai-estimate-chars-per-token)))

(defun pai-compaction--block-chars (block)
  "Return the characters BLOCK contributes to the request payload."
  (pcase (pai-block-type block)
    ('text (length (or (plist-get block :text) "")))
    ('image pai-compaction-image-chars)
    ;; A thinking block is sent back with its signature, and that signature is
    ;; the bulk of it: providers may return an empty `:thinking' text while the
    ;; opaque blob runs to thousands of characters.  Leaving it out made whole
    ;; reasoning turns look free.
    ('thinking (+ (length (or (plist-get block :thinking) ""))
                  (length (or (plist-get block :thinking-signature) ""))))
    ('tool-call (+ (length (or (plist-get block :name) ""))
                   (length (condition-case nil
                               (pai-json-encode (or (plist-get block :arguments)
                                                    (pai-json-empty-object)))
                             (error "")))))
    (_ 0)))

(defun pai-compaction--content-chars (content)
  "Return the estimated character count of CONTENT (string or block list)."
  (cond
   ((stringp content) (length content))
   ((listp content)
    (let ((n 0))
      (dolist (b content) (cl-incf n (pai-compaction--block-chars b)))
      n))
   (t 0)))

(defvar pai-compaction--token-cache (make-hash-table :test 'eq :weakness 'key)
  "Token estimates of messages: MESSAGE -> (CONTENT CHARS-PER-TOKEN . TOKENS).
The header, compaction and memory re-estimate the whole transcript several
times per turn; completed messages never change, so their estimate is kept
(weakly, so dropped messages are collected).  An entry only counts while the
message still holds the same `:content' list and the chars-per-token ratio
is unchanged.")

(defun pai-estimate-tokens (message)
  "Estimate the token count of MESSAGE.
Counts every block the provider serializers actually send, at
`pai-estimate-chars-per-token' characters per token.  Memoized per message
object (see `pai-compaction--token-cache')."
  (let* ((content (plist-get message :content))
         (hit (gethash message pai-compaction--token-cache)))
    (if (and hit (eq (car hit) content) (eql (cadr hit) pai-estimate-chars-per-token))
        (cddr hit)
      (let ((tokens (pai-estimate-tokens-from-chars (pai-compaction--content-chars content))))
        (puthash message (cons content (cons pai-estimate-chars-per-token tokens))
                 pai-compaction--token-cache)
        tokens))))

(defun pai-compaction--usage-report-p (message)
  "Return non-nil when MESSAGE carries a usable provider usage report."
  (and (pai-assistant-message-p message)
       (not (memq (plist-get message :stop-reason) '(error aborted)))
       (let ((u (plist-get message :usage)))
         (and u (> (or (plist-get u :total-tokens) 0) 0)))))

(defun pai-compaction--last-usage-index (messages)
  "Return the index of the newest usable usage anchor in MESSAGES, or nil.

Only the *newest* report counts.  An anchor stands in for everything before
it, so the further back it sits the more of the context is really just an
estimate wearing a provider's number -- and a marked (`:usage-stale') report
means even that number describes a context we have since rewritten.  Rather
than walk back to an older report, which would let one stale count speak for
hundreds of messages, give up the anchor entirely and estimate."
  (let ((idx nil) (i 0))
    (dolist (m messages)
      (when (pai-compaction--usage-report-p m)
        (setq idx (and (not (plist-get m :usage-stale)) i)))
      (setq i (1+ i)))
    idx))

(defun pai-invalidate-usage-anchors (messages &optional from)
  "Return MESSAGES with the usage anchors at or after index FROM marked stale.

`pai-estimate-context-tokens' trusts the newest provider usage report as the
true size of everything up to that message, and only estimates what follows.
That is sound only while the prefix is untouched.  Once a message is rewritten
or dropped -- by compaction, by a shake, by anything that edits history -- every
anchor at or after it reports a context that no longer exists, and the meter
would keep showing the old size until the next provider response replaced it.

Marking those anchors `:usage-stale' makes the estimate fall back to summing
the messages, which reflects the edit immediately.  Anchors *before* FROM still
describe an unmodified prefix, so they are kept: we give up only as much
provider ground truth as the edit actually invalidated.  The usage plists
themselves are preserved, so cost accounting is unaffected."
  (let ((from (or from 0))
        (i -1))
    (mapcar (lambda (m)
              (setq i (1+ i))
              (if (and (>= i from)
                       (plist-get m :usage)
                       (not (plist-get m :usage-stale)))
                  (plist-put (copy-sequence m) :usage-stale t)
                m))
            messages)))

(defun pai-estimate-context-tokens (messages)
  "Estimate the total context tokens for MESSAGES.
Uses the newest provider usage report as the size of everything up to it and
estimates the rest.  The report is only ever believed upward: a count below
our own estimate of the very same messages is not ground truth but a bad
reading, such as the Anthropic responses recorded before cached prompt tokens
were counted, which reported a few hundred tokens for a context of tens of
thousands."
  (let ((idx (pai-compaction--last-usage-index messages))
        (prefix 0) (trailing 0) (i 0))
    (dolist (m messages)
      (if (and idx (> i idx))
          (cl-incf trailing (pai-estimate-tokens m))
        (cl-incf prefix (pai-estimate-tokens m)))
      (setq i (1+ i)))
    (if (null idx)
        prefix
      (let* ((usage (plist-get (nth idx messages) :usage))
             (reported (or (and (> (or (plist-get usage :total-tokens) 0) 0)
                                (plist-get usage :total-tokens))
                           (+ (or (plist-get usage :input) 0)
                              (or (plist-get usage :output) 0)
                              (or (plist-get usage :cache-read) 0)
                              (or (plist-get usage :cache-write) 0)))))
        (+ (max reported prefix) trailing)))))

(defun pai-estimate-tool-tokens (tools)
  "Estimate the tokens of the provider declarations for TOOLS.
Tool JSON schemas are sent to the provider on every request separately from
the messages, so they count toward the real context size.  TOOLS is a list of
tool plists as returned by `pai-tools-all'."
  (let ((chars 0))
    (dolist (tool tools)
      (cl-incf chars (pai-compaction--tool-chars tool)))
    (pai-estimate-tokens-from-chars chars)))

(defvar pai-compaction--tool-chars-cache (make-hash-table :test 'eq :weakness 'key)
  "Declaration size of tools: TOOL -> (DECLARATION . CHARS).
The header re-estimates the tools after every message; their JSON schemas
only change when a tool is re-registered (a new plist) or revealed (a new
declaration).")

(defun pai-compaction--tool-chars (tool)
  "Return the characters TOOL's provider declaration contributes (memoized)."
  (let* ((decl (pai-tool-declaration tool))
         (hit (gethash tool pai-compaction--tool-chars-cache)))
    (if (and hit (equal (car hit) decl))
        (cdr hit)
      (let ((chars (+ (length (or (plist-get decl :name) ""))
                      (length (or (plist-get decl :description) ""))
                      (length (condition-case nil
                                  (pai-json-encode (or (plist-get decl :parameters)
                                                       (pai-json-empty-object)))
                                (error ""))))))
        (puthash tool (cons decl chars) pai-compaction--tool-chars-cache)
        chars))))

(defun pai-estimate-total-context-tokens (messages &optional tools)
  "Estimate total context tokens for MESSAGES including TOOLS declarations.
This matches what is actually sent to the provider on each request: the
anchored message estimate plus the tool JSON schemas."
  (+ (pai-estimate-context-tokens messages)
     (if tools (pai-estimate-tool-tokens tools) 0)))

;;;; Trigger

(defun pai-should-compact-p (messages context-window)
  "Return non-nil when MESSAGES exceed the compaction threshold.
The threshold is `pai-compaction-threshold-tokens' of CONTEXT-WINDOW, so the
trigger honors both `:compact-threshold' and the proportional reserve."
  (and (pai-compaction-enabled-p)
       (> context-window 0)
       (> (pai-estimate-context-tokens messages)
          (pai-compaction-threshold-tokens context-window))))

;;;; Cut point

(defun pai-compaction--cut-point-p (message)
  "Return non-nil when the kept context may start at MESSAGE.
Never at a tool result: it would be cut off from its tool call."
  (not (eq (pai-message-role message) 'tool-result)))

(defun pai-compaction--turn-start-p (message)
  "Return non-nil when MESSAGE starts a turn (a user-role message)."
  (eq (pai-message-role message) 'user))

(defun pai-compaction--find-cut-index (messages keep-recent)
  "Return the index in MESSAGES of the first message to keep (0: nothing to cut).
Port of pi's findCutPoint: walk back from the newest message accumulating
estimated tokens; once KEEP-RECENT is reached, cut at the closest valid cut
point at or after that message -- a user or assistant message, never a tool
result.  The cut may fall inside a turn (a long agent run after a single
prompt); see `pai-compaction--split-turn'.

Unlike pi, when no cut point follows (the newest messages are tool results
larger than KEEP-RECENT, as is typical between turns of a run), fall back to
the closest cut point before, keeping somewhat more than KEEP-RECENT rather
than everything."
  (let* ((vec (vconcat messages))
         (n (length vec))
         (acc 0))
    (or (cl-loop for i from (1- n) downto 0
                 do (cl-incf acc (pai-estimate-tokens (aref vec i)))
                 when (>= acc keep-recent)
                 return (or (cl-loop for c from i below n
                                     when (pai-compaction--cut-point-p (aref vec c))
                                     return c)
                            (cl-loop for c from (1- i) downto 0
                                     when (pai-compaction--cut-point-p (aref vec c))
                                     return c)))
        0)))

(defun pai-compaction--split-turn (messages cut)
  "Return the index of the turn start when keeping MESSAGES from CUT splits a turn.
That is the user message opening the turn the cut falls into, when the
message at CUT does not start a turn itself; nil otherwise."
  (let ((vec (vconcat messages)))
    (unless (or (>= cut (length vec)) (pai-compaction--turn-start-p (aref vec cut)))
      (cl-loop for i from (1- cut) downto 0
               when (pai-compaction--turn-start-p (aref vec i)) return i))))

;;;; Summarization

(defconst pai-compaction-system-prompt
  "You are a context summarization assistant. Your task is to read a conversation between a user and an AI assistant, then produce a structured summary following the exact format specified.

Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary."
  "System prompt for the compaction summarizer.")

(defconst pai-compaction-format-instructions
  "Summarize the conversation so work can continue with the older messages removed. Use exactly this Markdown structure:

## Goal
[What is the user trying to accomplish?]

## Constraints & Preferences
- [Constraints / preferences]

## Progress
### Done
- [x] [Completed tasks]
### In Progress
- [ ] [Current work]
### Blocked
- [Issues]

## Key Decisions
- **[Decision]**: [Brief rationale]

## Next Steps
1. [Ordered next steps]

## Critical Context
- [Important data, file paths, identifiers]"
  "Output-format instructions appended to the summarization request.")

(defun pai-compaction--serialize (messages)
  "Serialize MESSAGES into a plain-text transcript for summarization."
  (mapconcat
   (lambda (m)
     (pcase (pai-message-role m)
       ('user (concat "USER: "
                      (let ((content (pai-message-content m)))
                        ;; A carried-forward summary: its definitions block is
                        ;; carried again by `pai-compact', not summarized.
                        (if (and (pai-tool-schema-message-p m) (consp content))
                            (pai-content-text (list (car content)))
                          (pai-content-text content)))))
       ('assistant
        (concat "ASSISTANT: "
                (string-trim
                 (concat (pai-content-text (pai-message-content m))
                         (mapconcat (lambda (tc)
                                      (format "\n[tool_call %s %s]" (plist-get tc :name)
                                              (condition-case nil
                                                  (pai-json-encode (or (plist-get tc :arguments)
                                                                       (pai-json-empty-object)))
                                                (error "{}"))))
                                    (pai-message-tool-calls m) "")))))
       ('tool-result (concat "TOOL_RESULT[" (or (plist-get m :tool-name) "") "]: "
                             (if (pai-tool-schema-message-p m)
                                 "(tool definition loaded)"
                               (pai-content-text (plist-get m :content)))))
       ('system "")
       (_ "")))
   (seq-remove #'pai-system-message-p messages)
   "\n\n"))

(defconst pai-compaction-summary-max-tokens 3072
  "Output token limit of a compaction summary.")

(defconst pai-compaction-turn-prefix-instructions
  "This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.

Summarize the prefix to provide context for the retained suffix:

## Original Request
[What did the user ask for in this turn?]

## Early Progress
- [Key decisions and work done in the prefix]

## Context for Suffix
- [Information needed to understand the retained recent work]

Be concise. Focus on what's needed to understand the kept suffix."
  "Instructions for summarizing the prefix of a split turn (pi's prompt).")

(defvar pai-compaction-progress-function nil
  "When non-nil, called with each chunk of summary text as it streams in.
Bound by the UI around a compaction to show progress; the summary itself
is unaffected.")

(defun pai-compaction--request (messages custom-instructions &optional kind)
  "Return the summarization context for MESSAGES with CUSTOM-INSTRUCTIONS.
KIND `turn-prefix' asks for pi's split-turn prefix summary instead of the
full structured summary."
  (let ((convo (pai-compaction--serialize messages)))
    (pai-context
     (list (pai-system-message pai-compaction-system-prompt)
           (pai-user-message
            (concat (if (eq kind 'turn-prefix)
                        pai-compaction-turn-prefix-instructions
                      pai-compaction-format-instructions)
                    (when (and custom-instructions (not (eq kind 'turn-prefix))
                               (not (string-empty-p custom-instructions)))
                      (concat "\n\nAdditional instructions: " custom-instructions))
                    "\n\n<conversation>\n" convo "\n</conversation>")))
     nil)))

(defun pai-compaction--progress-handler (progress)
  "Return a stream-event handler feeding text deltas to PROGRESS, or nil."
  (and progress
       (lambda (ev)
         (when (eq (plist-get ev :type) 'text-delta)
           (funcall progress (or (plist-get ev :delta) ""))))))

(defun pai-compaction--final-result (final kind)
  "Return the summary result plist for the FINAL assistant message of KIND.
Like pi, an errored or length-capped response is a failure: a truncated
summary must not become the context."
  (let ((label (if (eq kind 'turn-prefix) "Turn prefix summarization" "Summarization")))
    (cond
     ((null final) (list :error (concat label " timed out")))
     ((memq (plist-get final :stop-reason) '(error aborted))
      (list :error (format "%s failed: %s" label
                           (or (plist-get final :error-message)
                               (symbol-name (plist-get final :stop-reason))))))
     ((eq (plist-get final :stop-reason) 'length)
      (list :error (concat label " failed: generation hit the token cap and the summary is incomplete")))
     (t (list :text (pai-content-text (pai-message-content final))
              :usage (plist-get final :usage))))))

(defun pai-compaction--max-tokens (kind)
  "Return the output token limit for a summary of KIND (the prefix gets half)."
  (if (eq kind 'turn-prefix)
      (/ pai-compaction-summary-max-tokens 2)
    pai-compaction-summary-max-tokens))

(defun pai-compaction--summarize-step (messages model instructions kind sync progress callback)
  "Summarize MESSAGES of KIND with MODEL, then call CALLBACK with the result.
SYNC blocks until done; otherwise return the stream handle."
  (let ((ctx (pai-compaction--request messages instructions kind))
        (opts (list :max-tokens (pai-compaction--max-tokens kind)))
        (on-delta (pai-compaction--progress-handler progress)))
    (if sync
        (progn (funcall callback
                        (pai-compaction--final-result
                         (pai-provider-stream-sync model ctx opts nil on-delta) kind))
               nil)
      (let ((done nil))
        (pai-provider-stream
         model ctx opts
         (lambda (ev)
           (when on-delta (ignore-errors (funcall on-delta ev)))
           (when (and (not done) (memq (plist-get ev :type) '(done error)))
             (setq done t)
             (funcall callback (pai-compaction--final-result (plist-get ev :message) kind)))))))))

(defun pai-compaction-summarize (messages model &optional custom-instructions)
  "Summarize MESSAGES with MODEL synchronously.
Return (:text S :usage U); on failure :text is empty and :error explains."
  (let (out)
    (pai-compaction--summarize-step messages model custom-instructions 'history t
                                    pai-compaction-progress-function
                                    (lambda (r) (setq out r)))
    (if (plist-get out :error) (append (list :text "") out) out)))

;;;; Summarizing what a cut drops

(defun pai-compaction--merge-usage (a b)
  "Return usage A plus usage B, either possibly nil."
  (cond ((and a b) (pai-usage-add a b)) (t (or a b))))

(defun pai-compaction-summarize-dropped (dropped kept model custom-instructions
                                                 callback &optional sync progress)
  "Summarize the DROPPED messages of a cut that keeps KEPT, then call CALLBACK.
Follows pi: when the cut splits a turn -- KEPT opens mid-turn and DROPPED
holds that turn's user message -- the history before the turn and the turn's
prefix are summarized separately (the prefix with pi's turn-prefix prompt,
so the original request survives) and merged.  CALLBACK receives
\(:text S :usage U) or (:error MESSAGE).  SYNC blocks; otherwise the work is
asynchronous and the return value is a function that cancels it (then
CALLBACK receives (:error \"cancelled\")).  PROGRESS receives text chunks."
  (let* ((all (append dropped kept))
         (ts (and kept (pai-compaction--split-turn all (length dropped))))
         (history (if ts (seq-take dropped ts) dropped))
         (prefix (and ts (nthcdr ts dropped)))
         (state (list :handle nil :cancelled nil :done nil))
         (finish (lambda (result)
                   (unless (plist-get state :done)
                     (plist-put state :done t)
                     (funcall callback (if (plist-get state :cancelled)
                                           (list :error "cancelled")
                                         result)))))
         (step (lambda (msgs kind k)
                 (if (plist-get state :cancelled)
                     (funcall finish nil)
                   (plist-put state :handle
                              (pai-compaction--summarize-step
                               msgs model custom-instructions kind sync progress
                               (lambda (r)
                                 (if (or (plist-get r :error) (plist-get state :cancelled))
                                     (funcall finish r)
                                   (funcall k r)))))))))
    (cond
     ((null prefix)
      (funcall step history 'history finish))
     (t
      (let ((do-prefix
             (lambda (hist)
               (funcall step prefix 'turn-prefix
                        (lambda (pre)
                          (funcall finish
                                   (list :text (concat (or (plist-get hist :text) "No prior history.")
                                                       "\n\n---\n\n**Turn Context (split turn):**\n\n"
                                                       (plist-get pre :text))
                                         :usage (pai-compaction--merge-usage
                                                 (plist-get hist :usage)
                                                 (plist-get pre :usage)))))))))
        (if history
            (funcall step history 'history do-prefix)
          (funcall do-prefix nil)))))
    (unless sync
      (lambda ()
        (unless (plist-get state :done)
          (plist-put state :cancelled t)
          (ignore-errors (pai-provider-abort (plist-get state :handle)))
          (funcall finish nil))))))

;;;; Compaction

(defun pai-compaction-summary-message (summary &optional carried)
  "Return the user message that injects a compaction SUMMARY into the transcript.
CARRIED is a `pai-tool-carried-schemas' plist: the deferred tool definitions
from the summarized part are appended verbatim as a second text block and the
message is tagged `:deferred-schemas', so compaction never unloads a tool."
  (let ((text (concat "The earlier part of this conversation was summarized to save context. "
                      "Continue based on this summary:\n\n" summary)))
    (if carried
        (pai-user-message (list (pai-text text) (pai-text (plist-get carried :text)))
                          :deferred-schemas (plist-get carried :names))
      (pai-user-message text))))

(defun pai-compaction--plan (messages)
  "Return the compaction plan for MESSAGES, or nil when nothing can be cut.
The plan is (:system S :dropped D :kept K :cut-index N :tokens-before T)."
  (let* ((system (seq-take-while #'pai-system-message-p messages))
         (rest (seq-drop-while #'pai-system-message-p messages))
         (cut (pai-compaction--find-cut-index rest (pai-compaction-keep-recent-tokens))))
    (when (> cut 0)
      (list :system system
            :dropped (seq-take rest cut)
            :kept (nthcdr cut rest)
            :cut-index cut
            :tokens-before (pai-estimate-context-tokens messages)))))

(defun pai-compaction--result (plan summary usage)
  "Return the compaction result of PLAN with SUMMARY and USAGE, or nil."
  (when (and summary (not (string-empty-p (string-trim summary))))
    (let ((kept (plist-get plan :kept)))
      (list :messages (append (plist-get plan :system)
                              (list (pai-compaction-summary-message
                                     summary
                                     (pai-tool-carried-schemas
                                      (plist-get plan :dropped) kept)))
                              ;; Everything the kept messages' usage counts
                              ;; described has just been replaced by the
                              ;; summary, so those anchors no longer
                              ;; describe this context.
                              (pai-invalidate-usage-anchors kept))
            :summary summary
            :cut-index (plist-get plan :cut-index)
            :tokens-before (plist-get plan :tokens-before)
            :usage usage))))

(defun pai-compact (messages model &optional custom-instructions)
  "Compact MESSAGES using MODEL.  Return a plist or nil when nothing to compact.
The plist is (:messages NEW-LIST :summary S :cut-index N :tokens-before T
:usage U), where NEW-LIST is leading system messages, the summary message, and
the kept recent messages."
  (let ((plan (pai-compaction--plan messages)) (out nil))
    (when plan
      (pai-compaction-summarize-dropped
       (plist-get plan :dropped) (plist-get plan :kept) model custom-instructions
       (lambda (r) (setq out r)) t pai-compaction-progress-function)
      (unless (plist-get out :error)
        (pai-compaction--result plan (plist-get out :text) (plist-get out :usage))))))

(defun pai-compact-async (messages model custom-instructions callback &optional progress)
  "Compact MESSAGES using MODEL without blocking; return a cancel function or nil.
CALLBACK is called once with the `pai-compact' result, with nil when there
is nothing to compact (then before this returns), or with (:error MESSAGE)
when summarizing failed or was cancelled.  PROGRESS receives summary text
chunks as they stream in."
  (let ((plan (pai-compaction--plan messages)))
    (if (null plan)
        (progn (funcall callback nil) nil)
      (pai-compaction-summarize-dropped
       (plist-get plan :dropped) (plist-get plan :kept) model custom-instructions
       (lambda (r)
         (funcall callback
                  (if (plist-get r :error)
                      r
                    (or (pai-compaction--result plan (plist-get r :text) (plist-get r :usage))
                        (list :error "the summary came back empty")))))
       nil progress))))

;;;; Context overflow (port of pi's isContextOverflow)

(defconst pai-compaction-overflow-patterns
  '("prompt is too long" "request_too_large" "input is too long for requested model"
    "exceeds the context window"
    "exceeds \\(?:the \\)?\\(?:model'?s \\)?maximum context length"
    "input token count.*exceeds the maximum" "maximum prompt length is [0-9]+"
    "reduce the length of the messages" "maximum context length is [0-9]+ tokens"
    "exceeds \\(?:the \\)?maximum allowed input length of [0-9,]+ tokens?"
    "input ([0-9]+ tokens) is longer than the model'?s context length"
    "exceeds the limit of [0-9]+" "exceeds the available context size"
    "greater than the context length" "context window exceeds limit"
    "exceeded model token limit" "too large for model with [0-9]+ maximum context length"
    "prompt has [0-9,]+ tokens?, but the configured context size is"
    "model_context_window_exceeded" "prompt too long; exceeded \\(?:max \\)?context length"
    "range of input length should be" "context[_ ]length[_ ]exceeded"
    "too many tokens" "token limit exceeded" "\\`4\\(?:00\\|13\\) *\\(?:status code\\)? *(no body)")
  "Provider error messages that mean the prompt overflowed the context window.")

(defconst pai-compaction-non-overflow-patterns
  '("\\`\\(?:Throttling error\\|Service unavailable\\):" "rate limit" "too many requests")
  "Error messages that match an overflow pattern but are not overflows.")

(defun pai-context-overflow-p (message &optional context-window)
  "Return non-nil when assistant MESSAGE failed because the context overflowed.
Either the provider rejected the prompt as too long, or (with CONTEXT-WINDOW)
it truncated the input so that no output fit, a length stop with no output."
  (let ((err (plist-get message :error-message))
        (usage (plist-get message :usage))
        (case-fold-search t))
    (or (and (eq (plist-get message :stop-reason) 'error) (stringp err)
             (not (seq-some (lambda (p) (string-match-p p err))
                            pai-compaction-non-overflow-patterns))
             (seq-some (lambda (p) (string-match-p p err)) pai-compaction-overflow-patterns)
             t)
        (and context-window (> context-window 0)
             (eq (plist-get message :stop-reason) 'length)
             (eql (or (plist-get usage :output) 0) 0)
             (>= (+ (or (plist-get usage :input) 0) (or (plist-get usage :cache-read) 0))
                 (* context-window 0.99))))))

(provide 'pai-compaction)
;;; pai-compaction.el ends here
