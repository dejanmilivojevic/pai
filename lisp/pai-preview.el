;;; pai-preview.el --- Live previews while choosing in the minibuffer -*- lexical-binding: t; -*-

;;; Commentary:

;; `pai-completing-read-preview' is `completing-read' over an alist of
;; (LABEL . VALUE) that calls a preview function with the VALUE of the
;; candidate currently selected, as you move -- in helm, vertico, icomplete
;; or the default minibuffer.  Previews run from a short idle timer, so
;; moving quickly through the list never waits for one.
;;
;; `pai-preview-session-file' and `pai-preview-messages' render a quick,
;; read-only view of a conversation in a side window:
;;   * a session file is read from its END only (`pai-preview-tail-bytes'),
;;     and its current branch followed back from the last entry, so even a
;;     multi-megabyte session previews at once; results are cached by
;;     file size and modification time;
;;   * the last `pai-preview-max-messages' messages are shown like the
;;     transcript: "▶ You", "● pai", tool calls and results as one-liners.
;;
;; Used by /resume (preview a session) and /tree (show where a point in the
;; tree is, see pai-ui).  Each picker has its own on/off setting
;; (`:preview-resume', `:preview-tree' in settings.json, also in /menu);
;; `pai-preview-toggle-key' (C-c C-f, like helm's follow mode) flips it
;; while choosing, and the choice is saved.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'pai-core)
(require 'pai-session)
(require 'pai-markdown)
(require 'pai-settings)

(defvar helm-alive-p)
;; special, so the `let' in `pai-completing-read-preview' binds them dynamically
(defvar helm-move-selection-after-hook)
(defvar helm-after-update-hook)
(declare-function helm-get-selection "helm-core" (&optional buffer force-display-part source))
(declare-function vertico--candidate "vertico" (&optional hl))

(defgroup pai-preview nil
  "Live previews while choosing sessions and tree points."
  :group 'pai)

(defcustom pai-preview-enabled t
  "Nil to never preview while choosing (overrides the per-picker settings).
Each picker is switched on and off with its own setting (`:preview-resume',
`:preview-tree'), from /menu or with `pai-preview-toggle-key' while choosing."
  :type 'boolean
  :group 'pai-preview)

(defcustom pai-preview-toggle-key "C-c C-f"
  "Key that turns the preview on or off while choosing; the choice is saved."
  :type 'string
  :group 'pai-preview)

(defcustom pai-preview-delay 0.12
  "Idle seconds after moving to a candidate before it is previewed."
  :type 'number
  :group 'pai-preview)

(defcustom pai-preview-max-messages 30
  "How many of a conversation's last messages a preview shows."
  :type 'integer
  :group 'pai-preview)

(defcustom pai-preview-tail-bytes 600000
  "How much of the end of a session file a preview reads."
  :type 'integer
  :group 'pai-preview)

(defcustom pai-preview-window-width 0.45
  "Width of the preview side window, as a fraction of the frame."
  :type 'number
  :group 'pai-preview)

(defconst pai-preview-buffer-name "*pai preview*"
  "Name of the preview buffer.")

;;;; Reading a session's tail

(defun pai-preview--tail-entries (file)
  "Return the entries of the current branch found in the tail of session FILE.
Oldest first.  Only the last `pai-preview-tail-bytes' are read; the branch
is followed back from the last entry through :parentId while the parents
are in that tail.  Also return whether the start of the file was reached,
as (ENTRIES . COMPLETE)."
  (let* ((size (or (file-attribute-size (file-attributes file)) 0))
         (beg (max 0 (- size pai-preview-tail-bytes)))
         (by-id (make-hash-table :test 'equal))
         (last nil))
    (with-temp-buffer
      (set-buffer-multibyte t)
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents file nil beg size))
      (goto-char (point-min))
      ;; a partial first line (we started mid-file) is skipped
      (when (> beg 0) (forward-line 1))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties (point) (line-end-position))))
          (unless (string-empty-p (string-trim line))
            (let ((e (ignore-errors (pai-json-decode line))))
              (when (and (consp e) (plist-get e :id))
                (puthash (plist-get e :id) e by-id)
                (setq last e)))))
        (forward-line 1)))
    (let ((path '()) (e last))
      (while e
        (push e path)
        (setq e (let ((p (plist-get e :parentId))) (and (stringp p) (gethash p by-id)))))
      (cons path (= beg 0)))))

(defun pai-preview--entries-messages (entries)
  "Return the non-system messages of session ENTRIES."
  (seq-remove (lambda (m) (or (null m) (pai-system-message-p m)))
              (mapcar (lambda (e)
                        (if (equal (plist-get e :type) "compaction")
                            (pai-user-message
                             (concat "[earlier conversation compacted] "
                                     (truncate-string-to-width
                                      (or (plist-get e :summary) "") 300 nil nil "…")))
                          (ignore-errors (pai-session--entry-to-message e))))
                      entries)))

;;;; Rendering

(defun pai-preview--one-line (text width)
  "Return TEXT squeezed to one line of at most WIDTH characters."
  (truncate-string-to-width
   (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (or text "")))
   width nil nil "…"))

(defun pai-preview--insert-message (m)
  "Insert message M, transcript-style, at point."
  (pcase (pai-message-role m)
    ('user
     (insert (propertize "\n▶ You\n" 'face 'pai-user-face))
     (insert (pai-md-highlight-fences
              (string-trim-right (pai-content-text (pai-message-content m))))
             "\n"))
    ('assistant
     (insert (propertize "\n● pai\n" 'face 'pai-assistant-header-face))
     (dolist (block (pai-normalize-content (pai-message-content m)))
       (pcase (pai-block-type block)
         ('text
          (let ((tx (string-trim (or (plist-get block :text) ""))))
            (unless (string-empty-p tx)
              (insert (pai-format-markdown (pai-md-highlight-fences tx)) "\n"))))
         ('tool-call
          (insert (propertize
                   (format "  ⚙ %s %s\n" (or (plist-get block :name) "tool")
                           (pai-preview--one-line (pai-json-encode (plist-get block :arguments)) 90))
                   'face 'shadow))))))
    ('tool-result
     (insert (propertize
              (format "  %s %s\n" (if (eq (plist-get m :is-error) t) "✗" "↳")
                      (pai-preview--one-line (pai-content-text (pai-message-content m)) 90))
              'face (if (eq (plist-get m :is-error) t) 'error 'shadow))))
    (_ nil)))

(defun pai-preview-render (title messages &optional note)
  "Return a preview string: TITLE, an optional NOTE, then the last MESSAGES."
  (let* ((n (length messages))
         (shown (last messages pai-preview-max-messages)))
    (with-temp-buffer
      (insert (propertize title 'face 'bold) "\n")
      (when (> n (length shown))
        (insert (propertize (format "… %d earlier message%s not shown\n"
                                    (- n (length shown)) (if (= (- n (length shown)) 1) "" "s"))
                            'face 'shadow)))
      (when note (insert (propertize (concat note "\n") 'face 'shadow)))
      (if (null shown)
          (insert (propertize "\n(no messages)\n" 'face 'shadow))
        (dolist (m shown) (pai-preview--insert-message m)))
      (buffer-string))))

(defvar pai-preview--cache (make-hash-table :test 'equal)
  "Rendered session previews: FILE -> (STAMP . TEXT).")

(defun pai-preview-session-text (file)
  "Return the preview text of session FILE (cached until the file changes)."
  (let* ((attrs (file-attributes file))
         (stamp (list (file-attribute-size attrs) (file-attribute-modification-time attrs)))
         (hit (gethash file pai-preview--cache)))
    (if (and hit (equal (car hit) stamp))
        (cdr hit)
      (let* ((tail (pai-preview--tail-entries file))
             (text (pai-preview-render
                    (format "%s  %s"
                            (format-time-string "%Y-%m-%d %H:%M" (file-attribute-modification-time attrs))
                            (file-name-nondirectory file))
                    (pai-preview--entries-messages (car tail))
                    (unless (cdr tail) "(showing the end of a long session)"))))
        (puthash file (cons stamp text) pai-preview--cache)
        text))))

;;;; The preview window

(defun pai-preview--anchor-end (win)
  "Keep the end of the preview visible in WIN (e.g. after a resize)."
  (when (and (window-live-p win) (eq (window-buffer win) (get-buffer pai-preview-buffer-name)))
    (with-selected-window win
      (goto-char (point-max))
      (ignore-errors (recenter -1)))))

(defun pai-preview-show (text)
  "Show TEXT in the preview side window, scrolled to its end.
The end stays in view when the window is resized later (helm and other
completion UIs often resize windows after the preview appeared)."
  (let ((buf (get-buffer-create pai-preview-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (goto-char (point-max)))
      (unless (derived-mode-p 'special-mode) (special-mode))
      (setq-local truncate-lines nil)
      (setq-local word-wrap t)
      (add-hook 'window-size-change-functions #'pai-preview--anchor-end nil t))
    (let ((win (display-buffer buf `((display-buffer-in-side-window)
                                     (side . right) (slot . 0)
                                     (window-width . ,pai-preview-window-width)
                                     (preserve-size . (t . nil))))))
      (pai-preview--anchor-end win))
    buf))

(defun pai-preview-session-file (file)
  "Preview session FILE in the side window."
  (pai-preview-show
   (condition-case err (pai-preview-session-text file)
     (error (format "Cannot preview %s: %s" (abbreviate-file-name file)
                    (error-message-string err))))))

(defun pai-preview-messages (title messages &optional note)
  "Preview MESSAGES under TITLE (and NOTE) in the side window."
  (pai-preview-show (pai-preview-render title (seq-remove #'pai-system-message-p messages) note)))

(defun pai-preview-close ()
  "Remove the preview window and buffer."
  (let ((buf (get-buffer pai-preview-buffer-name)))
    (when (buffer-live-p buf)
      (dolist (w (get-buffer-window-list buf nil t))
        (ignore-errors (delete-window w)))
      (kill-buffer buf))))

;;;; Completing with a preview

(defun pai-preview--selected-candidate ()
  "Return the candidate string selected in the active completion UI, or nil."
  (cond
   ((and (boundp 'helm-alive-p) helm-alive-p (fboundp 'helm-get-selection))
    (ignore-errors (helm-get-selection nil t)))
   ((and (bound-and-true-p vertico-mode) (fboundp 'vertico--candidate))
    (ignore-errors (vertico--candidate)))
   ((and (or (bound-and-true-p icomplete-mode) (bound-and-true-p fido-mode))
         (minibufferp))
    (car-safe (ignore-errors (completion-all-sorted-completions))))
   ((minibufferp) (minibuffer-contents-no-properties))))

(defun pai-preview--lookup (candidate choices)
  "Return the (LABEL . VALUE) of CHOICES matching CANDIDATE, or nil."
  (when (stringp candidate)
    (let ((c (substring-no-properties candidate)))
      (or (assoc c choices)
          (let ((trimmed (string-trim c)))
            (seq-find (lambda (ch) (equal (string-trim (car ch)) trimmed)) choices))))))

(defun pai-preview--prompt (prompt)
  "Return PROMPT with the toggle key hinted before its colon."
  (let ((hint (format "[%s preview]" pai-preview-toggle-key)))
    (if (string-match "\\(:?\\)[ \t]*\\'" prompt)
        (concat (string-trim-right (substring prompt 0 (match-beginning 0)))
                " " hint (match-string 1 prompt) " ")
      (concat prompt hint " "))))

(defvar-local pai-preview--key-alist nil
  "Emulation keymap alist of a preview minibuffer: ((t . MAP)), else nil.
Emulation maps come before minor-mode maps, which is where helm puts its
own keymap (`minor-mode-overriding-map-alist'); only there does our
toggle win over helm's own \\`C-c C-f' (`helm-follow-mode').")

(add-to-list 'emulation-mode-map-alists 'pai-preview--key-alist)

(defun pai-preview-on-p (setting)
  "Return non-nil when previews for picker SETTING (e.g. :preview-tree) are on.
Off unless turned on (in /menu or with `pai-preview-toggle-key')."
  (and pai-preview-enabled (pai-truthy (pai-settings-get setting nil))))

(defun pai-completing-read-preview (prompt choices preview &optional table cleanup setting)
  "Read one of CHOICES, an alist (LABEL . VALUE), calling PREVIEW as you move.
PREVIEW is called with the VALUE of the selected candidate (after
`pai-preview-delay' idle seconds, in the buffer current at the call).
TABLE, when given, is the completion table (default: the labels).
CLEANUP, when given, runs when the preview is turned off and afterwards
however the read ends; by default the preview window is closed.
SETTING is the settings key that switches this picker's preview on and
off (default `:preview'); `pai-preview-toggle-key' flips and saves it.
Return the chosen label, or nil."
  (let* ((setting (or setting :preview))
         (on (pai-preview-on-p setting))
         (origin (current-buffer))
         (last-value 'none)
         (timer nil)
         (close (lambda () (if cleanup (funcall cleanup) (pai-preview-close))))
         (tick
          (lambda ()
            (setq timer nil)
            (when on
              (let ((hit (pai-preview--lookup (pai-preview--selected-candidate) choices)))
                (when (and hit (not (equal (cdr hit) last-value)))
                  (setq last-value (cdr hit))
                  (when (buffer-live-p origin)
                    (with-current-buffer origin
                      (with-demoted-errors "pai preview: %S"
                        (funcall preview (cdr hit))))))))))
         (schedule
          (lambda ()
            (when (timerp timer) (cancel-timer timer))
            (setq timer (and on (run-with-idle-timer pai-preview-delay nil tick)))))
         (toggle
          (lambda ()
            (interactive)
            (setq on (not on) last-value 'none)
            ;; settings are per pai buffer: save from the one we came from
            (with-current-buffer (if (buffer-live-p origin) origin (current-buffer))
              (pai-settings-set setting (if on t :false)))
            (when (timerp timer) (cancel-timer timer))
            (if on
                (funcall tick)          ; asked for: preview now, not after a delay
              (setq timer nil)
              (with-current-buffer (if (buffer-live-p origin) origin (current-buffer))
                (funcall close)))
            (let ((message-log-max nil))
              (minibuffer-message "Preview %s" (if on "on" "off")))))
         ;; helm moves its selection without always running a minibuffer
         ;; command (e.g. after an asynchronous update)
         (helm-move-selection-after-hook
          (cons schedule (and (boundp 'helm-move-selection-after-hook)
                              helm-move-selection-after-hook)))
         (helm-after-update-hook
          (cons schedule (and (boundp 'helm-after-update-hook) helm-after-update-hook))))
    (unwind-protect
        (minibuffer-with-setup-hook
            (lambda ()
              (let ((map (make-sparse-keymap)))
                (define-key map (kbd pai-preview-toggle-key) toggle)
                (setq-local pai-preview--key-alist (list (cons t map))))
              (add-hook 'post-command-hook schedule nil t)
              (funcall schedule))
          (completing-read (pai-preview--prompt prompt)
                           (or table (mapcar #'car choices)) nil t))
      (when (timerp timer) (cancel-timer timer))
      (with-current-buffer (if (buffer-live-p origin) origin (current-buffer))
        (funcall close)))))

(provide 'pai-preview)
;;; pai-preview.el ends here
