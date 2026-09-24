;;; pai-agent-test.el --- Tests for the agent loop -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai-core)
(require 'pai-agent)
(require 'pai-faux)

(defun pai-agent-test--echo-tool (&optional on-exec)
  "Return an echo tool plist; ON-EXEC, if given, is called with (args ctx)."
  (list :name "echo" :description "echo a message" :deferred nil
        :parameters (list :type "object"
                          :properties (list :msg (list :type "string"))
                          :required '("msg"))
        :execute (lambda (args ctx _on-update on-done)
                   (when on-exec (funcall on-exec args ctx))
                   (funcall on-done (pai-tool-ok-result
                                     (format "echo: %s" (plist-get args :msg)))))))

(defun pai-agent-test--run (prompts config)
  "Run the agent with PROMPTS and CONFIG synchronously; return (events . messages)."
  (let ((events '()) (result nil) (done nil))
    (pai-agent-run prompts
                   (pai-context nil (plist-get config :tools))
                   config
                   (lambda (ev) (push ev events))
                   (lambda (msgs) (setq result msgs done t)))
    (should done) ; faux is synchronous
    (cons (nreverse events) result)))

(defun pai-agent-test--types (events)
  (mapcar (lambda (e) (plist-get e :type)) events))

;;;; Basic text turn

(ert-deftest pai-agent-simple-text-turn ()
  (pai-faux-reset)
  (pai-faux-push '(:text "hello there" :stop-reason stop))
  (let* ((out (pai-agent-test--run (list (pai-user-message "hi"))
                                   (list :model (pai-model "faux"))))
         (events (car out)) (messages (cdr out))
         (types (pai-agent-test--types events)))
    (should (eq (car types) 'agent-start))
    (should (eq (car (last types)) 'agent-end))
    (should (memq 'turn-start types))
    (should (memq 'turn-end types))
    (should (memq 'message-update types))
    ;; user prompt + assistant reply
    (should (= (length messages) 2))
    (should (pai-user-message-p (nth 0 messages)))
    (should (pai-assistant-message-p (nth 1 messages)))
    (should (equal (pai-content-text (pai-message-content (nth 1 messages))) "hello there"))))

;;;; Tool-call round trip

(ert-deftest pai-agent-tool-call-round-trip ()
  (pai-faux-reset)
  (pai-faux-push '(:tool-calls ((:id "c1" :name "echo" :arguments (:msg "hi"))) :stop-reason tool-use)
                 '(:text "all done" :stop-reason stop))
  (let* ((seen-args nil)
         (tool (pai-agent-test--echo-tool (lambda (args _ctx) (setq seen-args args))))
         (out (pai-agent-test--run (list (pai-user-message "use echo"))
                                   (list :model (pai-model "faux") :tools (list tool))))
         (events (car out)) (messages (cdr out))
         (types (pai-agent-test--types events)))
    (should (memq 'tool-execution-start types))
    (should (memq 'tool-execution-end types))
    (should (equal (plist-get seen-args :msg) "hi"))
    ;; user, assistant(tool call), tool-result, assistant(text)
    (should (= (length messages) 4))
    (should (pai-tool-result-message-p (nth 2 messages)))
    (should (equal (pai-content-text (plist-get (nth 2 messages) :content)) "echo: hi"))
    (should (equal (pai-content-text (pai-message-content (nth 3 messages))) "all done"))))

(ert-deftest pai-agent-unknown-tool-errors-and-continues ()
  (pai-faux-reset)
  (pai-faux-push '(:tool-calls ((:id "c1" :name "nope" :arguments (:x 1))) :stop-reason tool-use)
                 '(:text "recovered" :stop-reason stop))
  (let* ((out (pai-agent-test--run (list (pai-user-message "go"))
                                   (list :model (pai-model "faux") :tools nil)))
         (messages (cdr out))
         (tr (nth 2 messages)))
    (should (pai-tool-result-message-p tr))
    (should (eq (plist-get tr :is-error) t))
    (should (string-match-p "Unknown tool" (pai-content-text (plist-get tr :content))))
    (should (equal (pai-content-text (pai-message-content (nth 3 messages))) "recovered"))))

(defun pai-agent-test--limit-tool (on-exec)
  "Return a tool with number/boolean params; ON-EXEC gets its args."
  (list :name "lim" :description "x" :deferred nil
        :parameters (list :type "object"
                          :properties (list :limit (list :type "number")
                                            :n (list :type "integer")
                                            :flag (list :type "boolean")
                                            :q (list :type "string")))
        :execute (lambda (args _ctx _on-update on-done)
                   (funcall on-exec args)
                   (funcall on-done (pai-tool-ok-result
                                     (format "%d" (+ 1 (plist-get args :limit))))))))

(ert-deftest pai-agent-tool-args-quoted-numbers-are-coerced ()
  "A model sending \"10\" for a number parameter does not break the tool."
  (pai-faux-reset)
  (pai-faux-push '(:tool-calls ((:id "c1" :name "lim"
                                  :arguments (:limit "10" :n "3.0" :flag "false" :q "7")))
                               :stop-reason tool-use)
                 '(:text "ok" :stop-reason stop))
  (let* ((seen nil)
         (out (pai-agent-test--run (list (pai-user-message "go"))
                                   (list :model (pai-model "faux")
                                         :tools (list (pai-agent-test--limit-tool
                                                       (lambda (a) (setq seen a)))))))
         (tr (nth 2 (cdr out))))
    (should (equal (plist-get seen :limit) 10))
    (should (equal (plist-get seen :n) 3))
    (should (eq (plist-get seen :flag) :false))
    (should (equal (plist-get seen :q) "7"))   ; strings stay strings
    (should-not (eq (plist-get tr :is-error) t))
    (should (equal (pai-content-text (plist-get tr :content)) "11"))))

(ert-deftest pai-agent-tool-signalling-error-becomes-error-result ()
  "A tool that signals becomes an error result; the run continues."
  (pai-faux-reset)
  (pai-faux-push '(:tool-calls ((:id "c1" :name "lim" :arguments (:limit "many")))
                               :stop-reason tool-use)
                 '(:text "recovered" :stop-reason stop))
  (let* ((out (pai-agent-test--run (list (pai-user-message "go"))
                                   (list :model (pai-model "faux")
                                         :tools (list (pai-agent-test--limit-tool #'ignore)))))
         (messages (cdr out))
         (tr (nth 2 messages)))
    (should (eq (plist-get tr :is-error) t))
    (should (string-match-p "Tool lim failed: Wrong type argument"
                            (pai-content-text (plist-get tr :content))))
    (should (equal (pai-content-text (pai-message-content (nth 3 messages))) "recovered"))))

;;;; Hooks

(ert-deftest pai-agent-should-stop-after-turn ()
  (pai-faux-reset)
  ;; Even though the first turn requests a tool, should-stop-after-turn halts first.
  (pai-faux-push '(:tool-calls ((:id "c1" :name "echo" :arguments (:msg "x"))) :stop-reason tool-use)
                 '(:text "should not reach" :stop-reason stop))
  (let* ((tool (pai-agent-test--echo-tool))
         (out (pai-agent-test--run
               (list (pai-user-message "go"))
               (list :model (pai-model "faux") :tools (list tool)
                     :should-stop-after-turn (lambda (_ctx) t))))
         (messages (cdr out)))
    ;; user, assistant(tool call), tool-result -> then stop (no second assistant)
    (should (= (length messages) 3))
    (should (pai-tool-result-message-p (nth 2 messages)))))

(ert-deftest pai-agent-before-tool-call-block ()
  (pai-faux-reset)
  (pai-faux-push '(:tool-calls ((:id "c1" :name "echo" :arguments (:msg "x"))) :stop-reason tool-use)
                 '(:text "after block" :stop-reason stop))
  (let* ((executed nil)
         (tool (pai-agent-test--echo-tool (lambda (_a _c) (setq executed t))))
         (out (pai-agent-test--run
               (list (pai-user-message "go"))
               (list :model (pai-model "faux") :tools (list tool)
                     :before-tool-call (lambda (_ctx) '(:block t :reason "denied")))))
         (messages (cdr out))
         (tr (nth 2 messages)))
    (should-not executed)
    (should (eq (plist-get tr :is-error) t))
    (should (string-match-p "denied" (pai-content-text (plist-get tr :content))))))

(ert-deftest pai-agent-after-tool-call-override ()
  (pai-faux-reset)
  (pai-faux-push '(:tool-calls ((:id "c1" :name "echo" :arguments (:msg "x"))) :stop-reason tool-use)
                 '(:text "ok" :stop-reason stop))
  (let* ((tool (pai-agent-test--echo-tool))
         (out (pai-agent-test--run
               (list (pai-user-message "go"))
               (list :model (pai-model "faux") :tools (list tool)
                     :after-tool-call (lambda (_ctx)
                                        (list :content (list (pai-text "OVERRIDDEN")))))))
         (messages (cdr out)))
    (should (equal (pai-content-text (plist-get (nth 2 messages) :content)) "OVERRIDDEN"))))

;;;; Steering and follow-up queues

(ert-deftest pai-agent-steering-messages-injected ()
  (pai-faux-reset)
  (pai-faux-push '(:text "done" :stop-reason stop))
  (let* ((given nil)
         (out (pai-agent-test--run
               (list (pai-user-message "first"))
               (list :model (pai-model "faux")
                     :get-steering-messages
                     (lambda () (unless given
                                  (setq given t)
                                  (list (pai-user-message "steer!")))))))
         (messages (cdr out)))
    ;; user(first), user(steer!), assistant(done)
    (should (= (length messages) 3))
    (should (equal (pai-message-content (nth 1 messages)) "steer!"))))

(ert-deftest pai-agent-follow-up-messages-processed ()
  (pai-faux-reset)
  (pai-faux-push '(:text "answer one" :stop-reason stop)
                 '(:text "answer two" :stop-reason stop))
  (let* ((given nil)
         (out (pai-agent-test--run
               (list (pai-user-message "q1"))
               (list :model (pai-model "faux")
                     :get-follow-up-messages
                     (lambda () (unless given
                                  (setq given t)
                                  (list (pai-user-message "q2")))))))
         (messages (cdr out)))
    ;; user(q1), assistant(one), user(q2 follow-up), assistant(two)
    (should (= (length messages) 4))
    (should (equal (pai-content-text (pai-message-content (nth 1 messages))) "answer one"))
    (should (equal (pai-message-content (nth 2 messages)) "q2"))
    (should (equal (pai-content-text (pai-message-content (nth 3 messages))) "answer two"))))

;;;; Truncation and errors

(ert-deftest pai-agent-length-truncation-fails-tools ()
  (pai-faux-reset)
  (pai-faux-push '(:tool-calls ((:id "c1" :name "echo" :arguments (:msg "x"))) :stop-reason length))
  (let* ((executed nil)
         (tool (pai-agent-test--echo-tool (lambda (_a _c) (setq executed t))))
         (out (pai-agent-test--run
               (list (pai-user-message "go"))
               (list :model (pai-model "faux") :tools (list tool))))
         (messages (cdr out))
         (tr (nth 2 messages)))
    (should-not executed)
    (should (eq (plist-get tr :is-error) t))
    (should (string-match-p "token limit" (pai-content-text (plist-get tr :content))))))

(ert-deftest pai-agent-provider-error-ends-run ()
  (pai-faux-reset)
  (pai-faux-push '(:error "kaboom"))
  (let* ((out (pai-agent-test--run (list (pai-user-message "go"))
                                   (list :model (pai-model "faux"))))
         (events (car out)) (messages (cdr out))
         (types (pai-agent-test--types events)))
    (should (eq (car (last types)) 'agent-end))
    (should (eq (plist-get (nth 1 messages) :stop-reason) 'error))))

(ert-deftest pai-agent-parallel-execution ()
  (pai-faux-reset)
  (pai-faux-push '(:tool-calls ((:id "a" :name "slow" :arguments (:x 1))
                                (:id "b" :name "fast" :arguments (:x 2)))
                   :stop-reason tool-use)
                 '(:text "done" :stop-reason stop))
  (let* ((ends '())
         (slow (list :name "slow" :description "d" :deferred nil :parameters (list :type "object")
                     :execute (lambda (_a _c _u done)
                                (run-at-time 0.15 nil (lambda () (funcall done (pai-tool-ok-result "SLOW")))))))
         (fast (list :name "fast" :description "d" :deferred nil :parameters (list :type "object")
                     :execute (lambda (_a _c _u done)
                                (run-at-time 0.03 nil (lambda () (funcall done (pai-tool-ok-result "FAST")))))))
         (result nil) (done nil))
    (pai-agent-run (list (pai-user-message "go"))
                   (pai-context nil (list slow fast))
                   (list :model (pai-model "faux") :tool-execution 'parallel)
                   (lambda (ev)
                     (when (eq (plist-get ev :type) 'tool-execution-end)
                       (push (plist-get ev :tool-name) ends)))
                   (lambda (msgs) (setq result msgs done t)))
    (let ((deadline (+ (float-time) 5)))
      (while (and (not done) (< (float-time) deadline)) (accept-process-output nil 0.02)))
    (should done)
    ;; tool-execution-end fires in COMPLETION order: fast finished before slow
    (should (equal (reverse ends) '("fast" "slow")))
    ;; tool-result messages are in assistant SOURCE order: slow then fast
    (let ((trs (seq-filter #'pai-tool-result-message-p result)))
      (should (equal (mapcar (lambda (m) (pai-content-text (plist-get m :content))) trs)
                     '("SLOW" "FAST"))))))

(defvar-local pai-agent-test--project nil
  "Project state used to detect callbacks in the wrong buffer.")

(defun pai-agent-test--deferred-origin (mode)
  "Exercise deferred provider and tool callbacks in execution MODE."
  (let ((origin (generate-new-buffer " *pai-origin*"))
        (other (generate-new-buffer " *pai-other*"))
        provider-callback tool-callbacks observations result)
    (unwind-protect
        (cl-labels
            ((record (stage)
               (push (list stage pai-agent-test--project) observations))
             (tool (name)
               (list :name name :description name :parameters '(:type "object")
                     :deferred nil
                     :execute
                     (lambda (_args ctx update done)
                       (record name)
                       (push (list name update done (plist-get ctx :emit))
                             tool-callbacks))))
             (complete-tool (name)
               (let ((callbacks (assoc name tool-callbacks)))
                 (should callbacks)
                 (funcall (nth 1 callbacks) (pai-tool-ok-result "working"))
                 (funcall (nth 3 callbacks) '(:type custom-tool-event))
                 (funcall (nth 2 callbacks) (pai-tool-ok-result name)))))
          (with-current-buffer origin
            (setq pai-agent-test--project 'origin)
            (pai-agent-run
             (list (pai-user-message "go"))
             (pai-context nil (list (tool "first") (tool "second")))
             (list :model (pai-model "faux") :tool-execution mode
                   :stream-fn
                   (lambda (_model _ctx options callback)
                     (record 'provider)
                     (should (equal (plist-get options :api-key) "origin-key"))
                     (setq provider-callback callback))
                   :get-api-key
                   (lambda (_provider)
                     (record 'credentials)
                     (if (eq pai-agent-test--project 'origin)
                         "origin-key" "other-key"))
                   :before-tool-call (lambda (_call) (record 'before-tool) nil)
                   :after-tool-call (lambda (_call) (record 'after-tool) nil)
                   :prepare-next-turn (lambda (_turn) (record 'prepare-turn) nil))
             (lambda (event) (record (plist-get event :type)))
             (lambda (messages) (record 'completed) (setq result messages))))
          ;; No timers or UI mode: deliver callbacks with another project's
          ;; buffer current, as process filters and timers commonly do.
          (with-current-buffer other
            (setq pai-agent-test--project 'other)
            (let ((message (pai-assistant-message
                            :content (list (pai-tool-call "a" "first" nil)
                                           (pai-tool-call "b" "second" nil))
                            :stop-reason 'tool-use)))
              (funcall provider-callback (list :type 'start :partial message))
              (funcall provider-callback (list :type 'toolcall-delta :partial message))
              (funcall provider-callback (list :type 'done :message message)))
            (if (eq mode 'parallel)
                (progn (complete-tool "second") (complete-tool "first"))
              (complete-tool "first") (complete-tool "second"))
            (funcall provider-callback
                     (list :type 'done :message
                           (pai-assistant-message :content (list (pai-text "done"))
                                                  :stop-reason 'stop)))
            (should (eq (current-buffer) other)))
          (should (equal (mapcar (lambda (m) (plist-get m :tool-name))
                                (seq-filter #'pai-tool-result-message-p result))
                         '("first" "second")))
          (should (= (cl-count 'provider observations :key #'car) 2))
          (should (= (cl-count 'after-tool observations :key #'car) 2))
          (should (assoc 'prepare-turn observations))
          (should (assoc 'message-update observations))
          (should (assoc 'tool-execution-update observations))
          (should (assoc 'custom-tool-event observations))
          (should (assoc 'completed observations))
          (should (equal (delete-dups (mapcar #'cadr observations)) '(origin))))
      (kill-buffer origin)
      (kill-buffer other))))

(ert-deftest pai-agent-deferred-sequential-origin-buffer ()
  (pai-agent-test--deferred-origin 'sequential))

(ert-deftest pai-agent-deferred-parallel-origin-buffer ()
  (pai-agent-test--deferred-origin 'parallel))

(ert-deftest pai-agent-deferred-killed-origin-buffer ()
  (dolist (stage '(provider tool))
    (let ((origin (generate-new-buffer " *pai-killed-origin*"))
          callback run events completed)
      (unwind-protect
          (progn
            (with-current-buffer origin
              (setq run
                    (pai-agent-run
                     nil
                     (pai-context
                      nil (list (list :name "wait" :parameters '(:type "object")
                                      :execute (lambda (_a _c _u done)
                                                 (setq callback done)))))
                     (list :model (pai-model "faux")
                           :stream-fn (lambda (_m _c _o emit) (setq callback emit)))
                     (lambda (event) (push event events))
                     (lambda (_messages) (setq completed t))))
              (when (eq stage 'tool)
                (funcall callback
                         (list :type 'done :message
                               (pai-assistant-message
                                :content (list (pai-tool-call "a" "wait" nil))
                                :stop-reason 'tool-use)))))
            (kill-buffer origin)
            (let ((before events))
              (with-temp-buffer
                (funcall callback
                         (if (eq stage 'tool)
                             (pai-tool-ok-result "finished")
                           (list :type 'done :message
                                 (pai-assistant-message :stop-reason 'stop)))))
              (should (eq events before)))
            (should (pai-agent-aborted-p run))
            (should (pai-run-finished run))
            (should-not completed))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(provide 'pai-agent-test)
;;; pai-agent-test.el ends here
