;;; pai-anthropic-oauth-test.el --- Tests for Anthropic OAuth support -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai)
(require 'pai-provider-anthropic)
(require 'pai-auth)
(require 'pai-config)

(defun pai-anthropic-oauth-test--header (req name)
  "Return header NAME (case-insensitive) from request REQ's :headers alist."
  (cdr (assoc-string name (plist-get req :headers) t)))

;;;; Token detection

(ert-deftest pai-anthropic-oauth-token-detection ()
  (should (pai-anthropic--oauth-token-p "sk-ant-oat01-abc"))
  (should-not (pai-anthropic--oauth-token-p "sk-ant-api03-abc"))
  (should-not (pai-anthropic--oauth-token-p nil))
  (should-not (pai-anthropic--oauth-token-p "")))

;;;; Request building

(defun pai-anthropic-oauth-test--request (key)
  "Build an anthropic request with credential KEY."
  (pai-anthropic-build-request
   (list :id "claude-x" :base-url "https://api.anthropic.com/v1")
   (list :messages (list (pai-system-message "MY SYSTEM") (pai-user-message "hi"))
         :tools nil)
   (list :api-key key)))

(ert-deftest pai-anthropic-oauth-request-headers ()
  "An OAuth token uses Bearer auth + the oauth beta and drops x-api-key."
  (let ((req (pai-anthropic-oauth-test--request "sk-ant-oat01-TOKEN")))
    (should (equal (pai-anthropic-oauth-test--header req "authorization")
                   "Bearer sk-ant-oat01-TOKEN"))
    (should (equal (pai-anthropic-oauth-test--header req "anthropic-beta") "oauth-2025-04-20"))
    (should (equal (pai-anthropic-oauth-test--header req "anthropic-version") "2023-06-01"))
    (should-not (pai-anthropic-oauth-test--header req "x-api-key"))))

(ert-deftest pai-anthropic-oauth-user-agent-version ()
  "The reported CLI version comes from the customizable constant.

Anthropic refuses requests from clients it considers too old, so the
version must be a single knob and must not regress below the minimum
we have seen the API demand."
  (let ((req (pai-anthropic-oauth-test--request "sk-ant-oat01-TOKEN")))
    (should (equal (pai-anthropic-oauth-test--header req "user-agent")
                   (format "claude-cli/%s (external, cli)"
                           pai-anthropic-claude-code-cli-version)))
    (should (version<= "2.1.280" pai-anthropic-claude-code-cli-version)))
  (let ((pai-anthropic-claude-code-cli-version "9.9.9"))
    (should (equal (pai-anthropic-oauth-test--header
                    (pai-anthropic-oauth-test--request "sk-ant-oat01-T") "user-agent")
                   "claude-cli/9.9.9 (external, cli)"))))

(ert-deftest pai-anthropic-oauth-request-system ()
  "Under OAuth the first system block is the Claude Code identity, then ours."
  (let* ((req (pai-anthropic-oauth-test--request "sk-ant-oat01-TOKEN"))
         (system (plist-get (plist-get req :body) :system)))
    (should (listp system))
    (should (equal (plist-get (nth 0 system) :text) pai-anthropic-claude-code-system))
    (should (equal (plist-get (nth 1 system) :text) "MY SYSTEM"))))

(ert-deftest pai-anthropic-apikey-request-unchanged ()
  "A normal API key keeps x-api-key auth and a plain system prompt."
  (let* ((req (pai-anthropic-oauth-test--request "sk-ant-api03-KEY"))
         (system (plist-get (plist-get req :body) :system)))
    (should (equal (pai-anthropic-oauth-test--header req "x-api-key") "sk-ant-api03-KEY"))
    (should-not (pai-anthropic-oauth-test--header req "authorization"))
    (should-not (pai-anthropic-oauth-test--header req "anthropic-beta"))
    ;; no Claude Code identity injected
    (should-not (cl-find pai-anthropic-claude-code-system system
                         :key (lambda (b) (and (listp b) (plist-get b :text))) :test #'equal))))

;;;; Token refresh

(defmacro pai-anthropic-oauth-test--auth (&rest body)
  "Run BODY with a hermetic credential store."
  `(let* ((dir (file-name-as-directory (make-temp-file "pai-aoauth" t)))
          (pai-directory dir)
          (pai-auth-storage 'plaintext)
          (pai-auth--store 'unloaded)
          (pai-auth-oauth-refresh-handlers nil))
     (unwind-protect (progn ,@body) (delete-directory dir t))))

(ert-deftest pai-anthropic-oauth-refresh-on-expiry ()
  "An expired oauth token is refreshed via the handler and the new access used."
  (pai-anthropic-oauth-test--auth
   (setf (alist-get "anthropic" pai-auth-oauth-refresh-handlers nil nil #'equal)
         (lambda (cred)
           (list :type "oauth" :access "sk-ant-oat01-NEW"
                 :refresh (plist-get cred :refresh)
                 :expires (+ (pai-now-ms) 3600000))))
   (pai-auth-set "anthropic"
                 (list :type "oauth" :access "sk-ant-oat01-OLD"
                       :refresh "refresh-tok" :expires (- (pai-now-ms) 1000)))
   (should (equal (pai-auth-api-key "anthropic") "sk-ant-oat01-NEW"))
   ;; persisted
   (should (equal (plist-get (pai-auth-get "anthropic") :access) "sk-ant-oat01-NEW"))))

(ert-deftest pai-anthropic-oauth-no-refresh-when-valid ()
  "A non-expired token is returned as-is (handler not invoked)."
  (pai-anthropic-oauth-test--auth
   (setf (alist-get "anthropic" pai-auth-oauth-refresh-handlers nil nil #'equal)
         (lambda (_cred) (error "refresh must not run")))
   (pai-auth-set "anthropic"
                 (list :type "oauth" :access "sk-ant-oat01-VALID"
                       :refresh "r" :expires (+ (pai-now-ms) 3600000)))
   (should (equal (pai-auth-api-key "anthropic") "sk-ant-oat01-VALID"))))

(ert-deftest pai-anthropic-oauth-api-key-not-refreshed ()
  "A plain api_key credential is never routed through refresh."
  (pai-anthropic-oauth-test--auth
   (setf (alist-get "anthropic" pai-auth-oauth-refresh-handlers nil nil #'equal)
         (lambda (_cred) (error "refresh must not run")))
   (pai-auth-set "anthropic" (list :type "api_key" :key "sk-ant-api03-KEY"))
   (should (equal (pai-auth-api-key "anthropic") "sk-ant-api03-KEY"))))

(provide 'pai-anthropic-oauth-test)
;;; pai-anthropic-oauth-test.el ends here
