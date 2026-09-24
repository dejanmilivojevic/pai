;;; pai-auth.el --- Credential store and config-value resolution for pai -*- lexical-binding: t; -*-

;;; Commentary:

;; Persistent credential storage plus config-value resolution, a port of pi's
;; auth-storage + resolve-config-value + OAuth framework.
;;
;; Credentials live in `~/.pai/auth.json' (chmod 600): a JSON object mapping a
;; provider id to a credential plist, e.g. (:type "api_key" :key "sk-...") or
;; (:type "oauth" :access A :refresh R :expires MS).  The store is decoded into
;; a keyword-keyed plist (provider id -> credential plist) and cached in
;; `pai-auth--store'.
;;
;; `pai-resolve-config-value' mirrors pi's semantics for config strings: a
;; leading `!' runs the remainder as a shell command (memoized), otherwise
;; `${VAR}'/`$VAR' interpolate environment variables, with `$$' -> `$' and
;; `$!' -> `!'.
;;
;; The `/login' and `/logout' slash commands manage stored credentials.  The
;; OAuth flows for Anthropic (PKCE loopback) and GitHub Copilot (device flow)
;; are best-effort and run only on demand.

;;; Code:

(require 'subr-x)
(require 'url)
(require 'url-util)
(require 'pai-core)
(require 'pai-config)
(require 'pai-commands)

;;;; Config-value resolution

(defvar pai-resolve-config-value--cache (make-hash-table :test 'equal)
  "Memo cache mapping a `!command' config string to its resolved output.")

(defun pai-resolve-config-value--interpolate (str)
  "Interpolate environment variables in STR.
`${VAR}' and `$VAR' expand to the variable's value (empty string when
unset); `$$' becomes a literal `$' and `$!' a literal `!'."
  (replace-regexp-in-string
   "\\$\\$\\|\\$!\\|\\${[A-Za-z_][A-Za-z0-9_]*}\\|\\$[A-Za-z_][A-Za-z0-9_]*"
   (lambda (m)
     (cond
      ((string= m "$$") "$")
      ((string= m "$!") "!")
      ((string-prefix-p "${" m) (or (getenv (substring m 2 -1)) ""))
      (t (or (getenv (substring m 1)) ""))))
   str t t))

(defun pai-resolve-config-value (str)
  "Resolve config value STR using pi's semantics.
A leading `!' runs the remainder as a shell command via `sh -c' and
returns its trimmed stdout (memoized per-string for this process).
Otherwise environment variables in STR are interpolated.  Never signals;
on shell failure the original string is returned."
  (cond
   ((not (stringp str)) str)
   ((string-prefix-p "!" str)
    (let ((cached (gethash str pai-resolve-config-value--cache 'pai--miss)))
      (if (not (eq cached 'pai--miss))
          cached
        (let ((result
               (condition-case nil
                   (with-temp-buffer
                     (let ((code (call-process "sh" nil t nil "-c" (substring str 1))))
                       (if (eq code 0) (string-trim (buffer-string)) str)))
                 (error str))))
          (puthash str result pai-resolve-config-value--cache)
          result))))
   (t (pai-resolve-config-value--interpolate str))))

;;;; Credential store

(defvar pai-auth--store 'unloaded
  "In-memory credential store: a keyword-keyed plist mapping provider id to
a credential plist.  The sentinel `unloaded' means it has not been read
from disk yet.")

(defgroup pai-auth nil "Credential storage for pai." :group 'pai)

(defcustom pai-auth-storage 'auto
  "Where pai persists provider credentials.

- `auto'      Use `gpg' when `pai-auth-gpg-recipient' is set or an encrypted
              store already exists; otherwise `plaintext'.
- `plaintext' A chmod-600 JSON file (`auth.json'), the usual Unix convention
              for credential files (compare `~/.netrc', `~/.aws/credentials').
- `gpg'       A GPG-encrypted JSON file (`auth.json.gpg') via Emacs's built-in
              EasyPG.  Encrypted at rest with your key (see
              `pai-auth-gpg-recipient'); gpg-agent handles decryption.

Independently, `pai-api-key' also reads Emacs `auth-source' (e.g.
`~/.authinfo.gpg', `pass', or the Secret Service), so keys stored there are
used automatically."
  :type '(choice (const auto) (const plaintext) (const gpg))
  :group 'pai-auth)

(defcustom pai-auth-gpg-recipient nil
  "GPG recipient (key id or email) used to encrypt the credential store.
When nil, EasyPG falls back to symmetric (passphrase) encryption.  Only used
when `pai-auth-storage' resolves to `gpg'."
  :type '(choice (const :tag "Symmetric (passphrase)" nil) string)
  :group 'pai-auth)

(defun pai-auth--plaintext-file ()
  "Path to the plaintext credential store."
  (expand-file-name "auth.json" pai-directory))

(defun pai-auth--gpg-file ()
  "Path to the GPG-encrypted credential store."
  (expand-file-name "auth.json.gpg" pai-directory))

(defun pai-auth--effective-storage ()
  "Resolve `pai-auth-storage', turning `auto' into `gpg' or `plaintext'."
  (pcase pai-auth-storage
    ('gpg 'gpg)
    ('plaintext 'plaintext)
    (_ (if (or pai-auth-gpg-recipient (file-exists-p (pai-auth--gpg-file)))
           'gpg 'plaintext))))

(defun pai-auth-file ()
  "Return the path to the active credential store file."
  (if (eq (pai-auth--effective-storage) 'gpg)
      (pai-auth--gpg-file)
    (pai-auth--plaintext-file)))

(defun pai-auth--key (provider)
  "Return the plist key (a keyword) for PROVIDER id string."
  (intern (concat ":" provider)))

;;;; Store normalization / recovery

;; The store is a keyword-keyed plist (provider -> credential plist).  A prior
;; bug serialized an empty/odd store as a JSON *array* instead of an object;
;; once on disk as an array, decoding produced string keys that the
;; keyword-based getters never matched -- so credentials silently "vanished"
;; and every /login appended a duplicate.  `pai-auth--normalize' canonicalizes
;; any decoded shape (proper plist, string-keyed list, or a mangled flat array)
;; back into a clean keyword plist, keeping the last VALID credential per
;; provider, so existing corrupt stores self-heal on load.

(defun pai-auth--cred-p (x)
  "Return non-nil if X looks like a credential plist (keyword-keyed with :type)."
  (and (consp x) (keywordp (car x)) (plist-member x :type)))

(defun pai-auth--cred-valid-p (cred)
  "Return non-nil if CRED carries a usable secret."
  (pcase (plist-get cred :type)
    ("api_key" (let ((k (plist-get cred :key)))
                 (and (stringp k) (not (string-empty-p (string-trim k))))))
    ("oauth" (let ((a (plist-get cred :access)))
               (and (stringp a) (not (string-empty-p a)))))
    (_ (and cred t))))

(defun pai-auth--normalize (raw)
  "Canonicalize decoded store RAW into a clean keyword-keyed plist.
Accepts a proper plist, a string-keyed list, or a mangled flat array (the shape
left by the historical array-serialization bug).  Pairs each provider key with
the following credential object, keeps the last valid credential per provider,
and drops blanks."
  (let ((pending nil) (acc nil))
    (dolist (el raw)
      (cond
       ((keywordp el) (setq pending (substring (symbol-name el) 1)))
       ((and (stringp el) (not (string-empty-p el))) (setq pending el))
       ((symbolp el) (setq pending (and el (symbol-name el))))
       ((pai-auth--cred-p el)
        (when (and pending (pai-auth--cred-valid-p el))
          (setf (alist-get pending acc nil nil #'equal) el))
        (setq pending nil))))
    (let (out)
      (dolist (entry (nreverse acc))
        (setq out (plist-put out (pai-auth--key (car entry)) (cdr entry))))
      out)))

(defun pai-auth--canonical-p (raw)
  "Return non-nil if RAW is already a clean keyword plist (no recovery needed)."
  (equal raw (pai-auth--normalize raw)))

(defun pai-auth--file-gpg-p (file)
  "Return non-nil if FILE is a GPG-encrypted store path."
  (string-suffix-p ".gpg" file))

(defun pai-auth--ensure-epa ()
  "Ensure Emacs's built-in EasyPG file handler is active."
  (require 'epa-file)
  (unless (rassq 'epa-file-handler file-name-handler-alist)
    (epa-file-enable)))

(defun pai-auth--read-file (file)
  "Read and JSON-decode credential FILE (decrypting when GPG), or nil."
  (when (file-readable-p file)
    (when (pai-auth--file-gpg-p file) (pai-auth--ensure-epa))
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents file)
        (let ((s (string-trim (buffer-string))))
          (unless (string-empty-p s) (pai-json-decode s)))))))

(defun pai-auth--write-file (file store)
  "Write STORE as a JSON object to FILE (encrypting when GPG), chmod 600."
  (make-directory (file-name-directory file) t)
  (let* ((gpg (pai-auth--file-gpg-p file))
         (epa-file-encrypt-to (and gpg pai-auth-gpg-recipient
                                   (list pai-auth-gpg-recipient))))
    (when gpg (pai-auth--ensure-epa))
    (with-temp-file file
      (insert (pai-json-encode (or store (pai-json-empty-object))))))
  (set-file-modes file #o600))

(defun pai-auth--migrate ()
  "Import credentials from the inactive store file into the active one.
Runs when the active store is absent but the alternate format exists (e.g. after
enabling `gpg' storage).  Returns the imported store, or nil when nothing to do."
  (let* ((active (pai-auth-file))
         (alt (if (pai-auth--file-gpg-p active)
                  (pai-auth--plaintext-file) (pai-auth--gpg-file))))
    (when (and (not (file-exists-p active)) (file-readable-p alt))
      (let ((store (pai-auth--normalize (pai-auth--read-file alt))))
        (setq pai-auth--store store)
        (pai-auth--write-file active store)
        (ignore-errors (delete-file alt))
        store))))

(defun pai-auth-load ()
  "Load the credential store from disk into `pai-auth--store'.
Migrates a legacy/alternate store, and recovers+re-saves a corrupt
\(array/string-keyed) store.  Return the store."
  (let ((active (pai-auth-file)))
    (if (and (not (file-exists-p active)) (pai-auth--migrate))
        pai-auth--store
      (let* ((raw (pai-auth--read-file active))
             (needs-heal (and raw (not (pai-auth--canonical-p raw)))))
        (setq pai-auth--store (pai-auth--normalize raw))
        (when needs-heal
          ;; Preserve the original before overwriting, so nothing is lost if
          ;; recovery guesses wrong on a badly mangled store.
          (ignore-errors
            (let ((bak (concat active ".corrupt.bak")))
              (copy-file active bak t)
              (set-file-modes bak #o600)))
          (pai-auth--save))
        pai-auth--store))))

(defun pai-auth--ensure ()
  "Ensure the credential store has been loaded from disk."
  (when (eq pai-auth--store 'unloaded) (pai-auth-load)))

(defun pai-auth--save ()
  "Persist `pai-auth--store' to the active store file.
Always writes a JSON object (never a bare array), so an empty store round-trips."
  (let ((store (pai-auth--normalize pai-auth--store)))
    (setq pai-auth--store store)
    (pai-auth--write-file (pai-auth-file) store)))

(defun pai-auth--plist-delete (plist key)
  "Return a copy of PLIST with KEY (and its value) removed."
  (let (out)
    (while plist
      (unless (eq (car plist) key)
        (setq out (cons (car plist) (cons (cadr plist) out))))
      (setq plist (cddr plist)))
    (nreverse out)))

(defun pai-auth--provider-ids ()
  "Return the list of configured provider id strings."
  (pai-auth--ensure)
  (let (ids (p pai-auth--store))
    (while p
      (push (substring (symbol-name (car p)) 1) ids)
      (setq p (cddr p)))
    (nreverse ids)))

(defun pai-auth-get (provider)
  "Return the stored credential plist for PROVIDER, or nil."
  (pai-auth--ensure)
  (plist-get pai-auth--store (pai-auth--key provider)))

(defun pai-auth-set (provider plist)
  "Store credential PLIST for PROVIDER and persist to disk.  Return PLIST."
  (pai-auth--ensure)
  (setq pai-auth--store (plist-put pai-auth--store (pai-auth--key provider) plist))
  (pai-auth--save)
  plist)

(defun pai-auth-delete (provider)
  "Remove the stored credential for PROVIDER and persist to disk."
  (pai-auth--ensure)
  (setq pai-auth--store (pai-auth--plist-delete pai-auth--store (pai-auth--key provider)))
  (pai-auth--save)
  nil)

(defvar pai-auth-oauth-refresh-handlers nil
  "Alist of provider id -> refresh function.
Each function receives the stored oauth credential plist and returns a fresh
credential plist (with new :access/:refresh/:expires) or nil on failure.")

(defun pai-auth--expired-p (cred)
  "Return non-nil if oauth CRED has an expiry in the past."
  (let ((exp (plist-get cred :expires)))
    (and (numberp exp) (>= (pai-now-ms) exp))))

(defun pai-auth--maybe-refresh (provider cred)
  "Refresh PROVIDER's oauth CRED when expired and refreshable; return the cred.
Persists and returns the new credential on success, else the original CRED."
  (if (and (equal (plist-get cred :type) "oauth")
           (plist-get cred :refresh)
           (pai-auth--expired-p cred))
      (let ((handler (cdr (assoc provider pai-auth-oauth-refresh-handlers))))
        (or (and handler
                 (let ((new (ignore-errors (funcall handler cred))))
                   (and new (plist-get new :access) (pai-auth-set provider new))))
            cred))
    cred))

(defun pai-auth-api-key (provider)
  "Return a resolved API key string for PROVIDER, or nil.
For a stored \"api_key\" credential the key is passed through
`pai-resolve-config-value'; for an \"oauth\" credential the access token is
returned, refreshing it first when it has expired."
  (let ((cred (pai-auth-get provider)))
    (when cred
      (setq cred (pai-auth--maybe-refresh provider cred))
      (let ((type (plist-get cred :type)))
        (cond
         ((equal type "api_key") (pai-resolve-config-value (plist-get cred :key)))
         ((equal type "oauth") (plist-get cred :access))
         (t nil))))))

;;;; OAuth helpers

(defun pai-auth--base64url (bytes)
  "Return the url-safe base64 (no padding) encoding of unibyte string BYTES."
  (let ((s (base64-encode-string bytes t)))
    (setq s (replace-regexp-in-string "+" "-" s t t))
    (setq s (replace-regexp-in-string "/" "_" s t t))
    (replace-regexp-in-string "=+\\'" "" s t)))

(defun pai-auth--random-bytes (n)
  "Return a unibyte string of N random bytes."
  (let ((s (make-string n 0)))
    (dotimes (i n) (aset s i (random 256)))
    s))

(defun pai-auth--url-encode-params (pairs)
  "Encode alist PAIRS as an application/x-www-form-urlencoded query string."
  (mapconcat (lambda (kv)
               (concat (url-hexify-string (car kv)) "="
                       (url-hexify-string (cdr kv))))
             pairs "&"))

(defun pai-auth--extract-code (input)
  "Extract an authorization code from INPUT, a raw code or a redirected URL."
  (let ((s (string-trim (or input ""))))
    (if (string-match "[?&]code=\\([^&]+\\)" s)
        (url-unhex-string (match-string 1 s))
      s)))

(defun pai-auth--start-loopback-server (port on-code)
  "Start a loopback HTTP server on PORT calling ON-CODE with the auth code.
Return the server process."
  (make-network-process
   :name "pai-oauth-callback"
   :server t
   :host "127.0.0.1"
   :service port
   :family 'ipv4
   :coding 'binary
   :filter (lambda (proc chunk)
             (when (string-match "GET /callback\\?\\([^ ]*\\) " chunk)
               (let ((query (match-string 1 chunk)))
                 (when (string-match "code=\\([^&]+\\)" query)
                   (funcall on-code (url-unhex-string (match-string 1 query))))))
             (ignore-errors
               (process-send-string
                proc (concat "HTTP/1.1 200 OK\r\n"
                             "Content-Type: text/plain\r\n\r\n"
                             "Authorization complete; you may close this window.")))
             (ignore-errors (delete-process proc)))))

(defun pai-auth--http-json (url method body-plist &optional extra-headers)
  "Perform an HTTP METHOD request to URL and return the decoded JSON plist.
BODY-PLIST, when non-nil, is JSON-encoded as the request body.
EXTRA-HEADERS is an alist merged into the request headers."
  (let* ((url-request-method method)
         (url-request-extra-headers
          (append (when body-plist '(("Content-Type" . "application/json")))
                  extra-headers))
         (url-request-data
          (when body-plist (encode-coding-string (pai-json-encode body-plist) 'utf-8)))
         (buf (url-retrieve-synchronously url t t 30)))
    (when buf
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (when (re-search-forward "\r?\n\r?\n" nil t)
              (let ((s (string-trim (buffer-substring-no-properties (point) (point-max)))))
                (unless (string-empty-p s) (ignore-errors (pai-json-decode s))))))
        (kill-buffer buf)))))

;;;; OAuth flows

(defconst pai-auth--anthropic-client-id
  (base64-decode-string "OWQxYzI1MGEtZTYxYi00NGQ5LTg4ZWQtNTk0NGQxOTYyZjVl")
  "Public Claude Code OAuth client id.")

(defconst pai-auth--anthropic-token-url "https://api.anthropic.com/v1/oauth/token"
  "Anthropic OAuth token endpoint (code exchange and refresh).")

(defconst pai-auth--anthropic-scopes
  "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
  "OAuth scopes required for direct Claude Pro/Max inference.")

(defconst pai-auth--anthropic-redirect "http://localhost:54545/callback"
  "Loopback redirect URI registered for the Claude Code OAuth client.")

(defun pai-auth--anthropic-store (resp cred)
  "Build and persist an anthropic oauth credential from token RESP.
Falls back to CRED's refresh token when RESP omits one.  Return the cred or nil."
  (let ((access (plist-get resp :access_token)))
    (when access
      (pai-auth-set
       "anthropic"
       (list :type "oauth"
             :access access
             :refresh (or (plist-get resp :refresh_token) (plist-get cred :refresh))
             :expires (+ (pai-now-ms) (* (or (plist-get resp :expires_in) 0) 1000) -300000))))))

(defun pai-auth-oauth-anthropic ()
  "Run the Anthropic OAuth PKCE loopback flow.  Return t on success, nil on failure."
  (condition-case nil
      (let* ((client-id pai-auth--anthropic-client-id)
             (verifier (pai-auth--base64url (pai-auth--random-bytes 32)))
             (challenge (pai-auth--base64url (secure-hash 'sha256 verifier nil nil t)))
             (redirect-uri pai-auth--anthropic-redirect)
             (auth-url (concat "https://claude.ai/oauth/authorize?"
                               (pai-auth--url-encode-params
                                (list (cons "code" "true")
                                      (cons "client_id" client-id)
                                      (cons "response_type" "code")
                                      (cons "redirect_uri" redirect-uri)
                                      (cons "scope" pai-auth--anthropic-scopes)
                                      (cons "code_challenge" challenge)
                                      (cons "code_challenge_method" "S256")
                                      (cons "state" verifier)))))
             (captured nil)
             (server (ignore-errors
                       (pai-auth--start-loopback-server
                        54545 (lambda (code) (setq captured code))))))
        (unwind-protect
            (progn
              (browse-url auth-url)
              (message "Open this URL to authorize Anthropic:\n%s" auth-url)
              (let ((deadline (+ (float-time) 120)))
                (while (and (not captured) server (< (float-time) deadline))
                  (accept-process-output nil 0.2)))
              (let ((code (or captured
                              (pai-auth--extract-code
                               (read-string "Paste the redirected URL or code: ")))))
                (when (and code (not (string-empty-p code)))
                  ;; Claude returns `code#state'; split and use both parts.
                  (let* ((parts (split-string code "#"))
                         (auth-code (car parts))
                         (state (or (cadr parts) verifier))
                         (resp (pai-auth--http-json
                                pai-auth--anthropic-token-url "POST"
                                (list :grant_type "authorization_code"
                                      :client_id client-id
                                      :code auth-code
                                      :state state
                                      :redirect_uri redirect-uri
                                      :code_verifier verifier))))
                    (and (pai-auth--anthropic-store resp nil) t)))))
          (when (process-live-p server) (delete-process server))))
    (error nil)))

(defun pai-auth-oauth-anthropic-refresh (cred)
  "Refresh an anthropic oauth CRED.  Return the new credential plist, or nil."
  (condition-case nil
      (let ((resp (pai-auth--http-json
                   pai-auth--anthropic-token-url "POST"
                   (list :grant_type "refresh_token"
                         :refresh_token (plist-get cred :refresh)
                         :client_id pai-auth--anthropic-client-id)
                   (list (cons "anthropic-beta" "oauth-2025-04-20")
                         (cons "User-Agent"
                               "anthropic-sdk-typescript/0.112.1 userOAuthProvider")))))
        (pai-auth--anthropic-store resp cred))
    (error nil)))

(defun pai-auth-oauth-github-copilot ()
  "Run the GitHub Copilot OAuth device flow.  Return t on success, nil on failure."
  (condition-case nil
      (let* ((client-id (base64-decode-string "SXYxLmI1MDdhMDhjODdlY2ZlOTg="))
             (device (pai-auth--http-json
                      "https://github.com/login/device/code" "POST"
                      (list :client_id client-id :scope "read:user")))
             (device-code (plist-get device :device_code))
             (user-code (plist-get device :user_code))
             (verification-uri (plist-get device :verification_uri))
             (interval (or (plist-get device :interval) 5))
             (access nil))
        (when (and device-code user-code)
          (message "Enter code %s at %s" user-code verification-uri)
          (ignore-errors (browse-url verification-uri))
          (let ((deadline (+ (float-time) 300)))
            (while (and (not access) (< (float-time) deadline))
              (sleep-for interval)
              (let ((poll (pai-auth--http-json
                           "https://github.com/login/oauth/access_token" "POST"
                           (list :client_id client-id
                                 :device_code device-code
                                 :grant_type "urn:ietf:params:oauth:grant-type:device_code"))))
                (setq access (plist-get poll :access_token)))))
          (when access
            (let* ((copilot (pai-auth--http-json
                             "https://api.github.com/copilot_internal/v2/token" "GET" nil
                             (list (cons "Authorization" (concat "Bearer " access)))))
                   (token (plist-get copilot :token))
                   (expires-at (plist-get copilot :expires_at)))
              (when token
                (pai-auth-set "github-copilot"
                              (list :type "oauth"
                                    :access token
                                    :refresh access
                                    :expires (if expires-at (* expires-at 1000)
                                               (+ (pai-now-ms) (* 3600 1000)))))
                t)))))
    (error nil)))

;;;; Slash commands

(defvar pai-auth-oauth-handlers nil
  "Alist of provider IDs to login functions installed by extensions.
Each function takes no arguments and returns non-nil on successful login.")

(defun pai-auth-login-command (args _ctx)
  "Handle the `/login [provider]' command.
With no PROVIDER, list configured providers.  For an OAuth provider, run
its flow; otherwise prompt for an API key and store it."
  (let ((provider (string-trim (or args ""))))
    (if (string-empty-p provider)
        (let ((providers (pai-auth--provider-ids)))
          (list :message
                (if providers
                    (concat "Configured providers:\n"
                            (mapconcat (lambda (p) (concat "  " p)) providers "\n"))
                  "No providers configured.  Use /login <provider>.")))
      (let ((login (cdr (assoc provider pai-auth-oauth-handlers))))
        (if login
            (list :message (if (funcall login)
                               (format "Logged in to %s" provider)
                             (format "Login to %s failed" provider)))
        (let ((key (read-passwd (format "API key for %s: " provider))))
          (pai-auth-set provider (list :type "api_key" :key key))
          (list :message (format "Logged in to %s" provider))))))))

(defun pai-auth-logout-command (args _ctx)
  "Handle the `/logout [provider]' command."
  (let ((provider (string-trim (or args ""))))
    (if (string-empty-p provider)
        (list :message "Usage: /logout <provider>")
      (pai-auth-delete provider)
      (list :message (format "Logged out of %s" provider)))))

(defun pai-auth--login-completions (_prefix)
  "Return provider completion candidates for `/login'."
  (delete-dups (append (mapcar #'car pai-auth-oauth-handlers)
                       (when (boundp 'pai--providers) (hash-table-keys pai--providers))
                       (pai-auth--provider-ids))))

(pai-register-command "login"
  :description "Log in to a provider (store an API key or run OAuth)"
  :handler #'pai-auth-login-command
  :arg-completions #'pai-auth--login-completions)

(pai-register-command "logout"
  :description "Remove stored credentials for a provider"
  :handler #'pai-auth-logout-command
  :arg-completions (lambda (_prefix) (pai-auth--provider-ids)))

(provide 'pai-auth)
;;; pai-auth.el ends here
