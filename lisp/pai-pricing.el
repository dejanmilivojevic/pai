;;; pai-pricing.el --- Model prices from the models.dev catalog -*- lexical-binding: t; -*-

;;; Commentary:

;; Many models reach pai without prices: Anthropic's and OpenAI's model lists
;; carry none, so subscription (OAuth) and discovered models cost "$0".  Like
;; oh-my-pi, pai fills the gap from the public models.dev catalog: prices per
;; million tokens for thousands of provider/model pairs.
;;
;; The catalog (~5 MB) is downloaded in the background with curl at most once
;; a day and pruned to a small cache, ~/.pai/cache/prices.json, mapping
;; "PROVIDER/MODEL" to (:input :output :cache-read :cache-write).  Only
;; entries with a nonzero price are kept.
;;
;; `pai-model-rates' (pai-models) consults `pai-pricing-rates' only when a
;; model has no price of its own, so explicit prices -- a provider's
;; :cost, OpenRouter's discovered pricing -- always win.  Lookup is by the
;; model's exact provider id and model id (then without a trailing -YYYYMMDD
;; date); a custom provider (e.g. a local server) only gets a price when
;; models.dev lists that same provider id and model.
;;
;; Set `pai-pricing-url' to nil to never download.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-config)
(require 'pai-models)

(defgroup pai-pricing nil
  "Model prices from the models.dev catalog."
  :group 'pai)

(defcustom pai-pricing-url "https://models.dev/api.json"
  "Where the model price catalog is downloaded from; nil never downloads."
  :type '(choice (const :tag "Never download" nil) string)
  :group 'pai-pricing)

(defcustom pai-pricing-max-age (* 24 60 60)
  "Seconds before the cached price catalog is refreshed."
  :type 'integer
  :group 'pai-pricing)

(defvar pai-pricing-updated-hook nil
  "Normal hook run after a fresh price catalog was loaded.")

(defvar pai-pricing--table nil
  "Hash table \"PROVIDER/MODEL\" -> rates plist, or nil before loading.")

(defvar pai-pricing--process nil
  "The running catalog download, or nil.")

(defun pai-pricing-cache-file ()
  "Return the path of the pruned price cache."
  (expand-file-name "prices.json" (pai-state-directory "cache")))

;;;; Catalog -> table

(defun pai-pricing--rate (cost key)
  "Return COST's KEY as a float (models.dev prices are per million tokens)."
  (let ((v (and (hash-table-p cost) (gethash key cost))))
    (if (numberp v) (float v) 0.0)))

(defun pai-pricing-prune (catalog)
  "Return a hash table \"PROVIDER/MODEL\" -> rates from models.dev CATALOG.
CATALOG is the parsed api.json (hash tables).  Entries without any nonzero
price are dropped."
  (let ((table (make-hash-table :test 'equal)))
    (maphash
     (lambda (provider pdata)
       (let ((models (and (hash-table-p pdata) (gethash "models" pdata))))
         (when (hash-table-p models)
           (maphash
            (lambda (id mdata)
              (let* ((cost (and (hash-table-p mdata) (gethash "cost" mdata)))
                     (rates (list :input (pai-pricing--rate cost "input")
                                  :output (pai-pricing--rate cost "output")
                                  :cache-read (pai-pricing--rate cost "cache_read")
                                  :cache-write (pai-pricing--rate cost "cache_write"))))
                (when (pai-model-rates-nonzero-p rates)
                  (puthash (concat provider "/" id) rates table))))
            models))))
     catalog)
    table))

(defun pai-pricing--write-cache (table)
  "Write TABLE to the cache file atomically."
  (let ((obj (make-hash-table :test 'equal))
        (file (pai-pricing-cache-file)))
    (maphash (lambda (k r)
               (puthash k (vector (plist-get r :input) (plist-get r :output)
                                  (plist-get r :cache-read) (plist-get r :cache-write))
                        obj))
             table)
    (let ((tmp (make-temp-file (expand-file-name ".prices-" (file-name-directory file))))
          (coding-system-for-write 'utf-8))
      (with-temp-file tmp (insert (json-serialize obj)))
      (rename-file tmp file t))))

(defun pai-pricing--read-cache ()
  "Return the table stored in the cache file, or nil."
  (let ((file (pai-pricing-cache-file)))
    (when (file-readable-p file)
      (condition-case nil
          (let ((obj (with-temp-buffer
                       (insert-file-contents file)
                       (json-parse-buffer :object-type 'hash-table)))
                (table (make-hash-table :test 'equal)))
            (maphash (lambda (k v)
                       (when (and (vectorp v) (= (length v) 4))
                         (puthash k (list :input (aref v 0) :output (aref v 1)
                                          :cache-read (aref v 2) :cache-write (aref v 3))
                                  table)))
                     obj)
            table)
        (error nil)))))

;;;; Lookup

(defun pai-pricing-load ()
  "Load the cached table if not loaded yet; return it (possibly empty)."
  (or pai-pricing--table
      (setq pai-pricing--table (or (pai-pricing--read-cache)
                                   (make-hash-table :test 'equal)))))

(defun pai-pricing-rates (model)
  "Return catalog rates for MODEL (a plist with :provider and :id), or nil."
  (let ((table (pai-pricing-load))
        (provider (plist-get model :provider))
        (id (plist-get model :id)))
    (when (and (stringp provider) (stringp id))
      (or (gethash (concat provider "/" id) table)
          (and (string-match "\\`\\(.+\\)-[0-9]\\{8\\}\\'" id)
               (gethash (concat provider "/" (match-string 1 id)) table))))))

