;;; pai-providers-test.el --- Provider persistence and discovery tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'pai-providers)
(require 'pai-provider)

(defmacro pai-providers-test--isolated (&rest body)
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "pai-providers-test-" t)))
          (pai-directory (expand-file-name "state" dir))
          (default-directory dir)
          (pai-settings--global nil) (pai-settings--project nil)
          (pai-settings--project-dir nil)
          (pai--providers (make-hash-table :test 'equal))
          (pai--models (make-hash-table :test 'equal))
          (pai-providers--settings-providers (make-hash-table :test 'equal))
          (pai-providers--settings-models (make-hash-table :test 'equal))
          (pai-providers--settings-env (make-hash-table :test 'equal))
          (pai-providers--discovered (make-hash-table :test 'equal))
          (pai-provider-env-keys nil) (pai-api-keys nil))
     (unwind-protect (progn ,@body) (delete-directory dir t))))

(ert-deftest pai-providers-persistence-and-nondefault-port ()
  (pai-providers-test--isolated
    (pai-settings-set :thinking-level "high" 'global)
    (pai-settings-set :custom-models
                      '((:id "extra" :provider "local" :context-window 4096)) 'global)
    (pai-add-provider "http://127.0.0.1:8080/v1/" "9123" "openai" "fallback" "local")
    (setq pai-settings--global nil)
    (clrhash pai--providers)
    (clrhash pai--models)
    (pai-settings-load)
    (should-not (pai-models-load-custom))
    (should (equal (pai-settings-get :thinking-level) "high"))
    (should (equal (pai-provider-base-url "local") "http://127.0.0.1:9123/v1"))
    (should (equal (plist-get (pai-model "local/fallback") :id) "fallback"))
    (should (= (plist-get (pai-model "local/extra") :context-window) 4096))
    (should (equal (plist-get (pai-openai-build-request
                              (pai-model "local/fallback") (pai-context nil) nil) :url)
                   "http://127.0.0.1:9123/v1/chat/completions"))))

(ert-deftest pai-providers-invalid-config-does-not-register ()
  (pai-providers-test--isolated
    (should-error (pai-register-provider-config '(:id "bad" :api "typo" :base-url "http://localhost/v1")))
    (should-error (pai-register-provider-config '(:id "bad" :api "openai")))
    (should-error (pai-add-provider "http://localhost/v1" "65536" "openai" nil "bad"))
    (should-not (pai-provider "bad"))
    (should-not (file-exists-p (pai-settings-global-file)))))

(ert-deftest pai-providers-settings-reload-restores-extension-entries ()
  (pai-providers-test--isolated
    (let* ((extension (pai-register-provider-config
                       '(:id "shared" :base-url "http://extension/v1" :model "base")))
           (original (pai-model "shared/base")))
      (setq pai-settings--global
            '(:custom-providers ((:id "shared" :base-url "http://settings/v1" :model "base"
                                 :env-key "PAI_TEST_KEY"))
              :custom-models ((:id "extra" :provider "shared"))))
      (should-not (pai-models-load-custom))
      (should-not (eq (pai-model "shared/base") original))
      (should-not (pai-models-load-custom))
      (setq pai-settings--global nil)
      (should-not (pai-models-load-custom))
      (should (eq (pai-provider "shared") extension))
      (should (eq (pai-model "shared/base") original))
      (should-not (pai-model "shared/extra"))
      (should-not (assoc "shared" pai-provider-env-keys)))))

(ert-deftest pai-providers-settings-reload-keeps-later-extension-overrides ()
  (pai-providers-test--isolated
    (setq pai-settings--global
          '(:custom-providers ((:id "local" :base-url "http://localhost/v1" :model "fallback"))))
    (pai-models-load-custom)
    (let* ((replacement (pai-register-provider-config
                         '(:id "local" :base-url "http://extension/v1" :model "fallback")))
           (model (pai-model "local/fallback")))
      (setq pai-settings--global nil)
      (pai-models-load-custom)
      (should (eq (pai-provider "local") replacement))
      (should (eq (pai-model "local/fallback") model)))))

(ert-deftest pai-providers-openai-discovery-replaces-stale-and-preserves-metadata ()
  (pai-providers-test--isolated
    (pai-register-provider-config
     '(:id "local" :base-url "http://localhost:9999/v1" :api "openai"
       :models ((:id "declared" :context-window 2048 :reasoning t))))
    (let ((response '(:data ((:id "old") (:id "declared")))))
      (cl-letf (((symbol-function 'pai-providers--get-json) (lambda (_url _headers) response)))
        (should-not (pai-models-refresh))
        (should (pai-model "local/old"))
        (should (= (plist-get (pai-model "local/declared") :context-window) 2048))
        (setq response '(:data ((:id "new"))))
        (should-not (pai-models-refresh))
        (should-not (pai-model "local/old"))
        (should (pai-model "local/new"))
        (should (pai-model-reasoning-p (pai-model "local/declared")))
        (setq response '(:data nil))
        (should-not (pai-models-refresh))
        (should-not (pai-model "local/new"))
        (should (pai-model "local/declared"))))))

(ert-deftest pai-providers-refresh-continues-after-errors-and-keeps-cache ()
  (pai-providers-test--isolated
    (pai-register-provider-config '(:id "broken" :base-url "http://broken/v1" :model "fallback"))
    (pai-register-provider-config '(:id "healthy" :base-url "http://healthy/v1"))
    (let ((fail nil))
      (cl-letf (((symbol-function 'pai-providers--get-json)
                 (lambda (url _headers)
                   (if (and fail (string-match-p "broken" url))
                       (error "HTTP 503")
                     '(:data ((:id "cached")))))))
        (should-not (pai-models-refresh))
        (setq fail t)
        (let ((errors (pai-models-refresh)))
          (should (= (length errors) 1))
          (should (string-match-p "broken.*503" (car errors))))
        (should (pai-model "broken/cached"))
        (should (pai-model "broken/fallback"))
        (should (pai-model "healthy/cached"))))))

(ert-deftest pai-providers-extension-callback-and-unsupported-fallback ()
  (pai-providers-test--isolated
    (let ((calls 0))
      (pai-register-provider-config
       (list :id "extension" :base-url "http://localhost/v1"
             :list-models (lambda (_provider) (cl-incf calls) '((:id "callback-model")))))
      (pai-register-provider '(:id "opaque" :stream ignore))
      (pai-register-model (pai-make-model :id "manual" :provider "opaque"))
      (cl-letf (((symbol-function 'pai-providers--get-json)
                 (lambda (&rest _) (ert-fail "Callback must bypass HTTP"))))
        (should-not (pai-models-refresh)))
      (should (= calls 1))
      (should (pai-model "extension/callback-model"))
      (should (pai-model "opaque/manual")))))

(ert-deftest pai-providers-anthropic-pagination-and-credentials ()
  (pai-providers-test--isolated
    (pai-register-provider-config '(:id "a" :api "anthropic" :base-url "http://localhost:8001/v1"))
    (let ((pai-api-keys '(("a" . "secret"))) urls)
      (cl-letf (((symbol-function 'pai-providers--get-json)
                 (lambda (url headers)
                   (push url urls)
                   (should (equal (cdr (assoc "x-api-key" headers)) "secret"))
                   (if (string-match-p "after_id=first" url)
                       '(:data ((:id "second")) :has_more :false)
                     '(:data ((:id "first")) :has_more t :last_id "first")))))
        (should-not (pai-models-refresh)))
      (should (= (length urls) 2))
      (should (string-prefix-p "http://localhost:8001/v1/models?" (car urls)))
      (should (pai-model "a/first"))
      (should (pai-model "a/second")))))

(ert-deftest pai-providers-gemini-pagination-filters-nongeneration-models ()
  (pai-providers-test--isolated
    (pai-register-provider-config '(:id "g" :api "gemini" :base-url "http://localhost/v1beta"))
    (cl-letf (((symbol-function 'pai-providers--get-json)
               (lambda (url _headers)
                 (if (string-match-p "pageToken=next" url)
                     '(:models ((:name "models/chat-two" :supportedGenerationMethods ("generateContent"))))
                   '(:models ((:name "models/embedding" :supportedGenerationMethods ("embedContent"))
                              (:name "models/chat" :supportedGenerationMethods ("generateContent")
                               :inputTokenLimit 32000 :outputTokenLimit 4096))
                     :nextPageToken "next")))))
      (should-not (pai-models-refresh)))
    (should-not (pai-model "g/embedding"))
    (should (= (plist-get (pai-model "g/chat") :context-window) 32000))
    (should (equal (plist-get (pai-model "g/chat-two") :id) "chat-two"))))

(ert-deftest pai-providers-pagination-error-keeps-previous-discovery ()
  (pai-providers-test--isolated
    (pai-register-provider-config '(:id "a" :api "anthropic" :base-url "http://localhost/v1" :model "manual"))
    (let ((repeat nil))
      (cl-letf (((symbol-function 'pai-providers--get-json)
                 (lambda (_url _headers)
                   (if repeat '(:data ((:id "new")) :has_more t :last_id "loop")
                     '(:data ((:id "cached")) :has_more :false)))))
        (should-not (pai-models-refresh))
        (setq repeat t)
        (should (pai-models-refresh))
        (should (pai-model "a/cached"))
        (should (pai-model "a/manual"))
        (should-not (pai-model "a/new"))))))

(ert-deftest pai-providers-stream-extension-models-need-no-http-adapter ()
  (pai-providers-test--isolated
    (pai-register-provider
     (list :id "custom" :stream #'ignore
           :list-models (lambda (_provider)
                          '((:id "native" :api custom-protocol :context-window 777)))))
    (should-not (pai-models-refresh))
    (should (eq (pai-model-api (pai-model "custom/native")) 'custom-protocol))
    (should (= (plist-get (pai-model "custom/native") :context-window) 777))))

(ert-deftest pai-providers-openai-discovery-context-and-keyless-local ()
  (pai-providers-test--isolated
    (pai-register-provider-config '(:id "local" :base-url "http://localhost:9000/v1"))
    (cl-letf (((symbol-function 'pai-api-key) (lambda (_provider) nil))
              ((symbol-function 'pai-providers--get-json)
               (lambda (_url headers)
                 (should-not (assoc "Authorization" headers))
                 '(:data ((:id "llama" :context_length 16384)
                          (:id "qwen" :max_model_len 32768))))))
      (should-not (pai-models-refresh)))
    (should (= (plist-get (pai-model "local/llama") :context-window) 16384))
    (should (= (plist-get (pai-model "local/qwen") :context-window) 32768))))

(ert-deftest pai-providers-anthropic-discovery-reads-max-input-tokens ()
  ;; Anthropic reports limits as `max_input_tokens'/`max_tokens'.  Sibling
  ;; models disagree (opus-4-5 is 200k while opus-4-8 is 1M), so the declared
  ;; value must be used verbatim rather than guessed from the model ID.
  (pai-providers-test--isolated
    (pai-register-provider-config '(:id "a" :api "anthropic" :base-url "http://localhost/v1"))
    (cl-letf (((symbol-function 'pai-providers--get-json)
               (lambda (_url _headers)
                 '(:data ((:id "claude-opus-4-8" :max_input_tokens 1000000 :max_tokens 128000)
                          (:id "claude-opus-4-5-20251101" :max_input_tokens 200000 :max_tokens 64000)
                          (:id "claude-sonnet-4-5-20250929" :max_input_tokens 1000000 :max_tokens 64000))
                   :has_more :false))))
      (should-not (pai-models-refresh)))
    (should (= (plist-get (pai-model "a/claude-opus-4-8") :context-window) 1000000))
    (should (= (plist-get (pai-model "a/claude-opus-4-8") :max-tokens) 128000))
    (should (= (plist-get (pai-model "a/claude-opus-4-5-20251101") :context-window) 200000))
    (should (= (plist-get (pai-model "a/claude-opus-4-5-20251101") :max-tokens) 64000))
    (should (= (plist-get (pai-model "a/claude-sonnet-4-5-20250929") :context-window) 1000000))))

(ert-deftest pai-providers-discovery-overrides-fallback-model-placeholders ()
  ;; A provider's bare-ID fallback models are registered with `pai-make-model'
  ;; placeholder defaults.  When discovery later reports the real numbers they
  ;; must win, while metadata the API never returns (:cost) is preserved.
  (pai-providers-test--isolated
    (pai-register-provider-config
     '(:id "a" :api "anthropic" :base-url "http://localhost/v1"
       :models ("claude-sonnet-4-5-20250929")))
    ;; Before discovery it carries the generic default.
    (should (= (plist-get (pai-model "a/claude-sonnet-4-5-20250929") :context-window) 128000))
    (pai-register-model
     (append '(:cost (:input 3.0 :output 15.0))
             (pai-model "a/claude-sonnet-4-5-20250929")))
    (cl-letf (((symbol-function 'pai-providers--get-json)
               (lambda (_url _headers)
                 '(:data ((:id "claude-sonnet-4-5-20250929"
                           :max_input_tokens 1000000 :max_tokens 64000))
                   :has_more :false))))
      (should-not (pai-models-refresh)))
    (let ((model (pai-model "a/claude-sonnet-4-5-20250929")))
      ;; API truth replaces the placeholder rather than being shadowed by it.
      (should (= (plist-get model :context-window) 1000000))
      (should (= (plist-get model :max-tokens) 64000))
      ;; Hand-written metadata discovery never returns survives.
      (should (= (plist-get (plist-get model :cost) :input) 3.0)))))

(ert-deftest pai-providers-discovery-floor-is-learned-from-the-api ()
  ;; A model that ships without declared limits (or with an unusable
  ;; null/zero) inherits the smallest window the SAME response declared, so the
  ;; fallback tracks the provider instead of a hardcoded constant.
  (pai-providers-test--isolated
    (pai-register-provider-config '(:id "a" :api "anthropic" :base-url "http://localhost/v1"))
    (cl-letf (((symbol-function 'pai-providers--get-json)
               (lambda (_url _headers)
                 '(:data ((:id "claude-big" :max_input_tokens 1000000)
                          (:id "claude-small" :max_input_tokens 200000)
                          (:id "claude-unreleased-9")
                          (:id "claude-null-limits" :max_input_tokens :null :max_tokens 0))
                   :has_more :false))))
      (should-not (pai-models-refresh)))
    (should (= (plist-get (pai-model "a/claude-big") :context-window) 1000000))
    ;; Undeclared models take the smallest declared window (200k), never the
    ;; largest, and never the generic 128k default.
    (should (= (plist-get (pai-model "a/claude-unreleased-9") :context-window) 200000))
    (should (= (plist-get (pai-model "a/claude-null-limits") :context-window) 200000))
    ;; An unusable max_tokens leaves the model default rather than becoming 0.
    (should (> (plist-get (pai-model "a/claude-null-limits") :max-tokens) 0))))

(ert-deftest pai-providers-discovery-floor-absent-when-nothing-declared ()
  ;; With no declared windows anywhere, models keep the generic default rather
  ;; than inventing a number.
  (pai-providers-test--isolated
    (pai-register-provider-config '(:id "a" :api "anthropic" :base-url "http://localhost/v1"))
    (cl-letf (((symbol-function 'pai-providers--get-json)
               (lambda (_url _headers) '(:data ((:id "mystery")) :has_more :false))))
      (should-not (pai-models-refresh)))
    (should (= (plist-get (pai-model "a/mystery") :context-window)
               (plist-get (pai-make-model :id "probe") :context-window)))))

(ert-deftest pai-providers-environment-key-alternatives ()
  (pai-providers-test--isolated
    (let ((process-environment (copy-sequence process-environment)))
      (setenv "PAI_PROVIDER_TEST_PRIMARY" nil)
      (setenv "PAI_PROVIDER_TEST_SECONDARY" "resolved-secret")
      (pai-register-provider-config
       '(:id "local" :base-url "http://localhost/v1"
         :env-key ("PAI_PROVIDER_TEST_PRIMARY" "PAI_PROVIDER_TEST_SECONDARY")))
      (cl-letf (((symbol-function 'pai-auth-api-key) (lambda (_provider) nil)))
        (should (equal (pai-api-key "local") "resolved-secret"))))))

(ert-deftest pai-providers-discovery-rejects-http-and-invalid-json ()
  (pai-providers-test--isolated
    (cl-letf (((symbol-function 'call-process) (lambda (&rest _) 22)))
      (should-error (pai-providers--get-json "http://localhost/models" nil)))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _) (insert "not-json") 0)))
      (should-error (pai-providers--get-json "http://localhost/models" nil)))))

(ert-deftest pai-providers-stream-missing-key-errors ()
  ;; A provider that declares an env-key but resolves no key must fail with an
  ;; actionable error instead of sending an empty bearer token (which the API
  ;; rejects with a cryptic 401).
  (pai-providers-test--isolated
    (pai-register-provider-config
     '(:id "needsauth" :api openai-completions
       :base-url "https://example.test/v1" :env-key "PAI_TEST_MISSING_KEY"))
    (pai-register-model (pai-make-model :id "m" :provider "needsauth"
                                        :api 'openai-completions
                                        :base-url "https://example.test/v1"))
    (let ((process-environment nil) events)
      ;; no network handle is returned; the guard short-circuits
      (should (null (pai-provider-stream (pai-model "needsauth/m")
                                         (pai-context nil nil) nil
                                         (lambda (ev) (push ev events)))))
      (let* ((err (seq-find (lambda (ev) (eq (plist-get ev :type) 'error)) events))
             (msg (plist-get (plist-get err :message) :error-message)))
        (should err)
        (should (string-match-p "No API key" msg))
        (should (string-match-p "PAI_TEST_MISSING_KEY" msg))))))

;;;; On-demand discovery

(ert-deftest pai-model-ensure-discovers-one-provider ()
  "An unknown PROVIDER/MODEL id discovers that provider only, once a minute."
  (pai-providers-test--isolated
    (let ((local 0) (other 0))
      (pai-register-provider-config
       (list :id "local" :base-url "http://localhost/v1"
             :list-models (lambda (_p) (cl-incf local) '((:id "qwen")))))
      (pai-register-provider-config
       (list :id "other" :base-url "http://remote/v1"
             :list-models (lambda (_p) (cl-incf other) '((:id "big")))))
      (should-not (pai-model "local/qwen"))
      (should (equal (pai-model-key (pai-model-ensure "local/qwen")) "local/qwen"))
      (should (= local 1))
      (should (= other 0))
      ;; registered now: no further discovery
      (pai-model-ensure "local/qwen")
      (should (= local 1))
      ;; an unknown model does not rediscover within a minute
      (should-not (pai-model-ensure "local/missing"))
      (should (= local 1))
      ;; unknown provider, bare ids and nil are just lookups
      (should-not (pai-model-ensure "nope/x"))
      (should-not (pai-model-ensure nil))
      ;; discovery errors are reported, not raised
      (pai-register-provider-config
       (list :id "down" :base-url "http://down/v1"
             :list-models (lambda (_p) (error "connection refused"))))
      (should-not (pai-model-ensure "down/m")))))

(ert-deftest pai-scoped-model-discovers-on-demand ()
  (pai-providers-test--isolated
    (pai-register-provider-config
     (list :id "local" :base-url "http://localhost/v1"
           :list-models (lambda (_p) '((:id "qwen")))))
    (cl-letf (((symbol-function 'pai-settings-get)
               (lambda (k &optional _d) (when (eq k :scoped-models) '(:compact "local/qwen")))))
      (should (equal (pai-model-key (pai-scoped-model :compact 'fallback)) "local/qwen")))))

(provide 'pai-providers-test)
;;; pai-providers-test.el ends here
