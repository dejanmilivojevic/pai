;;; pai-extension-scope-test.el --- Extension instance boundaries -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pai)
(require 'pai-faux)

(defmacro pai-scope-test--with-projects (&rest body)
  "Run BODY with isolated home state and projects `project-a' and `project-b'."
  (declare (indent 0))
  `(let* ((root (make-temp-file "pai-extension-scope-" t))
          (home (expand-file-name "home" root))
          (project-a (file-name-as-directory (expand-file-name "a" root)))
          (project-b (file-name-as-directory (expand-file-name "b" root)))
          (pai-directory (expand-file-name ".pai" home))
          (pai-default-model "faux")
          (process-environment (copy-sequence process-environment))
          (pai--commands (copy-hash-table (default-value 'pai--commands)))
          (pai--tools (copy-hash-table (default-value 'pai--tools)))
          (pai--providers (copy-hash-table (default-value 'pai--providers)))
          (pai--models (copy-hash-table (default-value 'pai--models)))
          (pai--extensions nil)
          (pai--ext-handlers (make-hash-table :test 'eq))
          (pai--ext-loaded-files (make-hash-table :test 'equal))
          (pai--ext-message-renderers nil)
          (pai--ext-entry-renderers nil)
          (pai--ext-markdown-transformers nil)
          (pai--ext-autocomplete-providers nil)
          (pai--ext-shortcuts nil)
          (pai--ext-flags nil)
          (pai-provider-env-keys nil)
          (pai-auth-oauth-handlers nil)
          (pai-providers--settings-providers (make-hash-table :test 'equal))
          (pai-providers--settings-models (make-hash-table :test 'equal))
          (pai-providers--settings-env (make-hash-table :test 'equal))
          (pai-providers--discovered (make-hash-table :test 'equal))
          (pai-settings--global nil)
          (pai-settings--project nil)
          (pai-settings--project-dir nil)
          (pai-mode-map (copy-keymap pai-mode-map))
          (buffers nil)
          (trusted t))
     (unwind-protect
         (progn
           (make-directory home t)
           (make-directory project-a t)
           (make-directory project-b t)
           (setenv "HOME" home)
           (pai-faux-register)
           (cl-letf (((symbol-function 'pai-trust-trusted-p)
                      (lambda (&rest _args) trusted))
                     ((symbol-function 'pai-models-refresh)
                      (lambda () nil)))
             ,@body))
       (dolist (buffer buffers)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory root t))))

(defun pai-scope-test--write-extension (file name label key &optional shared)
  "Write a real extension FILE registering NAME, LABEL, and KEY.
When SHARED is non-nil, also override the common registry names and shortcut."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert ";;; -*- lexical-binding: t; -*-\n")
    (prin1
     `(pai-register-extension
       (lambda (api)
         (let ((label ,label)
               (names ',(if shared (list name "scope-shared") (list name))))
           (dolist (name names)
             (pai-ext-register-command
              api name :handler (lambda (_args _ctx) (list :message label)))
             (pai-ext-register-tool
              api (list :name name :description label
                        :parameters (pai-object-schema nil)
                        :execute (lambda (_args _ctx _update done)
                                   (funcall done (pai-tool-ok-result label)))))
             (pai-ext-register-provider
              api (list :id name
                        :stream (lambda (model context options emit)
                                  (let ((pai-faux-responses (list (list :text label)))
                                        (pai-faux-last-context nil)
                                        (pai-faux-last-options nil))
                                    (pai-faux-stream model context options emit))))))
           (pai-ext-on
            api 'context
            (lambda (event _ctx)
              (list :messages (append (plist-get event :messages)
                                      (list (pai-system-message label))))))
           (pai-ext-register-shortcut api ,key (lambda () (interactive) label))
           ,@(when shared
               '((pai-ext-register-shortcut
                  api "C-c C-z" (lambda () (interactive) label))))))
       ,name)
     (current-buffer))
    (insert "\n"))
  file)

