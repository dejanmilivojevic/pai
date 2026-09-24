;;; pai-ui.el --- Emacs-buffer chat UI for pai -*- lexical-binding: t; -*-

;;; Commentary:

;; The interactive front end: a chat buffer (`pai-mode') that renders the agent
;; event stream and provides a comint-style input area.  This replaces pi's
;; terminal TUI with native Emacs infrastructure (buffers, faces, keymaps,
;; header line).  The UI is a pure consumer of agent events and forwards those
;; events to extensions via `pai-ext-emit'.
;;
;; Layout: a read-only transcript region grows above a fixed prompt line; text
;; typed after the prompt is the input.  RET submits.  Submitting while a run is
;; active enqueues a steering message.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-core)
(require 'pai-config)
(require 'pai-settings)
(require 'pai-models)
(require 'pai-model-resolver)
(require 'pai-provider)
(require 'pai-provider-anthropic)
(require 'pai-provider-openai)
(require 'pai-provider-gemini)
(require 'pai-agent)
(require 'pai-tools)
(require 'pai-tools-builtin)
(require 'pai-history)
(require 'pai-prompt)
(require 'pai-skills)
(require 'pai-commands)
(require 'pai-markdown)
(require 'pai-compaction)
(require 'pai-activity)
(require 'pai-compose)
(require 'pai-refs)
(require 'pai-export)
(require 'pai-prompts)
(require 'pai-diff)
(require 'pai-session)
(require 'pai-preview)
(require 'pai-ext)
(require 'pai-trust)
(require 'pai-auth)
(require 'pai-usage)
(require 'pai-pricing)

(defvar pai-mode-map)

;;;; Faces

(defface pai-user-face '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the user message header." :group 'pai)
(defface pai-assistant-header-face '((t :inherit font-lock-function-name-face :weight bold))
  "Face for the assistant message header." :group 'pai)
(defface pai-assistant-face '((t :inherit default))
  "Face for streamed assistant text." :group 'pai)
(defface pai-thinking-face '((t :inherit shadow :slant italic))
  "Face for assistant reasoning." :group 'pai)
(defface pai-tool-face '((t :inherit font-lock-type-face))
  "Face for tool-call headers." :group 'pai)
(defface pai-tool-result-face '((t :inherit shadow))
  "Face for tool results." :group 'pai)
(defface pai-error-face '((t :inherit error))
  "Face for errors." :group 'pai)
(defface pai-note-face '((t :inherit font-lock-comment-face))
  "Face for UI notes." :group 'pai)
(defface pai-prompt-face '((t :inherit minibuffer-prompt :weight bold))
  "Face for the input prompt." :group 'pai)

(defconst pai-prompt-string "❯ " "The input prompt shown at the bottom of the chat buffer.")

;;;; Buffer-local state

(defvar-local pai--session nil "The `pai-session' backing this buffer.")
(defvar-local pai--model nil "The current model plist for this buffer.")
(defvar-local pai--run nil "The active `pai-run', or nil when idle.")
(defvar-local pai--output-marker nil "Marker at the end of the transcript region.")
(defvar-local pai--input-marker nil "Marker at the start of the editable input region.")
(defvar-local pai--steering-queue nil "Queued steering messages typed during a run.")
(defvar-local pai--status "idle" "Short status string for the header line.")
(defvar-local pai--assistant-open nil "Non-nil while an assistant block is being rendered.")
(defvar-local pai--reasoning nil "Thinking level for this buffer, or nil.")
(defvar-local pai--context-messages nil "The live LLM context (system prompt + turns).")
(defvar-local pai--usage-total nil "Accumulated usage plist for this session.")
(defvar-local pai--context-tokens 0 "Last estimated context-token count.")
(defvar-local pai--trusted nil "Whether the current project is trusted.")
(defvar-local pai--history-snapshot nil
  "Project input history captured when browsing started, newest first.")
(defvar-local pai--history-index nil
  "Index into `pai--history-snapshot' being shown, or nil when not browsing.")
(defvar-local pai--history-draft nil
  "The unsent input that was in place when history browsing started.")

(defvar-local pai--assistant-content-start nil
  "Marker at the start of the current assistant block's content.")
(defvar-local pai--active nil "Non-nil while an agent run is in progress.")
(defvar-local pai--ext-statuses nil "Alist of extension status key -> text.")
(defvar-local pai--widgets nil "Alist of extension widget key -> content string.")
(defvar-local pai--ext-header nil "Extension-provided header text.")
(defvar-local pai--ext-footer nil "Extension-provided footer text.")
(defvar-local pai--working-message nil "Transient working-indicator message.")
(defvar-local pai--usage-summary nil "Cached provider usage summary for the header line.")
(defvar-local pai--run-committed nil
  "Messages of the current run already committed to the context and session.")

;;;; Rendering primitives

(defun pai--propertize (text &optional face)
  "Return TEXT propertized read-only with optional FACE."
  (apply #'propertize text
         'read-only t 'front-sticky t 'rear-nonsticky t
         (when face (list 'face face))))

(defun pai--follow-input ()
  "Keep the input line pinned to the bottom of windows showing this buffer.
Only follows a window whose point sits within the input region, so a user who
has scrolled up to read history (point above `pai--input-marker') is not
yanked back down.  The selected window is left to `scroll-conservatively',
which keeps point (at the prompt) on the last row; other windows showing the
buffer have their `window-point' advanced to the prompt so they track output."
  (when (and pai--input-marker (marker-buffer pai--input-marker))
    (let ((im (marker-position pai--input-marker)))
      (dolist (win (get-buffer-window-list (current-buffer) nil t))
        (when (and (not (eq win (selected-window)))
                   (>= (window-point win) im))
          (set-window-point win (point-max)))))))

(defun pai--insert (text &optional face)
  "Insert TEXT (with optional FACE) into the transcript region.
The input line stays at the buffer's end; TEXT is inserted above it and the
prompt is re-pinned to the bottom of the window."
  (when (and pai--output-marker (marker-buffer pai--output-marker))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char pai--output-marker)
        (insert (pai--propertize text face)))
      (pai--follow-input))))

(defun pai--ensure-fresh-line ()
  "Insert a newline in the transcript unless it already ends with one."
  (when (and pai--output-marker (> (marker-position pai--output-marker) (point-min)))
    (let ((ch (char-before pai--output-marker)))
      (unless (eql ch ?\n) (pai--insert "\n")))))

;;;; Event rendering

(defun pai--render-user (message)
  "Render a user MESSAGE header and content."
  (setq pai--assistant-open nil)
  (pai--ensure-fresh-line)
  ;; the header remembers its message, so /tree can find the prompt again
  (pai--insert (propertize "\n▶ You\n" 'pai-prompt-ts (plist-get message :timestamp))
               'pai-user-face)
  (pai--insert (concat (pai-md-highlight-fences
                        (string-trim-right (pai-content-text (pai-message-content message))))
                       "\n")))

(defun pai--render-note (text &optional face)
  "Render a UI note TEXT with FACE (default `pai-note-face')."
  (pai--ensure-fresh-line)
  (pai--insert (concat "\n" (string-trim-right text) "\n") (or face 'pai-note-face)))

(defun pai--open-assistant ()
  "Insert the assistant block header if not already open."
  (unless pai--assistant-open
    (setq pai--assistant-open t)
    (pai--ensure-fresh-line)
    (pai--insert "\n● pai\n" 'pai-assistant-header-face)
    (setq pai--assistant-content-start (copy-marker pai--output-marker nil))))

(defun pai--handle-update (stream-event)
  "Render a streaming STREAM-EVENT (a unified assistant-message event)."
  (pcase (plist-get stream-event :type)
    ('text-delta (pai--open-assistant)
                 (pai--insert (plist-get stream-event :delta) 'pai-assistant-face))
    ('thinking-delta (pai--open-assistant)
                     (pai--insert (plist-get stream-event :delta) 'pai-thinking-face))
    (_ nil)))

(defun pai--insert-assistant-blocks (message)
  "Insert MESSAGE's thinking/text blocks (formatted) at the output marker."
  (let ((custom (pai-ext-render-message message)))
    (if custom
        (pai--insert (concat (string-trim-right custom) "\n"))
      (dolist (block (pai-message-content message))
        (pcase (pai-block-type block)
          ('thinking
           (let ((tx (string-trim-right (or (plist-get block :thinking) ""))))
             (unless (string-empty-p tx)
               (pai--insert (concat tx "\n") 'pai-thinking-face))))
          ('text
           (let ((tx (or (plist-get block :text) "")))
             (unless (string-empty-p tx)
               (pai--insert (concat (pai-markdown-render (pai-ext-transform-markdown tx)) "\n")))))
          (_ nil))))))

(defun pai--rerender-assistant (message)
  "Replace the streamed assistant region with a formatted render of MESSAGE."
  (let ((start (and pai--assistant-content-start
                    (marker-position pai--assistant-content-start)))
        (end (and pai--output-marker (marker-position pai--output-marker))))
    (when (and start end (< start end))
      (let ((inhibit-read-only t))
        (delete-region start end))
      (pai--insert-assistant-blocks message))))

(defun pai--finish-assistant (message)
  "Finish the current assistant block for MESSAGE."
  (when pai--assistant-open
    (pai--rerender-assistant message)
    (pai--ensure-fresh-line)
    (setq pai--assistant-open nil
          pai--assistant-content-start nil))
  (when (and (eq (plist-get message :stop-reason) 'error)
             (plist-get message :error-message))
    (pai--render-note (concat "error: " (plist-get message :error-message)) 'pai-error-face)))

(defun pai--summarize-args (args)
  "Return a compact one-line summary of tool ARGS."
  (let ((s (condition-case nil (pai-json-encode (or args (pai-json-empty-object))) (error "{}"))))
    (if (> (length s) 120) (concat (substring s 0 117) "...") s)))

(defvar-local pai--tool-call-args nil
  "Hash of tool-call id to (NAME . ARGS), so results can be shown per tool.")

(defun pai--remember-tool-call (id name args)
  "Remember tool call ID of tool NAME with ARGS for rendering its result."
  (when id
    (unless pai--tool-call-args
      (setq pai--tool-call-args (make-hash-table :test 'equal)))
    (puthash id (cons name args) pai--tool-call-args)))

(defun pai--render-tool-start (event)
  "Render the start of a tool call from EVENT."
  (setq pai--assistant-open nil)
  (pai--remember-tool-call (plist-get event :tool-call-id) (plist-get event :tool-name)
                           (plist-get event :args))
  (pai--ensure-fresh-line)
  (pai--insert (format "\n⚙ %s " (plist-get event :tool-name)) 'pai-tool-face)
  (let ((summary (copy-sequence
                  (pai-md-fontify (pai--summarize-args (plist-get event :args)) 'js-json-mode))))
    (add-face-text-property 0 (length summary) 'pai-tool-face t summary)
    (pai--insert (concat summary "\n"))))

(defun pai--tool-result-mode (name args)
  "Return the major mode that tool NAME's result for ARGS is code in, or nil."
  (pcase name
    ("read" (pai-md-mode-for-file (plist-get args :path)))
    ("read_buffer" (let ((buffer (get-buffer (or (plist-get args :name) ""))))
                     (and buffer
                          (not (memq (buffer-local-value 'major-mode buffer)
                                     '(fundamental-mode pai-mode)))
                          (pai-md--usable-mode (buffer-local-value 'major-mode buffer)))))
    ("elisp_eval" 'emacs-lisp-mode)
    (_ nil)))

(defun pai--render-tool-end (event)
  "Render the result of a tool call from EVENT, showing a diff for file edits."
  (let* ((result (plist-get event :result))
         (is-error (pai-truthy (plist-get event :is-error)))
         (details (plist-get result :details))
         (old (and details (plist-get details :old)))
         (new (and details (plist-get details :new))))
    (cond
     ((and (not is-error) old new (not (equal old new)))
      (pai--insert (concat "  " (pai-content-text (plist-get result :content)) "\n")
                   'pai-tool-result-face)
      (let* ((name (or (plist-get details :path) ""))
             (diff (pai-diff-render old new name name)))
        (pai--insert (concat (mapconcat (lambda (l) (concat "  " l))
                                        (split-string (string-trim-right diff) "\n") "\n")
                             "\n"))))
     (t
      (let* ((text (pai-content-text (plist-get result :content)))
             (trunc (pai-tools-truncate text 20 4096 'head))
             (body (plist-get trunc :text))
             (call (and pai--tool-call-args
                        (gethash (plist-get event :tool-call-id) pai--tool-call-args)))
             (mode (and (not is-error)
                        (pai--tool-result-mode (plist-get event :tool-name) (cdr call))))
             (more (when (plist-get trunc :truncated) "\n  … (truncated)")))
        (if (not mode)
            (pai--insert (concat (mapconcat (lambda (l) (concat "  " l))
                                            (split-string (concat body more) "\n") "\n")
                                 "\n")
                         (if is-error 'pai-error-face 'pai-tool-result-face))
          ;; Code: the language's own highlighting, indented like any result.
          (let ((code (pai-md-fontify body mode)))
            (pai--insert (concat (mapconcat (lambda (l) (concat "  " l))
                                            (split-string code "\n") "\n")
                                 (if more (propertize more 'face 'pai-tool-result-face) "")
                                 "\n")))))))))

(defun pai-ui--on-event (event)
  "Render a single agent EVENT into the current buffer."
  (pcase (plist-get event :type)
    ('agent-start
     (setq pai--run-committed nil)
     (pai--set-status "working…"))
    ('turn-start nil)
    ('message-start
     (let ((m (plist-get event :message)))
       (when (pai-user-message-p m) (pai--render-user m))
       (when (pai-assistant-message-p m) (setq pai--assistant-open nil))))
    ('message-update (pai--handle-update (plist-get event :event)))
    ('message-end
     (let ((m (plist-get event :message)))
       (when (pai-assistant-message-p m) (pai--finish-assistant m))
       (pai--commit-message m)))
    ('tool-execution-start (pai--render-tool-start event))
    ('tool-execution-end (pai--render-tool-end event))
    ('turn-end
     (mapc #'pai--commit-message (plist-get event :tool-results))
     (pai--schedule-usage-refresh))
    ('agent-end
     ;; Normally everything was committed as it completed; this catches the rest.
     (mapc #'pai--commit-message (plist-get event :messages))
     (setq pai--run-committed nil)
     (setq pai--active nil pai--run nil)
     (pai--set-status "idle")
     (setq pai--working-message nil)
     (pai--refresh-context-tokens)
     (pai--schedule-usage-refresh)
     (if (plist-get event :aborted)
         (progn (when pai--assistant-open
                  (pai--ensure-fresh-line)
                  (setq pai--assistant-open nil pai--assistant-content-start nil))
                (pai--render-note "— interrupted —" 'pai-error-face))
       (pai--render-note "— ready —"))
     (unless pai--steering-queue
       (pai-ext-emit 'agent-settled (pai--ext-context))))
    (_ nil)))

(defun pai--commit-message (message)
  "Commit a completed run MESSAGE to the live context and session, once.
Called as each message completes, so the header (context, cost, limits)
and extension widgets update while the agent works, not only at the end."
  (when (and message (not (memq message pai--run-committed)))
    (push message pai--run-committed)
    (when pai--session (pai-session-append-message pai--session message))
    (setq pai--context-messages (append pai--context-messages (list message)))
    (pai--update-usage (list message))))

;;;; Extension bridge

(defun pai--set-model-id (id)
  "Set the current model to ID, persist it, and emit `model-select'."
  (let ((m (pai-model id)))
    (when m
      (let ((prev pai--model))
        (setq pai--model m)
        (ignore-errors (pai-settings-set :model (pai-model-key m) 'project))
        (pai-ext-emit 'model-select (pai--ext-context) :model m :previous-model prev :source 'set)
        (pai--set-status "idle")
        (pai--schedule-usage-refresh t)))))

(defun pai--set-thinking-level (level)
  "Set the reasoning LEVEL, persist it, and emit `thinking-level-select'."
  (let ((prev (if pai--reasoning (symbol-name pai--reasoning) "off")))
    (setq pai--reasoning (if (or (null level) (equal level "off")) nil (intern level)))
    (ignore-errors (pai-settings-set :thinking-level (or level "off") 'project))
    (pai-ext-emit 'thinking-level-select (pai--ext-context) :level level :previous-level prev)))

(defun pai--ext-context ()
  "Build an extension/runtime context for the current buffer."
  (let ((buf (current-buffer)))
    (append
     (pai-ext-make-context
      :cwd default-directory :mode 'tui :has-ui t
      :model pai--model :session pai--session
      :ui (list :notify (lambda (msg &optional _type) (message "%s" msg))
                :select (lambda (title options) (completing-read (concat title " ") options))
                :confirm (lambda (title msg) (y-or-n-p (format "%s: %s " title msg)))
                :input (lambda (title &optional placeholder) (read-string (concat title " ") placeholder))
                :set-status (lambda (key text) (with-current-buffer buf (pai--set-ext-status key text)))
                :set-widget (lambda (key content &optional _opts) (with-current-buffer buf (pai--set-widget key content)))
                :set-panel (lambda (key text) (with-current-buffer buf (pai--set-panel key text)))
                :set-header (lambda (text) (with-current-buffer buf (setq pai--ext-header text) (force-mode-line-update)))
                :set-footer (lambda (text) (with-current-buffer buf (setq pai--ext-footer text) (pai--refresh-footer)))
                :set-title (lambda (title) (with-current-buffer buf (rename-buffer (format "*pai: %s*" title) t)))
                :set-working-message (lambda (msg) (with-current-buffer buf (setq pai--working-message msg) (force-mode-line-update))))
      :session-name-get (lambda () (and pai--session (pai-session-name pai--session)))
      :session-name-set (lambda (name)
                          (with-current-buffer buf
                            (when pai--session (pai-session-set-name pai--session name)))))
     (list :buffer buf
           :thinking-level (if pai--reasoning (symbol-name pai--reasoning) "off")
           :set-model (lambda (id) (with-current-buffer buf (pai--set-model-id id)))
           :set-thinking (lambda (level) (with-current-buffer buf (pai--set-thinking-level level)))))))

(defun pai--emit-fn ()
  "Return an event sink closure bound to the current buffer."
  (let ((buf (current-buffer)))
    (lambda (event)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (pai-ui--on-event event)
          (apply #'pai-ext-emit (plist-get event :type) (pai--ext-context) (cddr event)))))))

;;;; Config

(defun pai--config ()
  "Build the agent-loop config for the current buffer."
  (let ((buf (current-buffer)))
    (list :model pai--model
          :tools (pai-tools-all)
          :cwd default-directory
          :session pai--session
          :reasoning pai--reasoning
          :session-id (and pai--session (pai-session-id pai--session))
          :tool-execution (let ((te (pai-settings-get :tool-execution)))
                            (if (stringp te) (intern te) (or te pai-tool-execution)))
          :max-tokens (pai-settings-get :max-tokens)
          :temperature (pai-settings-get :temperature)
          :transform-context
          (lambda (msgs &optional _sig)
            (with-current-buffer buf (pai-ext-run-context msgs (pai--ext-context))))
          :before-tool-call
          (lambda (data)
            (with-current-buffer buf
              (pai-ext-run-tool-call (plist-get data :tool-call) (plist-get data :args)
                                     (pai--ext-context))))
          :after-tool-call
          (lambda (data)
            (with-current-buffer buf
              (pai-ext-run-tool-result (plist-get data :result) (pai--ext-context)
                                       (plist-get data :tool-call) (plist-get data :args))))
          :get-steering-messages
          (lambda ()
            (with-current-buffer buf
              (prog1 (nreverse pai--steering-queue) (setq pai--steering-queue nil)))))))

;;;; Status / header line

(defcustom pai-spinner-frames ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Frames of the spinner shown in the header line while pai is busy.
Set to nil to show the status text without animation."
  :type '(choice (const :tag "No animation" nil) (vector string))
  :group 'pai)

(defcustom pai-spinner-interval 0.1
  "Seconds between spinner frames."
  :type 'number
  :group 'pai)

(defvar-local pai--spinner-timer nil
  "Timer advancing this buffer's header-line spinner while busy.")

(defvar-local pai--spinner-index 0
  "Index of the spinner frame currently shown.")

(defun pai--busy-p ()
  "Return non-nil while the buffer's status is not idle."
  (not (equal pai--status "idle")))

(defun pai--spinner-frame ()
  "Return the current spinner frame, or nil when not animating."
  (when (and (pai--busy-p) (> (length pai-spinner-frames) 0))
    (aref pai-spinner-frames (% pai--spinner-index (length pai-spinner-frames)))))

(defun pai--spinner-stop ()
  "Stop this buffer's spinner."
  (when (timerp pai--spinner-timer) (cancel-timer pai--spinner-timer))
  (setq pai--spinner-timer nil pai--spinner-index 0))

(defun pai--spinner-start ()
  "Animate this buffer's header line until its status returns to idle.
The timer only redraws this buffer's header, and stops itself when the
buffer dies or goes idle."
  (unless (or (timerp pai--spinner-timer) (= (length pai-spinner-frames) 0))
    (let ((buf (current-buffer)) timer)
      (setq timer
            (run-at-time
             pai-spinner-interval pai-spinner-interval
             (lambda ()
               (if (not (buffer-live-p buf))
                   (cancel-timer timer)
                 (with-current-buffer buf
                   (if (not (pai--busy-p))
                       (pai--spinner-stop)
                     (setq pai--spinner-index (1+ pai--spinner-index))
                     (force-mode-line-update)))))))
      (setq pai--spinner-timer timer))))

(defun pai--set-status (status)
  "Set the buffer STATUS and refresh the header line.
Any status other than \"idle\" animates a spinner next to it."
  (setq pai--status status)
  (if (pai--busy-p) (pai--spinner-start) (pai--spinner-stop))
  (force-mode-line-update))

(defun pai--format-tokens (n)
  "Format token count N compactly (e.g. 1.2k, 120k, 1.2M)."
  (cond ((< n 1000) (number-to-string n))
        ((< n 10000) (format "%.1fk" (/ n 1000.0)))
        ((< n 1000000) (format "%dk" (round (/ n 1000.0))))
        (t (format "%.1fM" (/ n 1000000.0)))))

(defun pai--refresh-context-tokens ()
  "Re-estimate the live context size and refresh the header line.
Counts the current context messages (including the leading system prompt)
plus the tool declarations sent on every request."
  (require 'pai-compaction)
  (setq pai--context-tokens
        (pai-estimate-total-context-tokens pai--context-messages (pai-tools-all)))
  (force-mode-line-update)
  pai--context-tokens)

(defun pai--update-usage (messages)
  "Accumulate usage from MESSAGES, update the session cost, re-estimate context."
  (require 'pai-compaction)
  (dolist (m messages)
    (when (pai-assistant-message-p m)
      (setq pai--usage-total (pai-usage-add (or pai--usage-total (pai-usage))
                                            (or (plist-get m :usage) (pai-usage))))
      (unless pai--session (pai--add-message-cost m))))
  (when pai--session (pai--recompute-cost))
  (pai--refresh-context-tokens))

;;;; Session cost

(defvar-local pai--cost-total 0.0
  "Dollars spent in this session on non-local providers.")

(defvar-local pai--cost-incomplete nil
  "Non-nil when some non-local usage had no known price (cost is a lower bound).")

(defvar-local pai--unpriced-tokens '(0 . 0)
  "(INPUT . OUTPUT) tokens used in this session on local providers.")

(defun pai--message-model (message)
  "Return the model that produced assistant MESSAGE.
The registered model when known, else a minimal (:provider :id) plist the
price catalog can still look up, else the session's model."
  (let ((provider (plist-get message :provider))
        (id (plist-get message :model)))
    (if (and (stringp provider) (stringp id)
             (not (member provider '("unknown" ""))) (not (member id '("unknown" ""))))
        (or (pai-model (concat provider "/" id)) (list :provider provider :id id))
      pai--model)))

(defun pai--model-local-p (model)
  "Return non-nil when MODEL is served by a local provider (see `pai-provider-local-p')."
  (and model (pai-provider-local-p (plist-get model :provider) model)))

(defun pai--add-message-cost (message)
  "Add assistant MESSAGE's usage to the session: dollars, or tokens when local.
Every non-local provider counts in dollars -- a reported cost, else the
model's price; a free model adds $0; an unknown price marks the total as a
lower bound.  Local providers count tokens."
  (let ((u (plist-get message :usage)))
    (when u
      (let ((model (pai--message-model message)))
        (if (pai--model-local-p model)
            (let ((g (lambda (k) (or (plist-get u k) 0))))
              (setq pai--unpriced-tokens
                    (cons (+ (car pai--unpriced-tokens) (funcall g :input)
                             (funcall g :cache-read) (funcall g :cache-write))
                          (+ (cdr pai--unpriced-tokens) (funcall g :output)))))
          (unless (or (numberp (plist-get u :reported-cost))
                      (pai-model-priced-p model)
                      (pai-truthy (plist-get model :free))
                      (= 0 (+ (or (plist-get u :input) 0) (or (plist-get u :output) 0))))
            (setq pai--cost-incomplete t))
          (setq pai--cost-total (+ pai--cost-total (pai-usage-cost u model))))))))

(defun pai--recompute-cost ()
  "Recompute the session cost from every assistant message in its file.
All branches count: abandoned ones were spent too.  Each message is priced
with the model that produced it."
  (setq pai--cost-total 0.0 pai--unpriced-tokens (cons 0 0) pai--cost-incomplete nil)
  (when pai--session
    (dolist (e (pai-session-entries pai--session))
      (when (equal (plist-get e :type) "message")
        (let ((m (pai-session--entry-to-message e)))
          (when (and m (pai-assistant-message-p m))
            (pai--add-message-cost m)))))))

(defun pai-recompute-costs ()
  "Recompute the cost shown in every pai buffer (after prices changed)."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'pai-mode)
        (pai--recompute-cost)
        (force-mode-line-update)))))

(add-hook 'pai-pricing-updated-hook #'pai-recompute-costs)

(defun pai--format-dollars (amount)
  "Format AMOUNT as dollars rounded up to the cent, e.g. $0.01 for $0.0003.
Rounding up means any spend at all shows as at least a cent."
  (let ((cents (fceiling (- (* amount 100) 1e-9))))  ; epsilon: $0.05 stays $0.05
    (format "$%.2f" (if (> cents 0) (/ cents 100) 0.0))))

(defun pai--cost-text ()
  "Return the header's spend text.
Dollars for every non-local provider -- for a subscription that is the
API-equivalent price, as Claude Code shows; \"≥\" when some usage had no
known price -- and \"tok ↑IN ↓OUT\" for local providers."
  (let* ((in (car pai--unpriced-tokens))
         (out (cdr pai--unpriced-tokens))
         (tokens (and (> (+ in out) 0)
                      (format "tok ↑%s ↓%s" (pai--format-tokens in) (pai--format-tokens out))))
         (dollars (and (or (> pai--cost-total 0) pai--cost-incomplete
                           (not (or tokens (pai--model-local-p pai--model))))
                       (concat (if pai--cost-incomplete "≥" "")
                               (pai--format-dollars pai--cost-total)))))
    (cond ((and dollars tokens) (concat dollars " + " tokens))
          (dollars dollars)
          (tokens tokens)
          (t "tok ↑0 ↓0"))))

(defun pai--header-line ()
  "Return the header-line string with model, context usage, cost, and statuses.
The busy spinner comes first, so it stays visible in a narrow window; when
idle its cell holds a space, so nothing shifts as work starts and stops."
  (let* ((win (or (and pai--model (plist-get pai--model :context-window)) 0))
         (ctx pai--context-tokens)
         (pct (if (> win 0) (round (* 100.0 (/ (float ctx) win))) 0))
         (level (if pai--reasoning (symbol-name pai--reasoning) "off"))
         (statuses (mapconcat #'cdr pai--ext-statuses "  ")))
    (concat
     (or (pai--spinner-frame) " ")
     (when pai--ext-header (concat " " pai--ext-header " "))
     (format " pai  %s • %s  ctx %s/%s (%d%%)  %s%s  [%s]"
             (if pai--model (pai-model-key pai--model) "?")
             level (pai--format-tokens ctx) (pai--format-tokens win) pct (pai--cost-text)
             (if pai--usage-summary (concat "  " pai--usage-summary) "")
             (or pai--working-message pai--status))
     (when (and statuses (not (string-empty-p statuses))) (concat "  " statuses)))))

(defun pai--schedule-usage-refresh (&optional force)
  "Refresh the active provider's usage summary in the background.
The fetch is asynchronous and its result is shared by every pai buffer
\(see `pai-usage-refresh'), so calling this often costs nothing: the
provider is asked at most every `pai-usage-ttl' seconds.  With FORCE,
skip that wait (but never a rate-limit backoff)."
  (when (and pai--model (fboundp 'pai-usage-provider-p))
    (let ((provider (pai-model-provider pai--model)))
      (when (and provider (pai-usage-provider-p provider))
        (pai-usage-refresh provider force
                           (lambda (_state) (pai--show-usage provider)))))))

(defun pai--show-usage (provider)
  "Show PROVIDER's cached usage summary in every pai buffer using it."
  (let ((summary (pai-usage-summary provider)))
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and (derived-mode-p 'pai-mode) pai--model
                   (equal (pai-model-provider pai--model) provider))
          ;; Compare with properties: the same numbers turning stale only
          ;; change their face.
          (unless (equal-including-properties pai--usage-summary summary)
            (setq pai--usage-summary summary)
            (force-mode-line-update)))))))

(defun pai--mode-line ()
  "Return the footer text: extension widgets and the extension footer.
This is the \"bottom info\"; `pai-footer-position' decides where it shows."
  (let ((widgets (mapconcat #'cdr pai--widgets "  ")))
    (string-join (delq nil (list (and widgets (not (string-empty-p widgets)) widgets)
                                 pai--ext-footer))
                 "  ")))

;;;; Footer placement: mode line or above the prompt

(defface pai-footer-face '((t :inherit font-lock-comment-face))
  "Face of the footer when it is shown above the prompt."
  :group 'pai)

(defconst pai-footer-positions '("mode-line" "above-prompt")
  "Where the footer (widgets and extension footer) can be shown.")

(defconst pai--footer-overlay-priority 1000
  "Priority of the above-prompt footer overlay.
When several overlays put a `before-string' at the prompt, the one with the
higher priority is drawn closer to the prompt; this keeps the footer on the
line right above it, below activity and subagent blocks.")

(defvar-local pai--footer-overlay nil
  "Overlay showing the footer above the prompt, when placed there.")

(defun pai-footer-position ()
  "Return where the footer shows: `mode-line' (default) or `above-prompt'.
Set with the `:footer-position' setting (/menu -> Session -> Output)."
  (if (equal (format "%s" (pai-settings-get :footer-position)) "above-prompt")
      'above-prompt
    'mode-line))

(defun pai--mode-line-escape (text)
  "Return TEXT with `%' doubled, so a mode/header line shows it literally.
The result of an `:eval' in `mode-line-format' or `header-line-format' is
itself a mode-line construct, where `%' starts a directive: an unescaped
\"(33%)\" would render as \"(33\".  Text properties are kept."
  (if (and text (string-search "%" text))
      (replace-regexp-in-string "%" "%%" text t t)
    text))

(defun pai--header-line-segment ()
  "Return the header line text, escaped for `header-line-format'."
  (pai--mode-line-escape (pai--header-line)))

(defun pai--mode-line-segment ()
  "Return the footer for the mode line, or \"\" when it shows above the prompt."
  (if (eq (pai-footer-position) 'mode-line)
      (pai--mode-line-escape (concat " " (pai--mode-line)))
    ""))

(defun pai--prompt-start ()
  "Return the position where the prompt string begins, or nil."
  (when (and (markerp pai--input-marker) (marker-buffer pai--input-marker))
    (max (point-min) (- (marker-position pai--input-marker) (length pai-prompt-string)))))

(defvar-local pai--panels nil
  "Extension panels shown above the prompt: alist KEY -> TEXT, oldest first.")

(defun pai--set-panel (key text)
  "Show TEXT (a string, may span lines) above the prompt as panel KEY.
Nil or empty TEXT removes it.  Panels sit above the footer, in the order
they were first set; each keeps its own faces."
  (if (and text (not (string-empty-p text)))
      (if (assoc key pai--panels)
          (setcdr (assoc key pai--panels) text)
        (setq pai--panels (append pai--panels (list (cons key text)))))
    (setq pai--panels (assoc-delete-all key pai--panels)))
  (pai--refresh-footer))

(defun pai--render-footer ()
  "Show or hide what sits above the prompt: extension panels, then the footer
when `pai-footer-position' puts it there."
  (let* ((footer (and (eq (pai-footer-position) 'above-prompt) (pai--mode-line)))
         (footer (and footer (not (string-empty-p footer))
                      (propertize footer 'face 'pai-footer-face)))
         (parts (delq nil (append (mapcar (lambda (p) (string-trim-right (cdr p) "\n+"))
                                          pai--panels)
                                  (list footer))))
         (text (and parts (mapconcat #'identity parts "\n")))
         (pos (pai--prompt-start)))
    (if (and text (not (string-empty-p text)) pos)
        (progn
          (unless (overlayp pai--footer-overlay)
            (setq pai--footer-overlay (make-overlay pos pos nil t nil))
            (overlay-put pai--footer-overlay 'pai-footer t)
            (overlay-put pai--footer-overlay 'priority pai--footer-overlay-priority))
          (move-overlay pai--footer-overlay pos pos)
          (overlay-put pai--footer-overlay 'before-string (concat text "\n")))
      (when (overlayp pai--footer-overlay)
        (delete-overlay pai--footer-overlay))
      (setq pai--footer-overlay nil))))

(defun pai--refresh-footer ()
  "Redraw the footer wherever it is placed."
  (pai--render-footer)
  (force-mode-line-update))

(defun pai-refresh-footers ()
  "Redraw the footer in every pai buffer (after the placement setting changed)."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'pai-mode)
        (pai--refresh-footer)))))

(add-hook 'pai-settings-changed-hook #'pai-refresh-footers)

;;;; Extension UI setters

(defun pai--set-ext-status (key text)
  "Set extension status KEY to TEXT (nil removes it) and refresh the header."
  (setq pai--ext-statuses (assoc-delete-all key pai--ext-statuses))
  (when (and text (not (string-empty-p text)))
    (push (cons key text) pai--ext-statuses))
  (force-mode-line-update))

(defun pai--set-widget (key content)
  "Set extension widget KEY to CONTENT (a string or list of strings; nil removes)."
  (setq pai--widgets (assoc-delete-all key pai--widgets))
  (when content
    (push (cons key (if (listp content) (string-join content " ") content)) pai--widgets))
  (pai--refresh-footer))

;;;; Input handling

(defun pai--input-text ()
  "Return the current input text (trimmed)."
  (when (and pai--input-marker (marker-buffer pai--input-marker))
    (string-trim (buffer-substring-no-properties pai--input-marker (point-max)))))

(defun pai--clear-input ()
  "Delete the current input region."
  (let ((inhibit-read-only t))
    (delete-region pai--input-marker (point-max))))

(defun pai--compaction-shape (messages new)
  "Return (SYSTEM-COUNT . KEPT-COUNT) for compaction result NEW of MESSAGES, or nil.
NEW must be MESSAGES' leading system messages, one summary message, and a kept
tail no longer than the rest of MESSAGES; anything else is rejected."
  (let* ((system (seq-take-while #'pai-system-message-p messages))
         (n-sys (length system))
         (kept (- (length new) n-sys 1)))
    (when (and (>= kept 0)
               (<= kept (- (length messages) n-sys))
               (equal (seq-take new n-sys) system)
               (let ((summary (nth n-sys new)))
                 (and summary (not (pai-system-message-p summary)))))
      (cons n-sys kept))))

(defun pai--compact-by-extension (custom-instructions reason model)
  "Return the first valid `compact' extension result for the live context, or nil.
An invalid result is reported and ignored, so the built-in compaction runs."
  (let ((result (pai-ext-run-compact pai--context-messages (pai--ext-context)
                                     :reason reason :model model
                                     :custom-instructions custom-instructions)))
    (cond ((null result) nil)
          ((pai--compaction-shape pai--context-messages (plist-get result :messages))
           result)
          (t (message "pai: ignoring malformed compaction from extension (%s)"
                      (or (plist-get result :strategy) "unnamed"))
             nil))))

(defun pai--compaction-entry (result messages)
  "Return the session entry recording compaction RESULT of MESSAGES.
The entry is replayable -- carrying :firstKeptEntryId and :summaryMessage --
when the kept tail maps back to session entries; see
`pai-session-context-messages'."
  (let* ((new (plist-get result :messages))
         (shape (pai--compaction-shape messages new))
         (first-kept (and shape
                          (or (plist-get result :first-kept-entry-id)
                              (pai-session-first-kept-entry-id pai--session (cdr shape))))))
    (append (list :type "compaction"
                  :strategy (or (plist-get result :strategy) "summary")
                  :summary (or (plist-get result :summary) "")
                  :tokensBefore (or (plist-get result :tokens-before)
                                    (pai-estimate-context-tokens messages)))
            (when first-kept
              (list :firstKeptEntryId first-kept
                    :summaryMessage (nth (car shape) new))))))

(defface pai-compaction-bar-face '((t :inherit success))
  "Face of the filled part of the compaction progress bar.")

(defcustom pai-compaction-progress-interval 0.2
  "Seconds between redraws of the compaction progress indicator."
  :type 'number :group 'pai)

(defun pai--compaction-bar (fraction &optional width)
  "Return a WIDTH-cell progress bar filled to FRACTION (0-1)."
  (let* ((width (or width 12))
         (filled (min width (max 0 (round (* width fraction))))))
    (concat (propertize (make-string filled ?▰) 'face 'pai-compaction-bar-face)
            (make-string (- width filled) ?▱))))

(defun pai--compaction-detail (state)
  "Return the one-line progress text for compaction STATE."
  (let ((tokens (round (/ (plist-get state :chars) 4.0)))
        (limit pai-compaction-summary-max-tokens))
    (if (<= tokens 0)
        (format "%s · waiting for the model" (plist-get state :what))
      (format "%s · %s %s/%s tokens"
              (plist-get state :what)
              (pai--compaction-bar (/ (float tokens) limit))
              (pai-activity-fmt-count tokens) (pai-activity-fmt-count limit)))))

(defun pai--compaction-tick (buffer entry state)
  "Redraw compaction progress for ENTRY/STATE in BUFFER.
Compaction blocks Emacs; timers still fire inside the blocking wait, but
nothing is redrawn unless asked, so this forces a redisplay."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((detail (pai--compaction-detail state)))
        (plist-put entry :stream-chars (plist-get state :chars))
        (pai-activity-update entry :detail detail)
        (let ((message-log-max nil))
          (message "pai: compacting context %s · %s"
                   (pai-activity-fmt-duration (pai-activity-elapsed entry)) detail))
        (redisplay t)))))

(defun pai--compact-now (custom-instructions &optional reason)
  "Compact the live context now with optional CUSTOM-INSTRUCTIONS.  Return non-nil on success.
REASON is `manual' (default) or `auto'.  An extension `compact' handler may
take over; otherwise the built-in LLM summary (`pai-compact') is used.

Compaction blocks Emacs until it finishes, so it is made visible: a note in
the transcript, the header status, a live line above the prompt and the echo
area show elapsed time and how much of the summary has been written.  C-g
aborts it safely, leaving the context unchanged."
  (require 'pai-compaction)
  (let* ((model (or (ignore-errors (pai-scoped-model :compact pai--model)) pai--model))
         (reason (or reason 'manual))
         (messages pai--context-messages)
         (before (length messages))
         (buffer (current-buffer))
         (state (list :chars 0
                      :what (format "%d messages, ~%s tokens" before
                                    (pai-activity-fmt-count
                                     (pai-estimate-context-tokens messages)))))
         (entry nil) (timer nil) (outcome "failed"))
    (unless model (user-error "No compact model selected; use /model first"))
    (pai-ext-emit 'session-before-compact (pai--ext-context) :reason reason)
    (pai--render-note
     (format "Compacting context (%s): %s.  Emacs is busy until it finishes; C-g aborts."
             reason (plist-get state :what)))
    (pai--set-status "compacting…")
    (setq entry (pai-activity-start :prefix "cmp" :kind "compaction" :glyph "🗜"
                                    :label (format "compact·%s" reason)
                                    :detail (pai--compaction-detail state)))
    (pai--compaction-tick buffer entry state)
    (setq timer (run-at-time pai-compaction-progress-interval pai-compaction-progress-interval
                             #'pai--compaction-tick buffer entry state))
    (unwind-protect
        (let* ((pai-compaction-progress-function
                (lambda (delta)
                  (plist-put state :chars (+ (plist-get state :chars) (length delta)))))
               (result (or (pai--compact-by-extension custom-instructions reason model)
                           (pai-compact messages model custom-instructions)))
               (strategy (and result (or (plist-get result :strategy) "summary")))
               (took (pai-activity-fmt-duration (pai-activity-elapsed entry))))
          (setq outcome "completed")
          (prog1 (and result t)
            (if result
                (progn
                  (setq pai--context-messages (plist-get result :messages))
                  (pai--refresh-context-tokens)
                  (when pai--session
                    (pai-session-append pai--session (pai--compaction-entry result messages)))
                  (pai-ext-emit 'session-compact (pai--ext-context)
                                :reason reason :strategy strategy)
                  (pai--render-note (format "Compacted context%s (%d → %d messages) in %s."
                                            (if (equal strategy "summary") ""
                                              (format " [%s]" strategy))
                                            before (length pai--context-messages) took))
                  (message "pai: context compacted in %s (%d → %d messages)"
                           took before (length pai--context-messages)))
              (pai--render-note "Nothing to compact.")
              (message "pai: nothing to compact"))))
      (cancel-timer timer)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (pai-activity-finish entry outcome)
          (unless (equal outcome "completed")
            (pai--render-note "Compaction aborted; the context is unchanged." 'pai-error-face))
          (pai--set-status "idle"))))))

(defun pai-compact-command (args ctx)
  "Handler for `/compact': summarize and shrink the live context."
  (let ((buf (plist-get ctx :buffer)))
    (if (buffer-live-p buf)
        (progn (with-current-buffer buf (pai--compact-now (string-trim args))) nil)
      (list :message "No active pai session to compact"))))

(pai-register-command "compact"
                      :description "Summarize and shrink the conversation context"
                      :handler #'pai-compact-command)

;;;; Session management commands

(defun pai--render-message (m)
  "Render message M into the transcript (used when rebuilding)."
  (pcase (pai-message-role m)
    ('user (pai--render-user m))
    ('assistant
     (setq pai--assistant-open nil)
     (pai--open-assistant)
     (pai--insert-assistant-blocks m)
     (pai--ensure-fresh-line)
     (setq pai--assistant-open nil pai--assistant-content-start nil)
     (dolist (tc (pai-message-tool-calls m))
       (pai--render-tool-start (list :tool-call-id (plist-get tc :id)
                                     :tool-name (plist-get tc :name)
                                     :args (plist-get tc :arguments)))))
    ('tool-result
     (pai--render-tool-end (list :result m :is-error (plist-get m :is-error)
                                 :tool-call-id (plist-get m :tool-call-id)
                                 :tool-name (plist-get m :tool-name))))
    (_ nil)))

(defun pai--rebuild-transcript ()
  "Clear and re-render the transcript from the live context."
  (pai--init-buffer)
  (setq pai--assistant-open nil)
  (dolist (m pai--context-messages)
    (unless (pai-system-message-p m) (pai--render-message m)))
  (goto-char (point-max)))

(defun pai-name-command (args ctx)
  "Handler for `/name': show or set the session display name."
  (let ((buf (plist-get ctx :buffer)) (name (string-trim args)))
    (if (buffer-live-p buf)
        (with-current-buffer buf
          (if (string-empty-p name)
              (list :message (format "Session name: %s"
                                     (or (and pai--session (pai-session-name pai--session)) "(unnamed)")))
            (when pai--session (pai-session-set-name pai--session name))
            (pai-ext-emit 'session-info-changed (pai--ext-context) :name name)
            (list :message (format "Session named: %s" name))))
      (list :message "No active session"))))

(defun pai-session-info-command (_args ctx)
  "Handler for `/session': show session statistics."
  (let ((buf (plist-get ctx :buffer)))
    (if (buffer-live-p buf)
        (with-current-buffer buf
          (let* ((msgs pai--context-messages)
                 (users (seq-count #'pai-user-message-p msgs))
                 (assts (seq-count #'pai-assistant-message-p msgs))
                 (cost (pai--cost-text)))
            (list :message
                  (format "Session %s%s\nFile: %s\nMessages: %d (user %d, assistant %d)\nContext tokens: %d\nCost: %s"
                          (if pai--session (pai-session-id pai--session) "?")
                          (if (and pai--session (pai-session-name pai--session))
                              (format " — %s" (pai-session-name pai--session)) "")
                          (or (and pai--session (pai-session-file pai--session)) "(memory)")
                          (length msgs) users assts pai--context-tokens cost))))
      (list :message "No active session"))))

(defun pai-new-command (_args ctx)
  "Handler for `/new': start a fresh session in this buffer."
  (let ((buf (plist-get ctx :buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (pai-ext-emit 'session-shutdown (pai--ext-context) :reason 'new)
        (pai--setup default-directory)
        (pai-ext-emit 'session-start (pai--ext-context) :reason 'new)
        (pai--render-note "Started a new session")))
    nil))

(defconst pai--session-preview-width 80
  "Maximum width of the first-message preview shown by `/resume'.")

(defun pai--session-preview (file)
  "Return a one-line preview of the first user message in session FILE."
  (let ((text (ignore-errors (pai-session-first-user-text file))))
    (if (or (null text) (string-blank-p text))
        ""
      (truncate-string-to-width
       (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " text))
       pai--session-preview-width nil nil "…"))))

(defun pai--session-choices (dir)
  "Return an alist of (LABEL . FILE) for saved sessions under DIR.
Each label shows the modification time and a preview of the first user
message; identical labels are disambiguated with a \" <N>\" suffix."
  (let ((seen (make-hash-table :test 'equal)))
    (mapcar (lambda (f)
              (let* ((base (string-trim-right
                            (format "%s  %s"
                                    (format-time-string "%Y-%m-%d %H:%M"
                                                        (nth 5 (file-attributes f)))
                                    (pai--session-preview f))))
                     (n (puthash base (1+ (gethash base seen 0)) seen)))
                (cons (if (> n 1) (format "%s <%d>" base n) base) f)))
            (pai-session-list dir))))

(defun pai-resume-command (_args ctx)
  "Handler for `/resume': load a previous session into this buffer."
  (let ((buf (plist-get ctx :buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let* ((choices (pai--session-choices default-directory))
               (label (and choices
                           (pai-completing-read-preview "Resume session: " choices
                                                        #'pai-preview-session-file
                                                        nil nil :preview-resume)))
               (file (cdr (assoc label choices))))
          (if (not file)
              (pai--render-note "No session selected")
            (pai-ext-emit 'session-before-switch (pai--ext-context) :reason 'resume)
            (let ((loaded (pai-session-load file)))
              (setq pai--session loaded
                    pai--context-messages (pai-session-context-messages loaded)
                    pai--usage-total (pai-usage))
              (pai--rebuild-transcript)
              (pai--update-usage nil)   ; recomputes the cost from the file
              (unless noninteractive (pai-pricing-refresh))   ; if stale
              (pai-ext-emit 'session-start (pai--ext-context) :reason 'resume)
              (pai--render-note (let ((preview (pai--session-preview file)))
                                  (if (string-empty-p preview)
                                      "Resumed session"
                                    (format "Resumed session: %s" preview)))))))))
    nil))

(defun pai--open-forked-buffer (fork &optional initial-input)
  "Open a NEW buffer showing forked session FORK; return the buffer.
INITIAL-INPUT, when non-empty, is inserted at the prompt for editing."
  (let ((buf (generate-new-buffer (pai--buffer-name (pai-session-cwd fork)))))
    (with-current-buffer buf
      (pai--setup (pai-session-cwd fork) fork)
      (when (and initial-input (not (string-empty-p initial-input)))
        (goto-char (point-max))
        (insert initial-input)))
    (pop-to-buffer buf)
    (with-current-buffer buf (goto-char (point-max)))
    buf))

(defun pai-fork-command (_args ctx)
  "Handler for `/fork': branch from before a chosen prompt into a NEW buffer.
The new buffer's context is everything up to (but excluding) the selected
prompt, which is pre-filled at the input so you can re-ask it differently.
The original buffer is left untouched."
  (let ((buf (plist-get ctx :buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let* ((prompts (and pai--session (pai-session-user-prompts pai--session)))
               (label (and prompts (completing-read "Fork before prompt: "
                                                    (mapcar #'cdr prompts) nil t)))
               (entry (car (seq-filter (lambda (p) (equal (cdr p) label)) prompts))))
          (if (not entry)
              (pai--render-note "No prompt selected")
            (let* ((parent (pai-session-entry-parent-id pai--session (car entry)))
                   (fork (pai-session-fork pai--session parent)))
              ;; Render the note in the original buffer BEFORE opening the new
              ;; one, since opening pops to (and makes current) the new buffer.
              (pai--render-note
               (format "Forked into a new buffer before: %s"
                       (truncate-string-to-width (cdr entry) 48 nil nil "…")))
              (pai--open-forked-buffer fork (cdr entry)))))))
    nil))

(defun pai-clone-command (_args ctx)
  "Handler for `/clone': duplicate the current session into a NEW buffer."
  (let ((buf (plist-get ctx :buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when pai--session
          (let ((fork (pai-session-fork pai--session
                                        (pai-session-leaf-id pai--session))))
            (pai--render-note "Cloned the session into a new buffer")
            (pai--open-forked-buffer fork))))))
  nil)

(defun pai--tree-line (item)
  "Return the display line for prompt-outline ITEM.
`*' marks prompts on the current branch.  Side branches are indented under
the prompt they forked from, opening with `└─'; the rest of a side branch
lines up with its first prompt."
  (let ((indent (plist-get item :indent)))
    (format "%s %s%s"
            (if (plist-get item :on-branch) "*" " ")
            (concat (make-string (* 3 (max 0 (1- indent))) ?\s)
                    (cond ((= indent 0) "")
                          ((plist-get item :fork) "└─ ")
                          (t "   ")))
            (truncate-string-to-width
             (replace-regexp-in-string "[ \t\n]+" " " (string-trim (plist-get item :text)))
             70 nil nil "…"))))

(defun pai--tree-choices (outline)
  "Return an alist of (DISPLAY . ENTRY-ID) from prompt OUTLINE, in order.
Colliding displays get the entry id appended so candidates stay unique."
  (let ((raw (mapcar (lambda (it) (cons (plist-get it :id) (pai--tree-line it))) outline))
        (counts (make-hash-table :test 'equal))
        (out '()))
    (dolist (r raw) (cl-incf (gethash (cdr r) counts 0)))
    (dolist (r raw)
      (let ((disp (cdr r)))
        (when (> (gethash disp counts) 1)
          (setq disp (format "%s  (%s)" disp (car r))))
        (push (cons disp (car r)) out)))
    (nreverse out)))

(defun pai--ordered-completion-table (candidates)
  "Return a completion table for CANDIDATES that keeps their order.
Completion UIs (Vertico, Ivy, the default) re-sort candidates; a tree must
stay in tree order."
  (lambda (string pred action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action candidates string pred))))

(defun pai--prompt-position (ts &optional text)
  "Return the start of the rendered prompt with message timestamp TS, or nil.
Prompts rendered before they were tagged with their timestamp are found
by TEXT, the prompt's text: the last untagged \"▶ You\" header followed
by the same first line."
  (save-excursion
    (or (and ts
             (progn
               (goto-char (point-min))
               (let ((m (text-property-search-forward 'pai-prompt-ts ts #'equal)))
                 ;; the header starts with a blank line: land on "▶ You"
                 (and m (let ((pos (prop-match-beginning m)))
                          (if (eq (char-after pos) ?\n) (1+ pos) pos))))))
        (and text
             (let* ((first (string-trim (car (split-string (string-trim text) "\n"))))
                    (key (substring first 0 (min 80 (length first))))
                    (found nil))
               (unless (string-empty-p key)
                 (goto-char (point-min))
                 (while (search-forward "▶ You\n" nil t)
                   (let ((beg (match-beginning 0)))
                     (when (and (eq (get-text-property beg 'face) 'pai-user-face)
                                (not (get-text-property beg 'pai-prompt-ts))
                                (string-prefix-p key (buffer-substring-no-properties
                                                      (point) (min (point-max) (+ (point) (length key))))))
                       (setq found beg)))))
               found)))))

(defun pai--entry-timestamp (entry-id)
  "Return the message timestamp of session entry ENTRY-ID, or nil."
  (and pai--session
       (plist-get (plist-get (gethash entry-id (pai-session-by-id pai--session)) :message)
                  :timestamp)))

(defun pai--entry-prompt-position (entry-id)
  "Return where the prompt of session entry ENTRY-ID is rendered, or nil."
  (and pai--session
       (let ((m (plist-get (gethash entry-id (pai-session-by-id pai--session)) :message)))
         (pai--prompt-position (plist-get m :timestamp)
                               (ignore-errors (pai-content-text (plist-get m :content)))))))

(defface pai-tree-point-face
  '((t :inherit highlight :extend t))
  "Face of the line /tree shows where the next prompt would go."
  :group 'pai)

(defvar-local pai--tree-highlight nil
  "Overlay marking where the next prompt would go at the /tree point previewed.")

(defun pai--turn-end-position (prompt-pos)
  "Return where the turn whose prompt header is at PROMPT-POS ends.
That is the blank line before the next \"▶ You\" header, or the end of the
transcript: where the next prompt would go after jumping there."
  (save-excursion
    (goto-char prompt-pos)
    (forward-line 1)
    (let ((found nil))
      (while (and (not found) (search-forward "▶ You\n" nil t))
        (when (eq (get-text-property (match-beginning 0) 'face) 'pai-user-face)
          (setq found (match-beginning 0))))
      (let ((end (if found
                     ;; the header was inserted as "\n▶ You\n": stop before its blank line
                     (if (eq (char-before found) ?\n) (1- found) found)
                   (marker-position pai--output-marker))))
        ;; step back over blank lines and status notes (— ready —), so the
        ;; marker sits right below the answer's last line
        (goto-char end)
        (let ((floor (save-excursion (goto-char prompt-pos) (line-end-position 2)))
              (done nil))
          (while (not done)
            (skip-chars-backward "\n" floor)
            (if (and (> (point) floor)
                     (let ((f (get-text-property (line-beginning-position) 'face)))
                       (or (eq f 'pai-note-face) (and (listp f) (memq 'pai-note-face f)))))
                (goto-char (line-beginning-position))
              (setq done t))))
        (min end (1+ (point)))))))

(defun pai--tree-show-turn-end (pos)
  "Scroll to POS, the end of a turn, and mark it as where the next prompt goes.
Return non-nil when a window of this buffer shows it."
  (let ((wins (seq-remove (lambda (w) (window-minibuffer-p w))
                          (get-buffer-window-list (current-buffer) nil t))))
    (when wins
      (unless (overlayp pai--tree-highlight)
        (setq pai--tree-highlight (make-overlay pos pos))
        (overlay-put pai--tree-highlight 'priority 100))
      (move-overlay pai--tree-highlight pos pos)
      (overlay-put pai--tree-highlight 'before-string
                   (propertize "▶ your next prompt goes here\n" 'face 'pai-tree-point-face))
      (dolist (w wins)
        (set-window-point w pos)
        ;; the answer above, the marker near the bottom
        (with-selected-window w (ignore-errors (recenter -4))))
      t)))

(defun pai--tree-preview (entry-id)
  "Preview /tree point ENTRY-ID: where its turn ends, in place or aside.
When the prompt is on the branch shown, the transcript scrolls to the end
of its turn (the last agent message) and marks where the next prompt
would go; otherwise the preview window shows the conversation up to the
end of that turn."
  (let* ((prompt (pai--entry-prompt-position entry-id))
         (pos (and prompt (pai--turn-end-position prompt))))
    (if (and pos (pai--tree-show-turn-end pos))
        (pai-preview-close)
      (when (overlayp pai--tree-highlight) (delete-overlay pai--tree-highlight)
            (setq pai--tree-highlight nil))
      (pai-preview-messages
       "Point in the tree (not on the branch shown)"
       (pai-session-context-messages pai--session
                                     (pai-session-turn-leaf pai--session entry-id))))))

(defun pai--tree-preview-cleanup (buf windows)
  "Undo /tree previews in BUF, restoring WINDOWS: ((WIN START . POINT) ...)."
  (pai-preview-close)
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (overlayp pai--tree-highlight) (delete-overlay pai--tree-highlight))
      (setq pai--tree-highlight nil)))
  (dolist (w windows)
    (when (and (window-live-p (car w)) (eq (window-buffer (car w)) buf))
      (set-window-start (car w) (cadr w) t)
      (set-window-point (car w) (cddr w)))))

(defun pai-tree-command (_args ctx)
  "Handler for `/tree': jump to any point in the session tree, in place.
Shows every user prompt as a tree: the current branch (marked `*') runs down
one column and each branch you left is indented under the prompt it split
from, so you can rewind AND return to a branch you left.  Jumping lands at
the END of the chosen turn, keeping that turn's answer in context; the next
message you send continues from there.
While choosing (with the preview on), the transcript scrolls to the end of
the turn at point in the list and marks where the next prompt would go (a
turn on another branch is shown in a side window).  After the jump, point
is at the input, right below that turn's last agent message."
  (let ((buf (plist-get ctx :buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let* ((branch (and pai--session
                            (mapcar (lambda (e) (plist-get e :id))
                                    (pai-session-get-branch pai--session))))
               (outline (and pai--session (pai-session-prompt-outline pai--session branch)))
               (choices (pai--tree-choices outline))
               (windows (mapcar (lambda (w) (cons w (cons (window-start w) (window-point w))))
                                (get-buffer-window-list buf nil t)))
               (label (and choices
                           (pai-completing-read-preview
                            "Go to point in tree: " choices #'pai--tree-preview
                            (pai--ordered-completion-table (mapcar #'car choices))
                            (lambda () (pai--tree-preview-cleanup buf windows))
                            :preview-tree)))
               (entry-id (cdr (assoc label choices))))
          (if (not entry-id)
              (pai--render-note "No point selected")
            (pai-session-branch pai--session
                                (pai-session-turn-leaf pai--session entry-id))
            (setq pai--context-messages (pai-session-context-messages pai--session))
            (pai--refresh-context-tokens)
            (pai--rebuild-transcript)
            (pai-ext-emit 'session-tree (pai--ext-context) :new-leaf-id entry-id)
            (pai--render-note "Moved to the selected point in the tree")
            ;; at the input, right below the turn's last agent message
            (goto-char (point-max))
            (dolist (w (get-buffer-window-list buf nil t))
              (set-window-point w (point-max))
              (with-selected-window w (ignore-errors (recenter -1))))))))
    nil))

(pai-register-command "name" :description "Show or set the session name" :handler #'pai-name-command)
(pai-register-command "session" :description "Show session statistics" :handler #'pai-session-info-command)
(pai-register-command "new" :description "Start a new session" :handler #'pai-new-command)
(pai-register-command "resume" :description "Resume a previous session" :handler #'pai-resume-command)
(pai-register-command "fork" :description "Fork from an earlier prompt into a new buffer" :handler #'pai-fork-command)
(pai-register-command "clone" :description "Duplicate the session into a new buffer" :handler #'pai-clone-command)
(pai-register-command "tree" :description "Jump to any point in the session tree" :handler #'pai-tree-command)

;;;; /prices

(defun pai--format-age (seconds)
  "Format SECONDS as a short age, e.g. 5m, 3h, 2d."
  (cond ((< seconds 90) "just now")
        ((< seconds 5400) (format "%dm ago" (round (/ seconds 60))))
        ((< seconds 129600) (format "%dh ago" (round (/ seconds 3600))))
        (t (format "%dd ago" (round (/ seconds 86400))))))

(defun pai--model-price-text (model)
  "Return a line describing MODEL's price and where it comes from."
  (let* ((key (pai-model-key model))
         (own (plist-get model :cost))
         (rates (pai-model-rates model))
         (m (lambda (k) (or (plist-get rates k) 0.0))))
    (cond ((pai--model-local-p model) (format "%s: local, counted in tokens" key))
          ((pai-truthy (plist-get model :free)) (format "%s: free (listed at $0)" key))
          ((null rates) (format "%s: price unknown (cost shown as a lower bound, ≥)" key))
          (t (format "%s: $%s in / $%s out / $%s cache read / $%s cache write per M tokens (%s)"
                     key
                     (number-to-string (funcall m :input)) (number-to-string (funcall m :output))
                     (number-to-string (funcall m :cache-read))
                     (number-to-string (funcall m :cache-write))
                     (if (pai-model-rates-nonzero-p own) "provider" "models.dev"))))))

(defun pai-prices-command (args ctx)
  "Handler for `/prices [refresh]': show or refresh model prices.
Without arguments show the catalog's state and the session model's price;
`refresh' downloads the catalog now, and every pai buffer is repriced when
it arrives."
  (let ((buf (plist-get ctx :buffer))
        (arg (string-trim (or args ""))))
    (if (not (buffer-live-p buf))
        (list :message "No active pai buffer")
      (with-current-buffer buf
        (pcase arg
          ("refresh"
           (cond ((not pai-pricing-url)
                  (list :message "Price downloads are off (pai-pricing-url is nil)"))
                 ((pai-pricing-downloading-p)
                  (list :message "The price catalog is already downloading"))
                 ((not (executable-find pai-curl-program))
                  (list :message (format "Cannot download prices: %s not found" pai-curl-program)))
                 (t (pai-pricing-refresh t)
                    (list :message "Downloading the price catalog; costs update when it arrives"))))
          ("" (let ((age (pai-pricing-cache-age))
                    (n (hash-table-count (pai-pricing-load))))
                (list :message
                      (concat
                       (format "Price catalog: %d prices, %s%s\n"
                               n (if age (concat "updated " (pai--format-age age)) "never downloaded")
                               (if (pai-pricing-downloading-p) " (downloading now)" ""))
                       (format "Source: %s; refreshed when older than %dh, on session start, /resume and /reload\n"
                               (or pai-pricing-url "downloads off")
                               (round (/ pai-pricing-max-age 3600.0)))
                       "OpenRouter prices come from its model list (/model refreshes them)\n"
                       (if pai--model (pai--model-price-text pai--model) "No model selected")
                       (format "\nSession cost: %s" (pai--cost-text))))))
          (_ (list :message "Usage: /prices [refresh]")))))))

(pai-register-command "prices" :description "Show or refresh model prices"
                      :handler #'pai-prices-command
                      :arg-completions (lambda (_prefix) '("refresh")))

;;;; Misc commands and programmatic API

(defun pai-clear-command (_args ctx)
  "Handler for `/clear': clear the transcript display (keeps the context)."
  (let ((buf (plist-get ctx :buffer)))
    (when (buffer-live-p buf) (with-current-buffer buf (pai--init-buffer)))
    nil))

(defun pai-quit-command (_args ctx)
  "Handler for `/quit': close the pai buffer."
  (let ((buf (plist-get ctx :buffer)))
    (when (buffer-live-p buf) (run-at-time 0 nil #'kill-buffer buf))
    (list :message "Closing pai")))

(defun pai-reload-command (_args ctx)
  "Handler for `/reload': reload changed core files, extensions, prompts, skills.
Core `pai-*.el' files edited since startup are re-loaded, multi-file extensions
are fully reloaded (including `require'd siblings), and settings/models refresh."
  (let ((buf (plist-get ctx :buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when pai--active (user-error "Interrupt the active run before reloading"))
        ;; Snapshot the conversational state that must survive a reload, so the
        ;; session continues exactly where the user left off.  Reloading only
        ;; refreshes code (core files, extensions, prompts, skills); it must not
        ;; drop the transcript, context, model, usage, or reasoning level.
        (let ((prev-model pai--model)
              (key (and pai--model (pai-model-key pai--model)))
              (prev-session pai--session)
              (prev-context pai--context-messages)
              (prev-usage pai--usage-total)
              (prev-reasoning pai--reasoning)
              (prev-trusted pai--trusted)
              (core nil))
          (pai-ext-initialize-instance)
          (use-local-map (copy-keymap pai-mode-map))
          (pai-settings-load default-directory)
          (pai-models-load-custom)
          ;; Keep the prior trust decision; only prompt if it was never made.
          (setq pai--trusted (if prev-trusted t (pai--project-trusted-p)))
          (pai-reload-forget-extension-features (pai--extension-dirs))
          ;; widgets are redrawn by the extensions still enabled (the
          ;; `reload' event below); a disabled one's widget must not linger
          (setq pai--widgets nil pai--panels nil)
          (pai--load-trusted-extensions)
          (setq core (pai-reload-changed-core-files))
          ;; Restore session state.  Re-resolve the model from its key so it
          ;; picks up edited definitions, but fall back to the previous model
          ;; object if the key no longer resolves, so the model is never lost.
          (setq pai--model (or (and key (pai-model key)) prev-model)
                pai--session prev-session
                pai--context-messages prev-context
                pai--usage-total prev-usage
                pai--reasoning prev-reasoning)
          ;; Re-apply extension shortcuts dropped by the local-map refresh.
          (pai-ext-apply-shortcuts)
          (dolist (dir (pai--prompt-dirs)) (pai-prompts-register (list dir)))
          (pai-commands-unregister-skills)
          (let ((skills (pai-discover-skills (pai--skill-dirs))))
            (pai-commands-register-skills skills)
            (pai-commands-register-bundles skills))
          ;; Re-estimate context size from the restored messages.
          (pai--update-usage nil)
          (unless noninteractive (pai-pricing-refresh))   ; if stale
          (pai-ext-emit 'reload (pai--ext-context))
          (pai--refresh-footer)
          (pai--render-note
           (if core
               (format "Reloaded %d core file(s) (%s), extensions, prompts, and skills"
                       (length core)
                       (mapconcat (lambda (f) (file-name-nondirectory f)) core ", "))
             "Reloaded extensions, prompts, and skills")))))
    nil))

(defun pai-hotkeys-command (_args _ctx)
  "Handler for `/hotkeys': list the pai keybindings."
  (list :message
        (concat "Keybindings:\n"
                "  RET        send input\n"
                "  /          slash-command completion\n"
                "  C-c /      command picker (Helm if available)\n"
                "  TAB        complete commands / @files / *buffers\n"
                "  @ / *      mention a file / a buffer by name (read on demand)\n"                "  C-c i      (in any buffer) add it, or the selected lines, to the prompt\n"
                "  C-c C-c    interrupt the run\n"
                "  C-c C-m    switch model\n"
                "  C-c C-t    set thinking level\n"
                "  C-c C-l    clear transcript\n"
                "  C-c C-s    settings menu\n"
                "  C-c C-o    go to file/buffer/URL at point (M-. or mouse-2)\n"
                "  M-p / M-n  previous / next prompt or command (project history)\n"
                "  C-c C-e    edit the prompt in its own buffer (C-c C-c commit, C-c C-k abort)\n"
                "  C-c C-n    jump to input")))

(defun pai-changelog-command (_args _ctx)
  "Handler for `/changelog': show the project changelog if present."
  (let ((file (seq-find #'file-readable-p
                        (list (expand-file-name "CHANGELOG.md" default-directory)
                              (expand-file-name "docs/STATUS.md" default-directory)))))
    (if file
        (list :message (with-temp-buffer (insert-file-contents file nil 0 4000) (buffer-string)))
      (list :message "No changelog found"))))

(defun pai-import-command (args ctx)
  "Handler for `/import': load a session from a .jsonl PATH argument."
  (let ((buf (plist-get ctx :buffer)) (path (string-trim args)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (if (or (string-empty-p path) (not (file-readable-p (expand-file-name path))))
            (pai--render-note "Usage: /import <path-to-session.jsonl>" 'pai-error-face)
          (let ((loaded (pai-session-load (expand-file-name path))))
            (setq pai--session loaded
                  pai--context-messages (pai-session-context-messages loaded)
                  pai--usage-total (pai-usage))
            (pai--rebuild-transcript)
            (pai--update-usage nil)
            (pai--render-note (format "Imported %s" (file-name-nondirectory path)))))))
    nil))

(pai-register-command "clear" :description "Clear the transcript display" :handler #'pai-clear-command)
(pai-register-command "quit" :description "Close the pai buffer" :handler #'pai-quit-command)
(pai-register-command "reload" :description "Reload extensions, prompts, and skills" :handler #'pai-reload-command)
(pai-register-command "hotkeys" :description "List keybindings" :handler #'pai-hotkeys-command)
(pai-register-command "changelog" :description "Show the changelog" :handler #'pai-changelog-command)
(pai-register-command "import" :description "Import a session from a .jsonl file" :handler #'pai-import-command)

(defun pai-send-message (text &optional buffer)
  "Programmatically submit TEXT to the pai chat in BUFFER.
BUFFER defaults to the current pai buffer, else any live `pai-mode' buffer."
  (with-current-buffer (or buffer (pai--menu-buffer) (error "No pai buffer"))
    (goto-char (point-max))
    (insert text)
    (pai-send)))

(defun pai--maybe-compact ()
  "Compact the live context between runs when it exceeds the model's window."
  (require 'pai-compaction)
  (when (and pai--model
             (pai-should-compact-p pai--context-messages (plist-get pai--model :context-window)))
    (pai--compact-now nil 'auto)))

(defun pai--start-run (text)
  "Start an agent run for user input TEXT (noting @file and *buffer mentions)."
  (unless pai--model
    (setq pai--model (pai-model (or (pai-settings-get :model) pai-default-model))))
  (unless pai--model
    (user-error "No model selected; use M-x pai-add-provider, then /model"))
  (pai-ext-emit 'before-agent-start (pai--ext-context) :prompt text)
  (pai--maybe-compact)
  (setq pai--active t)
  (setq pai--run
        (pai-agent-run (list (pai-user-message (pai--expand-mentions text)))
                       (pai-context pai--context-messages (pai-tools-all))
                       (pai--config)
                       (pai--emit-fn)
                       (lambda (_msgs) nil))))

(defun pai--run-command (text)
  "Dispatch slash-command TEXT."
  (let* ((res (pai-command-dispatch text (pai--ext-context)))
         (r (plist-get res :result)))
    (cond
     ((not (plist-get res :handled))
      (pai--render-note (format "Unknown command: /%s" (plist-get res :name)) 'pai-error-face))
     ((plist-get r :message) (pai--render-note (plist-get r :message)))
     ((plist-get r :send) (pai--start-run (plist-get r :send)))
     (t nil))))

(defun pai--run-bang (text)
  "Run a shell bang command TEXT: `!cmd' adds output to context, `!!cmd' does not."
  (let* ((exclude (string-prefix-p "!!" text))
         (cmd (string-trim (substring text (if exclude 2 1)))))
    (if (string-empty-p cmd)
        (pai--render-note "Empty shell command" 'pai-error-face)
      (pai-ext-emit 'user-bash (pai--ext-context)
                    :command cmd :exclude-from-context exclude :cwd default-directory)
      (let ((out (with-output-to-string
                   (with-current-buffer standard-output
                     (call-process shell-file-name nil t nil shell-command-switch cmd)))))
        (pai--render-note (format "$ %s\n%s" cmd (string-trim-right out)) 'pai-tool-result-face)
        (unless exclude
          (let ((m (pai-user-message
                    (format "I ran `%s` in the shell and got:\n\n```\n%s\n```"
                            cmd (string-trim-right out)))))
            (setq pai--context-messages (append pai--context-messages (list m)))
            (when pai--session (pai-session-append-message pai--session m))))))))

(defun pai-send (&optional record)
  "Submit the current input line.
With RECORD (always set when called interactively), add the input to the
project's input history browsed by \\[pai-history-previous] and \\[pai-history-next].
Programmatic submissions (subagents, extensions) are not recorded."
  (interactive (list t))
  (when record (pai-refs-record-focus))
  (let ((text (pai--input-text)))
    (cond
     ((or (null text) (string-empty-p text)) (message "Empty input"))
     (t
      (setq pai--history-index nil pai--history-draft nil)
      (when record
        (ignore-errors (pai-history-add default-directory text)))
      (pai--clear-input)
      (let ((action (ignore-errors (pai-ext-run-input text (pai--ext-context)))))
        (cond
         ((and action (eq (plist-get action :action) 'handled)) nil)
         (t
          (when (and action (eq (plist-get action :action) 'transform) (plist-get action :text))
            (setq text (plist-get action :text)))
          (cond
           ((string-prefix-p "!" text) (pai--run-bang text))
           ((pai-command-input-p text) (pai--run-command text))
           (pai--active
            (push (pai-user-message (pai--expand-mentions text)) pai--steering-queue)
            (pai--render-note (format "queued (steering): %s" text)))
           (t (pai--start-run text))))))
      (goto-char (point-max))))))

;;;; Input history (M-p / M-n)

(defun pai--history-replace-input (text)
  "Replace the input area with TEXT and move point to its end."
  (pai--clear-input)
  (goto-char (point-max))
  (insert text))

(defun pai-history-previous (&optional n)
  "Replace the input with the Nth previous prompt or command of this project.
The history holds everything submitted in pai buffers of this project, newest
first; \\[pai-history-next] moves back towards the newest entry and finally
restores the input you were typing."
  (interactive "p")
  (unless (and pai--input-marker (marker-buffer pai--input-marker))
    (user-error "No input area"))
  (setq n (or n 1))
  (unless pai--history-index
    (setq pai--history-snapshot (pai-history-load default-directory)
          pai--history-draft (buffer-substring-no-properties pai--input-marker (point-max))
          pai--history-index -1))
  (let ((len (length pai--history-snapshot))
        (target (+ pai--history-index n)))
    (cond
     ((< target 0)
      (setq pai--history-index nil)
      (pai--history-replace-input (or pai--history-draft ""))
      (when (< target -1) (message "End of history; at current input")))
     ((>= target len)
      (when (= len 0) (setq pai--history-index nil))
      (message (if (= len 0) "No input history for this project"
                 "Beginning of history; no earlier input")))
     (t
      (setq pai--history-index target)
      (pai--history-replace-input (nth target pai--history-snapshot))
      (message "History %d/%d" (1+ target) len)))))

(defun pai-history-next (&optional n)
  "Replace the input with the Nth next (more recent) history entry.
Moving past the newest entry restores the input you were typing."
  (interactive "p")
  (if (null pai--history-index)
      (message "End of history; at current input")
    (pai-history-previous (- (or n 1)))))

(defun pai-interrupt ()
  "Abort the active run, if any."
  (interactive)
  (if pai--active
      (let ((run pai--run))
        ;; Aborting emits `agent-end' (:aborted t), which resets the UI.
        (when run (pai-agent-abort run))
        (when pai--active               ; no run, or its buffer sink is gone
          (setq pai--active nil pai--run nil)
          (pai--set-status "idle")
          (pai--render-note "— interrupted —" 'pai-error-face)))
    (message "No active run")))

(defun pai-set-model (id)
  "Set the current model to ID."
  (interactive
   (progn
     (dolist (err (pai-models-refresh)) (message "%s" err))
     (list (completing-read "Model: " (pai-model-keys) nil t))))
  (if (pai-model id)
      (progn (pai--set-model-id id) (pai--render-note (format "model set to %s" id)))
    (message "Unknown model: %s" id)))

(defun pai-set-thinking (level)
  "Set the reasoning LEVEL for this session."
  (interactive (list (completing-read "Thinking level: " pai-thinking-levels nil t)))
  (pai--set-thinking-level level)
  (pai--render-note (format "thinking level set to %s" level)))

(defun pai-clear ()
  "Clear the transcript display (does not delete the session file)."
  (interactive)
  (pai--init-buffer))

(defun pai-goto-input ()
  "Move point to the input area."
  (interactive)
  (goto-char (point-max)))

;;;; Jump to location (goto-dwim)

(declare-function ffap-file-at-point "ffap")

(defconst pai--path-token-chars "A-Za-z0-9_./~@+:*#-"
  "Characters that make up a file/buffer token grabbed at point.
`-' is placed last so it is treated literally by `skip-chars-forward'.")

(defun pai--path-bounds ()
  "Return (BEG . END) bounds of the path-like token around point, or nil."
  (save-excursion
    (let ((end (progn (skip-chars-forward pai--path-token-chars) (point)))
          (beg (progn (skip-chars-backward pai--path-token-chars) (point))))
      (when (< beg end) (cons beg end)))))

(defun pai--trim-token (tok)
  "Strip surrounding markdown/prose punctuation from TOK."
  (string-trim tok "[\"'`(<@]+" "[\"'`):.,;>]+"))

(defun pai--split-path-line-col (tok)
  "Split TOK into a list (PATH LINE COL); LINE/COL are integers or nil.
Handles `path', `path:LINE', and `path:LINE:COL' (e.g. grep output)."
  (let* ((segs (split-string tok ":"))
         (n (length segs))
         (digitp (lambda (s) (string-match-p "\\`[0-9]+\\'" s)))
         line col)
    (cond
     ((and (>= n 3) (funcall digitp (nth (- n 1) segs)) (funcall digitp (nth (- n 2) segs)))
      (setq col (string-to-number (nth (- n 1) segs))
            line (string-to-number (nth (- n 2) segs))
            segs (butlast segs 2)))
     ((and (>= n 2) (funcall digitp (nth (- n 1) segs)))
      (setq line (string-to-number (nth (- n 1) segs))
            segs (butlast segs 1))))
    (list (string-join segs ":") line col)))

(defun pai--resolve-file (path)
  "Return an existing file for PATH, resolved against `default-directory', or nil."
  (unless (string-empty-p path)
    (seq-find #'file-exists-p
              (delete-dups (list (expand-file-name path default-directory)
                                 (expand-file-name path))))))

(defun pai--url-at-point ()
  "Return a (:type url :url U) location for a URL at point, or nil."
  (require 'thingatpt)
  (let ((url (thing-at-point 'url t)))
    (when (and url (string-match-p "\\`[a-z][a-z0-9+.-]*://" url))
      (list :type 'url :url url))))

(defun pai--file-ref-at-point ()
  "Return a (:type file :path P :line L :col C) location at point, or nil."
  (let ((b (pai--path-bounds)))
    (when b
      (pcase-let ((`(,path ,line ,col)
                   (pai--split-path-line-col
                    (pai--trim-token (buffer-substring-no-properties (car b) (cdr b))))))
        (let ((file (pai--resolve-file path)))
          (when file (list :type 'file :path file :line line :col col)))))))

(defun pai--buffer-ref-at-point ()
  "Return a (:type buffer :buffer NAME) location for a live buffer at point, or nil.
Matches the path token, and, on a `list_buffers' TAB-separated row, the name
in the first field."
  (let* ((b (pai--path-bounds))
         (tok (and b (pai--trim-token (buffer-substring-no-properties (car b) (cdr b)))))
         (field (save-excursion
                  (let ((bol (line-beginning-position))
                        (eol (line-end-position)))
                    (goto-char bol)
                    (when (re-search-forward "\t" eol t)
                      (buffer-substring-no-properties bol (match-beginning 0))))))
         (name (seq-find (lambda (n) (and n (get-buffer n))) (list tok field))))
    (when name (list :type 'buffer :buffer name))))

(defun pai--ffap-fallback ()
  "Return a file location using `ffap' heuristics as a last resort, or nil."
  (require 'ffap)
  (let ((f (ignore-errors (ffap-file-at-point))))
    (when f
      (let ((file (pai--resolve-file f)))
        (when file (list :type 'file :path file))))))

(defun pai--location-at-point ()
  "Return a location plist describing the file/buffer/URL at point, or nil."
  (or (pai--url-at-point)
      (pai--file-ref-at-point)
      (pai--buffer-ref-at-point)
      (pai--ffap-fallback)))

(defun pai-goto-dwim (&optional here)
  "Jump to the file location, buffer, or URL referenced at point.

Understands project-relative paths, `file:LINE' and `file:LINE:COL' references
\(as produced by the grep tool), live buffer names (as listed by the
`list_buffers' tool), and URLs.  Files open in another window so the chat stays
visible; with a prefix argument HERE, reuse the current window instead."
  (interactive "P")
  (let ((loc (pai--location-at-point)))
    (unless loc (user-error "No file, buffer, or URL at point"))
    (pcase (plist-get loc :type)
      ('url (browse-url (plist-get loc :url)))
      ('buffer (if here (switch-to-buffer (plist-get loc :buffer))
                 (switch-to-buffer-other-window (plist-get loc :buffer))))
      ('file
       (let ((path (plist-get loc :path))
             (line (plist-get loc :line))
             (col (plist-get loc :col)))
         (if here (find-file path) (find-file-other-window path))
         (when line
           (goto-char (point-min))
           (forward-line (1- line))
           (when col (move-to-column (max 0 (1- col))))
           (recenter))
         (when (fboundp 'pulse-momentary-highlight-one-line)
           (pulse-momentary-highlight-one-line (point))))))))

(defalias 'pai-jump-dwim 'pai-goto-dwim
  "Alias for `pai-goto-dwim'.")

(defun pai-mouse-goto-dwim (event)
  "Move point to the mouse EVENT position and run `pai-goto-dwim'."
  (interactive "e")
  (mouse-set-point event)
  (pai-goto-dwim))

;;;; Settings screen helpers (readers shared with pai-settings-ui)

(defun pai--menu-buffer ()
  "Return a live `pai-mode' session buffer to apply settings to, or nil."
  (if (derived-mode-p 'pai-mode)
      (current-buffer)
    (seq-find (lambda (b) (with-current-buffer b (derived-mode-p 'pai-mode)))
              (buffer-list))))

(defun pai--menu-current-model ()
  "Return the model id to display in the settings menu."
  (let ((b (pai--menu-buffer)))
    (or (and b (with-current-buffer b (and pai--model (pai-model-key pai--model))))
        (pai-settings-get :model)
        pai-default-model "none")))

(defun pai--menu-current-thinking ()
  "Return the thinking level to display in the settings menu."
  (let ((b (pai--menu-buffer)))
    (or (and b (with-current-buffer b (and pai--reasoning (symbol-name pai--reasoning))))
        (pai-settings-get :thinking-level "off"))))

(defun pai--menu-apply (setter)
  "Call SETTER (a function of no args) inside the pai session buffer if any."
  (let ((b (pai--menu-buffer)))
    (if b (with-current-buffer b (funcall setter)) (funcall setter))))

(declare-function pai-settings-ui-open "pai-settings-ui" ())

(defun pai-settings-menu-command (_args ctx)
  "Open the vui settings screen for the `/menu' slash command.
CTX supplies the originating pai buffer so the screen inherits its directory."
  (let ((buf (plist-get ctx :buffer)))
    (if (buffer-live-p buf)
        (with-current-buffer buf (pai-settings-ui-open))
      (pai-settings-ui-open)))
  nil)

(pai-register-command "menu"
                      :description "Open the settings screen"
                      :handler #'pai-settings-menu-command)

;;;; Slash-command completion (TAB, Helm, or completing-read)

(declare-function helm-comp-read "helm-mode")

(defun pai--command-annotation (name)
  "Return an annotation string (the description) for command NAME."
  (let ((c (pai-command-get name)))
    (when (and c (not (string-empty-p (or (plist-get c :description) ""))))
      (concat "  —  " (plist-get c :description)))))

(defun pai-command-completion-candidates ()
  "Return (DISPLAY . NAME) pairs for all slash commands, description included."
  (mapcar (lambda (c)
            (cons (format "/%-16s %s" (plist-get c :name) (plist-get c :description))
                  (plist-get c :name)))
          (pai-commands-all)))

(defun pai--insert-command (name)
  "Replace the input area with the slash command NAME, ready for arguments.
When NAME has argument completions, open the value completion immediately."
  (goto-char (point-max))
  (let ((inhibit-read-only t))
    (delete-region pai--input-marker (point-max)))
  (insert "/" name " ")
  (pai--maybe-complete-args))

(defun pai-completion-at-point ()
  "`completion-at-point-functions' entry for slash commands in the input area.
Shows each command's description as an annotation.  On accepting a command a
trailing space is inserted and, when the command has argument completions,
the value completion opens automatically."
  (when (and pai--input-marker (>= (point) pai--input-marker))
    (let ((text (buffer-substring-no-properties pai--input-marker (point))))
      (when (string-match "\\`/\\([A-Za-z0-9_-]*\\)\\'" text)
        (list (1+ pai--input-marker) (point)
              (pai-command-names)
              :annotation-function #'pai--command-annotation
              :exit-function #'pai--command-completion-exit
              :exclusive 'no)))))

(defun pai--command-completion-exit (name status)
  "Exit function for command-name completion of NAME with STATUS.
Insert a trailing space and open argument completion when appropriate."
  (when (and (memq status '(finished sole))
             pai--input-marker (>= (point) pai--input-marker)
             (pai-command-get name))
    (unless (eql (char-before) ?\s) (insert " "))
    (pai--maybe-complete-args)))

(defun pai--command-arg-context ()
  "Return (COMMAND-PLIST . ARG-FN) when point is in the argument area of a
slash command line with argument completions, else nil."
  (when (and pai--input-marker (>= (point) pai--input-marker))
    (let ((text (buffer-substring-no-properties pai--input-marker (point))))
      (when (string-match "\\`/\\([A-Za-z0-9_-]+\\)[ \t]+" text)
        (let* ((cmd (pai-command-get (match-string 1 text)))
               (argfn (and cmd (plist-get cmd :arg-completions))))
          ;; a completer that ignores the position only fits the first
          ;; argument; past it, it would offer (and chain) the same list again
          (when (and argfn (or (plist-get cmd :arg-positional)
                               (null (pai-command-arg-words))))
            (cons cmd argfn)))))))

(defun pai-arg-completion-at-point ()
  "`completion-at-point-functions' entry completing a slash command's argument.
Active after `/command ' when the command registered `:arg-completions'."
  (let ((ctx (pai--command-arg-context)))
    (when ctx
      (let* ((beg (save-excursion (skip-chars-backward "^ \t" pai--input-marker) (point)))
             (prefix (buffer-substring-no-properties beg (point)))
             (cands (ignore-errors (funcall (cdr ctx) prefix))))
        (when cands
          ;; candidates with spaces (a task name, see `:line' in
          ;; `pai-command-tree-candidates') replace all the words they match
          (when (seq-some (lambda (c) (string-match-p "[ \t]" c)) cands)
            (setq beg (pai--arg-line-start beg cands)))
          (list beg (point) cands :exclusive 'no
                :exit-function #'pai--arg-completion-exit))))))

(defun pai--arg-line-start (beg cands)
  "Return the earliest word start before BEG whose text up to point prefixes CANDS.
Falls back to BEG.  Case is ignored, as in `pai-command-completion-tree'."
  (let ((args-start (save-excursion
                      (goto-char pai--input-marker)
                      (skip-chars-forward "^ \t")   ; past "/cmd"
                      (skip-chars-forward " \t")
                      (point)))
        (best beg))
    (save-excursion
      (goto-char beg)
      (while (> (point) args-start)
        (skip-chars-backward " \t" args-start)
        (skip-chars-backward "^ \t" args-start)
        (let ((typed (buffer-substring-no-properties (point) (point-max))))
          (when (seq-some (lambda (c) (string-prefix-p typed c t)) cands)
            (setq best (point))))))
    best))

(defun pai--next-arg-candidates ()
  "Return what the command at point offers for a new argument after point."
  (when (pai--command-arg-context)
    (save-excursion
      (let ((inhibit-read-only t) (buffer-undo-list t)
            (pos (point)))
        ;; ask as if a space were typed (argument words are read up to point)
        (insert " ")
        (prog1 (let ((ctx (pai--command-arg-context)))
                 (and ctx (ignore-errors (funcall (cdr ctx) ""))))
          (delete-region pos (1+ pos)))))))

(defun pai--arg-completion-exit (_value status)
  "After accepting an argument with STATUS, go on to the next level, if any.
A space is inserted and completion opens when the command offers words
after this one (e.g. `/memory session' then `on|off', then `--global')."
  (when (and (memq status '(finished sole))
             pai--input-marker (>= (point) pai--input-marker)
             (= (point) (point-max))
             (pai--next-arg-candidates))
    (insert " ")
    (pai--maybe-complete-args)))

(defun pai--maybe-complete-args ()
  "Open argument completion after `/command ' or `/command ARGS... ' when the
command offers words at that position."
  (when (and (not noninteractive)
             pai--input-marker (>= (point) pai--input-marker))
    (let ((text (buffer-substring-no-properties pai--input-marker (point)))
          (ctx (pai--command-arg-context)))
      (when (and ctx
                 (string-match "\\`/[A-Za-z0-9_-]+[ \t]+\\(?:[^ \t]+[ \t]+\\)*\\'" text)
                 (ignore-errors (funcall (cdr ctx) "")))
        (completion-at-point)))))

(defun pai-ext-completion-at-point ()
  "`completion-at-point-functions' entry consulting extension autocomplete providers."
  (when (and pai--input-marker (>= (point) pai--input-marker))
    (let* ((beg (save-excursion
                  (skip-chars-backward "^ \t\n" pai--input-marker) (point)))
           (prefix (buffer-substring-no-properties beg (point)))
           (cands (ignore-errors (pai-ext-autocomplete prefix))))
      (when cands (list beg (point) cands :exclusive 'no)))))

(defun pai--project-files ()
  "Return up to 500 project-relative file paths under the working directory."
  (let ((files (ignore-errors
                 (directory-files-recursively
                  default-directory ".*" nil
                  (lambda (d) (not (string-match-p "/\\.git\\(/\\|$\\)" d)))))))
    (mapcar (lambda (f) (file-relative-name f default-directory)) (seq-take files 500))))

(defun pai--mention-exit (_string status)
  "Exit function for @-mention completion with STATUS.
After a directory (the inserted name ends in `/') is accepted, reopen
completion so the user can drill further down, mirroring how the minibuffer
file dialog keeps completing inside a directory; accepting a file stops."
  (when (and (memq status '(finished sole))
             (eq (char-before) ?/)
             (not noninteractive))
    (completion-at-point)))

(defun pai-mention-completion-at-point ()
  "`completion-at-point-functions' entry completing @file mentions in the input.
This delegates to Emacs' built-in file-name completion
\(`completion-file-name-table'), so it behaves exactly like the minibuffer
file dialog: `..', `~', environment variables, partial completion and
directory drilling all work the same way.  Completion is rooted at the working
directory; selecting a directory reopens completion so you can descend, and
selecting a file ends it."
  (when (and pai--input-marker (>= (point) pai--input-marker))
    (let ((beg (save-excursion (skip-chars-backward "^ \t\n" pai--input-marker) (point))))
      (when (and (> (point) beg) (eq (char-after beg) ?@))
        (list (1+ beg) (point)
              ;; Hand the whole path after `@' to the standard file-name table
              ;; so all native file-completion behaviour (completion styles,
              ;; `..', `~', directory drilling) applies.  Relative names resolve
              ;; against the buffer's `default-directory' (the working dir).
              #'completion-file-name-table
              :exit-function #'pai--mention-exit
              :exclusive 'no)))))

(defconst pai--mention-boundary-chars '(?\s ?\t ?\n ?. ?, ?\; ?: ?! ?? ?\) ?\] ?} ?' ?\" ?`)
  "Characters that may directly follow a buffer mention.")

(defun pai--mention-ends-at-p (text pos)
  "Return non-nil when a mention in TEXT may end at POS.
It may when only punctuation separates POS from the end of the word, so
`*pt.' and `*pt,' mention `pt', but `*pt.elc' does not."
  (let ((i pos) (n (length text)))
    (while (and (< i n) (memq (aref text i) pai--mention-boundary-chars)
                (not (memq (aref text i) '(?\s ?\t ?\n))))
      (setq i (1+ i)))
    (or (= i n) (memq (aref text i) '(?\s ?\t ?\n)))))

(defun pai--buffer-mention-name (name)
  "Return how buffer NAME is written as a mention.
Names that already start with `*' (e.g. `*scratch*') are written as they
are; other names get a leading `*' (e.g. `*pai-ui.el')."
  (if (string-prefix-p "*" name) name (concat "*" name)))

(defun pai--mentionable-buffer-p (buffer)
  "Return non-nil when BUFFER may be mentioned from the current buffer.
Internal buffers (names starting with a space) and this buffer are left out."
  (let ((buffer (if (consp buffer) (cdr buffer) buffer)))
    (and (buffer-live-p (if (stringp buffer) (get-buffer buffer) buffer))
         (let ((name (if (stringp buffer) buffer (buffer-name buffer))))
           (and (not (string-prefix-p " " name))
                (not (equal name (buffer-name))))))))

(defun pai--mentionable-buffer-names ()
  "Return the names of the buffers that may be mentioned, longest first."
  (sort (mapcar #'buffer-name (seq-filter #'pai--mentionable-buffer-p (buffer-list)))
        (lambda (a b) (> (length a) (length b)))))

(defun pai--mention-range-at (text pos)
  "Return (RANGE . END) for a `:N' or `:N-M' suffix at POS in TEXT, or nil."
  (save-match-data
    (when (and (string-match ":\\([0-9]+\\)\\(?:-\\([0-9]+\\)\\)?" text pos)
               (= (match-beginning 0) pos))
      (let ((first (string-to-number (match-string 1 text)))
            (last (and (match-beginning 2) (string-to-number (match-string 2 text)))))
        (cons (cons first (max first (or last first))) (match-end 0))))))

(defun pai--find-buffer-refs (text)
  "Return the buffer references in TEXT as (BUFFER . RANGE), in order.
A reference is a `*' at the start of a word followed by a live buffer's
name (see `pai--buffer-mention-name'), optionally followed by `:N' or
`:N-M' (RANGE, a cons of lines; nil for the whole buffer).  Names may
contain spaces, so every `*' is matched against the live buffer names,
longest first; the reference must end at the end of the text, whitespace
or punctuation.  Repeated references are listed once."
  (let ((names (pai--mentionable-buffer-names))
        (n (length text))
        (i 0)
        (found '()))
    (while (setq i (string-search "*" text i))
      (let ((match
             (and (or (= i 0) (memq (aref text (1- i)) '(?\s ?\t ?\n)))
                  (cl-some
                   (lambda (name)
                     (let* ((beg (if (string-prefix-p "*" name) i (1+ i)))
                            (end (+ beg (length name))))
                       (when (and (<= end n) (string= name (substring text beg end)))
                         (let* ((range (pai--mention-range-at text end))
                                (stop (if range (cdr range) end)))
                           (when (pai--mention-ends-at-p text stop)
                             (list name (car range) stop))))))
                   names))))
        (if (not match)
            (setq i (1+ i))
          (push (cons (get-buffer (nth 0 match)) (nth 1 match)) found)
          ;; STOP is past the `*', so I strictly increases.
          (setq i (nth 2 match)))))
    (delete-dups (nreverse found))))

(defun pai--find-buffer-mentions (text)
  "Return the live buffers referenced in TEXT, each once, in order."
  (delete-dups (mapcar #'car (pai--find-buffer-refs text))))

(defun pai--find-file-mentions (text)
  "Return the @path mentions in TEXT that name existing files or directories.
Each element is (WRITTEN . ABSOLUTE); trailing punctuation after a path
\(`see @a.el,') is ignored when the path with it does not exist."
  (let ((found '()) (start 0))
    (while (string-match "\\(?:\\`\\|[ \t\n]\\)@\\([^ \t\n]+\\)" text start)
      ;; Take everything from this match first: the match is never empty, so
      ;; START strictly increases and the loop always ends, whatever the
      ;; code below does to the match data.
      (let ((written (match-string 1 text)))
        (setq start (match-end 0))
        (save-match-data
          (unless (file-exists-p (expand-file-name written))
            (setq written (replace-regexp-in-string "[.,;:!?)'\"`]+\\'" "" written)))
          (when (and (not (string-empty-p written))
                     (file-exists-p (expand-file-name written)))
            (push (cons written (expand-file-name written)) found)))))
    (seq-uniq (nreverse found) (lambda (a b) (equal (cdr a) (cdr b))))))

(defun pai--mention-reference (item)
  "Return the note line for ITEM: a file (WRITTEN . PATH) or (BUFFER . RANGE)."
  (if (bufferp (car item))
      (concat "- "
              (if (cdr item)
                  (format "lines %s of " (pai-refs--range-string (cdr item)))
                "")
              (pai-refs-describe-buffer (car item)))
    (format "- %s `%s`" (if (file-directory-p (cdr item)) "directory" "file") (car item))))

(defun pai--expand-mentions (text)
  "Return TEXT with a note naming the files and buffers it mentions.
Mentions are references, not attachments: @path mentions of existing files
or directories and *name[:N-M] mentions of live buffers (see
`pai--find-buffer-refs') are listed after TEXT, so the model knows what
each one is and reads what it needs.  Mentions that resolve to nothing are
left as plain text, and TEXT without mentions is returned unchanged."
  (let ((items (append (pai--find-file-mentions text) (pai--find-buffer-refs text))))
    (if (null items) text
      (concat text "\n\n[Mentioned, not attached; read with read / read_buffer:]\n"
              (mapconcat #'pai--mention-reference items "\n")))))

(defun pai-helm-commands ()
  "Pick a slash command with Helm (description shown next to each) and insert it."
  (interactive)
  (unless (require 'helm nil t)
    (user-error "Helm is not installed; use M-x pai-complete-command"))
  (let ((name (helm-comp-read "pai /command: "
                              (pai-command-completion-candidates)
                              :must-match t :name "pai slash commands")))
    (when (and (stringp name) (not (string-empty-p name)))
      (pai--insert-command name))))

(defun pai--completing-read-command ()
  "Fallback slash-command picker using `completing-read' with descriptions."
  (let* ((cmds (pai-command-names))
         (table (lambda (str pred action)
                  (if (eq action 'metadata)
                      (list 'metadata (cons 'annotation-function #'pai--command-annotation))
                    (complete-with-action action cmds str pred))))
         (name (completing-read "pai /command: " table nil t)))
    (when (and (stringp name) (not (string-empty-p name)))
      (pai--insert-command name))))

(defun pai-complete-command ()
  "Choose a slash command, preferring Helm when it is installed."
  (interactive)
  (if (require 'helm nil t)
      (pai-helm-commands)
    (pai--completing-read-command)))

(defun pai-at-mention ()
  "Insert an `@file' mention, choosing the file with the minibuffer file dialog.
In the input area this reads a file name with `read-file-name', so you get the
full native file-selection experience: TAB completes and drills into
directories, `..' walks up, `~' expands home, and completion continues until
you finally select a file (RET).  The chosen path (relative to the working
directory when possible) is inserted as `@path'.  Abort (\[keyboard-quit])
to insert a bare `@' instead.  Outside the input area, just insert `@'."
  (interactive)
  (if (not (and pai--input-marker (>= (point) pai--input-marker)
                (not noninteractive)))
      (insert "@")
    (let* ((default-directory default-directory)
           (file (condition-case nil
                     (read-file-name "@mention file: " default-directory nil t)
                   (quit nil))))
      (if (or (null file) (string-empty-p file))
          (insert "@")
        (let ((rel (file-relative-name file default-directory)))
          ;; Keep the relative path unless it escapes the working directory,
          ;; in which case fall back to the (abbreviated) absolute path.
          (insert "@" (if (string-prefix-p "../" rel)
                          (abbreviate-file-name file)
                        rel)))))))

(defun pai--at-word-start-p ()
  "Return non-nil when point is at the start of a word in the input."
  (or (= (point) pai--input-marker)
      (memq (char-before) '(?\s ?\t ?\n))))

(defun pai-buffer-mention ()
  "Insert a `*buffer' mention, choosing the buffer with `read-buffer'.
At the start of a word in the input area this opens Emacs' buffer picker
\(so your completion UI applies); the chosen buffer is inserted as a
mention; on send the model is told it is a buffer name, and reads it with
its tools if needed (the contents are not attached).  Abort
\([keyboard-quit]) to insert a plain `*'.  Elsewhere -- mid-word, as in
`**bold**' or `a*b', or outside the input -- just insert `*'."
  (interactive)
  (if (not (and pai--input-marker (>= (point) pai--input-marker)
                (not noninteractive)
                (pai--at-word-start-p)))
      (insert "*")
    (let ((name (condition-case nil
                    (read-buffer "*mention buffer: "
                                 (let ((other (other-buffer (current-buffer) t)))
                                   (and (pai--mentionable-buffer-p other) (buffer-name other)))
                                 t #'pai--mentionable-buffer-p)
                  (quit nil))))
      (if (or (null name) (string-empty-p name))
          (insert "*")
        (insert (pai--buffer-mention-name name))))))

(defun pai-buffer-mention-completion-at-point ()
  "`completion-at-point-functions' entry completing *buffer mentions in the input."
  (when (and pai--input-marker (>= (point) pai--input-marker))
    (let ((beg (save-excursion (skip-chars-backward "^ \t\n" pai--input-marker) (point))))
      (when (and (> (point) beg) (eq (char-after beg) ?*))
        (list beg (point)
              (mapcar #'pai--buffer-mention-name (pai--mentionable-buffer-names))
              :annotation-function
              (lambda (candidate)
                (let ((buffer (or (get-buffer candidate) (get-buffer (substring candidate 1)))))
                  (when buffer
                    (concat "  " (symbol-name (buffer-local-value 'major-mode buffer))))))
              :exclusive 'no)))))

(defun pai-slash ()
  "Insert `/', or open slash-command completion at the start of the input line."
  (interactive)
  (if (and pai--input-marker
           (= (point) (point-max))
           (= (point) (marker-position pai--input-marker)))
      (pai-complete-command)
    (insert "/")))

;;;; Mode and setup

(defvar pai-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'pai-send)
    (define-key map (kbd "C-c C-c") #'pai-interrupt)
    (define-key map (kbd "C-c C-k") #'pai-interrupt)
    (define-key map (kbd "C-c C-m") #'pai-set-model)
    (define-key map (kbd "C-c C-l") #'pai-clear)
    (define-key map (kbd "C-c C-n") #'pai-goto-input)
    (define-key map (kbd "/") #'pai-slash)
    (define-key map (kbd "@") #'pai-at-mention)
    (define-key map (kbd "C-c /") #'pai-complete-command)
    (define-key map (kbd "C-c C-t") #'pai-set-thinking)
    (define-key map (kbd "C-c C-s") #'pai-settings-ui-open)
    (define-key map (kbd "C-c C-o") #'pai-goto-dwim)
    (define-key map (kbd "M-.") #'pai-goto-dwim)
    (define-key map (kbd "<mouse-2>") #'pai-mouse-goto-dwim)
    map)
  "Keymap for `pai-mode'.")

;; Bindings added after the initial `defvar' must live outside it: `defvar'
;; does not re-evaluate its INIT when the variable is already bound, so a
;; `/reload' of this file would otherwise never install them.  Applying them
;; here (and copying into any live buffers' local maps) makes them take effect
;; on reload as well as first load.
(defconst pai--extra-keys
  '(("@" . pai-at-mention)
    ("*" . pai-buffer-mention)
    ("M-p" . pai-history-previous)
    ("M-n" . pai-history-next)
    ("C-c C-e" . pai-edit-input))
  "Bindings added to `pai-mode-map' after its original `defvar'.")

(defun pai--install-extra-keys ()
  "Install `pai--extra-keys' in `pai-mode-map' and in live pai buffers.
Runs on load so `/reload' picks up newly added keys; each pai buffer uses
a copy of the map, so the copies are updated too."
  (dolist (binding pai--extra-keys)
    (define-key pai-mode-map (kbd (car binding)) (cdr binding)))
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (derived-mode-p 'pai-mode) (current-local-map))
        (dolist (binding pai--extra-keys)
          (define-key (current-local-map) (kbd (car binding)) (cdr binding)))))))

(pai--install-extra-keys)

(define-derived-mode pai-mode fundamental-mode "pai"
  "Major mode for the pai agent chat buffer."
  ;; Re-entering the mode (/new, /resume) killed the locals that tracked the
  ;; footer and activity overlays; drop the now-orphaned overlays so their
  ;; last frame does not linger at the top of the buffer.
  (save-restriction
    (widen)
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (or (overlay-get ov 'pai-footer) (overlay-get ov 'pai-activity))
        (delete-overlay ov))))
  (use-local-map (copy-keymap pai-mode-map))
  (setq-local header-line-format '(:eval (pai--header-line-segment)))
  (setq-local mode-line-format
              (append (default-value 'mode-line-format) '((:eval (pai--mode-line-segment)))))
  (setq-local truncate-lines nil)
  ;; Terminal-style behaviour: the input line lives at the buffer's end and is
  ;; kept pinned to the bottom of the window.  A high `scroll-conservatively'
  ;; makes the window scroll one line at a time to keep point (the prompt) on
  ;; the last row instead of recentering with a jump, so streamed output flows
  ;; up out of view above the prompt just like pi's TUI.
  (setq-local scroll-conservatively 101)
  (setq-local scroll-margin 0)
  (setq-local scroll-step 1)
  (visual-line-mode 1)
  (add-hook 'completion-at-point-functions #'pai-completion-at-point nil t)
  (add-hook 'completion-at-point-functions #'pai-arg-completion-at-point nil t)
  (add-hook 'completion-at-point-functions #'pai-mention-completion-at-point nil t)
  (add-hook 'completion-at-point-functions #'pai-buffer-mention-completion-at-point nil t)
  (add-hook 'completion-at-point-functions #'pai-ext-completion-at-point nil t)
  ;; apply any extension-registered shortcuts
  (pai-ext-apply-shortcuts))

(defun pai--init-buffer ()
  "Initialize the current buffer's transcript and input area.
The prompt is preceded by a blank line and kept at the buffer's end; all
transcript output is inserted above it."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (pai--propertize (concat "\n" pai-prompt-string) 'pai-prompt-face))
    (setq pai--input-marker (copy-marker (point) nil))
    (setq pai--output-marker (copy-marker (point-min) t))
    (goto-char (point-max)))
  (pai--render-footer))

(defun pai--project-trusted-p ()
  "Return non-nil if the current project directory is trusted, prompting if needed."
  (require 'pai-trust)
  (pai-trust-trusted-p
   default-directory
   (lambda (dir)
     (if noninteractive
         (list :trusted nil)
       (let ((yes (y-or-n-p (format "Trust project %s (load its extensions/skills/prompts)? " dir))))
         (list :trusted yes
               :remember (and yes (y-or-n-p "Remember this decision? "))))))))

(defun pai--extension-dirs ()
  "Return the extension directories to load, gating project dirs by trust."
  (let ((dirs (list (expand-file-name "extensions" pai-directory))))
    (when pai--trusted
      (setq dirs (append dirs (list (expand-file-name ".pai/extensions" default-directory)))))
    (seq-filter #'file-directory-p dirs)))

(defun pai--skill-dirs ()
  "Return the skill directories to scan, gating project dirs by trust."
  (let ((dirs (list (expand-file-name "skills" pai-directory))))
    (when pai--trusted
      (setq dirs (append dirs (list (expand-file-name ".pai/skills" default-directory)
                                    (expand-file-name ".skills" default-directory)))))
    (seq-filter #'file-directory-p dirs)))

(defun pai--prompt-dirs ()
  "Return the prompt-template directories to scan, gating project dirs by trust."
  (let ((dirs (list (expand-file-name "prompts" pai-directory))))
    (when pai--trusted
      (push (expand-file-name ".pai/prompts" default-directory) dirs))
    (seq-filter #'file-directory-p dirs)))

(defun pai--load-trusted-extensions ()
  "Load extensions from trusted directories."
  (require 'pai-ext)
  (pai-load-extensions (pai--extension-dirs)))

(defun pai--setup (cwd &optional session)
  "Set up the current buffer as a pai chat for project CWD.
With SESSION, adopt it instead of creating a fresh one (used by fork/clone)."
  (pai-mode)
  (setq default-directory (file-name-as-directory (expand-file-name cwd)))
  (require 'pai-settings)
  (require 'pai-model-resolver)
  (pai-ext-initialize-instance)
  (pai-settings-load default-directory)
  (pai-models-load-custom)
  (let ((lvl (pai-settings-get :thinking-level)))
    (setq pai--reasoning (and lvl (not (equal lvl "off")) (intern lvl))))
  (setq pai--trusted (pai--project-trusted-p))
  (pai--load-trusted-extensions)
  (let ((id (or (pai-settings-get :model) pai-default-model)))
    (unless (or pai--model (pai-model id))
      (dolist (err (pai-models-refresh)) (message "%s" err)))
    (setq pai--model (or pai--model (pai-model id)
                         (and (null id) (car (pai-models))))))
  (pai-ext-emit 'resources-discover (pai--ext-context) :reason 'startup)
  (require 'pai-prompts)
  (dolist (dir (pai--prompt-dirs)) (pai-prompts-register (list dir)))
  (pai-commands-unregister-skills)
  (let ((skills (pai-discover-skills (pai--skill-dirs))))
    (pai-commands-register-skills skills)
    (pai-commands-register-bundles skills))
  (setq pai--usage-total (pai-usage) pai--context-tokens 0
        pai--cost-total 0.0 pai--unpriced-tokens (cons 0 0) pai--cost-incomplete nil)
  ;; prices for models that have none (subscriptions); background, daily
  (unless noninteractive (pai-pricing-refresh))
  (if session
      ;; Adopt an existing (e.g. forked) session; its transcript already carries
      ;; the leading system message.
      (progn
        (setq pai--session session
              pai--context-messages (pai-session-context-messages session))
        (pai--recompute-cost))
    (setq pai--session (pai-session-new default-directory))
    ;; Seed the transcript with the system prompt as the leading system message.
    (let ((sys (pai-system-message
                (pai-build-system-prompt
                 :cwd default-directory
                 :tools (pai-tools-all)
                 :skills (pai-discover-skills (pai--skill-dirs))
                 :context-files (pai--context-files default-directory)
                 :sections (pai-ext-run-system-prompt-sections (pai--ext-context))))))
      (setq pai--context-messages (list sys))
      (pai-session-append-message pai--session sys)))
  ;; The context is never empty: the system prompt and the tool schemas are
  ;; sent on every request, so seed the header with a real estimate.
  (pai--refresh-context-tokens)
  (pai--init-buffer)
  (pai--set-status "idle")
  (unless pai--model
    (pai--render-note "No model selected. Use M-x pai-add-provider to configure a server, then /model to select a model."))
  (pai-ext-emit 'session-start (pai--ext-context) :reason 'startup)
  (pai--schedule-usage-refresh t))

(defun pai--context-files (cwd)
  "Return an alist of (NAME . TEXT) for known project instruction files in CWD."
  (delq nil
        (mapcar (lambda (name)
                  (let ((file (expand-file-name name cwd)))
                    (when (file-readable-p file)
                      (cons name (with-temp-buffer (insert-file-contents file) (buffer-string))))))
                '("AGENTS.md" "CLAUDE.md" ".pai/AGENTS.md"))))

(defun pai--buffer-name (dir)
  "Return a session buffer name for project DIR, including its base name."
  (format "*pai: %s*"
          (file-name-nondirectory (directory-file-name (expand-file-name dir)))))

;;;###autoload
(defun pai (&optional cwd)
  "Open the pai agent chat buffer for CWD (default `default-directory')."
  (interactive)
  (let* ((dir (file-name-as-directory (file-truename (or cwd default-directory))))
         (existing (seq-find
                    (lambda (buffer)
                      (with-current-buffer buffer
                        (and (eq major-mode 'pai-mode)
                             (equal dir (file-name-as-directory
                                         (file-truename default-directory))))))
                    (buffer-list)))
         (buf (or existing (generate-new-buffer (pai--buffer-name dir)))))
    (unless existing
      (with-current-buffer buf (pai--setup dir)))
    (pop-to-buffer buf)
    (goto-char (point-max))
    buf))

;;;###autoload
(defun pai-new-session (&optional cwd)
  "Open a fresh pai session buffer for CWD."
  (interactive)
  (let* ((dir (or cwd default-directory))
         (buf (generate-new-buffer (pai--buffer-name dir))))
    (with-current-buffer buf
      (pai--setup dir))
    (pop-to-buffer buf)
    (goto-char (point-max))
    buf))

(provide 'pai-ui)
;;; pai-ui.el ends here
