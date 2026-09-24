;;; pai-settings.el --- Layered settings for pai -*- lexical-binding: t; -*-

;;; Commentary:

;; Persistent, layered settings mirroring pi's settings-manager: a global file
;; (`~/.pai/settings.json') and a project file (`<project>/.pai/settings.json'),
;; merged over built-in defaults.  Precedence: project > global > default.
;; Settings are keyword-keyed plists round-tripped as JSON.
;;
;; The `/settings' slash command inspects and edits them.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-core)
(require 'pai-config)
(require 'pai-commands)

(defvar pai-settings-defaults
  (list :model nil
        :thinking-level "off"
        :theme "default"
        :auto-compact t
        :compact-threshold 0.85
        :tool-execution "parallel"
        :max-tokens nil
        :temperature nil
        :stream-chunks t
        :footer-position "mode-line"
        :lsp (list :backend 'eglot
                   :enabled t
                   :servers '())
        :debug (list :enabled t))
  "Built-in default settings, used when neither project nor global sets a key.")

(defvar pai-settings--global nil "Loaded global settings plist.")
(defvar pai-settings--project nil "Loaded project settings plist.")
(defvar pai-settings--project-dir nil "Directory the project settings were loaded from.")

;;;; Files

(defun pai-settings-global-file ()
  "Return the path to the global settings file."
  (expand-file-name "settings.json" pai-directory))

(defun pai-settings-project-file (&optional dir)
  "Return the path to the project settings file for DIR (default cwd)."
  (expand-file-name ".pai/settings.json" (or dir default-directory)))

(defun pai-settings--read (file)
  "Read and decode settings FILE, returning a plist or nil."
  (when (and file (file-readable-p file))
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents file)
        (let ((s (string-trim (buffer-string))))
          (unless (string-empty-p s) (pai-json-decode s)))))))

(defcustom pai-settings-backups 20
  "How many earlier versions of each settings file to keep (0: none).
Before a settings file is overwritten, its previous content is copied to
`pai-settings-backup-directory'; `pai-settings-restore-backup' puts one back."
  :type 'integer
  :group 'pai)

(defun pai-settings-backup-directory ()
  "Return the directory holding settings backups."
  (expand-file-name "backups/settings/" pai-directory))

(defun pai-settings--backup-prefix (file)
  "Return the backup file name prefix of settings FILE."
  (concat (replace-regexp-in-string "[^A-Za-z0-9._-]+" "-"
                                    (string-trim (abbreviate-file-name (expand-file-name file))
                                                 "[~/.]+"))
          "--"))

(defun pai-settings-backups-of (file)
  "Return the backups of settings FILE, newest first."
  (let ((dir (pai-settings-backup-directory)))
    (and (file-directory-p dir)
         (sort (directory-files dir t (concat "\\`" (regexp-quote (pai-settings--backup-prefix file))
                                              "[0-9T]+\\.json\\'"))
               (lambda (a b) (string> a b))))))

(defun pai-settings--backup (file new-text)
  "Save FILE's current content as a backup when NEW-TEXT would replace it."
  (when (and (> pai-settings-backups 0) (file-readable-p file))
    (let ((old (with-temp-buffer (insert-file-contents file) (buffer-string))))
      (unless (or (string-empty-p (string-trim old)) (equal (string-trim old) (string-trim new-text)))
        (let ((dir (pai-settings-backup-directory)))
          (make-directory dir t)
          (let ((coding-system-for-write 'utf-8))
            (write-region old nil (expand-file-name
                                   (concat (pai-settings--backup-prefix file)
                                           (format-time-string "%Y%m%dT%H%M%S%6N") ".json")
                                   dir)
                          nil 'silent))
          (dolist (stale (nthcdr pai-settings-backups (pai-settings-backups-of file)))
            (ignore-errors (delete-file stale))))))))

(defun pai-settings--write (file plist)
  "Write settings PLIST to FILE as JSON, creating parent directories.
The previous content is kept as a backup (see `pai-settings-backups')."
  (make-directory (file-name-directory file) t)
  (let ((text (pai-json-encode (or plist (pai-json-empty-object)))))
    (ignore-errors (pai-settings--backup file text))
    (with-temp-file file (insert text))))

(defun pai-settings-restore-backup (file backup)
  "Restore settings FILE from BACKUP (the current content is backed up first).
Interactively choose the file (global or this project's) and one of its
backups.  Open pai buffers pick the restored settings up on `/reload'."
  (interactive
   (let* ((files (delq nil (list (pai-settings-global-file)
                                 (let ((p (pai-settings-project-file)))
                                   (and (pai-settings-backups-of p) p)))))
          (file (if (cdr files)
                    (completing-read "Restore settings file: " files nil t nil nil (car files))
                  (car files)))
          (backups (pai-settings-backups-of file)))
     (unless backups (user-error "No backups of %s" (abbreviate-file-name file)))
     (list file (completing-read (format "Restore %s from: " (abbreviate-file-name file))
                                 backups nil t nil nil (car backups)))))
  (let ((text (with-temp-buffer (insert-file-contents backup) (buffer-string))))
    (unless (ignore-errors (pai-json-decode (string-trim text)) t)
      (user-error "%s is not valid JSON" backup))
    (make-directory (file-name-directory file) t)
    (pai-settings--backup file text)
    (with-temp-file file (insert text))
    (message "Restored %s from %s; /reload to apply" (abbreviate-file-name file)
             (file-name-nondirectory backup))
    file))

;;;; Load / merge

(defvar pai-settings-changed-hook nil
  "Normal hook run after settings were loaded or a setting was set.")

(defun pai-settings--changed ()
  "Run `pai-settings-changed-hook', reporting (not raising) handler errors."
  (condition-case err (run-hooks 'pai-settings-changed-hook)
    (error (message "pai: settings hook failed: %s" (error-message-string err)))))

(defun pai-settings-load (&optional project-dir)
  "Load global and PROJECT-DIR settings into memory.  Return the merged plist."
  (setq pai-settings--global (pai-settings--read (pai-settings-global-file)))
  (setq pai-settings--project-dir (and project-dir (expand-file-name project-dir)))
  (setq pai-settings--project
        (and project-dir (pai-settings--read (pai-settings-project-file project-dir))))
  (pai-settings--changed)
  (pai-settings-merged))

(defvar pai-settings--lazy nil
  "(MTIME . PLIST): the global settings `pai-settings--ensure-loaded' read last.")

(defun pai-settings--mtime (file)
  "Return FILE's modification time, or nil."
  (file-attribute-modification-time (file-attributes file)))

(defun pai-settings--ensure-loaded ()
  "Load the global settings when they are empty here but not on disk.
Settings live in each pai buffer; code running elsewhere (the minibuffer,
a timer, another buffer) would otherwise see none, and a value it derives
from them -- e.g. a whole `:extensions' map with one key changed -- would
drop everything else when saved.  Settings that are set, even to test
values, are left alone."
  (let ((file (pai-settings-global-file)))
    (when (and (or (null pai-settings--global)
                   ;; a copy loaded here earlier is refreshed when the file
                   ;; changed since (another buffer saved a setting)
                   (and pai-settings--lazy
                        (eq pai-settings--global (cdr pai-settings--lazy))
                        (not (equal (car pai-settings--lazy) (pai-settings--mtime file)))))
               (file-readable-p file))
      (let ((plist (pai-settings--read file)))
        (setq pai-settings--global plist
              pai-settings--lazy (cons (pai-settings--mtime file) plist))))))

(defun pai-settings-merged ()
  "Return the merged settings plist (project > global > defaults)."
  (pai-settings--ensure-loaded)
  (append pai-settings--project pai-settings--global pai-settings-defaults))

(defun pai-settings-get (key &optional default)
  "Return the value of setting KEY, or DEFAULT when unset."
  (let ((merged (pai-settings-merged)))
    (if (plist-member merged key) (plist-get merged key) default)))

(defun pai-settings-scope-value (key scope)
  "Return KEY's raw value from SCOPE (`global' or `project') only.
Unlike `pai-settings-get', this does NOT merge across scopes or defaults, so a
caller can implement per-key precedence itself.  Returns nil when unset."
  (pai-settings--ensure-loaded)
  (plist-get (pcase scope ('project pai-settings--project) (_ pai-settings--global))
             key))

(defun pai-settings-scope-has (key scope)
  "Return non-nil if KEY is explicitly present in SCOPE's raw plist."
  (pai-settings--ensure-loaded)
  (plist-member (pcase scope ('project pai-settings--project) (_ pai-settings--global))
                key))

;;;; Set / save

(defun pai-settings-save (&optional scope)
  "Persist settings for SCOPE (`global' or `project')."
  (pcase scope
    ('project
     (when pai-settings--project-dir
       (pai-settings--write (pai-settings-project-file pai-settings--project-dir)
                            pai-settings--project)))
    (_ (pai-settings--write (pai-settings-global-file) pai-settings--global))))

(defun pai-settings-set (key value &optional scope)
  "Set setting KEY to VALUE in SCOPE (`global' default, or `project'); persist.
Only KEY changes on disk: the file is re-read and KEY put into it, so a
caller whose in-memory settings are stale or empty -- e.g. code running
outside the pai buffer that owns them (settings are per buffer) -- can
never overwrite the other settings.  Return VALUE."
  (pai-settings--ensure-loaded)
  (pcase scope
    ('project
     (setq pai-settings--project (plist-put (copy-sequence pai-settings--project) key value))
     (when pai-settings--project-dir
       (let ((file (pai-settings-project-file pai-settings--project-dir)))
         (pai-settings--write file (plist-put (copy-sequence (pai-settings--read file)) key value)))))
    (_
     (let ((lazy (and pai-settings--lazy (eq pai-settings--global (cdr pai-settings--lazy))))
           (file (pai-settings-global-file)))
       (setq pai-settings--global (plist-put (copy-sequence pai-settings--global) key value))
       (pai-settings--write file (plist-put (copy-sequence (pai-settings--read file)) key value))
       ;; a lazily loaded copy stays one: keep following the file
       (when lazy
         (setq pai-settings--lazy (cons (pai-settings--mtime file) pai-settings--global))))))
  (pai-settings--changed)
  value)

(defun pai-settings--coerce (key str)
  "Coerce STR to a value appropriate for setting KEY."
  (cond
   ((member str '("true" "yes" "on")) t)
   ((member str '("false" "no" "off"))
    (if (eq key :thinking-level) "off" :false))
   ((string-match-p "\\`-?[0-9]+\\'" str) (truncate (string-to-number str)))
   ((string-match-p "\\`-?[0-9]*\\.[0-9]+\\'" str) (string-to-number str))
   (t str)))

(defun pai-settings--describe ()
  "Return a human-readable description of the merged settings."
  (let ((merged (pai-settings-merged)) (lines '()) (rest nil))
    (setq rest merged)
    (while rest
      (push (format "  %s = %S" (substring (symbol-name (car rest)) 1) (cadr rest)) lines)
      (setq rest (cddr rest)))
    (concat "Settings (project > global > default):\n"
            (string-join (nreverse (delete-dups lines)) "\n")
            "\n\nUse: /settings menu  |  set KEY VALUE  |  get KEY  |  edit")))

(defun pai-settings-command (args _ctx)
  "Handler for the `/settings' slash command with ARGS."
  (let* ((parts (split-string (string-trim args) " " t))
         (verb (car parts)))
    (pcase verb
      ("menu"
       (if (fboundp 'pai-settings-ui-open)
           (progn (funcall (intern "pai-settings-ui-open"))
                  (list :message "Opening settings screen…"))
         (list :message "Settings screen unavailable (vui not loaded)")))
      ("set"
       (let* ((key (intern (concat ":" (nth 1 parts))))
              (raw (string-join (cddr parts) " "))
              (val (pai-settings--coerce key raw)))
         (pai-settings-set key val 'project)
         (list :message (format "set %s = %S (project)" (nth 1 parts) val))))
      ("get"
       (let ((key (intern (concat ":" (nth 1 parts)))))
         (list :message (format "%s = %S" (nth 1 parts) (pai-settings-get key)))))
      ("edit"
       (find-file (pai-settings-global-file))
       (list :message "Editing global settings; save the buffer to apply."))
      (_ (list :message (pai-settings--describe))))))

(defvar pai-thinking-levels)

(defun pai-settings--key-names ()
  "Return the names of the settings currently set (for completion)."
  (let ((merged (pai-settings-merged)) (out '()))
    (while merged
      (push (substring (symbol-name (car merged)) 1) out)
      (setq merged (cddr merged)))
    ;; copy: `sort' is destructive and `append' shares its last argument
    (sort (delete-dups (append out (copy-sequence
                                    '("preview-resume" "preview-tree" "auto-compact"
                                      "stream-chunks" "footer-position" "thinking-level"))))
          #'string<)))

(defun pai-settings--value-nodes (name)
  "Return the values to offer for setting NAME (a string)."
  (let ((v (pai-settings-get (intern (concat ":" name)))))
    (cond
     ((equal name "thinking-level") (and (boundp 'pai-thinking-levels) pai-thinking-levels))
     ((equal name "footer-position") '("mode-line" "above-prompt"))
     ((or (eq v t) (eq v :false)
          (member name '("preview-resume" "preview-tree" "auto-compact" "stream-chunks")))
      '("true" "false")))))

(defconst pai-settings-completion-tree
  `("menu"
    ("set" ,(lambda () (mapcar (lambda (k) (cons k (lambda () (pai-settings--value-nodes k))))
                               (pai-settings--key-names))))
    ("get" ,#'pai-settings--key-names)
    "edit")
  "What `/settings' completes at each argument position.")

(pai-register-command
 "settings"
 :description "View or change pai settings (set/get/edit)"
 :handler #'pai-settings-command
 :arg-completions (pai-command-completion-tree pai-settings-completion-tree))

(provide 'pai-settings)
;;; pai-settings.el ends here
