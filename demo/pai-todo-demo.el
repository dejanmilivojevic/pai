;;; pai-todo-demo.el --- A scripted demo of the pai-todo extension -*- lexical-binding: t; -*-

;;; Commentary:

;; M-x pai-todo-demo plays a short session in its own buffer, "*pai: todo
;; demo*", in a temporary project.  The "model" is scripted (pai's faux
;; provider, answering after `pai-todo-demo-delay' seconds like a streaming
;; model), so it costs nothing; background memory is stopped for the
;; session so nothing is learned from it.
;;
;; What it shows:
;;   1. the agent plans with the todo tool; the status bar follows each step
;;   2. it stops with open tasks and gets a reminder, then carries on
;;   3. it blocks a task it cannot do (a server is down)
;;   4. you: /todo, /todo unblock, /todo append, /todo done (typed for you)
;;   5. /todo edit opens the list as an Org outline

;;; Code:

(require 'cl-lib)
(require 'pai)
(add-to-list 'load-path (expand-file-name "../test" (file-name-directory (or load-file-name buffer-file-name))))
(require 'pai-faux)
(require 'pai-todo)

(declare-function pai-memory-set-session-state "pai-memory-settings" (session &rest kvs))

(defvar pai-todo-demo-delay 1.2 "Seconds the scripted model takes per reply.")
(defvar pai-todo-demo-pause 2.0 "Seconds between the demo's steps.")
(defvar pai-todo-demo-type-speed 0.04 "Seconds per typed character.")

(defun pai-todo-demo--stream (model context options emit)
  "Answer like `pai-faux-stream', after `pai-todo-demo-delay' seconds."
  (run-at-time pai-todo-demo-delay nil #'pai-faux-stream model context options emit)
  nil)

(pai-register-provider (list :id "todo-demo" :stream #'pai-todo-demo--stream))
(pai-register-model (pai-make-model :id "todo-demo" :name "Scripted demo model" :api 'faux
                                    :provider "todo-demo" :base-url "faux://demo"))

(defun pai-todo-demo--call (id &rest args)
  "A scripted todo tool call ID with ARGS."
  (list :id id :name "todo" :arguments args))

(defun pai-todo-demo--script ()
  "Queue the scripted model's replies."
  (pai-faux-reset)
  (pai-faux-push
   ;; the request: plan first
   (list :text "This touches parsing and the write path, so I'll plan it first."
         :tool-calls
         (list (pai-todo-demo--call
                "t1" :op "init"
                :list '((:phase "Investigate" :items ("Read deploy.sh" "Find where changes are applied"))
                        (:phase "Implement" :items ("Parse the --dry-run flag" "Skip writes in dry-run mode"))
                        (:phase "Verify" :items ("Run the deploy tests"))))))
   (list :text "deploy.sh is 120 lines; flags are parsed in `parse_args'."
         :tool-calls (list (pai-todo-demo--call "t2" :op "done" :task "Read deploy.sh")))
   (list :text "All writes go through `apply_changes'."
         :tool-calls (list (pai-todo-demo--call "t3" :op "done" :task "Find where changes are applied")))
   ;; ... and stops early, with open tasks: the extension reminds it
   '(:text "Investigation is done: `apply_changes' is the single place that writes." :stop-reason stop)
   ;; reminded: carries on
   (list :text "Right, continuing with the implementation."
         :tool-calls (list (pai-todo-demo--call "t4" :op "done" :task "Parse the --dry-run flag")))
   (list :text "`apply_changes' now only prints what it would do under --dry-run. The tests need the staging server, which is down."
         :tool-calls (list (pai-todo-demo--call "t5" :op "done" :task "Skip writes in dry-run mode")
                           (pai-todo-demo--call "t6" :op "block" :task "Run the deploy tests"
                                                :reason "the staging server is down")))
   '(:text "Implemented. The deploy tests are blocked until staging is back; the list shows it. (Blocked tasks do not trigger reminders.)"
     :stop-reason stop)))

