;;; pai-provider-anthropic-test.el --- Tests for the Anthropic provider -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai-core)
(require 'pai-models)
(require 'pai-provider)
(require 'pai-provider-anthropic)
(require 'pai-settings)

(defun pai-anthropic-test--model ()
  (pai-make-model :id "claude-sonnet-4" :api 'anthropic-messages
                  :provider "test-anthropic" :base-url "http://localhost:1234/v1"
                  :reasoning t))

(defun pai-anthropic-test--run (frames model)
  "Feed FRAMES (list of (:event :data)) to the Anthropic parser for MODEL.
Return the list of emitted unified events."
  (let* ((events '())
         (parser (pai-anthropic-make-parser model (lambda (ev) (push ev events))))
         (on-frame (plist-get parser :on-frame)))
    (dolist (f frames) (funcall on-frame f))
    (funcall (plist-get parser :on-close) 0)
    (nreverse events)))

;;;; Request building

(ert-deftest pai-anthropic-build-request-basic ()
  (let* ((pai-settings--global '(:prompt-cache :false))
         (pai-settings--project nil)
         (model (pai-anthropic-test--model))
         (ctx (pai-context (list (pai-system-message "be nice")
                                 (pai-user-message "hi"))
                           (list (list :name "bash" :description "run"
                                       :parameters (list :type "object")))))
         (req (pai-anthropic-build-request model ctx '(:api-key "sk-x" :max-tokens 1000)))
         (body (plist-get req :body)))
    (should (equal (plist-get req :url) "http://localhost:1234/v1/messages"))
    (should (equal (cdr (assoc "x-api-key" (plist-get req :headers))) "sk-x"))
    (should (equal (cdr (assoc "anthropic-version" (plist-get req :headers))) "2023-06-01"))
    (should (equal (plist-get body :model) "claude-sonnet-4"))
    (should (equal (plist-get body :max_tokens) 1000))
    (should (eq (plist-get body :stream) t))
    (should (equal (plist-get body :system) "be nice"))
    (should (= (length (plist-get body :messages)) 1))
    (should (equal (plist-get (car (plist-get body :messages)) :role) "user"))
    (should (= (length (plist-get body :tools)) 1))))

(ert-deftest pai-anthropic-caching-markers ()
  (let* ((pai-settings--global '(:prompt-cache t))
         (pai-settings--project nil)
         (model (pai-anthropic-test--model))
         (ctx (pai-context (list (pai-system-message "sys") (pai-user-message "hi"))
                           (list (list :name "bash" :description "d" :parameters (list :type "object")))))
         (req (pai-anthropic-build-request model ctx nil))
         (body (plist-get req :body))
         (json (pai-json-encode body)))
    ;; system is an array of text block(s) with cache_control
    (should (listp (plist-get body :system)))
    (should (string-match-p "cache_control" json))
    (should (string-match-p "ephemeral" json))
    ;; last tool carries a cache marker
    (should (plist-member (car (last (plist-get body :tools))) :cache_control))))

(ert-deftest pai-anthropic-tool-choice ()
  (let* ((pai-settings--global '(:prompt-cache :false)) (pai-settings--project nil)
         (model (pai-anthropic-test--model))
         (ctx (pai-context (list (pai-user-message "hi"))
                           (list (list :name "bash" :description "d" :parameters (list :type "object"))))))
    (should (equal (plist-get (plist-get (pai-anthropic-build-request model ctx '(:tool-choice required)) :body) :tool_choice)
                   '(:type "any")))
    (should (equal (plist-get (plist-get (pai-anthropic-build-request model ctx '(:tool-choice none)) :body) :tool_choice)
                   '(:type "none")))))

(ert-deftest pai-anthropic-messages-merge-tool-results ()
  ;; Two consecutive tool results must fold into one user message.
  (let* ((msgs (list (pai-user-message "do it")
                     (pai-assistant-message :content (list (pai-tool-call "t1" "bash" '(:command "ls"))
                                                           (pai-tool-call "t2" "bash" '(:command "pwd"))))
                     (pai-tool-result-message :tool-call-id "t1" :tool-name "bash" :content "a")
                     (pai-tool-result-message :tool-call-id "t2" :tool-name "bash" :content "b")))
         (out (pai-anthropic--messages msgs)))
    (should (= (length out) 3)) ; user, assistant, user(merged tool results)
    (should (equal (plist-get (nth 0 out) :role) "user"))
    (should (equal (plist-get (nth 1 out) :role) "assistant"))
    (should (equal (plist-get (nth 2 out) :role) "user"))
    (should (= (length (plist-get (nth 2 out) :content)) 2))
    (should (equal (plist-get (car (plist-get (nth 2 out) :content)) :type) "tool_result"))))

(ert-deftest pai-anthropic-empty-tool-args-encode-object ()
  ;; A tool call with no arguments must serialize input as {} not [].
  (let* ((blocks (pai-anthropic--content-blocks (list (pai-tool-call "t1" "noop" nil))))
         (json (pai-json-encode (car blocks))))
    (should (string-match-p "\"input\":{}" json))))

(ert-deftest pai-anthropic-image-block ()
  (let ((blocks (pai-anthropic--content-blocks (list (pai-image "BASE64" "image/png")))))
    (should (equal (plist-get (car blocks) :type) "image"))
    (should (equal (plist-get (plist-get (car blocks) :source) :media_type) "image/png"))))

(ert-deftest pai-anthropic-unsigned-thinking-dropped ()
  ;; An assistant turn persisted with only an empty, unsigned thinking
  ;; block (stream ended right after thinking started) must not be sent:
  ;; the API rejects it with `each thinking block must contain thinking'.
  (should (null (pai-anthropic--content-blocks (list (pai-thinking "" "")))))
  (should (null (pai-anthropic--content-blocks (list (pai-thinking "" nil)))))
  ;; Signed blocks with empty (omitted) thinking are still sent.
  (let ((b (car (pai-anthropic--content-blocks (list (pai-thinking "" "SIG"))))))
    (should (equal (plist-get b :type) "thinking"))
    (should (equal (plist-get b :signature) "SIG")))
  (let ((out (pai-anthropic--messages
              (list (pai-user-message "hi")
                    (pai-assistant-message :content (list (pai-thinking "" "")))
                    (pai-user-message "again")))))
    (should (= (length out) 1))
    (should (equal (plist-get (car out) :role) "user"))
    (should (= (length (plist-get (car out) :content)) 2))))

;;;; SSE parsing

(defconst pai-anthropic-test--frames
  '((:event "message_start"
     :data "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":10,\"output_tokens\":1}}}")
    (:event "content_block_start"
     :data "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}")
    (:event "content_block_delta"
     :data "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}")
    (:event "content_block_delta"
     :data "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" world\"}}")
    (:event "content_block_stop"
     :data "{\"type\":\"content_block_stop\",\"index\":0}")
    (:event "content_block_start"
     :data "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"bash\",\"input\":{}}}")
    (:event "content_block_delta"
     :data "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\"}}")
    (:event "content_block_delta"
     :data "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"ls\\\"}\"}}")
    (:event "content_block_stop"
     :data "{\"type\":\"content_block_stop\",\"index\":1}")
    (:event "message_delta"
     :data "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}")
    (:event "message_stop"
     :data "{\"type\":\"message_stop\"}"))
  "A realistic Anthropic SSE stream with text followed by a tool call.")

(ert-deftest pai-anthropic-parse-stream ()
  (let* ((events (pai-anthropic-test--run pai-anthropic-test--frames (pai-anthropic-test--model)))
         (types (mapcar (lambda (e) (plist-get e :type)) events))
         (done (car (last events)))
         (msg (plist-get done :message)))
    (should (eq (car types) 'start))
    (should (equal (seq-filter (lambda (tp) (memq tp '(text-start text-end toolcall-start toolcall-end done))) types)
                   '(text-start text-end toolcall-start toolcall-end done)))
    (should (eq (plist-get done :reason) 'tool-use))
    (should (eq (plist-get msg :stop-reason) 'tool-use))
    ;; content: text "Hello world" then a bash tool call with parsed args
    (let ((content (plist-get msg :content)))
      (should (= (length content) 2))
      (should (equal (pai-content-text content) "Hello world"))
      (let ((tc (nth 1 content)))
        (should (eq (pai-block-type tc) 'tool-call))
        (should (equal (plist-get tc :name) "bash"))
        (should (equal (plist-get (plist-get tc :arguments) :command) "ls"))))
    ;; usage: input 10 (message_start), output 20 (message_delta)
    (let ((u (plist-get msg :usage)))
      (should (= (plist-get u :input) 10))
      (should (= (plist-get u :output) 20))
      (should (= (plist-get u :total-tokens) 30)))))

(ert-deftest pai-anthropic-parse-usage-counts-cache-tokens ()
  "Cached prompt tokens are part of the context and of the bill.
`input_tokens' excludes anything served from the cache, so a warm session
reports a tiny input while the real prompt is the cached bulk."
  (let* ((frames '((:event "message_start"
                    :data "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":12,\"cache_read_input_tokens\":80000,\"cache_creation_input_tokens\":6000,\"output_tokens\":1}}}")
                   (:event "message_delta"
                    :data "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":40}}")
                   (:event "message_stop" :data "{\"type\":\"message_stop\"}")))
         (events (pai-anthropic-test--run frames (pai-anthropic-test--model)))
         (u (plist-get (plist-get (car (last events)) :message) :usage)))
    (should (= (plist-get u :input) 12))
    (should (= (plist-get u :cache-read) 80000))
    (should (= (plist-get u :cache-write) 6000))
    (should (= (plist-get u :output) 40))
    ;; The context meter anchors on :total-tokens, so it must be the whole
    ;; prompt, not just the uncached delta.
    (should (= (plist-get u :total-tokens) 86052))))

(ert-deftest pai-anthropic-parse-usage-restated-in-message-delta ()
  "Input and cache counts restated on message_delta are taken."
  (let* ((frames '((:event "message_start"
                    :data "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":5}}}")
                   (:event "message_delta"
                    :data "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"input_tokens\":7,\"cache_read_input_tokens\":900,\"output_tokens\":3}}")
                   (:event "message_stop" :data "{\"type\":\"message_stop\"}")))
         (events (pai-anthropic-test--run frames (pai-anthropic-test--model)))
         (u (plist-get (plist-get (car (last events)) :message) :usage)))
    (should (= (plist-get u :input) 7))
    (should (= (plist-get u :cache-read) 900))
    (should (= (plist-get u :total-tokens) 910))))

(ert-deftest pai-anthropic-parse-error-frame ()
  (let* ((frames '((:event "error"
                    :data "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"overloaded\"}}")))
         (events (pai-anthropic-test--run frames (pai-anthropic-test--model)))
         (last (car (last events))))
    (should (eq (plist-get last :type) 'error))
    (should (equal (plist-get (plist-get last :message) :error-message) "overloaded"))))

(provide 'pai-provider-anthropic-test)
;;; pai-provider-anthropic-test.el ends here
