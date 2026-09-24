;;; pai-export-test.el --- Tests for session export -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pai-core)
(require 'pai-session)
(require 'pai-commands)
(require 'pai-export)

(defun pai-export-test--session ()
  "Build a small in-memory session for export tests."
  (let ((s (pai-session-new "/tmp/pai-export-proj" 'memory)))
    (pai-session-append-message s (pai-user-message "list the files"))
    (pai-session-append-message
     s (pai-assistant-message
        :content (list (pai-thinking "let me look")
                       (pai-text "Sure, running ls now.")
                       (pai-tool-call "c1" "bash" '(:command "ls")))
        :provider "anthropic" :model "claude" :stop-reason 'tool-use))
    (pai-session-append-message
     s (pai-tool-result-message :tool-call-id "c1" :tool-name "bash"
                                :content "file-a.txt" :is-error nil))
    (pai-session-append-message
     s (pai-assistant-message
        :content (list (pai-text "There is one file: file-a.txt"))
        :provider "anthropic" :model "claude" :stop-reason 'stop))
    s))

(ert-deftest pai-export-markdown-content ()
  (let* ((s (pai-export-test--session))
         (md (pai-export-session-markdown s)))
    (should (string-match-p "## User" md))
    (should (string-match-p "## Assistant" md))
    (should (string-match-p "bash" md))
    (should (string-match-p "Sure, running ls now\\." md))
    (should (string-match-p "### Tool result (bash)" md))
    (should (string-match-p "> reasoning" md))))

(ert-deftest pai-export-html-full-document ()
  (let* ((s (pai-export-test--session))
         (html (pai-export-session-html s)))
    (should (string-match-p "<!DOCTYPE html>" html))
    (should (string-match-p "<style>" html))
    (should (string-match-p "</html>" html))
    (should (string-match-p "Assistant" html))))

(ert-deftest pai-export-html-escapes-script ()
  (let* ((msgs (list (pai-user-message "danger <script>alert(1)</script> end")))
         (html (pai-export-messages-html msgs "T")))
    (should (string-match-p "&lt;script&gt;" html))
    (should-not (string-match-p "<script>" html))))

(ert-deftest pai-export-command-writes-file ()
  (let* ((s (pai-export-test--session))
         (dir (make-temp-file "pai-export-dir" t))
         (cmd (pai-command-get "export")))
    (unwind-protect
        (progn
          (should cmd)
          ;; default -> HTML file named pi-session-<id>.html
          (let* ((ctx (list :session s :cwd dir))
                 (res (funcall (plist-get cmd :handler) "" ctx))
                 (path (expand-file-name
                        (format "pi-session-%s.html" (pai-session-id s)) dir)))
            (should (string-match-p "Exported to" (plist-get res :message)))
            (should (file-exists-p path))
            (with-temp-buffer
              (insert-file-contents path)
              (should (string-match-p "<!DOCTYPE html>" (buffer-string)))))
          ;; explicit .md path
          (let* ((mdpath (expand-file-name "out.md" dir))
                 (ctx (list :session s :cwd dir))
                 (res (funcall (plist-get cmd :handler) "out.md" ctx)))
            (should (string-match-p "Exported to" (plist-get res :message)))
            (should (file-exists-p mdpath))
            (with-temp-buffer
              (insert-file-contents mdpath)
              (should (string-match-p "## User" (buffer-string))))))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest pai-export-command-export-no-session ()
  (let* ((cmd (pai-command-get "export"))
         (res (funcall (plist-get cmd :handler) "" (list :cwd "/tmp"))))
    (should (plist-get res :message))
    (should-not (string-match-p "Exported to" (plist-get res :message)))))

(ert-deftest pai-export-command-copy ()
  (let* ((s (pai-export-test--session))
         (cmd (pai-command-get "copy"))
         (copied nil))
    (cl-letf (((symbol-function 'pai-clipboard-copy)
               (lambda (text) (setq copied text) t)))
      (let ((res (funcall (plist-get cmd :handler) "" (list :session s))))
        (should (equal (plist-get res :message) "Copied last reply to clipboard"))
        (should (equal copied "There is one file: file-a.txt"))))))

(ert-deftest pai-export-command-share-no-gh ()
  (let* ((s (pai-export-test--session))
         (cmd (pai-command-get "share")))
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
      (let ((res (funcall (plist-get cmd :handler) "" (list :session s))))
        (should (equal (plist-get res :message)
                       "/share needs the GitHub CLI (gh) installed"))))))

(ert-deftest pai-export-commands-registered ()
  (should (pai-command-get "export"))
  (should (pai-command-get "copy"))
  (should (pai-command-get "share")))

(ert-deftest pai-clipboard-copy-fallback ()
  ;; With no external program available, falls back to kill-new and succeeds.
  (cl-letf (((symbol-function 'pai-clipboard--program) (lambda () nil)))
    (should (pai-clipboard-copy "hello clipboard"))
    (should (equal (current-kill 0) "hello clipboard"))))

(provide 'pai-export-test)
;;; pai-export-test.el ends here
