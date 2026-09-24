;;; pai-extensions-test.el --- Tests for extension enable/disable -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai)
(require 'pai-ext)

(defmacro pai-extensions-test--sandbox (root &rest body)
  "Run BODY with throwaway global/project settings state rooted at ROOT."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (make-temp-file "pai-ext" t)))
          (pai-directory (expand-file-name "state" ,root))
          (default-directory (expand-file-name "proj/" ,root))
          (pai-settings--global nil)
          (pai-settings--project nil)
          (pai-settings--project-dir (expand-file-name "proj/" ,root)))
     (make-directory pai-directory t)
     (make-directory default-directory t)
     (unwind-protect (progn ,@body) (delete-directory ,root t))))

;;;; Effective enabled state / precedence

(ert-deftest pai-ext-enabled-default-on ()
  "Unknown extensions are enabled by default."
  (pai-extensions-test--sandbox root
    (should (pai-ext-enabled-p "brand-new"))))

(ert-deftest pai-ext-global-disable-respected ()
  "A global disable turns an extension off."
  (pai-extensions-test--sandbox root
    (pai-ext-set-enabled "foo" nil 'global)
    (should-not (pai-ext-enabled-p "foo"))
    (should (eq (pai-ext-override "foo" 'global) 'disabled))))

(ert-deftest pai-ext-project-overrides-global ()
  "A project override wins over the global setting, both directions."
  (pai-extensions-test--sandbox root
    (pai-ext-set-enabled "foo" nil 'global)   ; globally off
    (pai-ext-set-enabled "foo" t 'project)    ; project turns it back on
    (should (pai-ext-enabled-p "foo"))
    (pai-ext-set-enabled "bar" t 'global)     ; globally on (explicit)
    (pai-ext-set-enabled "bar" nil 'project)  ; project turns it off
    (should-not (pai-ext-enabled-p "bar"))))

(ert-deftest pai-ext-clear-override-inherits-global ()
  "Clearing a project override falls back to the global value."
  (pai-extensions-test--sandbox root
    (pai-ext-set-enabled "foo" nil 'global)
    (pai-ext-set-enabled "foo" t 'project)
    (should (pai-ext-enabled-p "foo"))
    (pai-ext-clear-override "foo" 'project)
    (should-not (pai-ext-override "foo" 'project))
    (should-not (pai-ext-enabled-p "foo")))) ; inherits global disable

(ert-deftest pai-ext-enabled-persists ()
  "Overrides round-trip through the settings files across a reload."
  (pai-extensions-test--sandbox root
    (pai-ext-set-enabled "foo" nil 'global)
    (pai-ext-set-enabled "bar" nil 'project)
    ;; Simulate a fresh session: drop in-memory state and reload from disk.
    (setq pai-settings--global nil pai-settings--project nil)
    (pai-settings-load (expand-file-name "proj/" root))
    (should-not (pai-ext-enabled-p "foo"))
    (should-not (pai-ext-enabled-p "bar"))))

;;;; Discovery

(ert-deftest pai-ext-discover-lists-global-and-project ()
  "Discovery returns extensions from both the global and project roots."
  (pai-extensions-test--sandbox root
    (let ((gdir (expand-file-name "extensions" pai-directory))
          (pdir (expand-file-name ".pai/extensions" default-directory)))
      (make-directory (expand-file-name "alpha" gdir) t)
      (with-temp-file (expand-file-name "loose.el" gdir) (insert ";; loose\n"))
      (make-directory (expand-file-name "beta" pdir) t)
      (let* ((found (pai-ext-discover))
             (names (mapcar (lambda (e) (plist-get e :name)) found)))
        (should (member "alpha" names))
        (should (member "loose" names))
        (should (member "beta" names))
        (should (eq (plist-get (seq-find (lambda (e) (equal (plist-get e :name) "alpha")) found)
                               :source)
                    'global))
        (should (eq (plist-get (seq-find (lambda (e) (equal (plist-get e :name) "beta")) found)
                               :source)
                    'project))))))

;;;; Loader gating

(defvar pai-ext-test--on nil)
(defvar pai-ext-test--off nil)

(ert-deftest pai-ext-loader-skips-disabled ()
  "A disabled extension is not loaded; enabled ones still load."
  (pai-extensions-test--sandbox root
    (let ((gdir (expand-file-name "extensions" pai-directory)))
      (make-directory gdir t)
      (with-temp-file (expand-file-name "on.el" gdir)
        (insert "(setq pai-ext-test--on t)\n"))
      (with-temp-file (expand-file-name "off.el" gdir)
        (insert "(setq pai-ext-test--off t)\n"))
      (pai-ext-set-enabled "off" nil 'global)
      (setq pai-ext-test--on nil pai-ext-test--off nil)
      (let ((pai--ext-loaded-files (make-hash-table :test 'equal)))
        (pai-load-extensions (list gdir))
        (should pai-ext-test--on)
        (should-not pai-ext-test--off)))))

(provide 'pai-extensions-test)
;;; pai-extensions-test.el ends here
