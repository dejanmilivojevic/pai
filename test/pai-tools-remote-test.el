;;; pai-tools-remote-test.el --- Built-in tools on a remote (TRAMP) cwd -*- lexical-binding: t; -*-

;;; Commentary:
;; The bash, grep, read and write tools follow a TRAMP working directory:
;; commands run on that host and absolute paths name its files.  The
;; "remote" here is TRAMP's built-in `docker' method talking to a fake
;; `docker' executable that runs the shell locally (and logs each call), so
;; the tests need neither Docker nor a network.

;;; Code:

(require 'ert)
(require 'tramp)
(require 'tramp-container nil t)
(require 'pai-tools)
(require 'pai-tools-builtin)

(defmacro pai-remote-test--with-fake-docker (dir &rest body)
  "Run BODY with a fake `docker' on PATH; bind DIR to a scratch directory."
  (declare (indent 1))
  `(let* ((,dir (file-name-as-directory (make-temp-file "pai-remote" t)))
          (bin (expand-file-name "bin/" ,dir))
          (log (expand-file-name "docker.log" ,dir))
          (exec-path (cons bin exec-path))
          (process-environment
           (cons (concat "PATH=" bin path-separator (getenv "PATH")) process-environment))
          (tramp-verbose 0)
          (tramp-cache-read-persistent-data nil)
          (tramp-persistency-file-name nil))
     (make-directory bin t)
     (with-temp-file (expand-file-name "docker" bin)
       (insert "#!/bin/sh\n"
               "# fake docker: `docker exec [-flags] [-u USER] HOST CMD...' runs CMD here\n"
               "echo \"$@\" >> " (shell-quote-argument log) "\n"
               "[ \"$1\" = exec ] || exit 1; shift\n"
               "while [ $# -gt 0 ]; do case \"$1\" in\n"
               "  -u) shift 2;; -*) shift;; *) break;; esac; done\n"
               "shift\n"
               "exec \"$@\"\n"))
     (set-file-modes (expand-file-name "docker" bin) #o755)
     (unwind-protect (progn ,@body)
       (ignore-errors (tramp-cleanup-all-connections))
       (ignore-errors (delete-directory ,dir t)))))

(defun pai-remote-test--run-tool (name args ctx)
  "Run tool NAME with ARGS in CTX and return its result, waiting for it."
  (let ((result nil) (deadline (+ (float-time) 30)))
    (funcall (plist-get (pai-tool-get name) :execute)
             args ctx nil (lambda (r) (setq result r)))
    (while (and (null result) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    result))

(defun pai-remote-test--text (result)
  "The text of tool RESULT."
  (pai-content-text (plist-get result :content)))

(ert-deftest pai-tool-resolve-path-maps-absolute-paths-to-the-remote-host ()
  (let ((ctx (list :cwd "/docker:box:/workspace/")))
    (should (equal (pai-tool-resolve-path ctx "a.txt") "/docker:box:/workspace/a.txt"))
    (should (equal (pai-tool-resolve-path ctx "/etc/hosts") "/docker:box:/etc/hosts"))
    (should (equal (pai-tool-resolve-path ctx "/docker:other:/x") "/docker:other:/x")))
  (should (equal (pai-tool-resolve-path (list :cwd "/tmp/") "/etc/hosts") "/etc/hosts")))

(ert-deftest pai-tool-bash-runs-on-the-remote-host ()
  (pai-remote-test--with-fake-docker dir
    (let* ((cwd (concat "/docker:box:" dir))
           (r (pai-remote-test--run-tool "bash" (list :command "pwd; echo hi >&2; exit 3")
                                         (list :cwd cwd))))
      (should r)
      (should (string-match-p (regexp-quote (directory-file-name dir))
                              (pai-remote-test--text r)))
      (should (string-match-p "hi" (pai-remote-test--text r)))
      (should (string-match-p "exited with code 3" (pai-remote-test--text r)))
      (should (string-match-p "exec" (with-temp-buffer
                                       (insert-file-contents (expand-file-name "docker.log" dir))
                                       (buffer-string)))))))

(ert-deftest pai-tool-file-tools-and-grep-on-the-remote-host ()
  (pai-remote-test--with-fake-docker dir
    (let ((ctx (list :cwd (concat "/docker:box:" dir))))
      ;; write with an absolute host path, read it back relatively
      (should-not (pai-truthy
                   (plist-get (pai-remote-test--run-tool
                               "write" (list :path (concat dir "note.txt")
                                             :content "needle in a haystack\n")
                               ctx)
                              :is-error)))
      (should (file-exists-p (expand-file-name "note.txt" dir)))
      (should (string-match-p "needle" (pai-remote-test--text
                                        (pai-remote-test--run-tool
                                         "read" (list :path "note.txt") ctx))))
      (let ((g (pai-remote-test--text
                (pai-remote-test--run-tool "grep" (list :pattern "needle") ctx))))
        (should (string-match-p "note.txt:1:needle" g)))
      (should (string-match-p "note.txt" (pai-remote-test--text
                                          (pai-remote-test--run-tool "ls" nil ctx)))))))

(provide 'pai-tools-remote-test)
;;; pai-tools-remote-test.el ends here
