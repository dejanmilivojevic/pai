;;; pai-activity.el --- Background activity indicator above the prompt -*- lexical-binding: t; -*-

;;; Commentary:

;; A small registry of background work owned by a pai buffer -- memory
;; workers today, anything else that runs an agent in the background
;; tomorrow -- rendered as a live block just above the prompt, one line per
;; running activity, in the same style as the subagent extensions:
;;
;;   🧠 obs-3   observer     1.2kt ·   30 tok/s · 12s · 8.2k tokens
;;
;; Owners start an activity with `pai-activity-start', feed it agent events
;; with `pai-activity-observe' (tokens and tok/s are then live), optionally
;; change its detail text with `pai-activity-update', and end it with
;; `pai-activity-finish'.  `pai-activity-stop' asks the owner to abort it
;; through the :on-stop callback supplied at start.
;;
;; Finished activities drop out of the block but stay in the buffer's history
;; (bounded by `pai-activity-history-size') so status commands can list them.
;; The block refreshes on a timer that only ticks while something runs.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'pai-core)

(defvar pai--input-marker)
(defvar pai-prompt-string)

(defgroup pai-activity nil
  "Background activity indicator for pai."
  :group 'pai)

(defface pai-activity-face '((t :inherit font-lock-comment-face))
  "Face for the background activity lines shown above the prompt."
  :group 'pai-activity)

(defcustom pai-activity-history-size 50
  "How many finished activities each pai buffer remembers."
  :type 'integer
  :group 'pai-activity)

(defcustom pai-activity-refresh-interval 0.5
  "Seconds between refreshes of the activity block while something runs."
  :type 'number
  :group 'pai-activity)

(defvar-local pai-activity--entries nil
  "Activities owned by this buffer, newest first.
Each entry is a mutable plist: (:id :kind :glyph :label :detail :status
:started :ended :buffer :on-stop :usage-tokens :stream-chars :tools :data).")

(defvar-local pai-activity--overlay nil
  "Overlay rendering the activity block above this buffer's prompt.")

(defvar-local pai-activity--timer nil
  "Repeating timer refreshing this buffer's activity block while active.")

(defvar pai-activity--counters (make-hash-table :test 'equal)
  "Per-prefix id counters (process-global, so ids stay unique).")

;;;; Formatting

(defun pai-activity-fmt-count (n)
  "Format token count N compactly (e.g. 950, 1.2k, 45k, 1.2M)."
  (let ((n (max 0 (round (or n 0)))))
    (cond ((< n 1000) (number-to-string n))
          ((< n 100000) (format "%.1fk" (/ n 1000.0)))
          ((< n 1000000) (format "%dk" (round (/ n 1000.0))))
          (t (format "%.1fM" (/ n 1000000.0))))))

(defun pai-activity-fmt-duration (seconds)
  "Format elapsed SECONDS compactly (e.g. 12s, 3m04s)."
  (let ((s (max 0 (round (or seconds 0)))))
    (if (< s 60) (format "%ds" s)
      (format "%dm%02ds" (/ s 60) (% s 60)))))

(defun pai-activity-elapsed (entry)
  "Return ENTRY's wall-clock runtime in seconds (frozen once ended)."
  (max 0.001 (- (or (plist-get entry :ended) (float-time))
                (or (plist-get entry :started) (float-time)))))

(defun pai-activity-tokens (entry)
  "Return ENTRY's best-known output token count.
Finished turns count real usage; the in-flight turn is estimated from
streamed characters (~4 chars/token) so the display stays live."
  (+ (or (plist-get entry :usage-tokens) 0)
     (max 0 (round (/ (or (plist-get entry :stream-chars) 0) 4.0)))))

(defun pai-activity-tps (entry)
  "Return ENTRY's output tokens per second over its runtime."
  (round (/ (pai-activity-tokens entry) (pai-activity-elapsed entry))))

(defun pai-activity--one-line (text width)
  "Return TEXT collapsed to one line and truncated to WIDTH."
  (truncate-string-to-width
   (string-trim (replace-regexp-in-string "[ \t\n]+" " " (or text "")))
   width nil nil "…"))

(defun pai-activity-line (entry)
  "Return the single status line for activity ENTRY."
  (let ((detail (plist-get entry :detail)))
    (concat
     (format "%s %-7s %-12s %6st · %4d tok/s · %s"
             (or (plist-get entry :glyph) "⛭")
             (plist-get entry :id)
             (pai-activity--one-line (plist-get entry :label) 12)
             (pai-activity-fmt-count (pai-activity-tokens entry))
             (pai-activity-tps entry)
             (pai-activity-fmt-duration (pai-activity-elapsed entry)))
     (if (and detail (not (string-empty-p detail)))
         (concat " · " (pai-activity--one-line detail 60))
       ""))))

;;;; Registry

(defun pai-activity--next-id (prefix)
  "Return a fresh id \"PREFIX-N\"."
  (format "%s-%d" prefix (cl-incf (gethash prefix pai-activity--counters 0))))

(defun pai-activity-running (&optional kind buffer)
  "Return BUFFER's running activities (optionally only KIND), oldest first.
BUFFER defaults to the current buffer."
  (with-current-buffer (or buffer (current-buffer))
    (reverse (seq-filter (lambda (e)
                           (and (equal (plist-get e :status) "running")
                                (or (null kind) (equal (plist-get e :kind) kind))))
                         pai-activity--entries))))

(defun pai-activity-entries (&optional kind buffer)
  "Return BUFFER's activities (optionally only KIND), newest first."
  (with-current-buffer (or buffer (current-buffer))
    (if kind
        (seq-filter (lambda (e) (equal (plist-get e :kind) kind)) pai-activity--entries)
      pai-activity--entries)))

(defun pai-activity-get (id &optional buffer)
  "Return the activity in BUFFER whose id is ID, or nil."
  (seq-find (lambda (e) (equal (plist-get e :id) id)) (pai-activity-entries nil buffer)))

(defun pai-activity--trim ()
  "Drop the oldest finished activities beyond `pai-activity-history-size'."
  (let ((finished 0))
    (setq pai-activity--entries
          (seq-filter (lambda (e)
                        (or (equal (plist-get e :status) "running")
                            (<= (cl-incf finished) pai-activity-history-size)))
                      pai-activity--entries))))

