;;; pai-tools-builtin.el --- Built-in tools for pai -*- lexical-binding: t; -*-

;;; Commentary:

;; The built-in tool set, implemented using Emacs as the operating system:
;; filesystem tools via Emacs file primitives, `bash' via `make-process',
;; search via ripgrep/grep with elisp fallbacks, and Emacs-native tools that
;; expose the live editor to the model (`elisp_eval', buffer inspection).
;;
;; Faithful in spirit to packages/coding-agent/src/core/tools/*.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-core)
(require 'pai-tools)

;;;; bash -----------------------------------------------------------------

(defun pai-tool-bash--env (ctx)
  "Return PAI_* environment entries derived from tool CTX."
  (let ((model (plist-get ctx :model)))
    (append
     (when model (list (format "PAI_MODEL=%s" (plist-get model :id))
                       (format "PAI_PROVIDER=%s" (plist-get model :provider))))
     (when (plist-get ctx :tool-call-id)
       (list (format "PAI_TOOL_CALL_ID=%s" (plist-get ctx :tool-call-id)))))))

(defun pai-tool-bash--execute (args ctx on-update on-done)
  "Run the bash tool for ARGS in CTX, streaming via ON-UPDATE, finishing ON-DONE."
  (let* ((command (plist-get args :command))
         (timeout (plist-get args :timeout))
         (default-directory (pai-tool-ctx-cwd ctx))
         (output "")
         (process-environment (append (pai-tool-bash--env ctx) process-environment))
         (finished nil)
         proc timer)
    (cl-flet ((done (code)
                (unless finished
                  (setq finished t)
                  (when timer (cancel-timer timer))
                  (let* ((trunc (pai-tools-truncate output nil nil 'tail))
                         (text (plist-get trunc :text))
                         (note (when (plist-get trunc :truncated)
                                 (format "\n[output truncated to last %d lines]" pai-tool-max-lines)))
                         (body (concat (if (string-empty-p (string-trim text)) "(no output)" text) note
                                       (unless (eq code 0) (format "\n[exited with code %s]" code)))))
                    (funcall on-done (list :content (list (pai-text body))
                                           :is-error (if (eq code 0) :false t)
                                           :details (list :exit-code code)))))))
      (condition-case err
          (setq proc (make-process
                      :name "pai-bash"
                      :command (list shell-file-name shell-command-switch command)
                      :connection-type 'pipe :noquery t :coding 'utf-8
                      :filter (lambda (_p chunk)
                                (setq output (concat output chunk))
                                (when on-update
                                  (funcall on-update (pai-tool-ok-result output))))
                      :sentinel (lambda (p _e)
                                  (when (memq (process-status p) '(exit signal))
                                    (done (process-exit-status p))))))
        (error (funcall on-done (pai-tool-error-result
                                 (format "Failed to start bash: %s" (error-message-string err))))))
      (when (and (numberp timeout) (> timeout 0))
        (setq timer (run-at-time timeout nil
                                 (lambda ()
                                   (when (and proc (process-live-p proc))
                                     (delete-process proc)
                                     (setq output (concat output "\n[timed out]")))))))
      proc)))

(pai-register-tool
 (list :name "bash"
       :label "Bash"
       :description "Execute a shell command with bash and return its combined stdout/stderr. Use for running programs, git, package managers, and file operations that are not covered by dedicated tools."
       :prompt-snippet "bash: run a shell command"
       :execution-mode 'sequential
       :parameters (pai-object-schema
                    (list :command (pai-string-schema "The shell command to execute.")
                          :timeout (pai-number-schema "Optional timeout in seconds."))
                    '("command"))
       :execute #'pai-tool-bash--execute))

;;;; read -----------------------------------------------------------------

(defconst pai-tool--image-extensions '("png" "jpg" "jpeg" "gif" "webp" "bmp")
  "File extensions treated as images by the read tool.")

(defun pai-tool--image-mime (path)
  "Return the image MIME type for PATH based on its extension, or nil."
  (pcase (downcase (or (file-name-extension path) ""))
    ("png" "image/png") ("jpg" "image/jpeg") ("jpeg" "image/jpeg")
    ("gif" "image/gif") ("webp" "image/webp") ("bmp" "image/bmp") (_ nil)))

(defun pai-tool-read--execute (args ctx _on-update on-done)
  "Run the read tool for ARGS in CTX, finishing via ON-DONE."
  (let* ((path (pai-tool-resolve-path ctx (plist-get args :path)))
         (offset (plist-get args :offset))
         (limit (plist-get args :limit)))
    (cond
     ((not (file-exists-p path))
      (funcall on-done (pai-tool-error-result (format "File not found: %s" path))))
     ((file-directory-p path)
      (funcall on-done (pai-tool-error-result (format "Path is a directory: %s" path))))
     ((member (downcase (or (file-name-extension path) "")) pai-tool--image-extensions)
      (let ((data (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally path)
                    (base64-encode-string (buffer-string) t))))
        (funcall on-done (list :content (list (pai-image data (pai-tool--image-mime path)))
                               :is-error :false))))
     (t
      (let* ((text (with-temp-buffer
                     (insert-file-contents path)
                     (buffer-string)))
             (all-lines (split-string text "\n"))
             (total (length all-lines))
             (start (if offset (max 0 (1- offset)) 0))
             (chosen (nthcdr start all-lines))
             (chosen (if limit (seq-take chosen limit) chosen))
             (trunc (pai-tools-truncate (string-join chosen "\n") nil nil 'head))
             (body (plist-get trunc :text))
             (shown (min (length chosen) pai-tool-max-lines))
             (note (when (or (plist-get trunc :truncated) limit (and offset (> offset 1)))
                     (format "\n[showing lines %d-%d of %d; use offset/limit to page]"
                             (1+ start) (+ start shown) total))))
        (funcall on-done (pai-tool-ok-result (concat body note)
                                             (list :total-lines total))))))))

(pai-register-tool
 (list :name "read"
       :label "Read"
       :description "Read the contents of a file. Supports text files (with optional line offset/limit) and images. Prefer this over `cat`/`sed`."
       :prompt-snippet "read: read a file's contents"
       :parameters (pai-object-schema
                    (list :path (pai-string-schema "Path to the file, absolute or relative to the working directory.")
                          :offset (pai-number-schema "1-based line to start reading from.")
                          :limit (pai-number-schema "Maximum number of lines to read."))
                    '("path"))
       :execute #'pai-tool-read--execute))

;;;; write ----------------------------------------------------------------

(defun pai-tool-write--execute (args ctx _on-update on-done)
  "Run the write tool for ARGS in CTX, finishing via ON-DONE."
  (let* ((path (pai-tool-resolve-path ctx (plist-get args :path)))
         (content (or (plist-get args :content) "")))
    (condition-case err
        (let ((old (when (file-exists-p path)
                     (with-temp-buffer (insert-file-contents path) (buffer-string)))))
          (let ((dir (file-name-directory path)))
            (when (and dir (not (file-exists-p dir))) (make-directory dir t)))
          (let ((coding-system-for-write 'utf-8))
            (with-temp-file path (insert content)))
          (funcall on-done (pai-tool-ok-result
                            (format "Wrote %d byte(s) to %s" (string-bytes content) path)
                            (list :old (or old "") :new content :path path
                                  :created (not old)))))
      (error (funcall on-done (pai-tool-error-result
                               (format "Failed to write %s: %s" path (error-message-string err))))))))

(pai-register-tool
 (list :name "write"
       :label "Write"
       :description "Create or overwrite a file with the given contents. Parent directories are created as needed. Use `edit` for changes to existing files."
       :prompt-snippet "write: create or overwrite a file"
       :execution-mode 'sequential
       :parameters (pai-object-schema
                    (list :path (pai-string-schema "Path to the file to write.")
                          :content (pai-string-schema "The full contents to write."))
                    '("path" "content"))
       :execute #'pai-tool-write--execute))

;;;; edit ----------------------------------------------------------------

(defun pai-tool--count-occurrences (needle)
  "Count non-overlapping occurrences of NEEDLE from point-min in current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((n 0))
      (while (search-forward needle nil t) (setq n (1+ n)))
      n)))

(defun pai-tool-edit--execute (args ctx _on-update on-done)
  "Run the edit tool for ARGS in CTX, finishing via ON-DONE."
  (let* ((path (pai-tool-resolve-path ctx (plist-get args :path)))
         (edits (plist-get args :edits)))
    (cond
     ((not (file-exists-p path))
      (funcall on-done (pai-tool-error-result (format "File not found: %s" path))))
     ((null edits)
      (funcall on-done (pai-tool-error-result "No edits provided.")))
     (t
      (condition-case err
          (let ((count 0)
                (old-content (with-temp-buffer (insert-file-contents path) (buffer-string)))
                (new-content nil))
            (with-temp-buffer
              (insert old-content)
              (dolist (e edits)
                (let* ((old (plist-get e :oldText))
                       (new (or (plist-get e :newText) ""))
                       (n (pai-tool--count-occurrences old)))
                  (cond
                   ((string-empty-p (or old ""))
                    (error "An edit has empty oldText"))
                   ((= n 0)
                    (error "oldText not found: %s" (truncate-string-to-width old 60)))
                   ((> n 1)
                    (error "oldText is ambiguous (%d matches): %s" n
                           (truncate-string-to-width old 60)))
                   (t (goto-char (point-min))
                      (search-forward old nil t)
                      (replace-match new t t)
                      (setq count (1+ count))))))
              (setq new-content (buffer-string))
              (let ((coding-system-for-write 'utf-8))
                (write-region (point-min) (point-max) path)))
            (funcall on-done (pai-tool-ok-result
                              (format "Replaced %d block(s) in %s" count path)
                              (list :blocks count :old old-content :new new-content
                                    :path path))))
        (error (funcall on-done (pai-tool-error-result
                                 (format "%s" (error-message-string err))))))))))

(pai-register-tool
 (list :name "edit"
       :label "Edit"
       :description "Make precise edits to an existing file by replacing exact text. Each edit's oldText must occur exactly once. Provide one or more {oldText,newText} pairs."
       :prompt-snippet "edit: replace exact text in a file"
       :execution-mode 'sequential
       :parameters (pai-object-schema
                    (list :path (pai-string-schema "Path to the file to edit.")
                          :edits (pai-array-schema
                                  "List of exact-text replacements to apply in order."
                                  (pai-object-schema
                                   (list :oldText (pai-string-schema "Exact text to find (must be unique).")
                                         :newText (pai-string-schema "Replacement text."))
                                   '("oldText" "newText"))))
                    '("path" "edits"))
       :execute #'pai-tool-edit--execute))

;;;; ls -------------------------------------------------------------------

(defun pai-tool-ls--execute (args ctx _on-update on-done)
  "Run the ls tool for ARGS in CTX, finishing via ON-DONE."
  (let* ((path (pai-tool-resolve-path ctx (or (plist-get args :path) ".")))
         (limit (or (plist-get args :limit) 500)))
    (if (not (file-directory-p path))
        (funcall on-done (pai-tool-error-result (format "Not a directory: %s" path)))
      (let* ((entries (sort (seq-remove (lambda (f) (member f '("." "..")))
                                        (directory-files path))
                            #'string<))
             (total (length entries))
             (shown (seq-take entries limit))
             (lines (mapcar (lambda (f)
                              (if (file-directory-p (expand-file-name f path))
                                  (concat f "/") f))
                            shown))
             (note (when (> total limit) (format "\n[%d of %d entries shown]" limit total))))
        (funcall on-done (pai-tool-ok-result
                          (concat (string-join lines "\n") note)))))))

(pai-register-tool
 (list :name "ls"
       :label "List"
       :description "List the entries of a directory. Directories are suffixed with a slash."
       :prompt-snippet "ls: list a directory"
       :parameters (pai-object-schema
                    (list :path (pai-string-schema "Directory to list (default: working directory).")
                          :limit (pai-number-schema "Maximum entries to return."))
                    nil)
       :execute #'pai-tool-ls--execute))

;;;; grep -----------------------------------------------------------------

(defun pai-tool-grep--execute (args ctx _on-update on-done)
  "Run the grep tool for ARGS in CTX, finishing via ON-DONE."
  (let* ((pattern (plist-get args :pattern))
         (path (pai-tool-resolve-path ctx (or (plist-get args :path) ".")))
         (ignore-case (pai-truthy (plist-get args :ignoreCase)))
         (literal (pai-truthy (plist-get args :literal)))
         (limit (or (plist-get args :limit) 100))
         (default-directory (pai-tool-ctx-cwd ctx))
         (rg (executable-find "rg"))
         (grep (executable-find "grep")))
    (condition-case err
        (let* ((out (with-output-to-string
                      (with-current-buffer standard-output
                        (cond
                         (rg (apply #'call-process rg nil t nil
                                    (append '("--line-number" "--no-heading" "--color" "never")
                                            (when ignore-case '("--ignore-case"))
                                            (when literal '("--fixed-strings"))
                                            (list "-e" pattern "--" path))))
                         (grep (apply #'call-process grep nil t nil
                                      (append '("-rnI")
                                              (when ignore-case '("-i"))
                                              (when literal '("-F"))
                                              (list "-e" pattern path))))
                         (t (error "Neither rg nor grep is available"))))))
               (lines (seq-remove #'string-empty-p (split-string out "\n")))
               (total (length lines))
               (shown (seq-take lines limit))
               (note (when (> total limit) (format "\n[%d of %d matches shown]" limit total))))
          (funcall on-done (pai-tool-ok-result
                            (if lines (concat (string-join shown "\n") note)
                              "(no matches)"))))
      (error (funcall on-done (pai-tool-error-result (error-message-string err)))))))

(pai-register-tool
 (list :name "grep"
       :label "Grep"
       :description "Search file contents for a pattern (regular expression by default) using ripgrep or grep. Returns file:line:match lines."
       :prompt-snippet "grep: search file contents"
       :parameters (pai-object-schema
                    (list :pattern (pai-string-schema "The search pattern (regex unless literal).")
                          :path (pai-string-schema "File or directory to search (default: working directory).")
                          :ignoreCase (pai-boolean-schema "Case-insensitive search.")
                          :literal (pai-boolean-schema "Treat the pattern as a literal string.")
                          :limit (pai-number-schema "Maximum matches to return."))
                    '("pattern"))
       :execute #'pai-tool-grep--execute))

;;;; find -----------------------------------------------------------------

(defun pai-tool-find--execute (args ctx _on-update on-done)
  "Run the find tool for ARGS in CTX, finishing via ON-DONE."
  (let* ((pattern (or (plist-get args :pattern) ""))
         (path (pai-tool-resolve-path ctx (or (plist-get args :path) ".")))
         (limit (or (plist-get args :limit) 1000)))
    (condition-case err
        (let* ((all (directory-files-recursively
                     path (if (string-empty-p pattern) ".*" pattern) nil))
               (rel (mapcar (lambda (f) (file-relative-name f (pai-tool-ctx-cwd ctx))) all))
               (total (length rel))
               (shown (seq-take rel limit))
               (note (when (> total limit) (format "\n[%d of %d paths shown]" limit total))))
          (funcall on-done (pai-tool-ok-result
                            (if rel (concat (string-join shown "\n") note) "(no matches)"))))
      (error (funcall on-done (pai-tool-error-result (error-message-string err)))))))

(pai-register-tool
 (list :name "find"
       :label "Find"
       :description "Find files whose names match a regular expression, searching recursively from a directory."
       :prompt-snippet "find: find files by name"
       :parameters (pai-object-schema
                    (list :pattern (pai-string-schema "Emacs regexp matched against file names.")
                          :path (pai-string-schema "Directory to search from (default: working directory).")
                          :limit (pai-number-schema "Maximum paths to return."))
                    nil)
       :execute #'pai-tool-find--execute))

;;;; elisp_eval (Emacs-native) -------------------------------------------

(defun pai-tool-elisp--execute (args _ctx _on-update on-done)
  "Evaluate Emacs Lisp from ARGS in the live image, finishing via ON-DONE."
  (let ((form-str (plist-get args :form)))
    (condition-case err
        (let ((value nil) (printed ""))
          (with-temp-buffer
            (let ((standard-output (current-buffer))
                  (pos 0) (len (length form-str)))
              (while (< pos len)
                (let ((res (condition-case nil (read-from-string form-str pos)
                             (error nil))))
                  (if (null res) (setq pos len)
                    (setq value (eval (car res) t))
                    (setq pos (cdr res))))))
            (setq printed (buffer-string)))
          (funcall on-done
                   (pai-tool-ok-result
                    (concat (unless (string-empty-p printed) (concat printed "\n"))
                            (format "=> %S" value))
                    (list :value (format "%S" value)))))
      (error (funcall on-done (pai-tool-error-result
                               (format "Error: %s" (error-message-string err))))))))

(pai-register-tool
 (list :name "elisp_eval"
       :label "Elisp"
       :description "Evaluate Emacs Lisp code in the running Emacs and return the value plus any printed output. This is the primary way to use Emacs as an operating system: inspect and modify buffers, call any Emacs function, drive packages, and query editor state."
       :prompt-snippet "elisp_eval: evaluate Emacs Lisp in the live editor"
       :execution-mode 'sequential
       :parameters (pai-object-schema
                    (list :form (pai-string-schema "Emacs Lisp source to evaluate (one or more top-level forms)."))
                    '("form"))
       :execute #'pai-tool-elisp--execute))

;;;; Buffer inspection (Emacs-native) ------------------------------------

(defun pai-tool-list-buffers--execute (_args _ctx _on-update on-done)
  "List live buffers, finishing via ON-DONE."
  (let ((lines (mapcar
                (lambda (b)
                  (with-current-buffer b
                    (format "%s\t%s\t%s\t%d chars"
                            (buffer-name b)
                            major-mode
                            (or (buffer-file-name b) "-")
                            (buffer-size b))))
                (seq-remove (lambda (b) (string-prefix-p " " (buffer-name b)))
                            (buffer-list)))))
    (funcall on-done (pai-tool-ok-result (string-join lines "\n")))))

(pai-register-tool
 (list :name "list_buffers"
       :label "Buffers"
       :description "List the live Emacs buffers with their name, major mode, backing file, and size."
       :prompt-snippet "list_buffers: list open Emacs buffers"
       :parameters (pai-object-schema nil)
       :execute #'pai-tool-list-buffers--execute))

(defun pai-tool-read-buffer--execute (args _ctx _on-update on-done)
  "Read a named Emacs buffer (optionally a line range) from ARGS via ON-DONE.
Lines are located with `forward-line' in the live buffer, so reading a few
lines of a huge buffer copies only those lines."
  (let* ((name (plist-get args :name))
         (offset (plist-get args :offset))
         (limit (plist-get args :limit))
         (buf (get-buffer name)))
    (if (not buf)
        (funcall on-done (pai-tool-error-result (format "No such buffer: %s" name)))
      (with-current-buffer buf
        (save-restriction
          (widen)
          (let* ((total (count-lines (point-min) (point-max)))
                 (first (max 1 (or offset 1)))
                 (beg (save-excursion (goto-char (point-min)) (forward-line (1- first)) (point)))
                 (end (if limit
                          (save-excursion (goto-char beg) (forward-line limit) (point))
                        (point-max)))
                 (text (string-trim-right (buffer-substring-no-properties beg end) "\n"))
                 (trunc (pai-tools-truncate text nil nil 'head))
                 (shown (min (count-lines beg end) pai-tool-max-lines))
                 (note (when (or (plist-get trunc :truncated) limit (> first 1))
                         (format "\n[showing lines %d-%d of %d; use offset/limit to page]"
                                 first (+ first (max 0 (1- shown))) total))))
            (funcall on-done (pai-tool-ok-result (concat (plist-get trunc :text) note)
                                                 (list :total-lines total)))))))))

(pai-register-tool
 (list :name "read_buffer"
       :label "Read buffer"
       :description "Read the text contents of a live Emacs buffer by name (buffers may not be backed by a file). Use offset/limit to read only some lines, e.g. a referenced range `*name:10-20` is offset 10, limit 11."
       :prompt-snippet "read_buffer: read an Emacs buffer's contents (or a line range)"
       :parameters (pai-object-schema
                    (list :name (pai-string-schema "The buffer name to read.")
                          :offset (pai-number-schema "1-based line to start reading from.")
                          :limit (pai-number-schema "Maximum number of lines to read."))
                    '("name"))
       :execute #'pai-tool-read-buffer--execute))

;;;; Convenience

(defconst pai-builtin-tool-names
  '("bash" "read" "write" "edit" "ls" "grep" "find"
    "elisp_eval" "list_buffers" "read_buffer")
  "Names of the built-in tools registered by this module.")

(defun pai-builtin-tools ()
  "Return the list of built-in tool plists."
  (pai-tools-select pai-builtin-tool-names))

(provide 'pai-tools-builtin)
;;; pai-tools-builtin.el ends here
