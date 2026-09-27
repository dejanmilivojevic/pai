;;; pai-model-resolver.el --- Model resolution, providers, scoped models -*- lexical-binding: t; -*-

;;; Commentary:

;; Resolve provider-qualified model identities and per-role selections
;; (main / task / compact).  Provider configuration and discovery live in
;; `pai-providers'.  Provides the `/model', `/thinking', and `/scoped-models'
;; slash commands.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-core)
(require 'pai-config)
(require 'pai-settings)
(require 'pai-models)
(require 'pai-providers)
(require 'pai-commands)

;;;; Resolution and scoped models

(defun pai-resolve-model (spec &optional fallback)
  "Resolve SPEC (a model id) to a model plist, or FALLBACK.
A provider-qualified SPEC whose provider has not been discovered yet is
discovered on demand (`pai-model-ensure')."
  (or (and spec (pai-model-ensure spec)) fallback))

(defvar pai-model-roles '(:main :task :compact)
  "The scoped-model roles, in display order.
Extensions add roles with `pai-register-model-role'.")

(defvar pai-model-role-fallbacks nil
  "Alist of (ROLE . FALLBACK-ROLE) consulted when ROLE has no model configured.
The chain is followed until a configured role is found; `:main' is the end.")

(defvar pai-model-role-descriptions
  '((:main . "Default for roles left on inherit (the conversation uses Model)")
    (:task . "Subagents and task tools")
    (:compact . "Context summaries when compacting"))
  "Alist of (ROLE . DESCRIPTION) shown by /scoped-models and the settings screen.")

(defconst pai-scoped-model-inherit "inherit"
  "The value that clears a scoped-model role so it inherits its fallback.")