(cl-defun pai-activity-start (&key id (prefix "act") kind glyph label detail on-stop data
                                   (buffer (current-buffer)))
  "Register a running activity owned by BUFFER and return its entry.
ID defaults to \"PREFIX-N\".  KIND groups activities (e.g. \"memory\"),
GLYPH starts its line, LABEL names it and DETAIL describes what it is doing.
ON-STOP is called with the entry by `pai-activity-stop'; DATA is kept for the
owner.  The entry is a mutable plist; use the functions in this file to
change it so the display stays in sync."
  (let ((entry (list :id (or id (pai-activity--next-id prefix))
                     :kind kind :glyph glyph :label label :detail detail
                     :status "running" :started (float-time) :ended nil
                     :buffer buffer :on-stop on-stop :data data
                     :usage-tokens 0 :stream-chars 0 :tools 0)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (push entry pai-activity--entries)
        (pai-activity--trim))
      (pai-activity-refresh buffer))
    entry))

(defun pai-activity-observe (entry event)
  "Fold agent EVENT into ENTRY's live metrics.  Mutates ENTRY."
  (pcase (plist-get event :type)
    ('message-update
     (let ((se (plist-get event :event)))
       (when (memq (plist-get se :type) '(text-delta thinking-delta toolcall-delta))
         (plist-put entry :stream-chars
                    (+ (or (plist-get entry :stream-chars) 0)
                       (length (or (plist-get se :delta) "")))))))
    ('message-end
     (let ((m (plist-get event :message)))
       (when (pai-assistant-message-p m)
         (plist-put entry :usage-tokens
                    (+ (or (plist-get entry :usage-tokens) 0)
                       (or (plist-get (plist-get m :usage) :output) 0)))
         (plist-put entry :stream-chars 0))))
    ('tool-execution-start
     (plist-put entry :tools (1+ (or (plist-get entry :tools) 0))))))

(defun pai-activity-update (entry &rest props)
  "Set PROPS (e.g. :detail STRING) on ENTRY and refresh its display."
  (while props
    (plist-put entry (car props) (cadr props))
    (setq props (cddr props)))
  (pai-activity-refresh (plist-get entry :buffer)))

(defun pai-activity-finish (entry &optional status)
  "Mark ENTRY finished with STATUS (default \"completed\"); return ENTRY.
A finished entry leaves the block but stays in the history.  Finishing an
entry that is no longer running is a no-op."
  (when (equal (plist-get entry :status) "running")
    (plist-put entry :status (or status "completed"))
    (plist-put entry :ended (float-time))
    (plist-put entry :stream-chars 0)
    (pai-activity-refresh (plist-get entry :buffer)))
  entry)

(defun pai-activity-stop (entry)
  "Ask ENTRY's owner to stop it; return non-nil when it was running.
Calls the :on-stop callback, then marks ENTRY \"stopped\" unless the callback
already finished it."
  (when (equal (plist-get entry :status) "running")
    (let ((on-stop (plist-get entry :on-stop)))
      (when on-stop
        (condition-case err (funcall on-stop entry)
          (error (message "pai-activity: stopping %s: %s"
                          (plist-get entry :id) (error-message-string err))))))
    (pai-activity-finish entry "stopped")
    t))

;;;; Display above the prompt

(defun pai-activity--prompt-start ()
  "Return the position where this buffer's prompt begins, or nil."
  (when (and (boundp 'pai--input-marker) (markerp pai--input-marker)
             (marker-buffer pai--input-marker))
    (max (point-min)
         (- (marker-position pai--input-marker)
            (length (if (boundp 'pai-prompt-string) pai-prompt-string ""))))))

(defun pai-activity-block-string (entries)
  "Return the multi-line block text for ENTRIES (one line each)."
  (propertize (concat (mapconcat #'pai-activity-line entries "\n") "\n")
              'face 'pai-activity-face))

(defun pai-activity--remove-overlay ()
  "Delete this buffer's activity overlay, if any."
  (when (overlayp pai-activity--overlay) (delete-overlay pai-activity--overlay))
  (setq pai-activity--overlay nil))

(defvar pai-activity-compact-renderers nil
  "Alist of (KIND . FUNCTION) for kinds shown as one compact line.
Running activities of KIND do not get a line each; instead FUNCTION is called
with no arguments in the owning buffer and returns one line (a string) or nil.
It may also show recently finished activities: the block keeps refreshing
while any compact line is non-nil.")

(defun pai-activity--compact-lines ()
  "Return the non-nil compact lines of this buffer's compact kinds."
  (delq nil (mapcar (lambda (r) (ignore-errors (funcall (cdr r))))
                    pai-activity-compact-renderers)))

(defun pai-activity--render ()
  "Show this buffer's running activities just above its prompt.
Return non-nil while there is something to show."
  (let* ((compact (pai-activity--compact-lines))
         (running (seq-remove (lambda (e) (assoc (plist-get e :kind)
                                                  pai-activity-compact-renderers))
                              (pai-activity-running)))
         (pos (pai-activity--prompt-start)))
    (if (and (or running compact) pos)
        (progn
          (unless (overlayp pai-activity--overlay)
            (setq pai-activity--overlay (make-overlay pos pos nil t nil))
            (overlay-put pai-activity--overlay 'pai-activity t))
          (move-overlay pai-activity--overlay pos pos)
          (overlay-put pai-activity--overlay 'before-string
                       (concat (mapconcat (lambda (l) (concat l "\n")) compact "")
                               (and running (pai-activity-block-string running)))))
      (pai-activity--remove-overlay))
    (or running compact)))

(defun pai-activity--display (buffer)
  "Redraw BUFFER's activity block; return non-nil while something is shown."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (let ((shown (pai-activity--render)))
           (and (or shown (pai-activity-running)) t)))))

(defun pai-activity--ensure-timer (buffer)
  "Start BUFFER's refresh timer unless one is live; it stops when idle."
  (with-current-buffer buffer
    (unless (timerp pai-activity--timer)
      (let (timer)
        (setq timer
              (run-at-time
               pai-activity-refresh-interval pai-activity-refresh-interval
               (lambda ()
                 (unless (pai-activity--display buffer)
                   (cancel-timer timer)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (setq pai-activity--timer nil)))))))
        (setq pai-activity--timer timer)))))

(defun pai-activity-refresh (&optional buffer)
  "Redraw BUFFER's activity block now and keep it ticking while active."
  (let ((buffer (or buffer (current-buffer))))
    (when (pai-activity--display buffer)
      (pai-activity--ensure-timer buffer))))

(defun pai-activity-summary (&optional kind buffer)
  "Return a short mode-line style summary of BUFFER's running activities.
Only KIND when non-nil; nil when nothing runs."
  (let ((running (pai-activity-running kind buffer)))
    (when running
      (format "%s %d" (or (plist-get (car running) :glyph) "⛭") (length running)))))

(provide 'pai-activity)
;;; pai-activity.el ends here
