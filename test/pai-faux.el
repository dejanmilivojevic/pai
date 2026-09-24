;;; pai-faux.el --- Faux in-process provider for tests -*- lexical-binding: t; -*-

;;; Commentary:

;; A deterministic, network-free provider used by the test suite and demos.
;; It consumes scripted response specs from `pai-faux-responses' and emits the
;; corresponding unified events synchronously.
;;
;; A response spec is a plist:
;;   (:text STRING            ; assistant text, streamed in chunks
;;    :thinking STRING        ; optional reasoning block
;;    :tool-calls (SPEC...)   ; each (:id ID :name NAME :arguments PLIST)
;;    :stop-reason SYMBOL      ; defaults to tool-use when tool-calls present, else stop
;;    :usage USAGE
;;    :error STRING)          ; when set, emit an error stream instead

;;; Code:

(require 'pai-core)
(require 'pai-models)
(require 'pai-provider)
(require 'pai-stream)

(defvar pai-faux-responses nil
  "Queue of response specs; each stream call consumes the head.")

(defvar pai-faux-default-response '(:text "ok" :stop-reason stop)
  "Response spec used when `pai-faux-responses' is empty.")

(defvar pai-faux-last-context nil
  "The CONTEXT plist passed to the most recent faux stream call.")

(defvar pai-faux-last-options nil
  "The OPTIONS plist passed to the most recent faux stream call.")

(defun pai-faux-reset ()
  "Clear the faux response queue and recorded call state."
  (setq pai-faux-responses nil
        pai-faux-last-context nil
        pai-faux-last-options nil))

(defun pai-faux-push (&rest specs)
  "Append response SPECS to the faux queue."
  (setq pai-faux-responses (append pai-faux-responses specs)))

(defun pai-faux--split (text)
  "Split TEXT into a list of small chunks to mimic streaming."
  (if (string-empty-p text)
      (list "")
    (let ((chunks '()) (i 0) (n (length text)) (size 8))
      (while (< i n)
        (push (substring text i (min n (+ i size))) chunks)
        (setq i (+ i size)))
      (nreverse chunks))))

(defun pai-faux-stream (model context options emit)
  "Faux implementation of the provider stream contract."
  (setq pai-faux-last-context context
        pai-faux-last-options options)
  (let ((acc (pai-accum-new model))
        (spec (if pai-faux-responses (pop pai-faux-responses) pai-faux-default-response)))
    (pai-accum-start acc emit)
    (if (plist-get spec :error)
        (pai-accum-error acc emit 'error (plist-get spec :error))
      (progn
        (when-let ((th (plist-get spec :thinking)))
          (let ((idx (pai-accum-thinking-start acc emit)))
            (pai-accum-thinking-delta acc emit idx th)
            (pai-accum-thinking-end acc emit idx)))
        (when-let ((text (plist-get spec :text)))
          (let ((idx (pai-accum-text-start acc emit)))
            (dolist (chunk (pai-faux--split text))
              (pai-accum-text-delta acc emit idx chunk))
            (pai-accum-text-end acc emit idx)))
        (dolist (tc (plist-get spec :tool-calls))
          (let ((idx (pai-accum-toolcall-start acc emit (plist-get tc :id) (plist-get tc :name)))
                (args (plist-get tc :arguments)))
            (when args (pai-accum-toolcall-delta acc emit idx (pai-json-encode args)))
            (pai-accum-toolcall-end acc emit idx args)))
        (pai-accum-set-usage acc (or (plist-get spec :usage)
                                     (pai-usage :input 10 :output 5 :total-tokens 15)))
        (pai-accum-done acc emit (or (plist-get spec :stop-reason)
                                     (if (plist-get spec :tool-calls) 'tool-use 'stop)))))
    nil))

(defun pai-faux-register ()
  "Register the faux provider and its model."
  (pai-register-provider (list :id "faux" :stream #'pai-faux-stream))
  (pai-register-model (pai-make-model :id "faux" :name "Faux" :api 'faux
                                      :provider "faux" :base-url "faux://local")))

(pai-faux-register)

(provide 'pai-faux)
;;; pai-faux.el ends here
