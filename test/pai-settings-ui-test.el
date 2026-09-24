;;; pai-settings-ui-test.el --- Tests for pai-settings-ui -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'seq)
(require 'pai)
(require 'pai-settings-ui)

(defmacro pai-settings-ui-test--sandbox (dir &rest body)
  "Run BODY with a throwaway settings state rooted at DIR."
  (declare (indent 1))
  `(let* ((,dir (file-name-as-directory (make-temp-file "pai-set-ui" t)))
          (pai-directory (expand-file-name "state" ,dir))
          (pai-settings--global nil)
          (pai-settings--project nil)
          (pai-settings--project-dir nil))
     (unwind-protect (progn ,@body) (delete-directory ,dir t))))

(defun pai-settings-ui-test--section (id)
  (seq-find (lambda (s) (eq (pai-settings-ui-section-id s) id))
            pai-settings-ui--sections))

(defun pai-settings-ui-test--item (sec-id sub-id key)
  (let* ((sec (pai-settings-ui-test--section sec-id))
         (sub (seq-find (lambda (s) (eq (pai-settings-ui-subsection-id s) sub-id))
                        (pai-settings-ui-section-subsections sec))))
    (seq-find (lambda (i) (equal (pai-settings-ui-item-key i) key))
              (pai-settings-ui-subsection-items sub))))

(defun pai-settings-ui-test--render ()
  "Mount the screen fresh and return its buffer text."
  (let* ((inst (vui-mount (vui-component 'pai-settings-screen) "*pai settings test*"))
         (buf (vui-instance-buffer inst)))
    (with-current-buffer buf (buffer-string))))

(ert-deftest pai-settings-ui-builtins-registered ()
  ;; The built-in tree is registered with the expected section order and a
  ;; representative item of each control type.
  (let ((ids (mapcar #'pai-settings-ui-section-id pai-settings-ui--sections)))
    ;; built-in sections keep this relative order; extensions may add more
    (should (equal '(model session project files)
                   (seq-filter (lambda (id) (memq id '(model session project files)))
                               ids))))
  (should (equal (pai-settings-ui-section-label
                  (pai-settings-ui-test--section 'model))
                 "Model & Reasoning"))
  (should (eq (pai-settings-ui-item-type
               (pai-settings-ui-test--item 'model 'model :model))
              'choice))
  (should (eq (pai-settings-ui-item-type
               (pai-settings-ui-test--item 'session 'context :auto-compact))
              'boolean))
  (should (eq (pai-settings-ui-item-type
               (pai-settings-ui-test--item 'model 'sampling :temperature))
              'number))
  (should (eq (pai-settings-ui-item-type
               (pai-settings-ui-test--item 'files 'actions 'edit-global))
              'action)))

(ert-deftest pai-settings-ui-register-overrides-not-duplicates ()
  ;; Re-registering the same item key replaces the entry rather than appending,
  ;; and doing so does not clobber the parent section/subsection labels.
  (let ((pai-settings-ui--sections (copy-sequence pai-settings-ui--sections)))
    (let ((before (length (pai-settings-ui-subsection-items
                           (seq-find (lambda (s) (eq (pai-settings-ui-subsection-id s) 'model))
                                     (pai-settings-ui-section-subsections
                                      (pai-settings-ui-test--section 'model)))))))
      (pai-settings-ui-register-item
       'model 'model :key :model :type 'string :label "Overridden"
       :get (lambda () "x") :set #'ignore)
      (let ((sub (seq-find (lambda (s) (eq (pai-settings-ui-subsection-id s) 'model))
                           (pai-settings-ui-section-subsections
                            (pai-settings-ui-test--section 'model)))))
        (should (= before (length (pai-settings-ui-subsection-items sub))))
        (should (equal "Overridden"
                       (pai-settings-ui-item-label
                        (pai-settings-ui-test--item 'model 'model :model))))
        ;; labels of the ancestors are untouched by item registration
        (should (equal "Model & Reasoning"
                       (pai-settings-ui-section-label
                        (pai-settings-ui-test--section 'model))))
        (should (equal "Model" (pai-settings-ui-subsection-label sub)))))))

(ert-deftest pai-settings-ui-boolean-item-roundtrips ()
  ;; A boolean item's :set/:get thunks round-trip through pai settings,
  ;; storing :false for off and t for on.
  (pai-settings-ui-test--sandbox dir
    (pai-settings-load nil)
    (let ((item (pai-settings-ui-test--item 'session 'context :auto-compact)))
      (funcall (pai-settings-ui-item-set item) nil)
      (should-not (pai-truthy (funcall (pai-settings-ui-item-get item))))
      (should (eq (pai-settings-get :auto-compact) :false))
      (funcall (pai-settings-ui-item-set item) t)
      (should (pai-truthy (funcall (pai-settings-ui-item-get item))))
      (should (eq (pai-settings-get :auto-compact) t)))))

(ert-deftest pai-settings-ui-number-item-parses-blank-and-value ()
  ;; The number field parser yields nil for blank input and a number otherwise.
  (let ((item (pai-settings-ui-test--item 'model 'sampling :temperature)))
    (should (null (pai-settings-ui--parse item "  ")))
    (should (equal 0.7 (pai-settings-ui--parse item "0.7")))
    (should (equal 42 (pai-settings-ui--parse item "42")))))

(ert-deftest pai-settings-ui-screen-renders-tree ()
  ;; Mounting the screen renders section labels, subsection headings, an item
  ;; label, and an action button.
  (let ((text (pai-settings-ui-test--render)))
    (should (string-match-p "Model & Reasoning" text))
    (should (string-match-p "Sampling" text))
    (should (string-match-p "Tool execution" text))
    (should (string-match-p "Trust this project" text))
    (should (string-match-p "\\[Edit global settings file\\]" text))))

(ert-deftest pai-settings-ui-extension-section-appears ()
  ;; An extension-registered section and item show up on the screen, and the
  ;; global registry is left untouched (registration is isolated here).
  (let ((pai-settings-ui--sections (copy-sequence pai-settings-ui--sections)))
    (pai-settings-ui-register-section 'demo-ext "Demo Extension" 999)
    (pai-settings-ui-register-subsection 'demo-ext 'demo "Demo")
    (pai-settings-ui-register-item
     'demo-ext 'demo
     :key :demo-flag :type 'boolean :label "Demo flag"
     :get (lambda () t) :set #'ignore)
    (let ((text (pai-settings-ui-test--render)))
      (should (string-match-p "Demo Extension" text))
      (should (string-match-p "Demo flag" text))))
  ;; outside the let, the extension section is gone again
  (should-not (pai-settings-ui-test--section 'demo-ext)))

(ert-deftest pai-settings-ui-dynamic-items-render ()
  ;; A dynamic subsection generates its rows at render time.
  (let ((pai-settings-ui--sections (copy-sequence pai-settings-ui--sections)))
    (pai-settings-ui-register-section 'dyn "Dyn Section" 998)
    (pai-settings-ui-register-dynamic-items
     'dyn 'rows
     (lambda ()
       (list (list :key :a :type 'boolean :label "Alpha row"
                   :get (lambda () t) :set #'ignore)
             (list :key :b :type 'boolean :label "Beta row"
                   :get (lambda () nil) :set #'ignore))))
    (let ((text (pai-settings-ui-test--render)))
      (should (string-match-p "Alpha row" text))
      (should (string-match-p "Beta row" text))))
  (should-not (pai-settings-ui-test--section 'dyn)))

(ert-deftest pai-settings-ui-scoped-models-rows ()
  ;; One row per role, extension roles included; the row edits the role.
  (let ((pai-model-roles (copy-sequence pai-model-roles))
        (pai-model-role-fallbacks (copy-alist pai-model-role-fallbacks))
        (pai-model-role-descriptions (copy-alist pai-model-role-descriptions)))
    (pai-settings-ui-test--sandbox dir
      (pai-register-model-role :x-demo :task "Demo role for tests")
      (let* ((rows (pai-settings-ui--scoped-model-items))
             (demo (seq-find (lambda (r) (equal (plist-get r :label) "x-demo")) rows))
             (model (pai-model-key (car (pai-models)))))
        (should (equal (mapcar (lambda (r) (plist-get r :label)) rows)
                       (mapcar #'pai-model-role-name pai-model-roles)))
        (should (string-match-p "Demo role for tests" (plist-get demo :doc)))
        (should (string-match-p "inherit" (plist-get demo :doc)))
        (should (equal (funcall (plist-get demo :get)) "inherit"))
        (should (member model (plist-get demo :choices)))
        (funcall (plist-get demo :set) model)
        (should (equal (pai-scoped-model-explicit :x-demo) model))
        (funcall (plist-get demo :set) "inherit")
        (should-not (pai-scoped-model-explicit :x-demo)))
      (let ((text (pai-settings-ui-test--render)))
        (should (string-match-p "Scoped models (per role)" text))
        (should (string-match-p "x-demo" text))
        (should (string-match-p "Subagents and task tools" text))))))

(ert-deftest pai-settings-ui-custom-item-render ()
  ;; A `custom' item renders whatever vnode its :render returns.
  (let ((pai-settings-ui--sections (copy-sequence pai-settings-ui--sections)))
    (pai-settings-ui-register-section 'cust "Cust" 997)
    (pai-settings-ui-register-item
     'cust 'x :key :c :type 'custom
     :render (lambda (_refresh) (vui-text "CUSTOM-ROW-XYZ")))
    (let ((text (pai-settings-ui-test--render)))
      (should (string-match-p "CUSTOM-ROW-XYZ" text))))
  (should-not (pai-settings-ui-test--section 'cust)))

(ert-deftest pai-settings-ui-edits-target-session-buffer ()
  ;; Edits in the screen write to the originating session buffer's buffer-local
  ;; settings (which are per-instance), not the global bindings.
  ;; Sandboxed like every other test here: `pai-settings-set' persists, so
  ;; without an isolated `pai-directory' this would write the buffer-local
  ;; plist over the real ~/.pai/settings.json of whoever runs the suite.
  (pai-settings-ui-test--sandbox dir
    (let ((sb (get-buffer-create " *pai-ui-target-test*")))
      (unwind-protect
          (progn
            (with-current-buffer sb
              (pai-mode)
              (pai-ext-initialize-instance)
              (pai-settings-set :auto-compact t 'global))
            (with-current-buffer sb (pai-settings-ui-open))
            (with-current-buffer (get-buffer "*pai settings*")
              (should (eq pai-settings-ui--target-buffer sb))
              (goto-char (point-min))
              (search-forward "Auto-compact") (search-forward "[") (backward-char 1)
              (vui-activate)
              (dolist (tm (copy-sequence timer-list)) (ignore-errors (timer-event-handler tm))))
            ;; the session's buffer-local setting flipped
            (with-current-buffer sb
              (should (eq (pai-settings-get :auto-compact) :false)))
            ;; the global default binding is untouched
            (should (null (default-value 'pai-settings--global))))
        (when (get-buffer "*pai settings*") (kill-buffer "*pai settings*"))
        (kill-buffer sb)))))

(provide 'pai-settings-ui-test)
;;; pai-settings-ui-test.el ends here
