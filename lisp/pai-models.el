;;; pai-models.el --- Model catalog for pai -*- lexical-binding: t; -*-

;;; Commentary:

;; Model registry and helpers.  Providers and extensions register discovered
;; models or explicit fallbacks with `pai-register-model'.  A model is a plist
;; (see docs/ARCHITECTURE.md, section 1).

;;; Code:

(require 'cl-lib)
(require 'pai-core)
(require 'pai-config)

(defvar pai--models (make-hash-table :test 'equal)
  "Hash table mapping provider-qualified model keys to model plists.")

(defun pai-model-key (model)
  "Return MODEL's provider-qualified registry key."
  (concat (plist-get model :provider) "/" (plist-get model :id)))

(defun pai-register-model (model)
  "Register MODEL by its provider-qualified key and return MODEL."
  (puthash (pai-model-key model) model pai--models)
  model)

(defun pai-model (id)
  "Return the model for qualified ID or a unique bare ID.
Return nil when ID is unknown or a bare ID is ambiguous."
  (or (gethash id pai--models)
      (let (match ambiguous)
        (maphash (lambda (_key model)
                   (when (equal id (plist-get model :id))
                     (if match (setq ambiguous t) (setq match model))))
                 pai--models)
        (unless ambiguous match))))

(defun pai-models ()
  "Return a list of all registered model plists."
  (hash-table-values pai--models))

(defun pai-model-keys ()
  "Return every registered model's qualified key, sorted for pickers.
Keys sort by provider, then model id, so models from every provider are easy
to browse in a long completion list."
  (sort (mapcar #'pai-model-key (pai-models)) #'string<))

(cl-defun pai-make-model (&key id name api provider base-url (reasoning nil)
                               (input '("text")) (context-window 128000)
                               (max-tokens 8192) thinking-level-map cost headers)
  "Construct a model plist from keyword arguments."
  (append
   (list :id id :name (or name id) :api api :provider provider
         :base-url base-url :reasoning (if reasoning t :false)
         :input input :context-window context-window :max-tokens max-tokens
         :cost (or cost (list :input 0.0 :output 0.0 :cache-read 0.0 :cache-write 0.0)))
   (when thinking-level-map (list :thinking-level-map thinking-level-map))
   (when headers (list :headers headers))))

(defun pai-model-api (model) (plist-get model :api))
(defun pai-model-provider (model) (plist-get model :provider))
(defun pai-model-reasoning-p (model) (pai-truthy (plist-get model :reasoning)))


(defun pai-model-rates-nonzero-p (rates)
  "Return non-nil when RATES has any nonzero per-million price."
  (and rates
       (cl-some (lambda (k) (let ((v (plist-get rates k))) (and (numberp v) (> v 0))))
                '(:input :output :cache-read :cache-write))))

(defvar pai-model-rates-functions nil
  "Abnormal hook: functions of MODEL returning a rates plist or nil.
Consulted, in order, when MODEL has no price of its own.  A rates plist has
per-million-token :input :output :cache-read :cache-write.")

(defun pai-model-rates (model)
  "Return MODEL's per-million-token rates, or nil when its price is unknown.
MODEL's own :cost wins; otherwise `pai-model-rates-functions' (e.g. the
models.dev catalog) are asked."
  (let ((own (plist-get model :cost)))
    (if (pai-model-rates-nonzero-p own)
        own
      (run-hook-with-args-until-success 'pai-model-rates-functions model))))

(defun pai-model-priced-p (model)
  "Return non-nil when MODEL's price is known."
  (and model (pai-model-rates model) t))

(defun pai-usage-cost (usage model)
  "Return the dollar cost of USAGE for MODEL.
A cost the provider reported for USAGE (:reported-cost, e.g. OpenRouter's
billed amount) wins; otherwise USAGE is priced with `pai-model-rates'.
Return 0.0 when neither is known -- see `pai-model-priced-p'."
  (let ((reported (plist-get usage :reported-cost)))
    (if (numberp reported)
        (float reported)
      (let* ((c (or (and model (pai-model-rates model)) '()))
             (g (lambda (k) (or (plist-get c k) 0.0))))
        (/ (+ (* (funcall g :input) (or (plist-get usage :input) 0))
              (* (funcall g :output) (or (plist-get usage :output) 0))
              (* (funcall g :cache-read) (or (plist-get usage :cache-read) 0))
              (* (funcall g :cache-write) (or (plist-get usage :cache-write) 0)))
           1000000.0)))))

(provide 'pai-models)
;;; pai-models.el ends here
