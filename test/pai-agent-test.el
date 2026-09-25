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

;;;; Interrupt

(ert-deftest pai-agent-abort-mid-stream-stops-immediately ()
  "Killing the stream runs its sentinel synchronously; the final event it
produces (here with a tool call) must not resume the loop."
  (let* ((events '()) (executed nil) (streams 0) (completed nil)
         (partial (pai-assistant-message :content (list (pai-text "half an answ"))))
         (tool (list :name "echo" :deferred nil :parameters '(:type "object")
                     :execute (lambda (_a _c _u done)
                                (setq executed t)
                                (funcall done (pai-tool-ok-result "x")))))
         (run (pai-agent-run
               (list (pai-user-message "go"))
               (pai-context nil (list tool))
               (list :model (pai-model "faux")
                     :stream-fn
                     (lambda (_m _c _o emit)
                       (cl-incf streams)
                       (funcall emit (list :type 'start :partial partial))
                       (funcall emit (list :type 'text-delta :delta "half an answ"
                                           :partial partial))
                       (make-process
                        :name "pai-test-stream" :command '("sleep" "30") :noquery t
                        :sentinel
                        (lambda (_p _e)
                          (funcall emit
                                   (list :type 'done :message
                                         (pai-assistant-message
                                          :content (list (pai-text "half an answ")
                                                         (pai-tool-call "c1" "echo" nil))
                                          :stop-reason 'tool-use)))))))
               (lambda (ev) (push ev events))
               (lambda (_m) (setq completed t)))))
    (pai-agent-abort run)
    (accept-process-output nil 0.1)
    (should (pai-agent-aborted-p run))
    (should (pai-run-finished run))
    (should-not executed)
    (should (= streams 1))
    (should-not completed)
    (let ((ends (seq-filter (lambda (e) (eq (plist-get e :type) 'agent-end)) events)))
      (should (= (length ends) 1))
      (should (plist-get (car ends) :aborted)))
    (should (eq (plist-get (car events) :type) 'agent-end))
    ;; the streamed text is kept, marked aborted, without tool calls
    (let ((last (car (last (pai-run-new-messages run)))))
      (should (eq (plist-get last :stop-reason) 'aborted))
      (should (equal (pai-content-text (pai-message-content last)) "half an answ"))
      (should-not (pai-message-tool-calls last)))))

(ert-deftest pai-agent-abort-mid-tool-kills-and-stops ()
  (let* ((events '()) (proc nil) (tool-done nil) (streams 0)
         (tool (list :name "slow" :deferred nil :parameters '(:type "object")
                     :execute (lambda (_a _c _u done)
                                (setq tool-done done
                                      proc (make-process :name "pai-test-tool"
                                                         :command '("sleep" "30")
                                                         :noquery t))
                                proc)))
         (run (pai-agent-run
               (list (pai-user-message "go"))
               (pai-context nil (list tool))
               (list :model (pai-model "faux")
                     :stream-fn
                     (lambda (_m _c _o emit)
                       (cl-incf streams)
                       (funcall emit
                                (list :type 'done :message
                                      (pai-assistant-message
                                       :content (list (pai-tool-call "c1" "slow" nil))
                                       :stop-reason 'tool-use)))
                       nil))
               (lambda (ev) (push ev events))
               nil)))
    (should (process-live-p proc))
    (pai-agent-abort run)
    (should-not (process-live-p proc))
    (let ((before events))
      ;; the tool reporting late must not resume the loop
      (funcall tool-done (pai-tool-ok-result "late"))
      (should (eq events before)))
    (should (= streams 1))
    (should (plist-get (car events) :aborted))))

;;;; Pausing between turns (compaction mid-run)

(defvar pai-agent-test--streams nil "Scripted assistant messages (dynamically bound).")
(defvar pai-agent-test--contexts nil "Recorded request contexts (dynamically bound).")

(defun pai-agent-test--scripted-stream (streams contexts)
  "Return a stream-fn answering from STREAMS (a list of messages) in order.
Each request's context messages are pushed onto the symbol CONTEXTS."
  (lambda (_m ctx _o emit)
    (set contexts (cons (plist-get ctx :messages) (symbol-value contexts)))
    (funcall emit (list :type 'done :message (pop (symbol-value streams))))
    nil))

(ert-deftest pai-agent-before-turn-pauses-and-resumes-with-new-context ()
  (let* ((tool (list :name "echo" :deferred nil :parameters '(:type "object")
                     :execute (lambda (_a _c _u done) (funcall done (pai-tool-ok-result "r")))))
         (pai-agent-test--streams
          (list (pai-assistant-message :content (list (pai-tool-call "c1" "echo" nil))
                                       :stop-reason 'tool-use)
                (pai-assistant-message :content (list (pai-text "done")) :stop-reason 'stop)))
         (pai-agent-test--contexts nil)
         (resume nil) (hook-calls 0) (completed nil)
         (compacted (list (pai-user-message "SUMMARY"))))
    (let ((run (pai-agent-run
                (list (pai-user-message "go"))
                (pai-context nil (list tool))
                (list :model (pai-model "faux")
                      :stream-fn (pai-agent-test--scripted-stream
                                  'pai-agent-test--streams 'pai-agent-test--contexts)
                      :before-turn (lambda (_ctx r) (cl-incf hook-calls) (setq resume r) t))
                #'ignore
                (lambda (_m) (setq completed t)))))
      ;; paused after the tool turn: no second request yet
      (should (= hook-calls 1))
      (should (= (length pai-agent-test--contexts) 1))
      (should (pai-agent-paused-p run))
      (should-not completed)
      (funcall resume (list :messages compacted))
      (should-not (pai-agent-paused-p run))
      (should completed)
      ;; the next request went out with the replaced context
      (should (= (length pai-agent-test--contexts) 2))
      (should (equal (pai-content-text (pai-message-content (car (car pai-agent-test--contexts))))
                     "SUMMARY"))
      ;; not offered again for the same turn
      (should (= hook-calls 1)))))

(ert-deftest pai-agent-before-turn-declined-continues ()
  (pai-faux-reset)
  (pai-faux-push '(:tool-calls ((:id "c1" :name "echo" :arguments (:msg "a"))) :stop-reason tool-use)
                 '(:text "end" :stop-reason stop))
  (let* ((calls 0)
         (out (pai-agent-test--run (list (pai-user-message "go"))
                                   (list :model (pai-model "faux")
                                         :tools (list (pai-agent-test--echo-tool))
                                         :before-turn (lambda (_c _r) (cl-incf calls) nil)))))
    (should (= calls 1))
    (should (equal (pai-content-text (pai-message-content (car (last (cdr out))))) "end"))))

(ert-deftest pai-agent-abort-while-paused-drops-resume ()
  (let* ((resume nil) (streams 0) (events nil)
         (tool (list :name "echo" :deferred nil :parameters '(:type "object")
                     :execute (lambda (_a _c _u done) (funcall done (pai-tool-ok-result "r")))))
         (run (pai-agent-run
               (list (pai-user-message "go"))
               (pai-context nil (list tool))
               (list :model (pai-model "faux")
                     :stream-fn (lambda (_m _c _o emit)
                                  (cl-incf streams)
                                  (funcall emit (list :type 'done :message
                                                      (pai-assistant-message
                                                       :content (list (pai-tool-call "c1" "echo" nil))
                                                       :stop-reason 'tool-use)))
                                  nil)
                     :before-turn (lambda (_c r) (setq resume r) t))
               (lambda (e) (push e events)))))
    (pai-agent-abort run)
    (funcall resume (list :messages nil))
    (should (= streams 1))
    (should (plist-get (car events) :aborted))))

(ert-deftest pai-agent-recover-error-retries-turn ()
  (let* ((pai-agent-test--streams
          (list (pai-assistant-message :stop-reason 'error
                                       :error-message "prompt is too long: 210000 tokens")
                (pai-assistant-message :content (list (pai-text "recovered")) :stop-reason 'stop)))
         (pai-agent-test--contexts nil)
         (seen nil)
         (run (pai-agent-run
               (list (pai-user-message "go"))
               (pai-context nil nil)
               (list :model (pai-model "faux")
                     :stream-fn (pai-agent-test--scripted-stream
                                 'pai-agent-test--streams 'pai-agent-test--contexts)
                     :recover-error (lambda (msg ctx resume)
                                      (setq seen (list msg ctx))
                                      (funcall resume (list :messages (list (pai-user-message "SMALL"))))
                                      t))
               #'ignore)))
    (should (equal (plist-get (car seen) :error-message) "prompt is too long: 210000 tokens"))
    ;; the failed message is not in the context handed to the hook
    (should-not (memq (car seen) (plist-get (cadr seen) :messages)))
    (should (= (length pai-agent-test--contexts) 2))
    (should (equal (pai-content-text (pai-message-content (car (car pai-agent-test--contexts))))
                   "SMALL"))
    (should (pai-run-finished run))
    (should (equal (pai-content-text (pai-message-content
                                      (car (last (plist-get (pai-run-context run) :messages)))))
                   "recovered"))))

(ert-deftest pai-agent-recover-error-declined-ends-run ()
  (let* ((pai-agent-test--streams
          (list (pai-assistant-message :stop-reason 'error :error-message "boom")))
         (pai-agent-test--contexts nil)
         (resumed nil) (completed nil))
    (pai-agent-run (list (pai-user-message "go")) (pai-context nil nil)
                   (list :model (pai-model "faux")
                         :stream-fn (pai-agent-test--scripted-stream
                                     'pai-agent-test--streams 'pai-agent-test--contexts)
                         :recover-error (lambda (_m _c resume) (setq resumed resume) t))
                   #'ignore (lambda (_m) (setq completed t)))
    (should-not completed)
    (funcall resumed)                   ; recovery failed: end with the error
    (should completed)
    (should (= (length pai-agent-test--contexts) 1))))

(ert-deftest pai-agent-abort-calls-handlers-once ()
  (let* ((calls 0)
         (run (pai-agent-run nil (pai-context nil nil)
                             (list :model (pai-model "faux")
                                   :stream-fn (lambda (&rest _) nil))
                             #'ignore)))
    (pai-agent-on-abort run (lambda () (cl-incf calls)))
    (pai-agent-abort run)
    (pai-agent-abort run)
    (should (= calls 1))))

(provide 'pai-agent-test)
;;; pai-agent-test.el ends here
