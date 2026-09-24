;;; pai-compose.el --- Edit the prompt in a dedicated buffer -*- lexical-binding: t; -*-

;;; Commentary:

;; `C-c C-e' in a pai buffer opens the whole input in a buffer of its own, the
;; way `org-edit-special' opens a source block: a real editing buffer with
;; your usual keys, undo, filling and highlighting.  `C-c C-c' (or `C-c C-e')
;; writes it back into the prompt, `C-c C-k' throws it away.  Nothing is
;; sent; you still press RET in the chat when you are ready.
;;
;; The compose buffer is in `pai-compose-mode', a small Markdown mode built on
;; `text-mode' (Emacs ships no markdown-mode): headings, emphasis, inline
;; code, links, quotes and lists are highlighted, and fenced code blocks are
;; highlighted *natively* in their language's major mode, like
;; `org-src-fontify-natively'.  Inside a fenced block `C-c C-e' goes one level
;; deeper: the block opens in its language's major mode (full mode hooks, so
;; your setup applies), and `C-c C-c' puts it back into the message.
;;
;; Both levels use the same minor mode, `pai-compose-edit-mode', which
;; supplies the keys on top of whatever major mode the buffer is in.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-markdown)

(defvar pai--input-marker)
(defvar font-lock-beg)
(defvar font-lock-end)
(declare-function pai--input-text "pai-ui" ())

(defgroup pai-compose nil
  "Editing the pai prompt in a dedicated buffer."
  :group 'pai)

(defcustom pai-compose-major-mode 'pai-compose-mode
  "Major mode of the buffer the whole message is edited in."
  :type 'function :group 'pai-compose)

(defcustom pai-compose-display-action
  '((display-buffer-reuse-window display-buffer-below-selected)
    (window-height . 0.5))
  "`display-buffer' action used to show compose buffers."
  :type 'sexp :group 'pai-compose)

;;;; The edit minor mode (shared by both levels)

(defvar-local pai-compose--commit nil
  "Function called with the buffer text when the edit is committed.")

(defvar-local pai-compose--origin nil
  "Buffer the edit came from; focus returns there when it ends.")

(defvar-local pai-compose--finished nil
  "Non-nil once this edit was committed or aborted.")

