;;; pai-auth-test.el --- Tests for credential storage/recovery -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai-core)
(require 'pai-config)
(require 'pai-auth)

(defmacro pai-auth-test--sandbox (dir &rest body)
  "Run BODY with a throwaway credential store rooted at DIR (no real ~/.pai)."
  (declare (indent 1))
  `(let* ((,dir (file-name-as-directory (make-temp-file "pai-auth" t)))
          (pai-directory ,dir)
          (pai-auth-storage 'plaintext)
          (pai-auth-gpg-recipient nil)
          (pai-auth--store 'unloaded)
          (auth-sources nil))
     (unwind-protect (progn ,@body) (delete-directory ,dir t))))

;;;; Persistence round-trip

(ert-deftest pai-auth-set-get-persist ()
  "A stored key round-trips through disk across a simulated restart."
  (pai-auth-test--sandbox dir
    (pai-auth-set "openrouter" '(:type "api_key" :key "sk-or-xyz"))
    (should (equal (pai-auth-api-key "openrouter") "sk-or-xyz"))
    ;; simulate a fresh Emacs: drop the in-memory store, reload from disk
    (setq pai-auth--store 'unloaded)
    (should (equal (pai-auth-api-key "openrouter") "sk-or-xyz"))))

(ert-deftest pai-auth-empty-store-is-object ()
  "An empty store serializes as a JSON object, never a bare array."
  (pai-auth-test--sandbox dir
    (pai-auth-set "x" '(:type "api_key" :key "k"))
    (pai-auth-delete "x")
    (let ((raw (with-temp-buffer (insert-file-contents (pai-auth-file)) (buffer-string))))
      (should (string-prefix-p "{" (string-trim raw)))
      (should-not (string-prefix-p "[" (string-trim raw))))))

;;;; Corruption recovery

(ert-deftest pai-auth-recovers-array-store ()
  "A corrupt flat-array store self-heals into a keyword-keyed object on load."
  (pai-auth-test--sandbox dir
    ;; Mirror the historical bug: a JSON array of [provider, cred, ...] with
    ;; duplicates and a blank credential.
    (with-temp-file (pai-auth-file)
      (insert (concat "[\"anthropic\",{\"type\":\"oauth\",\"access\":\"tok\",\"refresh\":\"r\",\"expires\":1},"
                      "\"openrouter\",{\"type\":\"api_key\",\"key\":\"\"},"
                      "\"openrouter\",{\"type\":\"api_key\",\"key\":\"sk-or-final\"}]")))
    (pai-auth-load)
    (should (equal (sort (copy-sequence (pai-auth--provider-ids)) #'string<)
                   '("anthropic" "openrouter")))
    ;; blank key dropped; last valid wins
    (should (equal (pai-auth-api-key "openrouter") "sk-or-final"))
    (should (equal (pai-auth-api-key "anthropic") "tok"))
    ;; the file is healed to a canonical object and stays stable on reload
    (let ((raw (with-temp-buffer (insert-file-contents (pai-auth-file)) (buffer-string))))
      (should (string-prefix-p "{" (string-trim raw)))
      (should (pai-auth--canonical-p (pai-json-decode raw))))))

(ert-deftest pai-auth-normalize-idempotent ()
  "Normalizing a clean store is a no-op (no spurious re-heal)."
  (let ((clean '(:anthropic (:type "api_key" :key "a")
                 :openrouter (:type "api_key" :key "b"))))
    (should (equal (pai-auth--normalize clean) clean))
    (should (pai-auth--canonical-p clean))))

;;;; Storage selection

(ert-deftest pai-auth-storage-selection ()
  "`auto' picks plaintext by default and gpg when a recipient is set."
  (pai-auth-test--sandbox dir
    (let ((pai-auth-storage 'auto) (pai-auth-gpg-recipient nil))
      (should (string-suffix-p "auth.json" (pai-auth-file)))
      (should-not (string-suffix-p ".gpg" (pai-auth-file))))
    (let ((pai-auth-storage 'auto) (pai-auth-gpg-recipient "me@example.com"))
      (should (string-suffix-p "auth.json.gpg" (pai-auth-file))))
    (let ((pai-auth-storage 'gpg))
      (should (string-suffix-p "auth.json.gpg" (pai-auth-file))))))

;;;; auth-source read integration

(ert-deftest pai-auth-api-key-reads-auth-source ()
  "`pai-api-key' resolves a key kept in Emacs auth-source."
  (pai-auth-test--sandbox dir
    (let* ((netrc (expand-file-name "authinfo" dir))
           (auth-sources (list netrc))
           (pai-api-keys nil)
           (pai-provider-env-keys nil))
      (with-temp-file netrc
        (insert "machine deepseek login apikey password sk-deepseek-123\n"))
      (auth-source-forget-all-cached)
      (should (equal (pai-api-key "deepseek") "sk-deepseek-123")))))

;;;; Resolution precedence

(ert-deftest pai-auth-api-keys-alist-beats-store ()
  "The `pai-api-keys' override wins over the persisted store."
  (pai-auth-test--sandbox dir
    (pai-auth-set "openrouter" '(:type "api_key" :key "stored"))
    (let ((pai-api-keys '(("openrouter" . "override"))))
      (should (equal (pai-api-key "openrouter") "override")))))

(provide 'pai-auth-test)
;;; pai-auth-test.el ends here