(defun pai-todo-demo--type (buf text then)
  "Type TEXT into BUF's input one character at a time, then call THEN."
  (if (string-empty-p text)
      (funcall then)
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (goto-char (point-max))
        (insert (substring text 0 1)))
      (run-at-time pai-todo-demo-type-speed nil
                   #'pai-todo-demo--type buf (substring text 1) then))))

(defun pai-todo-demo--idle-p (buf)
  "Return non-nil when BUF has no run going and none about to start."
  (with-current-buffer buf
    (and (not pai--active) (null pai--steering-queue))))

(defun pai-todo-demo--run (buf steps)
  "Play STEPS in BUF: each waits until BUF is idle, pauses, then runs."
  (when (and steps (buffer-live-p buf))
    (if (not (pai-todo-demo--idle-p buf))
        (run-at-time 0.3 nil #'pai-todo-demo--run buf steps)
      ;; idle for the whole pause (a reminder may start a new run meanwhile)
      (run-at-time
       pai-todo-demo-pause nil
       (lambda ()
         (if (not (pai-todo-demo--idle-p buf))
             (pai-todo-demo--run buf steps)
           (funcall (car steps) buf (lambda () (pai-todo-demo--run buf (cdr steps))))))))))

(defun pai-todo-demo--send (text)
  "A step that types TEXT and sends it."
  (lambda (buf next)
    (pai-todo-demo--type buf text
                         (lambda ()
                           (when (buffer-live-p buf)
                             (with-current-buffer buf (pai-send))
                             (funcall next))))))

(defun pai-todo-demo--note (text)
  "A step that shows TEXT as a note."
  (lambda (buf next)
    (with-current-buffer buf (pai--render-note text))
    (funcall next)))

(defun pai-todo-demo ()
  "Play a scripted demo of the todo extension in its own buffer."
  (interactive)
  (let* ((dir (file-name-as-directory (make-temp-file "pai-todo-demo" t)))
         (buf (get-buffer-create "*pai: todo demo*")))
    (with-temp-file (expand-file-name "deploy.sh" dir)
      (insert "#!/bin/sh\n# a pretend deploy script for the todo demo\n"))
    (with-current-buffer buf
      (let ((inhibit-read-only t)) (erase-buffer))
      (setq default-directory dir)
      (pai--setup dir)
      (setq pai--model (pai-model "todo-demo"))
      ;; a fake conversation: nothing to observe, learn or index.  Private
      ;; also works with an older pai-memory (no /memory stop yet).
      (when (fboundp 'pai-memory-set-session-state)
        (ignore-errors (pai-memory-set-session-state pai--session :private t :stopped t)))
      (pai--render-note
       "Todo demo: a scripted model (no tokens); this session is private to memory. Watch the ☑ widget in the status bar."))
    (pop-to-buffer-same-window buf)
    (pai-todo-demo--script)
    (pai-todo-demo--run
     buf
     (list (pai-todo-demo--send "Add a --dry-run flag to deploy.sh")
           (pai-todo-demo--note "Now you: /todo shows the list (blocked tasks marked ⛔).")
           (pai-todo-demo--send "/todo")
           (pai-todo-demo--note "Staging is back: unblock the tests (names match fuzzily and complete, spaces and all).")
           (pai-todo-demo--send "/todo unblock deploy tests")
           (pai-todo-demo--send "/todo append Verify: Update the changelog")
           (pai-todo-demo--send "/todo done deploy tests")
           (pai-todo-demo--note "Last: /todo edit opens the list as an Org outline (C-c C-c saves, C-c C-k cancels).")
           (pai-todo-demo--send "/todo edit")
           (lambda (b next)
             (with-current-buffer b
               (pai--render-note "Demo done. This buffer is a normal pai chat on the scripted model: try /todo yourself."))
             (funcall next))))
    buf))

(provide 'pai-todo-demo)
;;; pai-todo-demo.el ends here