(add-hook 'pai-model-rates-functions #'pai-pricing-rates)

;;;; Status

(defun pai-pricing-cache-age ()
  "Return the cache's age in seconds, or nil when there is no cache."
  (let ((file (pai-pricing-cache-file)))
    (and (file-exists-p file)
         (float-time (time-subtract nil (file-attribute-modification-time
                                         (file-attributes file)))))))

(defun pai-pricing-downloading-p ()
  "Return non-nil while a catalog download runs."
  (process-live-p pai-pricing--process))

;;;; Refresh

(defun pai-pricing--stale-p ()
  "Return non-nil when the cache is missing or older than `pai-pricing-max-age'."
  (let ((file (pai-pricing-cache-file)))
    (or (not (file-exists-p file))
        (> (float-time (time-subtract nil (file-attribute-modification-time
                                           (file-attributes file))))
           pai-pricing-max-age))))

(defun pai-pricing--install-download (file)
  "Parse downloaded catalog FILE, cache and install its prices; return the table."
  (let* ((catalog (with-temp-buffer
                    (set-buffer-multibyte t)
                    (let ((coding-system-for-read 'utf-8)) (insert-file-contents file))
                    (json-parse-buffer :object-type 'hash-table)))
         (table (pai-pricing-prune catalog)))
    (when (> (hash-table-count table) 0)
      (pai-pricing--write-cache table)
      (setq pai-pricing--table table)
      (run-hooks 'pai-pricing-updated-hook))
    table))

(defun pai-pricing-refresh (&optional force)
  "Download the price catalog in the background when the cache is stale.
FORCE downloads regardless of age.  Never blocks; errors are reported in
*Messages* and the old cache stays in use.  Return the process or nil."
  (pai-pricing-load)
  (when (and pai-pricing-url
             (not (process-live-p pai-pricing--process))
             (or force (pai-pricing--stale-p))
             (executable-find pai-curl-program))
    (let ((tmp (make-temp-file "pai-models-dev" nil ".json")))
      (setq pai-pricing--process
            (make-process
             :name "pai-pricing"
             :command (list pai-curl-program "-sS" "-L" "--fail" "--max-time" "60"
                            "-o" tmp pai-pricing-url)
             :noquery t
             :buffer nil
             :sentinel
             (lambda (proc _event)
               (unless (process-live-p proc)
                 (unwind-protect
                     (if (not (zerop (process-exit-status proc)))
                         (message "pai: price catalog download failed (curl exit %d)"
                                  (process-exit-status proc))
                       (condition-case err
                           (pai-pricing--install-download tmp)
                         (error (message "pai: price catalog unreadable: %s"
                                         (error-message-string err)))))
                   (ignore-errors (delete-file tmp))
                   (setq pai-pricing--process nil)))))))))

(provide 'pai-pricing)
;;; pai-pricing.el ends here
