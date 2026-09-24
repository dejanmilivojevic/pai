;;; pai.el --- Pi agent harness for Emacs -*- lexical-binding: t; -*-

;; Author: pai contributors
;; Version: 0.1.0
;; Keywords: ai, tools, convenience
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/earendil-works/pi

;;; Commentary:

;; pai is an Emacs Lisp port of the `pi' agent harness
;; (https://github.com/earendil-works/pi).  It is a self-extensible coding
;; agent that runs entirely inside Emacs and uses Emacs itself as its operating
;; system for tool calling: shell, files, project search, and — uniquely — live
;; Emacs Lisp evaluation and buffer inspection.
;;
;; Layers (see docs/ARCHITECTURE.md):
;;   pai-core       unified message/content/tool model + JSON
;;   pai-http       streaming SSE transport (curl)
;;   pai-provider   provider registry + dispatch
;;   pai-provider-* Anthropic, OpenAI, Gemini providers
;;   pai-agent      the event-driven agent loop
;;   pai-tools*     tool registry + built-in Emacs-native tools
;;   pai-prompt     system-prompt assembly
;;   pai-skills     markdown skills discovery
;;   pai-commands   slash commands
;;   pai-ext        extension API, event bus, loader
;;   pai-session    JSONL session persistence
;;   pai-ui         the chat buffer front end
;;
;; Entry points: M-x `pai' (open the chat) and M-x `pai-new-session'.

;;; Code:

;; Put the bundled vui.el (used by the settings screen) on `load-path' so a
;; single `lisp/' entry is enough to `require' pai.
(let ((vendor (expand-file-name
               "../vendor/vui"
               (file-name-directory (or load-file-name buffer-file-name
                                        default-directory)))))
  (when (file-directory-p vendor)
    (add-to-list 'load-path vendor)))

(require 'pai-core)
(require 'pai-config)
(require 'pai-models)
(require 'pai-model-resolver)
(require 'pai-http)
(require 'pai-stream)
(require 'pai-settings)
(require 'pai-provider)
(require 'pai-provider-anthropic)
(require 'pai-provider-openai)
(require 'pai-provider-gemini)
(require 'pai-agent)
(require 'pai-tools)
(require 'pai-tools-builtin)
(require 'pai-prompt)
(require 'pai-skills)
(require 'pai-markdown)
(require 'pai-compaction)
(require 'pai-export)
(require 'pai-prompts)
(require 'pai-diff)
(require 'pai-session)
(require 'pai-trust)
(require 'pai-auth)

;;;###autoload
(defun pai-oneshot (prompt &optional model-id cwd)
  "Run PROMPT once headlessly and return the assistant's final text.
Uses MODEL-ID (or the persisted model) in CWD (or `default-directory').
Blocks until the run completes; intended for scripts and batch use."
  (let ((directory (or cwd default-directory)))
    (with-temp-buffer
      (setq default-directory (file-name-as-directory (expand-file-name directory)))
      (pai-ext-initialize-instance)
      (pai-settings-load default-directory)
      (pai-models-load-custom)
      (pai-load-extensions
       (append (list (expand-file-name "extensions" pai-directory))
               (when (pai-trust-trusted-p default-directory)
                 (list (expand-file-name ".pai/extensions" default-directory)))))
      (let* (
         (id (or model-id (pai-settings-get :model) pai-default-model))
         (_discovery (unless (pai-model id) (pai-models-refresh)))
         (model (or (pai-model id)
                    (and (null id) (car (pai-models)))
                    (user-error "No model configured; use M-x pai-add-provider, then /model")))
         (sys (pai-system-message
               (pai-build-system-prompt :cwd default-directory :tools (pai-tools-all))))
         (result nil) (done nil))
    (pai-agent-run (list (pai-user-message prompt))
                   (pai-context (list sys) (pai-tools-all))
                   (list :model model :tool-execution 'sequential)
                   (lambda (_ev) nil)
                   (lambda (msgs) (setq result msgs done t)))
    (let ((deadline (+ (float-time) 600)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output nil 0.05)))
    (let ((last (seq-find #'pai-assistant-message-p (reverse result))))
      (and last (pai-content-text (pai-message-content last))))))))

(require 'pai-ext)
(require 'pai-ui)
(require 'pai-settings-ui)

(defconst pai-version "0.1.0" "Version of the pai package.")

;; Baseline core-file mtimes so `/reload' can detect edits made after startup.
(pai-reload-snapshot)

(provide 'pai)
;;; pai.el ends here
