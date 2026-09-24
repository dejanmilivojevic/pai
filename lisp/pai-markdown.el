;;; pai-markdown.el --- Lightweight markdown formatting for the chat UI -*- lexical-binding: t; -*-

;;; Commentary:

;; Formatting applied to finalized assistant text before it is displayed in the
;; chat buffer.  The main job is aligning GitHub-flavored markdown tables into
;; monospace columns using `string-width' (so CJK/wide characters line up), the
;; same way Emacs' own table facilities measure display width.
;;
;; `pai-format-markdown' is the entry point; it currently aligns tables and
;; leaves everything else untouched, so plain prose and code blocks pass
;; through unchanged.

;;; Code:

(require 'subr-x)

(declare-function browse-url "browse-url" (url &rest args))

(defface pai-md-heading '((t :inherit bold :height 1.1))
  "Face for markdown ATX headings.")

(defface pai-md-bold '((t :inherit bold))
  "Face for markdown strong (bold) spans.")

(defface pai-md-italic '((t :inherit italic))
  "Face for markdown emphasis (italic) spans.")

(defface pai-md-code '((t :inherit (font-lock-constant-face fixed-pitch)))
  "Face for inline markdown code spans.")

(defface pai-md-code-block '((t :inherit fixed-pitch :extend t))
  "Face added underneath the syntax highlighting of fenced code blocks.")

(defface pai-md-code-lang '((t :inherit shadow))
  "Face for the language label above a fenced code block.")

(defface pai-md-quote '((t :inherit font-lock-comment-face))
  "Face for markdown blockquotes.")

(defface pai-md-rule '((t :inherit shadow))
  "Face for markdown horizontal rules and table separators.")

(defface pai-md-link '((t :inherit link))
  "Face for markdown links.")

(defvar pai-md-link-map
  (let ((m (make-sparse-keymap)))
    (define-key m [mouse-1] #'pai-md-follow-link)
    (define-key m [mouse-2] #'pai-md-follow-link)
    (define-key m (kbd "RET") #'pai-md-follow-link)
    m)
  "Keymap active on text rendered as a markdown link.")

(defun pai-md-follow-link (&rest _)
  "Open the markdown link URL stored at point, if any."
  (interactive)
  (let ((url (get-text-property (point) 'pai-md-url)))
    (when url (browse-url url))))

(defun pai-md--row-p (line)
  "Return non-nil if LINE looks like a table row (contains a pipe and text)."
  (and (string-match-p "|" line)
       (string-match-p "[^ \t|]" line)))

(defun pai-md--separator-p (line)
  "Return non-nil if LINE is a markdown table separator row (dashes/colons)."
  (and (string-match-p "-" line)
       (string-match-p "|" line)
       (string-match-p "\\`[ \t|:-]+\\'" line)))

(defun pai-md--cells (line)
  "Split a table LINE into a list of trimmed cell strings."
  (let ((s (string-trim line)))
    (setq s (replace-regexp-in-string "\\`|" "" s))
    (setq s (replace-regexp-in-string "|\\'" "" s))
    (mapcar #'string-trim (split-string s "|"))))

(defun pai-md--align (spec)
  "Return the alignment symbol (`left', `right', `center') for separator SPEC."
  (let ((l (string-prefix-p ":" spec))
        (r (string-suffix-p ":" spec)))
    (cond ((and l r) 'center)
          (r 'right)
          (t 'left))))

(defun pai-md--pad (s width align)
  "Pad string S to display WIDTH according to ALIGN."
  (let* ((w (string-width s))
         (pad (max 0 (- width w))))
    (pcase align
      ('right (concat (make-string pad ?\s) s))
      ('center (let* ((l (/ pad 2)) (r (- pad l)))
                 (concat (make-string l ?\s) s (make-string r ?\s))))
      (_ (concat s (make-string pad ?\s))))))

(defun pai-md--sep-cell (width align)
  "Return a separator cell of display WIDTH encoding ALIGN with colons."
  (pcase align
    ('right (concat (make-string (max 1 (1- width)) ?-) ":"))
    ('center (if (>= width 2)
                 (concat ":" (make-string (max 1 (- width 2)) ?-) ":")
               (make-string (max 1 width) ?-)))
    (_ (make-string (max 1 width) ?-))))

(defun pai-md--render-row (cells widths aligns ncol)
  "Render a table row from CELLS using column WIDTHS/ALIGNS and NCOL columns."
  (concat "| "
          (mapconcat (lambda (i) (pai-md--pad (or (nth i cells) "") (aref widths i) (nth i aligns)))
                     (number-sequence 0 (1- ncol)) " | ")
          " |"))

(defun pai-md--render-sep (widths aligns ncol)
  "Render the separator row using column WIDTHS/ALIGNS and NCOL columns."
  (concat "| "
          (mapconcat (lambda (i) (pai-md--sep-cell (aref widths i) (nth i aligns)))
                     (number-sequence 0 (1- ncol)) " | ")
          " |"))

(defun pai-md-align-tables (text)
  "Return TEXT with any GitHub-flavored markdown tables aligned into columns."
  (let ((lines (split-string text "\n"))
        (out '()))
    (while lines
      (let ((line (car lines)) (next (cadr lines)))
        (if (and (pai-md--row-p line) next (pai-md--separator-p next))
            ;; Start of a table: collect header, separator, and body rows.
            (let ((header (pai-md--cells line))
                  (aligns (mapcar #'pai-md--align (pai-md--cells next)))
                  (body '()))
              (setq lines (cddr lines))
              (while (and lines (pai-md--row-p (car lines))
                          (not (pai-md--separator-p (car lines))))
                (push (pai-md--cells (car lines)) body)
                (setq lines (cdr lines)))
              (setq body (nreverse body))
              (let* ((rows (cons header body))
                     (ncol (apply #'max (length aligns) (mapcar #'length rows)))
                     (widths (make-vector ncol 3)))
                (dolist (r rows)
                  (dotimes (i ncol)
                    (aset widths i (max (aref widths i) (string-width (or (nth i r) ""))))))
                (setq aligns (append aligns (make-list (max 0 (- ncol (length aligns))) 'left)))
                (push (pai-md--render-row header widths aligns ncol) out)
                (push (pai-md--render-sep widths aligns ncol) out)
                (dolist (r body)
                  (push (pai-md--render-row r widths aligns ncol) out))))
          ;; Not a table: pass the line through unchanged.
          (push line out)
          (setq lines (cdr lines)))))
    (string-join (nreverse out) "\n")))

;;;; Syntax highlighting (the language's own major mode)
;;
;; Code is highlighted exactly the way Org highlights source blocks: it is
;; inserted into a hidden buffer running the language's major mode (with its
;; mode hooks delayed, so no LSP client, linter or minor mode starts), then
;; `font-lock-ensure' fontifies it and the resulting faces are copied back.
;; One hidden buffer is kept per mode, so a mode initializes only once.

(defcustom pai-md-lang-modes
  '(("elisp" . emacs-lisp-mode) ("emacs-lisp" . emacs-lisp-mode)
    ("lisp" . lisp-mode) ("scheme" . scheme-mode)
    ("js" . js-mode) ("javascript" . js-mode) ("jsx" . js-jsx-mode)
    ("node" . js-mode) ("mjs" . js-mode) ("cjs" . js-mode)
    ("json" . js-json-mode) ("jsonc" . js-json-mode)
    ("ts" . typescript-ts-mode) ("typescript" . typescript-ts-mode)
    ("tsx" . tsx-ts-mode)
    ("sh" . sh-mode) ("bash" . sh-mode) ("zsh" . sh-mode) ("shell" . sh-mode)
    ("console" . sh-mode) ("shellsession" . sh-mode)
    ("py" . python-mode) ("python" . python-mode)
    ("c++" . c++-mode) ("cpp" . c++-mode) ("objc" . objc-mode)
    ("html" . mhtml-mode) ("xml" . nxml-mode) ("svg" . nxml-mode)
    ("yml" . yaml-ts-mode) ("dockerfile" . dockerfile-ts-mode)
    ("diff" . diff-mode) ("patch" . diff-mode)
    ("tex" . latex-mode) ("latex" . latex-mode) ("org" . org-mode))
  "Alist mapping code-fence language names to major modes.
Names not listed here resolve to NAME-mode when that exists, or to the
mode `auto-mode-alist' picks for a file with extension NAME."
  :type '(alist :key-type string :value-type function)
  :group 'pai)

(defcustom pai-md-fontify-max-size 100000
  "Largest code block (in characters) that is syntax highlighted."
  :type 'integer :group 'pai)

(defconst pai-md--ts-grammars
  '(("js" . javascript) ("c++" . cpp) ("csharp" . c-sharp) ("go-mod" . gomod))
  "Tree-sitter grammar names that differ from their mode's prefix.")

(defun pai-md--ts-fallback (mode)
  "Return MODE, or a classic replacement when MODE is a grammar-less ts mode."
  (let ((name (symbol-name mode)))
    (if (not (and (string-suffix-p "-ts-mode" name)
                  (fboundp 'treesit-language-available-p)))
        mode
      (let* ((prefix (string-remove-suffix "-ts-mode" name))
             (grammar (or (cdr (assoc prefix pai-md--ts-grammars)) (intern prefix))))
        (if (ignore-errors (treesit-language-available-p grammar))
            mode
          (let ((classic (intern-soft (concat prefix "-mode"))))
            (and classic (fboundp classic) classic)))))))

(defun pai-md--usable-mode (mode)
  "Return the mode to fontify with for MODE, or nil when there is none.
Honours `major-mode-remap-alist' (e.g. a preference for tree-sitter modes)."
  (when (and mode (symbolp mode))
    (let ((mode (or (alist-get mode (bound-and-true-p major-mode-remap-alist)) mode)))
      (and (fboundp mode) (pai-md--ts-fallback mode)))))

(defun pai-md-mode-for-file (file)
  "Return the major mode Emacs would use for FILE, or nil."
  (when (and (stringp file) (not (string-empty-p file)))
    (let ((mode (assoc-default (file-name-nondirectory file) auto-mode-alist
                               #'string-match)))
      ;; Entries like ("\\.gz\\'" FN t) wrap another mode; ignore them.
      (pai-md--usable-mode (if (consp mode) nil mode)))))

(defun pai-md-lang-mode (lang)
  "Return the major mode for code-fence language LANG, or nil."
  (when (and (stringp lang) (not (string-empty-p lang)))
    (let ((lang (downcase (car (split-string lang "[ \t{,]" t)))))
      (or (pai-md--usable-mode (cdr (assoc lang pai-md-lang-modes)))
          (pai-md--usable-mode (intern-soft (concat lang "-mode")))
          (pai-md-mode-for-file (concat "file." lang))))))

(defun pai-md-fontify (code mode)
  "Return CODE with the syntax highlighting of major MODE as `face' properties.
Return CODE unchanged when MODE is nil, CODE is too large, or MODE fails."
  (if (or (null mode) (> (length code) pai-md-fontify-max-size))
      code
    (condition-case nil
        (let ((buffer (get-buffer-create (format " *pai-fontify %s*" mode))))
          (with-current-buffer buffer
            (unless (eq major-mode mode)
              (delay-mode-hooks (funcall mode)))
            (let ((inhibit-read-only t)
                  (inhibit-modification-hooks t))
              (erase-buffer)
              (insert code))
            (font-lock-ensure)
            (let ((out (substring-no-properties code))
                  (pos (point-min)))
              (while (< pos (point-max))
                (let* ((next (next-single-property-change
                              pos 'face nil
                              (next-single-property-change pos 'font-lock-face nil (point-max))))
                       (face (or (get-text-property pos 'face)
                                 (get-text-property pos 'font-lock-face))))
                  (when face
                    (put-text-property (1- pos) (1- next) 'face face out))
                  (setq pos next)))
              out)))
      (error code))))

(defun pai-md-fontify-lang (code lang)
  "Return CODE highlighted as code-fence language LANG."
  (pai-md-fontify code (pai-md-lang-mode lang)))

(defun pai-md-fontify-file (code file)
  "Return CODE highlighted with the major mode Emacs uses for FILE."
  (pai-md-fontify code (pai-md-mode-for-file file)))

(defun pai-md-code-block (code lang)
  "Return fenced CODE in LANG rendered for display: a label and highlighted code.
Every character carries `pai-md-verbatim', so later passes (filling,
inline markup) leave the block alone."
  (let ((body (copy-sequence (pai-md-fontify-lang code lang))))
    (add-face-text-property 0 (length body) 'pai-md-code-block t body)
    (let ((out (if (string-empty-p (string-trim (or lang "")))
                   body
                 (concat (propertize (concat "── " (string-trim lang)) 'face 'pai-md-code-lang)
                         "\n" body))))
      (put-text-property 0 (length out) 'pai-md-verbatim t out)
      out)))

(defun pai-md-highlight-fences (text)
  "Return TEXT verbatim, except that fenced code blocks are syntax highlighted.
For text that is not rendered as Markdown (e.g. user messages): the fences
stay visible, only the code between them gains colours."
  (let ((lines (split-string (or text "") "\n"))
        (out '()))
    (while lines
      (let ((line (car lines)))
        (setq lines (cdr lines))
        (if (not (string-match "\\`[ \t]*\\(```+\\|~~~+\\)[ \t]*\\(.*\\)\\'" line))
            (push line out)
          (let ((fence (match-string 1 line))
                (lang (string-trim (match-string 2 line)))
                (code '()))
            (while (and lines (not (string-match-p
                                    (concat "\\`[ \t]*" (regexp-quote fence) "[ \t]*\\'")
                                    (car lines))))
              (push (car lines) code)
              (setq lines (cdr lines)))
            (push (propertize line 'face 'pai-md-code-lang) out)
            (push (pai-md-fontify-lang (string-join (nreverse code) "\n") lang) out)
            (when lines
              (push (propertize (car lines) 'face 'pai-md-code-lang) out)
              (setq lines (cdr lines)))))))
    (string-join (nreverse out) "\n")))

(defun pai-markdown-fill (text column)
  "Return rendered TEXT with long lines wrapped at COLUMN.
Lines are wrapped one at a time and never joined, so the layout the text
was written with (line breaks, lists, code, tables) is kept; code blocks
and tables (`pai-md-verbatim') are never wrapped."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let ((fill-column column)
          (adaptive-fill-regexp "[ \t]*\\([-•*]\\|[0-9]+[.)]\\)?[ \t]*"))
      (while (not (eobp))
        (let ((beg (line-beginning-position))
              (end (line-end-position)))
          (when (and (> (string-width (buffer-substring beg end)) column)
                     (not (text-property-any beg end 'pai-md-verbatim t)))
            (let ((fill-prefix (save-excursion
                                 (goto-char beg)
                                 (and (looking-at adaptive-fill-regexp)
                                      (make-string (string-width (match-string 0)) ?\s)))))
              (fill-region-as-paragraph beg end nil t))))
        (forward-line 1)))
    (buffer-string)))

(defun pai-format-markdown (text)
  "Return TEXT formatted for display in the chat buffer.
Currently aligns markdown tables; other content is unchanged."
  (pai-md-align-tables text))

(defconst pai-md--inline-specs
  '(("`\\([^`\n]+\\)`" . code)
    ("\\[\\([^]\n]*\\)\\](\\([^)\n]*\\))" . link)
    ("\\*\\*\\([^\n]+?\\)\\*\\*" . bold)
    ("__\\([^\n]+?\\)__" . bold)
    ("\\*\\([^*\n]+?\\)\\*" . italic)
    ("_\\([^_\n]+?\\)_" . italic))
  "Alist of (REGEX . KIND) used for inline markdown formatting.
Order matters: earlier entries win ties on match position.")

(defun pai-md--make-link (label url)
  "Return propertized LABEL carrying markdown link URL and styling."
  (propertize (or label "")
              'face 'pai-md-link
              'pai-md-url (or url "")
              'help-echo (or url "")
              'mouse-face 'highlight
              'keymap pai-md-link-map))

(defun pai-md--inline-build (kind text)
  "Build the propertized span for inline KIND using match data over TEXT."
  (pcase kind
    ('code (propertize (match-string 1 text) 'face 'pai-md-code))
    ('bold (propertize (match-string 1 text) 'face 'pai-md-bold))
    ('italic (propertize (match-string 1 text) 'face 'pai-md-italic))
    ('link (pai-md--make-link (match-string 1 text) (match-string 2 text)))
    (_ (match-string 0 text))))

(defun pai-md--render-inline (text)
  "Return TEXT with inline markdown (code, links, bold, italic) rendered.
Unmatched markers pass through literally."
  (let ((i 0) (n (length text)) (parts nil))
    (while (< i n)
      (let ((best-start (1+ n)) best-end best-kind best-data)
        (dolist (spec pai-md--inline-specs)
          (when (and (string-match (car spec) text i)
                     (< (match-beginning 0) best-start))
            (setq best-start (match-beginning 0)
                  best-end (match-end 0)
                  best-kind (cdr spec)
                  best-data (match-data))))
        (if (not best-kind)
            (progn (push (substring text i) parts) (setq i n))
          (when (> best-start i)
            (push (substring text i best-start) parts))
          (set-match-data best-data)
          (push (pai-md--inline-build best-kind text) parts)
          (setq i best-end))))
    (apply #'concat (nreverse parts))))

(defun pai-md--render-table (lines)
  "Render leading table rows in LINES, returning (RENDERED . REST).
RENDERED is a list of propertized lines in reverse order to prepend."
  (let ((block nil))
    (while (and lines (pai-md--row-p (car lines)))
      (push (car lines) block)
      (setq lines (cdr lines)))
    (let ((alines (split-string
                   (pai-md-align-tables (string-join (nreverse block) "\n"))
                   "\n"))
          (rendered nil))
      (when alines
        (push (propertize (car alines) 'face 'pai-md-bold 'pai-md-verbatim t) rendered))
      (when (cdr alines)
        (push (propertize (cadr alines) 'face 'pai-md-rule 'pai-md-verbatim t) rendered))
      (dolist (l (cddr alines))
        (push (propertize l 'pai-md-verbatim t) rendered))
      (cons rendered lines))))

(defun pai-markdown-render (text)
  "Return TEXT rendered as a propertized string for GitHub-flavored markdown.
Never signals on malformed input; unmatched markers pass through literally."
  (let ((lines (split-string (or text "") "\n"))
        (out nil))
    (while lines
      (let ((line (car lines)))
        (cond
         ;; Fenced code block: strip fences, keep code, no inline formatting.
         ((string-match "\\`[ \t]*```\\(.*\\)\\'" line)
          (let ((lang (string-trim (match-string 1 line)))
                (code nil))
            (setq lines (cdr lines))
            (while (and lines
                        (not (string-match-p "\\`[ \t]*```[ \t]*\\'" (car lines))))
              (push (car lines) code)
              (setq lines (cdr lines)))
            (when lines (setq lines (cdr lines)))
            (push (pai-md-code-block (string-join (nreverse code) "\n") lang) out)))
         ;; Table: align via existing helper, style header bold.
         ((and (pai-md--row-p line)
               (cadr lines)
               (pai-md--separator-p (cadr lines)))
          (let* ((res (pai-md--render-table lines)))
            (setq out (append (car res) out)
                  lines (cdr res))))
         ;; Horizontal rule.
         ((string-match-p
           "\\`[ \t]*\\(-\\{3,\\}\\|\\*\\{3,\\}\\|_\\{3,\\}\\)[ \t]*\\'" line)
          (push (propertize "────────────────" 'face 'pai-md-rule) out)
          (setq lines (cdr lines)))
         ;; ATX heading.
         ((string-match "\\`[ \t]*\\(#\\{1,6\\}\\)[ \t]+\\(.*\\)\\'" line)
          (push (propertize (match-string 2 line) 'face 'pai-md-heading) out)
          (setq lines (cdr lines)))
         ;; Blockquote.
         ((string-match "\\`[ \t]*>[ \t]?\\(.*\\)\\'" line)
          (let ((content (match-string 1 line)))
            (push (concat (propertize "│ " 'face 'pai-md-quote)
                          (propertize content 'face 'pai-md-quote))
                  out))
          (setq lines (cdr lines)))
         ;; Unordered list.
         ((string-match "\\`\\([ \t]*\\)[-*+][ \t]+\\(.*\\)\\'" line)
          (push (concat (match-string 1 line) "• "
                        (pai-md--render-inline (match-string 2 line)))
                out)
          (setq lines (cdr lines)))
         ;; Ordered list.
         ((string-match "\\`\\([ \t]*\\)\\([0-9]+\\.\\)[ \t]+\\(.*\\)\\'" line)
          (push (concat (match-string 1 line) (match-string 2 line) " "
                        (pai-md--render-inline (match-string 3 line)))
                out)
          (setq lines (cdr lines)))
         ;; Paragraph / plain text.
         (t
          (push (pai-md--render-inline line) out)
          (setq lines (cdr lines))))))
    (string-join (nreverse out) "\n")))

(provide 'pai-markdown)
;;; pai-markdown.el ends here
