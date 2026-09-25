;;; pai-provider.el --- Provider registry and stream dispatch -*- lexical-binding: t; -*-

;;; Commentary:

;; The provider registry and the `pai-provider-stream' entry point used by the
;; agent loop.  A provider is a plist:
;;
;;   (:id STRING
;;    :build-request (lambda (MODEL CONTEXT OPTIONS) -> (:url :headers :body))
;;    :make-parser   (lambda (MODEL EMIT) -> (:on-frame FN :on-close FN)))
;;
;; where CONTEXT is `(:messages LIST :tools LIST)', OPTIONS a plist that
;; includes the resolved :api-key, and :body an internal object to JSON-encode.
;; The parser's :on-frame receives SSE frame plists `(:event :data)'; :on-close
;; receives the curl exit code and should finalize the stream if not already
;; done.
;;
;; A provider may instead supply `:stream (lambda (MODEL CONTEXT OPTIONS EMIT))'
;; to bypass HTTP entirely (used by the faux provider in tests).

;;; Code:

(require 'cl-lib)
(require 'pai-core)
(require 'pai-config)
(require 'pai-models)
(require 'pai-http)
(require 'pai-stream)

(defvar pai--providers (make-hash-table :test 'equal)
  "Hash table mapping provider id (string) to a provider plist.")

(defun pai-register-provider (provider)
  "Register PROVIDER (a plist) keyed by its :id.  Return PROVIDER."
  (puthash (plist-get provider :id) provider pai--providers)
  provider)

(defun pai-provider (id)
  "Return the provider plist for ID, or nil."
  (gethash id pai--providers))

(defun pai-provider-for-model (model)
  "Return the provider plist for MODEL, or nil."
  (pai-provider (pai-model-provider model)))

(defun pai-context (messages &optional tools)
  "Build a transcript context plist from MESSAGES and TOOLS."
  (list :messages messages :tools tools))

(defun pai-provider-stream (model context options emit)
  "Stream an assistant response for MODEL over CONTEXT.
OPTIONS is a plist (:api-key :max-tokens :temperature :reasoning :tools ...).
EMIT is called with each unified `AssistantMessageEvent'.  Return a handle
\(a process, or nil) that can be passed to `pai-provider-abort'."
  (let ((provider (pai-provider-for-model model)))
    (if (not provider)
        (let ((acc (pai-accum-new model)))
          (pai-accum-start acc emit)
          (pai-accum-error acc emit 'error
                           (format "No provider registered for %S"
                                   (pai-model-provider model)))
          nil)
      (let* ((key (or (plist-get options :api-key)
                      (pai-api-key (pai-model-provider model))))
             (provider-id (pai-model-provider model))
             (env-vars (cdr (assoc provider-id pai-provider-env-keys)))
             (options (plist-put (copy-sequence options) :api-key key))
             (stream-fn (plist-get provider :stream)))
        (if (and (or (null key) (string-empty-p key)) env-vars)
            ;; The provider declares an API key but none resolved; fail with an
            ;; actionable message instead of sending an empty bearer token.
            (let ((acc (pai-accum-new model)))
              (pai-accum-start acc emit)
              (pai-accum-error
               acc emit 'error
               (format "No API key for provider %S. Set it with `/login %s', `pai-api-keys', or the %s environment variable (note: GUI Emacs may not inherit your shell environment)."
                       provider-id provider-id
                       (mapconcat #'identity env-vars " or ")))
              nil)
          (if stream-fn
              (funcall stream-fn model context options emit)
            (pai-provider--http-stream provider model context options emit)))))))

;;;; Request bodies
;;
;; A long session sends the whole transcript on every turn.  Encoding it anew
;; each time -- `json-serialize' plus the UTF-8 copy `process-send-string'
;; makes of a multibyte string -- produced several megabytes of garbage per
;; turn, and with it a GC pause every few turns.  The conversation array is
;; therefore encoded element by element: every element's JSON is kept as a
;; unibyte UTF-8 fragment, and the body is sent to curl as a list of pieces.
;; Unchanged messages then cost nothing: no serializing, no concatenation, no
;; encoding (a unibyte string is sent as is).

(defconst pai-provider--conversation-keys '(:messages :contents :input)
  "Body keys that may hold the conversation array, in order of preference.")

(defconst pai-provider--marker "pai-conversation-placeholder-7f3e2c9a4b51d086"
  "Placeholder encoded in place of the conversation array.")

