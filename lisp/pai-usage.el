;;; pai-usage.el --- Provider usage / balance reporting -*- lexical-binding: t; -*-

;;; Commentary:

;; A small abstraction letting each provider report its account usage --
;; OpenRouter credits, Anthropic (Claude Pro/Max) rate-limit windows and spend,
;; etc. -- so core can surface a compact summary in the header line and a
;; detailed breakdown via the `/usage' slash command.
;;
;; A provider registers a fetcher with `pai-register-usage-provider':
;;
;;   (pai-register-usage-provider "openrouter" #'my-fetcher)
;;
;; The fetcher receives (KEY CRED) -- the resolved API key/token and the raw
;; stored credential plist -- and returns either the result plist
;;
;;   (:summary \"OR $12.34\"        ; short, for the header bar (nil to hide)
;;    :detail  \"OpenRouter\\n  ...\") ; multi-line, for `/usage'
;;
;; or, preferably, a request to make and how to read its reply:
;;
;;   (:request (:url URL :headers ALIST) :parse FN)  ; FN: decoded JSON -> result
;;
;; A request is made asynchronously (never blocking Emacs) by
;; `pai-usage-refresh', which also caches results for all buffers, refetches
;; at most every `pai-usage-ttl' seconds, and backs off when the provider
;; rate-limits (HTTP 429), keeping the last good numbers on screen.  Errors
;; are signalled by the fetcher or the parser and reported rather than shown
;; as data.  Built-in fetchers for OpenRouter and Anthropic are registered
;; below.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-core)
(require 'pai-config)
(require 'pai-commands)
(require 'pai-auth)
(require 'pai-provider-anthropic)
(require 'url)

(defvar pai-usage-providers nil
  "Alist of provider id (string) -> fetcher function.
The fetcher takes (KEY CRED) and returns a plist (:summary :detail) or signals.")

(defun pai-register-usage-provider (id fetcher)
  "Register FETCHER as the usage reporter for provider ID.  Re-registering replaces."
  (setf (alist-get id pai-usage-providers nil nil #'equal) fetcher)
  id)

(defun pai-usage-provider-p (id)
  "Return non-nil if a usage fetcher is registered for provider ID."
  (and (assoc id pai-usage-providers) t))

(defun pai-usage-fetch (id)
  "Fetch usage for provider ID.
Return a plist (:provider ID :summary S :detail D) or (:provider ID :error E),
or nil when no fetcher is registered."
  (let ((fetcher (cdr (assoc id pai-usage-providers))))
    (when fetcher
      (condition-case err
          (let* ((key (pai-api-key id))
                 (cred (and (fboundp 'pai-auth-get) (pai-auth-get id))))
            (if (not (or key cred))
                (list :provider id :error "not logged in")
              (let ((spec (funcall fetcher key cred)))
                (append (list :provider id)
                        (if (plist-get spec :request)
                            (funcall (plist-get spec :parse)
                                     (pai-usage--get-json
                                      (plist-get (plist-get spec :request) :url)
                                      (plist-get (plist-get spec :request) :headers)))
                          spec)))))
        (error (list :provider id :error (error-message-string err)))))))

(defun pai-usage-available-providers ()
  "Return ids of providers that have a fetcher AND a resolvable credential."
  (cl-loop for (id . _) in pai-usage-providers
           when (or (pai-api-key id)
                    (and (fboundp 'pai-auth-get) (pai-auth-get id)))
           collect id))

(defun pai-usage-fetch-all ()
  "Fetch usage for every logged-in provider.  Return a list of result plists."
  (mapcar #'pai-usage-fetch (pai-usage-available-providers)))

;;;; HTTP helper

(defun pai-usage--get-json (url headers)
  "GET URL with HEADERS (alist) and return the decoded JSON plist, or nil."
  (pai-auth--http-json url "GET" nil headers))

;;;; Formatting helpers

(defun pai-usage--reset-string (iso)
  "Format ISO-8601 reset time ISO as a short local time, or nil."
  (when (and (stringp iso) (not (string-empty-p iso)))
    (ignore-errors (format-time-string "%b %-d %H:%M" (date-to-time iso)))))

(defun pai-usage--money (amount)
  "Convert an Anthropic money plist AMOUNT (:amount_minor :exponent) to dollars."
  (let ((minor (plist-get amount :amount_minor))
        (exp (or (plist-get amount :exponent) 2)))
    (when (numberp minor)
      (/ (float minor) (expt 10 exp)))))

;;;; Built-in: OpenRouter

(defun pai-usage--openrouter (key _cred)
  "Return the request for the OpenRouter credit balance, using api KEY."
  (unless (and key (not (string-empty-p key)))
    (error "not logged in"))
  (list :request (list :url "https://openrouter.ai/api/v1/credits"
                       :headers (list (cons "Authorization" (concat "Bearer " key))))
        :parse #'pai-usage--openrouter-parse))

(defun pai-usage--openrouter-parse (resp)
  "Return the usage result for the OpenRouter credits reply RESP."
  (let ((data (plist-get resp :data)))
    (unless data (error "could not read OpenRouter credits"))
    (let* ((total (float (or (plist-get data :total_credits) 0)))
           (used (float (or (plist-get data :total_usage) 0)))
           (remaining (- total used)))
      (list :summary (format "OR $%.2f" remaining)
            :detail (concat "OpenRouter\n"
                            (format "  Purchased: $%.2f\n" total)
                            (format "  Used:      $%.4f\n" used)
                            (format "  Remaining: $%.2f" remaining))))))

;;;; Built-in: Anthropic (Claude Pro/Max, OAuth only)

(defconst pai-usage--anthropic-endpoint "https://api.anthropic.com/api/oauth/usage"
  "Anthropic OAuth account-usage endpoint.")

(defun pai-usage--pct (utilization)
  "Round Anthropic UTILIZATION (already a 0-100 percentage) to a clamped integer."
  (and (numberp utilization) (min 100 (max 0 (round utilization)))))

(defun pai-usage--anthropic-window (label bucket)
  "Format a Claude usage BUCKET (:utilization :resets_at) line labelled LABEL."
  (when bucket
    (let* ((pct (pai-usage--pct (plist-get bucket :utilization)))
           (reset (pai-usage--reset-string (plist-get bucket :resets_at))))
      (when pct
        (format "  %-8s %3d%% used%s" label pct
                (if reset (format " (resets %s)" reset) ""))))))

(defun pai-usage--anthropic (key cred)
  "Return the request for Claude subscription usage.  Needs an OAuth token (KEY or CRED)."
  (let ((oauth (or (and key (string-search "sk-ant-oat" key))
                   (equal (plist-get cred :type) "oauth"))))
    (unless oauth
      (error "usage requires a Claude subscription (run `/login anthropic')"))
    (list :request (list :url pai-usage--anthropic-endpoint
                         :headers (list (cons "Authorization" (concat "Bearer " key))
                                        (cons "anthropic-beta" pai-anthropic-oauth-beta)
                                        (cons "anthropic-version" pai-anthropic-version)
                                        (cons "user-agent" (pai-anthropic-claude-code-user-agent))
                                        (cons "content-type" "application/json")))
          :parse #'pai-usage--anthropic-parse)))

(defun pai-usage--anthropic-parse (resp)
  "Return the usage result for the Claude usage reply RESP."
  (progn
      (unless resp (error "could not read Claude usage"))
      (when (plist-get resp :error)
        (error "Claude usage: %s"
               (let ((e (plist-get resp :error)))
                 (or (and (listp e) (or (plist-get e :message) (plist-get e :type))) e))))
      (unless (or (plist-get resp :five_hour) (plist-get resp :seven_day))
        (error "Claude usage reply has no usage windows"))
      (let* ((h5 (plist-get resp :five_hour))
             (d7 (plist-get resp :seven_day))
             (d7o (plist-get resp :seven_day_opus))
             (spend (plist-get resp :spend))
             (lines (delq nil
                          (list (pai-usage--anthropic-window "5-hour" h5)
                                (pai-usage--anthropic-window "7-day" d7)
                                (pai-usage--anthropic-window "7d Opus" d7o))))
             (spend-line
              (when (and spend (numberp (pai-usage--money (plist-get spend :used))))
                (let ((used (pai-usage--money (plist-get spend :used)))
                      (limit (pai-usage--money (plist-get spend :limit))))
                  (format "  Extra spend: $%.2f%s" used
                          (if limit (format " / $%.2f" limit) "")))))
             (h5-pct (pai-usage--pct (plist-get h5 :utilization)))
             (d7-pct (pai-usage--pct (plist-get d7 :utilization))))
        (list :summary
              (cond ((and h5-pct d7-pct) (format "Claude 5h %d%% 7d %d%%" h5-pct d7-pct))
                    (h5-pct (format "Claude 5h %d%%" h5-pct))
                    (t "Claude"))
              :detail
              (concat "Claude (subscription)\n"
                      (if (or lines spend-line)
                          (string-join (delq nil (append lines (list spend-line))) "\n")
                        "  (no usage windows reported)"))))))

;;;; Asynchronous refresh, shared by all buffers

(defcustom pai-usage-ttl 120
  "Seconds a fetched usage result is reused before it is fetched again.
The result is shared by every pai buffer, so this bounds how often each
provider's usage endpoint is called, however many sessions are open."
  :type 'number :group 'pai)

(defcustom pai-usage-rate-limit-backoff 300
  "Seconds to wait after a provider rate-limits the usage request.
Doubled on every further rate limit (up to an hour), or longer when the
provider sends Retry-After.  The last good numbers stay on screen."
  :type 'number :group 'pai)

(defcustom pai-usage-request-timeout 30
  "Seconds before an unanswered usage request is abandoned."
  :type 'number :group 'pai)

(defvar pai-usage--cache (make-hash-table :test 'equal)
  "Provider id -> state plist.
:result  the last good result plist (:summary :detail), or nil
:time    when :result was fetched (float time)
:error   why the latest attempt failed, or nil
:next    earliest time the next fetch may start
:limited non-nil while backing off after a rate limit
:backoff the current rate-limit backoff in seconds
:pending callbacks waiting for the request in flight, or nil")

(defun pai-usage--state (id)
  "Return the cached state plist for provider ID."
  (gethash id pai-usage--cache))

(defun pai-usage--put (id &rest props)
  "Set PROPS in provider ID's cached state and return the state."
  (let ((state (copy-sequence (pai-usage--state id))))
    (while props
      (setq state (plist-put state (pop props) (pop props))))
    (puthash id state pai-usage--cache)
    state))

(defun pai-usage--request-async (url headers callback)
  "GET URL with HEADERS without blocking Emacs.
Call CALLBACK once with (STATUS BODY RETRY-AFTER): the HTTP status code
\(nil when there was no answer), the decoded JSON body (or nil) and the
Retry-After seconds (or nil)."
  (let* ((done nil)
         (timer nil)
         (buffer nil)
         (finish (lambda (status body retry)
                   (unless done
                     (setq done t)
                     (when timer (cancel-timer timer))
                     (funcall callback status body retry))))
         (url-request-method "GET")
         (url-request-extra-headers headers))
    (setq buffer
          (condition-case nil
              (url-retrieve
               url
               (lambda (_status)
                 (let ((reply (current-buffer)))
                   (unwind-protect
                       (let ((code nil) (retry nil) (body nil) (case-fold-search t))
                         (goto-char (point-min))
                         (when (looking-at "HTTP/[0-9.]+ \\([0-9]+\\)")
                           (setq code (string-to-number (match-string 1))))
                         (let ((head-end (save-excursion (re-search-forward "\r?\n\r?\n" nil t))))
                           (when (and head-end
                                      (re-search-forward "^retry-after:[ \t]*\\([0-9]+\\)" head-end t))
                             (setq retry (string-to-number (match-string 1))))
                           (when head-end
                             (let ((text (string-trim (buffer-substring-no-properties head-end (point-max)))))
                               (unless (string-empty-p text)
                                 (setq body (ignore-errors (pai-json-decode text)))))))
                         (funcall finish code body retry))
                     (when (buffer-live-p reply)
                       (let ((kill-buffer-query-functions nil)) (kill-buffer reply))))))
               nil t t)
            (error (funcall finish nil nil nil) nil)))
    (unless done
      (setq timer
            (run-at-time pai-usage-request-timeout nil
                         (lambda ()
                           (when (buffer-live-p buffer)
                             (let ((proc (get-buffer-process buffer)))
                               (when proc (delete-process proc)))
                             (let ((kill-buffer-query-functions nil)) (kill-buffer buffer)))
                           (funcall finish nil nil nil)))))
    buffer))

(defun pai-usage--settle (id result error &optional rate-limited retry-after)
  "Record the outcome of a fetch for ID and run the waiting callbacks.
RESULT is the new result plist on success; otherwise ERROR says why.
RATE-LIMITED starts or extends the backoff, honouring RETRY-AFTER."
  (let* ((now (float-time))
         (state (pai-usage--state id))
         (waiting (plist-get state :pending)))
    (cond
     (result
      (pai-usage--put id :result result :time now :error nil :limited nil :backoff nil
                      :next (+ now pai-usage-ttl) :pending nil))
     (rate-limited
      (let* ((backoff (min 3600 (if (plist-get state :limited)
                                    (* 2 (or (plist-get state :backoff) pai-usage-rate-limit-backoff))
                                  pai-usage-rate-limit-backoff)))
             (wait (max backoff (or retry-after 0))))
        (pai-usage--put id :error (format "rate-limited, retrying at %s"
                                          (format-time-string "%H:%M" (+ now wait)))
                        :limited t :backoff backoff :next (+ now wait) :pending nil)))
     (t
      (pai-usage--put id :error (or error "unavailable") :limited nil
                      :next (+ now pai-usage-ttl) :pending nil)))
    (let ((state (pai-usage--state id)))
      (dolist (cb (reverse waiting))
        (condition-case err (funcall cb state)
          (error (message "pai-usage: %s" (error-message-string err))))))))

(defun pai-usage-refresh (id &optional force callback)
  "Refresh provider ID's usage in the background; call CALLBACK with its state.
The fetch starts only when the cached result is older than `pai-usage-ttl'
\(FORCE skips that wait, but never a rate-limit backoff) and no request is
already in flight; otherwise CALLBACK gets the cached state at once, or
when the request in flight completes.  Never blocks Emacs."
  (let* ((fetcher (cdr (assoc id pai-usage-providers)))
         (state (pai-usage--state id))
         (now (float-time)))
    (cond
     ((null fetcher) nil)
     ((plist-get state :pending)
      (when callback (pai-usage--put id :pending (cons callback (plist-get state :pending)))))
     ((or (and (plist-get state :limited) (< now (plist-get state :next)))
          (and (not force) (plist-get state :next) (< now (plist-get state :next))))
      (when callback (funcall callback state)))
     (t
      (pai-usage--put id :pending (list (or callback #'ignore)))
      (condition-case err
          (let* ((key (pai-api-key id))
                 (cred (and (fboundp 'pai-auth-get) (pai-auth-get id))))
            (if (not (or key cred))
                (pai-usage--settle id nil "not logged in")
              (let ((spec (funcall fetcher key cred)))
                (if (not (plist-get spec :request))
                    ;; A fetcher that did its own (synchronous) work.
                    (pai-usage--settle id spec nil)
                  (let ((parse (plist-get spec :parse))
                        (req (plist-get spec :request)))
                    (pai-usage--request-async
                     (plist-get req :url) (plist-get req :headers)
                     (lambda (status body retry)
                       (cond
                        ((eql status 429)
                         (pai-usage--settle id nil nil t retry))
                        ((null status)
                         (pai-usage--settle id nil "no answer"))
                        ((not (and (>= status 200) (< status 300)))
                         (pai-usage--settle id nil (format "HTTP %d" status)))
                        (t
                         (condition-case err
                             (pai-usage--settle id (funcall parse body) nil)
                           (error (pai-usage--settle id nil (error-message-string err)))))))))))))
        (error (pai-usage--settle id nil (error-message-string err))))))))

(defface pai-usage-stale-face '((t :inherit warning))
  "Face of a usage summary whose numbers are not current.")

(defface pai-usage-unavailable-face '((t :inherit shadow))
  "Face of the usage placeholder shown when no numbers are available.")

(defcustom pai-usage-stale-after 600
  "Seconds after which a usage summary is shown as not current."
  :type 'number :group 'pai)

(defvar pai-usage-placeholders
  '(("anthropic" . "Claude 5h --% 7d --%")
    ("openrouter" . "OR $--"))
  "Provider id -> summary shown, greyed out, while no numbers are available.
It has the same shape as a real summary, so the header does not change
layout.  Providers without an entry show nothing until they have data.")

(defun pai-usage-summary (id)
  "Return the header-line usage summary for provider ID, or nil.
Always the same display: the latest numbers when they are current; the last
good numbers in `pai-usage-stale-face' when the latest refresh failed or
they are older than `pai-usage-stale-after'; and, without any numbers, the
provider's placeholder (see `pai-usage-placeholders') in
`pai-usage-unavailable-face'.  Hovering shows why."
  (let* ((state (pai-usage--state id))
         (summary (plist-get (plist-get state :result) :summary))
         (err (plist-get state :error))
         (age (and summary (- (float-time) (or (plist-get state :time) 0)))))
    (cond
     ((and summary (not err) (<= age pai-usage-stale-after))
      summary)
     (summary
      (propertize summary
                  'face 'pai-usage-stale-face
                  'help-echo (format "Usage from %s (%d min ago), not current%s"
                                     (format-time-string "%H:%M" (plist-get state :time))
                                     (round (/ age 60))
                                     (if err (concat ": " err) ""))))
     ((and state (cdr (assoc id pai-usage-placeholders)))
      (propertize (cdr (assoc id pai-usage-placeholders))
                  'face 'pai-usage-unavailable-face
                  'help-echo (concat "Usage not available"
                                     (if err (concat ": " err) " yet")))))))

;;;; Report / command

(defun pai-usage-report ()
  "Return a formatted usage report string for all logged-in providers.
Fetches synchronously; interactive use goes through `pai-usage-command'."
  (let ((results (pai-usage-fetch-all)))
    (if (null results)
        "No usage-reporting providers are logged in."
      (mapconcat
       (lambda (r)
         (or (plist-get r :detail)
             (format "%s\n  error: %s" (plist-get r :provider)
                     (or (plist-get r :error) "unavailable"))))
       results "\n\n"))))

(defun pai-usage--report-from-states (ids)
  "Return the usage report for provider IDS from their cached states."
  (mapconcat
   (lambda (id)
     (let* ((state (pai-usage--state id))
            (detail (plist-get (plist-get state :result) :detail))
            (err (plist-get state :error)))
       (cond ((and detail err)
              (format "%s\n  (from %s; latest refresh: %s)" detail
                      (format-time-string "%H:%M" (plist-get state :time)) err))
             (detail detail)
             (t (format "%s\n  error: %s" id (or err "unavailable"))))))
   ids "\n\n"))

(declare-function pai--render-note "pai-ui" (text &optional face))

(defun pai-usage-command (_args _ctx)
  "Handler for `/usage': show account usage/credits for logged-in providers.
The providers are asked in the background; the report appears in this
buffer when all have answered."
  (let ((ids (pai-usage-available-providers))
        (buffer (current-buffer)))
    (if (null ids)
        (list :message "No usage-reporting providers are logged in.")
      (let ((remaining (length ids)))
        (dolist (id ids)
          (pai-usage-refresh
           id t
           (lambda (_state)
             (when (= 0 (setq remaining (1- remaining)))
               (let ((report (pai-usage--report-from-states ids)))
                 (if (and (buffer-live-p buffer) (fboundp 'pai--render-note))
                     (with-current-buffer buffer (pai--render-note report))
                   (message "%s" report))))))))
      (list :message "Fetching usage…"))))

(pai-register-command "usage"
  :description "Show account usage/credits for logged-in providers"
  :handler #'pai-usage-command)

;;;; Register built-ins

(pai-register-usage-provider "openrouter" #'pai-usage--openrouter)
(pai-register-usage-provider "anthropic" #'pai-usage--anthropic)

(provide 'pai-usage)
;;; pai-usage.el ends here
