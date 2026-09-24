;;; pai-tools-test.el --- Tests for built-in tools -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai-core)
(require 'pai-tools)
(require 'pai-tools-builtin)

(defun pai-tools-test--run (name args &optional cwd)
  "Run tool NAME with ARGS (and optional CWD) synchronously; return the result.
Waits for asynchronous tools (bash) to finish."
  (let* ((tool (pai-tool-get name))
         (ctx (list :cwd (or cwd default-directory) :tool-call-id "t"))
         (result nil) (done nil))
    (funcall (plist-get tool :execute) args ctx nil
             (lambda (r) (setq result r done t)))
    (let ((deadline (+ (float-time) 15)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output nil 0.05)))
    result))

(defun pai-tools-test--text (result)
  (pai-content-text (plist-get result :content)))

(defun pai-tools-test--error-p (result)
  (pai-truthy (plist-get result :is-error)))

(defmacro pai-tools-test--with-tmpdir (var &rest body)
  "Bind VAR to a fresh temp directory, run BODY, then delete it."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "pai-tool-test" t))))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

;;;; write + read

(ert-deftest pai-tools-write-then-read ()
  (pai-tools-test--with-tmpdir dir
    (let ((w (pai-tools-test--run "write" '(:path "sub/hello.txt" :content "line1\nline2\n") dir)))
      (should-not (pai-tools-test--error-p w))
      (should (file-exists-p (expand-file-name "sub/hello.txt" dir))))
    (let ((r (pai-tools-test--run "read" '(:path "sub/hello.txt") dir)))
      (should (string-match-p "line1" (pai-tools-test--text r)))
      (should (string-match-p "line2" (pai-tools-test--text r))))))

(ert-deftest pai-tools-read-offset-limit ()
  (pai-tools-test--with-tmpdir dir
    (pai-tools-test--run "write" '(:path "f.txt" :content "a\nb\nc\nd\ne\n") dir)
    (let ((r (pai-tools-test--run "read" '(:path "f.txt" :offset 2 :limit 2) dir)))
      (should (string-match-p "^b\nc" (pai-tools-test--text r)))
      (should-not (string-match-p "^a" (pai-tools-test--text r))))))

(ert-deftest pai-tools-read-missing ()
  (pai-tools-test--with-tmpdir dir
    (should (pai-tools-test--error-p (pai-tools-test--run "read" '(:path "nope.txt") dir)))))

;;;; edit

(ert-deftest pai-tools-edit-replaces ()
  (pai-tools-test--with-tmpdir dir
    (pai-tools-test--run "write" '(:path "e.txt" :content "foo bar baz") dir)
    (let ((r (pai-tools-test--run "edit"
                                  '(:path "e.txt" :edits ((:oldText "bar" :newText "QUX"))) dir)))
      (should-not (pai-tools-test--error-p r))
      (should (equal (with-temp-buffer (insert-file-contents (expand-file-name "e.txt" dir))
                                       (buffer-string))
                     "foo QUX baz")))))

(ert-deftest pai-tools-edit-ambiguous-errors ()
  (pai-tools-test--with-tmpdir dir
    (pai-tools-test--run "write" '(:path "e.txt" :content "x x x") dir)
    (let ((r (pai-tools-test--run "edit" '(:path "e.txt" :edits ((:oldText "x" :newText "y"))) dir)))
      (should (pai-tools-test--error-p r))
      (should (string-match-p "ambiguous" (pai-tools-test--text r))))))

(ert-deftest pai-tools-edit-not-found-errors ()
  (pai-tools-test--with-tmpdir dir
    (pai-tools-test--run "write" '(:path "e.txt" :content "abc") dir)
    (let ((r (pai-tools-test--run "edit" '(:path "e.txt" :edits ((:oldText "zzz" :newText "y"))) dir)))
      (should (pai-tools-test--error-p r))
      (should (string-match-p "not found" (pai-tools-test--text r))))))

;;;; ls / find / grep

(ert-deftest pai-tools-ls ()
  (pai-tools-test--with-tmpdir dir
    (pai-tools-test--run "write" '(:path "a.txt" :content "x") dir)
    (make-directory (expand-file-name "adir" dir))
    (let ((r (pai-tools-test--run "ls" '(:path ".") dir)))
      (should (string-match-p "a\\.txt" (pai-tools-test--text r)))
      (should (string-match-p "adir/" (pai-tools-test--text r))))))

(ert-deftest pai-tools-find ()
  (pai-tools-test--with-tmpdir dir
    (pai-tools-test--run "write" '(:path "src/main.el" :content "x") dir)
    (pai-tools-test--run "write" '(:path "src/other.txt" :content "x") dir)
    (let ((r (pai-tools-test--run "find" '(:pattern "\\.el$") dir)))
      (should (string-match-p "main\\.el" (pai-tools-test--text r)))
      (should-not (string-match-p "other\\.txt" (pai-tools-test--text r))))))

(ert-deftest pai-tools-grep ()
  (pai-tools-test--with-tmpdir dir
    (pai-tools-test--run "write" '(:path "f1.txt" :content "hello world\nsecond line") dir)
    (pai-tools-test--run "write" '(:path "f2.txt" :content "nothing here") dir)
    (let ((r (pai-tools-test--run "grep" '(:pattern "world") dir)))
      (should-not (pai-tools-test--error-p r))
      (should (string-match-p "hello world" (pai-tools-test--text r))))))

;;;; bash (async)

(ert-deftest pai-tools-bash-echo ()
  (pai-tools-test--with-tmpdir dir
    (let ((r (pai-tools-test--run "bash" '(:command "echo hi from bash") dir)))
      (should-not (pai-tools-test--error-p r))
      (should (string-match-p "hi from bash" (pai-tools-test--text r))))))

(ert-deftest pai-tools-bash-nonzero-exit-is-error ()
  (pai-tools-test--with-tmpdir dir
    (let ((r (pai-tools-test--run "bash" '(:command "exit 3") dir)))
      (should (pai-tools-test--error-p r))
      (should (string-match-p "code 3" (pai-tools-test--text r))))))

(ert-deftest pai-tools-bash-runs-in-cwd ()
  (pai-tools-test--with-tmpdir dir
    (pai-tools-test--run "write" '(:path "marker.txt" :content "x") dir)
    (let ((r (pai-tools-test--run "bash" '(:command "ls") dir)))
      (should (string-match-p "marker\\.txt" (pai-tools-test--text r))))))

;;;; elisp_eval and buffer tools (Emacs-native)

(ert-deftest pai-tools-elisp-eval-value ()
  (let ((r (pai-tools-test--run "elisp_eval" '(:form "(+ 1 2 3)"))))
    (should-not (pai-tools-test--error-p r))
    (should (string-match-p "=> 6" (pai-tools-test--text r)))))

(ert-deftest pai-tools-elisp-eval-output ()
  (let ((r (pai-tools-test--run "elisp_eval" '(:form "(princ \"printed!\")"))))
    (should (string-match-p "printed!" (pai-tools-test--text r)))))

(ert-deftest pai-tools-elisp-eval-error ()
  (let ((r (pai-tools-test--run "elisp_eval" '(:form "(error \"boom\")"))))
    (should (pai-tools-test--error-p r))
    (should (string-match-p "boom" (pai-tools-test--text r)))))

(ert-deftest pai-tools-elisp-eval-multiple-forms ()
  (let ((r (pai-tools-test--run "elisp_eval" '(:form "(setq pai-test-x 10) (* pai-test-x 2)"))))
    (should (string-match-p "=> 20" (pai-tools-test--text r)))))

(ert-deftest pai-tools-list-and-read-buffer ()
  (let ((buf (generate-new-buffer "pai-test-buffer")))
    (unwind-protect
        (progn
          (with-current-buffer buf (insert "buffer contents here"))
          (let ((lr (pai-tools-test--run "list_buffers" nil)))
            (should (string-match-p "pai-test-buffer" (pai-tools-test--text lr))))
          (let ((rr (pai-tools-test--run "read_buffer" '(:name "pai-test-buffer"))))
            (should (string-match-p "buffer contents here" (pai-tools-test--text rr)))))
      (kill-buffer buf))))

;;;; registry

(ert-deftest pai-tools-builtins-registered ()
  (dolist (name pai-builtin-tool-names)
    (should (pai-tool-get name)))
  (should (= (length (pai-builtin-tools)) (length pai-builtin-tool-names))))

(ert-deftest pai-tools-declaration-shape ()
  (let ((decl (pai-tool-declaration (pai-tool-get "bash"))))
    (should (equal (plist-get decl :name) "bash"))
    (should (plist-get decl :description))
    (should (equal (plist-get (plist-get decl :parameters) :type) "object"))))

(provide 'pai-tools-test)
;;; pai-tools-test.el ends here
