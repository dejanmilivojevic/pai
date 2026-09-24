;;; pai-agent.el --- The agent loop -*- lexical-binding: t; -*-

;;; Commentary:

;; The event-driven agent loop: a faithful port of the control flow in
;; packages/agent/src/agent-loop.ts, restructured as a callback/continuation
;; state machine so it works with asynchronous providers and tools without
;; blocking Emacs.
;;
;; A run is driven by `pai-agent-run'.  It emits a stream of agent events (see
;; docs/ARCHITECTURE.md section 2) via the EMIT callback and, on completion,
;; calls ON-COMPLETE with the list of newly produced messages.
;;
;; The loop structure mirrors pi: an outer loop drains a follow-up queue and
;; wraps an inner loop that, each turn, optionally prepares the next turn,
;; injects steering/prepared messages, streams an assistant response, executes
;; its tool calls, then decides whether to stop or continue.

;;; Code:

(require 'cl-lib)
(require 'pai-core)
(require 'pai-provider)
(require 'pai-config)
(require 'pai-tools)

(cl-defstruct (pai-run (:constructor pai-run-create))
  context config emit
  (new-messages '())
  prepared pending
  lastturn
  (has-more t)
  streamfn handle on-complete
  (finished nil)
  origin-buffer
  (aborted nil)
  ;; partial assistant message of the stream in flight, or nil
  partial
  ;; processes / functions to kill / call when the run is aborted
  (abort-handlers '()))

;;;; Hook dispatch

(defun pai-agent--hook (run key)
  "Return the hook function stored under KEY in RUN's config, or nil."
  (plist-get (pai-run-config run) key))

(defun pai-agent--call (run key &rest args)
  "Call the hook KEY in RUN's config with ARGS; return its value or nil."
  (let ((fn (pai-agent--hook run key)))
    (when fn (apply fn args))))

(defun pai-agent--emit (run event)
  "Emit EVENT to RUN's sink."
  (when (pai-run-emit run)
    (funcall (pai-run-emit run) event)))

(defun pai-agent--deferred (run fn)
  "Return a wrapper around FN that always calls it in RUN's origin buffer.
Asynchronous continuations (provider stream events, tool callbacks) may fire
while an unrelated buffer is current; wrapping them keeps buffer-local agent
state (registries, settings) reachable.  If the origin buffer has been killed
the continuation is not run at all: the run is marked aborted and finished
without invoking callbacks in an unrelated buffer.  Once RUN is aborted or
finished, late continuations (a killed stream's final event, a tool that
completes after an interrupt) are dropped so the loop cannot resume."
  (let ((buf (pai-run-origin-buffer run)))
    (lambda (value)
      (cond
       ((or (pai-run-aborted run) (pai-run-finished run)) nil)
       ((buffer-live-p buf)
        (with-current-buffer buf (funcall fn value)))
       (t (setf (pai-run-aborted run) t
                (pai-run-finished run) t))))))

;;;; Message bookkeeping

(defun pai-agent--push-context (run message)
  "Append MESSAGE to RUN's context transcript."
  (setf (pai-run-context run)
        (plist-put (pai-run-context run) :messages
                   (append (plist-get (pai-run-context run) :messages) (list message)))))

(defun pai-agent--append-message (run message &optional emitp)
  "Append MESSAGE to context and new-messages.  When EMITP, emit lifecycle events."
  (when emitp (pai-agent--emit run (list :type 'message-start :message message)))
  (pai-agent--push-context run message)
  (setf (pai-run-new-messages run) (append (pai-run-new-messages run) (list message)))
  (when emitp (pai-agent--emit run (list :type 'message-end :message message))))

;;;; Public entry points

(defun pai-agent-run (prompts context config emit &optional on-complete)
  "Start an agent run with PROMPTS in CONTEXT under CONFIG.
CONTEXT is `(:messages LIST :tools LIST)' where :tools are executable tool
plists.  CONFIG is a plist of the model and hooks (see docs/ARCHITECTURE.md
section 4).  EMIT receives agent events; ON-COMPLETE receives the new message
list.  Return the run object (usable with `pai-agent-abort').
Deferred callbacks run in the current buffer captured here, independently of
major mode.  If that buffer is killed, further callbacks are discarded."
  (let ((run (pai-run-create
              :context (list :messages (copy-sequence (plist-get context :messages))
                             :tools (plist-get context :tools))
              :config config :emit emit
              :origin-buffer (current-buffer)
              :streamfn (or (plist-get config :stream-fn) #'pai-provider-stream)
              :on-complete on-complete)))
    (pai-agent--emit run '(:type agent-start))
    (pai-agent--emit run '(:type turn-start))
    (dolist (m prompts) (pai-agent--append-message run m t))
    (setf (pai-run-has-more run) t
          (pai-run-pending run) (pai-agent--call run :get-steering-messages))
    (pai-agent--inner-iterate run)
    run))

(defun pai-agent-on-abort (run handler)
  "Register HANDLER to stop work of RUN when it is aborted.
HANDLER is a process (deleted) or a function of no arguments (called).
Tools reach RUN via the `:run' key of their context."
  (when (and run handler)
    (push handler (pai-run-abort-handlers run))))

