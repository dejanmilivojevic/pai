;;; pai-activity-test.el --- Tests for the background activity indicator -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pai)
(require 'pai-activity)

(defmacro pai-activity-test--with-prompt-buffer (buf &rest body)
  "Run BODY in a fresh buffer BUF that has a pai-like prompt."
  (declare (indent 1))
  `(let ((,buf (generate-new-buffer " *activity-test*")))
     (unwind-protect
         (with-current-buffer ,buf
           (insert "history\n\n" pai-prompt-string)
           (setq-local pai--input-marker (copy-marker (point) nil))
           ,@body)
       (with-current-buffer ,buf
         (when (timerp pai-activity--timer) (cancel-timer pai-activity--timer)))
       (kill-buffer ,buf))))

(ert-deftest pai-activity-start-observe-finish ()
  (pai-activity-test--with-prompt-buffer buf
    (let ((e (pai-activity-start :prefix "tst" :kind "memory" :glyph "🧠"
                                 :label "observer" :detail "8.2k tokens")))
      (should (string-prefix-p "tst-" (plist-get e :id)))
      (should (equal (pai-activity-running) (list e)))
      (should (equal (pai-activity-running "memory") (list e)))
      (should-not (pai-activity-running "other"))
      ;; streamed text is estimated live, finished turns bank real usage
      (pai-activity-observe e (list :type 'message-update
                                    :event (list :type 'text-delta :delta (make-string 40 ?x))))
      (should (= (pai-activity-tokens e) 10))
      (pai-activity-observe e (list :type 'message-end
                                    :message (pai-assistant-message :usage (pai-usage :output 25))))
      (should (= (pai-activity-tokens e) 25))
      (pai-activity-observe e (list :type 'tool-execution-start))
      (should (= (plist-get e :tools) 1))
      (let ((line (pai-activity-line e)))
        (should (string-match-p "🧠" line))
        (should (string-match-p (regexp-quote (plist-get e :id)) line))
        (should (string-match-p "observer" line))
        (should (string-match-p "tok/s" line))
        (should (string-match-p "8.2k tokens" line)))
      (pai-activity-finish e)
      (should (equal (plist-get e :status) "completed"))
      (should-not (pai-activity-running))
      ;; still in history
      (should (equal (pai-activity-get (plist-get e :id)) e))
      ;; finishing twice keeps the first status
      (pai-activity-finish e "failed")
      (should (equal (plist-get e :status) "completed")))))

(ert-deftest pai-activity-block-renders-above-prompt ()
  (pai-activity-test--with-prompt-buffer buf
    (let ((e (pai-activity-start :label "observer" :detail "working")))
      (let ((ov pai-activity--overlay))
        (should (overlayp ov))
        (should (= (overlay-start ov)
                   (- (marker-position pai--input-marker) (length pai-prompt-string))))
        (should (string-match-p "observer" (overlay-get ov 'before-string))))
      ;; detail updates are redrawn
      (pai-activity-update e :detail "almost done")
      (should (string-match-p "almost done" (overlay-get pai-activity--overlay 'before-string)))
      ;; two running activities: two lines
      (let ((e2 (pai-activity-start :label "consolidator")))
        (should (= 2 (cl-count ?\n (overlay-get pai-activity--overlay 'before-string))))
        (pai-activity-finish e2))
      (pai-activity-finish e)
      (should-not (overlayp pai-activity--overlay)))))

(ert-deftest pai-activity-without-prompt-is-harmless ()
  (with-temp-buffer
    (let ((e (pai-activity-start :label "x")))
      (should-not pai-activity--overlay)
      (pai-activity-finish e)
      (when (timerp pai-activity--timer) (cancel-timer pai-activity--timer)))))

(ert-deftest pai-activity-stop-calls-owner ()
  (pai-activity-test--with-prompt-buffer buf
    (let* ((stopped nil)
           (e (pai-activity-start :label "x" :on-stop (lambda (entry) (setq stopped entry)))))
      (should (pai-activity-stop e))
      (should (eq stopped e))
      (should (equal (plist-get e :status) "stopped"))
      ;; stopping a finished activity is a no-op
      (setq stopped nil)
      (should-not (pai-activity-stop e))
      (should-not stopped))))

(ert-deftest pai-activity-stop-survives-failing-callback ()
  (pai-activity-test--with-prompt-buffer buf
    (let ((e (pai-activity-start :label "x" :on-stop (lambda (_e) (error "boom")))))
      (should (pai-activity-stop e))
      (should (equal (plist-get e :status) "stopped")))))

(ert-deftest pai-activity-history-is-bounded ()
  (pai-activity-test--with-prompt-buffer buf
    (let ((pai-activity-history-size 3)
          (live (pai-activity-start :label "live")))
      (dotimes (_ 6) (pai-activity-finish (pai-activity-start :label "done")))
      ;; one more start triggers trimming of the finished ones
      (pai-activity-finish (pai-activity-start :label "done"))
      (pai-activity-start :label "trigger")
      (should (memq live pai-activity--entries))
      (should (<= (cl-count "completed" pai-activity--entries
                            :key (lambda (e) (plist-get e :status)) :test #'equal)
                  3))
      (dolist (e (pai-activity-running)) (pai-activity-finish e)))))

(ert-deftest pai-activity-summary ()
  (pai-activity-test--with-prompt-buffer buf
    (should-not (pai-activity-summary))
    (let ((a (pai-activity-start :kind "memory" :glyph "🧠" :label "a"))
          (b (pai-activity-start :kind "memory" :glyph "🧠" :label "b")))
      (should (equal (pai-activity-summary "memory") "🧠 2"))
      (pai-activity-finish a) (pai-activity-finish b))))

(provide 'pai-activity-test)
;;; pai-activity-test.el ends here
