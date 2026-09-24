;;; pai-trust-test.el --- Tests for pai-trust -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai-trust)

(defmacro pai-trust-test--sandbox (dir &rest body)
  "Bind DIR to a fresh temp directory with an isolated trust store."
  (declare (indent 1))
  `(let* ((,dir (file-name-as-directory (make-temp-file "pai-trust" t)))
          (pai-directory (expand-file-name "state" ,dir))
          (pai-trust--store nil)
          (pai-settings--global nil)
          (pai-settings--project nil)
          (pai-settings--project-dir nil))
     (unwind-protect (progn ,@body) (delete-directory ,dir t))))

(ert-deftest pai-trust-set-get-roundtrip-persists ()
  (pai-trust-test--sandbox dir
    (should (eq (pai-trust-set dir t) t))
    (should (file-exists-p (pai-trust-file)))
    (should (eq (pai-trust-get dir) 'yes))
    ;; reload from disk
    (setq pai-trust--store nil)
    (should (eq (pai-trust-get dir) 'yes))))

(ert-deftest pai-trust-set-no-persists ()
  (pai-trust-test--sandbox dir
    (pai-trust-set dir nil)
    (setq pai-trust--store nil)
    (should (eq (pai-trust-get dir) 'no))))

(ert-deftest pai-trust-ancestor-inheritance ()
  (pai-trust-test--sandbox dir
    (let ((child (expand-file-name "a/b/c" dir)))
      (make-directory child t)
      (pai-trust-set dir t)
      (should (eq (pai-trust-get child) 'yes)))))

(ert-deftest pai-trust-undecided-when-unrecorded ()
  (pai-trust-test--sandbox dir
    (should (eq (pai-trust-get dir) 'undecided))))

(ert-deftest pai-trust-has-resources-p ()
  (pai-trust-test--sandbox dir
    (let ((empty (expand-file-name "empty" dir))
          (withres (expand-file-name "withres" dir)))
      (make-directory empty t)
      (make-directory (expand-file-name ".pai/skills" withres) t)
      (should-not (pai-project-has-resources-p empty))
      (should (pai-project-has-resources-p withres)))))

(ert-deftest pai-trust-trusted-resource-less-dir ()
  (pai-trust-test--sandbox dir
    (let ((empty (expand-file-name "empty" dir)))
      (make-directory empty t)
      ;; No resources -> trusted without prompting, even if setting denies.
      (setq pai-settings--global (list :default-project-trust "never"))
      (should (pai-trust-trusted-p empty)))))

(ert-deftest pai-trust-trusted-respects-default-setting ()
  (pai-trust-test--sandbox dir
    (let ((proj (expand-file-name "proj" dir)))
      (make-directory (expand-file-name ".pai/skills" proj) t)
      (setq pai-settings--global (list :default-project-trust "always"))
      (should (pai-trust-trusted-p proj))
      (setq pai-settings--global (list :default-project-trust "never"))
      (should-not (pai-trust-trusted-p proj)))))

(ert-deftest pai-trust-trusted-ask-calls-prompt-and-persists ()
  (pai-trust-test--sandbox dir
    (let* ((proj (expand-file-name "proj" dir))
           (called nil)
           (prompt-fn (lambda (_d) (setq called t) (list :trusted t :remember t))))
      (make-directory (expand-file-name ".pai/skills" proj) t)
      (setq pai-settings--global (list :default-project-trust "ask"))
      (should (pai-trust-trusted-p proj prompt-fn))
      (should called)
      ;; :remember t -> persisted as an explicit yes decision.
      (should (eq (pai-trust-get proj) 'yes)))))

(ert-deftest pai-trust-trusted-ask-headless-denies ()
  (pai-trust-test--sandbox dir
    (let ((proj (expand-file-name "proj" dir)))
      (make-directory (expand-file-name ".pai/skills" proj) t)
      (setq pai-settings--global (list :default-project-trust "ask"))
      (should-not (pai-trust-trusted-p proj)))))

(ert-deftest pai-trust-command-yes-sets-trust ()
  (pai-trust-test--sandbox dir
    (let ((r (pai-trust-command "yes" (list :cwd dir))))
      (should (string-match-p "Trusted" (plist-get r :message)))
      (should (eq (pai-trust-get dir) 'yes)))))

(ert-deftest pai-trust-command-empty-shows-decision ()
  (pai-trust-test--sandbox dir
    (let ((r (pai-trust-command "" (list :cwd dir))))
      (should (string-match-p "undecided" (plist-get r :message))))))

(ert-deftest pai-trust-command-registered ()
  (should (pai-command-get "trust")))

(provide 'pai-trust-test)
;;; pai-trust-test.el ends here
