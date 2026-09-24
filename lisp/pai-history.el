;;; pai-history.el --- Per-project input history for pai -*- lexical-binding: t; -*-

;;; Commentary:

;; Everything the user submits in a pai buffer -- prompts, slash commands and
;; `!' shell commands alike -- is recorded in a per-project history file under
;; `pai-directory' (history/<project-slug>.eld).  The file holds a single Lisp
;; list of strings, newest first.  All pai buffers of the same project share
;; it, and it survives restarts.
;;
;; The chat UI browses it with M-p / M-n (see `pai-history-previous' and
;; `pai-history-next' in pai-ui.el).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-config)

(defcustom pai-history-size 500
  "Maximum number of input history entries kept per project."
  :type 'integer
  :group 'pai)

(defun pai-history--slug (cwd)
  "Return a filesystem-safe slug for project directory CWD."
  (let ((s (directory-file-name (expand-file-name cwd))))
    (replace-regexp-in-string "^-+" "" (replace-regexp-in-string "[^A-Za-z0-9]+" "-" s))))

(defun pai-history-file (cwd)
  "Return the input history file for project CWD."
  (expand-file-name (concat (pai-history--slug cwd) ".eld")
                    (pai-state-directory "history")))

(defun pai-history-load (cwd)
  "Return the input history for project CWD, newest first."
  (let ((file (pai-history-file cwd)))
    (when (file-readable-p file)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents file)
            (let ((data (read (current-buffer))))
              (and (listp data) (cl-remove-if-not #'stringp data))))
        (error nil)))))

(defun pai-history-add (cwd text)
  "Record TEXT as the newest input history entry for project CWD.
An earlier identical entry is moved to the front rather than duplicated.
Return the updated history, newest first."
  (let ((text (string-trim text)))
    (if (string-empty-p text)
        (pai-history-load cwd)
      (let* ((hist (cons text (delete text (pai-history-load cwd))))
             (hist (seq-take hist pai-history-size))
             (file (pai-history-file cwd)))
        (with-temp-file file
          (let ((print-length nil) (print-level nil) (print-escape-newlines t))
            (insert ";; -*- mode: lisp-data -*-\n")
            (prin1 hist (current-buffer))
            (insert "\n")))
        hist))))

(provide 'pai-history)
;;; pai-history.el ends here
