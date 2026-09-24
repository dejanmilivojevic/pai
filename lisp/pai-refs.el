;;; pai-refs.el --- Refer to buffers, regions and "this" from any buffer -*- lexical-binding: t; -*-

;;; Commentary:

;; Two ways of pointing pai at what you are working on, without pasting it:
;;
;; 1. `pai-add-to-prompt' (\\`C-c i' from any buffer): adds a reference to
;;    the current buffer -- or, with an active region, to the lines it
;;    covers (`*todo.org:3-5') -- to the prompt of the pai session.  You stay
;;    where you are, so you can collect several references.
;;
;; 2. "This".  When you send a prompt, pai records -- without adding
;;    anything to the prompt -- the buffer you were in just before the pai
;;    buffer (with where point was and any selected region), the last file
;;    you visited and a few other recent buffers.  The `recent_buffers' tool
;;    returns that record, so the model looks it up only when you say
;;    "explain this", "fix this function" or "what does the last file do".
;;
;; Like @file and *buffer mentions these are references: the model is told
;; *what* you mean and reads what it needs with `read' / `read_buffer'.
;;
;; Everything here is bounded and synchronous only on small data (buffer
;; names, a few line numbers); nothing blocks.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-tools)

(defvar pai--input-marker)
(declare-function pai--buffer-mention-name "pai-ui" (name))

