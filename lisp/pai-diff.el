;;; pai-diff.el --- Unified diff generation and colorization -*- lexical-binding: t; -*-

;;; Commentary:

;; Produce and colorize unified diffs of two strings, for rendering file
;; edits/writes in the chat UI.  When the system `diff' program is available
;; it is used (via `call-process' on temp files); otherwise a naive
;; line-based fallback emits `-'/`+' lines for content that differs.

;;; Code:

(require 'subr-x)

(defface pai-diff-added
  '((t :inherit diff-added))
  "Face for added lines in a rendered diff."
  :group 'pai)

(defface pai-diff-removed
  '((t :inherit diff-removed))
  "Face for removed lines in a rendered diff."
  :group 'pai)

(defface pai-diff-hunk
  '((t :inherit diff-hunk-header))
  "Face for hunk headers (@@ ... @@) in a rendered diff."
  :group 'pai)

(defface pai-diff-header
  '((t :inherit diff-header))
  "Face for file headers (--- / +++) in a rendered diff."
  :group 'pai)

(defun pai-diff--fallback (old new old-name new-name)
  "Return a naive unified diff STRING for OLD and NEW.
Used when the system `diff' program is unavailable.  OLD-NAME and NEW-NAME
label the file headers.  Emits `-' lines for OLD content and `+' lines for
NEW content whenever the two differ, under a single hunk header."
  (let ((old-lines (split-string old "\n"))
        (new-lines (split-string new "\n")))
    (if (equal old-lines new-lines)
        ""
      (concat
       (format "--- %s\n" old-name)
       (format "+++ %s\n" new-name)
       (format "@@ -1,%d +1,%d @@\n" (length old-lines) (length new-lines))
       (mapconcat (lambda (l) (concat "-" l)) old-lines "\n") "\n"
       (mapconcat (lambda (l) (concat "+" l)) new-lines "\n") "\n"))))

(defun pai-diff-unified (old new &optional old-name new-name)
  "Return a unified-diff STRING comparing OLD and NEW strings.
OLD-NAME and NEW-NAME default to \"a\" and \"b\" for the `---'/`+++'
headers.  Uses the system `diff -u' when available, otherwise a naive
line-based fallback.  Never signals: returns \"\" on failure."
  (let ((old-name (or old-name "a"))
        (new-name (or new-name "b")))
    (condition-case nil
        (if (executable-find "diff")
            (let ((old-file (make-temp-file "pai-diff-old"))
                  (new-file (make-temp-file "pai-diff-new")))
              (unwind-protect
                  (progn
                    (let ((coding-system-for-write 'utf-8))
                      (write-region old nil old-file nil 'silent)
                      (write-region new nil new-file nil 'silent))
                    (with-temp-buffer
                      (let ((status (call-process
                                     "diff" nil t nil
                                     "-u"
                                     "--label" old-name
                                     "--label" new-name
                                     old-file new-file)))
                        ;; diff exits 0 (same) or 1 (differ); >=2 is error.
                        (if (>= status 2)
                            ""
                          (buffer-string)))))
                (ignore-errors (delete-file old-file))
                (ignore-errors (delete-file new-file))))
          (pai-diff--fallback old new old-name new-name))
      (error ""))))

(defun pai-diff--content-line-p (line)
  "Return non-nil when LINE is a diff content add/remove line.
File headers (`---'/`+++') are excluded."
  (and (> (length line) 0)
       (or (and (eq (aref line 0) ?+) (not (string-prefix-p "+++" line)))
           (and (eq (aref line 0) ?-) (not (string-prefix-p "---" line))))))

(defun pai-diff-stat (old new)
  "Return a plist (:added N :removed M) for the diff of OLD and NEW.
Counts added (`+') and removed (`-') content lines, excluding headers."
  (let ((added 0) (removed 0))
    (dolist (line (split-string (pai-diff-unified old new) "\n"))
      (when (pai-diff--content-line-p line)
        (if (eq (aref line 0) ?+)
            (setq added (1+ added))
          (setq removed (1+ removed)))))
    (list :added added :removed removed)))

(defun pai-diff-render (old new &optional old-name new-name)
  "Return a PROPERTIZED unified-diff string for OLD and NEW.
Added lines carry face `pai-diff-added', removed lines `pai-diff-removed',
hunk headers `pai-diff-hunk', and file headers `pai-diff-header'.
OLD-NAME and NEW-NAME label the file headers."
  (let* ((diff (pai-diff-unified old new old-name new-name))
         (lines (split-string diff "\n"))
         (out '()))
    (dolist (line lines)
      (let ((face
             (cond
              ((string-prefix-p "+++" line) 'pai-diff-header)
              ((string-prefix-p "---" line) 'pai-diff-header)
              ((string-prefix-p "@@" line) 'pai-diff-hunk)
              ((and (> (length line) 0) (eq (aref line 0) ?+)) 'pai-diff-added)
              ((and (> (length line) 0) (eq (aref line 0) ?-)) 'pai-diff-removed)
              (t nil))))
        (push (if face (propertize line 'face face) line) out)))
    (mapconcat #'identity (nreverse out) "\n")))

(provide 'pai-diff)

;;; pai-diff.el ends here
