;;; pai-tools.el --- Tool registry and helpers -*- lexical-binding: t; -*-

;;; Commentary:

;; The tool registry and the shared helpers used to build tools.  A tool is a
;; plist (see docs/ARCHITECTURE.md section 5):
;;
;;   (:name STRING :label STRING :description STRING
;;    :parameters JSON-SCHEMA :execution-mode (parallel|sequential)
;;    :prompt-snippet STRING :prompt-guidelines (STRING...)
;;    :execute (lambda (ARGS CTX ON-UPDATE ON-DONE)))
;;
;; The executor calls ON-DONE with a result plist
;; `(:content BLOCKS :details ANY :is-error BOOL)' when finished (synchronously
;; for cheap tools, later for async tools such as bash).  ON-UPDATE, when
;; non-nil, may be called with a partial result to stream progress.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-core)
(require 'pai-config)

(defvar pai--tools (make-hash-table :test 'equal)
  "Hash table mapping tool name (string) to a tool plist.")

(defun pai-register-tool (tool)
  "Register TOOL (a plist) keyed by its :name.  Return TOOL."
  (puthash (plist-get tool :name) tool pai--tools)
  tool)

(defun pai-unregister-tool (name)
  "Remove the tool named NAME from the registry."
  (remhash name pai--tools))

(defun pai-tool-get (name)
  "Return the tool plist named NAME, or nil."
  (gethash name pai--tools))

(defun pai-tools-all ()
  "Return a list of all registered tool plists."
  (hash-table-values pai--tools))

(defun pai-tools-select (names)
  "Return the registered tool plists whose names are in NAMES (a list of strings)."
  (delq nil (mapcar #'pai-tool-get names)))

(defun pai-tool-full-declaration (tool)
  "Return the complete provider declaration (:name :description :parameters) for TOOL."
  (list :name (plist-get tool :name)
        :description (or (plist-get tool :description) "")
        :parameters (or (plist-get tool :parameters)
                        (pai-object-schema nil))))

(defun pai-tool-declaration (tool)
  "Return the provider declaration for TOOL as sent on every request.
Deferred tools (see `pai-tool-deferred-p') get a compact stub; all others get
their full declaration."
  (if (pai-tool-deferred-p tool)
      (pai-tool-stub-declaration tool)
    (pai-tool-full-declaration tool)))

;;;; Deferred (lazily-described) tools
;;
;; Only core tools are declared in full on every request.  Other tools
;; (normally those registered by extensions) are declared as a compact stub:
;; name, one-line summary and a permissive schema.  The first call to a stub
;; is not executed; instead its result carries the tool's full description
;; and JSON schema.  That result lives in the message history, so the tool
;; list itself never changes during a session and the provider's prompt
;; cache (tools -> system -> messages) stays valid for every provider.
;; After compaction drops the reveal, the next call simply reveals again.

(defcustom pai-defer-extension-tools t
  "When non-nil, non-core tools are declared as compact stubs.
Their full schema is supplied in-conversation on first use.  The settings
key `:defer-tools' overrides this when set."
  :type 'boolean :group 'pai)

(defcustom pai-eager-tool-names nil
  "Names of additional tools that are always declared in full.
The built-in tools (`pai-builtin-tool-names') are always eager."
  :type '(repeat string) :group 'pai)

(defvar pai-builtin-tool-names)
(declare-function pai-settings-get "pai-settings" (key &optional default))