(defgroup pai-refs nil
  "Referring to buffers, regions and the previous buffer from pai."
  :group 'pai)

(defcustom pai-record-previous-buffer t
  "Whether sending a prompt records the buffers you were just in.
The record is only read on demand, through the `recent_buffers' tool, to
resolve \"this\", \"this file\", \"the last buffer\"; it is never added
to the prompt."
  :type 'boolean :group 'pai-refs)

(defcustom pai-recent-buffers-count 5
  "How many other recent buffers `recent_buffers' lists."
  :type 'integer :group 'pai-refs)

(defcustom pai-previous-buffer-ignore-regexp
  "\\`\\(?:\\*pai[ :]\\|\\*[Hh]elm\\|\\*Completions\\*\\|\\*Backtrace\\*\\|\\*which-key\\)"
  "Buffers whose names match this are never taken as the previous buffer.
Internal buffers (names starting with a space) and pai sessions are always
skipped."
  :type 'regexp :group 'pai-refs)

;;;; The previous buffer

(defvar-local pai--focus-record nil
  "Text describing where the user was when they last sent a prompt here.
Set by `pai-refs-record-focus'; read by the `recent_buffers' tool.")

(defun pai-refs--candidate-p (buffer)
  "Return non-nil when BUFFER can be the user's previous buffer."
  (and (buffer-live-p buffer)
       (let ((name (buffer-name buffer)))
         (and (not (string-prefix-p " " name))
              (not (string-match-p pai-previous-buffer-ignore-regexp name))
              (not (provided-mode-derived-p
                    (buffer-local-value 'major-mode buffer) 'pai-mode))
              (not (minibufferp buffer))))))

(defun pai-previous-buffer ()
  "Return the buffer the user was in before the current one, or nil.
Uses the frame's buffer order, which Emacs keeps by recency of selection."
  (seq-find (lambda (b) (and (not (eq b (current-buffer))) (pai-refs--candidate-p b)))
            (buffer-list (selected-frame))))

(defun pai-previous-file-buffer (&optional except)
  "Return the most recent file-visiting buffer other than EXCEPT, or nil."
  (seq-find (lambda (b) (and (not (eq b except)) (not (eq b (current-buffer)))
                             (buffer-file-name b) (pai-refs--candidate-p b)))
            (buffer-list (selected-frame))))

(defun pai-refs--lines (beg end)
  "Return (FIRST . LAST), the lines spanned by BEG..END in this buffer.
A region ending at the start of a line does not include that line."
  (let* ((first (line-number-at-pos beg t))
         (last (line-number-at-pos (if (and (> end beg)
                                            (save-excursion (goto-char end) (bolp)))
                                       (1- end)
                                     end)
                                   t)))
    (cons first (max first last))))

(defun pai-refs--range-string (range)
  "Return RANGE (FIRST . LAST) as \"N\" or \"N-M\"."
  (if (= (car range) (cdr range))
      (number-to-string (car range))
    (format "%d-%d" (car range) (cdr range))))

(defun pai-refs-describe-buffer (buffer)
  "Return \"buffer `NAME` (MODE, visiting FILE)\" for BUFFER."
  (with-current-buffer buffer
    (format "buffer `%s` (%s%s)" (buffer-name) major-mode
            (if buffer-file-name
                (format ", visiting %s" (abbreviate-file-name buffer-file-name))
              ""))))

(defun pai-refs--position-note (buffer)
  "Return where point and any active region are in BUFFER."
  (with-current-buffer buffer
    (let ((window (get-buffer-window buffer t)))
      (let ((pt (if window (window-point window) (point))))
        (concat (format ", point on line %d" (line-number-at-pos pt t))
                (when (and (region-active-p) (mark t))
                  (format ", lines %s selected"
                          (pai-refs--range-string
                           (pai-refs--lines (min pt (mark t)) (max pt (mark t)))))))))))

(defun pai-refs-focus-text ()
  "Describe where the user is coming from, for the `recent_buffers' tool.
Call it in the pai buffer at the moment a prompt is sent."
  (let* ((previous (pai-previous-buffer))
         (file (and previous (not (buffer-file-name previous))
                    (pai-previous-file-buffer previous)))
         (others (seq-take (seq-filter (lambda (b) (and (not (memq b (list previous file)))
                                                        (not (eq b (current-buffer)))
                                                        (pai-refs--candidate-p b)))
                                       (buffer-list (selected-frame)))
                           pai-recent-buffers-count)))
    (when previous
      (string-join
       (delq nil
             (list (concat "Previous buffer (where the user was right before sending the prompt): "
                           (pai-refs-describe-buffer previous)
                           (pai-refs--position-note previous))
                   (when file
                     (concat "Last file visited: " (pai-refs-describe-buffer file)))
                   (when others
                     (concat "Other recent buffers, most recent first: "
                             (mapconcat (lambda (b) (format "`%s`" (buffer-name b))) others ", ")))))
       "\n"))))

(defun pai-refs-record-focus ()
  "Record, in this pai buffer, where the user was as they send a prompt."
  (when pai-record-previous-buffer
    (setq pai--focus-record (pai-refs-focus-text))))

(defun pai-refs--recent-buffers-execute (_args _ctx _on-update on-done)
  "Execute the `recent_buffers' tool, finishing through ON-DONE."
  (funcall on-done
           (pai-tool-ok-result
            (or pai--focus-record
                "Nothing recorded: no prompt was sent by the user from this session yet."))))

(pai-register-tool
 (list :name "recent_buffers"
       :label "Recent buffers"
       :description (concat
                     "Return the Emacs buffer the user was in right before sending their latest "
                     "prompt (with the cursor line and any selected lines), the last file they "
                     "visited and other recent buffers.  Call it when the user refers to something "
                     "without naming it -- \"this\", \"that\", \"here\", \"this file/function\", "
                     "\"the last file/buffer\" -- then read what you need with read / read_buffer.")
       :prompt-snippet "recent_buffers: find what \"this\" / \"the last file\" refers to"
       :deferred nil
       :parameters (pai-object-schema nil)
       :execute #'pai-refs--recent-buffers-execute))

;;;; Adding references from any buffer

(defun pai-refs--session-p (buffer)
  "Return non-nil when BUFFER is a top-level pai session (not a subagent)."
  (with-current-buffer buffer
    (and (derived-mode-p 'pai-mode)
         (markerp pai--input-marker)
         (not (bound-and-true-p pai-isub--parent)))))

(defun pai-refs-target (&optional from)
  "Return the pai session that references from buffer FROM should go to.
Prefers, in order: a visible session for FROM's project, any session for
that project, a visible session, the most recently used session."
  (let* ((from (or from (current-buffer)))
         (dir (with-current-buffer from
                (expand-file-name (or (and buffer-file-name (file-name-directory buffer-file-name))
                                      default-directory))))
         (sessions (seq-filter #'pai-refs--session-p (buffer-list)))
         (mine (seq-filter (lambda (b)
                             (string-prefix-p (expand-file-name
                                               (buffer-local-value 'default-directory b))
                                              dir))
                           sessions))
         (visible (lambda (b) (get-buffer-window b 'visible))))
    (or (seq-find visible mine) (car mine) (seq-find visible sessions) (car sessions))))

(defun pai-refs--insert-into (target text)
  "Append TEXT to TARGET's prompt, separated from what is already there."
  (with-current-buffer target
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (unless (or (= (point) pai--input-marker)
                    (memq (char-before) '(?\s ?\t ?\n)))
          (insert " "))
        (insert text)))
    ;; Keep the session's own cursor at the end of its prompt.
    (dolist (window (get-buffer-window-list target nil t))
      (set-window-point window (point-max)))))

;;;###autoload
(defun pai-add-to-prompt ()
  "Add this buffer, or the selected lines, to the pai prompt as a reference.
With a region selected this adds `*BUFFER:FIRST-LAST', the lines the region
covers; without one it adds `*BUFFER', the whole buffer (the file it
visits, if any, is named when the prompt is sent).  Nothing is pasted: the
model is told what the reference is and reads what it needs.  You stay in
this buffer, so you can add several references before switching to pai.

The prompt used is the pai session for this buffer's project, preferring
a visible one (see `pai-refs-target')."
  (interactive)
  (let ((target (or (pai-refs-target) (user-error "No pai session is open")))
        (buffer (current-buffer)))
    (when (eq target buffer) (user-error "This is the pai session itself"))
    (when (string-prefix-p " " (buffer-name))
      (user-error "Internal buffers cannot be referenced"))
    (let* ((range (and (use-region-p) (pai-refs--lines (region-beginning) (region-end))))
           (ref (concat (pai--buffer-mention-name (buffer-name))
                        (if range (concat ":" (pai-refs--range-string range)) ""))))
      (pai-refs--insert-into target ref)
      (when range (deactivate-mark))
      (message "Added %s to %s" ref (buffer-name target)))))

(defcustom pai-add-to-prompt-key "C-c i"
  "Global key for `pai-add-to-prompt', or nil for none.
Set it with `customize' (or `setopt') so the binding is updated."
  :type '(choice (const :tag "None" nil) key-sequence)
  :group 'pai-refs
  :set (lambda (symbol value)
         (when (and (boundp symbol) (symbol-value symbol)
                    (eq (global-key-binding (kbd (symbol-value symbol))) #'pai-add-to-prompt))
           (global-unset-key (kbd (symbol-value symbol))))
         (set-default symbol value)
         (when value (global-set-key (kbd value) #'pai-add-to-prompt))))

(provide 'pai-refs)
;;; pai-refs.el ends here
