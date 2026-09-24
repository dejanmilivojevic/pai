;;; pai-hosted.el --- Opt-in hosted providers for pai -*- lexical-binding: t; -*-

;;; Commentary:

;; Copy this file to `~/.pai/extensions/' or `<project>/.pai/extensions/'
;; to enable these hosted services, or evaluate it after `(require 'pai)'.
;; Core pai does not load this file.  Remove entries you do not use.
;; Credentials are resolved only when needed; /model discovers the models
;; offered by each configured service.  No static catalog is installed.
;; For a service without model discovery, add an explicit :model fallback
;; to its configuration (or a :models list of IDs/model descriptors).

;;; Code:

(require 'pai)
(require 'pai-providers)
(require 'pai-auth)

(pai-register-extension
 (lambda (_pi)
   (dolist (config
            '((:id "openai" :api openai-completions
               :base-url "https://api.openai.com/v1" :env-key "OPENAI_API_KEY")
              (:id "anthropic" :api anthropic-messages
               :base-url "https://api.anthropic.com/v1" :env-key "ANTHROPIC_API_KEY")
              (:id "google" :api google-generative-ai
               :base-url "https://generativelanguage.googleapis.com/v1beta"
               :env-key ("GEMINI_API_KEY" "GOOGLE_API_KEY"))
              (:id "openrouter" :api openai-completions
               :base-url "https://openrouter.ai/api/v1" :env-key "OPENROUTER_API_KEY")
              (:id "groq" :api openai-completions
               :base-url "https://api.groq.com/openai/v1" :env-key "GROQ_API_KEY")
              (:id "deepseek" :api openai-completions
               :base-url "https://api.deepseek.com/v1" :env-key "DEEPSEEK_API_KEY")
              (:id "xai" :api openai-completions
               :base-url "https://api.x.ai/v1" :env-key "XAI_API_KEY")
              (:id "mistral" :api openai-completions
               :base-url "https://api.mistral.ai/v1" :env-key "MISTRAL_API_KEY")))
     (pai-register-provider-config config))
   (setf (alist-get "anthropic" pai-auth-oauth-handlers nil nil #'equal)
         #'pai-auth-oauth-anthropic))
 "hosted")

(provide 'pai-hosted)
;;; pai-hosted.el ends here