(defun pai-register-model-role (role &optional fallback description)
  "Register scoped-model ROLE (a keyword), falling back to FALLBACK when unset.
FALLBACK is another role keyword (default `:main').  DESCRIPTION says what
the role is used for.  Re-registering updates both.  Return ROLE."
  (unless (keywordp role) (error "Model role must be a keyword: %S" role))
  (unless (memq role pai-model-roles)
    (setq pai-model-roles (append pai-model-roles (list role))))
  (setf (alist-get role pai-model-role-fallbacks) (or fallback :main))
  (when description
    (setf (alist-get role pai-model-role-descriptions) description))
  role)

(defun pai-model-role-name (role)
  "Return ROLE's name without the leading colon."
  (substring (symbol-name role) 1))

(defun pai-scoped-model-explicit (role)
  "Return the model id configured for ROLE itself, or nil when it inherits."
  (plist-get (pai-settings-get :scoped-models) role))

(defun pai-scoped-model-resolution (role)
  "Return (ID . SOURCE) describing where ROLE's model comes from.
SOURCE is the role whose setting supplied ID (ROLE itself when set
explicitly), `:model' for the Model setting, `default' for
`pai-default-model', or nil when nothing is configured -- callers then use
the session's current model and ID is nil."
  (let ((scoped (pai-settings-get :scoped-models))
        (r role) (seen '()) (found nil))
    (while (and r (not found) (not (memq r seen)))
      (push r seen)
      (when (plist-get scoped r) (setq found (cons (plist-get scoped r) r)))
      (setq r (alist-get r pai-model-role-fallbacks)))
    (or found
        (and (plist-get scoped :main) (cons (plist-get scoped :main) :main))
        (and (pai-settings-get :model) (cons (pai-settings-get :model) :model))
        (and pai-default-model (cons pai-default-model 'default))
        (cons nil nil))))

(defun pai-scoped-model-id (role)
  "Return the configured model id for ROLE.
An unset role follows `pai-model-role-fallbacks' (e.g. an extension role to
`:task'), then falls back to the main model."
  (car (pai-scoped-model-resolution role)))

(defun pai-scoped-model-describe (role &optional session-model)
  "Return a short text saying which model ROLE uses and why.
SESSION-MODEL is the model key used when nothing is configured."
  (let* ((res (pai-scoped-model-resolution role))
         (id (car res)) (source (cdr res)))
    (cond ((eq source role) id)
          ((null source) (if session-model
                             (format "inherits → %s (the session's model)" session-model)
                           "inherits the session's model"))
          ((eq source :model) (format "inherits → %s (from Model)" id))
          ((eq source 'default) (format "inherits → %s (pai-default-model)" id))
          (t (format "inherits → %s (from %s)" id (pai-model-role-name source))))))

(defun pai-scoped-model-set (role id &optional scope)
  "Set scoped-model ROLE to model ID in SCOPE (default `project').
ID nil or `pai-scoped-model-inherit' clears ROLE so it inherits its fallback.
Return the stored model key, or nil when cleared."
  (let* ((scoped (copy-sequence (pai-settings-get :scoped-models)))
         (clear (or (null id) (equal id pai-scoped-model-inherit)))
         (key (unless clear
                (let ((model (pai-model id)))
                  (unless model (error "Unknown model: %s" id))
                  (pai-model-key model)))))
    (setq scoped (if clear
                     (cl-loop for (k v) on scoped by #'cddr
                              unless (eq k role) append (list k v))
                   (plist-put scoped role key)))
    (pai-settings-set :scoped-models scoped (or scope 'project))
    key))

(defun pai-scoped-model (role &optional fallback)
  "Return the model plist for ROLE (:main :task :compact), or FALLBACK.
The configured model is discovered on demand when its provider's models are
not registered yet (`pai-model-ensure')."
  (or (pai-model-ensure (pai-scoped-model-id role)) fallback))

;;;; Thinking levels

(defconst pai-thinking-levels '("off" "minimal" "low" "medium" "high" "xhigh" "max")
  "Valid thinking levels.")

;;;; Scoped thinking levels
;;
;; Each role may also set a thinking level (`:scoped-thinking' setting, a
;; plist ROLE -> level string).  An unset role inherits along the same
;; fallback chain as its model (a memory role -> `:task' -> `:main'); with
;; nothing set anywhere the role runs without thinking.  "off" is an
;; explicit level: it stops the inheritance.

(defun pai-scoped-thinking-explicit (role)
  "Return the thinking level configured for ROLE itself, or nil when it inherits."
  (plist-get (pai-settings-get :scoped-thinking) role))

(defun pai-scoped-thinking-resolution (role)
  "Return (LEVEL . SOURCE): ROLE's thinking level and the role that set it.
LEVEL is a string of `pai-thinking-levels'; (\"off\" . nil) when no role
in ROLE's fallback chain sets one."
  (let ((scoped (pai-settings-get :scoped-thinking))
        (r role) (seen '()) (found nil))
    (while (and r (not found) (not (memq r seen)))
      (push r seen)
      (let ((level (plist-get scoped r)))
        (when (member level pai-thinking-levels) (setq found (cons level r))))
      (setq r (alist-get r pai-model-role-fallbacks)))
    (or found
        (let ((main (plist-get scoped :main)))
          (and (member main pai-thinking-levels) (cons main :main)))
        (cons "off" nil))))

(defun pai-scoped-thinking (role)
  "Return the `:reasoning' value a run for ROLE uses: a level symbol, or nil for off."
  (let ((level (car (pai-scoped-thinking-resolution role))))
    (unless (equal level "off") (intern level))))

(defun pai-scoped-thinking-describe (role)
  "Return a short text saying which thinking level ROLE uses and why."
  (let* ((res (pai-scoped-thinking-resolution role))
         (level (car res)) (source (cdr res)))
    (cond ((eq source role) level)
          ((null source) "inherits → off")
          (t (format "inherits → %s (from %s)" level (pai-model-role-name source))))))

(defun pai-scoped-thinking-set (role level &optional scope)
  "Set ROLE's thinking LEVEL in SCOPE (default `project').
LEVEL nil or `pai-scoped-model-inherit' clears it so ROLE inherits.
Return the stored level, or nil when cleared."
  (let* ((scoped (copy-sequence (pai-settings-get :scoped-thinking)))
         (clear (or (null level) (equal level pai-scoped-model-inherit))))
    (unless (or clear (member level pai-thinking-levels))
      (error "Unknown thinking level: %s (use %s or %s)" level
             (string-join pai-thinking-levels ", ") pai-scoped-model-inherit))
    (setq scoped (if clear
                     (cl-loop for (k v) on scoped by #'cddr
                              unless (eq k role) append (list k v))
                   (plist-put scoped role level)))
    (pai-settings-set :scoped-thinking scoped (or scope 'project))
    (unless clear level)))

;;;; Slash commands

(defun pai-model--list-string (current)
  "Return a listing of catalog models, marking CURRENT's qualified key."
  (concat "Models (use /model <provider/id>):\n"
          (if (pai-models)
              (mapconcat
               (lambda (m)
                 (let ((key (pai-model-key m)))
                   (format "  %s%s" (if (equal key current) "* " "  ") key)))
               (sort (pai-models)
                     (lambda (a b) (string< (pai-model-key a) (pai-model-key b))))
               "\n")
            "  No models available.  Use /provider to configure a provider.")))

(defun pai-model-command (args ctx)
  "Handler for `/model'.  With no ARGS, discover and list models; else select."
  (let ((id (string-trim args))
        (setter (plist-get ctx :set-model))
        (current (let ((m (plist-get ctx :model))) (and m (pai-model-key m)))))
    (if (string-empty-p id)
        (let ((errors (pai-models-refresh)))
          (list :message
                (concat (pai-model--list-string current)
                        (when errors
                          (concat "\nDiscovery errors:\n"
                                  (mapconcat (lambda (err) (concat "  " err))
                                             errors "\n"))))))
      (if-let* ((model (pai-model id))
                (key (pai-model-key model)))
          (if setter
              (progn (funcall setter key) (list :message (format "Model set to %s" key)))
            (list :message (format "Model %s (no active session to apply to)" key)))
        (list :message (format "Unknown or ambiguous model: %s" id))))))

(defun pai-thinking-command (args ctx)
  "Handler for `/thinking'.  With no ARGS, show current; else set the level."
  (let ((level (string-trim args))
        (setter (plist-get ctx :set-thinking)))
    (if (string-empty-p level)
        (list :message (format "Thinking level: %s (options: %s)"
                               (or (plist-get ctx :thinking-level) "off")
                               (string-join pai-thinking-levels ", ")))
      (if (member level pai-thinking-levels)
          (if setter
              (progn (funcall setter level) (list :message (format "Thinking level set to %s" level)))
            (list :message "No active session to apply to"))
        (list :message (format "Invalid level: %s" level))))))

(defconst pai-scoped-thinking-word "thinking"
  "Second word of `/scoped-models ROLE thinking LEVEL'.")

(defun pai-scoped-models-command (args ctx)
  "Handler for `/scoped-models'.  Show or set per-role models and thinking.
`/scoped-models ROLE MODEL [LEVEL]' sets ROLE's model (and thinking level),
`/scoped-models ROLE thinking LEVEL' only its thinking level; `inherit' in
either place clears that setting so ROLE inherits it."
  (let* ((parts (split-string (string-trim args) " " t))
         (buf (plist-get ctx :buffer))
         (session-model (and (buffer-live-p buf)
                             (let ((m (buffer-local-value 'pai--model buf)))
                               (and m (pai-model-key m)))))
         (levels (string-join (cons pai-scoped-model-inherit pai-thinking-levels) "|"))
         (usage (format "Usage: /scoped-models <%s> <model-id|%s> [%s]\n       /scoped-models <role> %s <%s>"
                        (mapconcat #'pai-model-role-name pai-model-roles "|")
                        pai-scoped-model-inherit levels pai-scoped-thinking-word levels))
         (describe (lambda (role name)
                     (format "Scoped model %s: %s · thinking %s" name
                             (pai-scoped-model-describe role session-model)
                             (pai-scoped-thinking-describe role)))))
    (if (null parts)
        (list :message
              (concat "Scoped models:\n"
                      (mapconcat (lambda (r)
                                   (format "  %-20s %s · thinking %s" (pai-model-role-name r)
                                           (pai-scoped-model-describe r session-model)
                                           (pai-scoped-thinking-describe r)))
                                 pai-model-roles "\n")
                      "\n" usage "\nOr use /menu → Model & Reasoning → Scoped models."))
      (let* ((name (car parts))
             (role (intern (concat ":" name)))
             (id (nth 1 parts))
             (level (nth 2 parts))
             (valid-level (or (null level) (equal level pai-scoped-model-inherit)
                              (member level pai-thinking-levels))))
        (cond
         ((not (and (memq role pai-model-roles) id)) (list :message usage))
         ((not valid-level)
          (list :message (format "Unknown thinking level: %s\n%s" level usage)))
         ;; /scoped-models ROLE thinking LEVEL
         ((equal id pai-scoped-thinking-word)
          (if (null level)
              (list :message usage)
            (pai-scoped-thinking-set role level)
            (list :message (funcall describe role name))))
         ((not (or (equal id pai-scoped-model-inherit) (pai-model id)))
          (list :message (format "Unknown model: %s\n%s" id usage)))
         (t
          (pai-scoped-model-set role (unless (equal id pai-scoped-model-inherit) id))
          (when level (pai-scoped-thinking-set role level))
          (list :message (funcall describe role name))))))))

(pai-register-command "model" :description "List or switch the model"
                      :handler #'pai-model-command
                      :arg-completions
                      (lambda (prefix)
                        (when (string-empty-p prefix) (pai-models-refresh-for-choice))
                        (pai-model-keys)))
(pai-register-command "thinking" :description "Show or set the reasoning level"
                      :handler #'pai-thinking-command
                      :arg-completions (lambda (_p) pai-thinking-levels))
(pai-register-command "scoped-models" :description "Show or set per-role models and thinking (main/task/compact/...)"
                      :handler #'pai-scoped-models-command
                      :arg-positional t
                      :arg-completions
                      (lambda (_prefix)
                        (let ((words (pai-command-arg-words)))
                          (pcase (length words)
                            (0 (mapcar #'pai-model-role-name pai-model-roles))
                            ;; the role is typed: its model, or `thinking'
                            (1 (cons pai-scoped-thinking-word
                                     (cons pai-scoped-model-inherit (pai-model-keys))))
                            ;; the model (or `thinking') is typed: a level
                            (2 (cons pai-scoped-model-inherit pai-thinking-levels))
                            (_ nil)))))

(provide 'pai-model-resolver)
;;; pai-model-resolver.el ends here
