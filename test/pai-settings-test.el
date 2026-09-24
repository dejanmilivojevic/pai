;;; pai-settings-test.el --- Tests for pai-settings -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai-settings)

(defmacro pai-settings-test--sandbox (dir &rest body)
  (declare (indent 1))
  `(let* ((,dir (file-name-as-directory (make-temp-file "pai-set" t)))
          (pai-directory (expand-file-name "state" ,dir))
          (pai-settings--global nil)
          (pai-settings--project nil)
          (pai-settings--project-dir nil))
     (unwind-protect (progn ,@body) (delete-directory ,dir t))))

(ert-deftest pai-settings-defaults-present ()
  (pai-settings-test--sandbox dir
    (pai-settings-load nil)
    (should (equal (pai-settings-get :thinking-level) "off"))
    (should (equal (pai-settings-get :tool-execution) "parallel"))
    (should (eq (pai-settings-get :auto-compact) t))))

(ert-deftest pai-settings-global-set-and-reload ()
  (pai-settings-test--sandbox dir
    (pai-settings-load nil)
    (pai-settings-set :model "gpt-4o" 'global)
    (should (file-exists-p (pai-settings-global-file)))
    ;; reload from disk
    (setq pai-settings--global nil)
    (pai-settings-load nil)
    (should (equal (pai-settings-get :model) "gpt-4o"))))

(ert-deftest pai-settings-set-never-drops-other-keys ()
  "Setting one key with stale or empty settings in memory keeps the rest on disk.
Settings are per pai buffer; code running elsewhere (the minibuffer) sees
the empty default and once wiped settings.json this way."
  (pai-settings-test--sandbox dir
    (let ((proj (expand-file-name "proj/" dir)))
      (make-directory proj t)
      (pai-settings-load proj)
      (pai-settings-set :custom-providers '((:id "local" :base-url "http://h:8080/v1")) 'global)
      (pai-settings-set :auto-compact t 'global)
      (pai-settings-set :model "local/q" 'project)
      ;; memory emptied, as in a buffer that never loaded the settings
      (let ((pai-settings--global nil) (pai-settings--project nil))
        (pai-settings-set :preview-resume t 'global)
        (pai-settings-set :thinking-level "low" 'project))
      (let ((global (pai-settings--read (pai-settings-global-file)))
            (project (pai-settings--read (pai-settings-project-file proj))))
        (should (equal (plist-get (car (plist-get global :custom-providers)) :id) "local"))
        (should (eq (plist-get global :auto-compact) t))
        (should (eq (plist-get global :preview-resume) t))
        (should (equal (plist-get project :model) "local/q"))
        (should (equal (plist-get project :thinking-level) "low"))))))

(ert-deftest pai-settings-load-lazily-where-never-loaded ()
  "A buffer that never loaded settings reads them from disk, so a nested
value it derives and saves keeps the other entries."
  (pai-settings-test--sandbox dir
    (pai-settings-load nil)
    (pai-settings-set :extensions '(:pai-a :false :pai-b :false))
    (pai-settings-set :custom-providers '((:id "local")))
    (let ((pai-settings--global nil))      ; e.g. the minibuffer
      (should (equal (plist-get (car (pai-settings-get :custom-providers)) :id) "local"))
      ;; derive the map from what is there, change one key, save
      (let ((map (copy-sequence (pai-settings-scope-value :extensions 'global))))
        (pai-settings-set :extensions (plist-put map :pai-c :false))))
    (let ((disk (pai-settings--read (pai-settings-global-file))))
      (should (equal (plist-get disk :extensions) '(:pai-a :false :pai-b :false :pai-c :false)))
      (should (plist-get disk :custom-providers)))
    ;; a copy loaded lazily follows later changes made by others
    (let ((pai-settings--global nil) (pai-settings--lazy nil))
      (pai-settings-get :model)
      (let ((other (pai-settings--read (pai-settings-global-file))))
        (pai-settings--write (pai-settings-global-file) (plist-put other :model "from-elsewhere"))
        (set-file-times (pai-settings-global-file) (time-add nil 10)))
      (should (equal (pai-settings-get :model) "from-elsewhere")))
    ;; settings that are set (tests inject them) are never replaced
    (let ((pai-settings--global '(:model "injected")))
      (should (equal (pai-settings-get :model) "injected"))
      (should-not (pai-settings-get :custom-providers)))))

(ert-deftest pai-settings-backups-and-restore ()
  (pai-settings-test--sandbox dir
    (let ((file (pai-settings-global-file))
          (pai-settings-backups 3))
      (pai-settings-load nil)
      (pai-settings-set :model "one")             ; new file: nothing to back up
      (should-not (pai-settings-backups-of file))
      (pai-settings-set :model "two")
      (should (= (length (pai-settings-backups-of file)) 1))
      (should (equal (plist-get (pai-settings--read (car (pai-settings-backups-of file))) :model) "one"))
      (pai-settings-set :model "two")             ; unchanged: no new backup
      (should (= (length (pai-settings-backups-of file)) 1))
      (dolist (m '("three" "four" "five")) (pai-settings-set :model m))
      ;; only the newest 3 are kept
      (should (equal (mapcar (lambda (b) (plist-get (pai-settings--read b) :model))
                             (pai-settings-backups-of file))
                     '("four" "three" "two")))
      ;; restore puts one back and backs up what it replaced
      (pai-settings-restore-backup file (nth 2 (pai-settings-backups-of file)))
      (should (equal (plist-get (pai-settings--read file) :model) "two"))
      (should (equal (plist-get (pai-settings--read (car (pai-settings-backups-of file))) :model)
                     "five")))))

(ert-deftest pai-settings-project-overrides-global ()
  (pai-settings-test--sandbox dir
    (let ((proj (expand-file-name "proj" dir)))
      (make-directory proj)
      (pai-settings-load proj)
      (pai-settings-set :model "global-model" 'global)
      (pai-settings-set :model "project-model" 'project)
      (setq pai-settings--global nil pai-settings--project nil)
      (pai-settings-load proj)
      (should (equal (pai-settings-get :model) "project-model"))
      (should (file-exists-p (pai-settings-project-file proj))))))

(ert-deftest pai-settings-coerce-types ()
  (should (eq (pai-settings--coerce :auto-compact "false") :false))
  (should (eq (pai-settings--coerce :auto-compact "true") t))
  (should (= (pai-settings--coerce :compact-threshold "0.7") 0.7))
  (should (equal (pai-settings--coerce :model "claude") "claude")))

(ert-deftest pai-settings-command-set-get ()
  (pai-settings-test--sandbox dir
    (let ((proj (expand-file-name "proj" dir)))
      (make-directory proj)
      (pai-settings-load proj)
      (let ((r (pai-settings-command "set max-tokens 1234" nil)))
        (should (string-match-p "max-tokens" (plist-get r :message))))
      (should (= (pai-settings-get :max-tokens) 1234))
      (let ((r (pai-settings-command "get max-tokens" nil)))
        (should (string-match-p "1234" (plist-get r :message)))))))

(ert-deftest pai-settings-command-describe ()
  (pai-settings-test--sandbox dir
    (pai-settings-load nil)
    (let ((r (pai-settings-command "" nil)))
      (should (string-match-p "Settings" (plist-get r :message))))))

(ert-deftest pai-settings-registered-command ()
  (should (pai-command-get "settings")))

(provide 'pai-settings-test)
;;; pai-settings-test.el ends here
