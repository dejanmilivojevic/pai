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

(defun pai-tools-test--write-bytes (file bytes)
  "Write unibyte BYTES to FILE literally."
  (let ((coding-system-for-write 'no-conversion))
    (with-temp-buffer (set-buffer-multibyte nil) (insert bytes) (write-region nil nil file nil 'silent))))

(ert-deftest pai-tools-read-image-by-content ()
  "An image is recognised by its first bytes, whatever its extension."
  (pai-tools-test--with-tmpdir dir
    (pai-tools-test--write-bytes (expand-file-name "shot.bin" dir)
                                 (unibyte-string #xff #xd8 #xff #xe0 0 16 ?J ?F ?I ?F 0 1))
    (let* ((r (pai-tools-test--run "read" '(:path "shot.bin") dir))
           (block (car (plist-get r :content))))
      (should-not (pai-tools-test--error-p r))
      (should (eq (plist-get block :type) 'image))
      (should (equal (plist-get block :mime-type) "image/jpeg")))))

(ert-deftest pai-tools-read-refuses-binary ()
  (pai-tools-test--with-tmpdir dir
    (pai-tools-test--write-bytes (expand-file-name "blob.dat" dir)
                                 (apply #'unibyte-string (number-sequence 0 255)))
    (let ((r (pai-tools-test--run "read" '(:path "blob.dat") dir)))
      (should (pai-tools-test--error-p r))
      (should (string-match-p "Binary file" (pai-tools-test--text r))))))

(ert-deftest pai-tools-read-text-with-a-stray-byte ()
  "A text file with a few invalid bytes is shown, the bytes replaced."
  (pai-tools-test--with-tmpdir dir
    (pai-tools-test--write-bytes (expand-file-name "log.txt" dir)
                                 (concat (make-string 500 ?x) "\n" (unibyte-string #xff) "end\n"))
    (let ((r (pai-tools-test--run "read" '(:path "log.txt") dir)))
      (should-not (pai-tools-test--error-p r))
      (should (string-match-p "end" (pai-tools-test--text r))))))

(ert-deftest pai-tools-valid-text ()
  (let ((ok "plain é ✓"))
    (should (eq (pai-tools-valid-text ok) ok)))
  (should (equal (pai-tools-valid-text (concat "a" (string-to-multibyte (unibyte-string #xff)))) "a\uFFFD"))
  (should (equal (pai-tools-valid-text (string ?a #xd800)) "a\uFFFD"))
  (should (equal (pai-tools-valid-text (unibyte-string #xc3 #xa9)) "é"))
  (let ((r (pai-tools-sanitize-result
            (list :content (list (list :type 'text :text (string #xd800)))
                  :details (list :raw (vector (string #xdfff)))))))
    (should (pai-json-encode r)))
  (let ((clean (pai-tool-ok-result "fine")))
    (should (eq (pai-tools-sanitize-result clean) clean))))

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

(ert-deftest pai-tools-elisp-eval-huge-value-is-truncated ()
  "A huge value (the 27.9. session got a 221M-char result) is bounded."
  (let* ((r (pai-tools-test--run
             "elisp_eval" '(:form "(mapconcat #'number-to-string (number-sequence 1 200000) \"\\n\")")))
         (text (pai-tools-test--text r)))
    (should-not (pai-tools-test--error-p r))
    (should (<= (string-bytes text) (+ pai-tool-max-bytes 200)))
    (should (string-match-p "output truncated" text))
    (should (<= (length (plist-get (plist-get r :details) :value)) 4096))))

;;;; truncation helpers

(ert-deftest pai-tools-truncate-lines-and-bytes ()
  (let ((text "a\nb\nc\nd"))
    (should (equal (plist-get (pai-tools-truncate text 2 100) :text) "a\nb"))
    (should (equal (plist-get (pai-tools-truncate text 2 100 'tail) :text) "c\nd"))
    (should (equal (plist-get (pai-tools-truncate text 10 100) :text) text))
    (should-not (plist-get (pai-tools-truncate text 10 100) :truncated))
    (should (= (plist-get (pai-tools-truncate text 10 100) :total-lines) 4))
    ;; Byte limit cuts on line boundaries.
    (should (equal (plist-get (pai-tools-truncate "aaa\nbbb\nccc" 10 8) :text) "aaa\nbbb"))
    (should (equal (plist-get (pai-tools-truncate "aaa\nbbb\nccc" 10 8 'tail) :text) "bbb\nccc"))
    ;; A single over-long line is cut mid-line instead of kept whole.
    (let ((r (pai-tools-truncate (make-string 100000 ?x) 10 1000)))
      (should (plist-get r :truncated))
      (should (= (length (plist-get r :text)) 1000)))
    (let ((r (pai-tools-truncate (make-string 100000 ?x) 10 1000 'tail)))
      (should (= (length (plist-get r :text)) 1000)))
    ;; Multibyte text respects the byte limit.
    (let ((r (pai-tools-truncate (make-string 1000 ?é) 10 101)))
      (should (<= (string-bytes (plist-get r :text)) 101)))))

(ert-deftest pai-tools-truncate-huge-input-is-fast ()
  (let* ((text (mapconcat #'identity (make-list 300000 "some line of output") "\n"))
         (t0 (float-time))
         (h (pai-tools-truncate text))
         (tl (pai-tools-truncate text nil nil 'tail)))
    (should (< (- (float-time) t0) 2))
    (should (<= (string-bytes (plist-get h :text)) pai-tool-max-bytes))
    (should (<= (string-bytes (plist-get tl :text)) pai-tool-max-bytes))
    (should (= (plist-get h :total-lines) 300000))))

(ert-deftest pai-tools-cap-result ()
  (let* ((small (pai-tool-ok-result "ok" (list :exit-code 0))))
    (should (eq (pai-tools-cap-result small 100) small)))
  (let* ((big (make-string 5000 ?y))
         (r (pai-tools-cap-result
             (list :content (list (pai-text big) (list :type 'image :data big))
                   :details (list :value big :n 1 :v (vector big)))
             100))
         (blocks (plist-get r :content)))
    (should (< (string-bytes (plist-get (car blocks) :text)) 300))
    (should (string-match-p "tool output truncated" (plist-get (car blocks) :text)))
    ;; Images are untouched.
    (should (= (length (plist-get (cadr blocks) :data)) 5000))
    (should (< (length (plist-get (plist-get r :details) :value)) 200))
    (should (< (length (aref (plist-get (plist-get r :details) :v) 0)) 200))
    (should (= (plist-get (plist-get r :details) :n) 1))))

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
