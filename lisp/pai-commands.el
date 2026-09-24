;;; pai-commands.el --- Slash command registry -*- lexical-binding: t; -*-

;;; Commentary:

;; Registry and dispatch for slash commands (e.g. `/help', `/model').  Commands
;; come from three sources: built-ins here, extensions (via
;; `pai-ext-register-command'), skills (registered as `/skill:name', so a
;; skill never shadows or looks like a command) and skill bundles
;; (`/bundle:name', every skill whose front-matter says `bundle: name').  Port
;; of packages/coding-agent/src/core/slash-commands.ts.
;;
;; A command handler is `(lambda (ARGS CTX))' where ARGS is the argument string
;; and CTX the extension/runtime context.  Its return value is interpreted by
;; the caller (typically the UI): a plist may carry `:message' (text to show)
;; or `:send' (text to send to the agent as a user message).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'pai-tools)
(require 'pai-skills)

(defvar pai--commands (make-hash-table :test 'equal)
  "Hash table mapping slash-command name (string, no slash) to a command plist.")

(defvar pai-command--positional-completers (make-hash-table :test 'eq :weakness 'key)
  "Completion functions that know the argument position (see
`pai-command-completion-tree').  Others only complete the first argument.")

(cl-defun pai-register-command (name &key description handler arg-completions
                                     (arg-positional nil positional-given)
                                     (source 'builtin))
  "Register slash command NAME with DESCRIPTION and HANDLER.
ARG-COMPLETIONS, if given, is a function of the current prefix returning
completion candidates.  It completes only the first argument unless
ARG-POSITIONAL is non-nil (it then reads `pai-command-arg-words' and
returns what fits the position); functions made by
`pai-command-completion-tree' are positional by default.  SOURCE marks
the origin.  Return the command plist."
  (let ((cmd (list :name name :description (or description "")
                   :handler handler :arg-completions arg-completions
                   :arg-positional (if positional-given
                                       arg-positional
                                     (and arg-completions
                                          (gethash arg-completions
                                                   pai-command--positional-completers)
                                          t))
                   :source source)))
    (puthash name cmd pai--commands)
    cmd))

(defvar pai--input-marker)

(defun pai-command-arg-words ()
  "Return the argument words typed before the one being completed.
In a pai input area holding \"/cmd a b pre\" with point after \"pre\",
return (\"a\" \"b\").  An `:arg-completions' function receives only the
word at point; it calls this to complete later arguments by position.
Return nil outside a pai input area."
  (when (and (boundp 'pai--input-marker) (markerp pai--input-marker)
             (eq (marker-buffer pai--input-marker) (current-buffer))
             (>= (point) pai--input-marker))
    (let ((words (split-string (buffer-substring-no-properties pai--input-marker (point))
                               "[ \t]+")))
      ;; drop "/cmd" and the word being completed (possibly empty)
      (butlast (cdr words)))))

(defun pai-command--tree-nodes (tree)
  "Return the node list of TREE, calling it when it is a function.
A function node inside the list is expanded in place too."
  (let ((nodes (if (functionp tree) (ignore-errors (funcall tree)) tree)))
    (apply #'append
           (mapcar (lambda (n) (if (and (functionp n) (not (stringp n)))
                                   (ignore-errors (funcall n))
                                 (list n)))
                   nodes))))

(defun pai-command--tree-walk (tree words)
  "Walk TREE along WORDS; return (CANDIDATES . LINE-WORDS).
LINE-WORDS is non-nil-able list: when completion reached a `(:line ...)'
node, the words typed since it (they are one argument that may contain
spaces), else the symbol `none'.  See `pai-command-tree-candidates'."
  (let ((nodes (pai-command--tree-nodes tree))
        (rest nil) (dead nil) (line nil) (line-words 'none))
    (dolist (w words)
      (cond
       (dead nil)
       (line (setq line-words (append line-words (list w))))
       (rest nil)                       ; free text and flags: stay
       (t
        (let ((rest-node (seq-find (lambda (n) (and (consp n) (eq (car n) :rest))) nodes))
              (line-node (seq-find (lambda (n) (and (consp n) (eq (car n) :line))) nodes))
              (hit (seq-find (lambda (n) (or (equal n w) (and (consp n) (equal (car n) w))))
                             nodes)))
          (cond
           ((consp hit) (setq nodes (pai-command--tree-nodes (cdr hit))))
           (hit (setq nodes nil dead t))
           (line-node (setq line (cdr line-node) line-words (list w)))
           (rest-node (setq rest (cdr rest-node) nodes nil))
           (t (setq nodes nil dead t)))))))
    (cond
     (dead (cons nil 'none))
     (line (cons (pai-command--tree-nodes line) line-words))
     (rest (cons (seq-remove (lambda (f) (member f words)) rest) 'none))
     (t
      (let ((line-node (seq-find (lambda (n) (and (consp n) (eq (car n) :line))) nodes)))
        (cons (delete-dups
               (apply #'append
                      (mapcar (lambda (n)
                                (cond ((stringp n) (list n))
                                      ((and (consp n) (eq (car n) :rest)) (cdr n))
                                      ((and (consp n) (eq (car n) :line))
                                       (pai-command--tree-nodes (cdr n)))
                                      ((and (consp n) (stringp (car n))) (list (car n)))))
                              nodes)))
              (if line-node nil 'none)))))))

(defun pai-command-tree-candidates (tree words)
  "Return the words TREE offers after the typed argument WORDS.
TREE is a list of nodes for one argument position:
  \"word\"            a word with nothing after it;
  (\"word\" . SUBTREE) a word followed by SUBTREE (a tree, or a function
                     returning one, called when needed);
  FUNCTION           called with no arguments; returns more nodes (e.g. ids);
  (:rest W...)       free text from here on, with the words W offered at
                     every position until each was typed (flags);
  (:line . NODES)    the rest of the line is ONE argument that may contain
                     spaces (e.g. a task name); NODES (strings, or a function
                     returning them) are its candidates.
A typed word that matches nothing ends completion (no candidates)."
  (car (pai-command--tree-walk tree words)))

(defun pai-command-completion-tree (tree)
  "Return an `:arg-completions' function completing arguments by TREE.
See `pai-command-tree-candidates' for TREE.  Every level completes, so
`/cmd a b c' offers what may follow `a b'.  Candidates of a `(:line ...)'
node are matched against everything typed since it (case-insensitively);
the input completion then replaces that whole text (see
`pai-arg-completion-at-point')."
  (pai-command--positional
   (lambda (prefix)
    (let* ((walk (pai-command--tree-walk tree (pai-command-arg-words)))
           (typed (if (listp (cdr walk))
                      (string-join (append (cdr walk) (list prefix)) " ")
                    prefix))
           (completion-ignore-case (listp (cdr walk))))
      (seq-filter (lambda (c) (string-prefix-p typed c completion-ignore-case))
                  (car walk))))))

(defun pai-command--positional (fn)
  "Mark completion function FN as position-aware and return it."
  (puthash fn t pai-command--positional-completers)
  fn)

(defun pai-unregister-command (name)
  "Remove the command named NAME."
  (remhash name pai--commands))

(defun pai-command-get (name)
  "Return the command plist named NAME, or nil."
  (gethash name pai--commands))

(defun pai-commands-all ()
  "Return all registered command plists, sorted by name."
  (sort (hash-table-values pai--commands)
        (lambda (a b) (string< (plist-get a :name) (plist-get b :name)))))

(defun pai-command-names ()
  "Return a sorted list of command names."
  (sort (hash-table-keys pai--commands) #'string<))

(defun pai-command-input-p (input)
  "Return non-nil if INPUT looks like a slash command."
  (string-match-p "\\`/[A-Za-z0-9]" (string-trim-left input)))

(defun pai-command-parse (input)
  "Parse INPUT of the form \"/name args\" into (NAME . ARGS).
Return nil when INPUT is not a slash command."
  (let ((s (string-trim-left input)))
    (when (string-match "\\`/\\([A-Za-z0-9_-]+\\(?::[A-Za-z0-9_-]+\\)?\\)\\(?:[ \t]+\\|\\'\\)\\(\\(?:.\\|\n\\)*\\)\\'" s)
      (cons (match-string 1 s) (string-trim (match-string 2 s))))))

(defun pai-command-dispatch (input ctx)
  "Dispatch slash-command INPUT with CTX.
Return (:handled t :result R) when a command ran, (:handled nil :name N) for an
unknown command, or nil when INPUT is not a command."
  (let ((parsed (pai-command-parse input)))
    (when parsed
      (let ((cmd (pai-command-get (car parsed))))
        (if cmd
            (list :handled t :name (car parsed)
                  :result (funcall (plist-get cmd :handler) (cdr parsed) ctx))
          (list :handled nil :name (car parsed)))))))

;;;; Skills as commands

(defconst pai-skill-command-prefix "skill:"
  "Prefix of skill slash commands: skill NAME is invoked as `/skill:NAME'.")

(defun pai-skill-command-name (skill-name)
  "Return the slash-command name (no slash) of SKILL-NAME."
  (concat pai-skill-command-prefix skill-name))

(defun pai-skill-command-message (skill args)
  "Return the user message text that invokes SKILL with ARGS.
The skill body is wrapped in a <skill> block naming its file, so relative
references in it resolve; ARGS, when given, follow it as the user's request."
  (let ((path (plist-get skill :path)))
    (concat (format "<skill name=\"%s\" location=\"%s\">\n" (plist-get skill :name)
                    (abbreviate-file-name path))
            (format "References are relative to %s.\n\n"
                    (abbreviate-file-name (file-name-directory path)))
            (string-trim (or (plist-get skill :body) ""))
            "\n</skill>"
            (let ((a (string-trim (or args ""))))
              (if (string-empty-p a) "" (concat "\n\n" a))))))

(defun pai-commands-register-skills (skills)
  "Register each skill in SKILLS as a `/skill:NAME' command.
Running it sends the skill's instructions, followed by any arguments, as a
user message.  Skills hidden from the model (`disable-model-invocation')
are registered too: invoking them by hand is their purpose.  Return the
registered command names."
  (let ((names '()))
    (dolist (skill skills)
      (let ((name (pai-skill-command-name (plist-get skill :name))))
        (pai-register-command
         name
         :description (plist-get skill :description)
         :source 'skill
         :handler (lambda (args _ctx) (list :send (pai-skill-command-message skill args))))
        (push name names)))
    (nreverse names)))

(defun pai-commands-unregister-skills ()
  "Remove every registered skill and bundle command (before re-registering them)."
  (dolist (cmd (pai-commands-all))
    (when (memq (plist-get cmd :source) '(skill bundle))
      (pai-unregister-command (plist-get cmd :name)))))

(defun pai-skill-bundles (skills)
  "Return an alist (BUNDLE . SKILLS) from the `bundle:' front-matter of SKILLS.
A skill may name several bundles, separated by commas."
  (let ((out '()))
    (dolist (skill skills)
      (let ((names (plist-get skill :bundles)))
        (dolist (b names)
          (setf (alist-get b out nil nil #'equal)
                (append (alist-get b out nil nil #'equal) (list skill))))))
    (nreverse out)))

(defun pai-commands-register-bundles (skills)
  "Register `/bundle:NAME' for each bundle among SKILLS; return the names.
Running it sends every skill of the bundle, followed by any arguments."
  (let ((names '()))
    (dolist (b (pai-skill-bundles skills))
      (let ((name (concat "bundle:" (car b))) (members (cdr b)))
        (pai-register-command
         name
         :description (format "Skill bundle: %s"
                              (mapconcat (lambda (s) (plist-get s :name)) members ", "))
         :source 'bundle
         :handler (lambda (args _ctx)
                    (list :send
                          (concat (mapconcat (lambda (s) (pai-skill-command-message s nil))
                                             members "\n\n")
                                  (let ((a (string-trim (or args ""))))
                                    (if (string-empty-p a) "" (concat "\n\n" a)))))))
        (push name names)))
    (nreverse names)))

;;;; Built-in commands

(defun pai-commands--help (_args _ctx)
  "Return a help listing of all commands."
  (list :message
        (concat "Available commands:\n"
                (mapconcat (lambda (c) (format "  /%s — %s"
                                               (plist-get c :name)
                                               (plist-get c :description)))
                           (pai-commands-all) "\n"))))

(defun pai-commands--tools (_args _ctx)
  "Return a listing of registered tools."
  (list :message
        (concat "Tools:\n"
                (mapconcat (lambda (tool) (format "  %s%s — %s"
                                                  (plist-get tool :name)
                                                  (if (and (fboundp 'pai-tool-deferred-p)
                                                           (pai-tool-deferred-p tool))
                                                      " [deferred]" "")
                                                  (plist-get tool :description)))
                           (pai-tools-all) "\n"))))

(defun pai-commands--skills (_args _ctx)
  "Return a listing of discovered skills."
  (let ((skills (pai-discover-skills)))
    (list :message
          (if skills
              (concat "Skills:\n"
                      (mapconcat (lambda (s) (format "  /%s — %s"
                                                     (plist-get s :name)
                                                     (plist-get s :description)))
                                 skills "\n"))
            "No skills found."))))

(defun pai-commands-register-builtins ()
  "Register the source-agnostic built-in commands."
  (pai-register-command "help" :description "List available commands" :handler #'pai-commands--help)
  (pai-register-command "tools" :description "List registered tools" :handler #'pai-commands--tools)
  (pai-register-command "skills" :description "List discovered skills" :handler #'pai-commands--skills))

(pai-commands-register-builtins)

(provide 'pai-commands)
;;; pai-commands.el ends here
