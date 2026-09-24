;;; pai-provider-openai.el --- OpenAI Chat Completions provider -*- lexical-binding: t; -*-

;;; Commentary:

;; Provider for the OpenAI Chat Completions API (api symbol
;; `openai-completions').  Also works for the many OpenAI-compatible servers
;; (Groq, DeepSeek, OpenRouter, local llama.cpp/vLLM) by overriding the model
;; :base-url and :provider.  Port of the essentials of
;; packages/ai/src/api/openai-completions.ts.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-core)
(require 'pai-models)
(require 'pai-provider)
(require 'pai-stream)

;;;; Request building

(defun pai-openai--user-content (content)
  "Translate unified user CONTENT to an OpenAI message content value.
Returns a plain string when there are no images, else an array of parts."
  (let ((blocks (pai-normalize-content content)))
    (if (seq-every-p (lambda (b) (eq (pai-block-type b) 'text)) blocks)
        (pai-content-text blocks)
      (mapcar (lambda (b)
                (pcase (pai-block-type b)
                  ('text (list :type "text" :text (or (plist-get b :text) "")))
                  ('image (list :type "image_url"
                                :image_url (list :url (format "data:%s;base64,%s"
                                                              (plist-get b :mime-type)
                                                              (plist-get b :data)))))
                  (_ (list :type "text" :text ""))))
              blocks))))

(defun pai-openai--assistant-tool-calls (content)
  "Return an OpenAI tool_calls array from assistant CONTENT, or nil."
  (let ((calls (seq-filter (lambda (b) (eq (pai-block-type b) 'tool-call)) content)))
    (when calls
      (mapcar (lambda (tc)
                (list :id (plist-get tc :id)
                      :type "function"
                      :function (list :name (plist-get tc :name)
                                      :arguments (pai-json-encode
                                                  (or (plist-get tc :arguments)
                                                      (pai-json-empty-object))))))
              calls))))

(defun pai-openai--messages (messages)
  "Translate unified MESSAGES to an OpenAI messages array."
  (let (out)
    (dolist (m messages)
      (pcase (pai-message-role m)
        ('system (push (list :role "system" :content (pai-content-text (pai-message-content m))) out))
        ('user (push (list :role "user" :content (pai-openai--user-content (pai-message-content m))) out))
        ('tool-result
         (push (list :role "tool"
                     :tool_call_id (plist-get m :tool-call-id)
                     :content (pai-content-text (plist-get m :content)))
               out))
        ('assistant
         (let* ((content (pai-message-content m))
                (text (pai-content-text content))
                (tool-calls (pai-openai--assistant-tool-calls content)))
           (push (append (list :role "assistant")
                         (list :content (if (string-empty-p text) :null text))
                         (when tool-calls (list :tool_calls tool-calls)))
                 out)))))
    (nreverse out)))

(defun pai-openai--tools (tools)
  "Translate unified TOOLS declarations to OpenAI tool objects, or nil."
  (when tools
    (mapcar (lambda (tool)
              (list :type "function"
                    :function (list :name (plist-get tool :name)
                                    :description (or (plist-get tool :description) "")
                                    :parameters (or (plist-get tool :parameters)
                                                    (list :type "object"
                                                          :properties (pai-json-empty-object))))))
            tools)))

(defun pai-openai--reasoning-effort (level)
  "Map a unified thinking LEVEL symbol to an OpenAI reasoning_effort string."
  (pcase level
    ('minimal "minimal") ('low "low") ('medium "medium")
    ('high "high") ('xhigh "high") ('max "high") (_ "medium")))

(defun pai-openai--tool-choice (tc)
  "Map a unified tool-choice TC to an OpenAI tool_choice value."
  (pcase tc
    ('auto "auto") ('none "none") ((or 'required 'any) "required")
    (`(tool . ,name) (list :type "function" :function (list :name name)))
    (_ "auto")))

