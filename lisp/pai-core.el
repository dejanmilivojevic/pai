;;; pai-core.el --- Core data model and JSON for pai -*- lexical-binding: t; -*-

;; Author: pai contributors
;; Keywords: ai, tools, convenience
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Core of the pai agent harness: the unified message/content/tool data
;; model (a faithful port of packages/ai/src/types.ts from the `pi'
;; project) plus JSON (de)serialization helpers built on Emacs' native
;; JSON.
;;
;; Representation conventions (see docs/ARCHITECTURE.md):
;;
;; - JSON objects  -> keyword-keyed plists, e.g. (:role user :text "hi").
;; - JSON arrays   -> ordinary Lisp lists.
;; - JSON true     -> t
;; - JSON false    -> the keyword `:false'
;; - JSON null     -> the keyword `:null'
;; - enum-like discriminators (:role, :type, :stop-reason) are Lisp symbols.
;;
;; A nil value inside an object plist means "omit this key" when encoding.
;; Use `:false' / `:null' for an explicit false / null.  Empty JSON objects
;; are represented with a hash-table (see `pai-json-empty-object').

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;;;; Booleans

(defconst pai-true t "Canonical JSON true in pai's data model.")
(defconst pai-false :false "Canonical JSON false in pai's data model.")
(defconst pai-null :null "Canonical JSON null in pai's data model.")

(defun pai-truthy (value)
  "Return non-nil if VALUE is truthy in pai's data model.
Both nil and `:false' are falsey; everything else is truthy."
  (not (or (null value) (eq value :false))))

;;;; JSON

(defun pai-json-empty-object ()
  "Return a value that encodes to an empty JSON object `{}'."
  (make-hash-table :test 'equal :size 1))

(defun pai-json--plistp (x)
  "Return non-nil if X is a plist (a list whose first element is a keyword)."
  (and (consp x) (keywordp (car x))))

(defun pai-json--prepare (value)
  "Convert internal VALUE into a shape `json-serialize' accepts.
Objects become keyword plists (nil-valued keys omitted), arrays become
vectors, symbols other than t become strings."
  (cond
   ((eq value t) t)
   ((eq value :false) :false)
   ((eq value :null) :null)
   ((hash-table-p value)
    (let ((out (make-hash-table :test 'equal :size (max 1 (hash-table-count value)))))
      (maphash (lambda (k v)
                 (puthash (if (keywordp k) (substring (symbol-name k) 1)
                            (format "%s" k))
                          (pai-json--prepare v) out))
               value)
      out))
   ((numberp value) value)
   ((stringp value) value)
   ((keywordp value) (substring (symbol-name value) 1))
   ((pai-json--plistp value)
    (let (out (rest value))
      (while rest
        (let ((k (car rest)) (v (cadr rest)))
          (when (not (null v))
            (push k out)
            (push (pai-json--prepare v) out)))
        (setq rest (cddr rest)))
      (nreverse out)))
   ((listp value) (apply #'vector (mapcar #'pai-json--prepare value)))
   ((vectorp value) (apply #'vector (mapcar #'pai-json--prepare (append value nil))))
   ((symbolp value) (symbol-name value))
   (t value)))

(defun pai-json-encode (value)
  "Encode internal VALUE to a JSON string."
  (json-serialize (pai-json--prepare value)
                  :false-object :false
                  :null-object :null))

(defun pai-json-decode (string)
  "Decode JSON STRING into internal representation."
  (json-parse-string string
                     :object-type 'plist
                     :array-type 'list
                     :null-object :null
                     :false-object :false))

(defun pai-json-decode-buffer ()
  "Decode JSON from point in the current buffer into internal representation."
  (json-parse-buffer :object-type 'plist
                     :array-type 'list
                     :null-object :null
                     :false-object :false))

;;;; Time and identifiers

(defun pai-now-ms ()
  "Return the current time as integer milliseconds since the epoch."
  (truncate (* 1000 (float-time))))

(defun pai-uuidv7 ()
  "Return a UUIDv7 string: 48-bit ms timestamp + random, time-ordered."
  (let* ((ms (pai-now-ms))
         (ts (format "%012x" (logand ms #xffffffffffff)))
         (r (lambda (n) (random n))))
    (format "%s-%s-7%s-%x%s-%s"
            (substring ts 0 8)
            (substring ts 8 12)
            (format "%03x" (funcall r #x1000))
            (+ 8 (funcall r 4))              ;variant bits 10xx
            (format "%03x" (funcall r #x1000))
            (format "%04x%08x" (funcall r #x10000) (funcall r #x100000000)))))

;;;; Content-block constructors

(defun pai-text (text &optional signature)
  "Make a text content block for TEXT with optional SIGNATURE."
  (append (list :type 'text :text text)
          (when signature (list :text-signature signature))))

(defun pai-thinking (thinking &optional signature redacted)
  "Make a thinking content block.
THINKING is the reasoning text, SIGNATURE the opaque replay data, and
REDACTED non-nil marks safety-redacted reasoning."
  (append (list :type 'thinking :thinking thinking)
          (when signature (list :thinking-signature signature))
          (when redacted (list :redacted t))))

(defun pai-image (data mime-type)
  "Make an image content block from base64 DATA with MIME-TYPE."
  (list :type 'image :data data :mime-type mime-type))

(defun pai-tool-call (id name arguments &rest extra)
  "Make a tool-call content block.
ID is the provider call id, NAME the tool name, ARGUMENTS a plist of
validated arguments.  EXTRA may include :thought-signature or :namespace."
  (append (list :type 'tool-call :id id :name name :arguments arguments) extra))

(defun pai-block-type (block)
  "Return the type symbol of content BLOCK."
  (plist-get block :type))

(defun pai-content-text (content)
  "Return the concatenated text of CONTENT (string or block list)."
  (cond
   ((stringp content) content)
   ((listp content)
    (mapconcat (lambda (b)
                 (pcase (pai-block-type b)
                   ('text (or (plist-get b :text) ""))
                   (_ "")))
               content ""))
   (t "")))

(defun pai-normalize-content (content)
  "Normalize CONTENT to a list of content blocks.
A string becomes a single text block; a list is returned as-is."
  (cond
   ((stringp content) (list (pai-text content)))
   ((null content) nil)
   ((listp content) content)
   (t (list (pai-text (format "%s" content))))))

;;;; Usage

(defun pai-usage (&rest kv)
  "Make a usage plist from KV, defaulting all token counts to 0.
KV overrides may set :input :output :cache-read :cache-write :reasoning
:total-tokens :cost."
  (let ((u (list :input 0 :output 0 :cache-read 0 :cache-write 0 :total-tokens 0
                 :cost (list :input 0.0 :output 0.0 :cache-read 0.0
                             :cache-write 0.0 :total 0.0))))
    (while kv
      (setq u (plist-put u (car kv) (cadr kv)))
      (setq kv (cddr kv)))
    u))

(defun pai-usage-add (a b)
  "Return the element-wise sum of usage plists A and B."
  (cl-flet ((g (u k) (or (plist-get u k) 0)))
    (pai-usage
     :input (+ (g a :input) (g b :input))
     :output (+ (g a :output) (g b :output))
     :cache-read (+ (g a :cache-read) (g b :cache-read))
     :cache-write (+ (g a :cache-write) (g b :cache-write))
     :reasoning (+ (g a :reasoning) (g b :reasoning))
     :total-tokens (+ (g a :total-tokens) (g b :total-tokens))
     ;; dollars a provider reported; kept only when one side has them
     :reported-cost (let ((ra (plist-get a :reported-cost))
                          (rb (plist-get b :reported-cost)))
                      (and (or (numberp ra) (numberp rb))
                           (+ (if (numberp ra) ra 0) (if (numberp rb) rb 0)))))))

;;;; Message constructors

(defun pai-system-message (content &rest extra)
  "Make a system message with CONTENT and optional EXTRA plist keys.
EXTRA may include :sections, :tools-added, :tools-removed."
  (append (list :role 'system :content content) extra
          (list :timestamp (pai-now-ms))))

(defun pai-user-message (content &rest extra)
  "Make a user message with CONTENT (string or blocks) and EXTRA keys."
  (append (list :role 'user :content content) extra
          (list :timestamp (pai-now-ms))))

(cl-defun pai-assistant-message (&key (content nil) (api "unknown")
                                      (provider "unknown") (model "unknown")
                                      (usage (pai-usage)) (stop-reason 'pending)
                                      response-id response-model error-message
                                      (timestamp (pai-now-ms)))
  "Make an assistant message plist from keyword arguments."
  (append (list :role 'assistant :content content :api api :provider provider
                :model model :usage usage :stop-reason stop-reason)
          (when response-id (list :response-id response-id))
          (when response-model (list :response-model response-model))
          (when error-message (list :error-message error-message))
          (list :timestamp timestamp)))

(cl-defun pai-tool-result-message (&key tool-call-id tool-name (content nil)
                                        details (is-error nil) usage
                                        (timestamp (pai-now-ms)))
  "Make a tool-result message plist from keyword arguments."
  (append (list :role 'tool-result :tool-call-id tool-call-id :tool-name tool-name
                :content (pai-normalize-content content)
                :is-error (if is-error t :false))
          (when details (list :details details))
          (when usage (list :usage usage))
          (list :timestamp timestamp)))

;;;; Message accessors and predicates

(defun pai-message-role (message)
  "Return the role symbol of MESSAGE."
  (plist-get message :role))

(defun pai-message-content (message)
  "Return the content of MESSAGE."
  (plist-get message :content))

(defun pai-system-message-p (m) (eq (pai-message-role m) 'system))
(defun pai-user-message-p (m) (eq (pai-message-role m) 'user))
(defun pai-assistant-message-p (m) (eq (pai-message-role m) 'assistant))
(defun pai-tool-result-message-p (m) (eq (pai-message-role m) 'tool-result))

(defun pai-message-tool-calls (message)
  "Return the list of tool-call blocks in assistant MESSAGE."
  (when (pai-assistant-message-p message)
    (seq-filter (lambda (b) (eq (pai-block-type b) 'tool-call))
                (pai-message-content message))))

(defconst pai-orphan-tool-call-text
  "Tool call was interrupted before it produced a result (session crashed or run aborted)."
  "Content of the synthetic result given to a tool call that has none.")

(defun pai-repair-tool-pairing (messages)
  "Return MESSAGES with every tool call answered by exactly one tool result.
Providers reject a transcript where an assistant tool call is not followed
by its result (e.g. Anthropic's \"`tool_use' ids were found without
`tool_result' blocks\"), which happens when a session crashed or a run was
aborted mid-tool.  Missing results are synthesized as errors right after
the tool results that do follow the call; results whose call is not in the
preceding assistant message, or duplicate results, are dropped.  MESSAGES
is returned unchanged (`eq') when it needs no repair."
  (let ((out '()) (pending nil) (changed nil))
    (cl-flet ((flush ()
                (dolist (tc (nreverse pending))
                  (setq changed t)
                  (push (pai-tool-result-message
                         :tool-call-id (plist-get tc :id)
                         :tool-name (plist-get tc :name)
                         :content pai-orphan-tool-call-text
                         :is-error t)
                        out))
                (setq pending nil)))
      (dolist (m messages)
        (if (pai-tool-result-message-p m)
            (let ((tc (seq-find (lambda (c) (equal (plist-get c :id)
                                                   (plist-get m :tool-call-id)))
                                pending)))
              (if (not tc)
                  (setq changed t)
                (setq pending (delq tc pending))
                (push m out)))
          (flush)
          (push m out)
          (setq pending (reverse (pai-message-tool-calls m)))))
      (flush))
    (if changed (nreverse out) messages)))

;;;; Error result helpers

(defun pai-tool-error-result (text &optional details)
  "Make an error tool result whose content is TEXT with optional DETAILS."
  (append (list :content (list (pai-text text)) :is-error t)
          (when details (list :details details))))

(defun pai-tool-ok-result (content &optional details)
  "Make a successful tool result from CONTENT with optional DETAILS.
CONTENT may be a string or a list of content blocks."
  (append (list :content (pai-normalize-content content) :is-error :false)
          (when details (list :details details))))

(provide 'pai-core)
;;; pai-core.el ends here
