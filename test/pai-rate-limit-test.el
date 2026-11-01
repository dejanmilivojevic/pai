;;; pai-rate-limit-test.el --- Tests for waiting out rate limits -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai-core)
(require 'pai-agent)
(require 'pai-rate-limit)
(require 'pai-compaction)
(require 'pai-http)
(require 'pai-faux)

(defun pai-rate-limit-test--err (text &rest props)
  "Return a failed assistant message with error TEXT and extra PROPS."
  (append (pai-assistant-message :stop-reason 'error :error-message text) props))

;;;; Classification

(ert-deftest pai-rate-limit-error-p-classifies ()
  (dolist (text '("HTTP 429: {\"error\":{\"type\":\"rate_limit_error\"}}"
                  "HTTP 529: {\"type\":\"overloaded_error\"}"
                  "overloaded"
                  "Number of request tokens has exceeded your per-minute rate limit"
                  "HTTP 429: {\"error\":{\"status\":\"RESOURCE_EXHAUSTED\"}}"
                  "You have reached your usage limit. Try again in 3 hours."))
    (should (pai-rate-limit-error-p (pai-rate-limit-test--err text))))
  (dolist (text '("kaboom"
                  "HTTP 500: internal"
                  "HTTP 401: invalid x-api-key"
                  "HTTP 429: {\"error\":{\"code\":\"insufficient_quota\"}}"
                  "Your credit balance is too low"
                  "prompt is too long: 210000 tokens > 200000 maximum"))
    (should-not (pai-rate-limit-error-p (pai-rate-limit-test--err text))))
  ;; a successful message is never a rate limit
  (should-not (pai-rate-limit-error-p (pai-assistant-message :stop-reason 'stop)))
  ;; reset headers mark it even when the text is vague
  (should (pai-rate-limit-error-p (pai-rate-limit-test--err "HTTP 418: ?" :retry-at 5.0))))

;;;; Parsing

(ert-deftest pai-rate-limit-parse-duration-forms ()
  (should (= (pai-rate-limit-parse-duration "6m0s") 360))
  (should (= (pai-rate-limit-parse-duration "1.5s") 1.5))
  (should (= (pai-rate-limit-parse-duration "120ms") 0.12))
  (should (= (pai-rate-limit-parse-duration "1h2m3s") 3723))
  (should (= (pai-rate-limit-parse-duration "3 hours 2 minutes") 10920))
  (should (= (pai-rate-limit-parse-duration "2 hours, and 5 minutes") 7500))
  (should-not (pai-rate-limit-parse-duration "soon")))

(ert-deftest pai-rate-limit-reset-time-from-headers ()
  (let ((now 1000000000.0))
    (should (= (pai-rate-limit-reset-time '(("retry-after" . "30")) now) (+ now 30)))
    (should (= (pai-rate-limit-reset-time '(("retry-after-ms" . "1500")
                                            ("retry-after" . "2"))
                                          now)
               (+ now 1.5)))
    ;; Claude subscription window, rejected: its reset wins over retry-after
    (should (= (pai-rate-limit-reset-time
                '(("retry-after" . "10")
                  ("anthropic-ratelimit-unified-status" . "rejected")
                  ("anthropic-ratelimit-unified-reset" . "1000007200"))
                now)
               1000007200))
    ;; an allowed window is not a reason to wait
    (should-not (pai-rate-limit-reset-time
                 '(("anthropic-ratelimit-unified-status" . "allowed")
                   ("anthropic-ratelimit-unified-reset" . "1000007200"))
                 now))
    ;; OpenAI: the exhausted bucket counts, the other does not
    (should (= (pai-rate-limit-reset-time
                '(("x-ratelimit-remaining-requests" . "0")
                  ("x-ratelimit-reset-requests" . "6m0s")
                  ("x-ratelimit-remaining-tokens" . "1000")
                  ("x-ratelimit-reset-tokens" . "2h"))
                now)
               (+ now 360)))
    ;; Anthropic API buckets carry RFC 3339 times
    (should (= (pai-rate-limit-reset-time
                '(("anthropic-ratelimit-tokens-remaining" . "0")
                  ("anthropic-ratelimit-tokens-reset" . "2001-09-09T01:47:00Z"))
                now)
               (float-time (parse-iso8601-time-string "2001-09-09T01:47:00Z"))))
    ;; OpenRouter: epoch milliseconds
    (should (= (pai-rate-limit-reset-time '(("x-ratelimit-remaining" . "0")
                                            ("x-ratelimit-reset" . "1000000060000"))
                                          now)
               (+ now 60)))
    ;; an HTTP date
    (should (= (pai-rate-limit-reset-time '(("retry-after" . "Sun, 09 Sep 2001 01:47:00 GMT")) now)
               (float-time (parse-iso8601-time-string "2001-09-09T01:47:00Z"))))
    (should-not (pai-rate-limit-reset-time nil now))
    (should-not (pai-rate-limit-reset-time '(("content-type" . "application/json")) now))))

(ert-deftest pai-rate-limit-reset-time-from-text ()
  (let ((now 1000000000.0))
    (should (= (pai-rate-limit-text-reset-time
                "HTTP 429: {\"details\":[{\"@type\":\"RetryInfo\",\"retryDelay\": \"34s\"}]}" now)
               (+ now 34)))
    (should (= (pai-rate-limit-text-reset-time
                "Rate limit reached for gpt-x. Please try again in 6m0s. Visit ..." now)
               (+ now 360)))
    (should (= (pai-rate-limit-text-reset-time "Usage limit reached. Try again in 2 hours 5 minutes." now)
               (+ now 7500)))
    (should (= (pai-rate-limit-text-reset-time "limit resets at 2001-09-09T01:47:00Z" now)
               (float-time (parse-iso8601-time-string "2001-09-09T01:47:00Z"))))
    (should-not (pai-rate-limit-text-reset-time "rate limited" now))))

;;;; Waiting

(ert-deftest pai-rate-limit-wait-seconds-known-and-backoff ()
  (let ((now 1000000000.0)
        (pai-rate-limit-margin 2)
        (pai-rate-limit-backoff-initial 15)
        (pai-rate-limit-backoff-max 600))
    (should (equal (pai-rate-limit-wait-seconds
                    (pai-rate-limit-test--err "HTTP 429" :retry-at (+ now 3600)) 0 now)
                   (cons 3602.0 t)))
    (should (equal (pai-rate-limit-wait-seconds
                    (pai-rate-limit-test--err "try again in 20s") 5 now)
                   (cons 22.0 t)))
    (should (equal (pai-rate-limit-wait-seconds (pai-rate-limit-test--err "HTTP 429") 0 now)
                   (cons 15 nil)))
    (should (equal (pai-rate-limit-wait-seconds (pai-rate-limit-test--err "HTTP 429") 2 now)
                   (cons 60 nil)))
    (should (equal (pai-rate-limit-wait-seconds (pai-rate-limit-test--err "HTTP 429") 10 now)
                   (cons 600 nil)))
    ;; a reset time already past falls back to backoff
    (should (equal (pai-rate-limit-wait-seconds
                    (pai-rate-limit-test--err "HTTP 429" :retry-at (- now 5)) 0 now)
                   (cons 15 nil)))))

(ert-deftest pai-rate-limit-recover-respects-settings ()
  (let ((msg (pai-rate-limit-test--err "HTTP 429: rate limited" :retry-at (+ (float-time) 3600)))
        (state (pai-rate-limit-state-create)))
    (unwind-protect
        (progn
          (let ((pai-rate-limit-retry nil))
            (should-not (pai-rate-limit-recover state msg #'ignore)))
          ;; a budget smaller than the wait gives up
          (let ((pai-rate-limit-retry 60))
            (should-not (pai-rate-limit-recover state msg #'ignore)))
          ;; not a rate limit
          (should-not (pai-rate-limit-recover state (pai-rate-limit-test--err "kaboom") #'ignore))
          (let (info)
            (should (pai-rate-limit-recover state msg #'ignore
                                            :on-wait (lambda (i) (setq info i))))
            (should (pai-rate-limit-waiting-p state))
            (should (plist-get info :known))
            (should (= (plist-get info :attempt) 1))
            (should (> (plist-get info :seconds) 3590)))
          (pai-rate-limit-cancel state)
          (should-not (pai-rate-limit-waiting-p state))
          (pai-rate-limit-reset state)
          (should (= (pai-rate-limit-state-attempts state) 0)))
      (pai-rate-limit-cancel state))))

(defvar pai-rate-limit-test--streams nil)

(ert-deftest pai-rate-limit-agent-run-waits-then-retries ()
  "A headless run hit by rate limits waits and streams the same turn again."
  (pai-faux-reset)
  (pai-faux-push '(:error "HTTP 429: rate_limit_error")
                 '(:error "overloaded")
                 '(:text "made it" :stop-reason stop))
  (let* ((pai-rate-limit-backoff-initial 0.05)
         (state (pai-rate-limit-state-create))
         (waits nil) (retries 0) (done nil)
         (run (pai-agent-run
               (list (pai-user-message "go"))
               (pai-context nil nil)
               (list :model (pai-model "faux")
                     :recover-error (pai-rate-limit-recover-function
                                     state
                                     (lambda (info) (push info waits))
                                     (lambda () (cl-incf retries))))
               #'ignore
               (lambda (msgs) (setq done msgs)))))
    (let ((deadline (+ (float-time) 5)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output nil 0.02)))
    (should done)
    (should (= (length waits) 2))
    (should (= retries 2))
    ;; backoff doubles between attempts
    (should (equal (mapcar (lambda (i) (plist-get i :attempt)) (reverse waits)) '(1 2)))
    (should (pai-run-finished run))
    ;; the retried request carried no failed reply
    (should-not (seq-find (lambda (m) (eq (plist-get m :stop-reason) 'error))
                          (plist-get pai-faux-last-context :messages)))
    (should (equal (pai-content-text (pai-message-content
                                      (car (last (plist-get (pai-run-context run) :messages)))))
                   "made it"))))

(ert-deftest pai-rate-limit-agent-abort-drops-the-wait ()
  (pai-faux-reset)
  (pai-faux-push '(:error "HTTP 429: rate_limit_error")
                 '(:text "NOT REACHED" :stop-reason stop))
  (let* ((pai-rate-limit-backoff-initial 0.05)
         (state (pai-rate-limit-state-create))
         (events nil)
         (run (pai-agent-run
               (list (pai-user-message "go"))
               (pai-context nil nil)
               (list :model (pai-model "faux")
                     :recover-error (pai-rate-limit-recover-function state))
               (lambda (e) (push e events)))))
    (should (pai-rate-limit-waiting-p state))
    (pai-agent-abort run)
    (let ((deadline (+ (float-time) 0.3)))
      (while (< (float-time) deadline) (accept-process-output nil 0.02)))
    (should (plist-get (car events) :aborted))
    ;; the queued success was never requested
    (should (equal pai-faux-responses '((:text "NOT REACHED" :stop-reason stop))))
    (pai-rate-limit-cancel state)))

;;;; Transport: response headers reach the provider

(ert-deftest pai-rate-limit-http-error-carries-headers ()
  (require 'pai-http-test nil t)
  (skip-unless (and (fboundp 'pai-http-test--start-server) (executable-find "curl")))
  (let* ((srv (pai-http-test--start-server
               (concat "HTTP/1.1 429 Too Many Requests\r\n"
                       "Retry-After: 42\r\n"
                       "Content-Type: application/json\r\n"
                       "\r\n"
                       "{\"error\":\"slow down\"}")))
         (proc (car srv)) (closed nil) (err nil) (info nil) (plain nil))
    (unwind-protect
        (progn
          (pai-http-stream
           :url (format "http://127.0.0.1:%d/" (cdr srv))
           :body "{}"
           :on-frame #'ignore
           :on-error (lambda (m &optional i) (setq err m info i))
           :on-close (lambda (_c) (setq closed t)))
          (let ((deadline (+ (float-time) 10)))
            (while (and (not closed) (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (should (string-prefix-p "HTTP 429" err))
          (should (eql (plist-get info :status) 429))
          (should (equal (cdr (assoc "retry-after" (plist-get info :headers))) "42"))
          ;; one-argument handlers keep working
          (setq closed nil)
          (let ((srv2 (pai-http-test--start-server
                       "HTTP/1.1 429 Too Many Requests\r\n\r\nslow")))
            (unwind-protect
                (progn
                  (pai-http-stream
                   :url (format "http://127.0.0.1:%d/" (cdr srv2))
                   :body "{}" :on-frame #'ignore
                   :on-error (lambda (m) (setq plain m))
                   :on-close (lambda (_c) (setq closed t)))
                  (let ((deadline (+ (float-time) 10)))
                    (while (and (not closed) (< (float-time) deadline))
                      (accept-process-output nil 0.05)))
                  (should (string-prefix-p "HTTP 429" plain)))
              (delete-process (car srv2)))))
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest pai-rate-limit-provider-stamps-retry-at ()
  "The provider path turns reset headers into the failed message's :retry-at."
  (let* ((captured nil) (final nil)
         (provider (list :build-request (lambda (&rest _) (list :url "http://x" :body "{}"))
                         :make-parser (lambda (model emit)
                                        (let ((acc (pai-accum-new model)))
                                          (list :on-frame #'ignore :on-close #'ignore
                                                :on-error (lambda (msg)
                                                            (pai-accum-error acc emit 'error msg)))))))
         (before (float-time)))
    (cl-letf (((symbol-function 'pai-http-stream)
               (lambda (&rest args) (setq captured args) nil)))
      (pai-provider--http-stream provider (pai-model "faux") nil nil
                                 (lambda (ev) (when (eq (plist-get ev :type) 'error)
                                                (setq final (plist-get ev :message)))))
      (funcall (plist-get captured :on-error) "HTTP 429: slow down"
               '(:status 429 :headers (("retry-after" . "120")))))
    (should final)
    (should (equal (plist-get final :error-message) "HTTP 429: slow down"))
    (should (>= (plist-get final :retry-at) (+ before 120)))
    (should (pai-rate-limit-error-p final))))

(provide 'pai-rate-limit-test)
;;; pai-rate-limit-test.el ends here
