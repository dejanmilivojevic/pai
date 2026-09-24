;;; pai-tools-deferred-test.el --- Tests for deferred tool schemas -*- lexical-binding: t; -*-

;;; Commentary:
;; Non-core tools are declared as compact, byte-stable stubs; the full schema
;; is revealed in-conversation on first use so the provider's prompt cache is
;; never invalidated by a changing tool list.

;;; Code:

(require 'ert)
(require 'pai-core)
(require 'pai-tools)
(require 'pai-tools-builtin)
(require 'pai-agent)
(require 'pai-faux)
(require 'pai-provider-gemini)

(defconst pai-tools-deferred-test--long-description
  "Drive the frobnicator. It accepts many actions and a very long explanation \
follows here that should never be sent on every request.")

(defun pai-tools-deferred-test--tool (&optional on-exec &rest extra)
  "Return an extension-style tool; ON-EXEC is called with args.  EXTRA is appended."
  (append
   (list :name "frob"
         :description pai-tools-deferred-test--long-description
         :prompt-snippet "frob: drive the frobnicator"
         :parameters (pai-object-schema
                      (list :action (pai-string-schema "Action to run, one of: a, b, c."))
                      '("action"))
         :execute (lambda (args _ctx _update done)
                    (when on-exec (funcall on-exec args))
                    (funcall done (pai-tool-ok-result
                                   (format "frobbed %s" (plist-get args :action))))))
   extra))

(defmacro pai-tools-deferred-test--enabled (&rest body)
  "Run BODY with tool deferral enabled and no eager overrides."
  (declare (indent 0))
  `(let ((pai-defer-extension-tools t) (pai-eager-tool-names nil))
     ,@body))

;;;; Policy

(ert-deftest pai-tools-deferred-policy ()
  (pai-tools-deferred-test--enabled
    (should-not (pai-tool-deferred-p (pai-tool-get "bash")))
    (should (pai-tool-deferred-p (pai-tools-deferred-test--tool)))
    (should-not (pai-tool-deferred-p (pai-tools-deferred-test--tool nil :deferred nil)))
    (should-not (pai-tool-deferred-p (pai-tools-deferred-test--tool nil :deferred :false)))
    (should (pai-tool-deferred-p (list :name "bash" :deferred t)))
    (let ((pai-eager-tool-names '("frob")))
      (should-not (pai-tool-deferred-p (pai-tools-deferred-test--tool)))))
  (let ((pai-defer-extension-tools nil))
    (should-not (pai-tool-deferred-p (pai-tools-deferred-test--tool)))))

(ert-deftest pai-tools-deferred-stub-is-compact-and-stable ()
  (pai-tools-deferred-test--enabled
    (let* ((tool (pai-tools-deferred-test--tool))
           (a (pai-tool-declaration tool))
           (b (pai-tool-declaration tool))
           (full (pai-tool-full-declaration tool)))
      (should (equal (pai-json-encode a) (pai-json-encode b)))
      (should (equal (plist-get a :name) "frob"))
      (should (string-prefix-p "frob: drive the frobnicator" (plist-get a :description)))
      (should-not (string-match-p "very long explanation" (plist-get a :description)))
      (should (eq (plist-get (plist-get a :parameters) :additionalProperties) t))
      (should (< (length (pai-json-encode a)) (length (pai-json-encode full)))))
    ;; core tools are untouched
    (should (equal (pai-tool-declaration (pai-tool-get "read"))
                   (pai-tool-full-declaration (pai-tool-get "read"))))))

(ert-deftest pai-tools-deferred-reveal-result ()
  (pai-tools-deferred-test--enabled
    (let* ((tool (pai-tools-deferred-test--tool))
           (reveal (pai-tool-pending-reveal tool nil))
           (text (pai-content-text (plist-get reveal :content))))
      (should reveal)
      (should-not (pai-truthy (plist-get reveal :is-error)))
      (should (equal (plist-get (plist-get reveal :details) :deferred-schema) "frob"))
      (should (string-match-p "NOT executed" text))
      (should (string-match-p "very long explanation" text))
      (should (string-match-p "\"action\"" text))
      ;; once in history, no further reveal
      (let ((msg (pai-tool-result-message :tool-call-id "x" :tool-name "frob"
                                          :content (plist-get reveal :content)
                                          :details (plist-get reveal :details))))
        (should-not (pai-tool-pending-reveal tool (list msg))))
      ;; eager tools never reveal
      (should-not (pai-tool-pending-reveal (pai-tool-get "bash") nil)))))

;;;; Agent loop

(defun pai-tools-deferred-test--run (tool config)
  "Run the agent with TOOL and CONFIG; return (messages . contexts-sent)."
  (let ((contexts '()) (result nil) (done nil))
    (pai-agent-run (list (pai-user-message "frob it"))
                   (pai-context nil (list tool))
                   (append config
                           (list :model (pai-model "faux")
                                 :stream-fn (lambda (model ctx options emit)
                                              (push ctx contexts)
                                              (pai-faux-stream model ctx options emit))))
                   #'ignore
                   (lambda (msgs) (setq result msgs done t)))
    (should done)
    (cons result (nreverse contexts))))

(dolist (mode '(sequential parallel))
  (eval
   `(ert-deftest ,(intern (format "pai-tools-deferred-agent-reveal-then-execute-%s" mode)) ()
      (pai-tools-deferred-test--enabled
        (pai-faux-reset)
        (pai-faux-push
         '(:tool-calls ((:id "c1" :name "frob" :arguments (:action "a"))) :stop-reason tool-use)
         '(:tool-calls ((:id "c2" :name "frob" :arguments (:action "b"))) :stop-reason tool-use)
         '(:text "done" :stop-reason stop))
        (let* ((executed '()) (hooked 0)
               (tool (pai-tools-deferred-test--tool (lambda (args) (push args executed))))
               (out (pai-tools-deferred-test--run
                     tool (list :tool-execution ',mode
                                :before-tool-call (lambda (_c) (cl-incf hooked) nil))))
               (messages (car out)) (contexts (cdr out))
               (results (seq-filter #'pai-tool-result-message-p messages)))
          ;; first call revealed (not executed, no permission hook), second ran
          (should (= (length results) 2))
          (should (equal (plist-get (plist-get (nth 0 results) :details) :deferred-schema) "frob"))
          (should (equal (pai-content-text (plist-get (nth 1 results) :content)) "frobbed b"))
          (should (equal executed '((:action "b"))))
          (should (= hooked 1))
          ;; the tool list sent is byte-identical on every request (cache-safe)
          (should (= (length contexts) 3))
          (let ((encoded (mapcar (lambda (c) (pai-json-encode (plist-get c :tools))) contexts)))
            (should (equal (delete-dups (copy-sequence encoded)) (list (car encoded)))))
          (should (equal (pai-json-encode (car (plist-get (car contexts) :tools)))
                         (pai-json-encode (pai-tool-stub-declaration tool)))))))
   t))

(ert-deftest pai-tools-deferred-agent-already-revealed-in-history ()
  (pai-tools-deferred-test--enabled
    (pai-faux-reset)
    (pai-faux-push
     '(:tool-calls ((:id "c2" :name "frob" :arguments (:action "c"))) :stop-reason tool-use)
     '(:text "done" :stop-reason stop))
    (let* ((executed nil)
           (tool (pai-tools-deferred-test--tool (lambda (_a) (setq executed t))))
           (reveal (pai-tool-reveal-result tool))
           (history (list (pai-tool-result-message
                           :tool-call-id "c1" :tool-name "frob"
                           :content (plist-get reveal :content)
                           :details (plist-get reveal :details))))
           (done nil))
      (pai-agent-run (list (pai-user-message "again"))
                     (pai-context history (list tool))
                     (list :model (pai-model "faux"))
                     #'ignore (lambda (_m) (setq done t)))
      (should done)
      (should executed))))

;;;; Providers

(ert-deftest pai-tools-deferred-gemini-strips-additional-properties ()
  (pai-tools-deferred-test--enabled
    (let* ((decl (pai-tool-declaration (pai-tools-deferred-test--tool)))
           (tools (pai-gemini--tools (list decl)))
           (params (plist-get (car (plist-get (car tools) :functionDeclarations)) :parameters)))
      (should (equal (plist-get params :type) "object"))
      (should-not (plist-member params :additionalProperties))
      (should (equal (pai-gemini--schema '(:type "object" :additionalProperties t
                                           :properties (:x (:type "object" :additionalProperties :false))
                                           :required ("x")))
                     '(:type "object" :properties (:x (:type "object")) :required ("x")))))))

(provide 'pai-tools-deferred-test)
;;; pai-tools-deferred-test.el ends here
