;;; pai-example-extension.el --- Example pai extension -*- lexical-binding: t; -*-

;;; Commentary:

;; A small, self-contained example extension.  Copy it to
;; `~/.pai/extensions/' or `<project>/.pai/extensions/' to have it loaded
;; automatically by `pai', or evaluate this buffer after `(require 'pai)'.
;;
;; It demonstrates the common extension points: reacting to events,
;; registering a tool, registering a slash command, and — when an extension has
;; settings — contributing them to the settings screen (see policy below).

;;; Code:

(require 'pai)

(pai-register-extension
 (lambda (pi)
   ;; 1. React to a lifecycle event: report token throughput when a run ends.
   (pai-ext-on
    pi 'agent-end
    (lambda (event ctx)
      (let ((output 0))
        (dolist (m (plist-get event :messages))
          (when (pai-assistant-message-p m)
            (setq output (+ output (or (plist-get (plist-get m :usage) :output) 0)))))
        (when (> output 0)
          (pai-ext-ui-notify ctx (format "pai: %d output tokens this run" output))))))

   ;; 2. Register a tool the model can call.
   (pai-ext-register-tool
    pi (list :name "current_time"
             :description "Return the current date and time as a string."
             :parameters (pai-object-schema nil)
             :execute (lambda (_args _ctx _update done)
                        (funcall done (pai-tool-ok-result (current-time-string))))))

   ;; 3. Register a slash command that sends a canned prompt.
   (pai-ext-register-command
    pi "standup"
    :description "Ask the agent to summarize recent git activity"
    :handler (lambda (_args _ctx)
               (list :send "Summarize the last 5 git commits and today's changes.")))))

;; 4. Contribute settings to the settings screen (`/menu').
;;
;; POLICY: any extension that has user-facing settings MUST register them here
;; so every new session automatically surfaces and edits them.  Register under
;; `with-eval-after-load' so the screen stays a soft dependency — the extension
;; still works when the vui settings screen is not loaded.
;;
;; The tree is section -> subsection -> item.  Each item reads through `:get'
;; and writes through `:set', so the screen always reflects live settings.
(declare-function pai-settings-ui-register-section "pai-settings-ui")
(declare-function pai-settings-ui-register-subsection "pai-settings-ui")
(declare-function pai-settings-ui-register-item "pai-settings-ui")

(with-eval-after-load 'pai-settings-ui
  (pai-settings-ui-register-section 'example "Example Extension" 900)
  (pai-settings-ui-register-subsection 'example 'general "General" 10)
  (pai-settings-ui-register-item
   'example 'general
   :key :example-greeting :type 'string :label "Greeting"
   :doc "Text this example uses when it greets you"
   :get (lambda () (pai-settings-get :example-greeting))
   :set (lambda (v) (pai-settings-set :example-greeting v 'project)))
  (pai-settings-ui-register-item
   'example 'general
   :key :example-verbose :type 'boolean :label "Verbose"
   :doc "Emit extra notifications"
   :get (lambda () (pai-settings-get :example-verbose))
   :set (lambda (v) (pai-settings-set :example-verbose (if v t :false) 'project))))

(provide 'pai-example-extension)
;;; pai-example-extension.el ends here
