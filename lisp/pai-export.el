;;; pai-export.el --- Export sessions to Markdown/HTML + share -*- lexical-binding: t; -*-

;; Author: pai contributors
;; Keywords: ai, tools, convenience
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Export a pai conversation to Markdown or a self-contained HTML document,
;; copy the last reply to the system clipboard, and share a session as a
;; secret GitHub gist.  Port of pi's export-html + /copy + /share behavior.
;;
;; The public entry points are:
;;
;; - `pai-export-messages-markdown' / `pai-export-session-markdown'
;; - `pai-export-messages-html'     / `pai-export-session-html'
;; - `pai-clipboard-copy'
;;
;; plus the `/export', `/copy' and `/share' slash commands registered via
;; `pai-export-register-commands' (run on load).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-core)
(require 'pai-session)
(require 'pai-commands)

;;;; Markdown export

(defun pai-export--md-assistant (message)
  "Return the Markdown body for assistant MESSAGE."
  (let ((parts '()))
    (dolist (block (pai-normalize-content (pai-message-content message)))
      (pcase (pai-block-type block)
        ('thinking
         (let ((think (plist-get block :thinking)))
           (when (and think (not (string-empty-p think)))
             (push (concat "> reasoning\n>\n"
                           (mapconcat (lambda (l) (concat "> " l))
                                      (split-string think "\n") "\n"))
                   parts))))
        ('text
         (let ((tx (plist-get block :text)))
           (when (and tx (not (string-empty-p tx)))
             (push (string-trim-right tx) parts))))
        ('tool-call
         (push (concat "```\n" (or (plist-get block :name) "tool") " "
                       (pai-json-encode (plist-get block :arguments))
                       "\n```")
               parts))))
    (concat "## Assistant\n\n" (string-join (nreverse parts) "\n\n") "\n")))

(defun pai-export--md-message (message)
  "Return a Markdown string for MESSAGE, or nil when it should be skipped."
  (pcase (pai-message-role message)
    ('user
     (concat "## User\n\n"
             (string-trim-right (pai-content-text (pai-message-content message)))
             "\n"))
    ('assistant
     (pai-export--md-assistant message))
    ('tool-result
     (concat "### Tool result (" (or (plist-get message :tool-name) "tool") ")\n\n"
             "```\n"
             (string-trim-right (pai-content-text (pai-message-content message)))
             "\n```\n"))
    (_ nil)))

(defun pai-export-messages-markdown (messages &optional title)
  "Render MESSAGES to a Markdown string, optionally headed by TITLE."
  (let ((chunks '()))
    (when (and title (not (string-empty-p title)))
      (push (concat "# " title) chunks))
    (dolist (m messages)
      (let ((md (pai-export--md-message m)))
        (when md (push md chunks))))
    (concat (string-join (nreverse chunks) "\n") "\n")))

(defun pai-export-session-markdown (session)
  "Render SESSION to a Markdown string."
  (pai-export-messages-markdown (pai-session-messages session)
                                (pai-session-name session)))

;;;; HTML export

(defconst pai-export--html-style
  "body{font-family:system-ui,-apple-system,Segoe UI,sans-serif;max-width:52rem;\
margin:2rem auto;padding:0 1rem;line-height:1.5;color:#222;background:#fff;}
h1{font-size:1.4rem;}
section.msg{border:1px solid #e0e0e0;border-radius:6px;padding:.25rem 1rem 1rem;margin:1rem 0;}
section.user{background:#f5f7ff;}
section.assistant{background:#ffffff;}
section.tool{background:#f7f7f7;}
h2{font-size:.85rem;text-transform:uppercase;letter-spacing:.06em;color:#666;margin:.75rem 0 .5rem;}
h3{font-size:.8rem;color:#888;margin:.5rem 0;}
pre{white-space:pre-wrap;word-wrap:break-word;background:#f0f0f0;padding:.5rem .75rem;\
border-radius:4px;overflow-x:auto;font-size:.9rem;}
pre.tool-call{background:#eef;}
.reasoning{color:#777;font-style:italic;border-left:3px solid #ccc;padding-left:.75rem;\
margin:.5rem 0;white-space:pre-wrap;}"
  "Embedded CSS for exported HTML documents.")

(defun pai-export--html-escape (s)
  "Escape HTML special characters (&<>\") in string S."
  (let ((s (or s "")))
    (setq s (replace-regexp-in-string "&" "&amp;" s t t))
    (setq s (replace-regexp-in-string "<" "&lt;" s t t))
    (setq s (replace-regexp-in-string ">" "&gt;" s t t))
    (setq s (replace-regexp-in-string "\"" "&quot;" s t t))
    s))

(defun pai-export--html-pre (text &optional class)
  "Return a <pre> block for TEXT, escaped, with optional CLASS."
  (concat "<pre" (if class (concat " class=\"" class "\"") "") ">"
          (pai-export--html-escape text)
          "</pre>"))

(defun pai-export--html-assistant (message)
  "Return the HTML body for assistant MESSAGE."
  (let ((parts '()))
    (dolist (block (pai-normalize-content (pai-message-content message)))
      (pcase (pai-block-type block)
        ('thinking
         (let ((think (plist-get block :thinking)))
           (when (and think (not (string-empty-p think)))
             (push (concat "<div class=\"reasoning\">"
                           (pai-export--html-escape think) "</div>")
                   parts))))
        ('text
         (let ((tx (plist-get block :text)))
           (when (and tx (not (string-empty-p tx)))
             (push (pai-export--html-pre tx) parts))))
        ('tool-call
         (push (pai-export--html-pre
                (concat (or (plist-get block :name) "tool") " "
                        (pai-json-encode (plist-get block :arguments)))
                "tool-call")
               parts))))
    (concat "<section class=\"msg assistant\">\n<h2>Assistant</h2>\n"
            (string-join (nreverse parts) "\n") "\n</section>")))

(defun pai-export--html-message (message)
  "Return an HTML string for MESSAGE, or nil when it should be skipped."
  (pcase (pai-message-role message)
    ('user
     (concat "<section class=\"msg user\">\n<h2>User</h2>\n"
             (pai-export--html-pre (pai-content-text (pai-message-content message)))
             "\n</section>"))
    ('assistant
     (pai-export--html-assistant message))
    ('tool-result
     (concat "<section class=\"msg tool\">\n<h3>Tool result ("
             (pai-export--html-escape (or (plist-get message :tool-name) "tool"))
             ")</h3>\n"
             (pai-export--html-pre (pai-content-text (pai-message-content message)))
             "\n</section>"))
    (_ nil)))

(defun pai-export-messages-html (messages &optional title)
  "Render MESSAGES to a complete standalone HTML document string.
TITLE, when non-nil, becomes the document title and a leading heading."
  (let ((body '())
        (heading (and title (not (string-empty-p title)) title)))
    (dolist (m messages)
      (let ((h (pai-export--html-message m)))
        (when h (push h body))))
    (concat "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n"
            "<meta charset=\"utf-8\">\n"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
            "<title>" (pai-export--html-escape (or heading "pai session")) "</title>\n"
            "<style>\n" pai-export--html-style "\n</style>\n"
            "</head>\n<body>\n"
            (if heading (concat "<h1>" (pai-export--html-escape heading) "</h1>\n") "")
            (string-join (nreverse body) "\n")
            "\n</body>\n</html>\n")))

(defun pai-export-session-html (session)
  "Render SESSION to a complete standalone HTML document string."
  (pai-export-messages-html (pai-session-messages session)
                            (pai-session-name session)))

;;;; Clipboard

(defun pai-clipboard--program ()
  "Return (PROGRAM . ARGS) for an available clipboard tool, or nil."
  (cond
   ((executable-find "wl-copy") (list "wl-copy"))
   ((executable-find "xclip") (list "xclip" "-selection" "clipboard"))
   ((executable-find "pbcopy") (list "pbcopy"))
   ((executable-find "clip.exe") (list "clip.exe"))
   (t nil)))

(defun pai-clipboard--try-program (text)
  "Try to copy TEXT via an external clipboard program.  Return non-nil on success."
  (let ((cmd (pai-clipboard--program)))
    (when cmd
      (condition-case nil
          (zerop (with-temp-buffer
                   (insert text)
                   (apply #'call-process-region (point-min) (point-max)
                          (car cmd) nil nil nil (cdr cmd))))
        (error nil)))))

(defun pai-clipboard-copy (text)
  "Copy TEXT to the system clipboard.
Try an external tool (wl-copy, xclip, pbcopy, clip.exe) first, then fall
back to the Emacs kill ring and window-system selection.  Return non-nil
on success."
  (or (pai-clipboard--try-program text)
      (progn
        (kill-new text)
        (when (fboundp 'gui-select-text)
          (ignore-errors (gui-select-text text)))
        t)))

;;;; Slash commands

(defun pai-export--command-export (args ctx)
  "Handle `/export [PATH]'.  ARGS is the argument string, CTX the runtime context."
  (let ((session (plist-get ctx :session)))
    (if (not session)
        (list :message "No active session to export.")
      (let* ((cwd (or (plist-get ctx :cwd) default-directory))
             (arg (string-trim (or args "")))
             (markdown (string-suffix-p ".md" arg))
             (ext (if markdown "md" "html"))
             (path (if (string-empty-p arg)
                       (expand-file-name
                        (format "pi-session-%s.%s" (pai-session-id session) ext) cwd)
                     (expand-file-name arg cwd)))
             (content (if markdown
                          (pai-export-session-markdown session)
                        (pai-export-session-html session))))
        (when (file-name-directory path)
          (make-directory (file-name-directory path) t))
        (with-temp-file path (insert content))
        (list :message (format "Exported to %s" path))))))

(defun pai-export--command-copy (_args ctx)
  "Handle `/copy': copy the last assistant reply to the clipboard.  CTX is the context."
  (let ((session (plist-get ctx :session)))
    (if (not session)
        (list :message "No active session.")
      (let ((last (seq-find #'pai-assistant-message-p
                            (reverse (pai-session-messages session)))))
        (cond
         ((not last) (list :message "No assistant reply to copy."))
         ((pai-clipboard-copy (pai-content-text (pai-message-content last)))
          (list :message "Copied last reply to clipboard"))
         (t (list :message "Failed to copy to clipboard")))))))

(defun pai-export--command-share (_args ctx)
  "Handle `/share': export HTML and create a secret gist with `gh'.  CTX is the context."
  (let ((session (plist-get ctx :session)))
    (cond
     ((not session) (list :message "No active session to share."))
     ((not (executable-find "gh"))
      (list :message "/share needs the GitHub CLI (gh) installed"))
     (t
      (let ((tmp (make-temp-file "pai-share" nil ".html")))
        (unwind-protect
            (progn
              (with-temp-file tmp (insert (pai-export-session-html session)))
              (with-temp-buffer
                (let ((exit (call-process "gh" nil t nil "gist" "create" "--secret" tmp)))
                  (if (/= exit 0)
                      (list :message
                            (format "Failed to create gist: %s"
                                    (string-trim (buffer-string))))
                    (let ((url (string-trim
                                (car (last (split-string (buffer-string) "\n" t))))))
                      (pai-clipboard-copy url)
                      (list :message (format "Shared: %s" url)))))))
          (ignore-errors (delete-file tmp))))))))

(defun pai-export-register-commands ()
  "Register the `/export', `/copy' and `/share' slash commands."
  (pai-register-command "export"
                        :description "Export the session to Markdown (.md) or HTML"
                        :handler #'pai-export--command-export)
  (pai-register-command "copy"
                        :description "Copy the last assistant reply to the clipboard"
                        :handler #'pai-export--command-copy)
  (pai-register-command "share"
                        :description "Share the session as a secret GitHub gist"
                        :handler #'pai-export--command-share))

(pai-export-register-commands)

(provide 'pai-export)
;;; pai-export.el ends here
