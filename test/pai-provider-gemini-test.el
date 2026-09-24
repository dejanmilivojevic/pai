;;; pai-provider-gemini-test.el --- Tests for the Gemini provider -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai-core)
(require 'pai-models)
(require 'pai-provider)
(require 'pai-provider-gemini)

(defun pai-gemini-test--model ()
  (pai-make-model :id "gemini-2.5-pro" :api 'google-generative-ai
                  :provider "test-google" :base-url "http://localhost:1234/v1beta"
                  :reasoning t))

(defun pai-gemini-test--run (frames model)
  (let* ((events '())
         (parser (pai-gemini-make-parser model (lambda (ev) (push ev events))))
         (on-frame (plist-get parser :on-frame)))
    (dolist (f frames) (funcall on-frame f))
    (funcall (plist-get parser :on-close) 0)
    (nreverse events)))

(ert-deftest pai-gemini-build-request ()
  (let* ((model (pai-gemini-test--model))
         (ctx (pai-context (list (pai-system-message "sys") (pai-user-message "hi"))
                           (list (list :name "bash" :description "run"
                                       :parameters (list :type "object")))))
         (req (pai-gemini-build-request model ctx '(:api-key "gk")))
         (body (plist-get req :body)))
    (should (equal (plist-get req :url)
                   "http://localhost:1234/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse"))
    (should (equal (cdr (assoc "x-goog-api-key" (plist-get req :headers))) "gk"))
    (should (equal (plist-get (plist-get body :systemInstruction) :parts)
                   (list (list :text "sys"))))
    (should (= (length (plist-get body :contents)) 1))
    (should (equal (plist-get (car (plist-get body :contents)) :role) "user"))
    (should (plist-get (car (plist-get body :tools)) :functionDeclarations))))

(ert-deftest pai-gemini-contents-roles ()
  (let* ((msgs (list (pai-user-message "go")
                     (pai-assistant-message :content (list (pai-tool-call "c1" "bash" '(:command "ls"))))
                     (pai-tool-result-message :tool-call-id "c1" :tool-name "bash" :content "files")))
         (out (pai-gemini--contents msgs)))
    (should (equal (plist-get (nth 0 out) :role) "user"))
    (should (equal (plist-get (nth 1 out) :role) "model"))
    (should (plist-get (car (plist-get (nth 1 out) :parts)) :functionCall))
    ;; tool result becomes a user content with a functionResponse part
    (should (equal (plist-get (nth 2 out) :role) "user"))
    (should (plist-get (car (plist-get (nth 2 out) :parts)) :functionResponse))))

(defconst pai-gemini-test--text-frames
  '((:data "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hello\"}]}}]}")
    (:data "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\" world\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":5,\"totalTokenCount\":15}}")))

(ert-deftest pai-gemini-parse-text-stream ()
  (let* ((events (pai-gemini-test--run pai-gemini-test--text-frames (pai-gemini-test--model)))
         (done (car (last events)))
         (msg (plist-get done :message)))
    (should (eq (plist-get done :type) 'done))
    (should (eq (plist-get done :reason) 'stop))
    (should (equal (pai-content-text (plist-get msg :content)) "Hello world"))
    (let ((u (plist-get msg :usage)))
      (should (= (plist-get u :input) 10))
      (should (= (plist-get u :output) 5))
      (should (= (plist-get u :total-tokens) 15)))))

(defconst pai-gemini-test--tool-frames
  '((:data "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"bash\",\"args\":{\"command\":\"ls\"}}}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":5,\"totalTokenCount\":15}}")))

(ert-deftest pai-gemini-parse-tool-stream ()
  (let* ((events (pai-gemini-test--run pai-gemini-test--tool-frames (pai-gemini-test--model)))
         (done (car (last events)))
         (msg (plist-get done :message))
         (tcs (pai-message-tool-calls msg)))
    (should (eq (plist-get done :reason) 'tool-use))
    (should (= (length tcs) 1))
    (should (equal (plist-get (car tcs) :name) "bash"))
    (should (equal (plist-get (plist-get (car tcs) :arguments) :command) "ls"))))

(ert-deftest pai-gemini-thinking-parts ()
  (let* ((frames '((:data "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"thought\":true,\"text\":\"hmm\"},{\"text\":\"answer\"}]},\"finishReason\":\"STOP\"}]}")))
         (events (pai-gemini-test--run frames (pai-gemini-test--model)))
         (msg (plist-get (car (last events)) :message))
         (content (plist-get msg :content)))
    (should (seq-find (lambda (b) (eq (pai-block-type b) 'thinking)) content))
    (should (equal (pai-content-text content) "answer"))))

(ert-deftest pai-gemini-tool-config ()
  (let* ((model (pai-gemini-test--model))
         (ctx (pai-context (list (pai-user-message "hi"))
                           (list (list :name "bash" :description "d" :parameters (list :type "object")))))
         (body (plist-get (pai-gemini-build-request model ctx '(:tool-choice none :api-key "k")) :body)))
    (should (equal (plist-get (plist-get (plist-get body :toolConfig) :functionCallingConfig) :mode)
                   "NONE"))))

(provide 'pai-provider-gemini-test)
;;; pai-provider-gemini-test.el ends here
