;;; pai-rate-limit.el --- Wait out provider rate limits, then retry -*- lexical-binding: t; -*-

;;; Commentary:

;; When a provider rejects a turn because a rate or usage limit is exhausted
;; (HTTP 429, "rate_limit_error", Gemini's RESOURCE_EXHAUSTED, an overloaded
;; server, ...), the run does not end: it waits until the limit resets and
;; streams the same turn again, as often as it takes.  You can leave a
;; session -- or a whole tree of subagents -- running overnight and it picks
;; up again once the provider's window opens.
;;
;; The reset time comes from, in order of preference:
;;
;;   * response headers, recorded by `pai-provider--http-stream' as the
;;     assistant message's `:retry-at' (epoch seconds): `retry-after',
;;     `retry-after-ms', and every `*-reset' header whose window is exhausted
;;     (its `-remaining' is 0 or its `-status' is "rejected"), e.g. Anthropic's
;;     `anthropic-ratelimit-unified-reset' for Claude Pro/Max windows;
;;   * the error text: "retryDelay": "34s", "try again in 6m0s",
;;     "resets at 2026-11-01T17:00:00Z", ...;
;;   * otherwise exponential backoff, from `pai-rate-limit-backoff-initial'
;;     up to `pai-rate-limit-backoff-max' seconds between attempts.
;;
;; `pai-rate-limit-recover' implements an agent-loop `:recover-error' hook
;; (see `pai-agent--recover-error'); the chat UI and headless subagents use it.
;; A wait is dropped when the run is aborted (C-c C-c).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'parse-time)
(require 'pai-core)

(defgroup pai-rate-limit nil
  "Waiting out provider rate limits."
  :group 'pai)

(defcustom pai-rate-limit-retry t
  "Whether a turn rejected by a provider rate limit waits and retries.
t waits as long as it takes (until the limit resets, however long that
is); a number caps the total seconds a run waits before giving up; nil
ends the run with the error, as before."
  :type '(choice (const :tag "Wait as long as it takes" t)
                 (integer :tag "Give up after this many seconds of waiting")
                 (const :tag "Never retry" nil)))

(defcustom pai-rate-limit-backoff-initial 15
  "Seconds to wait before the first retry when the provider names no reset time."
  :type 'integer)

(defcustom pai-rate-limit-backoff-max 600
  "Longest wait, in seconds, between retries when no reset time is known.
With a known reset time the run waits until then, however far away."
  :type 'integer)

(defcustom pai-rate-limit-margin 2
  "Extra seconds to wait past a provider's announced reset time."
  :type 'integer)

(defconst pai-rate-limit-patterns
  '("\\`HTTP 429\\b" "\\`HTTP 529\\b" "\\`HTTP 503\\b"
    "rate[ _-]?limit" "too many requests" "resource[ _]exhausted"
    "usage[ _]limit" "overloaded" "quota" "throttl" "try again in")
  "Provider error messages that mean \"wait, then try again\".")

(defconst pai-rate-limit-fatal-patterns
  '("insufficient_quota" "credit balance" "billing" "request too large"
    "payment required" "\\`HTTP 40[0-3]\\b")
  "Error messages that match `pai-rate-limit-patterns' but will not go away
by waiting (an empty balance, a request larger than the limit itself).")

;;;; Classification

