;;; pai-skills.el --- Agent skills discovery -*- lexical-binding: t; -*-

;;; Commentary:

;; Skills are markdown files (`SKILL.md' or `*.md') carrying YAML frontmatter
;; with a name and description.  They provide on-demand, specialized guidance:
;; the model sees a compact list of available skills in its system prompt and
;; reads the full skill file with the `read' tool when relevant.  Port of
;; packages/coding-agent/src/core/skills.ts.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-config)

(defun pai-skills-default-dirs ()
  "Return the default skill search directories that exist."
  (seq-filter #'file-directory-p
              (list (expand-file-name "skills" pai-directory)
                    (expand-file-name ".pai/skills" default-directory)
                    (expand-file-name ".skills" default-directory))))

(defun pai-skills--parse-frontmatter (text)
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

(defun pai-skills--valid-name-p (name)
  "Return non-nil if NAME is a valid skill name."
  (and (stringp name)
       (<= (length name) 64)
       (string-match-p "\\`[a-z0-9]+\\(-[a-z0-9]+\\)*\\'" name)))

(defun pai-skill-from-file (file)
  "Parse a skill from FILE, returning a skill plist or nil if invalid."
  (let* ((text (with-temp-buffer (insert-file-contents file) (buffer-string)))
         (parsed (pai-skills--parse-frontmatter text))
         (fields (car parsed))
         (name (or (cdr (assoc "name" fields))
                   (let ((dir (file-name-nondirectory (directory-file-name (file-name-directory file)))))
                     (if (equal (file-name-nondirectory file) "SKILL.md") dir
                       (file-name-base file)))))
         (description (cdr (assoc "description" fields)))
         (disable (member (cdr (assoc "disable-model-invocation" fields)) '("true" "yes")))
         (bundles (let ((b (cdr (assoc "bundle" fields))))
                    (and b (split-string b "[][, \t\"']+" t)))))
    (when (and (pai-skills--valid-name-p name)
               (stringp description) (not (string-empty-p description))
               (<= (length description) 1024))
      (list :name name :description description :path (expand-file-name file)
            :disable-model-invocation (and disable t)
            :bundles bundles
            :body (cdr parsed)))))

(defun pai-discover-skills (&optional dirs)
  "Discover skills under DIRS (default `pai-skills-default-dirs').
Return a list of skill plists, de-duplicated by name (first wins)."
  (let ((seen (make-hash-table :test 'equal))
        (result '()))
    (dolist (dir (or dirs (pai-skills-default-dirs)))
      (when (file-directory-p dir)
        ;; Hidden subdirectories (.git, .runs, ...) are never descended into.
        (dolist (file (directory-files-recursively
                       dir "\\.md\\'" nil
                       (lambda (sub)
                         (not (string-prefix-p "." (file-name-nondirectory
                                                    (directory-file-name sub)))))))
          (let ((skill (ignore-errors (pai-skill-from-file file))))
            (when (and skill (not (gethash (plist-get skill :name) seen)))
              (puthash (plist-get skill :name) skill seen)
              (push skill result))))))
    (nreverse result)))

(defun pai-skills-prompt-section (skills)
  "Return the <skills> system-prompt section string for SKILLS, or nil.
Skills with :disable-model-invocation are excluded (slash-command only)."
  (let ((usable (seq-remove (lambda (s) (plist-get s :disable-model-invocation)) skills)))
    (when usable
      (concat
       "The following skills provide specialized instructions for specific tasks.\n"
       "Read the skill file with the read tool when relevant to the user's request.\n\n"
       (mapconcat
        (lambda (s)
          (format "<skill>\n<name>%s</name>\n<description>%s</description>\n<location>%s</location>\n</skill>"
                  (plist-get s :name) (plist-get s :description) (plist-get s :path)))
        usable "\n")))))

(provide 'pai-skills)
;;; pai-skills.el ends here
