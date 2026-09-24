;;; pai-providers.el --- Persistent providers and model discovery -*- lexical-binding: t; -*-

;;; Commentary:
;; Provider URLs are full API base paths.  Settings declare providers and optional
;; fallback models; discovery augments them without inventing a hosted catalog.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-parse)
(require 'url-util)
(require 'pai-settings)
(require 'pai-provider)
(require 'pai-provider-openai)
(require 'pai-provider-anthropic)
(require 'pai-provider-gemini)
(require 'pai-commands)

(defvar pai-providers--settings-providers (make-hash-table :test 'equal))
(defvar pai-providers--settings-models (make-hash-table :test 'equal))
(defvar pai-providers--settings-env (make-hash-table :test 'equal))
(defvar pai-providers--discovered (make-hash-table :test 'equal)
  "Model key to (discovered model . previous declaration).")

(defun pai--api-symbol (api)
  "Normalize API to a supported adapter symbol, or signal an error.
An omitted API means OpenAI-compatible; unknown API names are never guessed."
  (pcase (if (symbolp api) (symbol-name api) api)
    ((or "nil" "openai" "openai-completions") 'openai-completions)
    ((or "anthropic" "anthropic-messages") 'anthropic-messages)
    ((or "google" "gemini" "google-generative-ai") 'google-generative-ai)
    (_ (error "Unsupported provider API: %S" api))))

(defun pai-providers--url (url &optional port)
  "Validate full API base URL and optionally replace its PORT."
  (unless (and (stringp url) (string-match-p "\\`https?://" url))
    (error "Provider URL must start with http:// or https://"))
  (let ((parsed (url-generic-parse-url url)))
    (unless (and (url-host parsed) (not (string-empty-p (url-host parsed)))
                 (not (url-user parsed)) (not (url-password parsed))
                 (not (url-target parsed))
                 (not (string-match-p "[?[:space:]]" url)))
      (error "Provider URL must have a host and no credentials, query or fragment"))
    (when (and port (not (equal port "")))
      (let ((number (if (integerp port) port
                      (and (stringp port) (string-match-p "\\`[0-9]+\\'" port)
                           (string-to-number port)))))
        (unless (and number (<= 1 number 65535)) (error "Invalid provider port"))
        (setf (url-portspec parsed) number)))
    (string-trim-right (url-recreate-url parsed) "/+")))

(defun pai-provider-base-url (id)
  "Return provider ID's configured full API base URL, or nil."
  (plist-get (pai-provider id) :base-url))

(defun pai-providers--model (spec provider &optional extension)
  "Normalize model SPEC using PROVIDER metadata, preserving declared fields.
EXTENSION allows callback-defined APIs and models without HTTP base URLs."
  (when (stringp spec) (setq spec (list :id spec)))
  (let* ((id (plist-get spec :id))
         (api (if extension (or (plist-get spec :api) (plist-get provider :api))
                (pai--api-symbol (or (plist-get spec :api) (plist-get provider :api)))))
         (base (or (plist-get spec :base-url) (plist-get provider :base-url))))
    (unless (and (stringp id) (not (string-empty-p id)))
      (error "Model requires a nonempty :id"))
    (unless (or extension base) (error "Model %s requires a configured :base-url" id))
    (append (list :id id :provider (plist-get provider :id) :api api
                  :base-url (and base (pai-providers--url base)))
            spec
            (pai-make-model :id id :api api :provider (plist-get provider :id)
                            :base-url base))))

(defun pai-register-provider-config (config)
  "Register CONFIG and its explicit fallback models; return the provider plist.
CONFIG has :id, :base-url (full API base path), :api, optional :model,
:models (IDs or model plists), :env-key and :list-models.  A :list-models
callback receives the provider plist and returns model plists or signals an
error.  This function does not write settings or perform network requests."
  (let* ((id (plist-get config :id))
         (api (pai--api-symbol (plist-get config :api)))
         (base (pai-providers--url (plist-get config :base-url)))
         (env-key (plist-get config :env-key))
         (provider
          (append (list :id id :api api :base-url base
                        :build-request (pcase api
                                         ('anthropic-messages #'pai-anthropic-build-request)
                                         ('google-generative-ai #'pai-gemini-build-request)
                                         (_ #'pai-openai-build-request))
                        :make-parser (pcase api
                                       ('anthropic-messages #'pai-anthropic-make-parser)
                                       ('google-generative-ai #'pai-gemini-make-parser)
                                       (_ #'pai-openai-make-parser)))
                  config)))
    (unless (and (stringp id) (not (string-empty-p id))
                 (not (string-match-p "[/[:space:]]" id)))
      (error "Provider :id must be nonempty and contain no slash or whitespace"))
    (when (and env-key
               (not (and (or (stringp env-key) (listp env-key))
                         (cl-every (lambda (name)
                                     (and (stringp name) (not (string-empty-p name))))
                                   (if (stringp env-key) (list env-key) env-key)))))
      (error "Provider :env-key must be a name or list of names"))
    ;; Validate every model before mutating the registries.
    (let ((models (mapcar (lambda (spec) (pai-providers--model spec provider))
                          (append (when (plist-get config :model)
                                    (list (plist-get config :model)))
                                  (plist-get config :models)))))
      (pai-register-provider provider)
      (when env-key
        (setf (alist-get id pai-provider-env-keys nil nil #'equal)
              (if (stringp env-key) (list env-key) env-key)))
      (dolist (model models) (pai-register-model model)))
    provider))

(defun pai-register-openai-compatible (id &optional base-url)
  "Register OpenAI-compatible ID at BASE-URL or its existing configured URL.
No service-specific URL is inferred."
  (pai-register-provider-config
   (list :id id :api 'openai-completions
         :base-url (or base-url (pai-provider-base-url id)))))

(defun pai-providers--restore (owned registry &optional provider-id)
  "Restore OWNED entries in REGISTRY, optionally only for PROVIDER-ID.
Only replace an entry if it still is the object this module installed."
  (let (keys)
    (maphash
     (lambda (key entry)
       (when (or (null provider-id)
                 (equal provider-id (plist-get (car entry) :provider)))
         (when (eq (gethash key registry) (car entry))
           (if (cdr entry) (puthash key (cdr entry) registry) (remhash key registry)))
         (push key keys)))
     owned)
    (dolist (key keys) (remhash key owned))))

(defun pai-models-load-custom ()
  "Reload :custom-providers and :custom-models settings; return error strings.
Remove stale settings-owned entries, restoring any shadowed extension entries.
This does not discover models; call `pai-models-refresh' separately."
  (maphash (lambda (id _entry)
             (pai-providers--restore pai-providers--discovered pai--models id))
           pai-providers--settings-providers)
  (maphash (lambda (_key entry)
             (pai-providers--restore pai-providers--discovered pai--models
                                     (plist-get (car entry) :provider)))
           pai-providers--settings-models)
  (pai-providers--restore pai-providers--settings-models pai--models)
  (pai-providers--restore pai-providers--settings-providers pai--providers)
  (maphash (lambda (id entry)
             (when (eq (cdr (assoc id pai-provider-env-keys)) (car entry))
               (setq pai-provider-env-keys
                     (cl-remove id pai-provider-env-keys :key #'car :test #'equal))
               (when (cdr entry) (push (cons id (cdr entry)) pai-provider-env-keys))))
           pai-providers--settings-env)
  (clrhash pai-providers--settings-env)
  (let (errors)
    (dolist (config (pai-settings-get :custom-providers))
      (condition-case err
          (let* ((id (plist-get config :id))
                 (previous (if (gethash id pai-providers--settings-providers)
                               (error "Duplicate provider ID: %s" id)
                             (pai-provider id)))
                 (env (cdr (assoc id pai-provider-env-keys)))
                 (old-models (copy-hash-table pai--models))
                 (provider (pai-register-provider-config config)))
            (puthash id (cons provider previous) pai-providers--settings-providers)
            (when (plist-get config :env-key)
              (puthash id (cons (cdr (assoc id pai-provider-env-keys)) env)
                       pai-providers--settings-env))
            (maphash (lambda (key model)
                       (unless (eq model (gethash key old-models))
                         (puthash key (cons model (gethash key old-models))
                                  pai-providers--settings-models)))
                     pai--models))
        (error (push (format "Provider %s: %s" (plist-get config :id)
                             (error-message-string err)) errors))))
    (dolist (spec (pai-settings-get :custom-models))
      (condition-case err
          (let* ((id (plist-get spec :provider))
                 (provider (or (pai-provider id)
                               (error "Unknown provider: %s" id)))
                 (model (pai-providers--model spec provider))
                 (key (pai-model-key model))
                 (owned (gethash key pai-providers--settings-models))
                 (previous (if owned (cdr owned) (gethash key pai--models))))
            (pai-register-model model)
            (puthash key (cons model previous) pai-providers--settings-models))
        (error (push (format "Model %s: %s" (plist-get spec :id)
                             (error-message-string err)) errors))))
    (nreverse errors)))

(defun pai-providers--get-json (url headers)
  "GET URL with HEADERS using bounded curl; decode JSON or signal an error."
  (let ((stderr (make-temp-file "pai-model-discovery-")))
    (unwind-protect
        (with-temp-buffer
          (let* ((args (append '("--silent" "--show-error" "--fail"
                                 "--connect-timeout" "5" "--max-time" "15"
                                 "--max-filesize" "8388608")
                               (cl-mapcan (lambda (header)
                                            (list "--header" (concat (car header) ": " (cdr header))))
                                          headers)
                               (list "--url" url)))
                 (status (apply #'call-process pai-curl-program nil
                                (list (current-buffer) stderr) nil args)))
            (unless (and (integerp status) (zerop status))
              (error "Model discovery HTTP request failed (%s): %s" status
                     (with-temp-buffer
                       (insert-file-contents stderr)
                       (string-trim (buffer-string)))))
            (pai-json-decode (buffer-string))))
      (delete-file stderr))))

(defun pai-providers--token-limit (item keys)
  "Return the first positive integer token limit among KEYS in ITEM, or nil.
Discovery responses vary by vendor and may carry nulls, strings or zeros for
models that do not declare a limit, so only usable positive integers count."
  (cl-loop for key in keys
           for value = (plist-get item key)
           when (and (integerp value) (> value 0)) return value))

(defun pai-providers--merge-previous (model spec previous)
  "Return MODEL with PREVIOUS metadata merged in, except where SPEC declares it.
Discovery answers with the provider's own numbers, so a key the API declared in
SPEC always wins over the previously registered model.  Everything else
\(hand-written :cost, aliases and other metadata discovery never returns) is
carried over from PREVIOUS.  Without this rule a fallback model registered from
a bare ID pins its placeholder `pai-make-model' defaults, e.g. reporting a 128k
window for a model the API says is 1M."
  (let ((declared (if (stringp spec) '(:id) spec))
        (result (copy-sequence model))
        seen)
    ;; Model plists are built by appending defaults, so a key can appear more
    ;; than once; only the first occurrence is live under `plist-get' and a
    ;; later duplicate must not clobber it.
    (cl-loop for (key _value) on previous by #'cddr
             unless (or (memq key seen) (plist-member declared key))
             do (progn (push key seen)
                       (setq result (plist-put result key (plist-get previous key)))))
    result))

(defun pai-providers--apply-context-window-floor (models)
  "Fill in a context window for MODELS that did not declare one.
Use the smallest window the provider declared for its other models in the same
discovery response, so the fallback is learned from the API rather than
hardcoded.  The smallest is chosen because under-estimating only compacts
sooner, whereas over-estimating lets the agent overflow the real window and be
rejected by the provider.  Models keep the generic `pai-make-model' default
when the provider declared no windows at all."
  (let ((floor (cl-loop for model in models
                        for window = (plist-get model :context-window)
                        when (and (integerp window) (> window 0)) minimize window)))
    (if (and (integerp floor) (> floor 0))
        (mapcar (lambda (model)
                  (if (plist-get model :context-window)
                      model
                    (append model (list :context-window floor))))
                models)
      models)))

(defun pai-providers--private-host-p (host)
  "Return non-nil when HOST is this machine or a private network address."
  (and (stringp host)
       (let ((h (downcase (string-trim host "\\[" "\\]"))))
         (or (member h '("localhost" "::1" "0.0.0.0"))
             (string-suffix-p ".localhost" h)
             (string-suffix-p ".local" h)
             (string-suffix-p ".lan" h)
             (string-match-p "\\`127\\." h)
             (string-match-p "\\`10\\." h)
             (string-match-p "\\`192\\.168\\." h)
             (string-match-p "\\`169\\.254\\." h)
             (string-match-p "\\`172\\.\\(1[6-9]\\|2[0-9]\\|3[01]\\)\\." h)
             (string-match-p "\\`f[cd][0-9a-f][0-9a-f]:" h)))))

(defun pai-provider-local-p (provider-id &optional model)
  "Return non-nil when PROVIDER-ID serves models on this machine or network.
Local usage costs nothing per token, so it is reported in tokens, not
dollars.  A provider's `:local' setting (t or false) decides when present;
otherwise its base URL -- or MODEL's -- is local when its host is
loopback, a private network address, or a .local/.lan name."
  (let* ((provider (and (stringp provider-id) (gethash provider-id pai--providers)))
         (explicit (and provider (plist-member provider :local))))
    (if explicit
        (pai-truthy (plist-get provider :local))
      (let ((base (or (and provider (plist-get provider :base-url))
                      (and model (plist-get model :base-url)))))
        (and (stringp base)
             (pai-providers--private-host-p
              (url-host (url-generic-parse-url base))))))))

(defun pai-providers--pricing (item)
  "Return per-million rates from discovered ITEM's `pricing', or nil.
OpenRouter (and compatible routers) list prices per token as strings:
prompt, completion, input_cache_read, input_cache_write."
  (let ((p (plist-get item :pricing)))
    (when (and p (listp p))
      (let* ((rate (lambda (k)
                     (let* ((v (plist-get p k))
                            (per-token (cond ((numberp v) v)
                                             ((stringp v) (string-to-number v))
                                             (t 0))))
                       ;; per million, without float noise (2e-06 * 1e6
                       ;; would be 1.9999999999999998)
                       (/ (fround (* per-token 1e12)) 1e6))))
             (rates (list :input (funcall rate :prompt)
                          :output (funcall rate :completion)
                          :cache-read (funcall rate :input_cache_read)
                          :cache-write (funcall rate :input_cache_write))))
        (and (pai-model-rates-nonzero-p rates) rates)))))

(defun pai-providers--list-models (provider)
  "Discover PROVIDER's models via its supported HTTP API.
Pagination is bounded to 100 pages and repeated cursors are rejected."
  (let* ((api (pai--api-symbol (plist-get provider :api)))
         (base (pai-providers--url (plist-get provider :base-url)))
         (key (pai-api-key (plist-get provider :id)))
         (anthropic-oauth (and (eq api 'anthropic-messages)
                               (stringp key) (string-search "sk-ant-oat" key)))
         (headers (append
                   (when key
                     (list (cond
                            (anthropic-oauth (cons "Authorization" (concat "Bearer " key)))
                            ((eq api 'anthropic-messages) (cons "x-api-key" key))
                            ((eq api 'google-generative-ai) (cons "x-goog-api-key" key))
                            (t (cons "Authorization" (concat "Bearer " key))))))
                   (when (eq api 'anthropic-messages)
                     (list (cons "anthropic-version" pai-anthropic-version)))
                   (when anthropic-oauth
                     (list (cons "anthropic-beta" pai-anthropic-oauth-beta)))))
         (page 0) cursor seen models done)
    (while (not done)
      (when (>= page 100) (error "Model discovery exceeded 100 pages"))
      (cl-incf page)
      (let* ((url (concat base "/models"
                          (pcase api
                            ('anthropic-messages
                             (concat "?limit=1000" (when cursor (concat "&after_id=" (url-hexify-string cursor)))))
                            ('google-generative-ai
                             (concat "?pageSize=1000" (when cursor (concat "&pageToken=" (url-hexify-string cursor)))))
                            (_ ""))))
             (response (pai-providers--get-json url headers))
             (field (if (eq api 'google-generative-ai) :models :data))
             (items (plist-get response field)))
        (unless (and (plist-member response field) (listp items))
          (error "Malformed model discovery response: missing model array"))
        (dolist (item items)
          (when (or (not (eq api 'google-generative-ai))
                    (member "generateContent" (plist-get item :supportedGenerationMethods)))
            (let ((id (if (eq api 'google-generative-ai)
                          (string-remove-prefix "models/" (or (plist-get item :name) ""))
                        (plist-get item :id))))
              (unless (and (stringp id) (not (string-empty-p id)))
                (error "Malformed discovered model ID"))
              (push (append (list :id id)
                            (when-let* ((name (or (plist-get item :displayName)
                                                (plist-get item :display_name))))
                              (list :name name))
                            ;; Context window, in each API's own spelling:
                            ;; Anthropic `max_input_tokens', Gemini
                            ;; `inputTokenLimit', OpenAI-compatible
                            ;; `context_length', vLLM `max_model_len'.
                            ;; Left absent when undeclared so
                            ;; `pai-providers--apply-context-window-floor' can
                            ;; fill it from the provider's own smallest window.
                            (when-let* ((limit (pai-providers--token-limit
                                                item '(:max_input_tokens :inputTokenLimit
                                                       :context_length :max_model_len))))
                              (list :context-window limit))
                            (when-let* ((limit (pai-providers--token-limit
                                                item '(:max_output_tokens :outputTokenLimit
                                                       :max_tokens))))
                              (list :max-tokens limit))
                            ;; OpenRouter-style per-token prices; a listed
                            ;; price of zero is a known free model
                            (let ((cost (pai-providers--pricing item)))
                              (cond (cost (list :cost cost))
                                    ((plist-get item :pricing) (list :free t)))))
                    models))))
        (setq cursor
              (pcase api
                ('anthropic-messages
                 (when (eq (plist-get response :has_more) t)
                   (or (plist-get response :last_id)
                       (error "Missing Anthropic pagination cursor"))))
                ('google-generative-ai (plist-get response :nextPageToken))))
        (when (or (eq cursor :null) (equal cursor "")) (setq cursor nil))
        (when cursor
          (unless (stringp cursor) (error "Invalid model pagination cursor"))
          (when (member cursor seen) (error "Repeated model pagination cursor"))
          (push cursor seen))
        (setq done (null cursor))))
    (pai-providers--apply-context-window-floor (nreverse models))))

(defun pai-providers-discover (id provider)
  "Discover models for PROVIDER (registered as ID); signal an error on failure.
Use its :list-models callback, otherwise its :api/:base-url metadata.  All
network calls and validation finish before the cached set is replaced; the
provider's explicit models and fallback metadata are retained.  Return non-nil
when the provider supports discovery."
  (let ((callback (plist-get provider :list-models)))
    (when (or callback (and (plist-get provider :api) (plist-get provider :base-url)))
      (let* ((specs (if callback (funcall callback provider)
                      (pai-providers--list-models provider)))
             (built (mapcar (lambda (spec)
                              (cons (pai-providers--model spec provider callback) spec))
                            specs)))
        (pai-providers--restore pai-providers--discovered pai--models id)
        (pcase-dolist (`(,model . ,spec) built)
          (let* ((key (pai-model-key model))
                 (owned (gethash key pai-providers--discovered))
                 (previous (if owned (cdr owned) (gethash key pai--models)))
                 (merged (if previous
                             (pai-providers--merge-previous model spec previous)
                           model)))
            (pai-register-model merged)
            (puthash key (cons merged previous) pai-providers--discovered))))
      t)))

(defun pai-models-refresh ()
  "Discover models for registered providers; return a list of error strings.
Use :list-models callbacks first, otherwise supported :api/:base-url metadata.
Failures preserve cached and explicit models.  Successful discovery replaces
that provider's discovered set, retaining explicitly registered metadata and
fallback models.  Providers without discovery support are left unchanged."
  (let (errors)
    (maphash
     (lambda (id provider)
       (condition-case err
           (pai-providers-discover id provider)
         (error (push (format "%s: %s" id (error-message-string err)) errors))))
     pai--providers)
    (nreverse errors)))

(defvar-local pai-model-ensure--tried nil
  "Alist of (PROVIDER-ID . TIME) of on-demand discoveries in this session.
Model registries are per session (buffer-local), so this guard is too.")

(defun pai-model-ensure (id)
  "Return the model for ID, discovering its provider's models when needed.
When ID is \"PROVIDER/MODEL\" and not registered yet (discovery has not run
in this session), run discovery for that one provider -- not for all of them
-- and look again.  A provider is re-discovered on demand at most once a
minute.  Return nil when the model still cannot be found."
  (or (and id (pai-model id))
      (when (and (stringp id) (string-match "\\`\\([^/]+\\)/." id))
        (let* ((pid (match-string 1 id))
               (provider (gethash pid pai--providers))
               (last (alist-get pid pai-model-ensure--tried nil nil #'equal)))
          (when (and provider (or (null last) (> (- (float-time) last) 60)))
            (setf (alist-get pid pai-model-ensure--tried nil nil #'equal) (float-time))
            (condition-case err
                (pai-providers-discover pid provider)
              (error (message "pai: discovering %s models failed: %s"
                              pid (error-message-string err))))
            (pai-model id))))))

(defun pai-add-provider (url &optional port api model id key)
  "Add a provider at full API base URL, optionally overriding PORT.
API selects an adapter; MODEL is an optional fallback ID.  ID names the
provider.  KEY, when non-empty, is stored as the provider's API key so it
persists across sessions (no separate `/login' needed).  Persist through global
:custom-providers, then reload settings.  Return the registered provider.
Interactively prompt for every field."
  (interactive
   (let* ((url (read-string "Full API base URL (RET = http://localhost:8080/v1): "
                            nil nil "http://localhost:8080/v1"))
          (port (read-string "Port override (blank keeps URL port): "))
          (api (completing-read "API: " '("openai" "anthropic" "gemini") nil t nil nil "openai"))
          (model (read-string "Fallback model ID (blank uses discovery): "))
          (id (read-string "Provider ID (RET = local): " nil nil "local"))
          (key (read-passwd (format "API key for %s (blank to skip): " id))))
     (list url port api model id key)))
  (let* ((base (pai-providers--url url port))
         (id (or id "local"))
         (config (append (list :id id :base-url base :api (symbol-name (pai--api-symbol api)))
                         (when (and model (not (string-empty-p model))) (list :model model)))))
    ;; Reload global state before saving so standalone use never discards other settings.
    (pai-settings-load pai-settings--project-dir)
    ;; Validate without changing the live registries or credential metadata.
    (let ((pai--providers (make-hash-table :test 'equal))
          (pai--models (make-hash-table :test 'equal))
          (pai-provider-env-keys nil))
      (pai-register-provider-config config))
    (pai-settings-set :custom-providers
                      (append (cl-remove id (plist-get pai-settings--global :custom-providers)
                                         :key (lambda (p) (plist-get p :id)) :test #'equal)
                              (list config))
                      'global)
    (when (and key (stringp key) (not (string-empty-p (string-trim key)))
               (fboundp 'pai-auth-set))
      (pai-auth-set id (list :type "api_key" :key (string-trim key))))
    (let ((errors (pai-models-load-custom)))
      (when errors (message "%s" (string-join errors "\n"))))
    (pai-provider id)))

(defun pai-provider-command (args _ctx)
  "Handle /provider ARGS: add interactively or list configured providers."
  (pcase (string-trim args)
    ("add"
     (let* ((provider (call-interactively #'pai-add-provider))
            (errors (pai-models-refresh)))
       (list :message (concat (format "Saved provider %s globally." (plist-get provider :id))
                              (when errors (concat "\n" (string-join errors "\n")))))))
    ((or "" "list")
     (list :message
           (if (zerop (hash-table-count pai--providers))
               "No providers configured. Use /provider add."
             (concat "Providers:\n"
                     (string-join
                      (sort (mapcar (lambda (provider)
                                      (format "%s  %s  %s" (plist-get provider :id)
                                              (or (plist-get provider :api) "extension")
                                              (or (plist-get provider :base-url) "")))
                                    (hash-table-values pai--providers)) #'string-lessp)
                      "\n")))))
    (_ (list :message "Usage: /provider add | list"))))

(pai-register-command "provider"
                      :description "Add or list providers"
                      :handler #'pai-provider-command
                      :arg-completions (lambda (_prefix) '("add" "list")))

(provide 'pai-providers)
;;; pai-providers.el ends here
