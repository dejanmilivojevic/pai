;;; pai-ext-test.el --- Tests for prompt, skills, commands, extensions -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai-core)
(require 'pai-prompt)
(require 'pai-skills)
(require 'pai-commands)
(require 'pai-ext)
(require 'pai-tools-builtin)

;;;; System prompt

(ert-deftest pai-prompt-sections-and-order ()
  (let* ((prompt (pai-build-system-prompt
                  :cwd "/tmp/proj"
                  :tools (list (pai-tool-get "bash") (pai-tool-get "read"))
                  :context-files '(("AGENTS.md" . "be nice"))
                  :addendum "extra note"))
         (pre (string-match "<preamble>" prompt))
         (tools (string-match "<tools>" prompt))
         (rules (string-match "<rules>" prompt))
         (proj (string-match "<project_context>" prompt))
         (cwd (string-match "<cwd>" prompt))
         (add (string-match "<addendum>" prompt)))
    (should (and pre tools rules proj cwd add))
    ;; ordering
    (should (< pre tools rules proj cwd add))
    (should (string-match-p "be nice" prompt))
    (should (string-match-p "/tmp/proj" prompt))
    (should (string-match-p "bash" prompt))))

(ert-deftest pai-prompt-extra-sections ()
  (let ((prompt (pai-build-system-prompt :sections '(:memory "remember this"))))
    (should (string-match-p "<memory>\nremember this\n</memory>" prompt))))

;;;; Skills

(ert-deftest pai-skills-parse-frontmatter ()
  (let ((parsed (pai-skills--parse-frontmatter "---\nname: foo\ndescription: does foo\n---\nBody here")))
    (should (equal (cdr (assoc "name" (car parsed))) "foo"))
    (should (equal (cdr (assoc "description" (car parsed))) "does foo"))
    (should (equal (string-trim (cdr parsed)) "Body here"))))

(ert-deftest pai-skills-discover-and-section ()
  (let ((dir (file-name-as-directory (make-temp-file "pai-skills" t))))
    (unwind-protect
        (progn
          (let ((skill-dir (expand-file-name "db" dir)))
            (make-directory skill-dir)
            (with-temp-file (expand-file-name "SKILL.md" skill-dir)
              (insert "---\nname: db\ndescription: database helper\n---\n# DB\ninstructions")))
          (with-temp-file (expand-file-name "hidden.md" dir)
            (insert "---\nname: hidden\ndescription: only slash\ndisable-model-invocation: true\n---\nbody"))
          (let* ((skills (pai-discover-skills (list dir)))
                 (names (mapcar (lambda (s) (plist-get s :name)) skills)))
            (should (member "db" names))
            (should (member "hidden" names))
            (let ((section (pai-skills-prompt-section skills)))
              (should (string-match-p "<name>db</name>" section))
              ;; disabled skill excluded from the model-facing section
              (should-not (string-match-p "hidden" section)))))
      (delete-directory dir t))))

(ert-deftest pai-skills-discover-skips-hidden-directories ()
  "Skills under dot-directories (.git, .runs, ...) are not discovered."
  (let ((dir (file-name-as-directory (make-temp-file "pai-skills" t))))
    (unwind-protect
        (progn
          (dolist (sub '("visible" ".hidden/nested"))
            (let ((skill-dir (expand-file-name sub dir)))
              (make-directory skill-dir t)
              (with-temp-file (expand-file-name "SKILL.md" skill-dir)
                (insert (format "---\nname: %s\ndescription: d\n---\nbody"
                                (file-name-nondirectory sub))))))
          (let ((names (mapcar (lambda (s) (plist-get s :name))
                               (pai-discover-skills (list dir)))))
            (should (member "visible" names))
            (should-not (member "nested" names))))
      (delete-directory dir t))))

(ert-deftest pai-skills-invalid-rejected ()
  (let ((dir (file-name-as-directory (make-temp-file "pai-skills" t))))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "bad.md" dir)
            (insert "---\nname: Bad_Name\ndescription: x\n---\nbody"))
          (should (null (pai-discover-skills (list dir)))))
      (delete-directory dir t))))

;;;; Commands

(ert-deftest pai-commands-parse ()
  (should (equal (pai-command-parse "/model gpt-4o") '("model" . "gpt-4o")))
  (should (equal (pai-command-parse "/help") '("help" . "")))
  (should (null (pai-command-parse "not a command"))))

(ert-deftest pai-commands-dispatch-help ()
  (let ((res (pai-command-dispatch "/help" nil)))
    (should (plist-get res :handled))
    (should (string-match-p "Available commands" (plist-get (plist-get res :result) :message)))))

(ert-deftest pai-commands-unknown ()
  (let ((res (pai-command-dispatch "/nonexistent-xyz" nil)))
    (should-not (plist-get res :handled))
    (should (equal (plist-get res :name) "nonexistent-xyz"))))

(ert-deftest pai-commands-skill-command ()
  "Skills register as /skill:NAME and send their body, path and arguments."
  (let ((skill (list :name "greetz" :description "d" :body "SKILL BODY\n"
                     :path "/tmp/skills/greetz/SKILL.md")))
    (should (equal (pai-commands-register-skills (list skill)) '("skill:greetz")))
    (unwind-protect
        (progn
          ;; the bare name is not a command
          (should-not (plist-get (pai-command-dispatch "/greetz" nil) :handled))
          (let* ((res (pai-command-dispatch "/skill:greetz" nil))
                 (send (plist-get (plist-get res :result) :send)))
            (should (plist-get res :handled))
            (should (string-match-p "\\`<skill name=\"greetz\" location=\"/tmp/skills/greetz/SKILL.md\">" send))
            (should (string-match-p "References are relative to /tmp/skills/greetz/" send))
            (should (string-match-p "SKILL BODY\n</skill>\\'" send)))
          (let ((send (plist-get (plist-get (pai-command-dispatch "/skill:greetz  say hi to Ana " nil)
                                            :result)
                                 :send)))
            (should (string-match-p "</skill>\n\nsay hi to Ana\\'" send)))
          (should (eq (plist-get (pai-command-get "skill:greetz") :source) 'skill))
          (pai-commands-unregister-skills)
          (should-not (pai-command-get "skill:greetz"))
          ;; built-in commands survive the unregistering
          (should (pai-command-get "help")))
      (pai-unregister-command "skill:greetz"))))

(ert-deftest pai-command-parse-prefixed-names ()
  (should (equal (pai-command-parse "/skill:db add index") '("skill:db" . "add index")))
  (should (equal (pai-command-parse "/model x") '("model" . "x")))
  (should-not (pai-command-parse "/skill:")))

;;;; Extensions

(ert-deftest pai-ext-register-and-emit ()
  (pai-ext-reset)
  (let ((calls '()))
    (pai-register-extension
     (lambda (pi)
       (pai-ext-on pi 'agent-end (lambda (event _ctx) (push (plist-get event :type) calls)))))
    (pai-ext-emit 'agent-end nil)
    (should (equal calls '(agent-end)))))

(ert-deftest pai-ext-register-same-id-replaces ()
  "Registering an ID twice (e.g. the file loaded twice) must not stack handlers."
  (pai-ext-reset)
  (unwind-protect
      (let ((factory (lambda (api)
                       (pai-ext-on api 'system-prompt-sections (lambda (_e _c) '(:memory "M")))
                       (pai-ext-register-message-renderer api #'ignore))))
        (pai-register-extension factory "memory")
        (pai-register-extension (lambda (api) (pai-ext-on api 'agent-end #'ignore)) "other")
        (pai-register-extension factory "memory")
        (pai-register-extension factory "memory")
        (should (equal (mapcar #'car pai--extensions) '("other" "memory")))
        (should (equal (pai-ext-run-system-prompt-sections nil) '(:memory "M")))
        (should (= (length pai--ext-message-renderers) 1))
        (should (= (length (pai-ext--handlers 'agent-end)) 1)))
    (pai-ext-reset)))

(ert-deftest pai-ext-register-tool-and-command ()
  (pai-ext-reset)
  (pai-register-extension
   (lambda (pi)
     (pai-ext-register-tool pi (list :name "xtool" :description "x"
                                     :parameters (pai-object-schema nil)
                                     :execute (lambda (_a _c _u done) (funcall done (pai-tool-ok-result "x")))))
     (pai-ext-register-command pi "xcmd" :description "x" :handler (lambda (_a _c) (list :message "hi")))))
  (unwind-protect
      (progn
        (should (pai-tool-get "xtool"))
        (should (pai-command-get "xcmd"))
        (should (eq (plist-get (pai-command-get "xcmd") :source) 'extension)))
    (pai-unregister-tool "xtool")
    (pai-unregister-command "xcmd")))

(ert-deftest pai-ext-run-compact-first-result-wins ()
  (pai-ext-reset)
  (let ((calls '()))
    (pai-register-extension
     (lambda (pi)
       (pai-ext-on pi 'compact (lambda (_e _c) (push 'declines calls) nil))
       (pai-ext-on pi 'compact (lambda (e _c) (push 'takes calls)
                                 (list :messages (plist-get e :messages) :strategy "t"
                                       :reason (plist-get e :reason))))
       (pai-ext-on pi 'compact (lambda (_e _c) (push 'never calls) nil))))
    (let ((ret (pai-ext-run-compact (list (pai-user-message "x")) nil :reason 'auto)))
      (should (equal (plist-get ret :strategy) "t"))
      (should (eq (plist-get ret :reason) 'auto))
      (should (equal (reverse calls) '(declines takes))))))

(ert-deftest pai-ext-run-compact-none ()
  (pai-ext-reset)
  (should-not (pai-ext-run-compact (list (pai-user-message "x")) nil)))

(ert-deftest pai-ext-run-context-reducer ()
  (pai-ext-reset)
  (pai-register-extension
   (lambda (pi)
     (pai-ext-on pi 'context
                 (lambda (event _ctx)
                   (list :messages (append (plist-get event :messages)
                                           (list (pai-system-message "injected"))))))))
  (let ((out (pai-ext-run-context (list (pai-user-message "hi")) nil)))
    (should (= (length out) 2))
    (should (pai-system-message-p (nth 1 out)))))

(ert-deftest pai-ext-run-tool-call-block ()
  (pai-ext-reset)
  (pai-register-extension
   (lambda (pi)
     (pai-ext-on pi 'tool-call
                 (lambda (event _ctx)
                   (when (equal (plist-get event :name) "danger")
                     (list :block t :reason "no"))))))
  (should (plist-get (pai-ext-run-tool-call (pai-tool-call "c1" "danger" nil) nil nil) :block))
  (should (null (pai-ext-run-tool-call (pai-tool-call "c2" "safe" nil) nil nil))))

(ert-deftest pai-ext-run-tool-result-override ()
  (pai-ext-reset)
  (pai-register-extension
   (lambda (pi)
     (pai-ext-on pi 'tool-result
                 (lambda (_event _ctx) (list :content (list (pai-text "OVERRIDE")))))))
  (let ((over (pai-ext-run-tool-result (pai-tool-ok-result "orig") nil
                                       (pai-tool-call "c1" "t" nil) nil)))
    (should (equal (pai-content-text (plist-get over :content)) "OVERRIDE"))))

(ert-deftest pai-ext-exec ()
  (let ((res (pai-ext-exec "echo" "hello")))
    (should (= (plist-get res :code) 0))
    (should (string-match-p "hello" (plist-get res :stdout)))))

(ert-deftest pai-ext-load-from-file ()
  (pai-ext-reset)
  (let ((dir (file-name-as-directory (make-temp-file "pai-ext" t))))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "greet.el" dir)
            (insert ";; -*- lexical-binding: t; -*-\n"
                    "(pai-register-extension\n"
                    " (lambda (pi)\n"
                    "   (pai-ext-register-command pi \"loaded-cmd\"\n"
                    "     :description \"loaded\"\n"
                    "     :handler (lambda (_a _c) (list :message \"ok\")))))\n"))
          (pai-load-extensions (list dir))
          (should (pai-command-get "loaded-cmd")))
      (pai-unregister-command "loaded-cmd")
      (delete-directory dir t))))

(ert-deftest pai-ext-apply-shortcuts-keeps-newest-binding ()
  "Re-applying shortcuts preserves load-order precedence and copies the map."
  (pai-ext-reset)
  (let ((shared (make-sparse-keymap))
        (home (lambda () (interactive) 'home))
        (project (lambda () (interactive) 'project)))
    (with-temp-buffer
      (use-local-map shared)
      ;; Extensions load home first, then the project override.
      (pai-ext-register-shortcut nil "C-c C-z" home)
      (pai-ext-register-shortcut nil "C-c C-z" project)
      (should (eq (lookup-key (current-local-map) (kbd "C-c C-z")) project))
      ;; /reload rebuilds the local map, then restores the bindings.
      (use-local-map (copy-keymap shared))
      (should-not (commandp (lookup-key (current-local-map) (kbd "C-c C-z"))))
      (pai-ext-apply-shortcuts)
      (should (eq (lookup-key (current-local-map) (kbd "C-c C-z")) project))
      ;; The shared mode map is never touched.
      (should-not (commandp (lookup-key shared (kbd "C-c C-z"))))))
  (pai-ext-reset))

(provide 'pai-ext-test)
;;; pai-ext-test.el ends here