(defun pai-rate-limit-error-p (message)
  "Return non-nil when assistant MESSAGE failed on a rate or usage limit."
  (let ((err (plist-get message :error-message))
        (case-fold-search t))
    (and (eq (plist-get message :stop-reason) 'error)
         (stringp err)
         (or (plist-get message :retry-at)
             (seq-some (lambda (p) (string-match-p p err)) pai-rate-limit-patterns))
         (not (seq-some (lambda (p) (string-match-p p err)) pai-rate-limit-fatal-patterns))
         (not (and (fboundp 'pai-context-overflow-p) (pai-context-overflow-p message)))
         t)))

;;;; Parsing reset times

(defconst pai-rate-limit--units
  '(("ms" . 0.001) ("msec" . 0.001) ("millisecond" . 0.001) ("milliseconds" . 0.001)
    ("s" . 1) ("sec" . 1) ("secs" . 1) ("second" . 1) ("seconds" . 1)
    ("m" . 60) ("min" . 60) ("mins" . 60) ("minute" . 60) ("minutes" . 60)
    ("h" . 3600) ("hr" . 3600) ("hrs" . 3600) ("hour" . 3600) ("hours" . 3600)
    ("d" . 86400) ("day" . 86400) ("days" . 86400))
  "Duration unit names and their length in seconds.")

(defun pai-rate-limit-parse-duration (string &optional start)
  "Parse a duration such as \"6m0s\", \"1.5s\", \"120ms\" or \"2 hours 5 minutes\".
Parse from START (default 0) in STRING.  Return seconds, or nil when no
duration starts there."
  (let ((pos (or start 0)) (total nil) (case-fold-search t))
    (while (and (< pos (length string))
                (eq (string-match
                     "\\(?:[ \t]*,\\)?[ \t]*\\(?:and[ \t]+\\)?\\([0-9]+\\(?:\\.[0-9]+\\)?\\)[ \t]*\\([a-z]+\\)"
                     string pos)
                    pos)
                (assoc-string (match-string 2 string) pai-rate-limit--units t))
      (setq total (+ (or total 0)
                     (* (string-to-number (match-string 1 string))
                        (cdr (assoc-string (match-string 2 string) pai-rate-limit--units t))))
            pos (match-end 0)))
    total))

(defun pai-rate-limit--parse-date (string)
  "Return STRING (ISO 8601 or an HTTP date) as epoch seconds, or nil."
  (let ((s (string-trim string))
        (case-fold-search t))
    (ignore-errors
      (cond
       ((string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}[T ][0-9]" s)
        (float-time (parse-iso8601-time-string
                     (replace-regexp-in-string " " "T" s nil nil nil 0))))
       ;; Wed, 21 Oct 2026 07:28:00 GMT
       ((string-match-p "[0-9]\\{1,2\\} +[a-z]\\{3\\} +[0-9]\\{4\\} +[0-9:]+" s)
        (float-time (date-to-time s)))))))

(defun pai-rate-limit--parse-time-value (value now)
  "Return header VALUE as an absolute epoch time, relative to NOW.
VALUE is seconds from now, epoch seconds or milliseconds, a duration like
\"6m0s\", or a date."
  (let ((v (string-trim (format "%s" value))))
    (cond
     ((string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" v)
      (let ((n (string-to-number v)))
        (cond ((> n 1e12) (/ n 1000.0))   ; epoch milliseconds
              ((> n 1e9) (float n))        ; epoch seconds
              (t (+ now n)))))             ; seconds from now
     ((let ((d (pai-rate-limit-parse-duration v)))
        (and d (string-match-p "\\`[0-9.]+ *[a-z]+\\(?: *[0-9.]+ *[a-z]+\\)*\\'" v)
             (+ now d))))
     (t (pai-rate-limit--parse-date v)))))

(defun pai-rate-limit-reset-time (headers &optional now)
  "Return the epoch time a rate limit lifts, from response HEADERS, or nil.
HEADERS is an alist of (lower-case NAME . VALUE).  Counts `retry-after'
\(or `retry-after-ms') and each `*-reset' header whose window is exhausted:
its matching `-remaining' header is 0, or its `-status' header is
\"rejected\".  The latest of those wins.  NOW defaults to the current time."
  (let* ((now (or now (float-time)))
         (get (lambda (name) (cdr (assoc name headers))))
         (times nil))
    (let ((ms (funcall get "retry-after-ms"))
          (ra (funcall get "retry-after")))
      (cond (ms (push (+ now (/ (string-to-number ms) 1000.0)) times))
            (ra (when-let ((tm (pai-rate-limit--parse-time-value ra now)))
                  (push tm times)))))
    (pcase-dolist (`(,name . ,value) headers)
      (when (string-match "\\`\\(.*\\)-reset\\(-[a-z]+\\)?\\'" name)
        (let* ((stem (match-string 1 name))
               (suffix (or (match-string 2 name) ""))
               (remaining (or (funcall get (concat stem "-remaining" suffix))
                              (funcall get (concat stem "-remaining"))))
               (status (or (funcall get (concat stem "-status" suffix))
                           (funcall get (concat stem "-status")))))
          (when (or (and remaining
                         (string-match-p "\\`[ \t]*0+\\(?:\\.0+\\)?[ \t]*\\'" remaining))
                    (and status (string-match-p "rejected\\|exceeded\\|exhausted" status)))
            (when-let ((tm (pai-rate-limit--parse-time-value value now)))
              (push tm times))))))
    (when times (apply #'max times))))

(defun pai-rate-limit-text-reset-time (text &optional now)
  "Return the epoch time a rate limit lifts, as stated in error TEXT, or nil."
  (when (stringp text)
    (let ((now (or now (float-time)))
          (case-fold-search t))
      (cond
       ;; Gemini: "retryDelay": "34s"
       ((string-match "retry[_ -]?delay\"?[ \t]*[:=][ \t]*\"?\\([0-9.]+ *[a-z]+\\)" text)
        (when-let ((d (pai-rate-limit-parse-duration (match-string 1 text))))
          (+ now d)))
       ;; "Please try again in 6m0s" / "retry after 20 seconds"
       ((string-match "\\(?:try again\\|retry\\(?: after\\)?\\|wait\\)[ \t]+\\(?:in[ \t]+\\|for[ \t]+\\)?\\(?:about[ \t]+\\|~\\)?\\([0-9]\\)" text)
        (when-let ((d (pai-rate-limit-parse-duration text (match-beginning 1))))
          (+ now d)))
       ;; "resets at 2026-11-01T17:00:00Z" / "reset_at": 1762016400
       ((string-match "reset[a-z_]*\"?[ \t]*\\(?:at\\|:\\|=\\)?[ \t]*\"?\\([0-9]\\{4\\}-[0-9-]+[T ][0-9:.]+\\(?:Z\\|[+-][0-9:]+\\)?\\|[0-9]\\{10,13\\}\\)" text)
        (pai-rate-limit--parse-time-value (match-string 1 text) now))))))

;;;; Waiting

(cl-defstruct (pai-rate-limit-state (:constructor pai-rate-limit-state-create))
  "Rate-limit bookkeeping for one session or run."
  (attempts 0)   ; retries since the last successful turn
  (waited 0)     ; seconds waited since the last successful turn
  timer          ; the pending retry timer, or nil
  until)         ; epoch time of the pending retry, or nil

(defun pai-rate-limit-wait-seconds (message attempt &optional now)
  "Return (SECONDS . KNOWN) to wait before retrying the failed MESSAGE.
ATTEMPT counts earlier retries (0 for the first).  KNOWN is non-nil when
the provider named the reset time; otherwise SECONDS is a backoff."
  (let* ((now (or now (float-time)))
         (at (or (let ((r (plist-get message :retry-at))) (and (numberp r) r))
                 (pai-rate-limit-text-reset-time (plist-get message :error-message) now))))
    (if (and at (> at now))
        (cons (max 1 (+ (- at now) pai-rate-limit-margin)) t)
      (cons (min pai-rate-limit-backoff-max
                 (* pai-rate-limit-backoff-initial (expt 2 (min attempt 20))))
            nil))))

(defun pai-rate-limit-format-duration (seconds)
  "Format SECONDS compactly, e.g. \"45s\", \"12m\", \"3h05m\"."
  (let ((s (round seconds)))
    (cond ((< s 60) (format "%ds" s))
          ((< s 3600) (format "%dm%02ds" (/ s 60) (% s 60)))
          ((< s 86400) (format "%dh%02dm" (/ s 3600) (/ (% s 3600) 60)))
          (t (format "%dd%02dh" (/ s 86400) (/ (% s 86400) 3600))))))

(defun pai-rate-limit-format-time (time)
  "Format epoch TIME as a clock time, with the date when not today."
  (format-time-string (if (equal (format-time-string "%F" time) (format-time-string "%F"))
                          "%H:%M:%S" "%a %H:%M")
                      time))

(defun pai-rate-limit-cancel (state)
  "Cancel STATE's pending retry, if any."
  (when state
    (when (timerp (pai-rate-limit-state-timer state))
      (cancel-timer (pai-rate-limit-state-timer state)))
    (setf (pai-rate-limit-state-timer state) nil
          (pai-rate-limit-state-until state) nil)))

(defun pai-rate-limit-reset (state)
  "Forget STATE's retries after a successful turn (the backoff starts over)."
  (when state
    (pai-rate-limit-cancel state)
    (setf (pai-rate-limit-state-attempts state) 0
          (pai-rate-limit-state-waited state) 0)))

(defun pai-rate-limit-waiting-p (state)
  "Return non-nil while STATE has a retry pending."
  (and state (timerp (pai-rate-limit-state-timer state))))

(cl-defun pai-rate-limit-recover (state message retry &key on-wait)
  "Schedule RETRY after the rate limit that failed MESSAGE lifts.
STATE is a `pai-rate-limit-state'.  Return non-nil when a retry was
scheduled: MESSAGE is a rate-limit error, retrying is enabled (see
`pai-rate-limit-retry') and its waiting budget is not spent.  ON-WAIT,
when non-nil, is called first with a plist (:seconds :until :attempt
:known :message) describing the wait.  RETRY is called with no arguments
when the wait is over."
  (when (and state pai-rate-limit-retry (pai-rate-limit-error-p message))
    (let* ((now (float-time))
           (attempt (pai-rate-limit-state-attempts state))
           (wait (pai-rate-limit-wait-seconds message attempt now))
           (secs (car wait))
           (budget (and (numberp pai-rate-limit-retry) pai-rate-limit-retry)))
      (unless (and budget (> (+ (pai-rate-limit-state-waited state) secs) budget))
        (pai-rate-limit-cancel state)
        (setf (pai-rate-limit-state-attempts state) (1+ attempt)
              (pai-rate-limit-state-waited state) (+ (pai-rate-limit-state-waited state) secs)
              (pai-rate-limit-state-until state) (+ now secs))
        (when on-wait
          (funcall on-wait (list :seconds secs :until (+ now secs) :attempt (1+ attempt)
                                 :known (cdr wait) :message message)))
        (setf (pai-rate-limit-state-timer state)
              (run-at-time secs nil
                           (lambda ()
                             (setf (pai-rate-limit-state-timer state) nil
                                   (pai-rate-limit-state-until state) nil)
                             (funcall retry))))
        t))))

(defun pai-rate-limit-recover-function (state &optional on-wait on-retry)
  "Return an agent-loop `:recover-error' hook that waits out rate limits.
STATE is a `pai-rate-limit-state'.  ON-WAIT is called with the wait plist
\(see `pai-rate-limit-recover'); ON-RETRY with no arguments just before
the turn is streamed again.  For runs without a UI, e.g. headless
subagents: add it to the `pai-agent-run' config as `:recover-error'."
  (lambda (message context resume)
    (pai-rate-limit-recover
     state message
     (lambda ()
       (when on-retry (funcall on-retry))
       (funcall resume (list :messages (plist-get context :messages))))
     :on-wait on-wait)))

(provide 'pai-rate-limit)
;;; pai-rate-limit.el ends here
