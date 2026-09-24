;;; pai-provider-gemini.el --- Google Gemini provider -*- lexical-binding: t; -*-

;;; Commentary:

;; Provider for the Google Generative Language API (api symbol
;; `google-generative-ai').  Port of the essentials of
;; packages/ai/src/api/google-generative-ai.ts.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-core)
(require 'pai-models)
(require 'pai-provider)
(require 'pai-stream)

;;;; Request building

(defun pai-gemini--parts (content)
  "Translate unified CONTENT blocks to Gemini parts."
  (mapcar (lambda (b)
            (pcase (pai-block-type b)
              ('text (list :text (or (plist-get b :text) "")))
              ('image (list :inlineData (list :mimeType (plist-get b :mime-type)
                                              :data (plist-get b :data))))
              ('tool-call (list :functionCall (list :name (plist-get b :name)
                                                    :args (or (plist-get b :arguments)
                                                              (pai-json-empty-object)))))
              (_ (list :text ""))))
          (pai-normalize-content content)))

(defun pai-gemini--push-user (acc parts)
  "Push user PARTS onto reversed contents ACC, merging with a trailing user."
  (let ((head (car acc)))
    (if (and head (equal (plist-get head :role) "user"))
        (progn (setcar acc (list :role "user" :parts (append (plist-get head :parts) parts)))
               acc)
      (cons (list :role "user" :parts parts) acc))))

(defun pai-gemini--contents (messages)
  "Translate unified MESSAGES (sans system) to a Gemini contents array."
  (let (acc)
    (dolist (m messages)
      (pcase (pai-message-role m)
        ('user (setq acc (pai-gemini--push-user acc (pai-gemini--parts (pai-message-content m)))))
        ('assistant (push (list :role "model" :parts (pai-gemini--parts (pai-message-content m))) acc))
        ('tool-result
         (setq acc (pai-gemini--push-user
                    acc (list (list :functionResponse
                                    (list :name (plist-get m :tool-name)
                                          :response (list :result (pai-content-text
                                                                   (plist-get m :content)))))))))
        ('system nil)))
    (nreverse acc)))

(defun pai-gemini--schema (schema)
  "Return SCHEMA without `additionalProperties', which Gemini rejects.
Plists are cleaned recursively; other values are returned unchanged."
  (cond
   ((and (consp schema) (keywordp (car schema)))
    (let (out (rest schema))
      (while rest
        (unless (eq (car rest) :additionalProperties)
          (setq out (cons (pai-gemini--schema (cadr rest)) (cons (car rest) out))))
        (setq rest (cddr rest)))
      (nreverse out)))
   ((consp schema) (mapcar #'pai-gemini--schema schema))
   (t schema)))

(defun pai-gemini--tools (tools)
  "Translate unified TOOLS declarations to a Gemini tools array, or nil."
  (when tools
    (list (list :functionDeclarations
                (mapcar (lambda (tool)
                          (list :name (plist-get tool :name)
                                :description (or (plist-get tool :description) "")
                                :parameters (or (pai-gemini--schema (plist-get tool :parameters))
                                                (list :type "object"
                                                      :properties (pai-json-empty-object)))))
                        tools)))))

(defun pai-gemini--thinking-budget (level)
  "Return a Gemini thinkingBudget in tokens for LEVEL symbol."
  (pcase level
    ('minimal 512) ('low 2048) ('medium 8192) ('high 16384) ('xhigh 24576)
    ('max -1) (_ 8192)))

(defun pai-gemini-build-request (model context options)
  "Build a Gemini streamGenerateContent request plist for MODEL, CONTEXT, OPTIONS."
  (let* ((messages (plist-get context :messages))
         (system (pai-gemini--system messages))
         (tools (pai-gemini--tools (plist-get context :tools)))
         (reasoning (plist-get options :reasoning))
         (max-tokens (or (plist-get options :max-tokens) (plist-get model :max-tokens) pai-max-tokens))
         (gen-config (append
                      (list :maxOutputTokens max-tokens)
                      (when (plist-get options :temperature)
                        (list :temperature (plist-get options :temperature)))
                      (when (and reasoning (pai-model-reasoning-p model))
                        (list :thinkingConfig
                              (list :includeThoughts t
                                    :thinkingBudget (pai-gemini--thinking-budget reasoning))))))
         (tool-choice (plist-get options :tool-choice))
         (tool-config (when (and tools tool-choice)
                        (list :functionCallingConfig
                              (list :mode (pcase tool-choice
                                            ('none "NONE")
                                            ((or 'required 'any) "ANY")
                                            (_ "AUTO"))))))
         (body (append
                (list :contents (pai-gemini--contents messages)
                      :generationConfig gen-config)
                (when system (list :systemInstruction (list :parts (list (list :text system)))))
                (when tools (list :tools tools))
                (when tool-config (list :toolConfig tool-config)))))
    (list :url (format "%s/models/%s:streamGenerateContent?alt=sse"
                       (plist-get model :base-url) (plist-get model :id))
          :headers (list (cons "x-goog-api-key" (or (plist-get options :api-key) ""))
                         (cons "content-type" "application/json"))
          :body body)))

(defun pai-gemini--system (messages)
  "Return the system prompt string from MESSAGES, independent of load order."
  (let ((parts (delq nil
                     (mapcar (lambda (m)
                               (when (pai-system-message-p m)
                                 (let ((txt (pai-content-text (pai-message-content m))))
                                   (unless (string-empty-p txt) txt))))
                             messages))))
    (when parts (string-join parts "\n\n"))))

;;;; Stream parsing

(defun pai-gemini--stop (reason saw-call)
  "Map a Gemini finishReason REASON to a unified stop symbol.
SAW-CALL non-nil forces `tool-use'."
  (cond
   (saw-call 'tool-use)
   ((equal reason "MAX_TOKENS") 'length)
   ((member reason '("STOP" nil)) 'stop)
   (t 'stop)))

(defun pai-gemini-make-parser (model emit)
  "Return a Gemini SSE parser plist (:on-frame :on-close) for MODEL, EMIT."
  (let ((acc (pai-accum-new model))
        (open nil)          ; (KIND . our-index) for the current text/thinking block
        (call-counter 0)
        (saw-call nil)
        (reason nil) (done nil))
    (cl-labels
        ((close-open ()
           (when open
             (pcase (car open)
               ('text (pai-accum-text-end acc emit (cdr open)))
               ('thinking (pai-accum-thinking-end acc emit (cdr open))))
             (setq open nil)))
         (ensure (kind)
           (unless (and open (eq (car open) kind))
             (close-open)
             (setq open (cons kind (pcase kind
                                     ('text (pai-accum-text-start acc emit))
                                     ('thinking (pai-accum-thinking-start acc emit)))))))
         (finalize ()
           (unless done
             (setq done t)
             (close-open)
             (pai-accum-done acc emit (pai-gemini--stop reason saw-call))))
         (handle (frame)
           (let* ((data (condition-case nil (pai-json-decode (plist-get frame :data)) (error nil))))
             (when data
               (pai-accum-start acc emit)
               (when (plist-get data :responseId)
                 (setf (pai-accum-response-id acc) (plist-get data :responseId)))
               (let* ((cand (car (plist-get data :candidates)))
                      (parts (plist-get (plist-get cand :content) :parts))
                      (finish (plist-get cand :finishReason))
                      (usage (plist-get data :usageMetadata)))
                 (dolist (part parts)
                   (cond
                    ((plist-get part :functionCall)
                     (close-open)
                     (setq saw-call t)
                     (let* ((fc (plist-get part :functionCall))
                            (oi (pai-accum-toolcall-start
                                 acc emit (format "call_%d" (cl-incf call-counter))
                                 (plist-get fc :name))))
                       (pai-accum-toolcall-end acc emit oi (plist-get fc :args))))
                    ((and (pai-truthy (plist-get part :thought)) (plist-get part :text))
                     (ensure 'thinking)
                     (pai-accum-thinking-delta acc emit (cdr open) (plist-get part :text)))
                    ((plist-get part :text)
                     (ensure 'text)
                     (pai-accum-text-delta acc emit (cdr open) (plist-get part :text)))))
                 (when usage
                   (let ((input (or (plist-get usage :promptTokenCount) 0))
                         (output (or (plist-get usage :candidatesTokenCount) 0)))
                     (pai-accum-set-usage
                      acc (pai-usage :input input :output output
                                     :reasoning (or (plist-get usage :thoughtsTokenCount) 0)
                                     :total-tokens (or (plist-get usage :totalTokenCount)
                                                       (+ input output))))))
                 (when (and finish (not (eq finish :null)))
                   (setq reason finish))))))
         (close (_code) (finalize))
         (errf (msg)
           (unless done
             (setq done t)
             (close-open)
             (pai-accum-error acc emit 'error msg))))
      (list :on-frame #'handle :on-close #'close :on-error #'errf))))

(provide 'pai-provider-gemini)
;;; pai-provider-gemini.el ends here
