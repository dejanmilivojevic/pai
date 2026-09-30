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

(defun pai-tool-subagent-allowed-p (tool)
  "Return non-nil unless TOOL is kept from subagents.
A tool with `:subagent-exclude' non-nil (e.g. pai-memory's, which write to
or search the user's own memory) is not given to subagent runs."
  (not (plist-get tool :subagent-exclude)))

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

(defcustom pai-tool-max-lines 6000
  "Maximum number of lines a tool includes before truncating."
  :type 'integer :group 'pai)

(defcustom pai-tool-max-bytes (* 150 1024)
  "Maximum number of bytes a tool includes before truncating."
  :type 'integer :group 'pai)

(defcustom pai-tool-result-max-bytes (* 256 1024)
  "Hard limit on the text of any single tool result, in bytes.
A safety net applied to every tool result (builtin, extension and MCP)
before it enters the conversation, so one runaway result (a huge
`elisp_eval' value, a minified file, ...) cannot blow up the context and
the session file.  Strings inside the result details are capped too."
  :type 'integer :group 'pai)

(defun pai-tools--head-bytes-end (text end max-bytes)
  "Return the largest N <= END whose prefix of TEXT fits in MAX-BYTES."
  (let ((lo 0) (hi (min end max-bytes)))   ; a char takes at least one byte
    (while (< lo hi)
      (let ((mid (/ (+ lo hi 1) 2)))
        (if (<= (string-bytes (substring text 0 mid)) max-bytes)
            (setq lo mid)
          (setq hi (1- mid)))))
    lo))

(defun pai-tools--tail-bytes-start (text start max-bytes)
  "Return the smallest N >= START whose suffix of TEXT fits in MAX-BYTES."
  (let* ((len (length text))
         (lo (max start (- len max-bytes))) (hi len))
    (while (< lo hi)
      (let ((mid (/ (+ lo hi) 2)))
        (if (<= (string-bytes (substring text mid)) max-bytes)
            (setq hi mid)
          (setq lo (1+ mid)))))
    lo))