(defun pai-agent--record-partial (run)
  "Record the partial assistant message of RUN's aborted stream, if any.
Only its text is kept (tool calls may be truncated, thinking unsigned)."
  (let* ((partial (pai-run-partial run))
         (text (and partial
                    (seq-filter (lambda (b)
                                  (and (eq (pai-block-type b) 'text)
                                       (not (string-empty-p
                                             (string-trim (or (plist-get b :text) ""))))))
                                (pai-message-content partial)))))
    (setf (pai-run-partial run) nil)
    (when text
      (let ((msg (plist-put (plist-put (copy-sequence partial) :content (copy-sequence text))
                            :stop-reason 'aborted)))
        (pai-agent--emit run (list :type 'message-end :message msg))
        (setf (pai-run-new-messages run) (append (pai-run-new-messages run) (list msg)))
        (pai-agent--push-context run msg)))))

(defun pai-agent-abort (run)
  "Abort RUN immediately.
Kill the provider stream and running tools (see `pai-agent-on-abort'),
keep the text streamed so far, and emit `agent-end' with `:aborted t'.
No further events are emitted and ON-COMPLETE is not called: whoever aborts
owns the completion."
  (unless (or (pai-run-aborted run) (pai-run-finished run))
    ;; Mark first: killing a process runs its sentinel synchronously, and
    ;; the continuations it triggers must see the run is over.
    (setf (pai-run-aborted run) t)
    (let ((handle (pai-run-handle run)))
      (setf (pai-run-handle run) nil)
      (ignore-errors (pai-provider-abort handle)))
    (dolist (h (prog1 (pai-run-abort-handlers run)
                 (setf (pai-run-abort-handlers run) nil)))
      (condition-case err
          (cond ((processp h) (when (process-live-p h) (delete-process h)))
                ((functionp h) (funcall h)))
        (error (message "pai: abort handler failed: %s" (error-message-string err)))))
    (pai-agent--record-partial run)
    (setf (pai-run-finished run) t)
    (pai-agent--emit run (list :type 'agent-end :messages (pai-run-new-messages run)
                               :aborted t))))

(defun pai-agent-aborted-p (run)
  "Return non-nil if RUN has been aborted."
  (pai-run-aborted run))

;;;; Inner loop

(defun pai-agent--apply-turn-update (run upd)
  "Apply a prepare-next-turn update plist UPD to RUN."
  (when (plist-member upd :context) (setf (pai-run-context run) (plist-get upd :context)))
  (setf (pai-run-prepared run) (plist-get upd :messages))
  (let ((config (pai-run-config run)))
    (when (plist-get upd :model)
      (setq config (plist-put (copy-sequence config) :model (plist-get upd :model))))
    (when (plist-member upd :thinking-level)
      (let ((lvl (plist-get upd :thinking-level)))
        (setq config (plist-put (copy-sequence config) :reasoning
                                (if (eq lvl 'off) nil lvl)))))
    (setf (pai-run-config run) config)))

(defun pai-agent--inner-iterate (run)
  "Run one inner-loop iteration of RUN, or advance to the follow-up check."
  (cond
   ((pai-run-finished run) nil)
   ((not (or (pai-run-has-more run) (pai-run-pending run)))
    (pai-agent--after-inner run))
   (t
    (when (pai-run-lastturn run)
      (let ((upd (pai-agent--call run :prepare-next-turn (pai-run-lastturn run))))
        (when upd (pai-agent--apply-turn-update run upd)))
      (unless (pai-run-pending run)
        (setf (pai-run-pending run) (pai-agent--call run :get-steering-messages)))
      (pai-agent--emit run '(:type turn-start)))
    (dolist (m (append (pai-run-prepared run) (pai-run-pending run)))
      (pai-agent--append-message run m t))
    (setf (pai-run-prepared run) nil (pai-run-pending run) nil)
    (pai-agent--stream-assistant run))))

;;;; Streaming a turn

(defun pai-agent--convert-context (run)
  "Return the LLM Message list for RUN, applying transform/convert hooks.
Tool calls left without results (crash, abort) are repaired last, see
`pai-repair-tool-pairing'."
  (let* ((messages (plist-get (pai-run-context run) :messages))
         (transformed (or (pai-agent--call run :transform-context messages) messages))
         (converted (if (pai-agent--hook run :convert-to-llm)
                        (funcall (pai-agent--hook run :convert-to-llm) transformed)
                      transformed)))
    (pai-repair-tool-pairing converted)))

(defun pai-agent--tool-declarations (run)
  "Return provider tool declarations from RUN's executable tools.
Deferred tools are declared as stable stubs (see `pai-tool-declaration')."
  (mapcar #'pai-tool-declaration (plist-get (pai-run-context run) :tools)))

(defun pai-agent--pending-reveal (run tool)
  "Return a schema-reveal result if deferred TOOL is still unrevealed in RUN."
  (pai-tool-pending-reveal tool (plist-get (pai-run-context run) :messages)))

(defun pai-agent--stream-options (run)
  "Assemble provider stream OPTIONS from RUN's config."
  (let* ((config (pai-run-config run))
         (model (plist-get config :model))
         (key (pai-agent--call run :get-api-key (and model (pai-model-provider model)))))
    (append
     (when key (list :api-key key))
     (when (plist-get config :max-tokens) (list :max-tokens (plist-get config :max-tokens)))
     (when (plist-get config :temperature) (list :temperature (plist-get config :temperature)))
     (when (plist-get config :reasoning) (list :reasoning (plist-get config :reasoning)))
     (when (plist-get config :tool-choice) (list :tool-choice (plist-get config :tool-choice)))
     (when (plist-get config :session-id) (list :session-id (plist-get config :session-id))))))

(defun pai-agent--stream-assistant (run)
  "Stream one assistant response for RUN, then continue via on-assistant-done."
  (let* ((config (pai-run-config run))
         (model (plist-get config :model))
         (ctx (pai-context (pai-agent--convert-context run) (pai-agent--tool-declarations run)))
         (options (pai-agent--stream-options run))
         (started nil))
    (setf (pai-run-handle run)
          (funcall (pai-run-streamfn run) model ctx options
                   (pai-agent--deferred run (lambda (ev)
                     (pcase (plist-get ev :type)
                       ((or 'done 'error) (setf (pai-run-partial run) nil))
                       (_ (when (plist-get ev :partial)
                            (setf (pai-run-partial run) (plist-get ev :partial)))))
                     (pcase (plist-get ev :type)
                       ('start
                        (setq started t)
                        (pai-agent--emit run (list :type 'message-start
                                                   :message (plist-get ev :partial))))
                       ((or 'text-start 'text-delta 'text-end
                            'thinking-start 'thinking-delta 'thinking-end
                            'toolcall-start 'toolcall-delta 'toolcall-end)
                        (pai-agent--emit run (list :type 'message-update
                                                   :message (plist-get ev :partial)
                                                   :event ev)))
                       ((or 'done 'error)
                        (let ((final (plist-get ev :message)))
                          (unless started
                            (pai-agent--emit run (list :type 'message-start :message final)))
                          (pai-agent--emit run (list :type 'message-end :message final))
                          (pai-agent--on-assistant-done run final))))))))))

(defun pai-agent--on-assistant-done (run message)
  "Continue RUN after the assistant MESSAGE for this turn is complete."
  (setf (pai-run-new-messages run) (append (pai-run-new-messages run) (list message)))
  (pai-agent--push-context run message)
  (let ((stop (plist-get message :stop-reason)))
    (if (memq stop '(error aborted))
        (progn
          (pai-agent--emit run (list :type 'turn-end :message message :tool-results nil))
          (pai-agent--finish run))
      (let ((tool-calls (pai-message-tool-calls message)))
        (if (null tool-calls)
            (pai-agent--turn-complete run message nil nil)
          (if (eq stop 'length)
              (pai-agent--fail-truncated-tools run message tool-calls)
            (pai-agent--execute-tools run message tool-calls)))))))

;;;; Tool execution (sequential)

(defun pai-agent--tool-ctx (run tool-call-id)
  "Build the tool execution context plist for RUN and TOOL-CALL-ID."
  (let* ((config (pai-run-config run)))
    (list :cwd (or (plist-get config :cwd) default-directory)
          :model (plist-get config :model)
          :session (plist-get config :session)
          :run run
          :emit (pai-agent--deferred run (lambda (event) (pai-agent--emit run event)))
          :tool-call-id tool-call-id)))

(defun pai-agent--find-tool (run name)
  "Return the executable tool plist named NAME in RUN's context, or nil."
  (seq-find (lambda (tool) (equal (plist-get tool :name) name))
            (plist-get (pai-run-context run) :tools)))

(defun pai-agent--invoke-tool (tool args ctx on-update on-done)
  "Run TOOL's :execute on ARGS (numbers/booleans coerced) with CTX.
ON-UPDATE and ON-DONE are the tool callbacks.  An error signalled before
the tool finished becomes an error result instead of escaping into a
process filter and leaving the run hanging; ON-DONE runs at most once.
An error after the tool finished (e.g. while the batch continues inside
a synchronous ON-DONE) is not the tool's and is signalled again."
  (let ((done nil))
    (condition-case err
        (let ((ret (funcall (plist-get tool :execute) (pai-tool-coerce-args tool args)
                            ctx on-update
                            (lambda (result)
                              (unless done
                                (setq done t)
                                (funcall on-done result))))))
          ;; A tool returning its process (e.g. bash) is killed on abort.
          (when (and (not done) (processp ret))
            (pai-agent-on-abort (plist-get ctx :run) ret)))
      (error
       (if done
           (signal (car err) (cdr err))
         (setq done t)
         (funcall on-done
                  (pai-tool-error-result
                   (format "Tool %s failed: %s" (plist-get tool :name)
                           (error-message-string err)))))))))

(defun pai-agent--make-tool-result-message (tool-call result)
  "Build a tool-result message from TOOL-CALL and RESULT plist."
  (pai-tool-result-message
   :tool-call-id (plist-get tool-call :id)
   :tool-name (plist-get tool-call :name)
   :content (plist-get result :content)
   :details (plist-get result :details)
   :is-error (pai-truthy (plist-get result :is-error))
   :usage (plist-get result :usage)))

(defun pai-agent--fail-truncated-tools (run message tool-calls)
  "Fail every TOOL-CALL from a length-truncated MESSAGE without executing them."
  (let ((results '()))
    (dolist (tc tool-calls)
      (pai-agent--emit run (list :type 'tool-execution-start
                                 :tool-call-id (plist-get tc :id)
                                 :tool-name (plist-get tc :name)
                                 :args (plist-get tc :arguments)))
      (let ((result (pai-tool-error-result
                     (format "Tool call \"%s\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments."
                             (plist-get tc :name)))))
        (pai-agent--emit run (list :type 'tool-execution-end
                                   :tool-call-id (plist-get tc :id)
                                   :tool-name (plist-get tc :name)
                                   :result result :is-error t))
        (push (pai-agent--make-tool-result-message tc result) results)))
    (pai-agent--finish-tool-batch run message (nreverse results) nil)))

(defun pai-agent--execute-tools (run message tool-calls)
  "Execute TOOL-CALLS from MESSAGE, choosing parallel or sequential mode."
  (if (and (eq (plist-get (pai-run-config run) :tool-execution) 'parallel)
           (> (length tool-calls) 1)
           (not (seq-some
                 (lambda (tc)
                   (let ((tool (pai-agent--find-tool run (plist-get tc :name))))
                     (eq (plist-get tool :execution-mode) 'sequential)))
                 tool-calls)))
      (pai-agent--execute-tools-parallel run message tool-calls)
    (pai-agent--execute-tools-sequential run message tool-calls)))

(defun pai-agent--execute-tools-sequential (run message tool-calls)
  "Execute TOOL-CALLS from MESSAGE sequentially, then finish the batch."
  (let ((results '()) (terminate t))
    (cl-labels
        ((finish-call (tc tool args _ctx result remaining)
           (let* ((over (pai-agent--call run :after-tool-call
                                         (list :tool-call tc :args args :tool tool
                                               :result result
                                               :is-error (pai-truthy (plist-get result :is-error))
                                               :context (pai-run-context run))))
                  (final (pai-agent--merge-tool-override result over))
                  (call-terminate (pai-truthy
                                   (if (and over (plist-member over :terminate))
                                       (plist-get over :terminate)
                                     (plist-get final :terminate)))))
             ;; A batch terminates only when EVERY call requests termination.
             (setq terminate (and terminate call-terminate))
             (pai-agent--emit run (list :type 'tool-execution-end
                                        :tool-call-id (plist-get tc :id)
                                        :tool-name (plist-get tc :name)
                                        :result final
                                        :is-error (pai-truthy (plist-get final :is-error))))
             (push (pai-agent--make-tool-result-message tc final) results)
             (if (pai-run-aborted run)
                 (pai-agent--finish-tool-batch run message (nreverse results) nil)
               (step (cdr remaining)))))
         (step (remaining)
           (if (null remaining)
               (pai-agent--finish-tool-batch run message (nreverse results)
                                             (and results terminate))
             (let* ((tc (car remaining))
                    (name (plist-get tc :name))
                    (args (plist-get tc :arguments))
                    (tool (pai-agent--find-tool run name))
                    (ctx (pai-agent--tool-ctx run (plist-get tc :id)))
                    (reveal (pai-agent--pending-reveal run tool)))
               (pai-agent--emit run (list :type 'tool-execution-start
                                          :tool-call-id (plist-get tc :id)
                                          :tool-name name :args args))
               ;; A reveal executes nothing, so it skips the before-tool-call
               ;; (permission) hook.
               (let ((pre (unless reveal
                            (pai-agent--call run :before-tool-call
                                             (list :tool-call tc :args args :tool tool
                                                   :context (pai-run-context run))))))
                 (cond
                  (reveal (finish-call tc tool args ctx reveal remaining))
                  ((and pre (pai-truthy (plist-get pre :block)))
                   (let ((result (append
                                  (pai-tool-error-result
                                   (or (plist-get pre :reason)
                                       (format "Tool \"%s\" was blocked." name)))
                                  (when (plist-member pre :terminate)
                                    (list :terminate (plist-get pre :terminate))))))
                     (finish-call tc tool args ctx result remaining)))
                  ((null tool)
                   (finish-call tc tool args ctx
                                (pai-tool-error-result (format "Unknown tool: %s" name))
                                remaining))
                  (t
                   (pai-agent--invoke-tool tool args ctx
                            (pai-agent--deferred run (lambda (partial)
                              (pai-agent--emit run (list :type 'tool-execution-update
                                                         :tool-call-id (plist-get tc :id)
                                                         :tool-name name :args args
                                                         :partial-result partial))))
                            (pai-agent--deferred run (lambda (result)
                              (finish-call tc tool args ctx result remaining)))))))))))
      (step tool-calls))))

(defun pai-agent--execute-tools-parallel (run message tool-calls)
  "Execute TOOL-CALLS from MESSAGE concurrently, then finish the batch.
Preflight (before-tool-call) runs sequentially; allowed tools are launched
together; `tool-execution-end' is emitted in completion order; the tool-result
messages are assembled in assistant source order."
  (let* ((n (length tool-calls))
         (calls (apply #'vector tool-calls))
         (results (make-vector n nil))
         (terminate-flags (make-vector n nil))
         (pending n))
    (cl-labels
        ((complete (i tc tool args result)
           (let* ((over (pai-agent--call run :after-tool-call
                                         (list :tool-call tc :args args :tool tool
                                               :result result
                                               :is-error (pai-truthy (plist-get result :is-error))
                                               :context (pai-run-context run))))
                  (final (pai-agent--merge-tool-override result over))
                  (call-term (pai-truthy
                              (if (and over (plist-member over :terminate))
                                  (plist-get over :terminate)
                                (plist-get final :terminate)))))
             (aset results i final)
             (aset terminate-flags i call-term)
             (pai-agent--emit run (list :type 'tool-execution-end
                                        :tool-call-id (plist-get tc :id)
                                        :tool-name (plist-get tc :name)
                                        :result final
                                        :is-error (pai-truthy (plist-get final :is-error))))
             (setq pending (1- pending))
             (when (= pending 0) (finish))))
         (finish ()
           (let ((msgs (cl-loop for i from 0 below n
                                collect (pai-agent--make-tool-result-message
                                         (aref calls i) (aref results i))))
                 (terminate (and (> n 0) (cl-every #'identity (append terminate-flags nil)))))
             (pai-agent--finish-tool-batch run message msgs terminate))))
      (dotimes (i n)
        (let* ((tc (aref calls i))
               (name (plist-get tc :name))
               (args (plist-get tc :arguments))
               (tool (pai-agent--find-tool run name))
               (ctx (pai-agent--tool-ctx run (plist-get tc :id)))
               (reveal (pai-agent--pending-reveal run tool)))
          (pai-agent--emit run (list :type 'tool-execution-start
                                     :tool-call-id (plist-get tc :id)
                                     :tool-name name :args args))
          (let ((pre (unless reveal
                       (pai-agent--call run :before-tool-call
                                        (list :tool-call tc :args args :tool tool
                                              :context (pai-run-context run))))))
            (cond
             (reveal (complete i tc tool args reveal))
             ((and pre (pai-truthy (plist-get pre :block)))
              (complete i tc tool args
                        (append (pai-tool-error-result
                                 (or (plist-get pre :reason)
                                     (format "Tool \"%s\" was blocked." name)))
                                (when (plist-member pre :terminate)
                                  (list :terminate (plist-get pre :terminate))))))
             ((null tool)
              (complete i tc tool args (pai-tool-error-result (format "Unknown tool: %s" name))))
             (t
              (pai-agent--invoke-tool tool args ctx
                       (pai-agent--deferred run (lambda (partial)
                         (pai-agent--emit run (list :type 'tool-execution-update
                                                    :tool-call-id (plist-get tc :id)
                                                    :tool-name name :args args
                                                    :partial-result partial))))
                       (pai-agent--deferred run
                        (lambda (result) (complete i tc tool args result))))))))))))

(defun pai-agent--merge-tool-override (result over)
  "Merge an after-tool-call OVER plist onto RESULT, field by field."
  (if (null over)
      result
    (let ((out (copy-sequence result)))
      (when (plist-member over :content) (setq out (plist-put out :content (plist-get over :content))))
      (when (plist-member over :details) (setq out (plist-put out :details (plist-get over :details))))
      (when (plist-member over :is-error) (setq out (plist-put out :is-error (plist-get over :is-error))))
      (when (plist-member over :usage) (setq out (plist-put out :usage (plist-get over :usage))))
      out)))

(defun pai-agent--finish-tool-batch (run message results terminate)
  "Append tool RESULTS for MESSAGE to RUN and complete the turn.
TERMINATE non-nil requests stopping after this batch."
  (dolist (r results) (pai-agent--append-message run r nil))
  (pai-agent--turn-complete run message results (not terminate)))

;;;; Turn completion

(defun pai-agent--turn-complete (run message results has-more)
  "Emit turn-end for MESSAGE with RESULTS and decide whether to continue.
HAS-MORE indicates tool calls may continue the loop."
  (pai-agent--emit run (list :type 'turn-end :message message :tool-results results))
  (setf (pai-run-has-more run) has-more
        (pai-run-lastturn run) (list :message message :tool-results results
                                     :context (pai-run-context run)
                                     :new-messages (pai-run-new-messages run)))
  (if (pai-agent--call run :should-stop-after-turn (pai-run-lastturn run))
      (pai-agent--finish run)
    (progn
      (setf (pai-run-pending run) (pai-agent--call run :get-steering-messages))
      (pai-agent--inner-iterate run))))

;;;; Outer loop / completion

(defun pai-agent--after-inner (run)
  "Check the follow-up queue for RUN; loop again or finish."
  (let ((followups (pai-agent--call run :get-follow-up-messages)))
    (if followups
        (progn (setf (pai-run-pending run) followups)
               (pai-agent--inner-iterate run))
      (pai-agent--finish run))))

(defun pai-agent--finish (run)
  "Emit agent-end for RUN once and invoke its completion callback."
  (unless (pai-run-finished run)
    (setf (pai-run-finished run) t)
    (pai-agent--emit run (list :type 'agent-end :messages (pai-run-new-messages run)))
    (when (pai-run-on-complete run)
      (funcall (pai-run-on-complete run) (pai-run-new-messages run)))))

(provide 'pai-agent)
;;; pai-agent.el ends here
