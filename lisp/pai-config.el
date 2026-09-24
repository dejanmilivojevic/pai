;;; pai-config.el --- Configuration and credential resolution for pai -*- lexical-binding: t; -*-

;;; Commentary:

;; User-facing configuration (the `pai' customization group) plus resolution
;; of provider API keys from customization or environment variables, mirroring
;; packages/ai/src/env-api-keys.ts.

;;; Code:

(require 'cl-lib)

(defgroup pai nil
  "Pi agent harness for Emacs: a self-extensible coding agent."
  :group 'tools
  :prefix "pai-")

(defcustom pai-directory (expand-file-name "~/.pai")
  "Root directory for pai state: sessions, extensions, skills."
  :type 'directory
  :group 'pai)

(defcustom pai-default-model nil
  "Provider-qualified model ID used for new sessions, or nil to select one."
  :type '(choice (const :tag "Select a model" nil) string)
  :group 'pai)

(defcustom pai-api-keys nil
  "Alist mapping provider id (string) to an API key (string).
Takes precedence over environment variables.  Leave nil to rely on the
environment.  Example: \\='((\"anthropic\" . \"sk-ant-...\"))."
  :type '(alist :key-type string :value-type string)
  :group 'pai)

(defcustom pai-curl-program "curl"
  "Path to the curl executable used for streaming HTTP requests."
  :type 'string
  :group 'pai)

(defcustom pai-request-timeout 600
  "Default per-request timeout in seconds for provider HTTP requests."
  :type 'integer
  :group 'pai)

(defcustom pai-max-tokens 8192
  "Default maximum output tokens per request when the model has no cap."
  :type 'integer
  :group 'pai)

(defcustom pai-tool-execution 'parallel
  "Default tool execution mode: `parallel' or `sequential'."
  :type '(choice (const parallel) (const sequential))
  :group 'pai)

;; Environment variables consulted per provider, in priority order.
(defvar pai-provider-env-keys nil
  "Alist of provider id to API-key environment variable names.
Configured providers and opt-in extensions supply these mappings.")

(defun pai-api-key--from-auth-source (provider)
  "Return an API key for PROVIDER from Emacs `auth-source', or nil.
Looks up host PROVIDER, then host \"pai\" with user PROVIDER, so keys kept in
`~/.authinfo.gpg', `pass', or the Secret Service are used automatically."
  (require 'auth-source)
  (let ((found (or (auth-source-search :host provider :max 1)
                   (auth-source-search :host "pai" :user provider :max 1))))
    (when found
      (let ((secret (plist-get (car found) :secret)))
        (if (functionp secret) (funcall secret) secret)))))

(defun pai-api-key (provider)
  "Resolve an API key string for PROVIDER, or nil if none is configured.
Checks `pai-api-keys' first, then a stored credential, then Emacs `auth-source'
\(e.g. `~/.authinfo.gpg', `pass', Secret Service), then the environment
variables listed in `pai-provider-env-keys'.  Surrounding whitespace (a common
copy/paste or file/command artifact) is stripped; an all-blank value is nil."
  (let ((raw (or (cdr (assoc provider pai-api-keys))
                 (and (fboundp 'pai-auth-api-key) (pai-auth-api-key provider))
                 (ignore-errors (pai-api-key--from-auth-source provider))
                 (seq-some (lambda (var)
                             (let ((v (getenv var)))
                               (and v (not (string-empty-p (string-trim v))) v)))
                           (cdr (assoc provider pai-provider-env-keys))))))
    (when (stringp raw)
      (let ((key (string-trim raw)))
        (unless (string-empty-p key) key)))))

(defun pai-state-directory (&rest segments)
  "Return SEGMENTS joined under `pai-directory', creating the directory."
  (let ((dir (apply #'file-name-concat pai-directory segments)))
    (make-directory dir t)
    dir))

(provide 'pai-config)
;;; pai-config.el ends here
