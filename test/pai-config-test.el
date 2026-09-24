;;; pai-config-test.el --- Tests for pai-config and pai-models -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai-config)
(require 'pai-models)
(require 'pai-auth)

(ert-deftest pai-config-api-key-from-alist ()
  (let ((pai-api-keys '(("anthropic" . "sk-test"))))
    (should (equal (pai-api-key "anthropic") "sk-test"))))

(ert-deftest pai-config-api-key-from-env ()
  (let ((pai-api-keys nil)
        (pai-provider-env-keys '(("test-openai" . ("PAI_TEST_API_KEY"))))
        (process-environment '("PAI_TEST_API_KEY=env-key")))
    (should (equal (pai-api-key "test-openai") "env-key"))))

(ert-deftest pai-config-api-key-alist-beats-env ()
  (let ((pai-api-keys '(("test-openai" . "alist-key")))
        (pai-provider-env-keys '(("test-openai" . ("PAI_TEST_API_KEY"))))
        (process-environment '("PAI_TEST_API_KEY=env-key")))
    (should (equal (pai-api-key "test-openai") "alist-key"))))

(ert-deftest pai-config-api-key-missing ()
  (let ((pai-api-keys nil)
        (pai-provider-env-keys '(("test-provider" . ("PAI_TEST_API_KEY"))))
        (process-environment nil))
    (should (null (pai-api-key "test-provider")))))

(ert-deftest pai-config-api-key-empty-env-ignored ()
  (let ((pai-api-keys nil)
        (pai-provider-env-keys '(("test-provider" . ("PAI_TEST_API_KEY"))))
        (process-environment '("PAI_TEST_API_KEY=")))
    (should (null (pai-api-key "test-provider")))))

(ert-deftest pai-config-api-key-env-fallback ()
  (let ((pai-api-keys nil)
        (pai-provider-env-keys '(("test-provider" . ("PAI_TEST_FIRST_KEY" "PAI_TEST_SECOND_KEY"))))
        (process-environment '("PAI_TEST_FIRST_KEY=" "PAI_TEST_SECOND_KEY=fallback-key")))
    (should (equal (pai-api-key "test-provider") "fallback-key"))))

(ert-deftest pai-config-api-key-trims-whitespace ()
  ;; A trailing newline/space (common when a key is read from a file, a
  ;; command, or pasted) must be stripped, or it corrupts the auth header.
  ;; Bind the credential store and auth-source out so the test is hermetic and
  ;; never resolves the developer's real ~/.pai/auth.json or ~/.authinfo.
  (let ((pai-auth--store nil) (auth-sources nil))
    (let ((pai-api-keys '(("openrouter" . "sk-or-abc123\n")))
          (pai-provider-env-keys nil))
      (should (equal (pai-api-key "openrouter") "sk-or-abc123")))
    (let ((pai-api-keys nil)
          (pai-provider-env-keys '(("openrouter" . ("PAI_TEST_API_KEY"))))
          (process-environment '("PAI_TEST_API_KEY=  sk-or-env999  ")))
      (should (equal (pai-api-key "openrouter") "sk-or-env999")))
    ;; an all-whitespace value resolves to nil, not an empty key
    (let ((pai-api-keys '(("openrouter" . "   ")))
          (pai-provider-env-keys nil))
      (should (null (pai-api-key "openrouter"))))))

(ert-deftest pai-models-register-and-replace ()
  (let* ((pai--models (make-hash-table :test 'equal))
         (model (pai-make-model :id "my-model" :api 'openai-completions
                                :provider "local" :base-url "http://localhost:1234/v1"))
         (replacement (pai-make-model :id "my-model" :api 'openai-completions
                                      :provider "local" :base-url "http://localhost:5678/v1")))
    (pai-register-model model)
    (should (eq (pai-model "my-model") model))
    (should (eq (pai-model "local/my-model") model))
    (pai-register-model replacement)
    (should (eq (pai-model "my-model") replacement))
    (should (equal (pai-models) (list replacement)))
    (should-not (pai-model "missing"))))

(ert-deftest pai-models-duplicate-ids-remain-distinct ()
  (let* ((pai--models (make-hash-table :test 'equal))
         (first (pai-make-model :id "org/model" :provider "first"))
         (second (pai-make-model :id "org/model" :provider "second")))
    (pai-register-model first)
    (should (eq (pai-model "org/model") first))
    (pai-register-model second)
    (should-not (pai-model "org/model"))
    (should (eq (pai-model (pai-model-key first)) first))
    (should (eq (pai-model (pai-model-key second)) second))
    (should (= (length (pai-models)) 2))
    (should (equal (plist-get first :id) "org/model"))
    (should (equal (plist-get second :id) "org/model"))))

(provide 'pai-config-test)
;;; pai-config-test.el ends here
