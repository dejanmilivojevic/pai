;;; pai-ui-test.el --- Headless tests for the chat UI -*- lexical-binding: t; -*-

;;; Commentary:
;; Drives the real interactive commands in batch Emacs with the faux provider
;; and asserts on buffer contents and persistence.

;;; Code:

(require 'ert)
(require 'pai)
(require 'pai-faux)

(defmacro pai-ui-test--with-buffer (buf dir &rest body)
  "Bind DIR to a temp project and BUF to a fresh faux-backed pai buffer; run BODY."
  (declare (indent 2))
  `(let* ((,dir (file-name-as-directory (make-temp-file "pai-ui" t)))
          (pai-directory (expand-file-name ".pai-state" ,dir))
          (pai-default-model "faux")
          (,buf nil))
     (unwind-protect
         (progn
           (pai-ext-reset)
           (setq ,buf (get-buffer-create (generate-new-buffer-name "*pai-test*")))
           (with-current-buffer ,buf
             (setq default-directory ,dir)
             (pai--setup ,dir))
           ,@body)
       (when (buffer-live-p ,buf) (kill-buffer ,buf))
       (ignore-errors (delete-directory ,dir t)))))

(defun pai-ui-test--type-and-send (text)
  "Type TEXT into the input area and submit."
  (goto-char (point-max))
  (insert text)
  (pai-send))

(ert-deftest pai-ui-simple-exchange ()
  (pai-faux-reset)
  (pai-faux-push '(:text "Hello from the assistant." :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--type-and-send "hi there")
      (let ((content (buffer-string)))
        (should (string-match-p "▶ You" content))
        (should (string-match-p "hi there" content))
        (should (string-match-p "● pai" content))
        (should (string-match-p "Hello from the assistant." content))
        (should (string-match-p "— ready —" content)))
      ;; the input area is empty again and run is cleared
      (should (string-empty-p (pai--input-text)))
      (should-not pai--active)
      ;; session persisted: system + user + assistant
      (should (>= (length (pai-session-messages pai--session)) 3)))))

(ert-deftest pai-ui-tool-call-render ()
  (pai-faux-reset)
  (pai-faux-push '(:tool-calls ((:id "c1" :name "elisp_eval" :arguments (:form "(+ 1 2)")))
                  :stop-reason tool-use)
                 '(:text "The answer is 3." :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--type-and-send "compute 1+2")
      (let ((content (buffer-string)))
        (should (string-match-p "⚙ elisp_eval" content))
        (should (string-match-p "=> 3" content))
        (should (string-match-p "The answer is 3." content))))))

(ert-deftest pai-ui-skill-slash-command ()
  "Discovered skills are /skill:NAME commands that send the skill to the agent."
  (pai-faux-reset)
  (pai-faux-push '(:text "Following the skill." :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (let ((skill-dir (expand-file-name "skills/db" pai-directory)))
        (make-directory skill-dir t)
        (with-temp-file (expand-file-name "SKILL.md" skill-dir)
          (insert "---\nname: db\ndescription: database work\n---\nUse migrations.\n")))
      ;; skills are picked up by /reload (and new sessions)
      (pai-reload-command "" (list :buffer buf))
      (should (pai-command-get "skill:db"))
      (should-not (pai-command-get "db"))
      (pai-ui-test--type-and-send "/skill:db add an index")
      (let ((sent (pai-content-text (pai-message-content
                                     (car (last (plist-get pai-faux-last-context :messages)))))))
        (should (string-match-p "<skill name=\"db\"" sent))
        (should (string-match-p "Use migrations." sent))
        (should (string-match-p "add an index\\'" sent))))))

(ert-deftest pai-ui-slash-help ()
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--type-and-send "/help")
      (should (string-match-p "Available commands" (buffer-string)))
      ;; no run started for a pure display command
      (should-not pai--active))))

(ert-deftest pai-ui-unknown-slash ()
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--type-and-send "/does-not-exist")
      (should (string-match-p "Unknown command" (buffer-string))))))

(ert-deftest pai-ui-error-render ()
  (pai-faux-reset)
  (pai-faux-push '(:error "provider exploded"))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--type-and-send "go")
      (should (string-match-p "provider exploded" (buffer-string))))))

(ert-deftest pai-ui-input-region-readonly-transcript ()
  ;; The transcript region must be read-only; the input region editable.
  (pai-faux-reset)
  (pai-faux-push '(:text "reply" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--type-and-send "hello")
      ;; attempting to edit inside the transcript should error
      (goto-char (point-min))
      (should-error (insert "x") :type 'text-read-only)
      ;; typing at the end (input area) works
      (goto-char (point-max))
      (insert "draft")
      (should (equal (pai--input-text) "draft")))))

(ert-deftest pai-ui-model-in-header ()
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (should (equal (plist-get pai--model :id) "faux"))
      (should (string-match-p "faux" (pai--header-line))))))

(ert-deftest pai-ui-renders-aligned-table ()
  "A markdown table in an assistant reply is aligned when the message finalizes."
  (pai-faux-reset)
  (pai-faux-push '(:text "Here:\n| Name | Age |\n|---|---|\n| Alice | 30 |\n| Bob | 100 |\nDone."
                   :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--type-and-send "make a table")
      (let ((content (buffer-string)))
        ;; aligned header and separator rows appear; the raw "|---|---|" is gone
        (should (string-match-p "| Name  | Age |" content))
        (should (string-match-p "| ----- | --- |" content))
        (should (string-match-p "| Alice | 30  |" content))
        (should-not (string-match-p "|---|---|" content))))))

(ert-deftest pai-ui-command-candidates-have-descriptions ()
  (let ((cands (pai-command-completion-candidates)))
    (should (assoc-default "help" (mapcar (lambda (c) (cons (cdr c) (car c))) cands)))
    ;; a candidate display string carries the description text
    (should (seq-find (lambda (c) (string-match-p "List available commands" (car c))) cands)))
  (should (string-match-p "List available commands" (pai--command-annotation "help"))))

(ert-deftest pai-ui-completion-at-point-annotates ()
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (goto-char (point-max)) (insert "/")
      (let ((capf (pai-completion-at-point)))
        (should capf)
        (should (member "help" (nth 2 capf)))
        (should (functionp (plist-get (nthcdr 3 capf) :annotation-function)))))))

(ert-deftest pai-ui-arg-completion-values ()
  ;; After `/thinking ' the argument completion offers the thinking levels.
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (goto-char (point-max)) (insert "/thinking ")
      (let ((capf (pai-arg-completion-at-point)))
        (should capf)
        (should (equal (nth 2 capf) pai-thinking-levels))
        ;; bounds cover the (empty) argument at point
        (should (= (nth 0 capf) (point)))
        (should (= (nth 1 capf) (point)))))))

(ert-deftest pai-ui-arg-completion-partial-prefix ()
  ;; A partially typed argument narrows against the same candidate set; the
  ;; completion region begins at the start of the partial word.
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (goto-char (point-max)) (insert "/settings me")
      (let ((capf (pai-arg-completion-at-point)))
        (should capf)
        (should (member "menu" (nth 2 capf)))
        (should (equal (buffer-substring-no-properties (nth 0 capf) (nth 1 capf)) "me"))))))