(defun pai-tools-truncate (text &optional max-lines max-bytes from)
  "Truncate TEXT to MAX-LINES and MAX-BYTES, keeping the FROM end.
FROM is `head' (default) or `tail'.  Cuts fall on line boundaries when
possible; a single line longer than MAX-BYTES is cut mid-line.  Runs in
time linear in the kept part, so it is safe on huge strings.  Return a
plist \(:text STRING :truncated BOOL :total-lines N)."
  (let* ((max-lines (max 1 (or max-lines pai-tool-max-lines)))
         (max-bytes (max 0 (or max-bytes pai-tool-max-bytes)))
         (full text)
         (full-len (length text))
         (total (pai-tools--count-lines text))
         ;; Only a window of MAX-BYTES + 1 chars at the kept end can
         ;; survive (a char takes at least one byte): work on that alone.
         (offset (if (eq from 'tail) (max 0 (- full-len max-bytes 1)) 0))
         (text (if (< (1+ max-bytes) full-len)
                   (if (eq from 'tail) (substring text offset)
                     (substring text 0 (1+ max-bytes)))
                 text))
         (len (length text))
         (beg 0) (end len))
    (if (eq from 'tail)
        (let ((pos len) (n 0))
          ;; Keep the last MAX-LINES lines.
          (while (and (< n max-lines) pos)
            (let ((nl (and (> pos 0)
                           (cl-position ?\n text :end pos :from-end t))))
              (setq beg (if nl (1+ nl) 0) pos nl n (1+ n))))
          (when (> (string-bytes (substring text beg)) max-bytes)
            (let* ((s (pai-tools--tail-bytes-start text beg max-bytes))
                   (nl (string-search "\n" text s)))
              (setq beg (if (and nl (< (1+ nl) len) (> s 0)
                                 (not (eq (aref text (1- s)) ?\n)))
                            (1+ nl)
                          s)))))
      (let ((pos 0) (n 0))
        ;; Keep the first MAX-LINES lines.
        (while (and (< n max-lines) pos)
          (let ((nl (string-search "\n" text pos)))
            (setq n (1+ n))
            (if (and nl (< n max-lines))
                (setq pos (1+ nl))
              (setq end (or nl len) pos nil)))))
      (when (> (string-bytes (substring text 0 end)) max-bytes)
        (let* ((e (pai-tools--head-bytes-end text end max-bytes))
               (nl (and (> e 0) (< e len) (not (eq (aref text e) ?\n))
                        (cl-position ?\n text :end e :from-end t))))
          (setq end (if (and nl (> nl 0)) nl e)))))
    (setq beg (+ beg offset) end (+ end offset))
    (list :text (if (and (= beg 0) (= end full-len)) full (substring full beg end))
          :truncated (or (> beg 0) (< end full-len))
          :total-lines total)))

(defun pai-tools--count-lines (text)
  "Return the number of newline-separated lines in TEXT."
  (let ((n 1) (pos 0))
    (while (setq pos (string-search "\n" text pos))
      (setq n (1+ n) pos (1+ pos)))
    n))

(defun pai-tools--cap-details (details max-bytes)
  "Return DETAILS with every string longer than MAX-BYTES truncated.
DETAILS is returned unchanged (`eq') when nothing is oversized."
  (cl-labels ((big-p (x)
                (cond ((stringp x) (> (string-bytes x) max-bytes))
                      ((consp x) (or (big-p (car x)) (big-p (cdr x))))
                      ((vectorp x) (cl-some #'big-p x))))
              (cap (x)
                (cond ((not (big-p x)) x)
                      ((stringp x)
                       (concat (plist-get (pai-tools-truncate
                                           x most-positive-fixnum max-bytes 'head)
                                          :text)
                               "\n[truncated]"))
                      ((consp x) (cons (cap (car x)) (cap (cdr x))))
                      ((vectorp x) (vconcat (mapcar #'cap x))))))
    (cap details)))

(defun pai-tools-cap-result (result &optional max-bytes)
  "Cap the text blocks and detail strings of tool RESULT at MAX-BYTES.
MAX-BYTES defaults to `pai-tool-result-max-bytes'.  Image blocks are
left alone.  Return RESULT itself when nothing exceeds the limit."
  (let* ((max-bytes (or max-bytes pai-tool-result-max-bytes))
         (content (plist-get result :content))
         (details (plist-get result :details))
         (changed nil)
         (new-content
          (if (stringp content)
              (if (<= (string-bytes content) max-bytes) content
                (setq changed t)
                (list (pai-text (pai-tools--cap-text content max-bytes))))
            (mapcar (lambda (b)
                      (let ((text (and (eq (plist-get b :type) 'text)
                                       (plist-get b :text))))
                        (if (and (stringp text) (> (string-bytes text) max-bytes))
                            (progn (setq changed t)
                                   (append (list :type 'text
                                                 :text (pai-tools--cap-text text max-bytes))
                                           (cl-loop for (k v) on b by #'cddr
                                                    unless (memq k '(:type :text))
                                                    append (list k v))))
                          b)))
                    content)))
         (new-details (pai-tools--cap-details details max-bytes)))
    (if (and (not changed) (eq new-details details))
        result
      (let ((r (copy-sequence result)))
        (setq r (plist-put r :content new-content))
        (when details (setq r (plist-put r :details new-details)))
        r))))

(defconst pai-tools--invalid-char-regexp "[^\0-\uD7FF\uE000-\U0010FFFF]"
  "Matches characters that are not Unicode scalar values.
Raw bytes (from reading a binary file) and lone surrogates make
`json-serialize' fail, so no request or session line could be written.")

(defun pai-tools-valid-text (string)
  "Return STRING with every non-Unicode character replaced by U+FFFD.
A unibyte STRING is decoded as UTF-8 first.  Return STRING itself (`eq')
when it is already valid."
  (let ((s (if (and (not (multibyte-string-p string))
                    (string-match-p "[^[:ascii:]]" string))
               (decode-coding-string string 'utf-8 t)
             string)))
    (if (string-match-p pai-tools--invalid-char-regexp s)
        (replace-regexp-in-string pai-tools--invalid-char-regexp "\uFFFD" s t t)
      s)))

(defun pai-tools-sanitize-result (result)
  "Return tool RESULT with all its strings made valid Unicode.
See `pai-tools-valid-text'.  Return RESULT itself when nothing changed."
  (cl-labels ((clean (x)
                (cond ((stringp x) (pai-tools-valid-text x))
                      ((consp x)
                       (let ((a (clean (car x))) (d (clean (cdr x))))
                         (if (and (eq a (car x)) (eq d (cdr x))) x (cons a d))))
                      ((vectorp x)
                       (let ((v (mapcar #'clean x)))
                         (if (cl-every #'eq v (append x nil)) x (vconcat v))))
                      (t x))))
    (clean result)))

(defun pai-tools--cap-text (text max-bytes)
  "Return TEXT cut to MAX-BYTES with a note saying how much was dropped."
  (let* ((trunc (pai-tools-truncate text most-positive-fixnum max-bytes 'head))
         (kept (plist-get trunc :text)))
    (format "%s\n[tool output truncated: showing %d of %d bytes (%d lines); \
narrow the request to see more]"
            kept (string-bytes kept) (string-bytes text)
            (plist-get trunc :total-lines))))

(provide 'pai-tools)
;;; pai-tools.el ends here
