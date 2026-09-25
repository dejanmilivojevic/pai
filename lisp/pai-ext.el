;;; pai-ext.el --- Extension API, event bus, and loader -*- lexical-binding: t; -*-

;;; Commentary:

;; The extension system: the public API an extension uses to hook into the
;; agent, an event bus that dispatches lifecycle events to handlers, and a
;; loader that discovers `.el' extensions from user and project directories.
;; Port of packages/coding-agent/src/core/extensions/*.
;;
;; An extension is an `.el' file (or an in-Emacs form) that calls
;; `pai-register-extension' with a factory function receiving the API object:
;;
;;   (pai-register-extension
;;    (lambda (pi)
;;      (pai-ext-on pi 'agent-end (lambda (event ctx) ...))
;;      (pai-ext-register-tool pi my-tool)
;;      (pai-ext-register-command pi \"greet\" :handler #'my-greet)))
;;
;; Handlers receive (EVENT CTX): EVENT is a plist `(:type SYM ...)'; CTX is the
;; runtime/extension context (see `pai-ext-make-context').  The runtime feeds
;; agent-loop events through `pai-ext-emit' and threads the reducing hooks
;; (context, tool-call, tool-result, before-agent-start, message-end, input)
;; into the agent-loop config via the `pai-ext-run-*' helpers.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'pai-core)
(require 'pai-config)
(require 'pai-settings)
(require 'pai-tools)
(require 'pai-provider)
(require 'pai-models)
(require 'pai-commands)

(cl-defstruct (pai-ext-api (:constructor pai-ext-api-create)) id)

(defvar pai--extensions '()
  "Alist of (ID . FACTORY) for registered extensions, in registration order.")

(defvar pai--ext-handlers (make-hash-table :test 'eq)
  "Hash table mapping an event-type symbol to a list of (API . HANDLER).")

(defvar pai--ext-loaded-files (make-hash-table :test 'equal)
  "Set of already-loaded extension file paths.")

(defvar pai--ext-message-renderers nil "List of (API . FN) message renderers.")
(defvar pai--ext-entry-renderers nil "List of (API . FN) entry renderers.")
(defvar pai--ext-markdown-transformers nil "List of (API . FN) markdown transformers.")
(defvar pai--ext-autocomplete-providers nil "List of (API . FN) autocomplete providers.")
(defvar pai--ext-shortcuts nil "Alist of (KEY . COMMAND) registered by extensions.")
(defvar pai--ext-flags nil "Alist of (NAME . PLIST) CLI flags registered by extensions.")

(defconst pai-ext--instance-variables
  '(pai--extensions pai--ext-handlers pai--ext-loaded-files
    pai--ext-message-renderers pai--ext-entry-renderers
    pai--ext-markdown-transformers pai--ext-autocomplete-providers
    pai--ext-shortcuts pai--ext-flags pai--commands pai--tools
    pai--providers pai--models pai-provider-env-keys pai-auth-oauth-handlers
    pai-providers--settings-providers pai-providers--settings-models
    pai-providers--settings-env pai-providers--discovered
    pai-settings--global pai-settings--project pai-settings--project-dir)
  "Registrations and configuration owned by each pai instance.
Arbitrary Lisp globals defined by extensions are not sandboxed.")

(defun pai-ext-initialize-instance ()
  "Initialize this buffer's registries from non-instance registrations.
Also used by reload to discard removed extensions without affecting peers.
Copy registry containers, never lexical closures or their environments."
  (dolist (variable pai-ext--instance-variables)
    (when (boundp variable)
      (let ((value (default-value variable)))
        (set (make-local-variable variable)
             (cond ((hash-table-p value) (copy-hash-table value))
                   ((listp value) (copy-alist value))
                   (t value)))))))

(defun pai-ext-reset ()
  "Clear all registered extensions and handlers (for tests and reloads)."
  (setq pai--extensions '()
        pai--ext-message-renderers nil
        pai--ext-entry-renderers nil
        pai--ext-markdown-transformers nil
        pai--ext-autocomplete-providers nil
        pai--ext-shortcuts nil
        pai--ext-flags nil)
  (clrhash pai--ext-handlers)
  (clrhash pai--ext-loaded-files))

;;;; Registration API

(defun pai-ext--unregister (id)
  "Drop every registration made by the extension named ID.
Lists are rebuilt, never mutated: an instance's registries share structure
with the global ones they were copied from."
  (let ((mine (lambda (entry) (equal (pai-ext-api-id (car entry)) id))))
    (setq pai--extensions (seq-remove (lambda (e) (equal (car e) id)) pai--extensions))
    (maphash (lambda (event entries)
               (puthash event (seq-remove mine entries) pai--ext-handlers))
             pai--ext-handlers)
    (setq pai--ext-message-renderers (seq-remove mine pai--ext-message-renderers)
          pai--ext-entry-renderers (seq-remove mine pai--ext-entry-renderers)
          pai--ext-markdown-transformers (seq-remove mine pai--ext-markdown-transformers)
          pai--ext-autocomplete-providers (seq-remove mine pai--ext-autocomplete-providers))))

(defun pai-register-extension (factory &optional id)
  "Register and initialize an extension FACTORY (a function of the API object).
ID names the extension; a fresh one is generated when omitted.  Registering
an ID again (the file was loaded twice, or globally and then per instance)
replaces the earlier registration instead of duplicating its handlers.
Return the API."
  (when (and id (assoc id pai--extensions))
    (pai-ext--unregister id))
  (let* ((id (or id (format "ext-%d" (1+ (length pai--extensions)))))
         (api (pai-ext-api-create :id id)))
    (setq pai--extensions (append pai--extensions (list (cons id factory))))
    (funcall factory api)
    api))

(defun pai-ext-on (api event handler)
  "Subscribe HANDLER (a function of (EVENT CTX)) to EVENT for extension API."
  (push (cons api handler) (gethash event pai--ext-handlers))
  handler)

(defun pai-ext-register-tool (_api tool)
  "Register TOOL from an extension."
  (pai-register-tool tool))

(defun pai-ext-register-command (_api name &rest opts)
  "Register slash command NAME from an extension with OPTS.
See `pai-register-command' for the accepted OPTS."
  (apply #'pai-register-command name (append opts (list :source 'extension))))

(defun pai-ext-register-provider (_api provider)
  "Register a model PROVIDER from an extension."
  (pai-register-provider provider))

(defun pai-ext-register-model (_api model)
  "Register a MODEL from an extension."
  (pai-register-model model))

(defun pai-ext-register-message-renderer (api fn)
  "Register FN (MESSAGE -> propertized-string-or-nil) as a message renderer."
  (push (cons api fn) pai--ext-message-renderers) fn)

(defun pai-ext-register-entry-renderer (api fn)
  "Register FN (ENTRY -> propertized-string-or-nil) as a session-entry renderer."
  (push (cons api fn) pai--ext-entry-renderers) fn)

(defun pai-ext-register-markdown-transformer (api fn)
  "Register FN (TEXT -> TEXT) applied to assistant markdown before rendering."
  (push (cons api fn) pai--ext-markdown-transformers) fn)

(defun pai-ext-register-autocomplete-provider (api fn)
  "Register FN (PREFIX -> list of candidates) for input completion."
  (push (cons api fn) pai--ext-autocomplete-providers) fn)

(defun pai-ext-register-shortcut (_api key command)
  "Bind KEY to COMMAND in the current instance's local keymap, if any.
Later registrations win: a project extension overrides a home one that claims
the same key, because it is loaded after it."
  (push (cons key command) pai--ext-shortcuts)
  (when (current-local-map)
    (use-local-map (copy-keymap (current-local-map)))
    (local-set-key (kbd key) command))
  command)

(defun pai-ext-apply-shortcuts ()
  "Bind this instance's extension shortcuts in a private local keymap.
Used where the local map is (re)built -- mode setup and `/reload' -- to restore
bindings that were registered before it existed.  `pai--ext-shortcuts' is
newest-first, so it is applied in reverse: the newest registration for a key is
bound last and wins, exactly as when extensions load one after another.  The
map is copied first so bindings never leak into the shared mode map."
  (when (and pai--ext-shortcuts (current-local-map))
    (use-local-map (copy-keymap (current-local-map)))
    (dolist (shortcut (reverse pai--ext-shortcuts))
      (local-set-key (kbd (car shortcut)) (cdr shortcut)))))

(defun pai-ext-register-flag (_api name &rest opts)
  "Register a CLI FLAG NAME with OPTS (recorded; Emacs has no CLI parsing)."
  (push (cons name opts) pai--ext-flags) name)

;;;; Applying renderers / providers

(defun pai-ext-render-message (message)
  "Return the first non-nil extension render of MESSAGE, or nil."
  (seq-some (lambda (entry)
              (condition-case nil (funcall (cdr entry) message) (error nil)))
            (reverse pai--ext-message-renderers)))

(defun pai-ext-transform-markdown (text)
  "Apply all registered markdown transformers to TEXT, in registration order."
  (dolist (entry (reverse pai--ext-markdown-transformers) text)
    (setq text (condition-case nil (or (funcall (cdr entry) text) text) (error text)))))

(defun pai-ext-autocomplete (prefix)
  "Return the concatenated candidates from all autocomplete providers for PREFIX."
  (apply #'append
         (mapcar (lambda (entry)
                   (condition-case nil (funcall (cdr entry) prefix) (error nil)))
                 (reverse pai--ext-autocomplete-providers))))

;;;; Actions

(defun pai-ext-exec (program &rest args)
  "Run PROGRAM with ARGS synchronously; return (:code N :stdout S :stderr S)."
  (let* ((stderr-file (make-temp-file "pai-exec-err"))
         (code nil) (stdout nil))
    (unwind-protect
        (progn
          (setq stdout (with-output-to-string
                         (setq code (apply #'call-process program nil
                                           (list standard-output stderr-file) nil args))))
          (list :code code :stdout stdout
                :stderr (with-temp-buffer (insert-file-contents stderr-file) (buffer-string))))
      (delete-file stderr-file))))

;;;; Context

(cl-defun pai-ext-make-context (&key (cwd default-directory) (mode 'tui) (has-ui nil)
                                     model session ui signal abort session-name-get session-name-set)
  "Build an extension/runtime context plist from keyword arguments."
  (list :cwd cwd :mode mode :has-ui has-ui :model model :session session
        :ui ui :signal signal :abort abort
        :session-name-get session-name-get :session-name-set session-name-set))

(defun pai-ext-ctx-ui (ctx) "Return the UI plist from CTX." (plist-get ctx :ui))

(defun pai-ext-ui-notify (ctx message &optional type)
  "Notify MESSAGE (of TYPE) through CTX's UI, or via `message' as a fallback."
  (let ((fn (plist-get (pai-ext-ctx-ui ctx) :notify)))
    (if fn (funcall fn message type) (message "%s" message))))

(defun pai-ext-ui-select (ctx title options)
  "Prompt to select one of OPTIONS with TITLE through CTX's UI."
  (let ((fn (plist-get (pai-ext-ctx-ui ctx) :select)))
    (if fn (funcall fn title options) (completing-read (concat title " ") options))))

(defun pai-ext-ui-confirm (ctx title message)
  "Prompt a yes/no confirmation with TITLE and MESSAGE through CTX's UI."
  (let ((fn (plist-get (pai-ext-ctx-ui ctx) :confirm)))
    (if fn (funcall fn title message) (y-or-n-p (format "%s: %s " title message)))))

(defun pai-ext-ui-input (ctx title &optional placeholder)
  "Prompt for text input with TITLE (and PLACEHOLDER) through CTX's UI."
  (let ((fn (plist-get (pai-ext-ctx-ui ctx) :input)))
    (if fn (funcall fn title placeholder) (read-string (concat title " ") placeholder))))

(defun pai-ext-get-session-name (ctx)
  "Return the current session name from CTX, if available."
  (when-let ((fn (plist-get ctx :session-name-get))) (funcall fn)))

(defun pai-ext-set-session-name (ctx name)
  "Set the session name to NAME through CTX, if supported."
  (when-let ((fn (plist-get ctx :session-name-set))) (funcall fn name)))

;;;; Event dispatch

(defun pai-ext--handlers (event-type)
  "Return handlers for EVENT-TYPE in registration order."
  (reverse (gethash event-type pai--ext-handlers)))

(defun pai-ext-emit (event-type ctx &rest props)
  "Dispatch a notification EVENT-TYPE with PROPS to subscribers; ignore returns.
Return the list of handler return values."
  (let ((event (append (list :type event-type) props)))
    (mapcar (lambda (entry)
              (condition-case err
                  (funcall (cdr entry) event ctx)
                (error (message "pai extension handler error (%s): %s"
                                event-type (error-message-string err))
                       nil)))
            (pai-ext--handlers event-type))))

(defun pai-ext--call (entry event ctx)
  "Call handler ENTRY with EVENT and CTX, trapping and logging errors."
  (condition-case err
      (funcall (cdr entry) event ctx)
    (error (message "pai extension handler error: %s" (error-message-string err)) nil)))

;;;; Reducing hooks (threaded into the agent-loop config)

(defun pai-ext-run-context (messages ctx)
  "Run `context' handlers over MESSAGES; each may return (:messages NEW).  Return messages."
  (dolist (entry (pai-ext--handlers 'context))
    (let ((ret (pai-ext--call entry (list :type 'context :messages messages) ctx)))
      (when (and ret (plist-member ret :messages))
        (setq messages (plist-get ret :messages)))))
  messages)

(defun pai-ext-run-tool-call (tool-call args ctx)
  "Run `tool-call' handlers.  Return a before-tool-call decision plist or nil.
The first handler that returns (:block t ...) wins."
  (let ((decision nil) (input (copy-sequence args)))
    (catch 'blocked
      (dolist (entry (pai-ext--handlers 'tool-call))
        (let ((ret (pai-ext--call entry (list :type 'tool-call :tool-call tool-call
                                              :name (plist-get tool-call :name)
                                              :input input)
                                  ctx)))
          (when (and ret (pai-truthy (plist-get ret :block)))
            (setq decision ret)
            (throw 'blocked decision)))))
    decision))

(defun pai-ext-run-tool-result (result ctx tool-call args)
  "Run `tool-result' handlers over RESULT; fold their overrides.  Return override plist or nil."
  (let ((override nil))
    (dolist (entry (pai-ext--handlers 'tool-result))
      (let ((ret (pai-ext--call entry (list :type 'tool-result
                                            :tool-call-id (plist-get tool-call :id)
                                            :input args
                                            :content (plist-get result :content)
                                            :is-error (plist-get result :is-error)
                                            :details (plist-get result :details))
                                ctx)))
        (when ret
          (setq override (append ret (or override '())))
          (setq result (append (list :content (or (plist-get ret :content) (plist-get result :content))
                                     :details (or (plist-get ret :details) (plist-get result :details))
                                     :is-error (if (plist-member ret :is-error)
                                                   (plist-get ret :is-error)
                                                 (plist-get result :is-error)))
                               result)))))
    override))

(defun pai-ext-run-before-agent-start (data ctx)
  "Run `before-agent-start' handlers, folding returns into DATA.  Return DATA."
  (dolist (entry (pai-ext--handlers 'before-agent-start))
    (let ((ret (pai-ext--call entry (append (list :type 'before-agent-start) data) ctx)))
      (when (and ret (plist-member ret :system-prompt))
        (setq data (plist-put (copy-sequence data) :system-prompt (plist-get ret :system-prompt))))))
  data)

(defun pai-ext-run-compact (messages ctx &rest props)
  "Run `compact' handlers over MESSAGES; the first non-nil result wins.
PROPS are passed on in the event: :reason (`manual', `auto'), :model and
:custom-instructions.  A handler that takes over compaction returns a plist
shaped like `pai-compact''s result:

  (:messages NEW :summary S :strategy STRATEGY
   [:tokens-before T :usage U :first-kept-entry-id ID])

NEW must be the leading system messages of MESSAGES, then exactly one summary
message, then the kept tail of MESSAGES.  STRATEGY is a string naming the
handler's method (recorded in the session).  :first-kept-entry-id is the
session entry of the first kept message; when absent it is derived from the
kept tail's length.  Returning nil leaves compaction to the next handler and
finally to the built-in `pai-compact'.  Return the winning plist or nil."
  (catch 'done
    (dolist (entry (pai-ext--handlers 'compact))
      (let ((ret (pai-ext--call entry (append (list :type 'compact :messages messages) props)
                                ctx)))
        (when (and ret (plist-get ret :messages))
          (throw 'done ret))))
    nil))

(defun pai-ext-run-compact-async (messages ctx callback &rest props)
  "Run `compact' handlers over MESSAGES without blocking; call CALLBACK once.
Like `pai-ext-run-compact', but the event also carries `:callback', so a
handler with slow work (an LLM call) can finish later: it returns
`(:async CANCEL)' and eventually calls the callback once with its result, or
with nil to decline.  CANCEL is a function of no arguments stopping that
work, or nil.  Handlers that ignore `:callback' answer synchronously as
usual.  CALLBACK receives the first result, or nil when every handler
declined.  Return a function that cancels the pending work; CALLBACK is
not called after cancelling."
  (let* ((state (list :cancel nil :cancelled nil))
         (handlers (pai-ext--handlers 'compact))
         (next nil))
    (setq next
          (lambda ()
            (if (null handlers)
                (funcall callback nil)
              (let* ((entry (pop handlers))
                     (answered nil)
                     (respond (lambda (ret)
                                (unless (or answered (plist-get state :cancelled))
                                  (setq answered t)
                                  (plist-put state :cancel nil)
                                  (if (and ret (plist-get ret :messages))
                                      (funcall callback ret)
                                    (funcall next)))))
                     (ret (pai-ext--call
                           entry
                           (append (list :type 'compact :messages messages
                                         :callback (lambda (r) (funcall respond r)))
                                   props)
                           ctx)))
                (if (and (consp ret) (plist-member ret :async))
                    (unless answered (plist-put state :cancel (plist-get ret :async)))
                  (funcall respond ret))))))
    (funcall next)
    (lambda ()
      (plist-put state :cancelled t)
      (let ((cancel (plist-get state :cancel)))
        (plist-put state :cancel nil)
        (when (functionp cancel) (ignore-errors (funcall cancel)))))))

(defun pai-ext-run-system-prompt-sections (ctx)
  "Collect extra system-prompt sections from `system-prompt-sections' handlers.
Each handler returns a plist of (:NAME TEXT ...) sections, or nil.  Return the
concatenated plist for `pai-build-system-prompt''s :sections.  The system
prompt is built once, when a session is created, and saved as its first
message, so sections are a snapshot: they stay fixed for the whole session
\(and across /resume), which keeps the provider prompt cache valid."
  (let ((out '()))
    (dolist (entry (pai-ext--handlers 'system-prompt-sections))
      (let ((ret (pai-ext--call entry (list :type 'system-prompt-sections) ctx)))
        (while (and (consp ret) (keywordp (car ret)))
          (when (and (stringp (cadr ret)) (not (string-empty-p (string-trim (cadr ret)))))
            (setq out (append out (list (car ret) (cadr ret)))))
          (setq ret (cddr ret)))))
    out))

(defun pai-ext-run-message-end (message ctx)
  "Run `message-end' handlers; a handler may return (:message NEW).  Return message."
  (dolist (entry (pai-ext--handlers 'message-end))
    (let ((ret (pai-ext--call entry (list :type 'message-end :message message) ctx)))
      (when (and ret (plist-member ret :message))
        (setq message (plist-get ret :message)))))
  message)

(defun pai-ext-run-input (text ctx &optional images)
  "Run `input' handlers over TEXT/IMAGES.  Return an action plist.
Default action is (:action continue)."
  (let ((action (list :action 'continue)))
    (catch 'done
      (dolist (entry (pai-ext--handlers 'input))
        (let ((ret (pai-ext--call entry (list :type 'input :text text :images images) ctx)))
          (when (and ret (plist-get ret :action))
            (setq action ret)
            (unless (eq (plist-get ret :action) 'continue)
              (throw 'done action))))))
    action))

;;;; Enable / disable

;; Whether an extension loads is controlled by the `:extensions' setting: a map
;; of extension-name -> boolean, stored per scope (global and project).  New
;; extensions are enabled by default (absence = enabled).  Precedence is
;; per-extension with project overriding global, so a project can flip a single
;; extension without restating the rest.

(defun pai-ext--key (name)
  "Return the settings map key (a keyword) for extension NAME."
  (intern (concat ":" name)))

(defun pai-ext-name-of-file (file)
  "Return the extension name for a loose `.el' FILE (basename sans extension)."
  (file-name-sans-extension (file-name-nondirectory file)))

(defun pai-ext-name-of-dir (dir)
  "Return the extension name for extension directory DIR (its basename)."
  (file-name-nondirectory (directory-file-name dir)))

(defun pai-ext-override (name scope)
  "Return NAME's explicit override in SCOPE: `enabled', `disabled', or nil.
SCOPE is `global' or `project'.  nil means no override is set in that scope."
  (let ((k (pai-ext--key name)))
    (and (pai-settings-scope-has :extensions scope)
         (let ((map (pai-settings-scope-value :extensions scope)))
           (and (plist-member map k)
                (if (pai-truthy (plist-get map k)) 'enabled 'disabled))))))

(defun pai-ext-enabled-p (name)
  "Return non-nil if extension NAME should load.
Project override wins over global override; absent both, the default is enabled."
  (pcase (or (pai-ext-override name 'project) (pai-ext-override name 'global))
    ('disabled nil)
    (_ t)))

(defun pai-ext--plist-delete (plist key)
  "Return a copy of PLIST with KEY removed."
  (let (out)
    (while plist
      (unless (eq (car plist) key) (setq out (cons (cadr plist) (cons (car plist) out))))
      (setq plist (cddr plist)))
    (nreverse out)))

(defun pai-ext-set-enabled (name enabled scope)
  "Persist ENABLED (non-nil = on) for extension NAME in SCOPE.
SCOPE is `global' or `project'.  Takes effect on the next load/reload."
  (let* ((k (pai-ext--key name))
         (map (copy-sequence (pai-settings-scope-value :extensions scope))))
    (pai-settings-set :extensions (plist-put map k (if enabled t :false)) scope)))

(defun pai-ext-clear-override (name scope)
  "Remove NAME's override in SCOPE so it inherits (global) or defaults (enabled)."
  (let* ((k (pai-ext--key name))
         (map (pai-ext--plist-delete (pai-settings-scope-value :extensions scope) k)))
    (pai-settings-set :extensions map scope)))

;;;; Discovery

(defun pai-ext--global-dir ()
  "Return the global extensions directory path."
  (expand-file-name "extensions" pai-directory))

(defun pai-ext-discover-dirs ()
  "Return (DIR . SOURCE) pairs for existing extension roots.
SOURCE is `global' for the user extensions dir, `project' otherwise."
  (let ((global (pai-ext--global-dir))
        (project (expand-file-name ".pai/extensions" default-directory))
        (out nil))
    (when (file-directory-p global) (push (cons global 'global) out))
    (when (and (file-directory-p project) (not (file-equal-p project global)))
      (push (cons project 'project) out))
    (nreverse out)))

(defun pai-ext-discover (&optional dirs)
  "Return a list of plists describing every discoverable extension.
Each entry is (:name STR :source SYM :path STR), covering both loose `.el'
files and extension subdirectories across DIRS (default `pai-ext-discover-dirs').
Entries are deduped by name (first source wins) and independent of whether the
extension is currently enabled."
  (let ((dirs (or dirs (pai-ext-discover-dirs)))
        (seen (make-hash-table :test 'equal))
        (out nil))
    (dolist (pair dirs)
      (let ((dir (car pair)) (source (cdr pair)))
        (when (file-directory-p dir)
          (dolist (file (directory-files dir t "\\.el\\'"))
            (let ((name (pai-ext-name-of-file file)))
              (unless (gethash name seen)
                (puthash name t seen)
                (push (list :name name :source source :path file) out))))
          (dolist (entry (directory-files dir t "\\`[^.]"))
            (when (file-directory-p entry)
              (let ((name (pai-ext-name-of-dir entry)))
                (unless (gethash name seen)
                  (puthash name t seen)
                  (push (list :name name :source source :path entry) out))))))))
    (nreverse out)))

;;;; Loader

(defun pai-extensions-default-dirs ()
  "Return the default extension search directories that exist."
  (seq-filter #'file-directory-p
              (list (expand-file-name "extensions" pai-directory)
                    (expand-file-name ".pai/extensions" default-directory))))

;;;; Visibility: enabled, or needed by an enabled extension

;; The dashboard and the settings screen show an extension (and the settings
;; section it registers) only when it is enabled, or when an enabled
;; extension `require's it -- then it is loaded anyway and its settings
;; matter.  Both facts come from the extension sources, scanned once and
;; cached until a file changes: extensions register their settings from
;; `with-eval-after-load' forms that often run long after they were loaded,
;; so the owner of a section cannot be recorded at registration time.

(defvar pai-ext--scan-cache (make-hash-table :test 'equal)
  "FILE -> (MTIME . (:requires FEATURES :sections IDS)).")

(defun pai-ext--scan-file (file)
  "Return (:requires FEATURES :sections IDS) found in extension FILE.
FEATURES and IDS are symbols; the result is cached until FILE changes."
  (let* ((mtime (file-attribute-modification-time (file-attributes file)))
         (hit (gethash file pai-ext--scan-cache)))
    (if (and hit (equal (car hit) mtime))
        (cdr hit)
      (let ((requires '()) (sections '()))
        (with-temp-buffer
          (ignore-errors (insert-file-contents file))
          (goto-char (point-min))
          (while (re-search-forward "(require[ \t\n]+'\\([^ \t\n()]+\\)" nil t)
            (push (intern (match-string 1)) requires))
          (goto-char (point-min))
          (while (re-search-forward
                  "(pai-settings-ui-register-section[ \t\n]+'\\([^ \t\n()]+\\)" nil t)
            (push (intern (match-string 1)) sections)))
        (let ((r (list :requires (delete-dups requires) :sections (delete-dups sections))))
          (puthash file (cons mtime r) pai-ext--scan-cache)
          r)))))

(defun pai-ext-entries (&optional dirs)
  "Return the extensions found in DIRS as (NAME . FILES), like the loader.
DIRS defaults to `pai-extensions-default-dirs'.  A loose `.el' file is an
extension of one file; a subdirectory is one with all its `.el' files.  The
first extension of a name wins."
  (let ((seen (make-hash-table :test 'equal)) (out '()))
    (dolist (dir (or dirs (pai-extensions-default-dirs)))
      (when (file-directory-p dir)
        (dolist (entry (directory-files dir t "\\`[^.]"))
          (let ((name (if (file-directory-p entry) (pai-ext-name-of-dir entry)
                        (and (string-suffix-p ".el" entry) (pai-ext-name-of-file entry)))))
            (when (and name (not (gethash name seen)))
              (puthash name t seen)
              (push (cons name (if (file-directory-p entry)
                                   (directory-files entry t "\\`[^.].*\\.el\\'")
                                 (list entry)))
                    out))))))
    (nreverse out)))

(defun pai-ext-visible-names (&optional dirs)
  "Return the names of the extensions in DIRS that are enabled or needed.
An extension is needed when a visible one `require's a feature it provides
\(one of its file names); this is followed through, so what a needed
extension requires is visible too."
  (let* ((entries (pai-ext-entries dirs))
         (provider (make-hash-table :test 'eq))
         (visible (make-hash-table :test 'equal))
         (queue '()))
    (dolist (e entries)
      (dolist (f (cdr e)) (puthash (intern (file-name-base f)) (car e) provider)))
    (dolist (e entries)
      (when (pai-ext-enabled-p (car e))
        (puthash (car e) t visible)
        (push e queue)))
    (while queue
      (let ((e (pop queue)))
        (dolist (f (cdr e))
          (dolist (feature (plist-get (pai-ext--scan-file f) :requires))
            (let ((name (gethash feature provider)))
              (when (and name (not (gethash name visible)))
                (puthash name t visible)
                (push (assoc name entries) queue)))))))
    (seq-filter (lambda (n) (gethash n visible)) (mapcar #'car entries))))

(defun pai-ext-visible-p (name &optional dirs)
  "Return non-nil when extension NAME should be shown (see `pai-ext-visible-names')."
  (and (member name (pai-ext-visible-names dirs)) t))

(defun pai-ext-section-owner (section-id &optional dirs)
  "Return the extension in DIRS that registers settings SECTION-ID, or nil.
Core sections have no owner."
  (car (seq-find (lambda (e)
                   (seq-some (lambda (f) (memq section-id (plist-get (pai-ext--scan-file f) :sections)))
                             (cdr e)))
                 (pai-ext-entries dirs))))

(defun pai-load-extension-file (file)
  "Load a single extension FILE unless already loaded."
  (let ((path (file-truename file)))
    (unless (gethash path pai--ext-loaded-files)
      (condition-case err
          (progn (load path nil t t)
                 (puthash path t pai--ext-loaded-files))
        (error (message "pai: failed to load extension %s: %s" file
                        (error-message-string err)))))))

(defun pai-load-extension-dir (dir)
  "Load the extension rooted at subdirectory DIR.
The entry file is DIR/<name>.el where <name> is DIR's basename; when it is
missing, every `.el' directly in DIR is loaded.  DIR is added to `load-path'
first so a multi-file extension can `require' its own siblings."
  (let* ((name (file-name-nondirectory (directory-file-name dir)))
         (entry (expand-file-name (concat name ".el") dir)))
    (add-to-list 'load-path (directory-file-name dir))
    (if (file-exists-p entry)
        (pai-load-extension-file entry)
      (dolist (file (directory-files dir t "\\.el\\'"))
        (pai-load-extension-file file)))))

(cl-defun pai-load-extensions (&optional (dirs (pai-extensions-default-dirs)))
  "Load enabled extensions from DIRS; explicit nil loads nothing.
Within each root, loose `.el' files are loaded directly, and every
subdirectory is treated as a self-contained extension (see
`pai-load-extension-dir').  Extensions disabled via the `:extensions' setting
are skipped (see `pai-ext-enabled-p')."
  (dolist (dir dirs)
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "\\.el\\'"))
        (when (pai-ext-enabled-p (pai-ext-name-of-file file))
          (pai-load-extension-file file)))
      (dolist (entry (directory-files dir t "\\`[^.]"))
        (when (and (file-directory-p entry)
                   (pai-ext-enabled-p (pai-ext-name-of-dir entry)))
          (pai-load-extension-dir entry))))))

;;;; Reloading (development)

;; `/reload' must pick up on-disk edits without an Emacs restart.  Two things
;; get in the way and are handled here:
;;   1. `require' short-circuits a multi-file extension's already-loaded sibling
;;      files.  `pai-reload-forget-extension-features' drops their features so
;;      the loader re-`require's them fresh.
;;   2. Core `pai-*.el' files are never re-loaded.  `pai-reload-snapshot' records
;;      their mtimes at startup and `pai-reload-changed-core-files' re-`load's
;;      those edited since.

(defvar pai-reload--mtimes (make-hash-table :test 'equal)
  "Map of core pai source file -> modification time seen at last load/reload.")

(defun pai-reload--mtime (file)
  "Return FILE's modification time as a float, or 0."
  (let ((attrs (file-attributes file)))
    (if attrs (float-time (file-attribute-modification-time attrs)) 0)))

(defun pai-reload--core-dir ()
  "Return the directory holding the core pai `.el' source, or nil."
  (let ((lib (locate-library "pai-ext")))
    (and lib (file-name-directory lib))))

(defun pai-reload--core-files ()
  "Return the list of core pai `.el' source files."
  (let ((dir (pai-reload--core-dir)))
    (and dir (ignore-errors (directory-files dir t "\\`pai.*\\.el\\'")))))

(defun pai-reload-snapshot ()
  "Record current mtimes of core pai files, so later reloads detect edits."
  (dolist (file (pai-reload--core-files))
    (puthash file (pai-reload--mtime file) pai-reload--mtimes)))

(defun pai-reload-changed-core-files ()
  "Re-`load' core pai source files whose mtime changed since the last snapshot.
Return the list of reloaded files.  Registrations are keyed by name/id, so
re-running a file replaces rather than duplicates them."
  (let (reloaded)
    (dolist (file (pai-reload--core-files))
      (let ((mt (pai-reload--mtime file))
            (prev (gethash file pai-reload--mtimes)))
        (when (and prev (> mt prev))
          (condition-case err
              (progn (load file nil t t) (push file reloaded))
            (error (message "pai: failed to reload %s: %s" file
                            (error-message-string err)))))
        (puthash file mt pai-reload--mtimes)))
    (nreverse reloaded)))

(defun pai-reload-forget-extension-features (dirs)
  "Drop `features' provided by extension files under DIRS.
This forces the loader to re-`require' (and thus reload) a multi-file
extension's sibling files instead of short-circuiting on the cached feature."
  (let ((roots (delq nil (mapcar (lambda (d) (and (file-directory-p d) (file-truename d)))
                                 dirs))))
    (when roots
      (dolist (entry load-history)
        (let ((file (car entry)))
          (when (and (stringp file)
                     (let ((tf (file-truename file)))
                       (cl-some (lambda (r) (string-prefix-p r tf)) roots)))
            (dolist (def (cdr entry))
              (when (and (consp def) (eq (car def) 'provide))
                (setq features (delq (cdr def) features))))))))))

(provide 'pai-ext)
;;; pai-ext.el ends here
