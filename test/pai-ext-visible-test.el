;;; pai-ext-visible-test.el --- Disabled extensions stay out of sight -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pai)
(require 'pai-ext)
(require 'pai-settings-ui)

(defmacro pai-ext-visible-test--with-exts (dir specs &rest body)
  "Run BODY with extensions SPECS ((NAME . SOURCE) ...) in DIR, and empty settings.
Each NAME becomes DIR/NAME/NAME.el holding SOURCE."
  (declare (indent 2))
  `(let* ((,dir (file-name-as-directory (make-temp-file "pai-extvis" t)))
          (pai-settings--global nil) (pai-settings--project nil)
          (pai-directory (expand-file-name "home" ,dir)))
     (unwind-protect
         (progn
           (dolist (spec ,specs)
             (let ((d (expand-file-name (car spec) ,dir)))
               (make-directory d t)
               (with-temp-file (expand-file-name (concat (car spec) ".el") d)
                 (insert (cdr spec)))))
           ,@body)
       (delete-directory ,dir t))))

(defun pai-ext-visible-test--disable (&rest names)
  (setq pai-settings--global
        (list :extensions (apply #'append (mapcar (lambda (n) (list (intern (concat ":" n)) :false))
                                                  names)))))

(defconst pai-ext-visible-test--specs
  '(("ext-a" . "(require 'ext-b)\n(require 'cl-lib)\n(with-eval-after-load 'pai-settings-ui\n  (pai-settings-ui-register-section 'alpha \"Alpha\"))\n")
    ("ext-b" . "(require 'ext-c)\n(pai-settings-ui-register-section\n 'beta \"Beta\")\n")
    ("ext-c" . "(provide 'ext-c)\n")
    ("ext-d" . "(pai-settings-ui-register-section 'delta \"Delta\")\n")))

(ert-deftest pai-ext-visible-enabled-or-required ()
  (pai-ext-visible-test--with-exts dir pai-ext-visible-test--specs
    (let ((dirs (list dir)))
      (should (equal (pai-ext-visible-names dirs) '("ext-a" "ext-b" "ext-c" "ext-d")))
      ;; disabled and not required: hidden
      (pai-ext-visible-test--disable "ext-d")
      (should (equal (pai-ext-visible-names dirs) '("ext-a" "ext-b" "ext-c")))
      ;; disabled but required by an enabled one (also through a chain): shown
      (pai-ext-visible-test--disable "ext-b" "ext-c" "ext-d")
      (should (pai-ext-visible-p "ext-b" dirs))
      (should (pai-ext-visible-p "ext-c" dirs))
      (should-not (pai-ext-visible-p "ext-d" dirs))
      ;; once nothing enabled needs them, they are hidden too
      (pai-ext-visible-test--disable "ext-a" "ext-b" "ext-c" "ext-d")
      (should-not (pai-ext-visible-names dirs)))))

(ert-deftest pai-ext-section-owners ()
  (pai-ext-visible-test--with-exts dir pai-ext-visible-test--specs
    (let ((dirs (list dir)))
      (should (equal (pai-ext-section-owner 'alpha dirs) "ext-a"))
      (should (equal (pai-ext-section-owner 'beta dirs) "ext-b"))   ; call split over lines
      (should-not (pai-ext-section-owner 'session dirs)))))

(ert-deftest pai-ext-settings-sections-follow-visibility ()
  (pai-ext-visible-test--with-exts dir pai-ext-visible-test--specs
    (let ((pai-settings-ui--sections nil))
      (cl-letf (((symbol-function 'pai-extensions-default-dirs) (lambda () (list dir))))
        (pai-settings-ui-register-section 'session "Session" 10)
        (dolist (id '(alpha beta delta)) (pai-settings-ui-register-section id (symbol-name id)))
        (let ((ids (lambda () (mapcar #'pai-settings-ui-section-id (pai-settings-ui-visible-sections)))))
          (should (equal (funcall ids) '(session alpha beta delta)))
          ;; ext-b is disabled but ext-a needs it; ext-d is simply off
          (pai-ext-visible-test--disable "ext-b" "ext-d")
          (should (equal (funcall ids) '(session alpha beta))))))))

(ert-deftest pai-ext-scan-cache-follows-edits ()
  (pai-ext-visible-test--with-exts dir '(("ext-x" . "(require 'foo)\n"))
    (let ((file (expand-file-name "ext-x/ext-x.el" dir)))
      (should (equal (plist-get (pai-ext--scan-file file) :requires) '(foo)))
      (with-temp-file file (insert "(require 'bar)\n"))
      (set-file-times file (time-add nil 5))
      (should (equal (plist-get (pai-ext--scan-file file) :requires) '(bar))))))

(provide 'pai-ext-visible-test)
;;; pai-ext-visible-test.el ends here