(defun pai-tools--deferral-enabled-p ()
  "Return non-nil when tool deferral is enabled."
  (pai-truthy (if (fboundp 'pai-settings-get)
                  (pai-settings-get :defer-tools pai-defer-extension-tools)
                pai-defer-extension-tools)))

(defun pai-tool-deferred-p (tool)
  "Return non-nil when TOOL is declared as a stub until first use.
A tool's own `:deferred' property wins; otherwise every tool that is not
built in or listed in `pai-eager-tool-names' is deferred."
  (let ((name (plist-get tool :name)))
    (and (pai-tools--deferral-enabled-p)
         (not (member name pai-eager-tool-names))
         (if (plist-member tool :deferred)
             (pai-truthy (plist-get tool :deferred))
           (not (member name (bound-and-true-p pai-builtin-tool-names)))))))

(defun pai-tool-summary (tool)
  "Return a one-line summary of TOOL for its stub declaration."
  (or (plist-get tool :prompt-snippet)
      (car (split-string (or (plist-get tool :description) "") "\\(\\. \\|\n\\)"))
      ""))

(defun pai-tool-stub-declaration (tool)
  "Return the compact stub declaration for deferred TOOL.
The stub depends only on TOOL itself, so it is byte-stable across requests."
  (list :name (plist-get tool :name)
        :description (concat (string-trim-right (pai-tool-summary tool) "[. ]+")
                             ". [Schema not loaded: first call returns the full "
                             "definition without executing; then call again.]")
        :parameters (list :type "object"
                          :properties (pai-json-empty-object)
                          :additionalProperties t)))

(defun pai-message-revealed-tools (message)
  "Return the names of the tools whose full definitions MESSAGE carries.
That is either a reveal tool result (`:details (:deferred-schema NAME)') or
any message tagged `:deferred-schemas (NAME...)', such as a compaction summary
that carried reveals forward."
  (append
   (when (pai-tool-result-message-p message)
     (let* ((details (plist-get message :details))
            (name (and (listp details) (plist-get details :deferred-schema))))
       (when (and name (equal name (plist-get message :tool-name)))
         (list name))))
   (let ((names (plist-get message :deferred-schemas)))
     (and (listp names) names))))

(defun pai-tool-schema-message-p (message)
  "Return non-nil when MESSAGE carries a deferred tool definition.
Context reducers (compaction, shake, ...) must never drop or rewrite these."
  (and (pai-message-revealed-tools message) t))

(defun pai-tool-revealed-p (tool messages)
  "Return non-nil when TOOL's full schema already appears in MESSAGES."
  (let ((name (plist-get tool :name)))
    (seq-some (lambda (m) (member name (pai-message-revealed-tools m))) messages)))

(defun pai-tool-definition-text (tool)
  "Return the full definition of TOOL (description and JSON schema) as text."
  (let ((decl (pai-tool-full-declaration tool)))
    (format "Tool \"%s\"\n\nDescription:\n%s\n\nParameters (JSON schema):\n%s"
            (plist-get decl :name)
            (plist-get decl :description)
            (pai-json-encode (plist-get decl :parameters)))))

(defun pai-tool-reveal-result (tool)
  "Return the tool result that reveals TOOL's full definition."
  (pai-tool-ok-result
   (concat "Tool was NOT executed. Its full definition is now loaded; "
           "call it again with arguments matching this schema.\n\n"
           (pai-tool-definition-text tool))
   (list :deferred-schema (plist-get tool :name))))

(defun pai-tool-carried-schemas (dropped kept)
  "Return the definitions revealed in DROPPED messages that KEPT lacks.
For context reducers that remove DROPPED: the result is a plist
\(:names NAMES :text TEXT), or nil when nothing needs carrying.  Tools no
longer registered are skipped: they cannot be called, and a later
re-registration simply reveals again."
  (let (names)
    (dolist (m dropped)
      (dolist (name (pai-message-revealed-tools m))
        (when (and (pai-tool-get name)
                   (not (member name names))
                   (not (pai-tool-revealed-p (list :name name) kept)))
          (push name names))))
    (when names
      (setq names (nreverse names))
      (list :names names
            :text (concat "Full definitions of deferred tools loaded earlier "
                          "in this conversation (still in effect):\n\n"
                          (mapconcat (lambda (n) (pai-tool-definition-text (pai-tool-get n)))
                                     names "\n\n---\n\n"))))))

(defun pai-tool-pending-reveal (tool messages)
  "Return a reveal result when TOOL is deferred and not yet revealed in MESSAGES."
  (when (and tool (pai-tool-deferred-p tool)
             (not (pai-tool-revealed-p tool messages)))
    (pai-tool-reveal-result tool)))

;;;; JSON-schema helpers

(defun pai-object-schema (properties &optional required)
  "Build a JSON object schema from PROPERTIES and REQUIRED.
PROPERTIES is a plist mapping parameter keywords to their sub-schemas, e.g.
\(:command (:type \"string\" :description \"...\")).  REQUIRED is a list of
parameter name strings."
  (append (list :type "object"
                :properties (or properties (pai-json-empty-object)))
          (when required (list :required required))))

(defun pai-string-schema (description &rest extra)
  "Build a string parameter schema with DESCRIPTION and EXTRA plist keys."
  (append (list :type "string" :description description) extra))

(defun pai-number-schema (description &rest extra)
  "Build a number parameter schema with DESCRIPTION and EXTRA plist keys."
  (append (list :type "number" :description description) extra))

(defconst pai-tool--number-regexp
  "\\`[ \t]*[-+]?\\(?:[0-9]+\\.?[0-9]*\\|\\.[0-9]+\\)\\(?:[eE][-+]?[0-9]+\\)?[ \t]*\\'"
  "A number written as a string, as models sometimes send it.")

(defun pai-tool--coerce-value (schema value)
  "Return VALUE converted to SCHEMA's scalar type when it came as a string.
Models sometimes send numbers and booleans quoted (\"10\", \"true\"); anything
else is returned unchanged."
  (let ((type (plist-get schema :type)))
    (cond
     ((not (stringp value)) value)
     ((and (member type '("number" "integer"))
           (string-match-p pai-tool--number-regexp value))
      (let ((n (string-to-number (string-trim value))))
        (if (equal type "integer") (truncate n) n)))
     ((and (equal type "boolean") (member (downcase (string-trim value)) '("true" "false")))
      (if (equal (downcase (string-trim value)) "true") t :false))
     (t value))))

(defun pai-tool-coerce-args (tool args)
  "Return ARGS with top-level number/boolean parameters of TOOL coerced.
See `pai-tool--coerce-value'.  ARGS itself is not modified."
  (let ((props (plist-get (plist-get tool :parameters) :properties)))
    (if (not (and (consp props) (consp args)))
        args
      (let ((out args))
        (cl-loop for (key value) on args by #'cddr
                 for schema = (plist-get props key)
                 for new = (if (consp schema) (pai-tool--coerce-value schema value) value)
                 unless (eq new value)
                 do (setq out (plist-put (if (eq out args) (copy-sequence args) out) key new)))
        out))))

(defun pai-boolean-schema (description)
  "Build a boolean parameter schema with DESCRIPTION."
  (list :type "boolean" :description description))

(defun pai-array-schema (description item-schema)
  "Build an array parameter schema with DESCRIPTION and ITEM-SCHEMA."
  (list :type "array" :description description :items item-schema))

;;;; Context accessors

(defun pai-tool-ctx-cwd (ctx)
  "Return the working directory from tool CTX."
  (or (plist-get ctx :cwd) default-directory))

(defun pai-tool-resolve-path (ctx path)
  "Resolve PATH against the working directory in CTX."
  (expand-file-name path (pai-tool-ctx-cwd ctx)))

;;;; Output truncation

(defcustom pai-tool-max-lines 2000
  "Maximum number of lines a tool includes before truncating."
  :type 'integer :group 'pai)

(defcustom pai-tool-max-bytes (* 50 1024)
  "Maximum number of bytes a tool includes before truncating."
  :type 'integer :group 'pai)

(defun pai-tools-truncate (text &optional max-lines max-bytes from)
  "Truncate TEXT to MAX-LINES and MAX-BYTES, keeping the FROM end.
FROM is `head' (default) or `tail'.  Return a plist
\(:text STRING :truncated BOOL :total-lines N)."
  (let* ((max-lines (or max-lines pai-tool-max-lines))
         (max-bytes (or max-bytes pai-tool-max-bytes))
         (from (or from 'head))
         (lines (split-string text "\n"))
         (total (length lines))
         (truncated nil)
         (kept lines))
    (when (> total max-lines)
      (setq truncated t)
      (setq kept (if (eq from 'tail)
                     (nthcdr (- total max-lines) lines)
                   (butlast lines (- total max-lines)))))
    (let ((joined (string-join kept "\n")))
      (when (> (string-bytes joined) max-bytes)
        (setq truncated t)
        (if (eq from 'tail)
            (while (and (> (string-bytes joined) max-bytes) (cdr kept))
              (setq kept (cdr kept) joined (string-join kept "\n")))
          (while (and (> (string-bytes joined) max-bytes) (cdr kept))
            (setq kept (butlast kept) joined (string-join kept "\n")))))
      (list :text joined :truncated truncated :total-lines total))))

(provide 'pai-tools)
;;; pai-tools.el ends here
