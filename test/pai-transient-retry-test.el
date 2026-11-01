;;; pai-transient-retry-test.el --- Retrying turns after transient errors -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pai)
(require 'pai-ui)
(require 'pai-http)

(defun pai-transient-retry-test--failed (text)
  "Return a failed assistant message with error TEXT."
  (list :role 'assistant :content nil :stop-reason 'error :provider "kimi"
        :model "k3" :error-message text))

(ert-deftest pai-transient-error-classification ()
  "Overload and 5xx errors are transient; quota, credits and auth are not."
  (dolist (err '("HTTP 429: {\"error\":{\"message\":\"The engine is currently overloaded, please try again later\",\"type\":\"engine_overloaded_error\"}}"
                 "HTTP 503: Service Unavailable"
                 "HTTP 529: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}"
                 "HTTP 502: Bad Gateway"))
    (should (pai-transient-error-p (pai-transient-retry-test--failed err))))
  (dolist (err '("HTTP 403: {\"error\":{\"message\":\"Your current subscription does not have access to Kimi Code right now.\"}}"
                 "HTTP 402: Prompt tokens limit exceeded: add more credits"
                 "HTTP 429: You exceeded your current quota"
                 "HTTP 401: invalid api key"
                 "HTTP 400: bad request"))
    (should-not (pai-transient-error-p (pai-transient-retry-test--failed err))))
  (should-not (pai-transient-error-p '(:role assistant :stop-reason stop))))

(ert-deftest pai-transient-retry-backoff-then-gives-up ()
  "Each transient failure waits the next delay and resumes without the
failed reply; after the last delay the error is left to end the run."
  (with-temp-buffer
    (let ((pai-transient-retry-delays '(2 4))
          (pai--transient-retries 0)
          (pai--transient-retry-timer nil)
          (pai--context-messages nil)
          (pai--model '(:id "k3" :context-window 100000))
          timers resumed notes)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (secs _repeat fn) (push (cons secs fn) timers) 'timer))
                ((symbol-function 'timerp) (lambda (x) (eq x 'timer)))
                ((symbol-function 'cancel-timer) #'ignore)
                ((symbol-function 'pai--render-note) (lambda (text &rest _) (push text notes)))
                ((symbol-function 'pai--set-status) #'ignore))
        (dotimes (i 2)
          (let ((failed (pai-transient-retry-test--failed "HTTP 502: bad gateway")))
            (setq pai--context-messages (list (pai-user-message "hi") failed))
            (should (pai--recover-error failed (lambda (u) (push u resumed))))
            (should (= pai--transient-retries (1+ i)))
            (should-not (memq failed pai--context-messages))
            (let ((secs (caar timers)))
              (should (<= (nth i '(2 4)) secs (* 1.2 (nth i '(2 4))))))
            (funcall (cdar timers))
            (should (equal (plist-get (car resumed) :messages) pai--context-messages))))
        (should (string-match-p "kimi is busy; retrying in [0-9]+s (2/2)" (car notes)))
        ;; delays used up: not taken, so the run ends with the error
        (let ((failed (pai-transient-retry-test--failed "HTTP 502: bad gateway")))
          (setq pai--context-messages (list failed))
          (should-not (pai--recover-error failed #'ignore))
          (should (memq failed pai--context-messages)))))))

(ert-deftest pai-transient-retry-skips-non-transient ()
  "A permanent error is not retried."
  (with-temp-buffer
    (let ((pai--transient-retries 0)
          (pai--model '(:id "k3" :context-window 100000))
          (failed (pai-transient-retry-test--failed "HTTP 403: subscription required")))
      (setq-local pai--context-messages (list failed))
      (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) (error "scheduled"))))
        (should-not (pai--recover-error failed #'ignore))
        (should (= pai--transient-retries 0))))))

(ert-deftest pai-http-request-sends-body ()
  "A :body is posted from a private temp file that is removed afterwards."
  (let (args written-mode)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest plist)
                 (setq args (plist-get plist :command))
                 (let ((file (substring (car (last (butlast args))) 1)))
                   (setq written-mode (file-modes file))
                   (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                                  "a=1&b=x%20y"))
                   (funcall (plist-get plist :sentinel) 'proc "finished\n"))
                 'proc))
              ((symbol-function 'process-live-p) (lambda (_) nil))
              ((symbol-function 'process-exit-status) (lambda (_) 0))
              ((symbol-function 'process-send-string) #'ignore)
              ((symbol-function 'process-send-eof) #'ignore))
      (pai-http-request :url "https://x/y" :method "POST" :body "a=1&b=x%20y"
                        :headers '(("A" . "b")) :on-done #'ignore))
    (should (member "--data-binary" args))
    (should (= written-mode #o600))
    (should-not (file-exists-p (substring (car (last (butlast args))) 1)))))

(provide 'pai-transient-retry-test)
;;; pai-transient-retry-test.el ends here
