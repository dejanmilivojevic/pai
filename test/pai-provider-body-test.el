;;; pai-provider-body-test.el --- Piecewise, cached request bodies -*- lexical-binding: t; -*-

;;; Commentary:

;; `pai-provider-encode-body' must produce exactly the bytes a plain
;; `pai-json-encode' + UTF-8 encoding would, for every provider's request
;; shape, while re-encoding only the messages that changed.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pai-core)
(require 'pai-models)
(require 'pai-provider)
(require 'pai-provider-anthropic)
(require 'pai-provider-openai)
(require 'pai-provider-gemini)

(defun pai-body-test--conversation (n)
  "Return N turns of a conversation with tool calls and non-ASCII text."
  (cl-loop for i from 0 below n append
           (let ((id (format "c%d" i)))
             (list (pai-user-message (format "Turn %d: café ☕ \"quoted\" \\ back" i))
                   (pai-assistant-message
                    :content (list (pai-text (format "Answer %d — ok" i))
                                   (pai-tool-call id "read" (list :path (format "f%d.el" i))))
                    :stop-reason 'tool-use)
                   (pai-tool-result-message :tool-call-id id :tool-name "read"
                                            :content (format "contents %d\nline ✓" i))))))

(defun pai-body-test--context (n)
  (pai-context (cons (pai-system-message "You are pai. Ünïcode system prompt.")
                     (pai-body-test--conversation n))
               (list (list :name "read" :description "Read a file"
                           :parameters (pai-object-schema
                                        (list :path (pai-string-schema "Path.")))))))

(defun pai-body-test--models ()
  (list (pai-make-model :id "claude-x" :api 'anthropic-messages :provider "t-anthropic"
                        :base-url "http://localhost/v1" :reasoning t)
        (pai-make-model :id "gpt-x" :api 'openai-completions :provider "t-openai"
                        :base-url "http://localhost/v1")
        (pai-make-model :id "gemini-x" :api 'google-generative-ai :provider "t-gemini"
                        :base-url "http://localhost/v1")))

(defun pai-body-test--build (model ctx)
  (pcase (plist-get model :api)
    ('anthropic-messages (pai-anthropic-build-request model ctx (list :api-key "k")))
    ('openai-completions (pai-openai-build-request model ctx (list :api-key "k")))
    (_ (pai-gemini-build-request model ctx (list :api-key "k")))))

(ert-deftest pai-provider-encode-body-is-byte-identical ()
  "For every provider shape, the pieces are exactly the old encoding."
  (with-temp-buffer
    (dolist (model (pai-body-test--models))
      (dolist (n '(0 1 5))
        (let* ((body (plist-get (pai-body-test--build model (pai-body-test--context n)) :body))
               (pieces (pai-provider-encode-body body))
               (expected (encode-coding-string (pai-json-encode body) 'utf-8)))
          (should (seq-every-p (lambda (p) (not (multibyte-string-p p))) pieces))
          (should (equal (apply #'concat pieces) expected))
          ;; and it is still valid JSON describing the same request
          (should (equal (pai-json-decode (decode-coding-string (apply #'concat pieces) 'utf-8))
                         (pai-json-decode (pai-json-encode body)))))))))

(ert-deftest pai-provider-encode-body-reuses-unchanged-messages ()
  (with-temp-buffer
    (let* ((model (car (pai-body-test--models)))
           (encoded 0))
      (cl-letf* ((orig (symbol-function 'pai-json-encode))
                 ((symbol-function 'pai-json-encode)
                  (lambda (v) (cl-incf encoded) (funcall orig v))))
        (let* ((ctx1 (pai-body-test--context 10))
               (body1 (plist-get (pai-body-test--build model ctx1) :body))
               (n1 (length (plist-get body1 :messages))))
          (pai-provider-encode-body body1)
          ;; first time: the envelope plus every message
          (should (= encoded (1+ n1)))
          ;; next turn: the same transcript plus a little more
          (setq encoded 0)
          (let* ((ctx2 (pai-context (append (plist-get ctx1 :messages)
                                            (pai-body-test--conversation 1))
                                    (plist-get ctx1 :tools)))
                 (body2 (plist-get (pai-body-test--build model ctx2) :body))
                 (pieces (pai-provider-encode-body body2)))
            ;; only a handful are new (the new turn and the cache-marked
            ;; last messages), not the whole transcript
            (should (< encoded 6))
            (should (equal (apply #'concat pieces)
                           (encode-coding-string (funcall orig body2) 'utf-8)))))))))

(ert-deftest pai-provider-encode-body-forgets-old-messages ()
  (with-temp-buffer
    (let ((model (nth 1 (pai-body-test--models))))
      (pai-provider-encode-body (plist-get (pai-body-test--build model (pai-body-test--context 3)) :body))
      (let ((before (hash-table-count pai-provider--fragments)))
        (should (> before 0))
        ;; unrelated requests push the old entries out after a few generations
        (dotimes (i (+ 2 pai-provider-fragment-generations))
          (pai-provider-encode-body
           (plist-get (pai-body-test--build
                       model (pai-context (list (pai-user-message (format "only %d" i))
                                                (pai-user-message (format "other %d" i)))
                                          nil))
                      :body)))
        (should (<= (hash-table-count pai-provider--fragments)
                    (* 2 (1+ pai-provider-fragment-generations))))))))

(ert-deftest pai-provider-encode-body-without-a-conversation ()
  (with-temp-buffer
    (should (equal (pai-provider-encode-body '(:model "m" :messages nil))
                   (list (encode-coding-string (pai-json-encode '(:model "m" :messages nil)) 'utf-8))))
    (should (equal (apply #'concat (pai-provider-encode-body '(:model "m")))
                   (encode-coding-string (pai-json-encode '(:model "m")) 'utf-8)))))

(provide 'pai-provider-body-test)
;;; pai-provider-body-test.el ends here
