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

(defun pai-estimate-tokens (message)
  "Estimate the token count of MESSAGE.
Counts every block the provider serializers actually send, at
`pai-estimate-chars-per-token' characters per token."
  (pai-estimate-tokens-from-chars
   (pcase (pai-message-role message)
     ('tool-result (pai-compaction--content-chars (plist-get message :content)))
     (_ (pai-compaction--content-chars (pai-message-content message))))))

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
      (let ((decl (pai-tool-declaration tool)))
        (cl-incf chars (length (or (plist-get decl :name) "")))
        (cl-incf chars (length (or (plist-get decl :description) "")))
        (cl-incf chars (length (condition-case nil
                                   (pai-json-encode (or (plist-get decl :parameters)
                                                        (pai-json-empty-object)))
                                 (error ""))))))
    (pai-estimate-tokens-from-chars chars)))

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

(defun pai-compaction--find-cut-index (messages keep-recent)
  "Return the index in MESSAGES of the first message to KEEP.
Accumulate tokens from the end until KEEP-RECENT is reached, then snap the cut
to the nearest preceding user message so whole turns are kept together."
  (let ((n (length messages)) (acc 0) (cut nil))
    (cl-loop for i from (1- n) downto 0 do
             (cl-incf acc (pai-estimate-tokens (nth i messages)))
             (when (and (null cut) (>= acc keep-recent))
               (setq cut i)))
    (setq cut (or cut 0))
    (cl-loop for i from cut downto 0
             when (eq (pai-message-role (nth i messages)) 'user)
             return (setq cut i))
    cut))

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

(defvar pai-compaction-progress-function nil
  "When non-nil, called with each chunk of summary text as it streams in.
Bound by the UI around a compaction to show progress; the summary itself
is unaffected.")

(defun pai-compaction-summarize (messages model &optional custom-instructions)
  "Summarize MESSAGES with MODEL synchronously.  Return (:text S :usage U)."
  (let* ((convo (pai-compaction--serialize messages))
         (sys (pai-system-message pai-compaction-system-prompt))
         (user (pai-user-message
                (concat pai-compaction-format-instructions
                        (when (and custom-instructions (not (string-empty-p custom-instructions)))
                          (concat "\n\nAdditional instructions: " custom-instructions))
                        "\n\n<conversation>\n" convo "\n</conversation>")))
         (progress pai-compaction-progress-function)
         (final (pai-provider-stream-sync
                 model (pai-context (list sys user) nil)
                 (list :max-tokens pai-compaction-summary-max-tokens)
                 nil
                 (and progress
                      (lambda (ev)
                        (when (eq (plist-get ev :type) 'text-delta)
                          (funcall progress (or (plist-get ev :delta) ""))))))))
    (list :text (if final (pai-content-text (pai-message-content final)) "")
          :usage (and final (plist-get final :usage)))))

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

(defun pai-compact (messages model &optional custom-instructions)
  "Compact MESSAGES using MODEL.  Return a plist or nil when nothing to compact.
The plist is (:messages NEW-LIST :summary S :cut-index N :tokens-before T
:usage U), where NEW-LIST is leading system messages, the summary message, and
the kept recent messages."
  (let* ((system (seq-take-while #'pai-system-message-p messages))
         (rest (seq-drop-while #'pai-system-message-p messages))
         (keep (pai-compaction-keep-recent-tokens))
         (cut (pai-compaction--find-cut-index rest keep))
         (tokens-before (pai-estimate-context-tokens messages)))
    (when (> cut 0)
      (let* ((to-summarize (seq-take rest cut))
             (kept (nthcdr cut rest))
             (result (pai-compaction-summarize to-summarize model custom-instructions))
             (summary (plist-get result :text))
             (carried (pai-tool-carried-schemas to-summarize kept)))
        (when (and summary (not (string-empty-p (string-trim summary))))
          (list :messages (append system
                                  (list (pai-compaction-summary-message summary carried))
                                  ;; Everything the kept messages' usage counts
                                  ;; described has just been replaced by the
                                  ;; summary, so those anchors no longer
                                  ;; describe this context.
                                  (pai-invalidate-usage-anchors kept))
                :summary summary
                :cut-index cut
                :tokens-before tokens-before
                :usage (plist-get result :usage)))))))

(provide 'pai-compaction)
;;; pai-compaction.el ends here
