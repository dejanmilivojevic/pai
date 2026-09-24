;;; pai-usage-test.el --- Tests for provider usage reporting -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai-usage)

(defmacro pai-usage-test--with (keys creds json &rest body)
  "Run BODY with mocked credentials and HTTP.
KEYS is an alist provider->api-key, CREDS provider->cred-plist, JSON a function
\(URL HEADERS) -> decoded plist."
  (declare (indent 3))
  `(cl-letf (((symbol-function 'pai-api-key)
              (lambda (p) (cdr (assoc p ,keys))))
             ((symbol-function 'pai-auth-get)
              (lambda (p) (cdr (assoc p ,creds))))
             ((symbol-function 'pai-usage--get-json) ,json))
     ,@body))

;;;; Registry

(ert-deftest pai-usage-registry ()
  (let ((pai-usage-providers nil))
    (pai-register-usage-provider "x" (lambda (_k _c) '(:summary "X")))
    (should (pai-usage-provider-p "x"))
    (should-not (pai-usage-provider-p "y"))
    ;; re-register replaces
    (pai-register-usage-provider "x" (lambda (_k _c) '(:summary "X2")))
    (should (= 1 (length pai-usage-providers)))))

(ert-deftest pai-usage-available-only-logged-in ()
  (let ((pai-usage-providers nil))
    (pai-register-usage-provider "a" (lambda (_k _c) '(:summary "A")))
    (pai-register-usage-provider "b" (lambda (_k _c) '(:summary "B")))
    (pai-usage-test--with '(("a" . "key-a")) nil (lambda (&rest _) nil)
      (should (equal (pai-usage-available-providers) '("a"))))))

(ert-deftest pai-usage-fetch-error-captured ()
  (let ((pai-usage-providers nil))
    (pai-register-usage-provider "boom" (lambda (_k _c) (error "kaboom")))
    (pai-usage-test--with '(("boom" . "k")) nil (lambda (&rest _) nil)
      (let ((r (pai-usage-fetch "boom")))
        (should (equal (plist-get r :provider) "boom"))
        (should (string-match-p "kaboom" (plist-get r :error)))))))

;;;; OpenRouter

(ert-deftest pai-usage-openrouter-parse ()
  (pai-usage-test--with '(("openrouter" . "sk-or-x")) nil
      (lambda (url _headers)
        (should (string-match-p "openrouter.ai/api/v1/credits" url))
        '(:data (:total_credits 20 :total_usage 7.5)))
    (let ((r (pai-usage-fetch "openrouter")))
      (should (equal (plist-get r :summary) "OR $12.50"))
      (should (string-match-p "Remaining: \\$12.50" (plist-get r :detail)))
      (should (string-match-p "Purchased: \\$20.00" (plist-get r :detail))))))

(ert-deftest pai-usage-openrouter-not-logged-in ()
  (should-error (pai-usage--openrouter nil nil)))

;;;; Anthropic

(ert-deftest pai-usage-anthropic-oauth-parse ()
  (pai-usage-test--with nil nil
      (lambda (url headers)
        (should (string-match-p "api.anthropic.com/api/oauth/usage" url))
        (should (equal (cdr (assoc "anthropic-beta" headers)) "oauth-2025-04-20"))
        '(:five_hour (:utilization 12 :resets_at "2026-01-01T10:00:00Z")
          :seven_day (:utilization 45 :resets_at "2026-01-07T00:00:00Z")
          :spend (:used (:amount_minor 250 :exponent 2)
                  :limit (:amount_minor 2000 :exponent 2))))
    (let ((r (cl-letf (((symbol-function 'pai-api-key) (lambda (_) "sk-ant-oat01-TOK")))
               (pai-usage-fetch "anthropic"))))
      (should (equal (plist-get r :summary) "Claude 5h 12% 7d 45%"))
      (should (string-match-p "5-hour" (plist-get r :detail)))
      (should (string-match-p "12% used" (plist-get r :detail)))
      (should (string-match-p "45% used" (plist-get r :detail)))
      (should (string-match-p "Extra spend: \\$2.50 / \\$20.00" (plist-get r :detail))))))

(ert-deftest pai-usage-anthropic-requires-oauth ()
  "An API-key credential cannot report subscription usage."
  (should-error (pai-usage--anthropic "sk-ant-api03-KEY" '(:type "api_key"))))

;;;; Error replies are errors, not data

(ert-deftest pai-usage-anthropic-error-reply ()
  "A rate-limit or error body is reported as an error, never as a bare \"Claude\"."
  (should-error (pai-usage--anthropic-parse
                 '(:type "error" :error (:type "rate_limit_error" :message "Rate limited")))
                :type 'error)
  (should (string-match-p "Rate limited"
                          (condition-case e (pai-usage--anthropic-parse
                                             '(:error (:type "rate_limit_error" :message "Rate limited")))
                            (error (error-message-string e)))))
  (should-error (pai-usage--anthropic-parse '(:something "else"))))

;;;; Shared asynchronous refresh

(defmacro pai-usage-test--async (replies &rest body)
  "Run BODY with a fresh cache and `pai-usage--request-async' answering REPLIES.
REPLIES is a list of (STATUS BODY RETRY-AFTER) handed out in order; the
variable `requests' counts the requests made."
  (declare (indent 1))
  `(let ((pai-usage--cache (make-hash-table :test 'equal))
         (pai-usage-providers nil)
         (replies ,replies)
         (requests 0))
     (pai-register-usage-provider
      "p" (lambda (_k _c) (list :request (list :url "https://x" :headers nil)
                                 :parse (lambda (b) (list :summary (plist-get b :s) :detail "D")))))
     (cl-letf (((symbol-function 'pai-api-key) (lambda (_) "k"))
               ((symbol-function 'pai-auth-get) (lambda (_) nil))
               ((symbol-function 'pai-usage--request-async)
                (lambda (_url _headers cb)
                  (cl-incf requests)
                  (apply cb (or (pop replies) (list nil nil nil))))))
       ,@body)))

(ert-deftest pai-usage-refresh-caches-for-all-callers ()
  "Within the TTL every caller gets the cached result; nothing is refetched."
  (pai-usage-test--async '((200 (:s "P 10%") nil))
    (let (seen)
      (pai-usage-refresh "p" nil (lambda (st) (push (plist-get (plist-get st :result) :summary) seen)))
      (pai-usage-refresh "p" nil (lambda (st) (push (plist-get (plist-get st :result) :summary) seen)))
      (should (= requests 1))
      (should (equal seen '("P 10%" "P 10%")))
      (should (equal (pai-usage-summary "p") "P 10%")))))

(ert-deftest pai-usage-rate-limit-keeps-numbers-and-backs-off ()
  "A 429 keeps the last numbers, backs off, and even FORCE does not refetch."
  (let ((pai-usage-rate-limit-backoff 300))
    (pai-usage-test--async '((200 (:s "P 10%") nil) (429 nil nil) (429 nil 900))
      (pai-usage-refresh "p")
      ;; TTL passed: fetch again, rate-limited
      (pai-usage--put "p" :next 0)
      (pai-usage-refresh "p")
      (should (= requests 2))
      ;; same text, marked as not current
      (let ((shown (pai-usage-summary "p")))
        (should (equal (substring-no-properties shown) "P 10%"))
        (should (eq (get-text-property 0 'face shown) 'pai-usage-stale-face))
        (should (string-match-p "not current: rate-limited" (get-text-property 0 'help-echo shown))))
      (let ((st (pai-usage--state "p")))
        (should (plist-get st :limited))
        (should (string-match-p "rate-limited" (plist-get st :error)))
        (should (> (plist-get st :next) (+ (float-time) 290))))
      ;; FORCE during the backoff: no request
      (pai-usage-refresh "p" t)
      (should (= requests 2))
      ;; after the backoff, limited again: the wait doubles, or honours Retry-After
      (pai-usage--put "p" :next 0)
      (pai-usage-refresh "p")
      (should (= requests 3))
      (should (> (plist-get (pai-usage--state "p") :next) (+ (float-time) 890))))))

(ert-deftest pai-usage-rate-limit-without-numbers ()
  "Without any numbers the placeholder is shown, greyed out, with the reason."
  (pai-usage-test--async '((429 nil nil))
    (let ((pai-usage-placeholders '(("p" . "P --%"))))
      ;; nothing asked yet: nothing shown
      (should-not (pai-usage-summary "p"))
      (pai-usage-refresh "p")
      (let ((shown (pai-usage-summary "p")))
        (should (equal (substring-no-properties shown) "P --%"))
        (should (eq (get-text-property 0 'face shown) 'pai-usage-unavailable-face))
        (should (string-match-p "not available: rate-limited" (get-text-property 0 'help-echo shown)))))))

(ert-deftest pai-usage-current-vs-old ()
  "Fresh numbers are plain; numbers older than `pai-usage-stale-after' are marked."
  (pai-usage-test--async '((200 (:s "P 5%") nil))
    (pai-usage-refresh "p")
    (should-not (get-text-property 0 'face (pai-usage-summary "p")))
    (pai-usage--put "p" :time (- (float-time) 1000))
    (should (eq (get-text-property 0 'face (pai-usage-summary "p")) 'pai-usage-stale-face))))

(ert-deftest pai-usage-bad-reply-is-an-error ()
  "HTTP errors and unparsable replies are errors, and old numbers are kept."
  (pai-usage-test--async '((200 (:s "P 1%") nil) (500 nil nil))
    (pai-usage-refresh "p")
    (pai-usage--put "p" :next 0)
    (pai-usage-refresh "p")
    (should (equal (plist-get (pai-usage--state "p") :error) "HTTP 500"))
    (should (equal (substring-no-properties (pai-usage-summary "p")) "P 1%"))))

(ert-deftest pai-usage-waiters-share-one-request ()
  "Callers arriving while a request is in flight wait for it."
  (let ((pai-usage--cache (make-hash-table :test 'equal))
        (pai-usage-providers nil)
        (pending nil) (requests 0) (seen 0))
    (pai-register-usage-provider
     "p" (lambda (_k _c) (list :request (list :url "https://x") :parse (lambda (_b) '(:summary "S")))))
    (cl-letf (((symbol-function 'pai-api-key) (lambda (_) "k"))
              ((symbol-function 'pai-auth-get) (lambda (_) nil))
              ((symbol-function 'pai-usage--request-async)
               (lambda (_u _h cb) (cl-incf requests) (setq pending cb))))
      (pai-usage-refresh "p" nil (lambda (_) (cl-incf seen)))
      (pai-usage-refresh "p" t (lambda (_) (cl-incf seen)))
      (should (= requests 1))
      (should (= seen 0))
      (funcall pending 200 '(:x 1) nil)
      (should (= seen 2)))))

;;;; Helpers

(ert-deftest pai-usage-money-helper ()
  (should (= (pai-usage--money '(:amount_minor 1234 :exponent 2)) 12.34))
  (should (= (pai-usage--money '(:amount_minor 5 :exponent 0)) 5.0))
  (should (null (pai-usage--money '(:currency "USD")))))

(provide 'pai-usage-test)
;;; pai-usage-test.el ends here
