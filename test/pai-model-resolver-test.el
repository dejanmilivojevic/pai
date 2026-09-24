;;; pai-model-resolver-test.el --- Tests for model resolution -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai-core)
(require 'pai-settings)
(require 'pai-model-resolver)

(defmacro pai-mr-test--sandbox (dir &rest body)
  (declare (indent 1))
  `(let* ((,dir (file-name-as-directory (make-temp-file "pai-mr" t)))
          (pai-directory (expand-file-name "state" ,dir))
          (pai-settings--global nil) (pai-settings--project nil) (pai-settings--project-dir nil)
          (pai--models (make-hash-table :test 'equal))
          (pai--providers (make-hash-table :test 'equal)))
     (unwind-protect (progn ,@body) (delete-directory ,dir t))))

(defun pai-mr-test--model (provider id)
  "Register a local fixture model with PROVIDER and ID."
  (pai-register-model
   (pai-make-model :id id :provider provider :api 'openai-completions
                   :base-url "http://localhost:1234/v1")))

(ert-deftest pai-mr-scoped-defaults-to-main ()
  (pai-mr-test--sandbox dir
    (pai-settings-load nil)
    (pai-settings-set :scoped-models (list :main "local/main") 'global)
    (should (equal (pai-scoped-model-id :task) "local/main"))
    (should (equal (pai-scoped-model-id :compact) "local/main"))
    (pai-settings-set :scoped-models (list :main "local/main" :compact "local/small") 'global)
    (should (equal (pai-scoped-model-id :compact) "local/small"))))

(ert-deftest pai-mr-model-keys-sorted-across-providers ()
  (pai-mr-test--sandbox dir
    (pai-mr-test--model "zeta" "b")
    (pai-mr-test--model "anthropic" "z")
    (pai-mr-test--model "openrouter" "google/gemini")
    (pai-mr-test--model "anthropic" "a")
    (should (equal (pai-model-keys)
                   '("anthropic/a" "anthropic/z" "openrouter/google/gemini" "zeta/b")))))

(ert-deftest pai-mr-scoped-model-set-clear-and-describe ()
  (let ((pai-model-roles (copy-sequence pai-model-roles))
        (pai-model-role-fallbacks (copy-alist pai-model-role-fallbacks))
        (pai-model-role-descriptions (copy-alist pai-model-role-descriptions)))
    (pai-mr-test--sandbox dir
      (pai-mr-test--model "local" "main")
      (pai-mr-test--model "local" "small")
      (pai-settings-load nil)
      (pai-register-model-role :x-worker :task "Does X")
      (should (equal (alist-get :x-worker pai-model-role-descriptions) "Does X"))
      ;; nothing configured: the session's model
      (should (equal (pai-scoped-model-resolution :x-worker) '(nil)))
      (should (equal (pai-scoped-model-describe :x-worker "local/live")
                     "inherits → local/live (the session's model)"))
      ;; the Model setting
      (pai-settings-set :model "local/main" 'global)
      (should (equal (pai-scoped-model-resolution :x-worker) '("local/main" . :model)))
      ;; through :task
      (should (equal (pai-scoped-model-set :task "local/small") "local/small"))
      (should (equal (pai-scoped-model-resolution :x-worker) '("local/small" . :task)))
      (should (equal (pai-scoped-model-describe :x-worker) "inherits → local/small (from task)"))
      ;; explicit, then cleared again
      (pai-scoped-model-set :x-worker "local/main")
      (should (equal (pai-scoped-model-explicit :x-worker) "local/main"))
      (should (equal (pai-scoped-model-describe :x-worker) "local/main"))
      (should-not (pai-scoped-model-set :x-worker pai-scoped-model-inherit))
      (should-not (pai-scoped-model-explicit :x-worker))
      (should (equal (pai-scoped-model-explicit :task) "local/small"))
      ;; the setting was written to the project scope
      (should (plist-member (pai-settings-scope-value :scoped-models 'project) :task))
      (should-error (pai-scoped-model-set :task "nope/missing")))))

(ert-deftest pai-mr-scoped-models-command-inherit-and-listing ()
  (let ((pai-model-roles (copy-sequence pai-model-roles))
        (pai-model-role-fallbacks (copy-alist pai-model-role-fallbacks)))
    (pai-mr-test--sandbox dir
      (pai-mr-test--model "local" "main")
      (pai-settings-load nil)
      (pai-register-model-role :x-worker :task)
      (let ((msg (lambda (args) (plist-get (pai-scoped-models-command args nil) :message))))
        (should (string-match-p "Scoped model x-worker = local/main" (funcall msg "x-worker local/main")))
        (should (string-match-p "x-worker +local/main" (funcall msg "")))
        (should (string-match-p "inherits" (funcall msg "x-worker inherit")))
        (should-not (pai-scoped-model-explicit :x-worker))
        (should (string-match-p "Unknown model: nope" (funcall msg "task nope")))
        (should (string-match-p "Usage" (funcall msg "bogus-role local/main")))))))

(ert-deftest pai-mr-scoped-models-completion-by-position ()
  (with-temp-buffer
    (insert "> ")
    (setq-local pai--input-marker (copy-marker (point)))
    (let ((complete (plist-get (pai-command-get "scoped-models") :arg-completions)))
      (insert "/scoped-models ta")
      (should (member "task" (funcall complete "ta")))
      (should-not (member pai-scoped-model-inherit (funcall complete "ta")))
      (insert "sk ")
      (should (equal (pai-command-arg-words) '("task")))
      (should (member pai-scoped-model-inherit (funcall complete ""))))))

(ert-deftest pai-mr-registered-role-follows-fallback-chain ()
  "An extension role falls back to its declared role, then to :main."
  (let ((pai-model-roles (copy-sequence pai-model-roles))
        (pai-model-role-fallbacks (copy-alist pai-model-role-fallbacks)))
    (pai-mr-test--sandbox dir
      (pai-settings-load nil)
      (pai-register-model-role :memory-observer :task)
      (should (memq :memory-observer pai-model-roles))
      (pai-settings-set :scoped-models (list :main "local/main") 'global)
      (should (equal (pai-scoped-model-id :memory-observer) "local/main"))
      (pai-settings-set :scoped-models (list :main "local/main" :task "local/task") 'global)
      (should (equal (pai-scoped-model-id :memory-observer) "local/task"))
      (pai-settings-set :scoped-models (list :main "local/main" :task "local/task"
                                             :memory-observer "local/cheap")
                        'global)
      (should (equal (pai-scoped-model-id :memory-observer) "local/cheap"))
      ;; re-registering does not duplicate the role
      (pai-register-model-role :memory-observer :task)
      (should (= 1 (cl-count :memory-observer pai-model-roles))))))

(ert-deftest pai-mr-role-fallback-cycle-terminates ()
  (let ((pai-model-roles (copy-sequence pai-model-roles))
        (pai-model-role-fallbacks nil))
    (pai-mr-test--sandbox dir
      (pai-settings-load nil)
      (pai-register-model-role :x-a :x-b)
      (pai-register-model-role :x-b :x-a)
      (pai-settings-set :scoped-models (list :main "local/main") 'global)
      (should (equal (pai-scoped-model-id :x-a) "local/main")))))

(ert-deftest pai-mr-model-command-discovers-and-reports-errors ()
  (pai-mr-test--sandbox dir
    (let* ((fallback (pai-mr-test--model "offline" "fallback"))
           (errors '("offline: connection refused" "other: unauthorized")))
      (cl-letf (((symbol-function 'pai-models-refresh)
                 (lambda ()
                   (pai-mr-test--model "local" "discovered")
                   errors)))
        (let ((message (plist-get (pai-model-command "" (list :model fallback)) :message)))
          (should (string-match-p (regexp-quote "local/discovered") message))
          (should (string-match-p (regexp-quote "* offline/fallback") message))
          (dolist (err errors)
            (should (string-match-p (regexp-quote err) message))))))))

(ert-deftest pai-mr-model-command-selects-qualified-identities ()
  (pai-mr-test--sandbox dir
    (pai-mr-test--model "first" "shared")
    (pai-mr-test--model "second" "shared")
    (pai-mr-test--model "first" "unique")
    (let* ((selected nil)
           (ctx (list :set-model (lambda (id) (setq selected id)))))
      (pai-model-command "first/shared" ctx)
      (should (equal selected "first/shared"))
      (pai-model-command "second/shared" ctx)
      (should (equal selected "second/shared"))
      (pai-model-command "unique" ctx)
      (should (equal selected "first/unique"))
      (setq selected nil)
      (pai-model-command "shared" ctx)
      (should-not selected)
      (pai-model-command "missing" ctx)
      (should-not selected))))

(ert-deftest pai-mr-model-completions-refresh-only-on-opening ()
  (pai-mr-test--sandbox dir
    (let ((refreshes 0)
          (complete (plist-get (pai-command-get "model") :arg-completions)))
      (cl-letf (((symbol-function 'pai-models-refresh)
                 (lambda ()
                   (cl-incf refreshes)
                   (pai-mr-test--model "first" "shared")
                   (pai-mr-test--model "second" "shared")
                   nil)))
        (should (equal (sort (funcall complete "") #'string<)
                       '("first/shared" "second/shared")))
        (funcall complete "f")
        (funcall complete "first/")
        (should (= refreshes 1))
        (funcall complete "")
        (should (= refreshes 2))))))

(ert-deftest pai-mr-thinking-command ()
  (let* ((set nil)
         (ctx (list :thinking-level "off" :set-thinking (lambda (l) (setq set l)))))
    (should (string-match-p "off" (plist-get (pai-thinking-command "" ctx) :message)))
    (pai-thinking-command "medium" ctx)
    (should (equal set "medium"))
    (setq set nil)
    (pai-thinking-command "bogus" ctx)
    (should-not set)))

(ert-deftest pai-mr-scoped-command-set ()
  (pai-mr-test--sandbox dir
    (let ((proj (expand-file-name "p" dir)))
      (make-directory proj)
      (pai-settings-load proj)
      (pai-mr-test--model "local" "small")
      (pai-mr-test--model "first" "shared")
      (pai-mr-test--model "second" "shared")
      (pai-scoped-models-command "compact small" nil)
      (should (equal (pai-scoped-model-id :compact) "local/small"))
      (pai-scoped-models-command "compact second/shared" nil)
      (should (equal (pai-scoped-model-id :compact) "second/shared"))
      (pai-scoped-models-command "compact shared" nil)
      (should (equal (pai-scoped-model-id :compact) "second/shared"))
      (pai-settings-load proj)
      (should (equal (pai-scoped-model-id :compact) "second/shared"))
      (should (equal (plist-get (pai-scoped-model :compact) :provider) "second")))))

(provide 'pai-model-resolver-test)
;;; pai-model-resolver-test.el ends here
