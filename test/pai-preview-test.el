;;; pai-preview-test.el --- Tests for live previews -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pai)
(require 'pai-preview)

(defvar helm-alive-p)

(defmacro pai-preview-test--with-session (s file &rest body)
  "Bind S to a saved session with a fork, FILE to its file; run BODY."
  (declare (indent 2))
  `(let* ((dir (file-name-as-directory (make-temp-file "pai-prev" t)))
          (pai-directory dir)
          (,s (pai-session-new dir)))
     (unwind-protect
         (let* ((u1 (pai-session-append-message ,s (pai-user-message "first question")))
                (_a1 (pai-session-append-message
                      ,s (pai-assistant-message
                          :content (list (pai-text "first answer")
                                         (list :type 'tool-call :id "t1" :name "bash"
                                               :arguments '(:command "ls -la")))))))
           (pai-session-append-message
            ,s (list :role 'tool-result :tool-call-id "t1" :tool-name "bash"
                     :is-error t :content (list (pai-text "boom\nsecond line"))))
           (pai-session-append-message ,s (pai-user-message "abandoned branch"))
           ;; fork from the first prompt (the next prompt becomes its child) and
           ;; continue: the file's last entries are the current branch
           (pai-session-branch ,s (plist-get u1 :id))
           (pai-session-append-message ,s (pai-user-message "second question"))
           (pai-session-append-message
            ,s (pai-assistant-message :content (list (pai-text "second answer"))))
           (let ((,file (pai-session-file ,s)))
             (clrhash pai-preview--cache)
             ,@body))
       (delete-directory dir t))))

(ert-deftest pai-preview-tail-follows-the-current-branch ()
  (pai-preview-test--with-session s file
    (let* ((tail (pai-preview--tail-entries file))
           (texts (mapcar (lambda (m) (pai-content-text (pai-message-content m)))
                          (pai-preview--entries-messages (car tail)))))
      (should (cdr tail))                ; small file: read from its start
      (should (equal texts '("first question" "second question" "second answer"))))))

(ert-deftest pai-preview-tail-of-a-long-file ()
  "Reading only the end skips the partial first line and says so."
  (pai-preview-test--with-session s file
    (let* ((size (file-attribute-size (file-attributes file)))
           (last-line-bytes (with-temp-buffer
                              (insert-file-contents-literally file)
                              (goto-char (point-max))
                              (forward-line -1)
                              (- (point-max) (point))))
           (pai-preview-tail-bytes (+ last-line-bytes 5))
           (tail (pai-preview--tail-entries file)))
      (should (< pai-preview-tail-bytes size))
      (should-not (cdr tail))
      (should (equal (mapcar (lambda (e) (plist-get (plist-get e :message) :role)) (car tail))
                     '("assistant")))
      (should (string-match-p "showing the end of a long session"
                              (pai-preview-session-text file))))))

(ert-deftest pai-preview-renders-like-the-transcript ()
  (pai-preview-test--with-session s file
    (let ((text (pai-preview-session-text file)))
      (should (string-match-p (regexp-quote (file-name-nondirectory file)) text))
      (should (string-match-p "▶ You\nsecond question" text))
      (should (string-match-p "● pai\nsecond answer" text))
      (should-not (string-match-p "abandoned branch" text))
      (should (eq (get-text-property (string-match "▶ You" text) 'face text) 'pai-user-face))))
  ;; tool calls and results are one-liners; errors are marked
  (let ((text (pai-preview-render
               "t" (list (pai-assistant-message
                          :content (list (list :type 'tool-call :id "t1" :name "bash"
                                               :arguments '(:command "ls -la"))))
                         (list :role 'tool-result :tool-call-id "t1" :tool-name "bash"
                               :is-error t :content (list (pai-text "boom\nsecond line")))))))
    (should (string-match-p "⚙ bash {\"command\":\"ls -la\"}" text))
    (should (string-match-p "✗ boom second line" text)))
  ;; only the last messages are shown
  (let* ((pai-preview-max-messages 2)
         (text (pai-preview-render "t" (mapcar (lambda (i) (pai-user-message (format "m%d" i)))
                                             '(1 2 3 4)))))
    (should (string-match-p "2 earlier messages not shown" text))
    (should-not (string-match-p "m2" text))
    (should (string-match-p "m4" text))))

(ert-deftest pai-preview-session-cache ()
  (pai-preview-test--with-session s file
    (let ((calls 0))
      (cl-letf* ((orig (symbol-function 'pai-preview--tail-entries))
                 ((symbol-function 'pai-preview--tail-entries)
                  (lambda (f) (cl-incf calls) (funcall orig f))))
        (pai-preview-session-text file)
        (pai-preview-session-text file)
        (should (= calls 1))
        ;; the session grows: previewed again
        (pai-session-append-message s (pai-user-message "third question"))
        (should (string-match-p "third question" (pai-preview-session-text file)))
        (should (= calls 2))))))

(ert-deftest pai-preview-window-shows-and-closes ()
  (pai-preview-show "hello preview")
  (should (get-buffer pai-preview-buffer-name))
  (should (equal (with-current-buffer pai-preview-buffer-name (buffer-string)) "hello preview"))
  (pai-preview-close)
  (should-not (get-buffer pai-preview-buffer-name)))

(defun pai-preview-test--drive (moves)
  "Return a `completing-read' stand-in that moves through MOVES, then picks the last.
Each move sets the selected candidate and runs the minibuffer's hooks."
  (lambda (&rest _)
    (run-hooks 'minibuffer-setup-hook)
    (dolist (c moves)
      (setq pai-preview-test--selected c)
      (run-hooks 'post-command-hook))
    (car (last moves))))

(defvar pai-preview-test--selected nil)

(defmacro pai-preview-test--with-settings (&rest body)
  "Run BODY with empty, temporary settings."
  `(let* ((pai-directory (file-name-as-directory (make-temp-file "pai-prev-set" t)))
          (pai-settings--global nil) (pai-settings--project nil))
     (unwind-protect (progn ,@body) (delete-directory pai-directory t))))

(ert-deftest pai-preview-off-by-default ()
  (pai-preview-test--with-settings
   (should-not (pai-preview-on-p :preview-resume))
   (should-not (pai-preview-on-p :preview-tree))
   (pai-settings-set :preview-tree t)
   (should (pai-preview-on-p :preview-tree))
   (should-not (pai-preview-on-p :preview-resume))))

(ert-deftest pai-preview-completing-read-previews-as-you-move ()
  (pai-preview-test--with-settings
  (pai-settings-set :preview t)
  (let ((seen '()) (cleaned nil)
        (choices '(("alpha" . 1) ("beta" . 2) ("gamma" . 3))))
    (with-temp-buffer
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_secs _repeat fn &rest args) (apply fn args) nil))
                ((symbol-function 'pai-preview--selected-candidate)
                 (lambda () pai-preview-test--selected))
                ((symbol-function 'completing-read)
                 (pai-preview-test--drive '("alpha" "alpha" "nope" "gamma"))))
        (should (equal (pai-completing-read-preview
                        "Pick: " choices (lambda (v) (push v seen)) nil
                        (lambda () (setq cleaned t)))
                       "gamma"))))
    ;; each distinct candidate once, unknown ones skipped, cleanup ran
    (should (equal (nreverse seen) '(1 3)))
    (should cleaned))))

(ert-deftest pai-preview-cleanup-runs-on-quit ()
  (let ((cleaned nil))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (signal 'quit nil))))
      (should (condition-case nil
                  (progn (pai-completing-read-preview "Pick: " '(("a" . 1)) #'ignore nil
                                                      (lambda () (setq cleaned t)))
                         nil)
                (quit t))))
    (should cleaned)))

(ert-deftest pai-preview-reads-the-helm-selection ()
  (let ((helm-alive-p t))
    (cl-letf (((symbol-function 'helm-get-selection) (lambda (&rest _) "beta ")))
      (should (equal (pai-preview--selected-candidate) "beta "))
      ;; helm may pad or propertize its display: still matched
      (should (equal (pai-preview--lookup (pai-preview--selected-candidate)
                                          '(("alpha" . 1) ("beta" . 2)))
                     '("beta" . 2))))))

(ert-deftest pai-preview-can-be-turned-off ()
  (let ((pai-preview-enabled nil) (called nil))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "a")))
      (should (equal (pai-completing-read-preview "P: " '(("a" . 1)) (lambda (_) (setq called t)))
                     "a")))
    (should-not called)))

(ert-deftest pai-preview-per-picker-setting-and-toggle-key ()
  "Each picker has its own setting; the toggle key flips and saves it."
  (pai-preview-test--with-settings
   (let ((seen '()) (cleanups 0)
         (choices '(("alpha" . 1) ("beta" . 2))))
     (pai-settings-set :preview-tree :false)
     (should-not (pai-preview-on-p :preview-tree))
     (with-temp-buffer
       (cl-letf (((symbol-function 'run-with-idle-timer)
                  (lambda (_secs _repeat fn &rest args) (apply fn args) nil))
                 ((symbol-function 'pai-preview--selected-candidate)
                  (lambda () pai-preview-test--selected))
                 ((symbol-function 'minibuffer-message) #'ignore)
                 ((symbol-function 'completing-read)
                  (lambda (prompt &rest _)
                    (should (equal prompt "Tree [C-c C-f preview]: "))
                    (run-hooks 'minibuffer-setup-hook)
                    (let ((toggle (lookup-key (cdar pai-preview--key-alist) (kbd pai-preview-toggle-key))))
                      ;; above minor-mode maps, where helm keeps its keymap
                      (should (memq 'pai-preview--key-alist emulation-mode-map-alists))
                      (should (eq (key-binding (kbd pai-preview-toggle-key)) toggle))
                      (should (commandp toggle))
                      ;; off: moving previews nothing
                      (setq pai-preview-test--selected "alpha") (run-hooks 'post-command-hook)
                      (should-not seen)
                      ;; on: the current candidate previews at once, and it is saved
                      (funcall-interactively toggle)
                      (should (equal seen '(1)))
                      (should (eq (pai-settings-get :preview-tree) t))
                      (setq pai-preview-test--selected "beta") (run-hooks 'post-command-hook)
                      (should (equal seen '(2 1)))
                      ;; off again: cleanup runs, the setting is saved off
                      (funcall-interactively toggle)
                      (should (= cleanups 1))
                      (should (eq (pai-settings-get :preview-tree) :false)))
                    "beta")))
         (should (equal (pai-completing-read-preview
                         "Tree: " choices (lambda (v) (push v seen)) nil
                         (lambda () (cl-incf cleanups)) :preview-tree)
                        "beta"))
         ;; ... and once more when the read ends
         (should (= cleanups 2)))))))

(ert-deftest pai-preview-toggle-saves-in-the-origin-buffer ()
  "The toggle runs in the minibuffer but saves into the pai buffer's settings."
  (pai-preview-test--with-settings
   (pai-settings-set :custom-providers '((:id "local")))
   (let ((origin (generate-new-buffer " *origin*")))
     (unwind-protect
         (progn
           (with-current-buffer origin
             (setq-local pai-settings--global (pai-settings--read (pai-settings-global-file))))
           (let ((pai-settings--global nil))   ; the empty default, as in the minibuffer
             (with-current-buffer origin
               (cl-letf (((symbol-function 'minibuffer-message) #'ignore)
                         ((symbol-function 'completing-read)
                          (lambda (&rest _)
                            (run-hooks 'minibuffer-setup-hook)
                            (with-temp-buffer   ; like the minibuffer
                              (funcall-interactively
                               (lookup-key (cdar (with-current-buffer origin pai-preview--key-alist))
                                           (kbd pai-preview-toggle-key))))
                            "a")))
                 (pai-completing-read-preview "P: " '(("a" . 1)) #'ignore #'ignore #'ignore :preview-tree))))
           (with-current-buffer origin
             (should (eq (plist-get pai-settings--global :preview-tree) t))
             (should (plist-get pai-settings--global :custom-providers)))
           (let ((disk (pai-settings--read (pai-settings-global-file))))
             (should (eq (plist-get disk :preview-tree) t))
             (should (plist-get disk :custom-providers))))
       (kill-buffer origin)))))

(ert-deftest pai-preview-prompt-hint ()
  (should (equal (pai-preview--prompt "Resume session: ") "Resume session [C-c C-f preview]: "))
  (should (equal (pai-preview--prompt "Pick") "Pick [C-c C-f preview] ")))

(ert-deftest pai-preview-stays-at-the-end ()
  "The end of the preview is shown, also after the window changed."
  (pai-preview-show (mapconcat (lambda (i) (format "line %d" i)) (number-sequence 1 400) "\n"))
  (unwind-protect
      (let ((w (get-buffer-window pai-preview-buffer-name)))
        (should w)
        (with-current-buffer pai-preview-buffer-name
          (should (memq #'pai-preview--anchor-end window-size-change-functions)))
        (set-window-start w 1)
        (set-window-point w 1)
        (pai-preview--anchor-end w)
        (should (= (window-point w)
                   (with-current-buffer pai-preview-buffer-name (point-max)))))
    (pai-preview-close)))

(provide 'pai-preview-test)
;;; pai-preview-test.el ends here
