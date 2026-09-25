;;; pai-compaction-test.el --- Tests for compaction -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai-core)
(require 'pai-compaction)
(require 'pai-faux)

(ert-deftest pai-compaction-estimate-tokens ()
  (should (= (pai-estimate-tokens (pai-user-message "12345678"))
             (pai-estimate-tokens-from-chars 8)))
  (let ((a (pai-assistant-message :content (list (pai-text "aaaa") (pai-thinking "bbbb")))))
    (should (= (pai-estimate-tokens a) (pai-estimate-tokens-from-chars 8)))))

(ert-deftest pai-compaction-estimate-counts-thinking-signature ()
  "The signature is sent back on every request, so it is part of the context.
Providers may return an empty thinking text beside a multi-kilobyte blob."
  (let* ((sig (make-string 4000 ?s))
         (block (pai-thinking "" sig))
         (m (pai-assistant-message :content (list block))))
    (should (equal (plist-get block :thinking-signature) sig))
    (should (= (pai-estimate-tokens m) (pai-estimate-tokens-from-chars 4000)))))

(ert-deftest pai-compaction-estimate-counts-tool-call-arguments ()
  "Tool-call arguments are serialized into the request and must be counted."
  (let* ((args (list :path (make-string 600 ?p)))
         (m (pai-assistant-message
             :content (list (pai-tool-call "c1" "read" args)))))
    (should (> (pai-estimate-tokens m)
               (pai-estimate-tokens-from-chars 600)))))

(ert-deftest pai-compaction-estimate-image ()
  (let ((m (pai-user-message (list (pai-image "x" "image/png")))))
    (should (= (pai-estimate-tokens m)
               (pai-estimate-tokens-from-chars pai-compaction-image-chars)))))

(ert-deftest pai-compaction-context-tokens-uses-usage ()
  (let ((messages (list (pai-user-message "hi")
                        (pai-assistant-message :content (list (pai-text "hello"))
                                               :usage (pai-usage :total-tokens 1000)
                                               :stop-reason 'stop)
                        (pai-user-message (make-string 40 ?x)))))
    ;; base 1000 + the trailing message's estimate
    (should (= (pai-estimate-context-tokens messages)
               (+ 1000 (pai-estimate-tokens-from-chars 40))))))

(ert-deftest pai-compaction-context-tokens-ignores-stale-usage ()
  "A stale anchor no longer speaks for a context that was rewritten."
  (let* ((assistant (pai-assistant-message :content (list (pai-text "hello"))
                                           :usage (pai-usage :total-tokens 1000)
                                           :stop-reason 'stop))
         (messages (list (pai-user-message (make-string 40 ?x)) assistant)))
    (should (= (pai-estimate-context-tokens messages) 1000))
    ;; After invalidation the estimate is the sum of the messages, so an edit
    ;; to the prefix shows up immediately.
    (should (= (pai-estimate-context-tokens (pai-invalidate-usage-anchors messages))
               (+ (pai-estimate-tokens-from-chars 40)
                  (pai-estimate-tokens-from-chars 5))))))

(ert-deftest pai-compaction-invalidate-usage-anchors-from-index ()
  "Only anchors at or after the edit are marked, and data is preserved."
  (let* ((a1 (pai-assistant-message :content (list (pai-text "one"))
                                    :usage (pai-usage :total-tokens 500)
                                    :stop-reason 'stop))
         (a2 (pai-assistant-message :content (list (pai-text "two"))
                                    :usage (pai-usage :total-tokens 1000)
                                    :stop-reason 'stop))
         (messages (list a1 (pai-user-message "edited") a2))
         (out (pai-invalidate-usage-anchors messages 1)))
    (should-not (plist-get (nth 0 out) :usage-stale))
    (should (plist-get (nth 2 out) :usage-stale))
    ;; The usage plists survive, so cost accounting is untouched.
    (should (= (plist-get (plist-get (nth 2 out) :usage) :total-tokens) 1000))
    ;; Input messages are not mutated.
    (should-not (plist-get a2 :usage-stale))))

(ert-deftest pai-compaction-context-tokens-never-walks-back-to-an-older-anchor ()
  "A stale newest report means estimation, not a resurrected older one.

Walking back would let one old count speak for everything before it: the
report at index 0 describes a two-message prefix, not the thousand messages
that may follow."
  (let* ((a1 (pai-assistant-message :content (list (pai-text "one"))
                                    :usage (pai-usage :total-tokens 500)
                                    :stop-reason 'stop))
         (a2 (pai-assistant-message :content (list (pai-text "two"))
                                    :usage (pai-usage :total-tokens 1000)
                                    :stop-reason 'stop))
         (tail (pai-user-message (make-string 400 ?x)))
         (messages (list a1 tail a2))
         (out (pai-invalidate-usage-anchors messages 1)))
    (should-not (pai-compaction--last-usage-index out))
    (should (= (pai-estimate-context-tokens out)
               (+ (pai-estimate-tokens a1) (pai-estimate-tokens tail)
                  (pai-estimate-tokens a2))))))

(ert-deftest pai-compaction-context-tokens-floors-at-our-own-estimate ()
  "A report below our estimate of the same messages is a bad reading.

Anthropic responses recorded before cached prompt tokens were counted claim a
few hundred tokens for a context of tens of thousands; believing them made
the meter collapse."
  (let* ((big (pai-user-message (make-string 40000 ?x)))
         (anchor (pai-assistant-message :content (list (pai-text "ok"))
                                        ;; input 2 + output 572, no cache read
                                        :usage (pai-usage :total-tokens 574)
                                        :stop-reason 'stop))
         (messages (list big anchor))
         (estimate (+ (pai-estimate-tokens big) (pai-estimate-tokens anchor))))
    (should (> estimate 574))
    (should (= (pai-estimate-context-tokens messages) estimate))
    ;; A report above the estimate is still believed.
    (should (= (pai-estimate-context-tokens
                (list big (plist-put (copy-sequence anchor)
                                     :usage (pai-usage :total-tokens 99999))))
               99999))))

(ert-deftest pai-compaction-context-tokens-no-usage ()
  (let ((messages (list (pai-user-message (make-string 40 ?x))
                        (pai-user-message (make-string 40 ?y)))))
    (should (= (pai-estimate-context-tokens messages)
               (* 2 (pai-estimate-tokens-from-chars 40))))))

(ert-deftest pai-compaction-should-compact ()
  (let ((pai-settings--global '(:auto-compact t))
        (pai-settings--project nil)
        (big (list (pai-assistant-message :content (list (pai-text ""))
                                          :usage (pai-usage :total-tokens 190000)
                                          :stop-reason 'stop))))
    ;; 190000 > 200000 - 16384 = 183616
    (should (pai-should-compact-p big 200000))
    (should-not (pai-should-compact-p
                 (list (pai-assistant-message :usage (pai-usage :total-tokens 1000)
                                              :stop-reason 'stop))
                 200000))))

(ert-deftest pai-compaction-find-cut-snaps-to-user ()
  ;; Build many small turns; keep-recent small so cut lands mid-list at a user msg.
  (let* ((msgs (list (pai-user-message (make-string 40 ?a))     ;0
                     (pai-assistant-message :content (list (pai-text (make-string 40 ?b)))) ;1
                     (pai-user-message (make-string 40 ?c))     ;2
                     (pai-assistant-message :content (list (pai-text (make-string 40 ?d)))))) ;3
         ;; each ~10 tokens; keep-recent 15 -> accumulate from end: 3(10),2(20>=15)->cut=2 (user)
         (cut (pai-compaction--find-cut-index msgs 15)))
    (should (eq (pai-message-role (nth cut msgs)) 'user))
    (should (= cut 2))))

(ert-deftest pai-compaction-compact-with-faux ()
  (pai-faux-reset)
  (pai-faux-push '(:text "## Goal\nDo the thing\n## Next Steps\n1. continue" :stop-reason stop))
  (let* ((pai-settings--global '(:auto-compact t :compact-keep-recent-tokens 3))
         (pai-settings--project nil)
         (sys (pai-system-message "SYSPROMPT"))
         (msgs (list sys
                     (pai-user-message (make-string 200 ?a))
                     (pai-assistant-message :content (list (pai-text (make-string 200 ?b))))
                     (pai-user-message (make-string 8 ?c))
                     (pai-assistant-message :content (list (pai-text (make-string 8 ?d))))))
         (result (pai-compact msgs (pai-model "faux"))))
    (should result)
    (let ((new (plist-get result :messages)))
      ;; leading system preserved, then a summary user message, then kept recent
      (should (pai-system-message-p (nth 0 new)))
      (should (pai-user-message-p (nth 1 new)))
      (should (string-match-p "summarized" (pai-content-text (pai-message-content (nth 1 new)))))
      (should (string-match-p "Do the thing" (pai-content-text (pai-message-content (nth 1 new)))))
      ;; new list is shorter than original
      (should (< (length new) (length msgs))))))

(ert-deftest pai-compaction-compact-invalidates-kept-usage ()
  "Compaction must not leave the pre-compaction size anchored in the tail."
  (pai-faux-reset)
  (pai-faux-push '(:text "## Goal\nDo the thing" :stop-reason stop))
  (let* ((pai-settings--global '(:auto-compact t :compact-keep-recent-tokens 3))
         (pai-settings--project nil)
         (msgs (list (pai-system-message "SYSPROMPT")
                     (pai-user-message (make-string 200 ?a))
                     (pai-assistant-message :content (list (pai-text (make-string 200 ?b))))
                     (pai-user-message (make-string 8 ?c))
                     ;; The kept tail carries a usage report describing the
                     ;; whole pre-compaction context.
                     (pai-assistant-message :content (list (pai-text (make-string 8 ?d)))
                                            :usage (pai-usage :total-tokens 100000)
                                            :stop-reason 'stop)))
         (before (pai-estimate-context-tokens msgs))
         (result (pai-compact msgs (pai-model "faux")))
         (new (plist-get result :messages)))
    (should (= before 100000))
    (should (seq-find (lambda (m) (plist-get m :usage)) new))
    (should (seq-every-p (lambda (m) (or (not (plist-get m :usage))
                                         (plist-get m :usage-stale)))
                         new))
    ;; The meter reflects the compaction right away instead of after the
    ;; next provider response.
    (should (< (pai-estimate-context-tokens new) 1000))))

;;;; Deferred tool definitions survive compaction

(defconst pai-compaction-test--marker "FROBNICATOR-SCHEMA-MARKER")

(defun pai-compaction-test--frob ()
  "Return a deferred extension tool with a recognizable description."
  (list :name "frob-compact" :description (concat "Drive it. " pai-compaction-test--marker)
        :parameters (pai-object-schema (list :action (pai-string-schema "Action.")))
        :execute #'ignore))

(defun pai-compaction-test--reveal-turn (tool id)
  "Return (assistant-call reveal-result) messages for TOOL with call ID."
  (let ((reveal (pai-tool-reveal-result tool)))
    (list (pai-assistant-message
           :content (list (pai-tool-call id (plist-get tool :name) nil))
           :stop-reason 'tool-use)
          (pai-tool-result-message :tool-call-id id :tool-name (plist-get tool :name)
                                   :content (plist-get reveal :content)
                                   :details (plist-get reveal :details)))))

(defmacro pai-compaction-test--with-frob (&rest body)
  "Run BODY with the frob tool registered and tiny keep-recent settings."
  (declare (indent 0))
  `(let ((pai-settings--global '(:auto-compact t :compact-keep-recent-tokens 3))
         (pai-settings--project nil)
         (tool (pai-compaction-test--frob)))
     (pai-register-tool tool)
     (unwind-protect (progn ,@body)
       (pai-unregister-tool "frob-compact"))))

(ert-deftest pai-compaction-carries-revealed-tool-definitions ()
  "A reveal in the summarized part is carried into the summary message."
  (pai-compaction-test--with-frob
    (pai-faux-reset)
    (pai-faux-push '(:text "## Goal\nfrob things" :stop-reason stop))
    (let* ((msgs (append (list (pai-system-message "SYS")
                               (pai-user-message (make-string 200 ?a)))
                         (pai-compaction-test--reveal-turn tool "c1")
                         (list (pai-user-message (make-string 8 ?c))
                               (pai-assistant-message :content (list (pai-text "ok"))))))
           (result (pai-compact msgs (pai-model "faux")))
           (new (plist-get result :messages))
           (summary (nth 1 new)))
      (should result)
      ;; the reveal itself was summarized away ...
      (should-not (seq-find #'pai-tool-result-message-p new))
      ;; ... but its definition is carried, and still counts as revealed
      (should (equal (plist-get summary :deferred-schemas) '("frob-compact")))
      (should (string-match-p pai-compaction-test--marker
                              (pai-content-text (pai-message-content summary))))
      (should (pai-tool-revealed-p tool new))
      (should-not (pai-tool-pending-reveal tool new))
      ;; the summarizer is not fed the schema text
      (should-not (string-match-p pai-compaction-test--marker
                                  (pai-json-encode (plist-get pai-faux-last-context :messages)))))))

(ert-deftest pai-compaction-carried-definitions-survive-recompaction ()
  "A carried definition is carried again by the next compaction."
  (pai-compaction-test--with-frob
    (pai-faux-reset)
    (pai-faux-push '(:text "## Goal\nfirst" :stop-reason stop)
                   '(:text "## Goal\nsecond" :stop-reason stop))
    (let* ((msgs (append (list (pai-user-message (make-string 200 ?a)))
                         (pai-compaction-test--reveal-turn tool "c1")
                         (list (pai-user-message (make-string 8 ?c))
                               (pai-assistant-message :content (list (pai-text "ok"))))))
           (once (plist-get (pai-compact msgs (pai-model "faux")) :messages))
           (grown (append once
                          (list (pai-user-message (make-string 200 ?e))
                                (pai-assistant-message :content (list (pai-text (make-string 200 ?f))))
                                (pai-user-message "g")
                                (pai-assistant-message :content (list (pai-text "h"))))))
           (twice (plist-get (pai-compact grown (pai-model "faux")) :messages)))
      (should twice)
      (should (string-match-p "second" (pai-content-text (pai-message-content (car twice)))))
      (should (equal (plist-get (car twice) :deferred-schemas) '("frob-compact")))
      (should (pai-tool-revealed-p tool twice))
      ;; the old summary's definition block was not fed to the summarizer
      (should-not (string-match-p pai-compaction-test--marker
                                  (pai-json-encode (plist-get pai-faux-last-context :messages)))))))

(ert-deftest pai-compaction-does-not-duplicate-kept-reveal ()
  "A reveal that stays in the kept tail is not carried a second time."
  (pai-compaction-test--with-frob
    (pai-faux-reset)
    (pai-faux-push '(:text "## Goal\nx" :stop-reason stop))
    (let* ((msgs (append (list (pai-user-message (make-string 200 ?a))
                               (pai-assistant-message :content (list (pai-text (make-string 200 ?b))))
                               (pai-user-message "c"))
                         (pai-compaction-test--reveal-turn tool "c1")))
           (new (plist-get (pai-compact msgs (pai-model "faux")) :messages)))
      (should-not (plist-get (car new) :deferred-schemas))
      (should (pai-tool-revealed-p tool new)))))

(ert-deftest pai-compaction-skips-unregistered-tool-definitions ()
  "A reveal for a tool that no longer exists is not carried."
  (pai-faux-reset)
  (pai-faux-push '(:text "## Goal\nx" :stop-reason stop))
  (let* ((pai-settings--global '(:auto-compact t :compact-keep-recent-tokens 3))
         (pai-settings--project nil)
         (tool (list :name "gone-tool" :description "d"))
         (msgs (append (list (pai-user-message (make-string 200 ?a)))
                       (pai-compaction-test--reveal-turn tool "c1")
                       (list (pai-user-message (make-string 8 ?c))
                             (pai-assistant-message :content (list (pai-text "ok"))))))
         (new (plist-get (pai-compact msgs (pai-model "faux")) :messages)))
    (should new)
    (should-not (seq-find #'pai-tool-result-message-p new))
    (should-not (plist-get (car new) :deferred-schemas))))

;;;; Mid-run compaction (pi's split turn)

(defun pai-compaction-test--long-run (n)
  "Return one prompt followed by an agent run of N tool turns."
  (cons (pai-user-message "Please build the timeline widget")
        (cl-loop for i from 0 below n append
                 (let ((id (format "c%d" i)))
                   (list (pai-assistant-message
                          :content (list (pai-text (make-string 300 ?w))
                                         (pai-tool-call id "read" (list :path "f")))
                          :stop-reason 'tool-use)
                         (pai-tool-result-message :tool-call-id id :tool-name "read"
                                                  :content (make-string 300 ?r)))))))

(ert-deftest pai-compaction-cut-splits-a-single-long-run ()
  "One prompt then a long run: the cut lands inside the run, at an assistant."
  (let* ((msgs (pai-compaction-test--long-run 20))
         (cut (pai-compaction--find-cut-index msgs 1000)))
    (should (> cut 0))
    (should (eq (pai-message-role (nth cut msgs)) 'assistant))
    ;; the turn it splits starts at the prompt
    (should (eql (pai-compaction--split-turn msgs cut) 0))))

(ert-deftest pai-compaction-cut-falls-back-before-large-tool-results ()
  "Tool results larger than keep-recent at the end still leave a cut."
  (let* ((msgs (list (pai-user-message (make-string 900 ?a))
                     (pai-assistant-message :content (list (pai-text "x")))
                     (pai-user-message "go")
                     (pai-assistant-message :content (list (pai-tool-call "c1" "read" nil))
                                            :stop-reason 'tool-use)
                     (pai-tool-result-message :tool-call-id "c1" :tool-name "read"
                                              :content (make-string 3000 ?r))))
         (cut (pai-compaction--find-cut-index msgs 100)))
    (should (= cut 3))
    (should (eql (pai-compaction--split-turn msgs cut) 2))))

(ert-deftest pai-compaction-no-split-at-a-user-message ()
  (let ((msgs (list (pai-user-message "a") (pai-assistant-message) (pai-user-message "b"))))
    (should-not (pai-compaction--split-turn msgs 2))))

(ert-deftest pai-compaction-split-turn-summarizes-prefix-separately ()
  (pai-faux-reset)
  (pai-faux-push '(:text "TURN PREFIX: build the timeline widget" :stop-reason stop))
  (let* ((pai-settings--global '(:auto-compact t :compact-keep-recent-tokens 1000))
         (pai-settings--project nil)
         (msgs (cons (pai-system-message "SYS") (pai-compaction-test--long-run 20)))
         (result (pai-compact msgs (pai-model "faux")))
         (summary (plist-get result :summary)))
    (should result)
    ;; no history before the prompt: pi's placeholder, then the turn context
    (should (string-prefix-p "No prior history." summary))
    (should (string-match-p "\\*\\*Turn Context (split turn):\\*\\*" summary))
    (should (string-match-p "TURN PREFIX" summary))
    ;; the prefix was summarized with pi's turn-prefix prompt
    (should (string-match-p "PREFIX of a turn"
                            (pai-json-encode (plist-get pai-faux-last-context :messages))))
    ;; the kept tail opens at an assistant message and pairs stay intact
    (let ((new (plist-get result :messages)))
      (should (pai-system-message-p (nth 0 new)))
      (should (pai-user-message-p (nth 1 new)))
      (should (pai-assistant-message-p (nth 2 new)))
      (should (eq (pai-repair-tool-pairing new) new)))))

(ert-deftest pai-compaction-split-turn-with-history-makes-two-calls ()
  (pai-faux-reset)
  (pai-faux-push '(:text "HISTORY" :stop-reason stop) '(:text "PREFIX" :stop-reason stop))
  (let* ((pai-settings--global '(:auto-compact t :compact-keep-recent-tokens 1000))
         (pai-settings--project nil)
         (msgs (append (list (pai-user-message (make-string 600 ?o))
                             (pai-assistant-message :content (list (pai-text "old"))))
                       (pai-compaction-test--long-run 20)))
         (summary (plist-get (pai-compact msgs (pai-model "faux")) :summary)))
    (should (string-match-p "\\`HISTORY\n\n---\n\n\\*\\*Turn Context (split turn):\\*\\*\n\nPREFIX\\'"
                            summary))))

(ert-deftest pai-compaction-length-capped-summary-fails ()
  "Like pi, a summary cut off by the token cap is not used."
  (pai-faux-reset)
  (pai-faux-push '(:text "## Goal\ntrunc" :stop-reason length))
  (let ((pai-settings--global '(:auto-compact t :compact-keep-recent-tokens 3))
        (pai-settings--project nil))
    (should-not (pai-compact (list (pai-user-message (make-string 200 ?a))
                                   (pai-assistant-message :content (list (pai-text "b")))
                                   (pai-user-message (make-string 8 ?c))
                                   (pai-assistant-message :content (list (pai-text "d"))))
                             (pai-model "faux")))))

(ert-deftest pai-compaction-async-cancel ()
  (let* ((emit nil) (got :none) (killed nil)
         (pai-settings--global '(:auto-compact t :compact-keep-recent-tokens 3))
         (pai-settings--project nil))
    (cl-letf (((symbol-function 'pai-provider-stream) (lambda (_m _c _o e) (setq emit e) 'handle))
              ((symbol-function 'pai-provider-abort) (lambda (h) (setq killed h))))
      (let ((cancel (pai-compact-async
                     (list (pai-user-message (make-string 200 ?a))
                           (pai-assistant-message :content (list (pai-text "b")))
                           (pai-user-message (make-string 8 ?c))
                           (pai-assistant-message :content (list (pai-text "d"))))
                     (pai-model "faux") nil (lambda (r) (setq got r)))))
        (should (functionp cancel))
        (should (eq got :none))
        (funcall cancel)
        (should (eq killed 'handle))
        (should (equal got '(:error "cancelled")))
        ;; a late stream event changes nothing
        (funcall emit (list :type 'done :message (pai-assistant-message
                                                  :content (list (pai-text "late"))
                                                  :stop-reason 'stop)))
        (should (equal got '(:error "cancelled")))))))

(ert-deftest pai-compaction-context-overflow-p ()
  (cl-flet ((err (text) (pai-assistant-message :stop-reason 'error :error-message text)))
    (should (pai-context-overflow-p (err "prompt is too long: 213462 tokens > 200000 maximum")))
    (should (pai-context-overflow-p (err "This model's maximum context length is 128000 tokens")))
    (should (pai-context-overflow-p (err "Your input exceeds the context window of this model")))
    (should-not (pai-context-overflow-p (err "rate limit: too many tokens per minute")))
    (should-not (pai-context-overflow-p (err "HTTP 500: overloaded")))
    ;; a length stop with no output and a full window (silent truncation)
    (should (pai-context-overflow-p
             (pai-assistant-message :stop-reason 'length
                                    :usage (pai-usage :input 127500 :output 0))
             128000))
    (should-not (pai-context-overflow-p
                 (pai-assistant-message :stop-reason 'length
                                        :usage (pai-usage :input 1000 :output 0))
                 128000))))

(provide 'pai-compaction-test)
;;; pai-compaction-test.el ends here
