;;; pai-provider-anthropic.el --- Anthropic Messages provider -*- lexical-binding: t; -*-

;;; Commentary:

;; Provider for the Anthropic Messages API (api symbol `anthropic-messages').
;; Translates the unified transcript to Anthropic's request shape and parses
;; the SSE response into unified events.  Port of the essential behavior of
;; packages/ai/src/api/anthropic-messages.ts.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-core)
(require 'pai-models)
(require 'pai-provider)
(require 'pai-stream)
(require 'pai-settings)

(defconst pai-anthropic-version "2023-06-01"
  "Value of the anthropic-version request header.")

(defconst pai-anthropic-oauth-beta "oauth-2025-04-20"
  "anthropic-beta flag required for Claude Pro/Max OAuth-token requests.")

(defconst pai-anthropic-claude-code-system
  "You are Claude Code, Anthropic's official CLI for Claude."
  "System instruction Anthropic requires as the first system block under OAuth.")

(defcustom pai-anthropic-claude-code-cli-version "2.1.280"
  "Claude Code CLI version presented on OAuth-token requests.

Anthropic rejects requests whose client version is older than the
minimum it currently supports, with a `claude_code_version_too_old'
error.  Bump this string when that happens; everything that reports a
client version derives it from here."
  :type 'string
  :group 'pai)

(defun pai-anthropic-claude-code-user-agent ()
  "Return the User-Agent presented on OAuth-token requests."
  (format "claude-cli/%s (external, cli)" pai-anthropic-claude-code-cli-version))

(defun pai-anthropic--oauth-token-p (key)
  "Return non-nil when KEY is an Anthropic OAuth access token (sk-ant-oat...)."
  (and (stringp key) (string-search "sk-ant-oat" key) t))

;;;; Request building

(defun pai-anthropic--system (messages)
  "Return the Anthropic system prompt string from system MESSAGES, or nil."
  (let ((parts (delq nil
                     (mapcar (lambda (m)
                               (when (pai-system-message-p m)
                                 (let ((txt (pai-content-text (pai-message-content m))))
                                   (unless (string-empty-p txt) txt))))
                             messages))))
    (when parts (string-join parts "\n\n"))))

(defun pai-anthropic--content-blocks (content)
  "Translate unified CONTENT blocks to Anthropic request blocks."
  (delq nil
   (mapcar
   (lambda (b)
     (pcase (pai-block-type b)
       ('text (list :type "text" :text (or (plist-get b :text) "")))
       ('image (list :type "image"
                     :source (list :type "base64"
                                   :media_type (plist-get b :mime-type)
                                   :data (plist-get b :data))))
       ('thinking
        ;; Unsigned thinking blocks (a stream that ended right after a
        ;; thinking block started) are rejected by the API with
        ;; `each thinking block must contain thinking'; drop them.
        (let ((sig (plist-get b :thinking-signature)))
          (cond
           ((or (null sig) (equal sig "")) nil)
           ((pai-truthy (plist-get b :redacted))
            (list :type "redacted_thinking" :data sig))
           (t (list :type "thinking"
                    :thinking (or (plist-get b :thinking) "")
                    :signature sig)))))
       ('tool-call
        (list :type "tool_use" :id (plist-get b :id) :name (plist-get b :name)
              :input (or (plist-get b :arguments) (pai-json-empty-object))))
       (_ nil)))
   (pai-normalize-content content))))

(defun pai-anthropic--tool-result-block (message)
  "Translate a unified tool-result MESSAGE to an Anthropic tool_result block."
  (list :type "tool_result"
        :tool_use_id (plist-get message :tool-call-id)
        :content (pai-anthropic--content-blocks (plist-get message :content))
        :is_error (if (pai-truthy (plist-get message :is-error)) t :false)))

(defun pai-anthropic--push-user (acc blocks)
  "Push user BLOCKS onto reversed message list ACC, merging with a trailing user."
  (let ((head (car acc)))
    (if (and head (equal (plist-get head :role) "user"))
        (progn (setcar acc (list :role "user"
                                 :content (append (plist-get head :content) blocks)))
               acc)
      (cons (list :role "user" :content blocks) acc))))

(defun pai-anthropic--messages (messages)
  "Translate unified MESSAGES (sans system) to Anthropic messages array.
Messages whose translated content is empty are dropped: the Anthropic
Messages API rejects any message with a missing or empty `content' field
(e.g. `messages.N.content: Field required'), which can otherwise happen
when generation was interrupted (rate/token limit) and an assistant
message was persisted with no content blocks."
  (let (acc)
    (dolist (m messages)
      (pcase (pai-message-role m)
        ('user (let ((blocks (pai-anthropic--content-blocks (pai-message-content m))))
                 (when blocks
                   (setq acc (pai-anthropic--push-user acc blocks)))))
        ('tool-result (setq acc (pai-anthropic--push-user
                                 acc (list (pai-anthropic--tool-result-block m)))))
        ('assistant (let ((blocks (pai-anthropic--content-blocks (pai-message-content m))))
                      (when blocks
                        (push (list :role "assistant" :content blocks) acc))))
        ('system nil)))
    (nreverse acc)))

(defun pai-anthropic--tools (tools)
  "Translate unified TOOLS declarations to Anthropic tool objects, or nil."
  (when tools
    (mapcar (lambda (tool)
              (list :name (plist-get tool :name)
                    :description (or (plist-get tool :description) "")
                    :input_schema (or (plist-get tool :parameters)
                                      (list :type "object"
                                            :properties (pai-json-empty-object)))))
            tools)))

(defun pai-anthropic--thinking-budget (level)
  "Return an Anthropic thinking budget in tokens for LEVEL symbol."
  (pcase level
    ('minimal 1024) ('low 2048) ('medium 8192) ('high 16384) ('xhigh 24576)
    ('max 32000) (_ 8192)))

(defun pai-anthropic--tool-choice (tc)
  "Map a unified tool-choice TC to an Anthropic tool_choice object, or nil."
  (pcase tc
    ('auto (list :type "auto"))
    ('none (list :type "none"))
    ((or 'required 'any) (list :type "any"))
    (`(tool . ,name) (list :type "tool" :name name))
    (_ nil)))

(defun pai-anthropic--messages-with-cache (msgs caching)
  "Return MSGS, adding an ephemeral cache marker to the last block when CACHING."
  (if (or (not caching) (null msgs))
      msgs
    (let* ((rev (reverse msgs))
           (last (car rev))
           (content (plist-get last :content)))
      (if (and (listp content) content)
          (let* ((crev (reverse content))
                 (lastblock (append (car crev) (list :cache_control (list :type "ephemeral"))))
                 (newcontent (reverse (cons lastblock (cdr crev))))
                 (newlast (plist-put (copy-sequence last) :content newcontent)))
            (reverse (cons newlast (cdr rev))))
        msgs))))

(defun pai-anthropic-build-request (model context options)
  "Build an Anthropic request plist for MODEL, CONTEXT and OPTIONS."
  (let* ((messages (plist-get context :messages))
         (caching (pai-truthy (pai-settings-get :prompt-cache t)))
         (oauth (pai-anthropic--oauth-token-p (plist-get options :api-key)))
         (tools (pai-anthropic--tools (plist-get context :tools)))
         (tools (if (and caching tools)
                    (append (butlast tools)
                            (list (append (car (last tools))
                                          (list :cache_control (list :type "ephemeral")))))
                  tools))
         (system (pai-anthropic--system messages))
         ;; OAuth (Claude Pro/Max) requires the Claude Code identity as the first
         ;; system block, with the user's prompt following it.
         (system-val
          (cond
           (oauth
            (append
             (list (list :type "text" :text pai-anthropic-claude-code-system
                         :cache_control (list :type "ephemeral")))
             (when (and system (not (string-empty-p system)))
               (list (append (list :type "text" :text system)
                             (when caching (list :cache_control (list :type "ephemeral"))))))))
           ((and caching system)
            (list (list :type "text" :text system :cache_control (list :type "ephemeral"))))
           (t system)))
         (send-system (or oauth (and system t)))
         (reasoning (plist-get options :reasoning))
         (thinking (when (and reasoning (pai-model-reasoning-p model))
                     (list :type "enabled"
                           :budget_tokens (pai-anthropic--thinking-budget reasoning))))
         (base-max (or (plist-get options :max-tokens) (plist-get model :max-tokens) pai-max-tokens))
         (max-tokens (if thinking (max base-max (+ (plist-get thinking :budget_tokens) 4096)) base-max))
         (tool-choice (pai-anthropic--tool-choice (plist-get options :tool-choice)))
         (body (append
                (list :model (plist-get model :id)
                      :max_tokens max-tokens
                      :stream t
                      :messages (pai-anthropic--messages-with-cache
                                 (pai-anthropic--messages messages) caching))
                (when send-system (list :system system-val))
                (when tools (list :tools tools))
                (when thinking (list :thinking thinking))
                (when (and (plist-get options :temperature) (not thinking))
                  (list :temperature (plist-get options :temperature)))
                (when tool-choice (list :tool_choice tool-choice)))))
    (list :url (concat (plist-get model :base-url) "/messages")
          :headers (append
                    (if oauth
                        (list (cons "authorization"
                                    (concat "Bearer " (plist-get options :api-key)))
                              (cons "anthropic-beta" pai-anthropic-oauth-beta)
                              (cons "anthropic-version" pai-anthropic-version)
                              (cons "content-type" "application/json")
                              (cons "accept" "application/json")
                              (cons "user-agent" (pai-anthropic-claude-code-user-agent)))
                      (list (cons "x-api-key" (or (plist-get options :api-key) ""))
                            (cons "anthropic-version" pai-anthropic-version)
                            (cons "content-type" "application/json")))
                    (pai-anthropic--header-alist (plist-get model :headers)))
          :body body)))

(defun pai-anthropic--header-alist (headers)
  "Convert a HEADERS plist to an alist of string pairs."
  (let (out (rest headers))
    (while rest
      (push (cons (if (keywordp (car rest)) (substring (symbol-name (car rest)) 1)
                    (format "%s" (car rest)))
                  (cadr rest))
            out)
      (setq rest (cddr rest)))
    (nreverse out)))

;;;; Stream parsing

(defun pai-anthropic--stop (reason)
  "Map an Anthropic stop REASON string to a unified stop-reason symbol."
  (pcase reason
    ("end_turn" 'stop) ("stop_sequence" 'stop) ("pause_turn" 'stop) ("refusal" 'stop)
    ("max_tokens" 'length) ("tool_use" 'tool-use)
    (_ 'stop)))

(defun pai-anthropic-make-parser (model emit)
  "Return an Anthropic SSE parser plist (:on-frame :on-close) for MODEL, EMIT."
  (let ((acc (pai-accum-new model))
        (idx-map (make-hash-table :test 'eql)) ; anthropic index -> our index
        (input 0) (output 0) (cache-read 0) (cache-write 0)
        (stop 'stop) (done nil))
    (cl-labels
        ((our-idx (ai) (gethash ai idx-map))
         ;; `input_tokens' counts only the tokens that were NOT served from the
         ;; prompt cache.  We send `cache_control' on every request, so on a
         ;; warm session it is a few hundred while the real prompt is the
         ;; cached bulk: the total context is input + cache reads + cache
         ;; writes + output.  Reading only `input_tokens' made the context
         ;; meter report a fraction of the true size, and left cached input and
         ;; cache writes out of the usage record `pai-usage-cost' prices.
         (set-usage () (pai-accum-set-usage
                        acc (pai-usage :input input :output output
                                       :cache-read cache-read
                                       :cache-write cache-write
                                       :total-tokens (+ input cache-read
                                                        cache-write output))))
         (handle (frame)
           (let* ((data (condition-case nil (pai-json-decode (plist-get frame :data))
                          (error nil)))
                  (type (and data (plist-get data :type))))
             (pcase type
               ("message_start"
                (pai-accum-start acc emit)
                (let* ((msg (plist-get data :message))
                       (usage (plist-get msg :usage)))
                  (when (plist-get msg :id)
                    (setf (pai-accum-response-id acc) (plist-get msg :id)))
                  (when usage
                    (setq input (or (plist-get usage :input_tokens) 0))
                    (setq cache-read (or (plist-get usage :cache_read_input_tokens) 0))
                    (setq cache-write (or (plist-get usage :cache_creation_input_tokens) 0))
                    (set-usage))))
               ("content_block_start"
                (let* ((ai (plist-get data :index))
                       (cb (plist-get data :content_block))
                       (ct (plist-get cb :type)))
                  (pcase ct
                    ("text" (puthash ai (pai-accum-text-start acc emit) idx-map))
                    ("thinking" (puthash ai (pai-accum-thinking-start
                                             acc emit (plist-get cb :signature) nil)
                                         idx-map))
                    ("redacted_thinking"
                     (puthash ai (pai-accum-thinking-start acc emit (plist-get cb :data) t)
                              idx-map))
                    ("tool_use"
                     (puthash ai (pai-accum-toolcall-start acc emit (plist-get cb :id)
                                                           (plist-get cb :name))
                              idx-map)))))
               ("content_block_delta"
                (let* ((ai (plist-get data :index))
                       (oi (our-idx ai))
                       (delta (plist-get data :delta))
                       (dt (plist-get delta :type)))
                  (when oi
                    (pcase dt
                      ("text_delta" (pai-accum-text-delta acc emit oi (plist-get delta :text)))
                      ("thinking_delta" (pai-accum-thinking-delta acc emit oi (plist-get delta :thinking)))
                      ("signature_delta" (pai-accum-thinking-signature acc oi (plist-get delta :signature)))
                      ("input_json_delta" (pai-accum-toolcall-delta acc emit oi (plist-get delta :partial_json)))))))
               ("content_block_stop"
                (let* ((ai (plist-get data :index)) (oi (our-idx ai)))
                  (when oi
                    (pcase (pai-block-type (pai-accum-block acc oi))
                      ('text (pai-accum-text-end acc emit oi))
                      ('thinking (pai-accum-thinking-end acc emit oi))
                      ('tool-call (pai-accum-toolcall-end acc emit oi))))))
               ("message_delta"
                (let ((d (plist-get data :delta)) (u (plist-get data :usage)))
                  (when (plist-get d :stop_reason)
                    (setq stop (pai-anthropic--stop (plist-get d :stop_reason))))
                  ;; message_delta carries the final counts; Anthropic may
                  ;; restate the input side here, so take whatever it sends.
                  (when u
                    (when (plist-get u :output_tokens)
                      (setq output (plist-get u :output_tokens)))
                    (when (plist-get u :input_tokens)
                      (setq input (plist-get u :input_tokens)))
                    (when (plist-get u :cache_read_input_tokens)
                      (setq cache-read (plist-get u :cache_read_input_tokens)))
                    (when (plist-get u :cache_creation_input_tokens)
                      (setq cache-write (plist-get u :cache_creation_input_tokens)))
                    (set-usage))))
               ("message_stop"
                (unless done (setq done t) (pai-accum-done acc emit stop)))
               ("error"
                (unless done
                  (setq done t)
                  (pai-accum-error acc emit 'error
                                   (or (plist-get (plist-get data :error) :message)
                                       "anthropic stream error")))))))
         (close (_code)
           (unless done (setq done t) (pai-accum-done acc emit stop)))
         (errf (msg)
           (unless done (setq done t) (pai-accum-error acc emit 'error msg))))
      (list :on-frame #'handle :on-close #'close :on-error #'errf))))

(provide 'pai-provider-anthropic)
;;; pai-provider-anthropic.el ends here