(defvar pai-compose-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'pai-compose-commit)
    (define-key map (kbd "C-c C-k") #'pai-compose-abort)
    (define-key map (kbd "C-c C-e") #'pai-compose-dwim)
    map)
  "Keymap of `pai-compose-edit-mode'.")

(define-minor-mode pai-compose-edit-mode
  "Minor mode of a buffer editing something on behalf of another buffer.
\\<pai-compose-edit-mode-map>\\[pai-compose-commit] writes the text back, \\[pai-compose-abort] discards it."
  :lighter " Edit"
  :keymap pai-compose-edit-mode-map
  (when pai-compose-edit-mode
    (setq-local header-line-format
                (substitute-command-keys
                 (concat "Edit, then \\<pai-compose-edit-mode-map>\\[pai-compose-commit] to commit"
                         " or \\[pai-compose-abort] to abort"
                         (if (derived-mode-p 'pai-compose-mode)
                             " · \\[pai-compose-dwim] in a \\=`\\=`\\=` block edits it in its mode"
                           ""))))))

(defun pai-compose--leave (buffer)
  "Close compose BUFFER, restoring its window and returning to its origin."
  (let ((origin (buffer-local-value 'pai-compose--origin buffer)))
    (dolist (window (get-buffer-window-list buffer nil t))
      (quit-restore-window window 'kill))
    (when (buffer-live-p buffer)
      (let ((kill-buffer-query-functions nil)) (kill-buffer buffer)))
    (when (buffer-live-p origin)
      (let ((window (get-buffer-window origin 0)))
        (if window (select-window window) (pop-to-buffer origin))))))

(defun pai-compose-commit ()
  "Write this buffer's text back where it came from and close it."
  (interactive)
  (unless pai-compose-edit-mode (user-error "Not a pai edit buffer"))
  (let ((text (buffer-substring-no-properties (point-min) (point-max)))
        (commit pai-compose--commit)
        (buffer (current-buffer)))
    (when commit (funcall commit text))
    (setq pai-compose--finished t)
    (pai-compose--leave buffer)))

(defun pai-compose-abort ()
  "Close this buffer, discarding the edit."
  (interactive)
  (unless pai-compose-edit-mode (user-error "Not a pai edit buffer"))
  (setq pai-compose--finished t)
  (pai-compose--leave (current-buffer)))

(defun pai-compose--confirm-kill ()
  "Ask before a modified, unfinished edit buffer is killed."
  (or pai-compose--finished
      (not (buffer-modified-p))
      (yes-or-no-p "Discard this edit? ")))

(defun pai-compose-open (name text mode commit &optional point-offset)
  "Edit TEXT in a new buffer NAME in major MODE; return the buffer.
COMMIT is called with the edited text on \\[pai-compose-commit].  Point
starts POINT-OFFSET characters into the text (default: its end)."
  (let ((origin (current-buffer))
        (buffer (generate-new-buffer name)))
    (with-current-buffer buffer
      (insert text)
      (goto-char (min (point-max) (1+ (or point-offset (length text)))))
      (funcall mode)
      (setq pai-compose--commit commit
            pai-compose--origin origin
            pai-compose--finished nil)
      (pai-compose-edit-mode 1)
      (set-buffer-modified-p nil)
      (add-hook 'kill-buffer-query-functions #'pai-compose--confirm-kill nil t))
    (pop-to-buffer buffer pai-compose-display-action)
    buffer))

(defun pai-compose-dwim ()
  "In a fenced code block, edit it in its language's mode; otherwise commit."
  (interactive)
  (if (and (derived-mode-p 'pai-compose-mode) (pai-compose--block-at-point))
      (pai-compose-edit-block)
    (pai-compose-commit)))

;;;; Editing the pai prompt

(defvar-local pai-compose--buffer nil
  "The compose buffer editing this pai buffer's input, if any.")

(defun pai-edit-input ()
  "Edit the whole pai prompt in a dedicated buffer.
\\<pai-compose-edit-mode-map>\\[pai-compose-commit] writes it back into the prompt (without sending it);
\\[pai-compose-abort] leaves the prompt as it was."
  (interactive)
  (unless (and (boundp 'pai--input-marker) (markerp pai--input-marker)
               (eq (marker-buffer pai--input-marker) (current-buffer)))
    (user-error "Not in a pai buffer"))
  (if (buffer-live-p pai-compose--buffer)
      (pop-to-buffer pai-compose--buffer pai-compose-display-action)
    (let* ((chat (current-buffer))
           (original (buffer-substring-no-properties pai--input-marker (point-max)))
           (offset (and (>= (point) pai--input-marker) (- (point) pai--input-marker))))
      (let ((editor (pai-compose-open
                     (format "*pai compose: %s*" (buffer-name chat))
                     original pai-compose-major-mode
                     (lambda (text) (pai-compose--write-input chat original text))
                     offset)))
        ;; `pai-compose-open' leaves the editor current: record it in the chat.
        (with-current-buffer chat (setq pai-compose--buffer editor))
        editor))))

(defun pai-compose--write-input (chat original text)
  "Replace CHAT's prompt with TEXT; ORIGINAL is what it held when opened."
  (unless (buffer-live-p chat) (user-error "The pai buffer is gone"))
  (with-current-buffer chat
    (setq pai-compose--buffer nil)
    (let ((current (buffer-substring-no-properties pai--input-marker (point-max))))
      (when (or (equal current original)
                (string-empty-p (string-trim current))
                (yes-or-no-p "The prompt changed since you opened the editor; replace it? "))
        (let ((inhibit-read-only t))
          (delete-region pai--input-marker (point-max))
          (goto-char pai--input-marker)
          (insert (string-trim-right text)))
        (goto-char (point-max))))))

;;;; Fenced code blocks

(defconst pai-compose--fence-re "^\\([ \t]*\\)\\(```+\\|~~~+\\)[ \t]*\\([^ \t\n`]*\\).*$"
  "Regexp matching a fence line; group 2 is the fence, group 3 the language.")

(defun pai-compose--blocks ()
  "Return the fenced blocks of this buffer as (OPEN-BEG BODY-BEG BODY-END CLOSE-END LANG).
An unclosed block runs to the end of the buffer (CLOSE-END is then nil)."
  (save-excursion
    (save-match-data
      (goto-char (point-min))
      (let ((blocks '()))
        (while (re-search-forward pai-compose--fence-re nil t)
          (let* ((open-beg (match-beginning 0))
                 (fence (match-string-no-properties 2))
                 (lang (match-string-no-properties 3))
                 (body-beg (min (point-max) (1+ (match-end 0)))))
            (if (re-search-forward (concat "^[ \t]*" (regexp-quote fence) "[ \t]*$") nil t)
                (push (list open-beg body-beg (max body-beg (1- (match-beginning 0)))
                            (match-end 0) lang)
                      blocks)
              (push (list open-beg body-beg (point-max) nil lang) blocks)
              (goto-char (point-max)))))
        (nreverse blocks)))))

(defun pai-compose--block-at-point ()
  "Return the fenced block (see `pai-compose--blocks') containing point, or nil."
  (let ((pos (point)))
    (seq-find (lambda (b) (and (>= pos (nth 0 b)) (<= pos (or (nth 3 b) (point-max)))))
              (pai-compose--blocks))))

(defun pai-compose-edit-block ()
  "Edit the fenced code block at point in its language's major mode."
  (interactive)
  (let ((block (or (pai-compose--block-at-point) (user-error "Not in a fenced code block"))))
    (pcase-let* ((`(,_open ,beg ,end ,_close ,lang) block)
                 (mode (or (pai-md-lang-mode lang) 'fundamental-mode))
                 (beg-marker (copy-marker beg))
                 (end-marker (copy-marker end t))
                 (message-buffer (current-buffer))
                 (offset (and (>= (point) beg) (<= (point) end) (- (point) beg))))
      (pai-compose-open
       (format "*pai compose %s block*" (if (string-empty-p lang) "code" lang))
       (buffer-substring-no-properties beg end) mode
       (lambda (text)
         (when (buffer-live-p message-buffer)
           (with-current-buffer message-buffer
             (save-excursion
               (goto-char beg-marker)
               (delete-region beg-marker end-marker)
               (insert (string-trim-right text "\n+"))))))
       offset))))

;;;; The compose major mode

(defun pai-compose--fontify-blocks (limit)
  "Font-lock matcher: highlight fenced blocks up to LIMIT natively.
The body gets its language's faces (over `pai-md-code-block', so no
Markdown keyword touches code); the fence lines are matched for
`pai-md-code-lang'.  Returns non-nil with match data on a fence line."
  (let ((found nil))
    (while (and (not found) (re-search-forward pai-compose--fence-re limit t))
      (let* ((open-beg (match-beginning 0))
             (open-end (match-end 0))
             (fence (match-string-no-properties 2))
             (lang (match-string-no-properties 3))
             (body-beg (min (point-max) (1+ open-end)))
             (close (save-excursion
                      (and (re-search-forward
                            (concat "^[ \t]*" (regexp-quote fence) "[ \t]*$") nil t)
                           (cons (match-beginning 0) (match-end 0)))))
             (body-end (if close (max body-beg (1- (car close))) (point-max))))
        (when (< body-beg body-end)
          (let ((code (pai-md-fontify-lang (buffer-substring-no-properties body-beg body-end)
                                           lang)))
            (with-silent-modifications
              (put-text-property body-beg body-end 'face 'pai-md-code-block)
              (let ((i 0) (n (length code)))
                (while (< i n)
                  (let ((next (next-single-property-change i 'face code n))
                        (face (get-text-property i 'face code)))
                    (when face
                      (put-text-property (+ body-beg i) (+ body-beg next) 'face
                                         (list face 'pai-md-code-block)))
                    (setq i next))))
              (put-text-property open-beg (if close (cdr close) (point-max))
                                 'font-lock-multiline t))))
        (with-silent-modifications
          (put-text-property open-beg open-end 'face 'pai-md-code-lang)
          (when close (put-text-property (car close) (cdr close) 'face 'pai-md-code-lang)))
        (goto-char (if close (cdr close) (point-max)))
        (set-match-data (list open-beg open-end))
        (setq found t)))
    found))

(defun pai-compose--extend-region ()
  "Extend the font-lock region to whole fenced blocks.
Editing one line of a block must refontify the whole block, since the
language's highlighting depends on the code around it."
  (let ((changed nil))
    (dolist (b (pai-compose--blocks))
      (let ((beg (nth 0 b)) (end (or (nth 3 b) (point-max))))
        (when (and (< beg font-lock-end) (> end font-lock-beg))
          (when (< beg font-lock-beg) (setq font-lock-beg beg changed t))
          (when (> end font-lock-end) (setq font-lock-end end changed t)))))
    changed))

(defconst pai-compose-font-lock-keywords
  `((pai-compose--fontify-blocks (0 'pai-md-code-lang keep))
    ("^#\\{1,6\\}[ \t]+.*$" (0 'pai-md-heading keep))
    ("^[ \t]*>.*$" (0 'pai-md-quote keep))
    ("^[ \t]*\\([-*+]\\|[0-9]+[.)]\\)[ \t]" (1 'font-lock-builtin-face keep))
    ("`[^`\n]+`" (0 'pai-md-code keep))
    ("\\*\\*[^*\n]+\\*\\*" (0 'pai-md-bold keep))
    ("\\(?:^\\|[^*]\\)\\(\\*[^* \n][^*\n]*\\*\\)" (1 'pai-md-italic keep))
    ("\\[[^]\n]+\\]([^)\n]+)" (0 'pai-md-link keep))
    ("@[^ \t\n]+" (0 'font-lock-constant-face keep)))
  "Font-lock keywords of `pai-compose-mode'.")

(define-derived-mode pai-compose-mode text-mode "pai-compose"
  "Major mode for composing a pai message (Markdown).
Fenced code blocks are highlighted in their language's own major mode;
\\<pai-compose-edit-mode-map>\\[pai-compose-dwim] inside one edits it in that mode."
  (setq-local font-lock-defaults '(pai-compose-font-lock-keywords t))
  (setq-local font-lock-multiline t)
  (add-hook 'font-lock-extend-region-functions #'pai-compose--extend-region nil t)
  (setq-local comment-start nil))

(provide 'pai-compose)
;;; pai-compose.el ends here
