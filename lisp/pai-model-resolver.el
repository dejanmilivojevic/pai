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

(defun pai-scoped-models-command (args ctx)
  "Handler for `/scoped-models'.  Show or set per-role models.
`/scoped-models ROLE inherit' clears ROLE."
  (let* ((parts (split-string (string-trim args) " " t))
         (buf (plist-get ctx :buffer))
         (session-model (and (buffer-live-p buf)
                             (let ((m (buffer-local-value 'pai--model buf)))
                               (and m (pai-model-key m)))))
         (usage (format "Usage: /scoped-models <%s> <model-id|%s>"
                        (mapconcat #'pai-model-role-name pai-model-roles "|")
                        pai-scoped-model-inherit)))
    (if (null parts)
        (list :message
              (concat "Scoped models:\n"
                      (mapconcat (lambda (r)
                                   (format "  %-20s %s" (pai-model-role-name r)
                                           (pai-scoped-model-describe r session-model)))
                                 pai-model-roles "\n")
                      "\n" usage "\nOr use /menu → Model & Reasoning → Scoped models."))
      (let* ((role (intern (concat ":" (car parts))))
             (id (cadr parts)))
        (cond
         ((not (and (memq role pai-model-roles) id)) (list :message usage))
         ((equal id pai-scoped-model-inherit)
          (pai-scoped-model-set role nil)
          (list :message (format "Scoped model %s: %s" (car parts)
                                 (pai-scoped-model-describe role session-model))))
         ((pai-model id)
          (list :message (format "Scoped model %s = %s" (car parts)
                                 (pai-scoped-model-set role id))))
         (t (list :message (format "Unknown model: %s\n%s" id usage))))))))

(pai-register-command "model" :description "List or switch the model"
                      :handler #'pai-model-command
                      :arg-completions
                      (lambda (prefix)
                        (when (string-empty-p prefix) (pai-models-refresh))
                        (pai-model-keys)))
(pai-register-command "thinking" :description "Show or set the reasoning level"
                      :handler #'pai-thinking-command
                      :arg-completions (lambda (_p) pai-thinking-levels))
(pai-register-command "scoped-models" :description "Show or set per-role models (main/task/compact/...)"
                      :handler #'pai-scoped-models-command
                      :arg-positional t
                      :arg-completions
                      (lambda (_prefix)
                        (pcase (length (pai-command-arg-words))
                          (0 (mapcar #'pai-model-role-name pai-model-roles))
                          ;; the role is typed: complete its model
                          (1 (cons pai-scoped-model-inherit (pai-model-keys)))
                          (_ nil))))

(provide 'pai-model-resolver)
;;; pai-model-resolver.el ends here