(defun pai-scope-test--setup (directory)
  "Return a fresh buffer set up through the real entry point for DIRECTORY."
  (let ((buffer (generate-new-buffer " *pai-scope*")))
    (condition-case err
        (progn
          (with-current-buffer buffer (pai--setup directory))
          buffer)
      (error (kill-buffer buffer) (signal (car err) (cdr err))))))

(defun pai-scope-test--command (name)
  "Return the observable message from slash command NAME."
  (plist-get (plist-get (pai-command-dispatch (concat "/" name) nil) :result)
             :message))

(defun pai-scope-test--tool (name)
  "Execute registered tool NAME and return its text result."
  (let (result)
    (funcall (plist-get (pai-tool-get name) :execute)
             nil nil nil (lambda (value) (setq result value)))
    (pai-content-text (plist-get result :content))))

(defun pai-scope-test--provider (name)
  "Stream a response through registered provider NAME and return its text."
  (let* ((model (pai-make-model :id name :provider name :api 'faux))
         (message (pai-provider-stream-sync
                   model (pai-context nil) '(:api-key "fixture") 1)))
    (should (pai-assistant-message-p message))
    (pai-content-text (pai-message-content message))))

(defun pai-scope-test--assert-registration (name label)
  "Assert NAME behaves as LABEL through commands, tools, and providers."
  (should (equal (pai-scope-test--command name) label))
  (should (equal (pai-scope-test--tool name) label))
  (should (equal (pai-scope-test--provider name) label)))

(defun pai-scope-test--assert-absent (name)
  "Assert NAME is unavailable through every fixture registry."
  (should-not (plist-get (pai-command-dispatch (concat "/" name) nil) :handled))
  (should-not (pai-tool-get name))
  (should-not (pai-provider name)))

(defun pai-scope-test--context-labels ()
  "Run real reducing hooks and return the contributed message texts."
  (mapcar #'pai-message-content (pai-ext-run-context nil nil)))

(defun pai-scope-test--shortcut (key)
  "Invoke the extension command bound to KEY in the current local map."
  (let ((command (lookup-key (current-local-map) (kbd key))))
    (should (commandp command))
    (call-interactively command)))

(ert-deftest pai-extension-scope-home-and-project-registries ()
  "Home loads per instance; project overrides do not leak to peers or globals."
  (pai-scope-test--with-projects
    (pai-scope-test--write-extension
     (expand-file-name "extensions/home.el" pai-directory)
     "scope-home" "home" "C-c 1" t)
    (pai-scope-test--write-extension
     (expand-file-name ".pai/extensions/a.el" project-a)
     "scope-a" "a" "C-c 2" t)
    (pai-scope-test--write-extension
     (expand-file-name ".pai/extensions/b.el" project-b)
     "scope-b" "b" "C-c 3" t)
    ;; This closure must remain connected to the original lexical binding when
    ;; the global baseline is copied into either instance.
    (let ((calls 0))
      (pai-register-command "scope-baseline"
                            :handler (lambda (_args _ctx)
                                       (list :message (cl-incf calls))))
      (let ((a (car (push (pai-scope-test--setup project-a) buffers)))
            (b (car (push (pai-scope-test--setup project-b) buffers))))
        (with-current-buffer a
          (pai-scope-test--assert-registration "scope-home" "home")
          (pai-scope-test--assert-registration "scope-shared" "a")
          (pai-scope-test--assert-registration "scope-a" "a")
          (pai-scope-test--assert-absent "scope-b")
          (should (equal (pai-scope-test--context-labels) '("home" "a")))
          (should (equal (pai-scope-test--shortcut "C-c 1") "home"))
          (should (equal (pai-scope-test--shortcut "C-c C-z") "a"))
          (should-not (lookup-key (current-local-map) (kbd "C-c 3")))
          (should (= (pai-scope-test--command "scope-baseline") 1)))
        (with-current-buffer b
          (pai-scope-test--assert-registration "scope-home" "home")
          (pai-scope-test--assert-registration "scope-shared" "b")
          (pai-scope-test--assert-registration "scope-b" "b")
          (pai-scope-test--assert-absent "scope-a")
          (should (equal (pai-scope-test--context-labels) '("home" "b")))
          (should (equal (pai-scope-test--shortcut "C-c 1") "home"))
          (should (equal (pai-scope-test--shortcut "C-c C-z") "b"))
          (should-not (lookup-key (current-local-map) (kbd "C-c 2")))
          (should (= (pai-scope-test--command "scope-baseline") 2)))
        (should (= calls 2))
        (with-temp-buffer
          (dolist (name '("scope-home" "scope-shared" "scope-a" "scope-b"))
            (pai-scope-test--assert-absent name))
          (should-not (pai-scope-test--context-labels))
          (should (= (pai-scope-test--command "scope-baseline") 3)))
        (should (= calls 3))
        (should-not (lookup-key pai-mode-map (kbd "C-c C-z")))))))

(ert-deftest pai-extension-scope-denied-project-without-home-extensions ()
  "An empty allowed directory list must not fall back to project discovery."
  (pai-scope-test--with-projects
    (setq trusted nil)
    (pai-scope-test--write-extension
     (expand-file-name ".pai/extensions/denied.el" project-a)
     "scope-denied" "denied" "C-c 2" t)
    (should-not (file-directory-p (expand-file-name "extensions" pai-directory)))
    (let ((a (pai-scope-test--setup project-a)))
      (push a buffers)
      (with-current-buffer a
        (pai-scope-test--assert-absent "scope-denied")
        (pai-scope-test--assert-absent "scope-shared")
        (should-not (pai-scope-test--context-labels))
        (should-not (lookup-key (current-local-map) (kbd "C-c 2")))
        (pai-command-dispatch "/reload" (list :buffer a))
        (pai-scope-test--assert-absent "scope-denied")
        (should-not (pai-scope-test--context-labels))))))

(ert-deftest pai-extension-scope-reload-removes-stale-state-only-here ()
  "Reload replaces changed files, drops deleted files, and never doubles hooks."
  (pai-scope-test--with-projects
    (pai-scope-test--write-extension
     (expand-file-name "extensions/home.el" pai-directory)
     "scope-home" "home" "C-c 1" t)
    (let* ((changed (pai-scope-test--write-extension
                     (expand-file-name ".pai/extensions/a.el" project-a)
                     "scope-a" "a-old" "C-c 2" t))
           (deleted (pai-scope-test--write-extension
                     (expand-file-name ".pai/extensions/obsolete.el" project-a)
                     "scope-obsolete" "obsolete" "C-c 4")))
      (pai-scope-test--write-extension
       (expand-file-name ".pai/extensions/b.el" project-b)
       "scope-b" "b" "C-c 3" t)
      (let ((a (car (push (pai-scope-test--setup project-a) buffers)))
            (b (car (push (pai-scope-test--setup project-b) buffers))))
        (with-current-buffer a
          (pai-scope-test--assert-registration "scope-a" "a-old")
          (pai-scope-test--assert-registration "scope-obsolete" "obsolete")
          (should (equal (pai-scope-test--context-labels)
                         '("home" "a-old" "obsolete")))
          (should (equal (pai-scope-test--shortcut "C-c 2") "a-old"))
          (should (equal (pai-scope-test--shortcut "C-c 4") "obsolete")))
        (pai-scope-test--write-extension changed "scope-a-new" "a-new" "C-c 5" t)
        (delete-file deleted)
        (dotimes (_ 2)
          (with-current-buffer a
            (should (plist-get (pai-command-dispatch "/reload" (list :buffer a))
                               :handled))
            (pai-scope-test--assert-registration "scope-home" "home")
            (pai-scope-test--assert-registration "scope-a-new" "a-new")
            (pai-scope-test--assert-registration "scope-shared" "a-new")
            (pai-scope-test--assert-absent "scope-a")
            (pai-scope-test--assert-absent "scope-obsolete")
            (pai-scope-test--assert-absent "scope-b")
            (should (equal (pai-scope-test--context-labels) '("home" "a-new")))
            (should (equal (pai-scope-test--shortcut "C-c C-z") "a-new"))
            (should (equal (pai-scope-test--shortcut "C-c 5") "a-new"))
            (should-not (lookup-key (current-local-map) (kbd "C-c 2")))
            (should-not (lookup-key (current-local-map) (kbd "C-c 4"))))
          (with-current-buffer b
            (pai-scope-test--assert-registration "scope-home" "home")
            (pai-scope-test--assert-registration "scope-b" "b")
            (pai-scope-test--assert-registration "scope-shared" "b")
            (pai-scope-test--assert-absent "scope-a-new")
            (should (equal (pai-scope-test--context-labels) '("home" "b")))
            (should (equal (pai-scope-test--shortcut "C-c C-z") "b"))
            (should-not (lookup-key (current-local-map) (kbd "C-c 5")))))
        ;; Removing the last project override restores home, rather than the
        ;; stale value that happened to be present at the previous reload.
        (delete-file changed)
        (with-current-buffer a
          (pai-command-dispatch "/reload" (list :buffer a))
          (pai-scope-test--assert-registration "scope-shared" "home")
          (pai-scope-test--assert-absent "scope-a-new")
          (should (equal (pai-scope-test--context-labels) '("home")))
          (should (equal (pai-scope-test--shortcut "C-c C-z") "home"))
          (should-not (lookup-key (current-local-map) (kbd "C-c 5"))))
        (with-current-buffer b
          (pai-scope-test--assert-registration "scope-shared" "b")
          (should (equal (pai-scope-test--context-labels) '("home" "b"))))
        (with-temp-buffer
          (dolist (name '("scope-home" "scope-shared" "scope-a" "scope-a-new"
                          "scope-obsolete" "scope-b"))
            (pai-scope-test--assert-absent name))
          (should-not (pai-scope-test--context-labels)))))))

(ert-deftest pai-extension-scope-entrypoint-selects-project-instance ()
  "Opening a project reuses its instance, not whichever pai buffer is first."
  (pai-scope-test--with-projects
    (pai-scope-test--write-extension
     (expand-file-name ".pai/extensions/a.el" project-a)
     "scope-a" "a" "C-c 2" t)
    (pai-scope-test--write-extension
     (expand-file-name ".pai/extensions/b.el" project-b)
     "scope-b" "b" "C-c 3" t)
    (save-window-excursion
      (let ((a (pai project-a)))
        (push a buffers)
        (let ((b (pai project-b)))
          (unless (memq b buffers) (push b buffers))
          (should-not (eq a b))
          (should (eq (current-buffer) b))
          (should (equal (pai-scope-test--command "scope-shared") "b"))
          (should (eq (pai (expand-file-name "./" project-a)) a))
          (should (eq (current-buffer) a))
          (should (equal (pai-scope-test--command "scope-shared") "a"))
          (should (eq (pai project-b) b)))))))

(ert-deftest pai-extension-scope-reload-redraws-widgets ()
  "/reload drops widgets; extensions still loaded redraw theirs on `reload'."
  (pai-scope-test--with-projects
    (let ((file (expand-file-name "extensions/wid.el" pai-directory)))
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert "(pai-register-extension (lambda (api) (pai-ext-on api 'reload (lambda (_e ctx) (with-current-buffer (plist-get ctx :buffer) (pai--set-widget \"wid\" \"W\")))))) \"wid\")\n"))
      (let ((a (car (push (pai-scope-test--setup project-a) buffers))))
        (with-current-buffer a
          (pai--set-widget "gone" "stale")   ; from an extension no longer loaded
          (pai-command-dispatch "/reload" (list :buffer a))
          (should (equal (assoc "wid" pai--widgets) '("wid" . "W")))
          (should-not (assoc "gone" pai--widgets)))))))

(provide 'pai-extension-scope-test)
;;; pai-extension-scope-test.el ends here
