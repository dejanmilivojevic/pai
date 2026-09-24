;;; pai-trust.el --- Project trust store and gating for pai -*- lexical-binding: t; -*-

;;; Commentary:

;; Persistent per-directory trust decisions, mirroring pi's trust-manager /
;; project-trust.  A JSON object at `~/.pai/trust.json' maps canonical absolute
;; directory paths to booleans.  Before loading trust-requiring project
;; resources (project settings, extensions, skills, prompts, themes, system
;; prompt overrides, or top-level AGENTS.md/CLAUDE.md) the agent gates on the
;; recorded decision, inheriting the nearest ancestor's choice and falling back
;; to the `:default-project-trust' setting.
;;
;; The `/trust' slash command inspects and edits the decision for the current
;; project directory.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-core)
(require 'pai-config)
(require 'pai-settings)
(require 'pai-commands)

(defvar pai-trust--store nil
  "In-memory trust cache.
A hash table mapping canonical directory path strings to t or `:false',
or nil when the store has not been loaded from disk yet.")

;;;; Store file

(defun pai-trust-file ()
  "Return the path to the trust store file."
  (expand-file-name "trust.json" pai-directory))

(defun pai-trust-load ()
  "Read the trust file into `pai-trust--store' and return the store."
  (let ((store (make-hash-table :test 'equal))
        (file (pai-trust-file)))
    (when (file-readable-p file)
      (ignore-errors
        (let ((plist (with-temp-buffer
                       (insert-file-contents file)
                       (let ((s (string-trim (buffer-string))))
                         (unless (string-empty-p s) (pai-json-decode s))))))
          (while plist
            (let ((k (car plist)) (v (cadr plist)))
              (puthash (substring (symbol-name k) 1) v store))
            (setq plist (cddr plist))))))
    (setq pai-trust--store store)))

(defun pai-trust--ensure ()
  "Ensure `pai-trust--store' is loaded, then return it."
  (or pai-trust--store (pai-trust-load)))

(defun pai-trust--save ()
  "Persist `pai-trust--store' to the trust file."
  (let ((file (pai-trust-file)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (pai-json-encode (or pai-trust--store (pai-json-empty-object)))))))

;;;; Decisions

(defun pai-trust-canonical (dir)
  "Return the canonical absolute path for DIR, without a trailing slash."
  (directory-file-name (file-truename (expand-file-name dir))))

(defun pai-trust-get (dir)
  "Return the trust decision for DIR: `yes', `no', or `undecided'.
Looks up the canonical DIR exactly; if absent, walks up ancestor
directories and inherits the nearest recorded decision."
  (let ((store (pai-trust--ensure))
        (cur (pai-trust-canonical dir)))
    (catch 'done
      (while t
        (let ((v (gethash cur store 'missing)))
          (unless (eq v 'missing)
            (throw 'done (if (pai-truthy v) 'yes 'no))))
        (let ((parent (directory-file-name (file-name-directory cur))))
          (when (string= parent cur)
            (throw 'done 'undecided))
          (setq cur parent))))))

(defun pai-trust-set (dir trusted)
  "Record boolean TRUSTED for the canonical DIR and persist.  Return TRUSTED."
  (puthash (pai-trust-canonical dir) (if trusted t :false) (pai-trust--ensure))
  (pai-trust--save)
  trusted)

;;;; Gating

(defconst pai-trust--resource-paths
  '(".pai/settings.json" ".pai/extensions" ".pai/skills" ".pai/prompts"
    ".pai/themes" ".pai/SYSTEM.md" ".pai/APPEND_SYSTEM.md"
    "AGENTS.md" "CLAUDE.md")
  "Project resources whose presence requires a trust decision for a directory.")

(defun pai-project-has-resources-p (dir)
  "Return non-nil if DIR contains any trust-requiring project resource."
  (seq-some (lambda (p) (file-exists-p (expand-file-name p dir)))
            pai-trust--resource-paths))

(defun pai-trust-trusted-p (dir &optional prompt-fn)
  "Return non-nil if DIR should be trusted.
If the recorded decision is `yes' return t, if `no' return nil.  When
`undecided' and DIR has no trust-requiring resources, return t (nothing
to gate).  Otherwise consult the `:default-project-trust' setting:
\"always\" trusts, \"never\" denies, and \"ask\" calls PROMPT-FN with DIR.
PROMPT-FN returns a plist like (:trusted BOOL :remember BOOL); when
`:remember' is non-nil the decision is persisted.  With no PROMPT-FN in
\"ask\" mode the directory is denied (headless)."
  (pcase (pai-trust-get dir)
    ('yes t)
    ('no nil)
    (_
     (if (not (pai-project-has-resources-p dir))
         t
       (pcase (pai-settings-get :default-project-trust "ask")
         ("always" t)
         ("never" nil)
         (_
          (if prompt-fn
              (let* ((res (funcall prompt-fn dir))
                     (trusted (plist-get res :trusted)))
                (when (plist-get res :remember)
                  (pai-trust-set dir trusted))
                (and trusted t))
            nil)))))))

;;;; Slash command

(defun pai-trust-command (args ctx)
  "Handle the `/trust' command with ARGS in extension context CTX.
With no ARGS, show the current decision for the project directory; with
`yes' or `no', record it."
  (let* ((dir (or (plist-get ctx :cwd) default-directory))
         (arg (downcase (string-trim (or args "")))))
    (cond
     ((string-empty-p arg)
      (list :message (format "Trust for %s: %s"
                             (pai-trust-canonical dir)
                             (pai-trust-get dir))))
     ((string= arg "yes")
      (pai-trust-set dir t)
      (list :message (format "Trusted %s" (pai-trust-canonical dir))))
     ((string= arg "no")
      (pai-trust-set dir nil)
      (list :message (format "Removed trust for %s" (pai-trust-canonical dir))))
     (t (list :message "Usage: /trust [yes|no]")))))

(pai-register-command
 "trust"
 :description "Show or set trust for the current project directory"
 :handler #'pai-trust-command
 :arg-completions (lambda (_prefix) '("yes" "no")))

(provide 'pai-trust)
;;; pai-trust.el ends here
