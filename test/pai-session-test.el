;;; pai-session-test.el --- Tests for session persistence -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai-core)
(require 'pai-session)

(defmacro pai-session-test--with-file (var &rest body)
  (declare (indent 1))
  `(let ((,var (make-temp-file "pai-session" nil ".jsonl")))
     (unwind-protect (progn ,@body) (ignore-errors (delete-file ,var)))))

(ert-deftest pai-session-slug ()
  (should (equal (pai-session--slug "/home/user/proj") "home-user-proj")))

(ert-deftest pai-session-roundtrip ()
  (pai-session-test--with-file file
    (let ((session (pai-session-new "/tmp/proj" file)))
      (pai-session-append-message session (pai-user-message "hello"))
      (pai-session-append-message
       session
       (pai-assistant-message :content (list (pai-text "hi there")
                                             (pai-tool-call "c1" "bash" '(:command "ls")))
                              :provider "anthropic" :model "claude" :stop-reason 'tool-use))
      (pai-session-append-message
       session
       (pai-tool-result-message :tool-call-id "c1" :tool-name "bash" :content "files" :is-error nil))
      ;; reload from disk
      (let* ((loaded (pai-session-load file))
             (msgs (pai-session-messages loaded)))
        (should (= (length msgs) 3))
        ;; roles are symbols again after load
        (should (eq (pai-message-role (nth 0 msgs)) 'user))
        (should (eq (pai-message-role (nth 1 msgs)) 'assistant))
        (should (eq (pai-message-role (nth 2 msgs)) 'tool-result))
        ;; content and discriminators preserved
        (should (equal (pai-message-content (nth 0 msgs)) "hello"))
        (should (eq (plist-get (nth 1 msgs) :stop-reason) 'tool-use))
        (let ((tc (car (pai-message-tool-calls (nth 1 msgs)))))
          (should (eq (pai-block-type tc) 'tool-call))
          (should (equal (plist-get tc :name) "bash"))
          (should (equal (plist-get (plist-get tc :arguments) :command) "ls")))
        (should (equal (pai-content-text (plist-get (nth 2 msgs) :content)) "files"))))))

(ert-deftest pai-session-header-written ()
  (pai-session-test--with-file file
    (let ((s (pai-session-new "/tmp/proj" file)))
      ;; Nothing is written until the first user message.
      (should (= 0 (file-attribute-size (file-attributes file))))
      (pai-session-append-message s (pai-user-message "hi")))
    (let ((first (car (with-temp-buffer (insert-file-contents file)
                                        (split-string (buffer-string) "\n" t)))))
      (let ((hdr (pai-json-decode first)))
        (should (equal (plist-get hdr :type) "session"))
        (should (= (plist-get hdr :version) pai-session-version))
        (should (equal (plist-get hdr :cwd) "/tmp/proj"))))))

(ert-deftest pai-session-empty-not-persisted ()
  ;; A session with only a system prompt never creates a file and is not
  ;; listed; once a user message arrives, everything buffered is flushed.
  (let* ((root (make-temp-file "pai-sess-root" t))
         (pai-directory root)
         (cwd "/tmp/pai-empty-proj"))
    (unwind-protect
        (let ((s (pai-session-new cwd)))
          (pai-session-append-message s (pai-system-message "sys"))
          (pai-session-append-model-change s "p" "m")
          (should-not (file-exists-p (pai-session-file s)))
          (should-not (pai-session-list cwd))
          (pai-session-append-message s (pai-user-message "hello"))
          (should (file-exists-p (pai-session-file s)))
          (should (equal (pai-session-list cwd) (list (pai-session-file s))))
          (pai-session-append-message s (pai-assistant-message :content (list (pai-text "yo"))))
          (let ((loaded (pai-session-load (pai-session-file s))))
            (should (equal (pai-session-id loaded) (pai-session-id s)))
            (should (= 3 (length (pai-session-messages loaded))))
            (should (seq-find (lambda (e) (equal (plist-get e :type) "model_change"))
                              (pai-session-entries loaded)))))
      (delete-directory root t))))

(ert-deftest pai-session-first-user-text ()
  ;; The first user message is extracted from string or block content.
  (pai-session-test--with-file file
    (let ((s (pai-session-new "/tmp/proj" file)))
      (pai-session-append-message s (pai-system-message "sys"))
      (pai-session-append-message s (pai-user-message (list (pai-text "first\nquestion"))))
      (pai-session-append-message s (pai-user-message "second"))
      (should (equal (pai-session-first-user-text file) "first\nquestion")))))

(ert-deftest pai-session-list-skips-legacy-empty-files ()
  ;; Empty session files written by older versions are hidden from the list.
  (let* ((root (make-temp-file "pai-sess-root" t))
         (pai-directory root)
         (cwd "/tmp/pai-legacy-proj")
         (dir (pai-session-directory cwd)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "empty.jsonl" dir)
            (insert "{\"type\":\"session\",\"version\":1,\"id\":\"x\"}\n"
                    "{\"id\":\"a\",\"type\":\"message\",\"message\":{\"role\":\"system\",\"content\":\"s\"}}\n"))
          (should-not (pai-session-list cwd)))
      (delete-directory root t))))

(ert-deftest pai-session-name-and-custom ()
  (pai-session-test--with-file file
    (let ((session (pai-session-new "/tmp/proj" file)))
      (pai-session-set-name session "My Session")
      (pai-session-append-message session (pai-user-message "hi"))
      (pai-session-append-custom session "widget" '(:x 1))
      (let ((loaded (pai-session-load file)))
        (should (equal (pai-session-name loaded) "My Session"))
        (should (seq-find (lambda (e) (equal (plist-get e :type) "custom"))
                          (pai-session-entries loaded)))))))

(ert-deftest pai-session-memory-no-file ()
  ;; An in-memory session keeps entries but writes nothing.
  (let ((session (pai-session-new "/tmp/proj" 'memory)))
    (should (null (pai-session-file session)))
    (pai-session-append-message session (pai-user-message "x"))
    (should (= (length (pai-session-messages session)) 1))))

(ert-deftest pai-session-transcript ()
  (let ((session (pai-session-new "/tmp/proj" 'memory)))
    (pai-session-append-message session (pai-user-message "q"))
    (let ((ctx (pai-session-transcript session)))
      (should (= (length (plist-get ctx :messages)) 1)))))

(ert-deftest pai-session-entry-ids-and-parent ()
  (let* ((s (pai-session-new "/tmp/proj" 'memory))
         (e1 (pai-session-append-message s (pai-user-message "a")))
         (e2 (pai-session-append-message s (pai-user-message "b"))))
    (should (plist-get e1 :id))
    (should (null (plist-get e1 :parentId)))
    (should (equal (plist-get e2 :parentId) (plist-get e1 :id)))
    (should (equal (pai-session-leaf-id s) (plist-get e2 :id)))
    ;; branch root->leaf
    (let ((branch (pai-session-get-branch s)))
      (should (= (length branch) 2))
      (should (equal (plist-get (car branch) :id) (plist-get e1 :id))))))

(ert-deftest pai-session-branch-navigation ()
  (let* ((s (pai-session-new "/tmp/proj" 'memory))
         (e1 (pai-session-append-message s (pai-user-message "root")))
         (_e2 (pai-session-append-message s (pai-user-message "child-a"))))
    ;; branch back to e1 and append a sibling
    (pai-session-branch s (plist-get e1 :id))
    (pai-session-append-message s (pai-user-message "child-b"))
    (let ((texts (mapcar (lambda (e) (pai-content-text (pai-message-content (plist-get e :message))))
                         (pai-session-get-branch s))))
      (should (equal texts '("root" "child-b"))))
    ;; the tree has one root with two children
    (let ((roots (pai-session-tree s)))
      (should (= (length roots) 1))
      (should (= (length (plist-get (car roots) :children)) 2)))))

(ert-deftest pai-session-context-and-prompts ()
  (let ((s (pai-session-new "/tmp/proj" 'memory)))
    (pai-session-append-message s (pai-system-message "sys"))
    (pai-session-append-message s (pai-user-message "hello"))
    (pai-session-append-message s (pai-assistant-message :content (list (pai-text "hi there"))))
    (should (= (length (pai-session-context-messages s)) 3))
    (should (equal (cdar (pai-session-user-prompts s)) "hello"))
    (should (equal (pai-session-last-assistant-text s) "hi there"))))

(ert-deftest pai-session-fork-replays ()
  (pai-session-test--with-file file
    (let* ((s (pai-session-new "/tmp/proj" file))
           (_ (pai-session-append-message s (pai-user-message "q1")))
           (mid (pai-session-append-message s (pai-assistant-message :content (list (pai-text "a1")))))
           (_ (pai-session-append-message s (pai-user-message "q2")))
           (fork (pai-session-fork s (plist-get mid :id))))
      (unwind-protect
          (let ((msgs (pai-session-messages fork)))
            ;; fork contains only up to mid: q1, a1 (not q2)
            (should (= (length msgs) 2))
            (should (equal (pai-content-text (pai-message-content (nth 0 msgs))) "q1"))
            (should (not (equal (pai-session-file fork) (pai-session-file s)))))
        (ignore-errors (delete-file (pai-session-file fork)))))))

;;;; Compaction replay

(defun pai-session-test--texts (messages)
  "Return (ROLE . TEXT) pairs for MESSAGES."
  (mapcar (lambda (m) (cons (pai-message-role m) (pai-content-text (pai-message-content m))))
          messages))

(defun pai-session-test--compacted-session (file)
  "Return a session in FILE: sys u1 a1 u2 a2 | compaction(kept from u2) | u3.
Also return the ids as a plist in the second value (a cons)."
  (let* ((s (pai-session-new "/tmp/proj" file))
         (_ (pai-session-append-message s (pai-system-message "SYS")))
         (_ (pai-session-append-message s (pai-user-message "u1")))
         (_ (pai-session-append-message s (pai-assistant-message :content (list (pai-text "a1")))))
         (u2 (pai-session-append-message s (pai-user-message "u2")))
         (_ (pai-session-append-message
             s (pai-assistant-message :content (list (pai-text "a2"))
                                      :usage '(:input 900 :output 10 :total-tokens 910))))
         (comp (pai-session-append
                s (list :type "compaction" :strategy "summary" :summary "SUM"
                        :tokensBefore 999 :firstKeptEntryId (plist-get u2 :id)
                        :summaryMessage (pai-user-message "SUMMARY-MESSAGE"))))
         (u3 (pai-session-append-message s (pai-user-message "u3"))))
    (cons s (list :u2 (plist-get u2 :id) :comp (plist-get comp :id) :u3 (plist-get u3 :id)))))

(ert-deftest pai-session-compaction-replays-on-load ()
  "A resumed session sees the compacted context, not the full transcript."
  (pai-session-test--with-file file
    (pai-session-test--compacted-session file)
    (let ((msgs (pai-session-context-messages (pai-session-load file))))
      (should (equal (pai-session-test--texts msgs)
                     '((system . "SYS") (user . "SUMMARY-MESSAGE")
                       (user . "u2") (assistant . "a2") (user . "u3")))))))

(ert-deftest pai-session-compaction-replay-marks-kept-usage-stale ()
  "Usage anchors in the kept tail measured the pre-compaction context."
  (pai-session-test--with-file file
    (pai-session-test--compacted-session file)
    (let* ((msgs (pai-session-context-messages (pai-session-load file)))
           (a2 (nth 3 msgs)))
      (should (plist-get a2 :usage))
      (should (plist-get a2 :usage-stale)))))

(ert-deftest pai-session-compaction-replay-uses-summary-text-fallback ()
  (pai-session-test--with-file file
    (let* ((s (pai-session-new "/tmp/proj" file))
           (u1 (pai-session-append-message s (pai-user-message "u1"))))
      (pai-session-append s (list :type "compaction" :summary "only text"
                                  :firstKeptEntryId (plist-get u1 :id)))
      (let ((msgs (pai-session-context-messages (pai-session-load file))))
        (should (= (length msgs) 2))
        (should (string-match-p "only text" (pai-content-text (pai-message-content (car msgs)))))))))

(ert-deftest pai-session-legacy-compaction-is-ignored ()
  "Entries written before replay existed carry no cut point: full transcript."
  (pai-session-test--with-file file
    (let ((s (pai-session-new "/tmp/proj" file)))
      (pai-session-append-message s (pai-user-message "u1"))
      (pai-session-append s (list :type "compaction" :summary "S" :tokensBefore 1))
      (pai-session-append-message s (pai-user-message "u2"))
      (should (equal (pai-session-test--texts (pai-session-context-messages (pai-session-load file)))
                     '((user . "u1") (user . "u2")))))))

(ert-deftest pai-session-compaction-is-branch-local ()
  "Moving to a point before the compaction restores the uncompacted branch."
  (pai-session-test--with-file file
    (let* ((made (pai-session-test--compacted-session file))
           (s (car made))
           (u2 (plist-get (cdr made) :u2)))
      ;; context at u2 (before the compaction entry) is uncompacted
      (should (equal (mapcar #'cdr (pai-session-test--texts (pai-session-context-messages s u2)))
                     '("SYS" "u1" "a1" "u2")))
      ;; a new branch from u2 does not see the compaction
      (pai-session-branch s u2)
      (pai-session-append-message s (pai-user-message "other"))
      (should-not (seq-find (lambda (m) (equal (pai-content-text (pai-message-content m))
                                               "SUMMARY-MESSAGE"))
                            (pai-session-context-messages s))))))

(ert-deftest pai-session-compaction-replay-keeps-deferred-schemas ()
  "The carried deferred-tool tag survives the JSON round trip."
  (pai-session-test--with-file file
    (let* ((s (pai-session-new "/tmp/proj" file))
           (u1 (pai-session-append-message s (pai-user-message "u1"))))
      (pai-session-append s (list :type "compaction" :summary "S"
                                  :firstKeptEntryId (plist-get u1 :id)
                                  :summaryMessage (pai-user-message
                                                   (list (pai-text "S") (pai-text "DEFS"))
                                                   :deferred-schemas '("frob"))))
      (let ((summary (car (pai-session-context-messages (pai-session-load file)))))
        (should (equal (plist-get summary :deferred-schemas) '("frob")))
        (should (eq (plist-get (car (pai-message-content summary)) :type) 'text))))))

(ert-deftest pai-session-latest-compaction-wins ()
  (pai-session-test--with-file file
    (let* ((made (pai-session-test--compacted-session file))
           (s (car made))
           (u3 (plist-get (cdr made) :u3)))
      (pai-session-append-message s (pai-assistant-message :content (list (pai-text "a3"))))
      (pai-session-append s (list :type "compaction" :summary "S2" :firstKeptEntryId u3
                                  :summaryMessage (pai-user-message "SECOND")))
      (should (equal (mapcar #'cdr (pai-session-test--texts
                                    (pai-session-context-messages (pai-session-load file))))
                     '("SYS" "SECOND" "u3" "a3"))))))

(ert-deftest pai-session-first-kept-entry-id ()
  (pai-session-test--with-file file
    (let* ((made (pai-session-test--compacted-session file))
           (s (car made))
           (ids (cdr made)))
      ;; last 1 message is u3; last 3 are u2 a2 u3 (the summary is no entry)
      (should (equal (pai-session-first-kept-entry-id s 1) (plist-get ids :u3)))
      (should (equal (pai-session-first-kept-entry-id s 3) (plist-get ids :u2)))
      ;; nothing older than the previous compaction's first kept entry counts
      (should-not (pai-session-first-kept-entry-id s 4))
      (should-not (pai-session-first-kept-entry-id s 0)))))

(ert-deftest pai-session-fork-custom-entries-and-hooks ()
  "Custom entries are copied only when claimed, with ids remapped; hooks run."
  (pai-session-test--with-file file
    (let* ((s (pai-session-new "/tmp/proj" file))
           (u (pai-session-append-message s (pai-user-message "u"))))
      (pai-session-append-custom s "keep" (list :ref (plist-get u :id)))
      (pai-session-append-custom s "skip" (list :x 1))
      (let* ((seen nil)
             (pai-session-fork-custom-functions
              (list (lambda (e map)
                      (when (equal (plist-get e :customType) "keep")
                        (list :ref (gethash (plist-get (plist-get e :data) :ref) map))))))
             (pai-session-fork-functions (list (lambda (src new) (setq seen (list src new)))))
             (fork (pai-session-fork s (pai-session-leaf-id s)))
             (customs (seq-filter (lambda (e) (equal (plist-get e :type) "custom"))
                                  (pai-session-entries fork)))
             (fu (seq-find (lambda (e) (equal (plist-get e :type) "message"))
                           (pai-session-entries fork))))
        (should (equal (mapcar (lambda (e) (plist-get e :customType)) customs) '("keep")))
        (should (equal (plist-get (plist-get (car customs) :data) :ref) (plist-get fu :id)))
        (should-not (equal (plist-get fu :id) (plist-get u :id)))
        (should (eq (car seen) s))
        (should (eq (cadr seen) fork))))))

;;;; Prompt tree and outline

(defun pai-session-test--say (s text &optional parent)
  "Append user TEXT and an answer to S, branching from PARENT; return the prompt entry."
  (when parent (pai-session-branch s parent))
  (let ((u (pai-session-append-message s (pai-user-message text))))
    (pai-session-append-message s (pai-assistant-message :content (list (pai-text (concat "re " text)))))
    u))

(defun pai-session-test--outline-lines (s)
  "Return (TEXT INDENT FORK ON-BRANCH) for S's outline on its current branch."
  (mapcar (lambda (it) (list (plist-get it :text) (plist-get it :indent)
                             (plist-get it :fork) (plist-get it :on-branch)))
          (pai-session-prompt-outline
           s (mapcar (lambda (e) (plist-get e :id)) (pai-session-get-branch s)))))

(ert-deftest pai-session-prompt-tree-survives-long-sessions ()
  "Regression: /tree failed with excessive-lisp-nesting on long sessions."
  (pai-session-test--with-file file
    (let ((s (pai-session-new "/tmp/proj" file)))
      (pai-session-append-message s (pai-system-message "SYS"))
      (dotimes (i 1500) (pai-session-test--say s (format "q%d" i)))
      (let ((max-lisp-eval-depth 1600))
        (should (= (length (pai-session-prompt-tree s)) 1500))
        (let ((outline (pai-session-prompt-outline s)))
          (should (= (length outline) 1500))
          ;; a straight chain never indents
          (should (seq-every-p (lambda (it) (= 0 (plist-get it :indent))) outline)))))))

(ert-deftest pai-session-prompt-outline-layout ()
  "The current branch stays in one column; forks indent under their fork point."
  (pai-session-test--with-file file
    (let* ((s (pai-session-new "/tmp/proj" file))
           (_ (pai-session-append-message s (pai-system-message "SYS")))
           (a (pai-session-test--say s "a"))
           (b (pai-session-test--say s "b"))
           (_c (pai-session-test--say s "c"))
           (a-leaf (pai-session-turn-leaf s (plist-get a :id)))
           (b-leaf (pai-session-turn-leaf s (plist-get b :id)))
           ;; x forks off a (sibling of b), y continues x, z forks off x
           (x (pai-session-test--say s "x" a-leaf))
           (_y (pai-session-test--say s "y"))
           (_z (pai-session-test--say s "z" (pai-session-turn-leaf s (plist-get x :id)))))
      ;; current branch: a b d
      (pai-session-test--say s "d" b-leaf)
      (should (equal (pai-session-test--outline-lines s)
                     ;; off the current branch, the most recent follow-up (z)
                     ;; continues and the older one (y) forks
                     '(("a" 0 nil t)
                       ("x" 1 t nil)    ; side branch under a...
                       ("y" 2 t nil)    ; ...with its own fork under x
                       ("z" 1 nil nil)  ; x's continuation lines up with x
                       ("b" 0 nil t)
                       ("c" 1 t nil)    ; b's other follow-up
                       ("d" 0 nil t))))
      ;; its display lines
      (should (equal (mapcar #'car (pai--tree-choices
                                    (pai-session-prompt-outline
                                     s (mapcar (lambda (e) (plist-get e :id))
                                               (pai-session-get-branch s)))))
                     '("* a" "  └─ x" "     └─ y" "     z" "* b" "  └─ c" "* d")))
      ;; the ancestor-depth tree keeps its contract
      (should (equal (mapcar (lambda (tr) (list (nth 1 tr) (nth 2 tr))) (pai-session-prompt-tree s))
                     '(("a" 0) ("b" 1) ("c" 2) ("d" 2) ("x" 1) ("y" 2) ("z" 2)))))))

(ert-deftest pai-session-replacements-apply-on-branch ()
  "Context edits replace their entries' messages, branch-locally, newest last."
  (pai-session-test--with-file file
    (let* ((s (pai-session-new "/tmp/proj" file))
           (u1 (pai-session-append-message s (pai-user-message "big one")))
           (_ (pai-session-append-message s (pai-assistant-message :content (list (pai-text "a1")))))
           (old (pai-session-context-messages s))
           (new (list (pai-user-message "[elided]") (cadr old))))
      (should (equal (pai-session-replacements s old new)
                     (list (list :entryId (plist-get u1 :id) :message (car new)))))
      (should (eq (pai-session-replacements s old (list (car new))) 'unmirrored))
      (pai-session-append s (list :type "shake" :replacements
                                  (vconcat (pai-session-replacements s old new))))
      (should (equal (pai-session-test--texts (pai-session-context-messages (pai-session-load file)))
                     '((user . "[elided]") (assistant . "a1"))))
      ;; a newer edit of the same entry wins
      (pai-session-append s (list :type "shake" :replacements
                                  (vector (list :entryId (plist-get u1 :id)
                                                :message (pai-user-message "[again]")))))
      (should (equal (cdar (pai-session-test--texts (pai-session-context-messages s))) "[again]"))
      ;; a branch from before the edits sees the original
      (pai-session-branch s (plist-get u1 :id))
      (should (equal (cdar (pai-session-test--texts (pai-session-context-messages s))) "big one"))
      ;; pairs carry entry ids
      (should (equal (car (car (pai-session-context-pairs s))) (plist-get u1 :id))))))

(ert-deftest pai-session-replacements-with-compaction ()
  "Edits apply to the kept tail of a compaction; the summary has no entry."
  (pai-session-test--with-file file
    (let* ((made (pai-session-test--compacted-session file))
           (s (car made))
           (u2 (plist-get (cdr made) :u2)))
      (pai-session-append s (list :type "shake" :replacements
                                  (vector (list :entryId u2 :message (pai-user-message "u2*")))))
      (let ((pairs (pai-session-context-pairs (pai-session-load file))))
        (should (equal (mapcar (lambda (p) (pai-content-text (pai-message-content (cdr p)))) pairs)
                       '("SYS" "SUMMARY-MESSAGE" "u2*" "a2" "u3")))
        (should-not (car (nth 1 pairs)))))))

(ert-deftest pai-session-loads-bare-string-messages ()
  "Older sessions saved some steering notices as bare strings; they still load."
  (pai-session-test--with-file file
    (let* ((s (pai-session-new "/tmp/proj" file))
           (u (pai-session-append-message s (pai-user-message "hi"))))
      (with-temp-buffer
        (insert (format "{\"id\":\"zz\",\"parentId\":%S,\"type\":\"message\",\"message\":\"[subagent sub-1 done] report\"}\n"
                        (plist-get u :id)))
        (append-to-file (point-min) (point-max) file)))
    (let ((msgs (pai-session-context-messages (pai-session-load file))))
      (should (= (length msgs) 2))
      (should (eq (pai-message-role (cadr msgs)) 'user))
      (should (equal (pai-message-content (cadr msgs)) "[subagent sub-1 done] report")))))

(ert-deftest pai-session-list-ignores-subdirectories ()
  "Worker transcripts in a subdirectory never show up in /resume."
  (let* ((pai-directory (make-temp-file "pai-home" t))
         (cwd "/tmp/pai-list-proj")
         (dir (pai-session-directory cwd))
         (sub (expand-file-name "memory-workers" dir)))
    (unwind-protect
        (progn
          (make-directory sub t)
          (let ((main (pai-session-new cwd)))
            (pai-session-append-message main (pai-user-message "hi")))
          (let ((worker (pai-session-new cwd (expand-file-name "w.jsonl" sub))))
            (pai-session-append-message worker (pai-user-message "worker")))
          (let ((files (pai-session-list cwd)))
            (should (= (length files) 1))
            (should-not (seq-find (lambda (f) (string-match-p "memory-workers" f)) files))))
      (delete-directory pai-directory t))))

(provide 'pai-session-test)
;;; pai-session-test.el ends here