(ert-deftest pai-ui-completion-tree-levels ()
  "`pai-command-tree-candidates' walks any depth; free text and flags too."
  (let ((tree `("a" ("b" ("c" "--x") "d")
                ("ids" ,(lambda () '("id1" "id2")))
                ("forget" (:rest "--regex" "--all")))))
    (should (equal (pai-command-tree-candidates tree nil) '("a" "b" "ids" "forget")))
    (should (equal (pai-command-tree-candidates tree '("b")) '("c" "d")))
    (should (equal (pai-command-tree-candidates tree '("b" "c")) '("--x")))       ; third level
    (should-not (pai-command-tree-candidates tree '("b" "c" "--x")))
    (should-not (pai-command-tree-candidates tree '("a")))                      ; a leaf
    (should-not (pai-command-tree-candidates tree '("nope")))
    (should-not (pai-command-tree-candidates tree '("b" "nope" )))
    (should (equal (pai-command-tree-candidates tree '("ids")) '("id1" "id2")))
    ;; free text, then flags at every position until used
    (should (equal (pai-command-tree-candidates tree '("forget")) '("--regex" "--all")))
    (should (equal (pai-command-tree-candidates tree '("forget" "some" "text")) '("--regex" "--all")))
    (should (equal (pai-command-tree-candidates tree '("forget" "x" "--all" "y")) '("--regex"))))
  ;; (:line ...): the rest of the line is one argument with spaces
  (let ((tree `(("done" (:line . ,(lambda () '("Wire workspace" "Run tests")))) "edit")))
    (should (equal (pai-command-tree-candidates tree '("done")) '("Wire workspace" "Run tests")))
    (should (equal (pai-command-tree-candidates tree '("done" "Wire")) '("Wire workspace" "Run tests")))
    (should (equal (cdr (pai-command--tree-walk tree '("done" "Wire"))) '("Wire")))
    (should (eq (cdr (pai-command--tree-walk tree '("edit"))) 'none))))

(ert-deftest pai-ui-arg-completion-third-level ()
  "Argument completion works past the first argument, per command."
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (let ((at (lambda (text)
                  (goto-char (point-max))
                  (let ((inhibit-read-only t)) (delete-region pai--input-marker (point-max)))
                  (insert text)
                  (nth 2 (pai-arg-completion-at-point)))))
        (should (equal (funcall at "/settings ") '("menu" "set" "get" "edit")))
        (should (member "thinking-level" (funcall at "/settings set ")))
        (should (equal (funcall at "/settings set thinking-level ") pai-thinking-levels))
        (should (equal (funcall at "/settings set preview-tree ") '("true" "false")))
        (should (member "preview-tree" (funcall at "/settings get ")))
        (should-not (funcall at "/settings get preview-tree "))))))

(ert-deftest pai-ui-arg-completion-chains-to-the-next-level ()
  "Accepting an argument inserts a space when more follows, and not otherwise."
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (let ((opened 0))
        (cl-letf (((symbol-function 'pai--maybe-complete-args) (lambda () (cl-incf opened))))
          (goto-char (point-max)) (insert "/settings set")
          (pai--arg-completion-exit "set" 'finished)
          (should (equal (pai--input-text) "/settings set"))
          (should (string-suffix-p "set " (buffer-substring-no-properties pai--input-marker (point-max))))
          (should (= opened 1))
          ;; a final word: nothing inserted, nothing opened
          (let ((inhibit-read-only t)) (delete-region pai--input-marker (point-max)))
          (insert "/settings edit")
          (pai--arg-completion-exit "edit" 'finished)
          (should (string-suffix-p "edit" (buffer-substring-no-properties pai--input-marker (point-max))))
          (should (= opened 1))
          ;; still typing (not finished): nothing happens
          (let ((inhibit-read-only t)) (delete-region pai--input-marker (point-max)))
          (insert "/settings se")
          (pai--arg-completion-exit "se" 'exact)
          (should (= opened 1)))))))

(ert-deftest pai-ui-arg-completion-single-level-does-not-repeat ()
  "A completer that ignores the position (like `/model') completes only the
first argument: accepting a value neither chains nor offers it again."
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-register-command "zz-flat" :handler #'ignore
                            :arg-completions (lambda (_p) '("alpha" "beta")))
      (unwind-protect
          (let ((opened 0))
            (cl-letf (((symbol-function 'pai--maybe-complete-args) (lambda () (cl-incf opened))))
              (goto-char (point-max)) (insert "/zz-flat ")
              (should (equal (nth 2 (pai-arg-completion-at-point)) '("alpha" "beta")))
              (insert "alpha")
              (pai--arg-completion-exit "alpha" 'finished)
              (should (string-suffix-p "alpha" (buffer-substring-no-properties
                                                pai--input-marker (point-max))))
              (should (= opened 0))
              (insert " ")
              (should-not (pai-arg-completion-at-point))))
        (pai-unregister-command "zz-flat")))))

(ert-deftest pai-ui-arg-completion-inactive-without-space ()
  ;; Without a trailing space the argument completion does not fire (the
  ;; command-name completion is still in charge).
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (goto-char (point-max)) (insert "/thinking")
      (should-not (pai-arg-completion-at-point))
      (should (pai-completion-at-point)))))

(ert-deftest pai-ui-arg-completion-none-for-argless-command ()
  ;; A command without registered arg-completions yields no value completion.
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (goto-char (point-max)) (insert "/help ")
      (should-not (pai-arg-completion-at-point)))))

(ert-deftest pai-ui-command-exit-inserts-space ()
  ;; Accepting a command name inserts the trailing space so argument completion
  ;; can start.
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (goto-char (point-max)) (insert "/thinking")
      (pai--command-completion-exit "thinking" 'finished)
      (should (equal (buffer-substring-no-properties pai--input-marker (point)) "/thinking ")))))

(ert-deftest pai-ui-insert-command ()
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (goto-char (point-max)) (insert "partial")
      (pai--insert-command "model")
      (should (equal (pai--input-text) "/model")))))

(ert-deftest pai-ui-complete-command-fallback ()
  ;; With Helm unavailable, `pai-complete-command' uses completing-read.
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (cl-letf (((symbol-function 'require)
                 (lambda (feat &rest _) (unless (eq feat 'helm) (funcall #'featurep feat))))
                ((symbol-function 'completing-read) (lambda (&rest _) "help")))
        (pai-complete-command))
      (should (equal (pai--input-text) "/help")))))

(ert-deftest pai-ui-compact-now-shrinks-context ()
  (pai-faux-reset)
  (pai-faux-push '(:text "## Goal\nSummary here\n## Next Steps\n1. go" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      ;; force a large live context
      (setq pai--context-messages
            (append pai--context-messages
                    (cl-loop for i from 0 below 20 append
                             (list (pai-user-message (make-string 400 ?a))
                                   (pai-assistant-message :content (list (pai-text (make-string 400 ?b))))))))
      (let ((before (length pai--context-messages))
            (pai-settings--global '(:auto-compact t :compact-keep-recent-tokens 50)))
        (pai--compact-now nil)
        (should (< (length pai--context-messages) before))
        ;; a compaction entry was persisted
        (should (seq-find (lambda (e) (equal (plist-get e :type) "compaction"))
                          (pai-session-entries pai--session)))
        (should (string-match-p "Compacted context" (buffer-string)))))))

(defun pai-ui-test--big-context ()
  "Append a large, compactable conversation to the live context."
  (setq pai--context-messages
        (append pai--context-messages
                (cl-loop for i from 0 below 20 append
                         (list (pai-user-message (make-string 400 ?a))
                               (pai-assistant-message :content (list (pai-text (make-string 400 ?b)))))))))

(ert-deftest pai-ui-compact-now-shows-progress ()
  "Compaction announces itself, tracks streamed summary text and cleans up."
  (pai-faux-reset)
  (pai-faux-push '(:text "## Goal\nA summary long enough to count\n## Next Steps\n1. go" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--big-context)
      (let ((pai-settings--global '(:auto-compact t :compact-keep-recent-tokens 50))
            (statuses '()) (ticks 0))
        (cl-letf* ((orig-status (symbol-function 'pai--set-status))
                   (orig-tick (symbol-function 'pai--compaction-tick))
                   ((symbol-function 'pai--set-status)
                    (lambda (s) (push s statuses) (funcall orig-status s)))
                   ((symbol-function 'pai--compaction-tick)
                    (lambda (&rest args) (cl-incf ticks) (apply orig-tick args))))
          (should (pai--compact-now nil 'auto)))
        (should (member "compacting…" statuses))
        (should (equal pai--status "idle"))
        (should (>= ticks 1))
        (should (string-match-p "Compacting context (auto): 4[0-9] messages" (buffer-string)))
        (should (string-match-p "Compacted context.* in [0-9]+s\\." (buffer-string)))
        ;; the activity ran, counted the streamed summary, and is finished
        (let ((entry (car (pai-activity-entries "compaction"))))
          (should entry)
          (should (equal (plist-get entry :status) "completed"))
          (should-not (pai-activity-running "compaction")))))))

(ert-deftest pai-ui-compact-now-abort-cleans-up ()
  "An aborted compaction (C-g, error) leaves the context and indicators clean."
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--big-context)
      (let ((before pai--context-messages))
        (cl-letf (((symbol-function 'pai-compact) (lambda (&rest _) (signal 'quit nil))))
          (should (condition-case nil (progn (pai--compact-now nil) nil) (quit t))))
        (should (eq pai--context-messages before))
        (should (equal pai--status "idle"))
        (should-not (pai-activity-running "compaction"))
        (should (equal (plist-get (car (pai-activity-entries "compaction")) :status) "failed"))
        (should (string-match-p "Compaction aborted" (buffer-string)))))))

(ert-deftest pai-ui-compaction-progress-streams ()
  "The summarizer reports streamed text to `pai-compaction-progress-function'."
  (pai-faux-reset)
  (pai-faux-push '(:text "abcdefgh" :stop-reason stop))
  (let* ((seen "")
         (pai-compaction-progress-function (lambda (d) (setq seen (concat seen d)))))
    (pai-compaction-summarize (list (pai-user-message "x")) (pai-model "faux"))
    (should (equal seen "abcdefgh"))))

(defun pai-ui-test--persisted-turns (n)
  "Append N user/assistant turns to both the live context and the session."
  (dotimes (_ n)
    (dolist (m (list (pai-user-message (make-string 400 ?a))
                     (pai-assistant-message :content (list (pai-text (make-string 400 ?b))))))
      (setq pai--context-messages (append pai--context-messages (list m)))
      (pai-session-append-message pai--session m))))

(defun pai-ui-test--roles-and-texts (messages)
  (mapcar (lambda (m) (list (pai-message-role m) (pai-content-text (pai-message-content m))))
          messages))

(ert-deftest pai-ui-compact-now-is-replayable ()
  "The compaction entry lets a reload rebuild exactly the compacted context."
  (pai-faux-reset)
  (pai-faux-push '(:text "## Goal\nReplay me" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--persisted-turns 10)
      (let ((pai-settings--global '(:auto-compact t :compact-keep-recent-tokens 50)))
        (should (pai--compact-now nil))
        (let ((entry (seq-find (lambda (e) (equal (plist-get e :type) "compaction"))
                               (pai-session-entries pai--session))))
          (should (plist-get entry :firstKeptEntryId))
          (should (plist-get entry :summaryMessage))
          (should (equal (plist-get entry :strategy) "summary")))
        ;; the next turn lands after the compaction
        (let ((m (pai-user-message "after")))
          (setq pai--context-messages (append pai--context-messages (list m)))
          (pai-session-append-message pai--session m))
        (let ((replayed (pai-session-context-messages
                         (pai-session-load (pai-session-file pai--session)))))
          (should (equal (pai-ui-test--roles-and-texts replayed)
                         (pai-ui-test--roles-and-texts pai--context-messages))))))))

(ert-deftest pai-ui-compact-now-unmirrored-context-is-not-replayable ()
  "When the live context does not match the session, no cut point is recorded."
  (pai-faux-reset)
  (pai-faux-push '(:text "## Goal\nx" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      ;; live-only messages: the session holds just the system prompt
      (setq pai--context-messages
            (append pai--context-messages
                    (cl-loop for i from 0 below 10 append
                             (list (pai-user-message (make-string 400 ?a))
                                   (pai-assistant-message :content (list (pai-text (make-string 400 ?b))))))))
      (let ((pai-settings--global '(:auto-compact t :compact-keep-recent-tokens 50)))
        (should (pai--compact-now nil))
        (let ((entry (seq-find (lambda (e) (equal (plist-get e :type) "compaction"))
                               (pai-session-entries pai--session))))
          (should entry)
          (should-not (plist-get entry :firstKeptEntryId)))))))

(ert-deftest pai-ui-compact-extension-takes-over ()
  "A `compact' handler replaces the LLM summary; its strategy is recorded."
  (pai-faux-reset)
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--persisted-turns 3)
      (let ((seen nil))
        (pai-register-extension
         (lambda (pi)
           (pai-ext-on pi 'compact
                       (lambda (event _ctx)
                         (setq seen (plist-get event :reason))
                         (let* ((msgs (plist-get event :messages))
                                (sys (seq-take-while #'pai-system-message-p msgs)))
                           (list :messages (append sys (list (pai-user-message "OBSERVED"))
                                                   (last msgs 2))
                                 :summary "obs" :strategy "observational"))))))
        (should (pai--compact-now nil 'auto))
        (should (eq seen 'auto))
        ;; no LLM call was made
        (should-not pai-faux-last-context)
        (should (equal (pai-content-text (pai-message-content (nth 1 pai--context-messages)))
                       "OBSERVED"))
        (let ((entry (seq-find (lambda (e) (equal (plist-get e :type) "compaction"))
                               (pai-session-entries pai--session))))
          (should (equal (plist-get entry :strategy) "observational"))
          (should (plist-get entry :firstKeptEntryId)))
        (should (string-match-p "Compacted context \\[observational\\]" (buffer-string)))))))

(ert-deftest pai-ui-compact-extension-malformed-falls-back ()
  "A handler result that is not system + summary + kept tail is ignored."
  (pai-faux-reset)
  (pai-faux-push '(:text "## Goal\nfallback" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--persisted-turns 10)
      (pai-register-extension
       (lambda (pi)
         (pai-ext-on pi 'compact
                     ;; drops the system prompt: invalid
                     (lambda (_event _ctx)
                       (list :messages (list (pai-user-message "bad")) :strategy "bad")))))
      (let ((pai-settings--global '(:auto-compact t :compact-keep-recent-tokens 50)))
        (should (pai--compact-now nil))
        (should (pai-system-message-p (car pai--context-messages)))
        (should (string-match-p "fallback" (pai-content-text
                                            (pai-message-content (nth 1 pai--context-messages)))))))))

;;;; Busy spinner

(ert-deftest pai-ui-spinner-animates-while-busy ()
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (should-not pai--spinner-timer)
      (should (string-match-p "\\[idle\\]" (pai--header-line)))
      ;; idle: the spinner's cell is a space, so nothing shifts
      (should (string-prefix-p "  pai" (pai--header-line)))
      (pai--set-status "working…")
      (should (timerp pai--spinner-timer))
      ;; busy: the spinner leads the header; the status stays in brackets
      (should (string-prefix-p "⠋ pai" (pai--header-line)))
      (should (string-match-p "\\[working…\\]" (pai--header-line)))
      ;; each tick shows the next frame
      (let ((pai-spinner-interval 0.01))
        (pai--spinner-stop)
        (pai--spinner-start)
        (let ((deadline (+ (float-time) 2)))
          (while (and (< pai--spinner-index 2) (< (float-time) deadline))
            (accept-process-output nil 0.02))))
      (should (>= pai--spinner-index 2))
      (should-not (string-prefix-p "⠋" (pai--header-line)))
      ;; a working message is animated too
      (setq pai--working-message "reading files")
      (should (string-match-p "\\`[^ ] pai.*\\[reading files\\]" (pai--header-line)))
      (setq pai--working-message nil)
      ;; back to idle: no frame, timer gone
      (pai--set-status "idle")
      (should-not pai--spinner-timer)
      (should (string-match-p "\\[idle\\]" (pai--header-line))))))

(ert-deftest pai-ui-spinner-can-be-disabled ()
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (let ((pai-spinner-frames nil))
        (pai--set-status "working…")
        (should-not pai--spinner-timer)
        (should (string-match-p "\\[working…\\]" (pai--header-line)))
        (pai--set-status "idle")))))

(ert-deftest pai-ui-spinner-stops-with-its-buffer ()
  (pai-ui-test--with-buffer buf dir
    (let (timer)
      (with-current-buffer buf
        (let ((pai-spinner-interval 0.01))
          (pai--set-status "working…")
          (setq timer pai--spinner-timer)))
      (kill-buffer buf)
      (let ((deadline (+ (float-time) 1)))
        (while (and (memq timer timer-list) (< (float-time) deadline))
          (accept-process-output nil 0.02)))
      (should-not (memq timer timer-list)))))

;;;; Usage in the header

(ert-deftest pai-ui-usage-turning-stale-updates-header ()
  "Regression: the same numbers turning stale (only the face changes) must
reach the header; `equal' ignores text properties."
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (let ((pai--model (list :id "m" :provider "p")))
        (cl-letf (((symbol-function 'pai-usage-summary)
                   (lambda (_) (propertize "P 5%" 'face 'pai-usage-stale-face))))
          (setq pai--usage-summary "P 5%")
          (pai--show-usage "p")
          (should (eq (get-text-property 0 'face pai--usage-summary) 'pai-usage-stale-face)))))))

;;;; Header and mode line escaping

(ert-deftest pai-ui-header-and-footer-escape-percent ()
  "`%' in the header or footer is shown literally, not read as a directive.
Regression: \"ctx 325k/1.0M (33%)\" rendered as \"(33\"."
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (setq pai--usage-summary "Claude 5h 18% 7d 85%")
      (pai--set-widget "w" "cache 90%")
      ;; format-mode-line renders nothing in batch, so check the escaping:
      ;; every % reaches the mode-line engine doubled
      (let ((header (pai--header-line-segment))
            (footer (pai--mode-line-segment)))
        (should (string-match-p "([0-9]+%%)" header))
        (should (string-match-p "Claude 5h 18%% 7d 85%%" header))
        (should (string-match-p "cache 90%%" footer))
        (should-not (string-match-p "[^%]%[^%]" (replace-regexp-in-string "%%" "" header))))
      (should (equal header-line-format '(:eval (pai--header-line-segment))))
      (should (equal (pai--mode-line-escape "a%b%%") "a%%b%%%%"))
      (should (equal (pai--mode-line-escape nil) nil)))))

;;;; Footer placement

(defun pai-ui-test--footer-string ()
  "Return the above-prompt footer text, or nil."
  (and (overlayp pai--footer-overlay) (overlay-buffer pai--footer-overlay)
       (overlay-get pai--footer-overlay 'before-string)))

(ert-deftest pai-ui-footer-defaults-to-mode-line ()
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai--set-widget "w" "WIDGET")
      (setq pai--ext-footer "FOOT")
      (should (eq (pai-footer-position) 'mode-line))
      (should (equal (pai--mode-line-segment) " WIDGET  FOOT"))
      (should-not (pai-ui-test--footer-string))
      ;; the mode line carries the segment (format-mode-line is empty in batch)
      (should (member '(:eval (pai--mode-line-segment)) mode-line-format)))))

(ert-deftest pai-ui-footer-above-prompt ()
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai--set-widget "w" "WIDGET")
      ;; setting the position repositions the footer at once (settings hook)
      (pai-settings-set :footer-position "above-prompt" 'project)
      (should (eq (pai-footer-position) 'above-prompt))
      (should (equal (pai--mode-line-segment) ""))
      (should (string-match-p "\\`WIDGET\n\\'" (pai-ui-test--footer-string)))
      (should (= (overlay-start pai--footer-overlay) (pai--prompt-start)))
      (should (eq (get-text-property 0 'face (pai-ui-test--footer-string)) 'pai-footer-face))
      ;; widget and footer changes are redrawn
      (pai--set-widget "x" "MORE")
      (should (string-match-p "MORE" (pai-ui-test--footer-string)))
      (funcall (plist-get (plist-get (pai--ext-context) :ui) :set-footer) "EXTFOOT")
      (should (string-match-p "EXTFOOT" (pai-ui-test--footer-string)))
      ;; nothing to show: no empty line above the prompt
      (pai--set-widget "w" nil) (pai--set-widget "x" nil)
      (funcall (plist-get (plist-get (pai--ext-context) :ui) :set-footer) nil)
      (should-not (pai-ui-test--footer-string))
      (pai--set-widget "w" "BACK")
      (should (pai-ui-test--footer-string))
      ;; back to the mode line
      (pai-settings-set :footer-position "mode-line" 'project)
      (should-not (pai-ui-test--footer-string))
      (should (equal (pai--mode-line-segment) " BACK")))))

(ert-deftest pai-ui-footer-stays-at-prompt ()
  "Transcript output lands above the footer; /new keeps it at the prompt."
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-settings-set :footer-position "above-prompt" 'project)
      (pai--set-widget "w" "WIDGET")
      (pai--render-note "some transcript output")
      (should (= (overlay-start pai--footer-overlay) (pai--prompt-start)))
      (should (< (string-match "some transcript output" (buffer-string))
                 (1- (overlay-start pai--footer-overlay))))
      (pai--init-buffer)
      (should (= (overlay-start pai--footer-overlay) (pai--prompt-start))))))

(ert-deftest pai-ui-footer-sits-below-activity-lines ()
  "The footer overlay outranks other above-prompt blocks, so it is drawn last."
  (require 'pai-activity)
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-settings-set :footer-position "above-prompt" 'project)
      (pai--set-widget "w" "WIDGET")
      (let ((e (pai-activity-start :label "worker")))
        (unwind-protect
            (progn
              (should (overlayp pai-activity--overlay))
              (should (= (overlay-start pai-activity--overlay) (overlay-start pai--footer-overlay)))
              (should (> (overlay-get pai--footer-overlay 'priority)
                         (or (overlay-get pai-activity--overlay 'priority) 0))))
          (pai-activity-finish e)
          (when (timerp pai-activity--timer) (cancel-timer pai-activity--timer)))))))

(ert-deftest pai-ui-new-session-drops-stale-overlays ()
  "Re-entering `pai-mode' (/new) must not leave the old footer/activity overlays behind."
  (require 'pai-activity)
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-settings-set :footer-position "above-prompt" 'project)
      (pai--set-widget "w" "WIDGET")
      (let ((e (pai-activity-start :label "worker")))
        (should (overlayp pai-activity--overlay))
        (when (timerp pai-activity--timer) (cancel-timer pai-activity--timer))
        (pai-mode)
        (should-not (seq-find (lambda (ov) (or (overlay-get ov 'pai-footer)
                                               (overlay-get ov 'pai-activity)))
                              (overlays-in (point-min) (point-max))))
        (ignore e)))))

(ert-deftest pai-ui-compact-command ()
  (pai-faux-reset)
  (pai-faux-push '(:text "summary" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (setq pai--context-messages
            (append pai--context-messages
                    (cl-loop for i from 0 below 10 append
                             (list (pai-user-message (make-string 400 ?a))
                                   (pai-assistant-message :content (list (pai-text (make-string 400 ?b))))))))
      (let ((pai-settings--global '(:auto-compact t :compact-keep-recent-tokens 50)))
        ;; dispatch through the command path
        (pai-ui-test--type-and-send "/compact")
        (should (string-match-p "Compacted context" (buffer-string)))))))

(ert-deftest pai-ui-header-shows-usage ()
  (pai-faux-reset)
  (pai-faux-push '(:text "hi" :usage (:input 100 :output 50 :total-tokens 150 :cache-read 0 :cache-write 0)
                   :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--type-and-send "hello")
      (let ((hl (pai--header-line)))
        (should (string-match-p "ctx" hl))
        ;; a non-local provider always shows dollars; the faux model has no
        ;; price, so the total is a lower bound
        (should (string-match-p "≥\\$0\\.00" hl))))))

(ert-deftest pai-ui-commits-messages-live-during-run ()
  "Context, session and usage update as messages complete, not only at agent-end."
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (let* ((n0 (length pai--context-messages))
             (count-entries (lambda ()
                              (and pai--session
                                   (seq-count (lambda (e) (equal (plist-get e :type) "message"))
                                              (pai-session-entries pai--session)))))
             (e0 (funcall count-entries))
             (tok0 pai--context-tokens)
             (u (pai-user-message (make-string 4000 ?a)))
             (a (pai-assistant-message :content (list (pai-text "ok"))
                                       :usage (pai-usage :input 10 :output 5)
                                       :stop-reason 'tool-use))
             (r (list :role 'tool-result :tool-call-id "t1" :tool-name "x"
                      :content (list (pai-text "res")) :is-error nil)))
        (pai-ui--on-event '(:type agent-start))
        (pai-ui--on-event (list :type 'message-start :message u))
        (pai-ui--on-event (list :type 'message-end :message u))
        (should (= (length pai--context-messages) (1+ n0)))
        (should (> pai--context-tokens tok0))
        (pai-ui--on-event (list :type 'message-start :message a))
        (pai-ui--on-event (list :type 'message-end :message a))
        (should (= (plist-get pai--usage-total :output) 5))
        (pai-ui--on-event (list :type 'turn-end :message a :tool-results (list r)))
        (should (eq (car (last pai--context-messages)) r))
        ;; agent-end must not commit or count anything twice
        (pai-ui--on-event (list :type 'agent-end :messages (list u a r)))
        (should (= (length pai--context-messages) (+ n0 3)))
        (should (= (plist-get pai--usage-total :output) 5))
        (when e0 (should (= (funcall count-entries) (+ e0 3))))))))

(ert-deftest pai-ui-fresh-session-context-tokens-nonzero ()
  "A brand-new session already costs tokens (system prompt + tool schemas)."
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (should (> pai--context-tokens 0))
      (should-not (string-match-p "ctx 0/" (pai--header-line))))))

(ert-deftest pai-ui-renders-markdown-heading ()
  (pai-faux-reset)
  (pai-faux-push '(:text "# Title\n\nsome **bold** text" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--type-and-send "go")
      ;; the heading text carries the markdown heading face somewhere in the buffer
      (should (string-match-p "Title" (buffer-string)))
      (should (cl-loop for pos from (point-min) below (point-max)
                       for f = (get-text-property pos 'face)
                       thereis (or (eq f 'pai-md-heading)
                                   (and (listp f) (memq 'pai-md-heading f))))))))

(ert-deftest pai-ui-name-and-session-commands ()
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--type-and-send "/name My Work")
      (should (equal (pai-session-name pai--session) "My Work"))
      (should (string-match-p "My Work" (buffer-string)))
      (pai-ui-test--type-and-send "/session")
      (should (string-match-p "Messages:" (buffer-string))))))

(ert-deftest pai-ui-new-command-resets ()
  (pai-faux-reset)
  (pai-faux-push '(:text "reply" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--type-and-send "hello")
      (let ((old-id (pai-session-id pai--session)))
        (pai-ui-test--type-and-send "/new")
        (should (not (equal (pai-session-id pai--session) old-id)))
        ;; context is just the system prompt again
        (should (= (length pai--context-messages) 1))))))

(defun pai-ui-test--pai-buffers ()
  "Return all live `pai-mode' buffers."
  (seq-filter (lambda (b) (with-current-buffer b (derived-mode-p 'pai-mode)))
              (buffer-list)))

(ert-deftest pai-ui-clone-command ()
  (pai-faux-reset)
  (pai-faux-push '(:text "reply" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--type-and-send "hello")
      (let ((old-file (pai-session-file pai--session))
            (before (length (pai-ui-test--pai-buffers))))
        (pai-ui-test--type-and-send "/clone")
        ;; the original buffer's session is unchanged
        (should (equal (pai-session-file pai--session) old-file))
        (should (string-match-p "Cloned" (buffer-string)))
        ;; a new pai buffer opened with a different session file
        (let ((new (seq-find (lambda (b)
                               (and (not (eq b buf))
                                    (with-current-buffer b
                                      (not (equal (pai-session-file pai--session) old-file)))))
                             (pai-ui-test--pai-buffers))))
          (should (= (length (pai-ui-test--pai-buffers)) (1+ before)))
          (should new)
          (kill-buffer new))))))

(ert-deftest pai-ui-fork-opens-new-buffer ()
  (pai-faux-reset)
  (pai-faux-push '(:text "a1" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--type-and-send "q1")
      (let ((old-file (pai-session-file pai--session))
            (before (length (pai-ui-test--pai-buffers))))
        ;; fork before the "q1" prompt; completing-read picks it
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "q1")))
          (pai-ui-test--type-and-send "/fork"))
        ;; original buffer untouched
        (should (equal (pai-session-file pai--session) old-file))
        (let ((new (seq-find (lambda (b) (not (eq b buf))) (pai-ui-test--pai-buffers))))
          (should (= (length (pai-ui-test--pai-buffers)) (1+ before)))
          (should new)
          (with-current-buffer new
            ;; context excludes q1 (forked from its parent = system only)
            (should (= (length pai--context-messages) 1))
            ;; the prompt is pre-filled at the input for editing
            (should (equal (pai--input-text) "q1")))
          (kill-buffer new))))))

(ert-deftest pai-ui-tree-spans-whole-tree ()
  (pai-faux-reset)
  (pai-faux-push '(:text "a1" :stop-reason stop) '(:text "a2b" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--type-and-send "first")
      (pai-ui-test--type-and-send "second")
      ;; rewind to "first"; landing keeps its answer ("a1") in context
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_p coll &rest _)
                   (seq-find (lambda (c) (string-match-p "first" c)) (all-completions "" coll)))))
        (pai-ui-test--type-and-send "/tree"))
      (should (seq-find (lambda (m) (and (pai-assistant-message-p m)
                                         (equal (pai-content-text (pai-message-content m)) "a1")))
                        pai--context-messages))
      (pai-ui-test--type-and-send "branchB")
      ;; the whole-tree listing offers BOTH "second" (abandoned) and others,
      ;; with "branchB" nested one level under "first" (depth 1)
      (let* ((triples (pai-session-prompt-tree pai--session))
             (all (mapcar #'cadr triples))
             (depth (lambda (txt) (nth 2 (seq-find (lambda (tr) (equal (cadr tr) txt)) triples)))))
        (should (member "second" all))
        (should (member "branchB" all))
        (should (member "first" all))
        (should (= 0 (funcall depth "first")))
        (should (= 1 (funcall depth "second")))    ; second branched from first
        (should (= 1 (funcall depth "branchB"))))   ; branchB also branched from first
      ;; current-branch listing excludes the abandoned "second"
      (let ((branch (mapcar #'cdr (pai-session-user-prompts pai--session))))
        (should-not (member "second" branch))
        (should (member "branchB" branch)))
      ;; /tree shows the current branch in one column and "second" as a
      ;; side branch under "first", in tree order
      (let (offered)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_p coll &rest _)
                     (setq offered (all-completions "" coll))
                     (should (equal (funcall coll "" nil 'metadata)
                                    '(metadata (display-sort-function . identity)
                                               (cycle-sort-function . identity))))
                     nil)))
          (pai-ui-test--type-and-send "/tree"))
        (should (equal offered '("* first" "  └─ second" "* branchB")))))))

(ert-deftest pai-ui-ext-status-in-header ()
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai--set-ext-status "k" "HELLO-STATUS")
      (should (string-match-p "HELLO-STATUS" (pai--header-line))))))

(ert-deftest pai-ui-ext-message-renderer-override ()
  (pai-faux-reset)
  (pai-faux-push '(:text "original text" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-register-extension
       (lambda (pi)
         (pai-ext-register-message-renderer
          pi (lambda (m) (when (pai-assistant-message-p m) "RENDERED-BY-EXT")))))
      (pai-ui-test--type-and-send "hi")
      (should (string-match-p "RENDERED-BY-EXT" (buffer-string)))
      (should-not (string-match-p "original text" (buffer-string))))))

(ert-deftest pai-ui-ext-markdown-transformer ()
  (pai-faux-reset)
  (pai-faux-push '(:text "hello" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-register-extension
       (lambda (pi)
         (pai-ext-register-markdown-transformer pi (lambda (tx) (concat tx " [xformed]")))))
      (pai-ui-test--type-and-send "hi")
      (should (string-match-p "xformed" (buffer-string))))))

(ert-deftest pai-ui-ext-autocomplete-provider ()
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-register-extension
       (lambda (pi)
         (pai-ext-register-autocomplete-provider pi (lambda (_prefix) '("@alpha" "@beta")))))
      (goto-char (point-max)) (insert "@a")
      (let ((capf (pai-ext-completion-at-point)))
        (should capf)
        (should (member "@alpha" (nth 2 capf)))))))

(ert-deftest pai-ui-ext-shortcut ()
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ext-register-shortcut nil "C-c C-x C-y" #'ignore)
      (should (eq (key-binding (kbd "C-c C-x C-y")) #'ignore)))))

(ert-deftest pai-ui-bang-command-adds-to-context ()
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (let ((before (length pai--context-messages)))
        (pai-ui-test--type-and-send "!echo bang-out")
        (should (string-match-p "bang-out" (buffer-string)))
        (should (> (length pai--context-messages) before))))))

(ert-deftest pai-ui-double-bang-excludes-context ()
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (let ((before (length pai--context-messages)))
        (pai-ui-test--type-and-send "!!echo hidden-out")
        (should (string-match-p "hidden-out" (buffer-string)))
        (should (= (length pai--context-messages) before))))))

(ert-deftest pai-ui-edit-tool-renders-diff ()
  (pai-faux-reset)
  (pai-faux-push '(:tool-calls ((:id "e1" :name "edit"
                                :arguments (:path "f.txt" :edits ((:oldText "b" :newText "BEE")))))
                   :stop-reason tool-use)
                 '(:text "edited" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-temp-file (expand-file-name "f.txt" dir) (insert "a\nb\nc\n"))
    (with-current-buffer buf
      (pai-ui-test--type-and-send "change b to BEE")
      (let ((content (buffer-string)))
        (should (string-match-p "\\+BEE" content))
        (should (string-match-p "-b" content))
        ;; the added line carries the diff-added face
        (should (cl-loop for pos from (point-min) below (point-max)
                         for f = (get-text-property pos 'face)
                         thereis (or (eq f 'pai-diff-added)
                                     (and (listp f) (memq 'pai-diff-added f)))))))))

(ert-deftest pai-ui-mention-expansion ()
  "@file mentions are named, never attached; unknown paths stay plain text."
  (pai-ui-test--with-buffer buf dir
    (with-temp-file (expand-file-name "notes.txt" dir) (insert "SECRET-CONTENT"))
    (make-directory (expand-file-name "sub" dir))
    (with-current-buffer buf
      (let ((expanded (pai--expand-mentions "look at @notes.txt, and @sub please")))
        (should-not (string-match-p "SECRET-CONTENT" expanded))
        (should (string-prefix-p "look at @notes.txt, and @sub please\n\n[Mentioned, not attached" expanded))
        (should (string-match-p "^- file `notes.txt`$" expanded))
        (should (string-match-p "^- directory `sub`$" expanded)))
      ;; @nonexistent is left as-is, with no note
      (should (equal (pai--expand-mentions "hi @nope.xyz") "hi @nope.xyz")))))

(ert-deftest pai-ui-file-mentions-trailing-punctuation-terminates ()
  "Regression: `@file,' followed by more text once looped forever (froze Emacs).
The trailing-punctuation check clobbered the match data the loop advanced by."
  (pai-ui-test--with-buffer buf dir
    (make-directory (expand-file-name "lisp" dir))
    (with-temp-file (expand-file-name "lisp/pai-ui.el" dir) (insert "x"))
    (with-current-buffer buf
      (should (equal (mapcar #'car (pai--find-file-mentions
                                    "show me *todo.org and look at @lisp/pai-ui.el, @lisp/"))
                     '("lisp/pai-ui.el" "lisp/")))
      (should (equal (mapcar #'car (pai--find-file-mentions "@lisp/pai-ui.el, @lisp/pai-ui.el; @nope,"))
                     '("lisp/pai-ui.el"))))))

;;;; /tree and /resume previews

(defun pai-ui-test--prompt-id (text)
  "Return the entry id of the user prompt TEXT in the current session."
  (plist-get (seq-find (lambda (e) (and (equal (plist-get e :type) "message")
                                        (equal (pai-content-text
                                                (plist-get (plist-get e :message) :content))
                                               text)))
                       (pai-session-entries pai--session))
             :id))

(ert-deftest pai-ui-tree-lands-below-the-last-answer ()
  (pai-faux-reset)
  (pai-faux-push '(:text "a1" :stop-reason stop) '(:text "a2" :stop-reason stop)
                 '(:text "a3" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--type-and-send "first")
      (pai-ui-test--type-and-send "second")
      (pai-ui-test--type-and-send "third")
      ;; rendered prompts remember their message
      (should (pai--prompt-position (pai--entry-timestamp (pai-ui-test--prompt-id "second"))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_p coll &rest _)
                   (seq-find (lambda (c) (string-match-p "second" c)) (all-completions "" coll)))))
        (pai-ui-test--type-and-send "/tree"))
      ;; after the rebuild, point is at the input, right below the chosen
      ;; turn's last agent message: that is where the next prompt goes
      (should (= (point) (point-max)))
      (should-not (string-match-p "third" (buffer-string)))
      (let ((before (buffer-substring-no-properties (point-min) (marker-position pai--output-marker))))
        (should (string-match-p "● pai\na2\n+Moved to the selected point in the tree\n*\\'" before))))))

(ert-deftest pai-ui-tree-previews-in-place-or-aside ()
  (pai-faux-reset)
  (pai-faux-push '(:text "a1" :stop-reason stop) '(:text "a2" :stop-reason stop)
                 '(:text "a3" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (set-window-buffer (selected-window) buf)
    (with-current-buffer buf
      (pai-ui-test--type-and-send "first")
      (pai-ui-test--type-and-send "second")
      (let ((first (pai-ui-test--prompt-id "first"))
            (second (pai-ui-test--prompt-id "second")))
        ;; prompts rendered before they were tagged are found by their text
        (let ((tagged (pai--entry-prompt-position first)))
          (let ((inhibit-read-only t))
            (remove-text-properties (point-min) (point-max) '(pai-prompt-ts nil)))
          (should-not (pai--prompt-position (pai--entry-timestamp first)))
          (should (equal (pai--entry-prompt-position first) tagged))
          (should-not (equal (pai--entry-prompt-position second) tagged)))
        ;; a turn on the branch shown: scrolled to its end, right below its
        ;; answer, marked as where the next prompt would go
        (pai--tree-preview first)
        (should (overlayp pai--tree-highlight))
        (let ((pos (overlay-start pai--tree-highlight)))
          (should (= pos (overlay-end pai--tree-highlight)))
          (should (string-match-p "your next prompt goes here"
                                  (overlay-get pai--tree-highlight 'before-string)))
          (should (equal (buffer-substring-no-properties (- pos 3) pos) "a1\n"))
          ;; below the marker: the status note, then the next prompt
          (should (string-prefix-p "\n— ready —\n\n▶ You\nsecond"
                                   (buffer-substring-no-properties pos (+ pos 30))))
          (should (= (window-point (selected-window)) pos)))
        ;; the last turn ends right below its answer, above the status
        (pai--tree-preview second)
        (should (equal (buffer-substring-no-properties
                        (- (overlay-start pai--tree-highlight) 3) (overlay-start pai--tree-highlight))
                       "a2\n"))
        ;; rewind to "first" and branch: "second" is no longer shown
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_p coll &rest _)
                     (seq-find (lambda (c) (string-match-p "first" c)) (all-completions "" coll)))))
          (pai-ui-test--type-and-send "/tree"))
        (pai-ui-test--type-and-send "branchB")
        (should-not (pai--prompt-position (pai--entry-timestamp second)))
        (unwind-protect
            (progn
              (pai--tree-preview second)
              (should-not pai--tree-highlight)
              (let ((text (with-current-buffer pai-preview-buffer-name (buffer-string))))
                (should (string-match-p "not on the branch shown" text))
                (should (string-match-p "▶ You\nsecond" text))
                (should (string-match-p "● pai\na2" text))
                (should-not (string-match-p "branchB" text))))
          ;; cleanup removes the preview and the highlight, restores the window
          (let ((start (window-start)))
            (pai--tree-preview first)
            (pai--tree-preview-cleanup buf (list (cons (selected-window) (cons start (point-max)))))
            (should-not (get-buffer pai-preview-buffer-name))
            (should-not pai--tree-highlight)
            (should (= (window-point (selected-window)) (point-max)))))))))

(ert-deftest pai-ui-resume-previews-sessions ()
  (pai-faux-reset)
  (pai-faux-push '(:text "old answer" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--type-and-send "an old question")
      (pai-ui-test--type-and-send "/new")
      (let (preview offered setting)
        (cl-letf (((symbol-function 'pai-completing-read-preview)
                   (lambda (_prompt choices fn &optional _table _cleanup set)
                     (setq preview fn offered choices setting set)
                     (car (car choices)))))
          (pai-ui-test--type-and-send "/resume"))
        (should (eq preview #'pai-preview-session-file))
        (should (eq setting :preview-resume))
        (should (string-match-p "an old question" (car (car offered))))
        (should (string-match-p "▶ You\nan old question"
                                (pai-preview-session-text (cdr (car offered)))))
        (should (string-match-p "an old question" (buffer-string)))))))

(defmacro pai-ui-test--with-buffers (specs &rest body)
  "Run BODY with buffers SPECS ((NAME . CONTENT) ...) alive, killed afterwards."
  (declare (indent 1))
  `(let ((made (mapcar (lambda (spec)
                         (with-current-buffer (get-buffer-create (car spec))
                           (erase-buffer) (insert (cdr spec)) (current-buffer)))
                       ,specs)))
     (unwind-protect (progn ,@body)
       (let ((kill-buffer-query-functions nil)) (mapc #'kill-buffer made)))))

(ert-deftest pai-ui-buffer-mention-name ()
  "Starred names are written as-is; others get a leading star."
  (should (equal (pai--buffer-mention-name "*scratch*") "*scratch*"))
  (should (equal (pai--buffer-mention-name "pai-ui.el") "*pai-ui.el")))

(ert-deftest pai-ui-find-buffer-mentions ()
  "Mentions match live buffers, longest name first, at word starts only."
  (pai-ui-test--with-buffers '(("*pt log*" . "L") ("*pt log* 2" . "L2") ("pt.el" . "E") ("pt" . "P"))
    (with-temp-buffer
      (let ((names (lambda (text) (mapcar #'buffer-name (pai--find-buffer-mentions text)))))
        ;; spaces in names, starred names written as they are
        (should (equal (funcall names "see *pt log* now") '("*pt log*")))
        (should (equal (funcall names "see *pt log* 2") '("*pt log* 2")))
        ;; plain names get a star; punctuation ends a mention; longest wins
        (should (equal (funcall names "*pt.el, and *pt.") '("pt.el" "pt")))
        ;; repeated mentions attach once
        (should (equal (funcall names "*pt and *pt") '("pt")))
        ;; not at a word start, or no such buffer, or partial name: no mention
        (should-not (funcall names "a*pt.el"))
        (should-not (funcall names "**bold** and *nope*"))
        (should-not (funcall names "*pt.elc"))))))

(ert-deftest pai-ui-buffer-mention-expansion ()
  "*buffer mentions are named with their mode and file, never attached."
  (pai-ui-test--with-buffer buf dir
    (with-temp-file (expand-file-name "notes.txt" dir) (insert "FILE-CONTENT"))
    (pai-ui-test--with-buffers '(("*pt log*" . "BUFFER-CONTENT"))
      (with-current-buffer buf
        (let ((expanded (pai--expand-mentions "compare @notes.txt with *pt log* please")))
          (should-not (string-match-p "FILE-CONTENT\\|BUFFER-CONTENT" expanded))
          (should (string-match-p "read_buffer" expanded))
          ;; files first, then buffers
          (should (string-match-p "^- file `notes.txt`\n- buffer `\\*pt log\\*` (fundamental-mode)$"
                                  expanded)))
        ;; the chat buffer itself is never named
        (should (equal (pai--expand-mentions (concat "*" (buffer-name)))
                       (concat "*" (buffer-name))))))))

(ert-deftest pai-ui-buffer-mention-picker ()
  "`*' opens the picker at word starts only; aborting inserts a plain star."
  (pai-ui-test--with-buffer buf dir
    (pai-ui-test--with-buffers '(("*pt log*" . "x"))
      (with-current-buffer buf
        (let ((noninteractive nil) (asked 0))
          (cl-letf (((symbol-function 'read-buffer)
                     (lambda (&rest _) (cl-incf asked) "*pt log*")))
            (goto-char (point-max))
            (pai-buffer-mention)                   ; start of input
            (insert " and ") (pai-buffer-mention)  ; after a space
            (insert "a") (pai-buffer-mention)      ; mid-word: literal
            (should (= asked 2))
            (should (equal (pai--input-text) "*pt log* and *pt log*a*")))
          (cl-letf (((symbol-function 'read-buffer) (lambda (&rest _) (signal 'quit nil))))
            (insert " ") (pai-buffer-mention)
            (should (string-suffix-p " *" (pai--input-text)))))))))

(ert-deftest pai-ui-buffer-mention-capf ()
  "TAB after `*prefix' completes buffer mentions."
  (pai-ui-test--with-buffer buf dir
    (pai-ui-test--with-buffers '(("*pt log*" . "x") ("pt.el" . "y"))
      (with-current-buffer buf
        (goto-char (point-max))
        (insert "see *pt")
        (pcase-let ((`(,beg ,end ,table . ,_) (pai-buffer-mention-completion-at-point)))
          (should (equal (buffer-substring beg end) "*pt"))
          (should (member "*pt log*" (all-completions "*pt" table)))
          (should (member "*pt.el" (all-completions "*pt" table))))
        ;; not a star token: no completion from this function
        (insert " plain")
        (should-not (pai-buffer-mention-completion-at-point))))))

(ert-deftest pai-ui-buffer-ref-ranges ()
  "`*name:N' and `*name:N-M' reference lines; the note says so."
  (pai-ui-test--with-buffers '(("*pt log*" . "a\nb\nc") ("pt.el" . "x"))
    (with-temp-buffer
      (should (equal (mapcar (lambda (r) (cons (buffer-name (car r)) (cdr r)))
                             (pai--find-buffer-refs "see *pt log*:2-3, *pt.el:7 and *pt.el"))
                     '(("*pt log*" . (2 . 3)) ("pt.el" . (7 . 7)) ("pt.el"))))
      ;; a range glued to more text is not a reference
      (should-not (pai--find-buffer-refs "*pt.el:7x"))
      (let ((note (pai--expand-mentions "fix *pt log*:2-3")))
        (should (string-match-p "^- lines 2-3 of buffer `\\*pt log\\*` (fundamental-mode)$" note))))))

(ert-deftest pai-ui-previous-buffer-not-in-prompt ()
  "Nothing about the previous buffer is added to what is sent."
  (with-temp-buffer
    (should (equal (pai--expand-mentions "explain this") "explain this"))))

(ert-deftest pai-ui-recent-buffers-tool ()
  "Sending records the previous buffer; recent_buffers returns the record."
  (pai-ui-test--with-buffer buf dir
    (pai-ui-test--with-buffers '(("pt.el" . "one\ntwo\nthree\nfour") ("pt-other" . "o"))
      (let ((result nil)
            (run (lambda () (with-current-buffer buf
                              (pai-refs--recent-buffers-execute nil nil nil
                                                                (lambda (r) (setq result r)))
                              (pai-content-text (plist-get result :content))))))
        ;; nothing sent yet
        (should (string-match-p "Nothing recorded" (funcall run)))
        (with-current-buffer "pt.el"
          (transient-mark-mode 1)
          (goto-char (point-min)) (forward-line 1)
          (push-mark (point) t t)
          (forward-line 2))
        (switch-to-buffer "pt-other")
        (switch-to-buffer "pt.el")
        (with-current-buffer buf
          (switch-to-buffer buf)
          (pai-refs-record-focus))
        (let ((text (funcall run)))
          (should (string-match-p "^Previous buffer .*: buffer `pt.el` (fundamental-mode), point on line 4, lines 2-3 selected$" text))
          ;; pt.el visits no file, so no last-file line unless one exists
          (should (string-match-p "`pt-other`" text)))
        ;; turned off: nothing is recorded
        (with-current-buffer buf
          (setq pai--focus-record nil)
          (let ((pai-record-previous-buffer nil)) (pai-refs-record-focus)))
        (should (string-match-p "Nothing recorded" (funcall run)))))))

(ert-deftest pai-ui-previous-buffer-skips-noise ()
  "pai sessions, internal and ignored buffers are never the previous buffer."
  (pai-ui-test--with-buffers '(("pt-real.txt" . "x") ("*helm pt*" . "h") (" pt-internal" . "i"))
    (with-temp-buffer
      ;; most recent first: internal, helm, then the real one
      (switch-to-buffer "pt-real.txt")
      (switch-to-buffer "*helm pt*")
      (switch-to-buffer " pt-internal")
      (switch-to-buffer (current-buffer))
      (should (equal (buffer-name (pai-previous-buffer)) "pt-real.txt")))))

(ert-deftest pai-ui-add-to-prompt ()
  "C-c i adds the selected lines, or the whole buffer, to the session's prompt."
  (pai-ui-test--with-buffer buf dir
    (pai-ui-test--with-buffers '(("pt.el" . "one\ntwo\nthree\n"))
      (with-current-buffer buf (goto-char (point-max)) (insert "look at"))
      (with-current-buffer "pt.el"
        (setq default-directory dir)
        (emacs-lisp-mode)
        (transient-mark-mode 1)
        ;; whole buffer
        (pai-add-to-prompt)
        (should (equal (with-current-buffer buf (pai--input-text)) "look at *pt.el"))
        ;; selected lines 2-3 (region ending at a line start excludes that line)
        (goto-char (point-min)) (forward-line 1) (push-mark (point) t t) (forward-line 2)
        (pai-add-to-prompt)
        (should-not (region-active-p))
        (should (equal (with-current-buffer buf (pai--input-text)) "look at *pt.el *pt.el:2-3"))
        ;; a region inside one line references that line
        (goto-char (point-min)) (push-mark (point) t t) (end-of-line)
        (pai-add-to-prompt)
        (should (equal (with-current-buffer buf (pai--input-text))
                       "look at *pt.el *pt.el:2-3 *pt.el:1"))))))

(ert-deftest pai-ui-add-to-prompt-needs-session ()
  "Without a pai session C-c i says so instead of doing anything."
  (cl-letf (((symbol-function 'pai-refs-target) (lambda (&rest _) nil)))
    (with-temp-buffer
      (should-error (pai-add-to-prompt) :type 'user-error))))

(ert-deftest pai-ui-read-buffer-range ()
  "read_buffer honours offset/limit and reports the range."
  (pai-ui-test--with-buffers '(("pt.el" . "l1\nl2\nl3\nl4\nl5"))
    (let (result)
      (pai-tool-read-buffer--execute '(:name "pt.el" :offset 2 :limit 2) nil nil
                                     (lambda (r) (setq result r)))
      (should (equal (pai-content-text (plist-get result :content))
                     "l2\nl3\n[showing lines 2-3 of 5; use offset/limit to page]"))
      (pai-tool-read-buffer--execute '(:name "pt.el") nil nil (lambda (r) (setq result r)))
      (should (equal (pai-content-text (plist-get result :content)) "l1\nl2\nl3\nl4\nl5")))))

(ert-deftest pai-ui-hotkeys-and-clear ()
  (pai-faux-reset)
  (pai-faux-push '(:text "hi" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--type-and-send "hello")
      (should (string-match-p "hello" (buffer-string)))
      (pai-ui-test--type-and-send "/hotkeys")
      (should (string-match-p "Keybindings" (buffer-string)))
      (pai-ui-test--type-and-send "/clear")
      (should-not (string-match-p "hello" (buffer-string))))))

(ert-deftest pai-ui-import-command ()
  (pai-ui-test--with-buffer buf dir
    (let ((file (make-temp-file "pai-imp" nil ".jsonl")))
      (unwind-protect
          (let ((s (pai-session-new dir file)))
            (pai-session-append-message s (pai-user-message "imported-q"))
            (pai-session-append-message s (pai-assistant-message :content (list (pai-text "imported-a"))))
            (with-current-buffer buf
              (pai-ui-test--type-and-send (concat "/import " file))
              (should (string-match-p "imported-q" (buffer-string)))
              (should (string-match-p "imported-a" (buffer-string)))))
        (ignore-errors (delete-file file))))))

(ert-deftest pai-oneshot-headless ()
  (pai-faux-reset)
  (pai-faux-push '(:text "oneshot-reply" :stop-reason stop))
  (let* ((dir (make-temp-file "pai-headless-" t))
         (pai-directory (expand-file-name ".pai" dir))
         (pai-default-model "faux"))
    (unwind-protect
        (should (equal (pai-oneshot "hi" nil dir) "oneshot-reply"))
      (delete-directory dir t))))

(ert-deftest pai-ui-prompt-pinned-at-bottom ()
  ;; The input prompt stays on the buffer's last line after a full exchange,
  ;; with all transcript output rendered above it.
  (pai-faux-reset)
  (pai-faux-push '(:text "a reply spanning\nseveral lines\nof text" :stop-reason stop))
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-ui-test--type-and-send "hello there")
      ;; last line is the prompt (optionally followed by typed input)
      (goto-char (point-max))
      (should (save-excursion (beginning-of-line)
                              (looking-at-p (regexp-quote pai-prompt-string))))
      ;; a fresh draft goes after the prompt, still on the last line
      (insert "next command")
      (should (equal (pai--input-text) "next command"))
      ;; the reply text is above the input marker (in the transcript region)
      (should (< (save-excursion (goto-char (point-min))
                                 (search-forward "several lines" nil t))
                 (marker-position pai--input-marker))))))

(ert-deftest pai-ui-scroll-settings-terminal-like ()
  ;; pai-mode configures comint-style follow scrolling so the prompt is pinned
  ;; to the bottom of the window rather than recentering with a jump.
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (should (= scroll-conservatively 101))
      (should (= scroll-margin 0)))))

(ert-deftest pai-ui-follow-input-no-window ()
  ;; The follow helper must be a harmless no-op when the buffer has no window.
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (should-not (get-buffer-window buf))
      (should-not (pai--follow-input)))))

(ert-deftest pai-ui-settings-menu-defined ()
  ;; The vui settings screen entry point is a real command and the /menu slash
  ;; command is registered and routed to it.
  (should (commandp 'pai-settings-ui-open))
  (should (fboundp 'pai-settings-menu-command))
  (should (pai-command-get "menu")))

(ert-deftest pai-ui-settings-menu-readers ()
  ;; The value readers used for the menu descriptions return sane defaults.
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (should (stringp (pai--menu-current-model)))
      (should (member (pai--menu-current-thinking) pai-thinking-levels)))))

(ert-deftest pai-ui-goto-dwim-split-path ()
  ;; The path:line:col parser handles bare paths, file:line, and file:line:col.
  (should (equal (pai--split-path-line-col "a/b.el") '("a/b.el" nil nil)))
  (should (equal (pai--split-path-line-col "a/b.el:12") '("a/b.el" 12 nil)))
  (should (equal (pai--split-path-line-col "a/b.el:12:3") '("a/b.el" 12 3))))

(ert-deftest pai-ui-goto-dwim-detects-file-ref ()
  ;; A project-relative file:line reference in the transcript resolves to the
  ;; real file, with the line number parsed out (grep-style).
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (let ((rel "notes/todo.el"))
        (make-directory (expand-file-name "notes" dir) t)
        (with-temp-file (expand-file-name rel dir) (insert "line1\nline2\nline3\n"))
        (goto-char (point-max))
        (let ((inhibit-read-only t)) (insert (format "see %s:2 for details" rel)))
        (goto-char (point-max))
        (search-backward "notes/todo")
        (let ((loc (pai--location-at-point)))
          (should (eq (plist-get loc :type) 'file))
          (should (equal (file-truename (plist-get loc :path))
                         (file-truename (expand-file-name rel dir))))
          (should (= (plist-get loc :line) 2)))))))

(ert-deftest pai-ui-goto-dwim-opens-file-at-line ()
  ;; `pai-goto-dwim' opens the referenced file and moves point to the line.
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (let ((rel "a.txt"))
        (with-temp-file (expand-file-name rel dir) (insert "one\ntwo\nthree\n"))
        (goto-char (point-max))
        (let ((inhibit-read-only t)) (insert (format "%s:3" rel)))
        (search-backward "a.txt")
        (save-window-excursion
          (pai-goto-dwim t)                 ; HERE = reuse window (batch-safe)
          (should (equal (file-truename (buffer-file-name))
                         (file-truename (expand-file-name rel dir))))
          (should (= (line-number-at-pos) 3))
          (kill-buffer))))))

(ert-deftest pai-ui-goto-dwim-detects-buffer-name ()
  ;; A live buffer name in the transcript is detected as a buffer location.
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (goto-char (point-max))
      (let ((inhibit-read-only t)) (insert "buffer *scratch* is open"))
      (search-backward "scratch")
      (let ((loc (pai--location-at-point)))
        (should (eq (plist-get loc :type) 'buffer))
        (should (equal (plist-get loc :buffer) "*scratch*"))))))

(ert-deftest pai-ui-goto-dwim-detects-url ()
  ;; A URL in the transcript is detected as a URL location.
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (goto-char (point-max))
      (let ((inhibit-read-only t)) (insert "docs at https://example.com/path here"))
      (search-backward "example")
      (let ((loc (pai--location-at-point)))
        (should (eq (plist-get loc :type) 'url))
        (should (string-prefix-p "https://example.com" (plist-get loc :url)))))))

(ert-deftest pai-ui-goto-dwim-none-at-point ()
  ;; With nothing resolvable at point, the command signals a user-error.
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (goto-char (point-max))
      (let ((inhibit-read-only t)) (insert "just some prose zzz"))
      (search-backward "zzz")
      (should-error (pai-goto-dwim) :type 'user-error))))

(ert-deftest pai-ui-model-selection-persists-provider-identity ()
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (pai-register-model (pai-make-model :id "shared" :provider "one"))
      (pai-register-model (pai-make-model :id "shared" :provider "two"))
      (progn
        (pai-set-model "two/shared")
        (should (equal (pai-model-provider pai--model) "two"))
        (pai-settings-load dir)
        (should (equal (pai-settings-get :model) "two/shared"))
        (should (string-match-p "two/shared" (pai--header-line)))))))

(ert-deftest pai-ui-no-model-keeps-configuration-commands-usable ()
  (pai-ui-test--with-buffer buf dir
    (let ((pai--models (make-hash-table :test 'equal))
          (pai--providers (make-hash-table :test 'equal))
          (pai-default-model nil))
      (with-current-buffer buf
        (setq pai--model nil)
        (should-error (pai--start-run "hello") :type 'user-error)
        (should-not pai--active)
        (should-error (pai--compact-now nil) :type 'user-error)
        (pai-ui-test--type-and-send "/model")
        (should-not pai--active)
        (should-not pai--model)))))

;;;; Input history (M-p / M-n)

(ert-deftest pai-ui-test-history-browse ()
  "Prompts and commands are recorded per project and browsed with M-p/M-n."
  (pai-ui-test--with-buffer buf dir
    (with-current-buffer buf
      (dolist (in '("first prompt" "/hotkeys" "!!true"))
        (goto-char (point-max)) (insert in) (pai-send t))
      ;; Programmatic sends are not recorded.
      (goto-char (point-max)) (insert "/hotkeys") (pai-send)
      (should (equal (pai-history-load dir) '("!!true" "/hotkeys" "first prompt")))
      (goto-char (point-max)) (insert "draft")
      (pai-history-previous)
      (should (equal (pai--input-text) "!!true"))
      (pai-history-previous)
      (should (equal (pai--input-text) "/hotkeys"))
      (pai-history-previous)
      (should (equal (pai--input-text) "first prompt"))
      (pai-history-previous)                ; at the oldest: stays put
      (should (equal (pai--input-text) "first prompt"))
      (pai-history-next)
      (pai-history-next)
      (should (equal (pai--input-text) "!!true"))
      (pai-history-next)                    ; past the newest: draft restored
      (should (equal (pai--input-text) "draft"))
      (should-not pai--history-index)
      (should (eq (key-binding (kbd "M-p")) #'pai-history-previous))
      (should (eq (key-binding (kbd "M-n")) #'pai-history-next)))))

(ert-deftest pai-ui-test-history-dedup-and-project-scope ()
  "Re-submitting moves an entry to the front; other projects are separate."
  (pai-ui-test--with-buffer buf dir
    (pai-history-add dir "a")
    (pai-history-add dir "b")
    (pai-history-add dir "a")
    (should (equal (pai-history-load dir) '("a" "b")))
    (should-not (pai-history-load (expand-file-name "other" dir)))
    (let ((pai-history-size 2))
      (pai-history-add dir "multi\nline")
      (should (equal (pai-history-load dir) '("multi\nline" "a"))))))

(provide 'pai-ui-test)
;;; pai-ui-test.el ends here
