;;; pai-core-test.el --- Tests for pai-core -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT tests for the core data model and JSON helpers.

;;; Code:

(require 'ert)
(require 'pai-core)

;;;; JSON encode/decode

(ert-deftest pai-core-json-roundtrip-object ()
  (let* ((obj (list :a 1 :b "x" :c t :d :false :e :null))
         (s (pai-json-encode obj))
         (back (pai-json-decode s)))
    (should (equal (plist-get back :a) 1))
    (should (equal (plist-get back :b) "x"))
    (should (eq (plist-get back :c) t))
    (should (eq (plist-get back :d) :false))
    (should (eq (plist-get back :e) :null))))

(ert-deftest pai-core-json-encodes-list-as-array ()
  (should (equal (pai-json-encode (list :xs (list 1 2 3))) "{\"xs\":[1,2,3]}")))

(ert-deftest pai-core-json-omits-nil-object-keys ()
  ;; nil values inside an object are omitted entirely.
  (should (equal (pai-json-encode (list :a 1 :b nil :c 3)) "{\"a\":1,\"c\":3}")))

(ert-deftest pai-core-json-empty-list-is-array ()
  ;; nil object value is omitted; an explicit empty array uses the empty vector.
  (should (equal (pai-json-encode (list :xs [])) "{\"xs\":[]}")))

(ert-deftest pai-core-json-symbol-value-becomes-string ()
  (should (equal (pai-json-encode (list :role 'user)) "{\"role\":\"user\"}")))

(ert-deftest pai-core-json-nested ()
  (let* ((v (list :msgs (list (list :role 'user :content "hi")
                              (list :role 'assistant :content "yo"))))
         (s (pai-json-encode v))
         (back (pai-json-decode s)))
    (should (equal (length (plist-get back :msgs)) 2))
    (should (equal (plist-get (car (plist-get back :msgs)) :role) "user"))))

;;;; Booleans

(ert-deftest pai-core-truthy ()
  (should (pai-truthy t))
  (should (pai-truthy "x"))
  (should (pai-truthy 0))
  (should-not (pai-truthy nil))
  (should-not (pai-truthy :false)))

;;;; Identifiers

(ert-deftest pai-core-uuidv7-shape ()
  (let ((id (pai-uuidv7)))
    (should (string-match-p
             "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-7[0-9a-f]\\{3\\}-[89ab][0-9a-f]\\{3\\}-[0-9a-f]\\{12\\}\\'"
             id))))

(ert-deftest pai-core-uuidv7-time-ordered ()
  ;; Two ids minted in order should sort in mint order when time advances.
  (let ((a (pai-uuidv7)))
    (sleep-for 0.005)
    (let ((b (pai-uuidv7)))
      (should (string-lessp a b)))))

;;;; Content blocks

(ert-deftest pai-core-text-block ()
  (let ((b (pai-text "hello")))
    (should (eq (pai-block-type b) 'text))
    (should (equal (plist-get b :text) "hello"))
    (should-not (plist-member b :text-signature)))
  (should (equal (plist-get (pai-text "x" "sig") :text-signature) "sig")))

(ert-deftest pai-core-tool-call-block ()
  (let ((b (pai-tool-call "id1" "bash" (list :command "ls"))))
    (should (eq (pai-block-type b) 'tool-call))
    (should (equal (plist-get b :id) "id1"))
    (should (equal (plist-get b :name) "bash"))
    (should (equal (plist-get (plist-get b :arguments) :command) "ls"))))

(ert-deftest pai-core-content-text-extraction ()
  (should (equal (pai-content-text "plain") "plain"))
  (should (equal (pai-content-text (list (pai-text "a") (pai-image "d" "image/png")
                                         (pai-text "b")))
                 "ab")))

(ert-deftest pai-core-normalize-content ()
  (should (equal (pai-normalize-content "hi") (list (pai-text "hi"))))
  (should (equal (pai-normalize-content nil) nil))
  (let ((blocks (list (pai-text "x"))))
    (should (eq (pai-normalize-content blocks) blocks))))

;;;; Usage

(ert-deftest pai-core-usage-defaults ()
  (let ((u (pai-usage)))
    (should (= (plist-get u :input) 0))
    (should (= (plist-get u :total-tokens) 0))
    (should (= (plist-get (plist-get u :cost) :total) 0.0))))

(ert-deftest pai-core-usage-add ()
  (let ((s (pai-usage-add (pai-usage :input 10 :output 5 :total-tokens 15)
                          (pai-usage :input 3 :output 2 :total-tokens 5))))
    (should (= (plist-get s :input) 13))
    (should (= (plist-get s :output) 7))
    (should (= (plist-get s :total-tokens) 20))))

;;;; Messages

(ert-deftest pai-core-user-message ()
  (let ((m (pai-user-message "hi")))
    (should (pai-user-message-p m))
    (should (eq (pai-message-role m) 'user))
    (should (equal (pai-message-content m) "hi"))
    (should (integerp (plist-get m :timestamp)))))

(ert-deftest pai-core-assistant-message ()
  (let ((m (pai-assistant-message :content (list (pai-text "hello")
                                                 (pai-tool-call "t1" "bash" (list :command "ls")))
                                  :provider "anthropic" :model "claude"
                                  :stop-reason 'tool-use)))
    (should (pai-assistant-message-p m))
    (should (eq (plist-get m :stop-reason) 'tool-use))
    (should (equal (length (pai-message-tool-calls m)) 1))
    (should (equal (plist-get (car (pai-message-tool-calls m)) :name) "bash"))))

(ert-deftest pai-core-tool-result-message ()
  (let ((m (pai-tool-result-message :tool-call-id "t1" :tool-name "bash"
                                    :content "output" :is-error nil)))
    (should (pai-tool-result-message-p m))
    (should (equal (plist-get m :tool-call-id) "t1"))
    (should (eq (plist-get m :is-error) :false))
    (should (equal (pai-content-text (plist-get m :content)) "output"))))

(ert-deftest pai-core-tool-error-result ()
  (let ((r (pai-tool-error-result "boom")))
    (should (eq (plist-get r :is-error) t))
    (should (equal (pai-content-text (plist-get r :content)) "boom"))))

;;;; Tool call / result pairing repair

(defun pai-core-test--call-msg (&rest ids)
  (pai-assistant-message
   :content (cons (pai-text "doing")
                  (mapcar (lambda (id) (list :type 'tool-call :id id :name "bash"
                                             :arguments nil))
                          ids))))

(defun pai-core-test--result (id)
  (pai-tool-result-message :tool-call-id id :tool-name "bash" :content "ok"))

(ert-deftest pai-core-repair-tool-pairing-noop ()
  (let ((msgs (list (pai-user-message "hi") (pai-core-test--call-msg "a")
                    (pai-core-test--result "a") (pai-user-message "next"))))
    (should (eq (pai-repair-tool-pairing msgs) msgs))))

(ert-deftest pai-core-repair-tool-pairing-crashed-then-resumed ()
  ;; Crash after the tool call was saved, then the user sent a new prompt.
  (let* ((msgs (list (pai-user-message "hi") (pai-core-test--call-msg "a" "b")
                     (pai-core-test--result "a") (pai-user-message "continue")))
         (out (pai-repair-tool-pairing msgs)))
    (should (equal (mapcar #'pai-message-role out)
                   '(user assistant tool-result tool-result user)))
    (should (equal (plist-get (nth 2 out) :tool-call-id) "a"))
    (should (equal (plist-get (nth 3 out) :tool-call-id) "b"))
    (should (eq (plist-get (nth 3 out) :is-error) t))))

(ert-deftest pai-core-repair-tool-pairing-trailing-and-orphans ()
  (let* ((msgs (list (pai-core-test--result "x") (pai-user-message "hi")
                     (pai-core-test--call-msg "a")))
         (out (pai-repair-tool-pairing msgs)))
    (should (equal (mapcar #'pai-message-role out) '(user assistant tool-result)))
    (should (equal (plist-get (nth 2 out) :tool-call-id) "a"))))

(ert-deftest pai-core-repair-tool-pairing-anthropic-request ()
  (require 'pai-provider-anthropic)
  (let* ((msgs (pai-repair-tool-pairing
                (list (pai-user-message "hi") (pai-core-test--call-msg "a")
                      (pai-user-message "continue"))))
         (req (pai-anthropic--messages msgs))
         (user2 (plist-get (nth 2 req) :content)))
    (should (= (length req) 3))
    (should (equal (plist-get (car user2) :type) "tool_result"))
    (should (equal (plist-get (car user2) :tool_use_id) "a"))
    (should (equal (plist-get (cadr user2) :type) "text"))))

;;;; Message JSON round-trip (session persistence relies on this)

(ert-deftest pai-core-message-json-roundtrip ()
  (let* ((m (pai-user-message "hello world"))
         (s (pai-json-encode m))
         (back (pai-json-decode s)))
    (should (equal (plist-get back :role) "user"))
    (should (equal (plist-get back :content) "hello world"))))

(provide 'pai-core-test)
;;; pai-core-test.el ends here