(defconst pai-provider--comma (encode-coding-string "," 'utf-8))
(defconst pai-provider--open (encode-coding-string "[" 'utf-8))
(defconst pai-provider--close (encode-coding-string "]" 'utf-8))

(defvar-local pai-provider--fragments nil
  "Encoded conversation elements: ELEMENT (compared with `equal') -> (JSON . GEN).
JSON is the element's unibyte UTF-8 encoding; GEN the last request using it.")

(defvar-local pai-provider--generation 0
  "Number of request bodies encoded in this buffer.")

(defconst pai-provider-fragment-generations 4
  "Encoded elements unused for this many requests are dropped.
More than one, so runs sharing a buffer (a subagent next to the main
run) keep each other's entries.")

(defun pai-provider--utf8 (string)
  "Return STRING as a unibyte UTF-8 string (a new string)."
  (encode-coding-string string 'utf-8))

(defun pai-provider-encode-body (body)
  "Encode request BODY as JSON; return a list of unibyte strings to send in order.
Their concatenation is exactly the UTF-8 encoding of `pai-json-encode' of
BODY.  The conversation array (see `pai-provider--conversation-keys') is
encoded element by element with each element's JSON cached in this buffer,
so a turn only encodes what changed."
  (let ((key (and (consp body) (keywordp (car body))
                  (seq-find (lambda (k) (let ((v (plist-get body k))) (and (consp v) (cdr v))))
                            pai-provider--conversation-keys))))
    (if (not key)
        (list (pai-provider--utf8 (pai-json-encode body)))
      (let* ((cache (or pai-provider--fragments
                        (setq pai-provider--fragments (make-hash-table :test 'equal))))
             (gen (setq pai-provider--generation (1+ pai-provider--generation)))
             (envelope (pai-provider--utf8
                        (pai-json-encode (plist-put (copy-sequence body) key pai-provider--marker))))
             (quoted (concat "\"" pai-provider--marker "\""))
             (at (string-search quoted envelope))
             ;; built in reverse, see the `nreverse' below
             (pieces (list pai-provider--open (substring envelope 0 at))))
        (let ((first t))
          (dolist (element (plist-get body key))
            (let ((hit (gethash element cache)))
              (if hit
                  (setcdr hit gen)
                (setq hit (cons (pai-provider--utf8 (pai-json-encode element)) gen))
                (puthash element hit cache))
              (unless first (push pai-provider--comma pieces))
              (setq first nil)
              (push (car hit) pieces))))
        (push pai-provider--close pieces)
        (push (substring envelope (+ at (length quoted))) pieces)
        ;; forget elements no recent request used
        (maphash (lambda (k v)
                   (when (< (cdr v) (- gen pai-provider-fragment-generations))
                     (remhash k cache)))
                 cache)
        (nreverse pieces)))))

(defun pai-provider--http-stream (provider model context options emit)
  "Run the HTTP streaming path for PROVIDER in the originating buffer.
Discard deferred parser callbacks if that buffer has been killed."
  (let* ((origin-buffer (current-buffer))
         (req (funcall (plist-get provider :build-request) model context options))
         (parser (funcall (plist-get provider :make-parser) model emit))
         (on-frame (plist-get parser :on-frame))
         (on-close (plist-get parser :on-close))
         (on-error (plist-get parser :on-error))
         (body (plist-get req :body))
         (body-str (cond ((null body) nil)
                         ((stringp body) body)
                         (t (pai-provider-encode-body body))))
         (errored nil))
    (pai-http-stream
     :url (plist-get req :url)
     :method (or (plist-get req :method) "POST")
     :headers (plist-get req :headers)
     :body body-str
     :on-frame (lambda (frame)
                 (when (buffer-live-p origin-buffer)
                   (with-current-buffer origin-buffer
                     (funcall on-frame frame))))
     :on-error (lambda (msg)
                 (when (buffer-live-p origin-buffer)
                   (with-current-buffer origin-buffer
                     (setq errored t)
                     ;; Let the parser finalize as an error, keeping any
                     ;; partial assistant content streamed so far.
                     (if on-error
                         (funcall on-error msg)
                       (let ((acc (pai-accum-new model)))
                         (pai-accum-start acc emit)
                         (pai-accum-error acc emit 'error msg))))))
     :on-close (lambda (code)
                 (when (buffer-live-p origin-buffer)
                   (with-current-buffer origin-buffer
                     (unless errored (funcall on-close code))))))))

(defun pai-provider-abort (handle)
  "Abort a streaming request identified by HANDLE."
  (when (and handle (processp handle) (process-live-p handle))
    (delete-process handle)))

;;;; Shared request-building helpers used by concrete providers

(defun pai-provider--tool-declarations (context)
  "Return the tool declaration list from CONTEXT, or nil."
  (plist-get context :tools))
(defun pai-provider-stream-sync (model context options &optional timeout on-event)
  "Stream MODEL over CONTEXT synchronously and return the final assistant message.
Blocks (pumping process output) until the stream produces a `done' or `error'
event, or TIMEOUT seconds (default 180) elapse.  Returns nil on timeout.
ON-EVENT, when non-nil, is called with every stream event (e.g. to show
progress; timers keep running while this blocks, but Emacs only redraws
when asked to)."
  (let ((final nil) (done nil))
    (pai-provider-stream
     model context options
     (lambda (ev)
       (when on-event
         (condition-case err (funcall on-event ev)
           (error (message "pai: stream progress handler: %s" (error-message-string err)))))
       (when (memq (plist-get ev :type) '(done error))
         (setq final (plist-get ev :message) done t))))
    (let ((deadline (+ (float-time) (or timeout 180))))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output nil 0.05)))
    final))


(provide 'pai-provider)
;;; pai-provider.el ends here
