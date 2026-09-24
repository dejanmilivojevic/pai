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
                         (t (pai-json-encode body))))
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
