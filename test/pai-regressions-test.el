;;; pai-regressions-test.el --- Regression tests for review findings -*- lexical-binding: t; -*-

;;; Commentary:

;; One test per finding of a code review: each failed before its fix and
;; documents what went wrong.  Most are correctness bugs; the rest guard
;; against UI blocking (synchronous work in the command loop, process
;; filters or sentinels) and quadratic costs.
;;
;; Timing-based tests use wide margins (the bad cases took seconds; the
;; bounds are fractions of a second) and compare growth ratios where
;; absolute speed depends on the machine.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pai)
(require 'pai-faux)

;;;; Helpers

(defun pai-regression--wait (pred &optional seconds)
  "Pump process output and timers until PRED returns non-nil or SECONDS pass."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall pred)))

(defun pai-regression--script (dir name body)
  "Write an executable shell script NAME with BODY into DIR; return its path."
  (let ((file (expand-file-name name dir)))
    (with-temp-file file (insert "#!/bin/sh\n" body "\n"))
    (set-file-modes file #o755)
    file))

(defun pai-regression--file-bytes (file)
  "Return FILE's raw bytes as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun pai-regression--seconds (fn)
  "Call FN and return the wall-clock seconds it took."
  (let ((t0 (float-time)))
    (funcall fn)
    (- (float-time) t0)))

(defmacro pai-regression--with-pai-buffer (buf dir &rest body)
  "Run BODY with BUF a fresh faux-backed pai chat buffer in temp project DIR."
  (declare (indent 2))
  `(let* ((,dir (file-name-as-directory (make-temp-file "pai-review" t)))
          (pai-directory (expand-file-name ".pai-state" ,dir))
          (pai-default-model "faux")
          (,buf nil))
     (unwind-protect
         (progn
           (pai-ext-reset)
           (setq ,buf (generate-new-buffer "*pai-review*"))
           (with-current-buffer ,buf
             (setq default-directory ,dir)
             (pai--setup ,dir))
           ,@body)
       (when (buffer-live-p ,buf) (kill-buffer ,buf))
       (ignore-errors (delete-directory ,dir t)))))

;;;; 1. edit tool matches oldText case-insensitively

(ert-deftest pai-regression-edit-is-case-sensitive ()
  "`edit' matches oldText exactly.  It used `search-forward' under the default
`case-fold-search' (t), so \"foo\" matched -- and replaced -- \"Foo\"."
  (let ((file (make-temp-file "pai-regression-edit" nil ".txt" "Foo bar\n")) res)
    (unwind-protect
        (progn
          (pai-tool-edit--execute (list :path file :edits '((:oldText "foo" :newText "baz")))
                                  nil nil (lambda (r) (setq res r)))
          (should (pai-truthy (plist-get res :is-error)))       ; oldText not found
          (should (equal (pai-regression--file-bytes file) "Foo bar\n")))
      (delete-file file))))

;;;; 2. edit tool rewrites every line ending of a CRLF file

(ert-deftest pai-regression-edit-preserves-crlf ()
  "Editing a CRLF file keeps its line endings.  The file was decoded as DOS
and written back as `utf-8' (Unix), converting every line."
  (let ((file (make-temp-file "pai-regression-crlf" nil ".txt")) res)
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (write-region "one\r\ntwo\r\n" nil file nil 'silent))
          (pai-tool-edit--execute (list :path file :edits '((:oldText "one" :newText "uno")))
                                  nil nil (lambda (r) (setq res r)))
          (should-not (pai-truthy (plist-get res :is-error)))
          (should (equal (pai-regression--file-bytes file) "uno\r\ntwo\r\n")))
      (delete-file file))))

;;;; 3. bash timeout note is lost

(ert-deftest pai-regression-bash-timeout-is-reported ()
  "A timed-out command says so.  `delete-process' runs the sentinel
synchronously, so the result used to be sent before \"[timed out]\" was added."
  (let (res)
    (pai-tool-bash--execute '(:command "echo started; sleep 5" :timeout 0.3)
                            nil nil (lambda (r) (setq res r)))
    (should (pai-regression--wait (lambda () res) 4))
    (should (string-match-p "timed out" (pai-content-text (plist-get res :content))))))

;;;; 4. elisp_eval hides read errors

(ert-deftest pai-regression-elisp-eval-reports-read-errors ()
  "Unreadable input (an unbalanced form) is an error; it used to report
success, \"=> nil\"."
  (let (res)
    (pai-tool-elisp--execute '(:form "(+ 1 2") nil nil (lambda (r) (setq res r)))
    (should (pai-truthy (plist-get res :is-error)))))

;;;; 5. output cap does not apply to a single long line

(ert-deftest pai-regression-read-caps-single-long-line ()
  "One 300 KB line (minified JS, a base64 blob) is cut to the byte cap; line
based truncation used to pass it through whole."
  (let ((file (make-temp-file "pai-regression-long" nil ".js" (make-string 300000 ?x))) res)
    (unwind-protect
        (progn
          (pai-tool-read--execute (list :path file) nil nil (lambda (r) (setq res r)))
          (should (<= (string-bytes (pai-content-text (plist-get res :content)))
                      (+ pai-tool-max-bytes 1024))))
      (delete-file file))))

;;;; 6. read's paging note misreports what was shown

(ert-deftest pai-regression-read-note-matches-lines-shown ()
  "When output is cut by the byte cap, the paging note names the lines shown.
It was computed from the line cap alone (\"1-1001 of 1001\" for ~250 shown
lines), so the model believed it had read the whole file."
  (let ((file (make-temp-file "pai-regression-read"))
        res)
    (unwind-protect
        (progn
          (with-temp-file file
            (dotimes (i 1000) (insert (format "%04d %s\n" i (make-string 200 ?y)))))
          (pai-tool-read--execute (list :path file) nil nil (lambda (r) (setq res r)))
          (let* ((text (pai-content-text (plist-get res :content)))
                 (shown (cl-count-if (lambda (l) (string-match-p "\\`[0-9]\\{4\\} " l))
                                     (split-string text "\n"))))
            (should (string-match "showing lines 1-\\([0-9]+\\)" text))
            (should (= (string-to-number (match-string 1 text)) shown))))
      (delete-file file))))

;;;; 7. invalid UTF-8 in a tool result wedges the run

(defun pai-regression--encoding-stream (model context options emit)
  "Faux stream that first encodes the request body as the HTTP path does."
  (with-temp-buffer
    (pai-provider-encode-body
     (plist-get (pai-anthropic-build-request model context options) :body)))
  (pai-faux-stream model context options emit))

(ert-deftest pai-regression-invalid-utf8-tool-output-ends-run ()
  "A tool printing invalid UTF-8 (a binary or Latin-1 file) does not hang the
run.  The bytes decode to raw-byte chars and `json-serialize' signalled on
them when the next request was encoded; the error escaped into the bash
sentinel and the run never reached `agent-end' (the UI stayed \"working…\")."
  (pai-faux-reset)
  (pai-faux-push '(:tool-calls ((:id "c1" :name "bash" :arguments (:command "printf 'ok \\377\\n'")))
                  :stop-reason tool-use)
                 '(:text "done" :stop-reason stop))
  (let ((ended nil))
    (with-temp-buffer
      (pai-agent-run (list (pai-user-message "go"))
                     (pai-context nil (pai-builtin-tools))
                     (list :model (pai-model "faux") :stream-fn #'pai-regression--encoding-stream)
                     (lambda (ev) (when (eq (plist-get ev :type) 'agent-end) (setq ended ev))))
      (should (pai-regression--wait (lambda () ended) 5))
      ;; ended normally, not stopped by an internal error
      (should-not (plist-get ended :error))
      (should-not (plist-get ended :aborted)))))

(ert-deftest pai-regression-invalid-utf8-message-can-be-saved ()
  "The session writer accepts the same bytes (it signalled on them too)."
  (let* ((dir (make-temp-file "pai-regression-session" t))
         (session (pai-session-new dir (expand-file-name "s.jsonl" dir))))
    (unwind-protect
        (progn
          (pai-session-append-message session (pai-user-message "hello"))
          (should (condition-case nil
                      (progn (pai-session-append-message
                              session (pai-tool-result-message
                                       :tool-call-id "c1" :tool-name "bash"
                                       :content (decode-coding-string "ok \377" 'utf-8)))
                             t)
                    (error nil))))
      (delete-directory dir t))))

;;;; 8. a stream cut off after HTTP 200 counts as a successful answer

(ert-deftest pai-regression-truncated-stream-is-an-error ()
  "curl exiting non-zero after a 200 (--max-time, a reset connection) ends the
turn as an error.  It used to finish with stop-reason `stop' -- here with a
half-streamed tool call whose arguments were silently dropped."
  (let* ((dir (make-temp-file "pai-regression-curl" t))
         (data (expand-file-name "sse" dir))
         (frames (list '(:type "message_start" :message (:id "m1" :usage (:input_tokens 5)))
                       '(:type "content_block_start" :index 0
                               :content_block (:type "tool_use" :id "t1" :name "bash"))
                       '(:type "content_block_delta" :index 0
                               :delta (:type "input_json_delta"
                                             :partial_json "{\"command\": \"rm -rf /tmp/pai-"))))
         (pai-curl-program nil)
         (origin (generate-new-buffer " *pai-regression-origin*"))
         (final nil))
    (unwind-protect
        (progn
          (with-temp-file data
            (insert "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n")
            (dolist (f frames) (insert "data: " (pai-json-encode f) "\n\n")))
          (setq pai-curl-program
                (pai-regression--script dir "curl" (format "cat '%s'\nexit 28" data)))
          (pai-register-provider-config
           '(:id "review-anth" :api "anthropic" :base-url "http://127.0.0.1:9/v1" :model "m"))
          ;; callbacks run in the origin buffer, so it must outlive the wait
          (with-current-buffer origin
            (pai-provider-stream (pai-model "review-anth/m")
                                 (pai-context (list (pai-user-message "hi")))
                                 (list :api-key "k")
                                 (lambda (ev) (when (memq (plist-get ev :type) '(done error))
                                                (setq final ev)))))
          (should (pai-regression--wait (lambda () final) 5))
          (should (eq (plist-get (plist-get final :message) :stop-reason) 'error)))
      (kill-buffer origin)
      (remhash "review-anth" pai--providers)
      (delete-directory dir t))))

;;;; 9. OpenAI / Gemini drop images in tool results

(ert-deftest pai-regression-openai-keeps-image-tool-results ()
  "An image a tool returns (`read' of a PNG) reaches OpenAI models; tool
results were flattened to their text, so the model received \"\"."
  (let* ((msg (pai-tool-result-message :tool-call-id "c1" :tool-name "read"
                                       :content (list (pai-image "QUJD" "image/png"))))
         (json (pai-json-encode (pai-openai--messages (list msg)))))
    (should (string-search "QUJD" json))))

(ert-deftest pai-regression-gemini-keeps-image-tool-results ()
  "Same for Gemini's functionResponse."
  (let* ((msg (pai-tool-result-message :tool-call-id "c1" :tool-name "read"
                                       :content (list (pai-image "QUJD" "image/png"))))
         (json (pai-json-encode (pai-gemini--contents (list msg)))))
    (should (string-search "QUJD" json))))

;;;; 10. Gemini thought signatures on function calls are dropped

(ert-deftest pai-regression-gemini-keeps-thought-signature ()
  "The `thoughtSignature' Gemini sends next to a `functionCall' is kept and
replayed (Gemini 3 rejects function calls without it); it was dropped."
  (let* ((model (pai-make-model :id "g" :api 'google-generative-ai :provider "g"
                                :base-url "http://x"))
         (final nil)
         (parser (pai-gemini-make-parser
                  model (lambda (ev) (when (eq (plist-get ev :type) 'done)
                                       (setq final (plist-get ev :message)))))))
    (funcall (plist-get parser :on-frame)
             (list :data (pai-json-encode
                          '(:candidates [(:content (:parts [(:functionCall (:name "ls" :args (:path "."))
                                                             :thoughtSignature "SIG")])
                                          :finishReason "STOP")]))))
    (funcall (plist-get parser :on-close) 0)
    (should (string-search "SIG" (pai-json-encode (pai-gemini--contents (list final)))))))

;;;; 11. stream-sync leaves the request running after a timeout

(ert-deftest pai-regression-stream-sync-aborts-on-timeout ()
  "`pai-provider-stream-sync' aborts the request on timeout (or C-g); the
request used to keep running, and billing, after it returned."
  (let ((proc nil))
    (pai-register-provider
     (list :id "review-slow"
           :stream (lambda (_m _c _o _emit)
                     (setq proc (make-process :name "review-slow" :command '("sleep" "30")
                                              :noquery t)))))
    (pai-register-model (pai-make-model :id "slow" :api 'faux :provider "review-slow"
                                        :base-url "faux://"))
    (unwind-protect
        (progn
          (should-not (pai-provider-stream-sync (pai-model "review-slow/slow")
                                                (pai-context (list (pai-user-message "x")))
                                                nil 0.3))
          (should-not (process-live-p proc)))
      (when (process-live-p proc) (delete-process proc))
      (remhash "review-slow" pai--providers))))

;;;; 12. API keys are passed on curl's command line

(ert-deftest pai-regression-api-key-not-in-process-arguments ()
  "Headers reach curl through a private file, not -H arguments, which any
local user can read (ps, /proc/PID/cmdline) -- API keys included."
  (let* ((dir (make-temp-file "pai-regression-argv" t))
         (argv (expand-file-name "argv" dir))
         (pai-curl-program
          (pai-regression--script dir "curl" (format "echo \"$@\" > '%s'\nexit 7" argv)))
         (closed nil))
    (unwind-protect
        (progn
          (pai-http-stream :url "http://127.0.0.1:9/v1/messages"
                           :headers '(("x-api-key" . "sk-SECRET-123"))
                           :body "{}"
                           :on-close (lambda (_) (setq closed t)))
          (should (pai-regression--wait (lambda () closed) 5))
          (should-not (string-search "sk-SECRET-123"
                                     (with-temp-buffer (insert-file-contents argv) (buffer-string)))))
      (delete-directory dir t))))

;;;; 13. write/edit diffs are rendered into the transcript uncapped

(ert-deftest pai-regression-write-diff-is-capped-in-transcript ()
  "A file edit's diff is capped in the transcript like other results; a
`write' of a new 5000-line file used to insert all 5000 lines."
  (pai-regression--with-pai-buffer buf dir
    (with-current-buffer buf
      (let ((before (count-lines (point-min) (point-max)))
            (new (mapconcat (lambda (i) (format "line %d" i)) (number-sequence 1 5000) "\n")))
        (pai--render-tool-end
         (list :tool-call-id "c1" :tool-name "write" :is-error nil
               :result (pai-tool-ok-result "Wrote" (list :old "" :new new :path "big.txt"
                                                          :created t))))
        (should (< (- (count-lines (point-min) (point-max)) before) 200))))))

;;;; 14. many tool calls in one message overflow the Lisp stack

(defun pai-regression--async-faux (model context options emit)
  "Faux stream answering from a timer, as a real HTTP stream would."
  (run-at-time 0 nil (lambda () (pai-faux-stream model context options emit)))
  nil)

(ert-deftest pai-regression-many-sequential-tool-calls-finish ()
  "A large batch of synchronous tools completes.  Sequential execution
recursed once per call, overflowing `max-lisp-eval-depth' (~50 calls
interpreted, ~250 byte-compiled) so the run never ended."
  (pai-faux-reset)
  (pai-faux-push (list :tool-calls (cl-loop for i below 300
                                            collect (list :id (format "c%d" i) :name "list_buffers"
                                                          :arguments nil))
                       :stop-reason 'tool-use)
                 '(:text "done" :stop-reason stop))
  (let ((ended nil))
    (with-temp-buffer
      (pai-agent-run (list (pai-user-message "go")) (pai-context nil (pai-builtin-tools))
                     (list :model (pai-model "faux") :stream-fn #'pai-regression--async-faux)
                     (lambda (ev) (when (eq (plist-get ev :type) 'agent-end) (setq ended ev))))
      (should (pai-regression--wait (lambda () ended) 10))
      (should-not (plist-get ended :error))
      (should-not (plist-get ended :aborted)))))

;;;; UI blocking

(ert-deftest pai-regression-grep-does-not-block ()
  "The grep tool runs asynchronously.  It used `call-process': Emacs was
frozen (no redisplay, no input, no C-c C-c) until the search ended."
  (let* ((dir (make-temp-file "pai-regression-rg" t))
         (exec-path (cons dir exec-path))
         (done nil))
    (pai-regression--script dir "rg" "sleep 1.5; echo 'a.el:1:match'")
    (unwind-protect
        (let ((took (pai-regression--seconds
                     (lambda ()
                       (pai-tool-grep--execute '(:pattern "match") (list :cwd dir) nil
                                               (lambda (_) (setq done t)))))))
          (should (< took 0.5))
          (should (pai-regression--wait (lambda () done) 5)))
      (delete-directory dir t))))

(ert-deftest pai-regression-bang-command-does-not-block ()
  "`!cmd' runs asynchronously; with `call-process' a slow command
\(`!make') froze Emacs until it exited."
  (pai-regression--with-pai-buffer buf dir
    (with-current-buffer buf
      (should (< (pai-regression--seconds (lambda () (pai--run-bang "!sleep 1.5"))) 0.5)))))

(ert-deftest pai-regression-model-discovery-does-not-block ()
  "Model pickers (C-c C-m, `/model' completion) do not wait for discovery
when models are known.  They ran `pai-models-refresh': a blocking curl per
provider and page (up to 5 s connect + 15 s each).  The background refresh
queries providers concurrently."
  (let* ((dir (make-temp-file "pai-regression-disc" t))
         (pai-curl-program (pai-regression--script dir "curl" "sleep 1; echo '{\"data\":[{\"id\":\"m\"}]}'"))
         (errors :pending))
    (unwind-protect
        (with-temp-buffer
          (pai-ext-initialize-instance)
          (pai-register-provider-config '(:id "review-p1" :api "openai" :base-url "http://127.0.0.1:9/v1" :model "known"))
          (pai-register-provider-config '(:id "review-p2" :api "openai" :base-url "http://127.0.0.1:9/v1"))
          ;; the picker returns at once
          (should (< (pai-regression--seconds #'pai-models-refresh-for-choice) 0.5))
          ;; the async refresh reports once both providers answered, together
          (let ((took (pai-regression--seconds
                       (lambda ()
                         (pai-models-refresh-async (lambda (errs) (setq errors errs)))
                         (pai-regression--wait (lambda () (not (eq errors :pending))) 10)))))
            (should (null errors))
            (should (< took 1.8)))
          (should (pai-model "review-p2/m")))
      (delete-directory dir t))))

(ert-deftest pai-regression-auto-compaction-at-run-start-does-not-block ()
  "A prompt sent while the context is over the threshold compacts without
blocking.  It used `pai--compact-now', waiting on `pai-provider-stream-sync':
Emacs was unusable for the whole summary (up to its 180 s timeout)."
  (pai-faux-reset)
  (pai-faux-push '(:text "## Goal\nsummary\n## Next Steps\n1. go" :stop-reason stop)
                 '(:text "answer after compaction" :stop-reason stop))
  (pai-regression--with-pai-buffer buf dir
    (with-current-buffer buf
      (setq pai--context-messages
            (append pai--context-messages
                    (cl-loop for _ below 20 append
                             (list (pai-user-message (make-string 400 ?a))
                                   (pai-assistant-message :content (list (pai-text (make-string 400 ?b))))))))
      (let ((pai-settings--global '(:auto-compact t :compact-threshold 0.01
                                                  :compact-keep-recent-tokens 50))
            (orig (symbol-function 'pai-faux-stream)))
        (cl-letf (((symbol-function 'pai-faux-stream)
                   (lambda (&rest args) (run-at-time 1.0 nil (lambda () (apply orig args))) nil)))
          (should (< (pai-regression--seconds (lambda () (pai--start-run "next question"))) 0.5))
          ;; compaction streams, then the run starts and completes
          (should pai--active)
          (should (pai-regression--wait (lambda () (not pai--active)) 15))
          (let ((text (buffer-string)))
            (should (string-match "Compacted context" text))
            (should (string-match-p "▶ You\nnext question" (substring text (match-end 0))))
            (should (string-match-p "— ready —" (substring text (match-end 0))))))))))

(ert-deftest pai-regression-cap-result-handles-long-detail-lists ()
  "`pai-tools-cap-result' (applied to every tool result) handles long detail
lists.  It recursed once per list cell when a string needed capping, so ~1000
items (interpreted) or ~3000 (compiled) overflowed `max-lisp-eval-depth'
inside the agent loop, and every level rescanned the rest (quadratic)."
  (let* ((details (append (make-list 5000 "a") (list (make-string 300000 ?x))))
         (capped (plist-get (pai-tools-cap-result (list :content (list (pai-text "x"))
                                                        :details details))
                            :details)))
    (should (= (length capped) 5001))
    (should (< (string-bytes (car (last capped))) (+ pai-tool-result-max-bytes 100)))
    ;; nothing oversized: returned as is
    (let ((small (list :content (list (pai-text "x")) :details (make-list 5000 "a"))))
      (should (eq (pai-tools-cap-result small) small)))))

(ert-deftest pai-regression-sanitize-result-handles-long-lists ()
  "`pai-tools-sanitize-result' (applied to every tool result) handles long
lists.  It recursed once per list cell, so a tool whose details held ~2000
items (byte-compiled; ~500 interpreted) stopped the run with an internal
error, even when every string was valid."
  (let* ((clean (list :content (list (pai-text "x")) :details (make-list 20000 "a")))
         (dirty (list :content (list (pai-text "x"))
                      :details (append (make-list 20000 "a")
                                       (list (decode-coding-string "ok \377" 'utf-8))))))
    ;; nothing to fix: returned as is
    (should (eq (pai-tools-sanitize-result clean) clean))
    (let ((details (plist-get (pai-tools-sanitize-result dirty) :details)))
      (should (= (length details) 20001))
      (should (equal (car (last details)) "ok \ufffd")))))

(ert-deftest pai-regression-oauth-refresh-handler-registered ()
  "Expired Anthropic OAuth tokens are refreshed.  Core defined
`pai-auth-oauth-anthropic-refresh' but never registered it, so an expired
token was sent as is and every request failed until /login."
  (should (assoc "anthropic" pai-auth-oauth-refresh-handlers)))

;;;; Performance (quadratic behaviour)

(defun pai-regression--feed-tool-args (kb)
  "Stream KB kilobytes of tool arguments through the Anthropic parser."
  (let* ((model (pai-make-model :id "m" :api 'anthropic-messages :provider "x" :base-url "http://x"))
         (on-frame (plist-get (pai-anthropic-make-parser model #'ignore) :on-frame))
         (json (pai-json-encode (list :path "a" :content (make-string (* kb 1024) ?a))))
         (frame (lambda (obj) (funcall on-frame (list :data (pai-json-encode obj))))))
    (funcall frame '(:type "message_start" :message (:id "m1")))
    (funcall frame '(:type "content_block_start" :index 0
                           :content_block (:type "tool_use" :id "t1" :name "write")))
    (cl-loop for i from 0 below (length json) by 30
             do (funcall frame (list :type "content_block_delta" :index 0
                                     :delta (list :type "input_json_delta"
                                                  :partial_json (substring json i (min (length json) (+ i 30)))))))
    (funcall frame '(:type "message_stop"))))

(ert-deftest pai-regression-stream-accumulation-is-linear ()
  "Streaming tool-call arguments costs linear time.  Each delta re-concatenated
the whole JSON buffer: 4x the arguments cost ~12x the time, and a 400 KB
`write' spent seconds in GC."
  (garbage-collect)
  (let ((small (pai-regression--seconds (lambda () (pai-regression--feed-tool-args 50))))
        (large (pai-regression--seconds (lambda () (pai-regression--feed-tool-args 200)))))
    (should (< (/ large small) 7))))

(defun pai-regression--bash-output (mb)
  "Run the bash tool producing MB megabytes of output; return seconds taken."
  (let ((res nil))
    (pai-regression--seconds
     (lambda ()
       (pai-tool-bash--execute (list :command (format "yes 0123456789abcdef0123456789abcde | head -c %d"
                                                      (* mb 1024 1024)))
                               nil #'ignore (lambda (r) (setq res r)))
       (pai-regression--wait (lambda () res) 120)))))

(ert-deftest pai-regression-bash-output-accumulation-is-linear ()
  "Bash output accumulates in linear time.  The filter did (concat output
chunk) and passed the whole output on every chunk: 16 MB of output took ~17 s
of Emacs CPU (byte-compiled), during which Emacs was mostly frozen."
  (let ((small (pai-regression--bash-output 1))
        (large (pai-regression--bash-output 6)))
    (should (< (/ large small) 12))))

(ert-deftest pai-regression-truncate-is-fast ()
  "Truncation is linear.  Byte truncation dropped one line at a time with
`butlast' + `string-join': ~1.5 s for one 2 MB tool output."
  (let ((text (mapconcat #'identity (make-list 2000 (make-string 1000 ?a)) "\n")))
    (should (< (pai-regression--seconds (lambda () (pai-tools-truncate text))) 0.2))))

(ert-deftest pai-regression-read-slice-of-large-file-is-cheap ()
  "`read' with offset/limit decodes only the lines shown.  It loaded and split
the whole file: 0.4 s to read one line of 35 MB."
  (let ((file (make-temp-file "pai-regression-big")))
    (unwind-protect
        (progn
          (with-temp-file file
            (dotimes (i 150000) (insert (format "line %d %s\n" i (make-string 80 ?x)))))
          (should (< (pai-regression--seconds
                      (lambda () (pai-tool-read--execute (list :path file :offset 1 :limit 1)
                                                         nil nil #'ignore)))
                     0.1)))
      (delete-file file))))

(ert-deftest pai-regression-session-append-is-linear ()
  "`pai-session-append' is O(1); it copied the entry list per entry, O(n^2)
per session."
  (cl-flet ((fill (n) (let ((s (pai-session-new nil 'memory)))
                        (pai-regression--seconds
                         (lambda () (dotimes (_ n) (pai-session-append s '(:type "custom"))))))))
    (let ((small (fill 2000)) (large (fill 16000)))
      (should (< (/ large small) 16)))))

(provide 'pai-regressions-test)
;;; pai-regressions-test.el ends here
