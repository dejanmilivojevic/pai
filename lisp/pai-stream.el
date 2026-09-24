;;; pai-stream.el --- Assistant-message streaming accumulator -*- lexical-binding: t; -*-

;;; Commentary:

;; Shared machinery for turning a provider's incremental output into the
;; unified `AssistantMessageEvent' stream (see docs/ARCHITECTURE.md section 2).
;;
;; A `pai-accum' holds the assistant message being built.  Provider parsers
;; call the `pai-accum-*' operations, which mutate the accumulator and emit the
;; corresponding unified event via the EMIT callback.  Every event carries a
;; `:partial' snapshot of the assistant message so far.

;;; Code:

(require 'cl-lib)
(require 'pai-core)
(require 'pai-models)

(cl-defstruct (pai-accum (:constructor pai-accum-create))
  model
  (content '())            ; list of content blocks, in order
  usage
  (stop-reason 'pending)
  response-id
  response-model
  error-message
  started)                 ; non-nil once `start' has been emitted

(defun pai-accum-new (model)
  "Return a fresh accumulator for MODEL."
  (pai-accum-create :model model :usage (pai-usage)))

(defun pai-accum-message (acc)
  "Build an assistant message snapshot from accumulator ACC."
  (let ((m (pai-accum-model acc)))
    (pai-assistant-message
     :content (copy-sequence (pai-accum-content acc))
     :api (if m (symbol-name (pai-model-api m)) "unknown")
     :provider (if m (pai-model-provider m) "unknown")
     :model (if m (plist-get m :id) "unknown")
     :usage (or (pai-accum-usage acc) (pai-usage))
     :stop-reason (pai-accum-stop-reason acc)
     :response-id (pai-accum-response-id acc)
     :response-model (pai-accum-response-model acc)
     :error-message (pai-accum-error-message acc))))

(defun pai-accum--emit (acc emit type &rest props)
  "Emit a unified event of TYPE with PROPS plus a :partial snapshot via EMIT."
  (when emit
    (funcall emit (append (list :type type) props
                          (list :partial (pai-accum-message acc))))))

(defun pai-accum-nblocks (acc)
  "Return the number of content blocks in ACC."
  (length (pai-accum-content acc)))

(defun pai-accum-block (acc idx)
  "Return content block at IDX in ACC."
  (nth idx (pai-accum-content acc)))

(defun pai-accum-set-block (acc idx block)
  "Store BLOCK at IDX in ACC."
  (setf (nth idx (pai-accum-content acc)) block))

(defun pai-accum-push-block (acc block)
  "Append BLOCK to ACC's content; return its index."
  (let ((idx (pai-accum-nblocks acc)))
    (setf (pai-accum-content acc)
          (append (pai-accum-content acc) (list block)))
    idx))

;;;; Lifecycle events

(defun pai-accum-start (acc emit)
  "Emit the `start' event for ACC unless already started."
  (unless (pai-accum-started acc)
    (setf (pai-accum-started acc) t)
    (pai-accum--emit acc emit 'start)))

(defun pai-accum-set-usage (acc usage)
  "Set ACC's usage to USAGE."
  (setf (pai-accum-usage acc) usage))

(defun pai-accum-set-stop (acc reason)
  "Set ACC's stop reason to REASON."
  (setf (pai-accum-stop-reason acc) reason))

(defun pai-accum-done (acc emit reason)
  "Finalize ACC with stop REASON and emit the `done' event."
  (setf (pai-accum-stop-reason acc) reason)
  (pai-accum--emit acc emit 'done :reason reason :message (pai-accum-message acc)))

(defun pai-accum-error (acc emit reason message)
  "Finalize ACC as an error with REASON and MESSAGE, emit `error'."
  (setf (pai-accum-stop-reason acc) reason
        (pai-accum-error-message acc) message)
  (pai-accum--emit acc emit 'error :reason reason :message (pai-accum-message acc)))

;;;; Text blocks

(defun pai-accum-text-start (acc emit)
  "Begin a text block in ACC; emit `text-start'; return its index."
  (let ((idx (pai-accum-push-block acc (pai-text ""))))
    (pai-accum--emit acc emit 'text-start :content-index idx)
    idx))

(defun pai-accum-text-delta (acc emit idx delta)
  "Append DELTA to the text block at IDX in ACC; emit `text-delta'."
  (let ((block (pai-accum-block acc idx)))
    (pai-accum-set-block acc idx (plist-put block :text (concat (plist-get block :text) delta)))
    (pai-accum--emit acc emit 'text-delta :content-index idx :delta delta)))

(defun pai-accum-text-end (acc emit idx)
  "Finish the text block at IDX in ACC; emit `text-end'."
  (pai-accum--emit acc emit 'text-end :content-index idx
                   :content (plist-get (pai-accum-block acc idx) :text)))

;;;; Thinking blocks

(defun pai-accum-thinking-start (acc emit &optional signature redacted)
  "Begin a thinking block in ACC; emit `thinking-start'; return its index."
  (let ((idx (pai-accum-push-block acc (pai-thinking "" signature redacted))))
    (pai-accum--emit acc emit 'thinking-start :content-index idx)
    idx))

(defun pai-accum-thinking-delta (acc emit idx delta)
  "Append DELTA to the thinking block at IDX in ACC; emit `thinking-delta'."
  (let ((block (pai-accum-block acc idx)))
    (pai-accum-set-block acc idx (plist-put block :thinking (concat (plist-get block :thinking) delta)))
    (pai-accum--emit acc emit 'thinking-delta :content-index idx :delta delta)))

(defun pai-accum-thinking-signature (acc idx signature)
  "Append SIGNATURE to the thinking block at IDX in ACC (no event)."
  (let ((block (pai-accum-block acc idx)))
    (pai-accum-set-block acc idx
                         (plist-put block :thinking-signature
                                    (concat (or (plist-get block :thinking-signature) "") signature)))))

(defun pai-accum-thinking-end (acc emit idx)
  "Finish the thinking block at IDX in ACC; emit `thinking-end'."
  (pai-accum--emit acc emit 'thinking-end :content-index idx
                   :content (plist-get (pai-accum-block acc idx) :thinking)))

;;;; Tool-call blocks

(defun pai-accum-toolcall-start (acc emit id name &optional initial-json)
  "Begin a tool-call block (ID, NAME) in ACC; emit `toolcall-start'.
INITIAL-JSON seeds the arguments JSON buffer.  Return the block index."
  (let* ((block (append (pai-tool-call id name nil)
                        (list :_json (or initial-json ""))))
         (idx (pai-accum-push-block acc block)))
    (pai-accum--emit acc emit 'toolcall-start :content-index idx)
    idx))

(defun pai-accum-toolcall-delta (acc emit idx json-fragment)
  "Append JSON-FRAGMENT to the tool-call args buffer at IDX; emit `toolcall-delta'."
  (let ((block (pai-accum-block acc idx)))
    (pai-accum-set-block acc idx
                         (plist-put block :_json (concat (plist-get block :_json) json-fragment)))
    (pai-accum--emit acc emit 'toolcall-delta :content-index idx :delta json-fragment)))

(defun pai-accum--parse-args (json)
  "Parse tool-call arguments JSON, returning a plist (nil on empty/failure)."
  (if (or (null json) (string-empty-p (string-trim json)))
      nil
    (condition-case nil
        (pai-json-decode json)
      (error nil))))

(defun pai-accum-toolcall-end (acc emit idx &optional final-args)
  "Finish the tool-call block at IDX; emit `toolcall-end'.
FINAL-ARGS, when non-nil, is used directly as the parsed arguments plist;
otherwise the accumulated JSON buffer is parsed."
  (let* ((block (pai-accum-block acc idx))
         (args (or final-args (pai-accum--parse-args (plist-get block :_json))))
         (clean (pai-tool-call (plist-get block :id) (plist-get block :name) args)))
    (pai-accum-set-block acc idx clean)
    (pai-accum--emit acc emit 'toolcall-end :content-index idx :tool-call clean)))

(provide 'pai-stream)
;;; pai-stream.el ends here
