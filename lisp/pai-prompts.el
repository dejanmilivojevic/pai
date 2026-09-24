;;; pai-prompts.el --- User prompt templates as slash commands -*- lexical-binding: t; -*-

;;; Commentary:

;; User prompt templates (pi's `.pi/prompts').  Prompts are markdown files,
;; optionally carrying YAML frontmatter with a name and description.  Each is
;; registered as a slash command that, when invoked, injects a rendered prompt
;; body (with argument substitution) as a user message to the agent.  Port of
;; the prompt-template discovery in the `pi' coding agent.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-config)
(require 'pai-core)
(require 'pai-commands)

(defun pai-prompts-default-dirs ()
  "Return the default prompt search directories that exist."
  (seq-filter #'file-directory-p
              (list (expand-file-name "prompts" pai-directory)
                    (expand-file-name ".pai/prompts" default-directory))))

(defun pai-prompts--parse-frontmatter (text)
  "Parse leading YAML frontmatter from TEXT.
Return (FIELDS . BODY) where FIELDS is an alist of string key/value and BODY
is the remaining text.  When there is no frontmatter, FIELDS is nil."
  (if (string-match "\\`---\r?\n\\(\\(?:.\\|\n\\)*?\\)\r?\n---\r?\n?" text)
      (let ((fm (match-string 1 text))
            (body (substring text (match-end 0)))
            (fields '()))
        (dolist (line (split-string fm "\n"))
          (when (string-match "\\`\\([A-Za-z0-9_-]+\\):[ \t]*\\(.*\\)\\'" line)
            (let ((k (match-string 1 line))
                  (v (string-trim (match-string 2 line))))
              (when (and (>= (length v) 2)
                         (or (and (string-prefix-p "\"" v) (string-suffix-p "\"" v))
                             (and (string-prefix-p "'" v) (string-suffix-p "'" v))))
                (setq v (substring v 1 -1)))
              (push (cons k v) fields))))
        (cons (nreverse fields) body))
    (cons nil text)))

(defun pai-prompts--first-line (body)
  "Return the first non-empty, trimmed line of BODY, or nil."
  (seq-some (lambda (line)
              (let ((l (string-trim line)))
                (and (not (string-empty-p l)) l)))
            (split-string (or body "") "\n")))

(defun pai-prompt-from-file (file)
  "Parse a prompt template from FILE, returning a prompt plist.
The plist has keys :name, :description, :path and :body.  NAME defaults to
the file base name (sans .md).  DESCRIPTION comes from frontmatter or the
first non-empty body line.  BODY is the markdown after any frontmatter."
  (let* ((text (with-temp-buffer (insert-file-contents file) (buffer-string)))
         (parsed (pai-prompts--parse-frontmatter text))
         (fields (car parsed))
         (body (cdr parsed))
         (name (or (cdr (assoc "name" fields))
                   (file-name-base file)))
         (description (or (cdr (assoc "description" fields))
                          (pai-prompts--first-line body)
                          "")))
    (list :name name
          :description description
          :path (expand-file-name file)
          :body body)))

(defun pai-prompts-discover (&optional dirs)
  "Discover prompt templates under DIRS (default `pai-prompts-default-dirs').
Return a list of prompt plists, de-duplicated by name (first wins),
scanning `*.md' files."
  (let ((seen (make-hash-table :test 'equal))
        (result '()))
    (dolist (dir (or dirs (pai-prompts-default-dirs)))
      (when (file-directory-p dir)
        (dolist (file (directory-files-recursively dir "\\.md\\'"))
          (let ((prompt (ignore-errors (pai-prompt-from-file file))))
            (when (and prompt (not (gethash (plist-get prompt :name) seen)))
              (puthash (plist-get prompt :name) prompt seen)
              (push prompt result))))))
    (nreverse result)))

(defun pai-prompt-render (body args)
  "Render prompt BODY, substituting arguments from ARGS.
`$ARGUMENTS' and `${ARGUMENTS}' expand to the full ARGS string; `$1'..`$9'
expand to the Nth whitespace-separated argument (empty when absent); `$$'
becomes a literal `$'.  Any other `$NAME' is left untouched.  Never signals."
  (let* ((args (or args ""))
         (parts (split-string (string-trim args) "[ \t\r\n]+" t)))
    (replace-regexp-in-string
     "\\$\\$\\|\\${ARGUMENTS}\\|\\$ARGUMENTS\\b\\|\\$[1-9]"
     (lambda (m)
       (cond
        ((string= m "$$") "$")
        ((or (string= m "${ARGUMENTS}") (string= m "$ARGUMENTS")) args)
        (t (or (nth (1- (string-to-number (substring m 1))) parts) ""))))
     (or body "") t t)))

(defun pai-prompts-register (&optional dirs)
  "Discover prompts under DIRS and register each as a slash command.
Each command's handler returns `(:send RENDERED)' where RENDERED is the
prompt body with arguments substituted.  Commands are marked with source
`prompt'.  Return the list of registered command names."
  (let ((names '()))
    (dolist (prompt (pai-prompts-discover dirs))
      (let ((name (plist-get prompt :name))
            (body (plist-get prompt :body)))
        (pai-register-command
         name
         :description (plist-get prompt :description)
         :source 'prompt
         :handler (lambda (args _ctx) (list :send (pai-prompt-render body args))))
        (push name names)))
    (nreverse names)))

(provide 'pai-prompts)
;;; pai-prompts.el ends here
