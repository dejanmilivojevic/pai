;;; pai-prompts-test.el --- Tests for pai-prompts -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai-prompts)

(defmacro pai-prompts-test--sandbox (dir &rest body)
  "Bind DIR to a fresh temp prompts directory; run BODY; clean up."
  (declare (indent 1))
  `(let* ((,dir (file-name-as-directory (make-temp-file "pai-prompts" t))))
     (unwind-protect (progn ,@body) (delete-directory ,dir t))))

(defun pai-prompts-test--write (dir name content)
  "Write CONTENT to NAME under DIR and return its full path."
  (let ((file (expand-file-name name dir)))
    (with-temp-file file (insert content))
    file))

;;;; from-file / discovery

(ert-deftest pai-prompts-from-file-frontmatter ()
  (pai-prompts-test--sandbox dir
    (let* ((file (pai-prompts-test--write
                  dir "raw.md"
                  "---\nname: review\ndescription: Review the code\n---\nPlease review $ARGUMENTS.\n"))
           (p (pai-prompt-from-file file)))
      (should (equal (plist-get p :name) "review"))
      (should (equal (plist-get p :description) "Review the code"))
      (should (equal (plist-get p :path) (expand-file-name file)))
      (should (equal (plist-get p :body) "Please review $ARGUMENTS.\n")))))

(ert-deftest pai-prompts-from-file-no-frontmatter ()
  (pai-prompts-test--sandbox dir
    (let* ((file (pai-prompts-test--write
                  dir "explain.md"
                  "Explain this thoroughly.\nSecond line.\n"))
           (p (pai-prompt-from-file file)))
      ;; name from base name, description from first non-empty line.
      (should (equal (plist-get p :name) "explain"))
      (should (equal (plist-get p :description) "Explain this thoroughly."))
      (should (equal (plist-get p :body) "Explain this thoroughly.\nSecond line.\n")))))

(ert-deftest pai-prompts-discover-dedup ()
  (pai-prompts-test--sandbox dir
    (pai-prompts-test--write dir "a.md" "---\nname: dup\n---\nfirst\n")
    (let ((sub (expand-file-name "sub" dir)))
      (make-directory sub)
      (pai-prompts-test--write sub "b.md" "---\nname: dup\n---\nsecond\n"))
    (pai-prompts-test--write dir "c.md" "Only body here.\n")
    (let* ((prompts (pai-prompts-discover (list dir)))
           (names (mapcar (lambda (p) (plist-get p :name)) prompts)))
      (should (member "dup" names))
      (should (member "c" names))
      ;; first wins on name collision -> exactly one "dup".
      (should (= 1 (seq-count (lambda (n) (equal n "dup")) names))))))

;;;; render

(ert-deftest pai-prompts-render-arguments ()
  (should (equal (pai-prompt-render "Do $ARGUMENTS now" "the thing")
                 "Do the thing now"))
  (should (equal (pai-prompt-render "Do ${ARGUMENTS} now" "the thing")
                 "Do the thing now")))

(ert-deftest pai-prompts-render-positional ()
  (should (equal (pai-prompt-render "$1 and $2 and $3" "alpha beta")
                 "alpha and beta and "))
  (should (equal (pai-prompt-render "arg9=$9" "a b")
                 "arg9=")))

(ert-deftest pai-prompts-render-literal-dollar ()
  (should (equal (pai-prompt-render "cost is $$5" "x")
                 "cost is $5")))

(ert-deftest pai-prompts-render-leaves-unknown ()
  (should (equal (pai-prompt-render "keep $FOO and $BAR" "x")
                 "keep $FOO and $BAR"))
  ;; $ARGUMENTS must not swallow a larger identifier.
  (should (equal (pai-prompt-render "$ARGUMENTSX" "y")
                 "$ARGUMENTSX")))

;;;; register / dispatch

(ert-deftest pai-prompts-register-dispatch ()
  (pai-prompts-test--sandbox dir
    (pai-prompts-test--write
     dir "greet.md"
     "---\nname: greet-test-cmd\ndescription: Greeting\n---\nSay hi to $ARGUMENTS ($1!)\n")
    (let ((names (pai-prompts-register (list dir))))
      (unwind-protect
          (progn
            (should (member "greet-test-cmd" names))
            (let* ((cmd (pai-command-get "greet-test-cmd"))
                   (handler (plist-get cmd :handler)))
              (should cmd)
              (should (eq (plist-get cmd :source) 'prompt))
              (let ((r (funcall handler "hello world" nil)))
                (should (equal (plist-get r :send)
                               "Say hi to hello world (hello!)\n")))))
        (dolist (n names) (pai-unregister-command n))))))

(provide 'pai-prompts-test)
;;; pai-prompts-test.el ends here
