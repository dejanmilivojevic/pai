;;; pai-http-test.el --- Integration tests for the curl SSE transport -*- lexical-binding: t; -*-

;;; Commentary:
;; These tests exercise the real `curl' path of `pai-http-stream' against a
;; tiny in-process TCP server, validating HTTP header parsing, SSE framing, and
;; error handling.

;;; Code:

(require 'ert)
(require 'pai-http)

(defvar pai-http-test--server nil)

(defun pai-http-test--start-server (response)
  "Start a localhost TCP server that replies with RESPONSE then half-closes.
Return a cons (PROCESS . PORT)."
  (let* ((proc (make-network-process
                :name "pai-http-test-server" :server t :host 'local :service t
                :family 'ipv4 :coding 'binary :noquery t
                :filter
                (lambda (conn chunk)
                  (let ((acc (concat (or (process-get conn 'acc) "") chunk)))
                    (process-put conn 'acc acc)
                    (when (and (string-match-p "\r\n\r\n" acc)
                               (not (process-get conn 'replied)))
                      (process-put conn 'replied t)
                      (process-send-string conn response)
                      (process-send-eof conn))))))
         (port (cadr (process-contact proc))))
    (cons proc port)))

(defun pai-http-test--collect (response &optional method body)
  "Run a request against a server returning RESPONSE; return a result plist.
The plist has :frames (list), :error (string or nil), :closed (bool)."
  (let* ((srv (pai-http-test--start-server response))
         (proc (car srv)) (port (cdr srv))
         (frames '()) (err nil) (closed nil))
    (unwind-protect
        (progn
          (pai-http-stream
           :url (format "http://127.0.0.1:%d/" port)
           :method (or method "POST")
           :headers '(("content-type" . "application/json"))
           :body body
           :on-frame (lambda (f) (push f frames))
           :on-error (lambda (m) (setq err m))
           :on-close (lambda (_c) (setq closed t)))
          (let ((deadline (+ (float-time) 10)))
            (while (and (not closed) (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (list :frames (nreverse frames) :error err :closed closed))
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest pai-http-streams-sse-frames ()
  (let* ((response (concat "HTTP/1.1 200 OK\r\n"
                           "Content-Type: text/event-stream\r\n"
                           "\r\n"
                           "data: {\"n\":1}\n\n"
                           "event: tick\ndata: {\"n\":2}\n\n"))
         (result (pai-http-test--collect response)))
    (should (plist-get result :closed))
    (should (null (plist-get result :error)))
    (let ((frames (plist-get result :frames)))
      (should (= (length frames) 2))
      (should (equal (plist-get (nth 0 frames) :data) "{\"n\":1}"))
      (should (equal (plist-get (nth 1 frames) :event) "tick"))
      (should (equal (plist-get (nth 1 frames) :data) "{\"n\":2}")))))

(ert-deftest pai-http-reports-http-error ()
  (let* ((response (concat "HTTP/1.1 500 Internal Server Error\r\n"
                           "Content-Type: application/json\r\n"
                           "\r\n"
                           "{\"error\":\"boom\"}"))
         (result (pai-http-test--collect response)))
    (should (plist-get result :closed))
    (should (null (plist-get result :frames)))
    (should (stringp (plist-get result :error)))
    (should (string-match-p "HTTP 500" (plist-get result :error)))
    (should (string-match-p "boom" (plist-get result :error)))))

(ert-deftest pai-http-sends-body ()
  ;; The server echoes nothing, but we can confirm curl completes with a body.
  (let* ((response (concat "HTTP/1.1 200 OK\r\n\r\n" "data: ok\n\n"))
         (result (pai-http-test--collect response "POST" "{\"hello\":\"world\"}")))
    (should (plist-get result :closed))
    (should (equal (plist-get (car (plist-get result :frames)) :data) "ok"))))

;;;; Full stack: real curl -> Anthropic parser -> agent loop

(require 'pai-core)
(require 'pai-models)
(require 'pai-provider)
(require 'pai-provider-anthropic)
(require 'pai-agent)

(defconst pai-http-test--anthropic-response
  (concat
   "HTTP/1.1 200 OK\r\n"
   "Content-Type: text/event-stream\r\n\r\n"
   "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"usage\":{\"input_tokens\":5,\"output_tokens\":1}}}\n\n"
   "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
   "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi there\"}}\n\n"
   "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
   "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n"
   "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
  "A complete Anthropic SSE response served over the local HTTP test server.")

(ert-deftest pai-http-anthropic-agent-loop-end-to-end ()
  "Run the agent loop over the real curl transport and Anthropic parser."
  (let* ((srv (pai-http-test--start-server pai-http-test--anthropic-response))
         (proc (car srv)) (port (cdr srv))
         (model (pai-make-model :id "claude-test" :api 'anthropic-messages
                                :provider "anthropic"
                                :base-url (format "http://127.0.0.1:%d/v1" port)))
         (pai--providers (make-hash-table :test 'equal))
         (result nil) (done nil))
    (unwind-protect
        (progn
          (pai-register-provider
           (list :id "anthropic" :build-request #'pai-anthropic-build-request
                 :make-parser #'pai-anthropic-make-parser))
          (pai-agent-run
           (list (pai-user-message "hello"))
           (pai-context nil nil)
           (list :model model :get-api-key (lambda (_p) "test-key"))
           (lambda (_ev) nil)
           (lambda (msgs) (setq result msgs done t)))
          (let ((deadline (+ (float-time) 10)))
            (while (and (not done) (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (should done)
          ;; user prompt + assistant reply
          (should (= (length result) 2))
          (let ((assistant (nth 1 result)))
            (should (pai-assistant-message-p assistant))
            (should (equal (pai-content-text (pai-message-content assistant)) "Hi there"))
            (should (eq (plist-get assistant :stop-reason) 'stop))
            (should (= (plist-get (plist-get assistant :usage) :output) 3))))
      (when (process-live-p proc) (delete-process proc)))))

(provide 'pai-http-test)
;;; pai-http-test.el ends here
