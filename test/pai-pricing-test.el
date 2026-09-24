;;; pai-pricing-test.el --- Tests for model prices and session cost -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pai)
(require 'pai-faux)
(require 'pai-pricing)

(defconst pai-pricing-test--catalog
  "{\"anthropic\":{\"models\":{
      \"claude-opus-5-5\":{\"cost\":{\"input\":4,\"output\":20,\"cache_read\":0.2,\"cache_write\":5}},
      \"claude-free\":{\"cost\":{\"input\":0,\"output\":0}},
      \"claude-nocost\":{}}},
    \"lmstudio\":{\"models\":{\"qwen\":{\"cost\":{\"input\":0,\"output\":0}}}},
    \"openrouter\":{\"models\":{\"anthropic/claude-sonnet-5\":{\"cost\":{\"input\":2,\"output\":10}}}}}"
  "A tiny models.dev-shaped catalog.")

(defmacro pai-pricing-test--with-catalog (&rest body)
  "Run BODY with the fixture catalog installed in a temp pai home."
  (declare (indent 0))
  `(let* ((pai-directory (make-temp-file "pai-pricing" t))
          (pai-pricing--table nil)
          (file (make-temp-file "catalog" nil ".json" pai-pricing-test--catalog)))
     (unwind-protect
         (progn (pai-pricing--install-download file) ,@body)
       (delete-file file)
       (delete-directory pai-directory t))))

;;;; Catalog

(ert-deftest pai-pricing-prunes-and-caches ()
  (pai-pricing-test--with-catalog
    (should (= (hash-table-count pai-pricing--table) 2))
    (should (equal (gethash "anthropic/claude-opus-5-5" pai-pricing--table)
                   '(:input 4.0 :output 20.0 :cache-read 0.2 :cache-write 5.0)))
    ;; zero and missing prices are dropped
    (should-not (gethash "anthropic/claude-free" pai-pricing--table))
    (should-not (gethash "lmstudio/qwen" pai-pricing--table))
    ;; the cache file round-trips
    (setq pai-pricing--table nil)
    (should (equal (gethash "openrouter/anthropic/claude-sonnet-5" (pai-pricing-load))
                   '(:input 2.0 :output 10.0 :cache-read 0.0 :cache-write 0.0)))))

(ert-deftest pai-pricing-lookup-rules ()
  (pai-pricing-test--with-catalog
    ;; exact, then without a -YYYYMMDD date
    (should (pai-model-rates '(:provider "anthropic" :id "claude-opus-5-5")))
    (should (equal (plist-get (pai-model-rates '(:provider "anthropic" :id "claude-opus-5-5-20260601"))
                              :output)
                   20.0))
    ;; other providers never borrow prices: a local model stays unpriced
    (should-not (pai-model-rates '(:provider "local" :id "claude-opus-5-5")))
    (should-not (pai-model-priced-p '(:provider "local" :id "Qwen3.6-35B-A3B-NVFP4")))
    ;; a model's own price wins over the catalog
    (should (equal (plist-get (pai-model-rates '(:provider "anthropic" :id "claude-opus-5-5"
                                                  :cost (:input 1.0 :output 2.0)))
                              :input)
                   1.0))
    ;; an all-zero own price counts as unknown
    (should (equal (plist-get (pai-model-rates '(:provider "anthropic" :id "claude-opus-5-5"
                                                  :cost (:input 0.0 :output 0.0)))
                              :input)
                   4.0))))

(ert-deftest pai-pricing-refresh-guards ()
  (let* ((pai-directory (make-temp-file "pai-pricing" t))
         (pai-pricing--table nil)
         (started nil))
    (unwind-protect
        (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (setq started t) nil)))
          ;; disabled
          (let ((pai-pricing-url nil)) (pai-pricing-refresh t))
          (should-not started)
          ;; fresh cache: no download
          (pai-pricing--write-cache (make-hash-table :test 'equal))
          (pai-pricing-refresh)
          (should-not started)
          ;; stale: download
          (let ((pai-pricing-max-age -1))
            (when (executable-find pai-curl-program)
              (pai-pricing-refresh)
              (should started))))
      (delete-directory pai-directory t))))

;;;; Usage cost

(ert-deftest pai-usage-cost-prefers-reported-cost ()
  (let ((model (pai-make-model :id "m" :provider "p" :cost '(:input 1.0 :output 1.0))))
    (should (= (pai-usage-cost (pai-usage :input 1000000) model) 1.0))
    (should (= (pai-usage-cost (pai-usage :input 1000000 :reported-cost 0.25) model) 0.25))
    ;; reported costs add up; unreported ones stay unreported
    (should (= (plist-get (pai-usage-add (pai-usage :reported-cost 0.1) (pai-usage :reported-cost 0.2))
                          :reported-cost)
               0.30000000000000004))
    (should-not (plist-get (pai-usage-add (pai-usage) (pai-usage)) :reported-cost))))

;;;; OpenAI-compatible / OpenRouter

(ert-deftest pai-openai-usage-splits-cache-and-keeps-cost ()
  (let ((acc (pai-accum-new (pai-make-model :id "m" :provider "openrouter"))))
    (pai-openai--apply-usage acc '(:prompt_tokens 1000 :completion_tokens 50 :total_tokens 1050
                                   :prompt_tokens_details (:cached_tokens 800 :cache_write_tokens 100)
                                   :cost 0.0123))
    (let ((u (plist-get (pai-accum-message acc) :usage)))
      (should (= (plist-get u :input) 100))
      (should (= (plist-get u :cache-read) 800))
      (should (= (plist-get u :cache-write) 100))
      (should (= (plist-get u :output) 50))
      (should (= (plist-get u :reported-cost) 0.0123))))
  ;; plain OpenAI-compatible servers: no details, no cost
  (let ((acc (pai-accum-new (pai-make-model :id "m" :provider "local"))))
    (pai-openai--apply-usage acc '(:prompt_tokens 10 :completion_tokens 5))
    (let ((u (plist-get (pai-accum-message acc) :usage)))
      (should (= (plist-get u :input) 10))
      (should-not (plist-get u :reported-cost)))))

(ert-deftest pai-openai-requests-cost-from-openrouter-only ()
  (let ((ctx (list :messages (list (pai-user-message "hi")))))
    (should (equal (plist-get (plist-get (pai-openai-build-request
                                          (pai-make-model :id "x" :provider "openrouter"
                                                          :base-url "https://openrouter.ai/api/v1")
                                          ctx nil)
                                         :body)
                              :usage)
                   '(:include t)))
    (should-not (plist-member (plist-get (pai-openai-build-request
                                          (pai-make-model :id "x" :provider "local"
                                                          :base-url "http://127.0.0.1:8080/v1")
                                          ctx nil)
                                         :body)
                              :usage))))

(ert-deftest pai-providers-discovery-reads-openrouter-pricing ()
  (should (equal (pai-providers--pricing
                  '(:pricing (:prompt "0.000002" :completion "0.00001"
                              :input_cache_read "0.0000002" :input_cache_write "0.0000025")))
                 '(:input 2.0 :output 10.0 :cache-read 0.2 :cache-write 2.5)))
  (should-not (pai-providers--pricing '(:pricing (:prompt "0" :completion "0"))))
  (should-not (pai-providers--pricing '(:id "x"))))

;;;; Header cost

(ert-deftest pai-cost-dollars-round-up-to-the-cent ()
  (should (equal (pai--format-dollars 0.0) "$0.00"))
  (should (equal (pai--format-dollars 0.0003) "$0.01"))
  (should (equal (pai--format-dollars 0.044) "$0.05"))
  (should (equal (pai--format-dollars 0.05) "$0.05"))
  (should (equal (pai--format-dollars 1.231) "$1.24"))
  (should (equal (pai--format-dollars 20.0) "$20.00")))

(defmacro pai-pricing-test--with-buffer (buf &rest body)
  "Run BODY in a fresh faux pai buffer BUF with the fixture catalog."
  (declare (indent 1))
  `(pai-pricing-test--with-catalog
     (let* ((dir (file-name-as-directory (make-temp-file "pai-cost" t)))
            (pai-default-model "faux")
            (,buf (get-buffer-create (generate-new-buffer-name "*pai-cost-test*"))))
       (unwind-protect
           (progn
             (pai-ext-reset)
             (with-current-buffer ,buf
               (setq default-directory dir)
               (pai--setup dir)
               (pai-register-provider-config
                '(:id "local" :api "openai-completions" :base-url "http://172.26.160.1:8080/v1"))
               ,@body))
         (kill-buffer ,buf)
         (delete-directory dir t)))))

(defun pai-pricing-test--answer (provider model usage)
  "Record an assistant message from PROVIDER/MODEL with USAGE, as agent-end does."
  (let ((m (pai-assistant-message :content (list (pai-text "ok")) :provider provider
                                  :model model :usage usage :stop-reason 'stop)))
    (pai-session-append-message pai--session m)
    (pai--update-usage (list m))))

(ert-deftest pai-cost-header-prices-per-message-model ()
  (pai-pricing-test--with-buffer buf
    ;; subscription model with no own price: priced from the catalog
    (pai-pricing-test--answer "anthropic" "claude-opus-5-5"
                              (pai-usage :input 1000 :output 1000 :cache-read 100000))
    ;; 1000*4 + 1000*20 + 100000*0.2 = 44000 per million = $0.044
    (should (< (abs (- pai--cost-total 0.044)) 1e-9))
    (should (string-match-p "\\$0\\.05" (pai--header-line)))
    ;; a reported cost wins
    (pai-pricing-test--answer "openrouter" "anthropic/claude-sonnet-5"
                              (pai-usage :input 10 :output 10 :reported-cost 0.5))
    (should (< (abs (- pai--cost-total 0.544)) 1e-9))
    ;; a local model shows tokens, not $0
    (pai-pricing-test--answer "local" "Qwen3.6-35B-A3B-NVFP4"
                              (pai-usage :input 1500 :cache-read 500 :output 300))
    (should (equal pai--unpriced-tokens '(2000 . 300)))
    (should (string-match-p "\\$0\\.55 \\+ tok ↑2\\.0k ↓300" (pai--header-line)))
    ;; /resume recomputes the same from the file
    (let ((cost pai--cost-total) (tok pai--unpriced-tokens))
      (setq pai--cost-total 0.0 pai--unpriced-tokens (cons 0 0))
      (pai--recompute-cost)
      (should (= pai--cost-total cost))
      (should (equal pai--unpriced-tokens tok)))
    ;; /session shows it too
    (should (string-match-p "Cost: \\$0\\.55 \\+ tok"
                            (plist-get (pai-session-info-command "" (list :buffer buf)) :message)))))

(ert-deftest pai-cost-header-local-only-shows-tokens ()
  (pai-pricing-test--with-buffer buf
    ;; the session's model (faux) is not local: dollars from the start
    (should (equal (pai--cost-text) "$0.00"))
    (pai-pricing-test--answer "local" "Qwen3.6-35B-A3B-NVFP4"
                              (pai-usage :input 120000 :output 4500))
    (should (equal (pai--cost-text) "tok ↑120k ↓4.5k"))
    (should-not (string-match-p "\\$" (pai--header-line)))))

(ert-deftest pai-cost-recomputes-when-prices-arrive ()
  (let* ((pai-directory (make-temp-file "pai-pricing" t))
         (pai-pricing--table (make-hash-table :test 'equal))
         (dir (file-name-as-directory (make-temp-file "pai-cost" t)))
         (pai-default-model "faux")
         (buf (get-buffer-create (generate-new-buffer-name "*pai-cost-test*"))))
    (unwind-protect
        (progn
          (pai-ext-reset)
          (with-current-buffer buf
            (setq default-directory dir)
            (pai--setup dir)
            (pai-pricing-test--answer "anthropic" "claude-opus-5-5" (pai-usage :output 1000000))
            ;; no catalog yet: still dollars, marked as a lower bound
            (should (equal (pai--cost-text) "≥$0.00")))
          ;; the catalog arrives: every pai buffer is repriced
          (let ((file (make-temp-file "catalog" nil ".json" pai-pricing-test--catalog)))
            (pai-pricing--install-download file)
            (delete-file file))
          (with-current-buffer buf
            (should (equal (pai--cost-text) "$20.00"))))
      (kill-buffer buf)
      (delete-directory dir t)
      (delete-directory pai-directory t))))

;;;; /prices

(ert-deftest pai-prices-command-status-and-refresh ()
  (pai-pricing-test--with-buffer buf
    (let ((msg (plist-get (pai-prices-command "" (list :buffer buf)) :message)))
      (should (string-match-p "Price catalog: 2 prices, updated just now" msg))
      (should (string-match-p "refreshed when older than 24h" msg))
      ;; the faux session model has no price
      (should (string-match-p "faux/faux: price unknown" msg))
      (should (string-match-p "Session cost: " msg)))
    (let ((pai--model (pai-make-model :id "claude-opus-5-5" :provider "anthropic")))
      (should (string-match-p "claude-opus-5-5: \\$4\\.0 in / \\$20\\.0 out .*(models\\.dev)"
                              (plist-get (pai-prices-command "" (list :buffer buf)) :message))))
    (let ((pai--model (pai-make-model :id "q" :provider "local")))
      (should (string-match-p "local, counted in tokens"
                              (plist-get (pai-prices-command "" (list :buffer buf)) :message))))
    ;; refresh forces a download
    (let ((forced nil))
      (cl-letf (((symbol-function 'pai-pricing-refresh) (lambda (&optional f) (setq forced f)))
                ((symbol-function 'executable-find) (lambda (&rest _) "/usr/bin/curl")))
        (should (string-match-p "Downloading"
                                (plist-get (pai-prices-command "refresh" (list :buffer buf)) :message)))
        (should forced)))
    (let ((pai-pricing-url nil))
      (should (string-match-p "off" (plist-get (pai-prices-command "refresh" (list :buffer buf))
                                               :message))))
    (should (string-match-p "Usage" (plist-get (pai-prices-command "bogus" (list :buffer buf))
                                               :message)))))

;;;; Local vs. paid providers

(ert-deftest pai-provider-local-detection ()
  (let ((pai--providers (make-hash-table :test 'equal)))
    (dolist (url '("http://localhost:8080/v1" "http://127.0.0.1:1234/v1" "http://[::1]:8080/v1"
                   "http://172.26.160.1:8080/v1" "http://10.0.0.5/v1" "http://192.168.1.20:11434/v1"
                   "http://gpu-box.local:8000/v1" "http://nas.lan/v1"))
      (puthash "p" (list :id "p" :base-url url) pai--providers)
      (should (pai-provider-local-p "p")))
    (dolist (url '("https://openrouter.ai/api/v1" "https://api.anthropic.com/v1"
                   "http://172.32.0.1/v1" "http://8.8.8.8/v1"))
      (puthash "p" (list :id "p" :base-url url) pai--providers)
      (should-not (pai-provider-local-p "p")))
    ;; explicit setting wins either way
    (puthash "p" (list :id "p" :base-url "http://localhost/v1" :local :false) pai--providers)
    (should-not (pai-provider-local-p "p"))
    (puthash "p" (list :id "p" :base-url "https://tunnel.example.com/v1" :local t) pai--providers)
    (should (pai-provider-local-p "p"))
    ;; unknown provider: the model's base URL decides
    (should (pai-provider-local-p "nope" '(:base-url "http://127.0.0.1/v1")))
    (should-not (pai-provider-local-p "nope"))))

(ert-deftest pai-cost-free-models-count-as-dollars ()
  "OpenRouter models listed at $0 (free, routers) show $0.00, not tokens."
  (pai-pricing-test--with-buffer buf
    (pai-register-provider-config
     '(:id "openrouter" :api "openai-completions" :base-url "https://openrouter.ai/api/v1"))
    (pai-register-model (append (pai-make-model :id "vendor/model:free" :provider "openrouter"
                                                :base-url "https://openrouter.ai/api/v1")
                                '(:free t)))
    (pai-pricing-test--answer "openrouter" "vendor/model:free" (pai-usage :input 5000 :output 500))
    (should (equal (pai--cost-text) "$0.00"))
    (should-not pai--cost-incomplete)))

(ert-deftest pai-providers-discovery-prices-and-marks-free-models ()
  "Discovery turns OpenRouter pricing into :cost, and a $0 listing into :free."
  (let ((specs
         (cl-letf (((symbol-function 'pai-providers--get-json)
                    (lambda (&rest _)
                      '(:data ((:id "a/paid" :pricing (:prompt "0.000002" :completion "0.00001"))
                               (:id "b/model:free" :pricing (:prompt "0" :completion "0"))
                               (:id "c/unlisted"))))))
           (pai-providers--list-models
            '(:id "openrouter" :api "openai-completions" :base-url "https://openrouter.ai/api/v1")))))
    (let ((paid (seq-find (lambda (x) (equal (plist-get x :id) "a/paid")) specs))
          (free (seq-find (lambda (x) (equal (plist-get x :id) "b/model:free")) specs))
          (none (seq-find (lambda (x) (equal (plist-get x :id) "c/unlisted")) specs)))
      (should (equal (plist-get paid :cost) '(:input 2.0 :output 10.0 :cache-read 0.0 :cache-write 0.0)))
      (should-not (plist-get paid :free))
      (should (plist-get free :free))
      (should-not (plist-get free :cost))
      (should-not (plist-get none :free)))))

(provide 'pai-pricing-test)
;;; pai-pricing-test.el ends here
