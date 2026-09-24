;;; pai-stream-test.el --- Tests for streaming accumulator and dispatch -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai-core)
(require 'pai-stream)
(require 'pai-provider)
(require 'pai-faux)

(defun pai-test--collect (model context options)
  "Stream MODEL over CONTEXT/OPTIONS via faux and return the list of events."
  (let ((events '()))
    (pai-provider-stream model context options
                         (lambda (ev) (push ev events)))
    (nreverse events)))

(defun pai-test--event-types (events)
  (mapcar (lambda (e) (plist-get e :type)) events))

(ert-deftest pai-stream-text-events ()
  (pai-faux-reset)
  (pai-faux-push '(:text "hello world" :stop-reason stop))
  (let* ((events (pai-test--collect (pai-model "faux") (pai-context nil) nil))
         (types (pai-test--event-types events)))
    (should (eq (car types) 'start))
    (should (memq 'text-start types))
    (should (memq 'text-delta types))
    (should (memq 'text-end types))
    (should (eq (car (last types)) 'done))
    (let ((done (car (last events))))
      (should (eq (plist-get done :reason) 'stop))
      (should (equal (pai-content-text (plist-get (plist-get done :message) :content))
                     "hello world")))))

(ert-deftest pai-stream-deltas-concatenate ()
  (pai-faux-reset)
  (pai-faux-push '(:text "abcdefghijklmnop" :stop-reason stop))
  (let* ((events (pai-test--collect (pai-model "faux") (pai-context nil) nil))
         (deltas (seq-filter (lambda (e) (eq (plist-get e :type) 'text-delta)) events)))
    (should (> (length deltas) 1))
    ;; Concatenating the text deltas reconstructs the full assistant text.
    (should (equal (mapconcat (lambda (e) (plist-get e :delta)) deltas "")
                   "abcdefghijklmnop"))
    ;; The final message carries the complete text.
    (should (equal (pai-content-text
                    (plist-get (plist-get (car (last events)) :message) :content))
                   "abcdefghijklmnop"))))

(ert-deftest pai-stream-tool-call-events ()
  (pai-faux-reset)
  (pai-faux-push '(:tool-calls ((:id "c1" :name "bash" :arguments (:command "ls")))
                  :stop-reason tool-use))
  (let* ((events (pai-test--collect (pai-model "faux") (pai-context nil) nil))
         (types (pai-test--event-types events)))
    (should (memq 'toolcall-start types))
    (should (memq 'toolcall-end types))
    (let* ((done (car (last events)))
           (msg (plist-get done :message))
           (tcs (pai-message-tool-calls msg)))
      (should (eq (plist-get done :reason) 'tool-use))
      (should (= (length tcs) 1))
      (should (equal (plist-get (car tcs) :name) "bash"))
      (should (equal (plist-get (plist-get (car tcs) :arguments) :command) "ls"))
      ;; internal json scratch key must be stripped from the finalized block
      (should-not (plist-member (car tcs) :_json)))))

(ert-deftest pai-stream-thinking-events ()
  (pai-faux-reset)
  (pai-faux-push '(:thinking "let me think" :text "answer" :stop-reason stop))
  (let* ((events (pai-test--collect (pai-model "faux") (pai-context nil) nil))
         (types (pai-test--event-types events)))
    (should (memq 'thinking-start types))
    (should (memq 'thinking-delta types))
    (should (memq 'thinking-end types))
    (let* ((msg (plist-get (car (last events)) :message))
           (thinking (seq-find (lambda (b) (eq (pai-block-type b) 'thinking))
                               (plist-get msg :content))))
      (should (equal (plist-get thinking :thinking) "let me think")))))

(ert-deftest pai-stream-error-event ()
  (pai-faux-reset)
  (pai-faux-push '(:error "boom"))
  (let* ((events (pai-test--collect (pai-model "faux") (pai-context nil) nil))
         (last (car (last events))))
    (should (eq (plist-get last :type) 'error))
    (should (equal (plist-get (plist-get last :message) :error-message) "boom"))))

(ert-deftest pai-stream-unknown-provider-errors ()
  (let* ((model (pai-make-model :id "nope" :api 'x :provider "does-not-exist" :base-url "x://"))
         (events (pai-test--collect model (pai-context nil) nil)))
    (should (eq (plist-get (car (last events)) :type) 'error))))

(ert-deftest pai-stream-records-context ()
  (pai-faux-reset)
  (pai-faux-push '(:text "hi"))
  (pai-test--collect (pai-model "faux")
                     (pai-context (list (pai-user-message "yo")) nil)
                     '(:max-tokens 100))
  (should (equal (plist-get (car (plist-get pai-faux-last-context :messages)) :content) "yo"))
  (should (= (plist-get pai-faux-last-options :max-tokens) 100)))

(provide 'pai-stream-test)
;;; pai-stream-test.el ends here