(defun pai-openai-build-request (model context options)
  "Build an OpenAI Chat Completions request plist for MODEL, CONTEXT, OPTIONS."
  (let* ((messages (plist-get context :messages))
         (tools (pai-openai--tools (plist-get context :tools)))
         (reasoning (plist-get options :reasoning))
         (max-tokens (or (plist-get options :max-tokens) (plist-get model :max-tokens) pai-max-tokens))
         (body (append
                (list :model (plist-get model :id)
                      :messages (pai-openai--messages messages)
                      :stream t
                      :stream_options (list :include_usage t)
                      :max_completion_tokens max-tokens)
                (when tools (list :tools tools))
                (when (plist-get options :tool-choice)
                  (list :tool_choice (pai-openai--tool-choice (plist-get options :tool-choice))))
                (when (plist-get options :session-id)
                  (list :prompt_cache_key (plist-get options :session-id)))
                ;; OpenRouter usage accounting: the final usage chunk then
                ;; reports the billed `cost'
                (when (pai-openai--openrouter-p model)
                  (list :usage (list :include t)))
                (when (and reasoning (pai-model-reasoning-p model))
                  (list :reasoning_effort (pai-openai--reasoning-effort reasoning)))
                (when (and (plist-get options :temperature) (not (pai-model-reasoning-p model)))
                  (list :temperature (plist-get options :temperature))))))
    (list :url (concat (plist-get model :base-url) "/chat/completions")
          :headers (list (cons "Authorization" (format "Bearer %s" (or (plist-get options :api-key) "")))
                         (cons "content-type" "application/json"))
          :body body)))

;;;; Stream parsing

(defun pai-openai--stop (reason)
  "Map an OpenAI finish REASON string to a unified stop-reason symbol."
  (pcase reason
    ("stop" 'stop) ("length" 'length) ("tool_calls" 'tool-use)
    ("function_call" 'tool-use) ("content_filter" 'stop) (_ 'stop)))

(defun pai-openai--apply-usage (acc u)
  "Apply an OpenAI usage object U to accumulator ACC.
`prompt_tokens' includes cached ones; they are split out so they are priced
at cache rates: `prompt_tokens_details.cached_tokens' (cache reads) and
`cache_write_tokens' (OpenRouter, for providers that bill cache writes).
A reported dollar `cost' (OpenRouter usage accounting) is kept as
:reported-cost."
  (let* ((prompt (or (plist-get u :prompt_tokens) 0))
         (output (or (plist-get u :completion_tokens) 0))
         (total (or (plist-get u :total_tokens) (+ prompt output)))
         (pdetails (plist-get u :prompt_tokens_details))
         (num (lambda (v) (if (numberp v) v 0)))
         (cache-read (funcall num (and (listp pdetails) (plist-get pdetails :cached_tokens))))
         (cache-write (funcall num (and (listp pdetails) (plist-get pdetails :cache_write_tokens))))
         (input (max 0 (- prompt cache-read cache-write)))
         (details (plist-get u :completion_tokens_details))
         (reasoning (and (listp details) (plist-get details :reasoning_tokens)))
         (cost (plist-get u :cost)))
    (pai-accum-set-usage acc (apply #'pai-usage
                                    :input input :output output
                                    :cache-read cache-read :cache-write cache-write
                                    :reasoning (funcall num reasoning)
                                    :total-tokens total
                                    (when (numberp cost) (list :reported-cost cost))))))

(defun pai-openai--openrouter-p (model)
  "Return non-nil when MODEL is served by OpenRouter."
  (let ((base (plist-get model :base-url)))
    (and (stringp base) (string-match-p "openrouter\\.ai" base))))

(defun pai-openai-make-parser (model emit)
  "Return an OpenAI SSE parser plist (:on-frame :on-close) for MODEL, EMIT."
  (let ((acc (pai-accum-new model))
        (text-oi nil)
        (thinking-oi nil)
        (tool-map (make-hash-table :test 'eql)) ; tool_call index -> our index
        (stop 'stop) (done nil))
    (cl-labels
        ((finalize ()
           (unless done
             (setq done t)
             (when thinking-oi (pai-accum-thinking-end acc emit thinking-oi))
             (when text-oi (pai-accum-text-end acc emit text-oi))
             (maphash (lambda (_i oi) (pai-accum-toolcall-end acc emit oi)) tool-map)
             (pai-accum-done acc emit stop)))
         (handle (frame)
           (let ((data-str (plist-get frame :data)))
             (if (equal (string-trim data-str) "[DONE]")
                 (finalize)
               (let* ((data (condition-case nil (pai-json-decode data-str) (error nil))))
                 (when data
                   (pai-accum-start acc emit)
                   (when (and (plist-get data :id) (not (pai-accum-response-id acc)))
                     (setf (pai-accum-response-id acc) (plist-get data :id)))
                   (when (plist-get data :usage)
                     (pai-openai--apply-usage acc (plist-get data :usage)))
                   (let* ((choice (car (plist-get data :choices)))
                          (delta (plist-get choice :delta))
                          (content (plist-get delta :content))
                          (reasoning (plist-get delta :reasoning_content))
                          (tool-calls (plist-get delta :tool_calls))
                          (finish (plist-get choice :finish_reason)))
                     (when (and (stringp reasoning) (not (string-empty-p reasoning)))
                       (unless thinking-oi (setq thinking-oi (pai-accum-thinking-start acc emit)))
                       (pai-accum-thinking-delta acc emit thinking-oi reasoning))
                     (when (and (stringp content) (not (string-empty-p content)))
                       (when (and thinking-oi (not text-oi))
                         (pai-accum-thinking-end acc emit thinking-oi)
                         (setq thinking-oi nil))
                       (unless text-oi (setq text-oi (pai-accum-text-start acc emit)))
                       (pai-accum-text-delta acc emit text-oi content))
                     (dolist (tc tool-calls)
                       (let* ((tidx (or (plist-get tc :index) 0))
                              (fn (plist-get tc :function))
                              (oi (gethash tidx tool-map)))
                         (unless oi
                           (setq oi (pai-accum-toolcall-start
                                     acc emit (or (plist-get tc :id) (format "call_%d" tidx))
                                     (or (plist-get fn :name) "")))
                           (puthash tidx oi tool-map))
                         (when (plist-get fn :arguments)
                           (pai-accum-toolcall-delta acc emit oi (plist-get fn :arguments)))))
                     (when (and finish (not (eq finish :null)))
                       (setq stop (pai-openai--stop finish)))))))))
         (close (_code) (finalize))
         (errf (msg)
           (unless done
             (setq done t)
             (when thinking-oi (pai-accum-thinking-end acc emit thinking-oi))
             (when text-oi (pai-accum-text-end acc emit text-oi))
             (pai-accum-error acc emit 'error msg))))
      (list :on-frame #'handle :on-close #'close :on-error #'errf))))

(provide 'pai-provider-openai)
;;; pai-provider-openai.el ends here
