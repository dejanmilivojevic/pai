;;; pai-integration-test.el --- End-to-end tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercises the whole stack together (UI + agent loop + tools + session +
;; extensions) with the faux provider: a multi-turn conversation that uses a
;; real tool against a real file, persists to disk, and continues context.

;;; Code:

(require 'ert)
(require 'pai)
(require 'pai-faux)

(defmacro pai-int--with-project (dir buf &rest body)
  (declare (indent 2))
  `(let* ((,dir (file-name-as-directory (make-temp-file "pai-int" t)))
          (pai-directory (expand-file-name ".pai-state" ,dir))
          (pai-default-model "faux")
          (,buf nil))
     (unwind-protect
         (progn
           (pai-ext-reset)
           (setq ,buf (get-buffer-create (generate-new-buffer-name "*pai-int*")))
           (with-current-buffer ,buf (setq default-directory ,dir) (pai--setup ,dir))
           ,@body)
       (when (buffer-live-p ,buf) (kill-buffer ,buf))
       (ignore-errors (delete-directory ,dir t)))))

(defun pai-int--send (text)
  (goto-char (point-max)) (insert text) (pai-send))

(ert-deftest pai-integration-multi-turn-with-tool ()
  "A tool-using turn followed by a plain turn, persisted and context-carried."
  (pai-int--with-project dir buf
    ;; a real file the agent will read
    (with-temp-file (expand-file-name "notes.txt" dir) (insert "the secret is 42\n"))
    (with-current-buffer buf
      ;; Turn 1: assistant reads the file, then answers.
      (pai-faux-reset)
      (pai-faux-push '(:tool-calls ((:id "c1" :name "read" :arguments (:path "notes.txt")))
                      :stop-reason tool-use)
                     '(:text "The secret is 42." :stop-reason stop))
      (pai-int--send "what is the secret in notes.txt?")
      (let ((content (buffer-string)))
        (should (string-match-p "⚙ read" content))
        (should (string-match-p "the secret is 42" content)) ; tool result rendered
        (should (string-match-p "The secret is 42\\." content)))

      ;; Turn 2: a plain follow-up; prior context must be present.
      (pai-faux-reset)
      (pai-faux-push '(:text "You asked about notes.txt earlier." :stop-reason stop))
      (pai-int--send "thanks")
      (should (string-match-p "You asked about notes.txt earlier." (buffer-string)))

      ;; The faux provider saw a transcript containing the earlier messages.
      (let ((seen (plist-get pai-faux-last-context :messages)))
        (should (seq-find (lambda (m) (and (pai-user-message-p m)
                                           (string-match-p "secret" (format "%s" (pai-message-content m)))))
                          seen))
        ;; system prompt is the leading message and mentions tools
        (should (pai-system-message-p (car seen)))
        (should (string-match-p "elisp_eval" (pai-content-text (pai-message-content (car seen)))))))

    ;; Session persisted to disk and reloads with the full conversation.
    (with-current-buffer buf
      (let* ((file (pai-session-file pai--session))
             (loaded (pai-session-load file))
             (roles (mapcar #'pai-message-role (pai-session-messages loaded))))
        (should (file-exists-p file))
        ;; system, user, assistant(tool call), tool-result, assistant, user, assistant
        (should (memq 'tool-result roles))
        (should (>= (seq-count (lambda (r) (eq r 'user)) roles) 2))
        (should (>= (seq-count (lambda (r) (eq r 'assistant)) roles) 3))))))

(ert-deftest pai-integration-extension-observes-events ()
  "An extension registered before a run observes lifecycle events end to end."
  (pai-int--with-project dir buf
    (let ((observed '()))
      (with-current-buffer buf
      (pai-register-extension
       (lambda (pi)
         (pai-ext-on pi 'agent-start (lambda (_e _c) (push 'start observed)))
         (pai-ext-on pi 'tool-execution-end (lambda (_e _c) (push 'tool observed)))
         (pai-ext-on pi 'agent-end (lambda (_e _c) (push 'end observed))))))
      (with-current-buffer buf
        (pai-faux-reset)
        (pai-faux-push '(:tool-calls ((:id "c1" :name "elisp_eval" :arguments (:form "(+ 40 2)")))
                        :stop-reason tool-use)
                       '(:text "42" :stop-reason stop))
        (pai-int--send "add 40 and 2"))
      (should (memq 'start observed))
      (should (memq 'tool observed))
      (should (memq 'end observed)))))

(ert-deftest pai-integration-context-hook-injects ()
  "A `context' extension hook can inject a message into every request."
  (pai-int--with-project dir buf
    (with-current-buffer buf
    (pai-register-extension
     (lambda (pi)
       (pai-ext-on pi 'context
                   (lambda (event _ctx)
                     (list :messages (append (plist-get event :messages)
                                             (list (pai-system-message "INJECTED-CONTEXT")))))))))
    (with-current-buffer buf
      (pai-faux-reset)
      (pai-faux-push '(:text "ok" :stop-reason stop))
      (pai-int--send "hello")
      (let ((seen (plist-get pai-faux-last-context :messages)))
        (should (seq-find (lambda (m) (and (pai-system-message-p m)
                                           (equal (pai-message-content m) "INJECTED-CONTEXT")))
                          seen))))))

(provide 'pai-integration-test)
;;; pai-integration-test.el ends here
