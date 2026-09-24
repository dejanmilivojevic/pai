;;; pai-session.el --- Append-only JSONL session persistence -*- lexical-binding: t; -*-

;;; Commentary:

;; Sessions persist a conversation as append-only JSON Lines under
;; `pai-directory'/sessions/<project-slug>/<uuid>.jsonl.  The first line is a
;; header; subsequent lines are entries (messages, model changes, custom
;; extension state, labels, session info).  Loading replays the entries into a
;; transcript.  Port of the essentials of
;; packages/coding-agent/src/core/session-manager.ts.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'pai-core)
(require 'pai-config)

(defconst pai-session-version 1 "On-disk session format version.")

(cl-defstruct (pai-session (:constructor pai-session-create))
  id cwd file name
  (entries '())
  leaf-id
  (by-id (make-hash-table :test 'equal))
  ;; Lines are buffered in PENDING (newest first) until the first user
  ;; message arrives, so sessions that were opened but never used do not
  ;; leave a file behind (and thus never show up in the history).
  (persisted nil)
  (pending '()))

;;;; Paths

(defun pai-session--slug (cwd)
  "Return a filesystem-safe slug for project directory CWD."
  (let ((s (directory-file-name (expand-file-name cwd))))
    (replace-regexp-in-string "^-+" "" (replace-regexp-in-string "[^A-Za-z0-9]+" "-" s))))

(defun pai-session-directory (cwd)
  "Return (creating) the sessions directory for project CWD."
  (pai-state-directory "sessions" (pai-session--slug cwd)))

;;;; Serialization

(defun pai-session--symbol (v)
  "Coerce V to a symbol if it is a string, else return V."
  (if (stringp v) (intern v) v))

(defun pai-session--symbolize-block (block)
  "Return content BLOCK with its :type coerced to a symbol."
  (if (and (listp block) (plist-member block :type))
      (plist-put (copy-sequence block) :type (pai-session--symbol (plist-get block :type)))
    block))

(defun pai-session--symbolize-content (content)
  "Return CONTENT (string or block list) with block :type values as symbols."
  (if (listp content) (mapcar #'pai-session--symbolize-block content) content))

(defun pai-session-normalize-message (message)
  "Return decoded MESSAGE with role/type/stop-reason coerced back to symbols.
JSON decoding yields string discriminators; the rest of pai uses symbols.
A bare string -- how older versions saved a steering notice from a
subagent -- becomes a user message, so those sessions still load."
  (let ((m (if (stringp message) (pai-user-message message) (copy-sequence message))))
    (when (plist-member m :role)
      (setq m (plist-put m :role (pai-session--symbol (plist-get m :role)))))
    (when (plist-member m :stop-reason)
      (setq m (plist-put m :stop-reason (pai-session--symbol (plist-get m :stop-reason)))))
    (when (plist-member m :content)
      (setq m (plist-put m :content (pai-session--symbolize-content (plist-get m :content)))))
    m))

;;;; Writing

(defun pai-session--user-message-entry-p (object)
  "Return non-nil when OBJECT is a message entry carrying a user message."
  (and (equal (plist-get object :type) "message")
       (memq (pai-session--symbol (plist-get (plist-get object :message) :role))
             '(user))))

(defun pai-session--flush (session)
  "Write SESSION's buffered lines to its file and mark it persisted."
  (let ((file (pai-session-file session)))
    (when file
      (let ((text (mapconcat (lambda (o) (concat (pai-json-encode o) "\n"))
                             (reverse (pai-session-pending session)) "")))
        (unless (string-empty-p text)
          (make-directory (file-name-directory file) t)
          (write-region text nil file t 'silent))))
    (setf (pai-session-pending session) nil
          (pai-session-persisted session) t)))

(defun pai-session--append-line (session object)
  "Append OBJECT as a JSON line to SESSION's file, when it has one.
Until SESSION holds a user message the line is only buffered, so empty
sessions are never written to disk."
  (when (pai-session-file session)
    (if (pai-session-persisted session)
        (write-region (concat (pai-json-encode object) "\n") nil
                      (pai-session-file session) t 'silent)
      (push object (pai-session-pending session))
      (when (pai-session--user-message-entry-p object)
        (pai-session--flush session)))))

(defun pai-session-new (&optional cwd file)
  "Create and persist a new session for CWD (default `default-directory').
When FILE is nil, a path under the sessions directory is chosen; pass the
symbol `memory' for an in-memory session that is never written to disk."
  (let* ((cwd (expand-file-name (or cwd default-directory)))
         (id (pai-uuidv7))
         (file (cond ((eq file 'memory) nil)
                     (file (expand-file-name file))
                     (t (expand-file-name (concat id ".jsonl") (pai-session-directory cwd)))))
         (session (pai-session-create :id id :cwd cwd :file file :entries '())))
    (pai-session--append-line session
                              (list :type "session" :version pai-session-version
                                    :id id :timestamp (pai-now-ms) :cwd cwd))
    session))

(defun pai-session--gen-id (session)
  "Return a fresh 8-hex entry id not present in SESSION's index."
  (let ((by-id (pai-session-by-id session)) id)
    (while (or (null id) (gethash id by-id))
      (setq id (format "%08x" (random (expt 2 32)))))
    id))

(defun pai-session-append (session entry)
  "Append ENTRY (a plist with a string :type) to SESSION and persist it.
Assigns a unique :id and links :parentId to the current leaf, advancing it."
  (let* ((id (pai-session--gen-id session))
         (full (append (list :id id :parentId (pai-session-leaf-id session)) entry)))
    (setf (pai-session-entries session) (append (pai-session-entries session) (list full)))
    (puthash id full (pai-session-by-id session))
    (setf (pai-session-leaf-id session) id)
    (pai-session--append-line session full)
    full))

(defun pai-session-append-message (session message)
  "Append MESSAGE to SESSION as a message entry."
  (pai-session-append session (list :type "message" :message message)))

(defun pai-session-append-custom (session custom-type data)
  "Append an extension custom entry of CUSTOM-TYPE carrying DATA to SESSION."
  (pai-session-append session (list :type "custom" :customType custom-type :data data)))

(defun pai-session-set-name (session name)
  "Set SESSION's display NAME and persist a session_info entry."
  (setf (pai-session-name session) name)
  (pai-session-append session (list :type "session_info" :name name)))

;;;; Loading

(defun pai-session-load (file)
  "Load a session from FILE and return a `pai-session'.
Message entries are normalized back to symbol discriminators."
  (let ((lines (with-temp-buffer
                 (insert-file-contents file)
                 (split-string (buffer-string) "\n" t)))
        (session nil) (entries '()))
    (dolist (line lines)
      (let ((obj (ignore-errors (pai-json-decode line))))
        (when obj
          (pcase (plist-get obj :type)
            ("session"
             (setq session (pai-session-create
                            :id (plist-get obj :id)
                            :cwd (plist-get obj :cwd)
                            :file (expand-file-name file)
                            :persisted t)))
            ("message"
             (push (plist-put (copy-sequence obj) :message
                              (pai-session-normalize-message (plist-get obj :message)))
                   entries))
            ("session_info"
             (when session (setf (pai-session-name session) (plist-get obj :name)))
             (push obj entries))
            (_ (push obj entries))))))
    (unless session
      (setq session (pai-session-create :file (expand-file-name file) :persisted t)))
    (setq entries (nreverse entries))
    (setf (pai-session-entries session) entries)
    (dolist (e entries)
      (when (plist-get e :id) (puthash (plist-get e :id) e (pai-session-by-id session))))
    (setf (pai-session-leaf-id session)
          (and entries (plist-get (car (last entries)) :id)))
    session))

;;;; Queries

(defun pai-session-messages (session)
  "Return the list of messages in SESSION, in order."
  (delq nil (mapcar (lambda (e) (when (equal (plist-get e :type) "message")
                                  (plist-get e :message)))
                    (pai-session-entries session))))

(defun pai-session-transcript (session)
  "Return a context plist (:messages ...) from SESSION for the agent loop."
  (list :messages (pai-session-messages session)))

(defun pai-session--file-has-user-message-p (file)
  "Return non-nil when session FILE contains at least one user message."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (re-search-forward "\"role\" *: *\"user\"" nil t)))

(defun pai-session-first-user-text (file)
  "Return the text of the first user message in session FILE, or nil.
Only lines up to the first user message are decoded."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (text)
      (while (and (not text) (not (eobp)))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (when (string-match-p "\"role\" *: *\"user\"" line)
            (let ((obj (ignore-errors (pai-json-decode line))))
              (when (pai-session--user-message-entry-p obj)
                (setq text (pai-content-text
                            (pai-session--symbolize-content
                             (plist-get (plist-get obj :message) :content))))))))
        (forward-line 1))
      text)))

(defun pai-session-list (cwd)
  "Return the non-empty session files for project CWD, newest first.
Sessions without any user message (opened but never used) are skipped."
  (let ((dir (pai-session-directory cwd)))
    (when (file-directory-p dir)
      (sort (seq-filter #'pai-session--file-has-user-message-p
                        (directory-files dir t "\\.jsonl\\'"))
            (lambda (a b) (file-newer-than-file-p a b))))))

;;;; Additional entry types

(defun pai-session-append-model-change (session provider model-id)
  "Record a model change to PROVIDER/MODEL-ID in SESSION."
  (pai-session-append session (list :type "model_change" :provider provider :modelId model-id)))

(defun pai-session-append-thinking-change (session level)
  "Record a thinking-LEVEL change in SESSION."
  (pai-session-append session (list :type "thinking_level_change" :thinkingLevel level)))

(defun pai-session-append-custom-message (session custom-type content &optional display)
  "Append a custom message (CUSTOM-TYPE, CONTENT) that participates in LLM context."
  (pai-session-append session (list :type "custom_message" :customType custom-type
                                    :content content :display (if display t :false))))

(defun pai-session-append-label (session target-id label)
  "Bookmark TARGET-ID with LABEL in SESSION."
  (pai-session-append session (list :type "label" :targetId target-id :label label)))

;;;; Tree navigation

(defun pai-session-get-branch (session &optional leaf)
  "Return the entries on the path from the root to LEAF (default current leaf)."
  (let ((by-id (pai-session-by-id session))
        (id (or leaf (pai-session-leaf-id session)))
        (path '()))
    (while id
      (let ((e (gethash id by-id)))
        (when e (push e path))
        (setq id (and e (plist-get e :parentId)))))
    path))

(defun pai-session-branch (session target-id)
  "Set SESSION's leaf to TARGET-ID so the next append forks from there."
  (setf (pai-session-leaf-id session) target-id))

(defun pai-session-tree (session)
  "Return the root nodes of SESSION's entry tree.
Each node is (:entry E :children (NODE...))."
  (let ((nodes (make-hash-table :test 'equal)) (roots '()))
    (dolist (e (pai-session-entries session))
      (puthash (plist-get e :id) (list :entry e :children '()) nodes))
    (dolist (e (pai-session-entries session))
      (let ((node (gethash (plist-get e :id) nodes))
            (parent (and (plist-get e :parentId) (gethash (plist-get e :parentId) nodes))))
        (if parent
            (setf (plist-get parent :children)
                  (append (plist-get parent :children) (list node)))
          (push node roots))))
    (nreverse roots)))

(defun pai-session--entry-to-message (entry)
  "Convert a session ENTRY to an LLM message, or nil if it is not context."
  (pcase (plist-get entry :type)
    ("message" (pai-session-normalize-message (plist-get entry :message)))
    ("custom_message" (pai-user-message (or (plist-get entry :content) "")))
    (_ nil)))

;;;; Compaction replay
;;
;; A `compaction' entry records how the live context was shrunk:
;;   :firstKeptEntryId  the entry whose message is the first one kept verbatim
;;   :summaryMessage    the exact message that replaced everything before it
;;   :summary           the summary text (fallback when :summaryMessage is absent)
;;   :strategy          who produced it ("summary" = built-in `pai-compact')
;; Rebuilding the context from the branch replays the newest such entry, so a
;; resumed or re-entered session sees the same context the live one had.
;; Legacy entries without :firstKeptEntryId cannot be replayed and are ignored.

(defun pai-session--compaction-replayable-p (entry branch-ids)
  "Return non-nil when compaction ENTRY can be replayed on a branch.
BRANCH-IDS lists the ids of the branch entries that precede ENTRY."
  (and (equal (plist-get entry :type) "compaction")
       (stringp (plist-get entry :firstKeptEntryId))
       (member (plist-get entry :firstKeptEntryId) branch-ids)
       (or (plist-get entry :summaryMessage)
           (stringp (plist-get entry :summary)))))

(defun pai-session--latest-compaction (branch)
  "Return (ENTRY . INDEX) for the newest replayable compaction on BRANCH, or nil."
  (let ((ids '()) (found nil) (i 0))
    (dolist (e branch)
      (when (pai-session--compaction-replayable-p e ids)
        (setq found (cons e i)))
      (push (plist-get e :id) ids)
      (setq i (1+ i)))
    found))

(defun pai-session--compaction-message (entry)
  "Return the summary message that compaction ENTRY put in the context."
  (let ((m (plist-get entry :summaryMessage)))
    (if (and m (plist-member m :role))
        (pai-session-normalize-message m)
      (pai-user-message
       (concat "The earlier part of this conversation was summarized to save context. "
               "Continue based on this summary:\n\n" (plist-get entry :summary))))))

(defun pai-session--mark-usage-stale (messages)
  "Return MESSAGES with every provider usage anchor marked `:usage-stale'.
Those anchors measured the context before the compaction replaced its head."
  (mapcar (lambda (m)
            (if (and (plist-get m :usage) (not (plist-get m :usage-stale)))
                (plist-put (copy-sequence m) :usage-stale t)
              m))
          messages))

;;;; Context edits
;;
;; An entry carrying `:replacements' -- a list of (:entryId ID :message M) --
;; records that a context edit (e.g. /shake) replaced the messages of earlier
;; entries.  Rebuilding the context applies every such entry on the branch,
;; oldest first, so a later edit of the same entry wins.  Edits are
;; branch-local like everything else, and survive /resume.

(defun pai-session-replacement-table (branch)
  "Return a hash table from entry id to its replacement message on BRANCH."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (e branch)
      (dolist (r (append (plist-get e :replacements) nil))
        (when (and (stringp (plist-get r :entryId)) (plist-get r :message))
          (puthash (plist-get r :entryId)
                   (pai-session-normalize-message (plist-get r :message))
                   table))))
    table))

(defun pai-session-entry-message (entry &optional table)
  "Return the LLM message ENTRY contributes, after replacements in TABLE."
  (let ((m (pai-session--entry-to-message entry)))
    (or (and m table (gethash (plist-get entry :id) table)) m)))

(defun pai-session--stale-after-edits (pairs table)
  "Return PAIRS with usage anchors marked stale from the first edited message on.
An edit rewrote part of the prefix those provider usage reports measured."
  (let ((seen nil))
    (mapcar (lambda (p)
              (when (and (car p) (gethash (car p) table)) (setq seen t))
              (if seen (cons (car p) (car (pai-session--mark-usage-stale (list (cdr p))))) p))
            pairs)))

(defun pai-session-context-pairs (session &optional leaf)
  "Return (ENTRY-ID . MESSAGE) pairs of the context of SESSION's branch to LEAF.
This is `pai-session-context-messages' with each message's source entry; the
compaction summary has a nil id."
  (let* ((branch (pai-session-get-branch session leaf))
         (table (pai-session-replacement-table branch)))
    (pai-session--stale-after-edits (pai-session--context-pairs branch table) table)))

(defun pai-session--context-pairs (branch table)
  "Return the context pairs of BRANCH with replacements from TABLE."
  (let* ((pairs (lambda (entries)
                  (delq nil (mapcar (lambda (e)
                                      (let ((m (pai-session-entry-message e table)))
                                        (and m (cons (plist-get e :id) m))))
                                    entries))))
         (compaction (pai-session--latest-compaction branch)))
    (if (not compaction)
        (funcall pairs branch)
      (let* ((entry (car compaction))
             (before (seq-take branch (cdr compaction)))
             (after (nthcdr (1+ (cdr compaction)) branch))
             (first-kept (plist-get entry :firstKeptEntryId))
             (kept (seq-drop-while (lambda (e) (not (equal (plist-get e :id) first-kept)))
                                   before))
             (system (seq-take-while (lambda (p) (pai-system-message-p (cdr p)))
                                     (funcall pairs before))))
        (append system
                (list (cons nil (pai-session--compaction-message entry)))
                (let ((kp (funcall pairs kept)))
                  (cl-mapcar #'cons (mapcar #'car kp)
                             (pai-session--mark-usage-stale (mapcar #'cdr kp))))
                (funcall pairs after))))))

(defun pai-session-context-messages (session &optional leaf)
  "Return the LLM message list reconstructed from SESSION's branch to LEAF.
The newest replayable compaction on the branch is applied: the leading system
messages are kept, everything else before its first kept entry is replaced by
its summary message.  Context edits (`:replacements') are applied too."
  (mapcar #'cdr (pai-session-context-pairs session leaf)))

(defun pai-session-replacements (session old new &optional leaf)
  "Return the `:replacements' that turn live context OLD into NEW, or `unmirrored'.
OLD must mirror SESSION's context (same length and roles), and NEW must have
one message per message of OLD.  Changed messages without a source entry (a
compaction summary) cannot be recorded and are skipped.  A difference only in
`:usage-stale' is not a change: replay marks stale anchors itself."
  (let ((pairs (pai-session-context-pairs session leaf)))
    (if (not (and (= (length pairs) (length old) (length new))
                  (cl-every (lambda (p m) (eq (pai-message-role (cdr p)) (pai-message-role m)))
                            pairs old)))
        'unmirrored
      (delq nil (cl-mapcar (lambda (p o n)
                             (and (car p)
                                  (not (equal (pai-session--sans-stale o) (pai-session--sans-stale n)))
                                  (list :entryId (car p) :message (pai-session--sans-stale n))))
                           pairs old new)))))

(defun pai-session--sans-stale (message)
  "Return MESSAGE without its `:usage-stale' mark (rebuilt on replay)."
  (if (plist-member message :usage-stale)
      (let ((out '()) (m message))
        (while m
          (unless (eq (car m) :usage-stale) (setq out (append out (list (car m) (cadr m)))))
          (setq m (cddr m)))
        out)
    message))

(defun pai-session-first-kept-entry-id (session kept-count &optional leaf)
  "Return the id of the entry holding the first of the last KEPT-COUNT messages.
The messages counted are those `pai-session-context-messages' would produce
from SESSION's branch to LEAF, so this maps a compaction's kept tail back to
the entries it came from.  Return nil when the branch holds fewer messages
than KEPT-COUNT after its latest compaction, or KEPT-COUNT is not positive:
the live context then does not mirror the session, and the compaction cannot
be recorded as replayable."
  (when (and (integerp kept-count) (> kept-count 0))
    (let* ((branch (pai-session-get-branch session leaf))
           (compaction (pai-session--latest-compaction branch))
           ;; A compaction's kept tail starts at its first kept entry; nothing
           ;; older than that is in the live context any more.
           (floor (and compaction (plist-get (car compaction) :firstKeptEntryId)))
           (n 0) (found nil))
      (catch 'done
        (dolist (e (reverse branch))
          (when (and (pai-session--entry-to-message e)
                     (not (pai-system-message-p (pai-session--entry-to-message e))))
            (setq n (1+ n))
            (when (= n kept-count)
              (setq found (plist-get e :id))
              (throw 'done nil)))
          (when (and floor (equal (plist-get e :id) floor))
            (throw 'done nil))))
      found)))

(defun pai-session-user-prompts (session)
  "Return (ENTRY-ID . TEXT) pairs for each user message on the current branch."
  (delq nil (mapcar (lambda (e)
                      (when (and (equal (plist-get e :type) "message")
                                 (eq (pai-message-role (plist-get e :message)) 'user))
                        (cons (plist-get e :id)
                              (pai-content-text (pai-message-content (plist-get e :message))))))
                    (pai-session-get-branch session))))

(defun pai-session-entry-parent-id (session id)
  "Return the :parentId of entry ID in SESSION, or nil."
  (plist-get (gethash id (pai-session-by-id session)) :parentId))

(defun pai-session-all-user-prompts (session)
  "Return (ENTRY-ID . TEXT) for every user message across SESSION's whole tree.
Unlike `pai-session-user-prompts', this spans every branch, not just the path
to the current leaf, so navigation can jump to abandoned branches."
  (delq nil (mapcar (lambda (e)
                      (when (and (equal (plist-get e :type) "message")
                                 (eq (pai-message-role (plist-get e :message)) 'user))
                        (cons (plist-get e :id)
                              (pai-content-text (pai-message-content (plist-get e :message))))))
                    (pai-session-entries session))))

(defun pai-session--user-entry-p (entry)
  "Return non-nil when ENTRY is a user message."
  (and (equal (plist-get entry :type) "message")
       (eq (pai-message-role (plist-get entry :message)) 'user)))

(defun pai-session--prompt-children (session)
  "Return (ROOTS . CHILDREN) for SESSION's tree of user prompts.
ROOTS are the prompt entries with no earlier prompt on their path;
CHILDREN maps a prompt id to the prompts whose nearest earlier prompt it is.
Both keep session order.  Iterative, so long sessions cannot overflow the
Lisp stack."
  (let ((by-id (pai-session-by-id session))
        (nearest (make-hash-table :test 'equal))   ; entry id -> nearest prompt id at/above
        (children (make-hash-table :test 'equal))
        (roots '()))
    ;; entries are stored parents-first, so one pass resolves every ancestor
    (dolist (e (pai-session-entries session))
      (let* ((id (plist-get e :id))
             (parent (plist-get e :parentId))
             (above (and parent (gethash parent by-id) (gethash parent nearest))))
        (if (pai-session--user-entry-p e)
            (progn
              (if above
                  (puthash above (cons e (gethash above children)) children)
                (push e roots))
              (puthash id id nearest))
          (when above (puthash id above nearest)))))
    (maphash (lambda (k v) (puthash k (nreverse v) children)) children)
    (cons (nreverse roots) children)))

(defun pai-session-prompt-tree (session)
  "Return user-prompt turns of SESSION in pre-order as (ID TEXT DEPTH) triples.
DEPTH is the number of ancestor user prompts, i.e. how deeply the turn is
nested in the branch tree.  Iterative (explicit stack)."
  (let* ((tree (pai-session--prompt-children session))
         (children (cdr tree))
         (stack (mapcar (lambda (e) (cons e 0)) (car tree)))
         (out '()))
    (while stack
      (let* ((top (pop stack)) (e (car top)) (depth (cdr top)))
        (push (list (plist-get e :id)
                    (pai-content-text (pai-message-content (plist-get e :message)))
                    depth)
              out)
        (setq stack (append (mapcar (lambda (c) (cons c (1+ depth)))
                                    (gethash (plist-get e :id) children))
                            stack))))
    (nreverse out)))

(defun pai-session-prompt-outline (session &optional branch-ids)
  "Return SESSION's prompts laid out as a tree for display, in display order.
Each item is a plist (:id :text :indent :fork :on-branch).  A chain of turns
stays at one INDENT; only a fork adds indentation: at a prompt with several
follow-ups the one on the current branch (BRANCH-IDS, a list of entry ids;
else the most recent) continues at the same indent, and every other one
starts a side branch one level deeper, shown right after the fork point.
FORK is non-nil on the first prompt of a side branch.  Iterative."
  (let* ((tree (pai-session--prompt-children session))
         (children (cdr tree))
         (on-branch (let ((h (make-hash-table :test 'equal)))
                      (dolist (id branch-ids) (puthash id t h))
                      h))
         (primary (lambda (kids)
                    (or (seq-find (lambda (k) (gethash (plist-get k :id) on-branch)) kids)
                        (car (last kids)))))
         (stack '())
         (out '()))
    ;; top-level prompts are siblings under a virtual root
    (let* ((roots (car tree)) (main (funcall primary roots)))
      (when main (push (list main 0 nil) stack))
      (dolist (r (reverse (remq main roots))) (push (list r 1 t) stack)))
    (while stack
      (pcase-let ((`(,e ,indent ,fork) (pop stack)))
        (push (list :id (plist-get e :id)
                    :text (pai-content-text (pai-message-content (plist-get e :message)))
                    :indent indent :fork fork
                    :on-branch (and (gethash (plist-get e :id) on-branch) t))
              out)
        (let* ((kids (gethash (plist-get e :id) children))
               (main (funcall primary kids)))
          ;; the continuation pops last, after every side branch
          (when main (push (list main indent nil) stack))
          (dolist (k (reverse (remq main kids)))
            (push (list k (1+ indent) t) stack)))))
    (nreverse out)))

(defun pai-session-turn-leaf (session prompt-id)
  "Return the id of the last entry of PROMPT-ID's turn in SESSION.
Descends through the answer chain (non-user descendants, taking the most recent
at each step) and stops before the next user prompt, so branching there keeps
the turn's assistant answer in context.  Returns PROMPT-ID when there is no
answer yet."
  (let ((children (make-hash-table :test 'equal)))
    (dolist (e (pai-session-entries session))
      (let ((p (plist-get e :parentId)))
        (when p (setf (gethash p children)
                      (append (gethash p children) (list e))))))
    (let ((cur prompt-id))
      (catch 'done
        (while t
          (let ((answer (car (last (seq-remove
                                    (lambda (e)
                                      (and (equal (plist-get e :type) "message")
                                           (eq (pai-message-role (plist-get e :message))
                                               'user)))
                                    (gethash cur children))))))
            (if answer (setq cur (plist-get answer :id)) (throw 'done cur))))))))

(defun pai-session-last-assistant-text (session)
  "Return the text of the last assistant message on SESSION's branch, or nil."
  (let ((text nil))
    (dolist (e (pai-session-get-branch session))
      (when (equal (plist-get e :type) "message")
        (let ((m (plist-get e :message)))
          (when (pai-assistant-message-p m)
            (setq text (pai-content-text (pai-message-content m)))))))
    text))

(defvar pai-session-fork-custom-functions nil
  "Abnormal hook deciding which `custom' entries a fork carries over.
Each function is called with a custom ENTRY of the source branch and ID-MAP,
a hash table from source entry ids to the fork's ids for everything copied
so far.  The first non-nil return value is the data plist to record in the
fork (under the same customType); when every function returns nil the entry
is not copied.  Entry ids inside the data must be translated through ID-MAP.")

(defvar pai-session-fork-functions nil
  "Abnormal hook run with SOURCE and NEW after `pai-session-fork' built NEW.")

(defun pai-session-fork (session entry-id)
  "Create and return a NEW on-disk session replaying SESSION's branch up to ENTRY-ID.
Messages are always copied; `custom' entries only when a function in
`pai-session-fork-custom-functions' claims them."
  (let ((new (pai-session-new (pai-session-cwd session)))
        (branch (pai-session-get-branch session entry-id))
        (id-map (make-hash-table :test 'equal)))
    (when (pai-session-name session)
      (pai-session-set-name new (pai-session-name session)))
    (dolist (e branch)
      (let ((copy
             (pcase (plist-get e :type)
               ("message" (pai-session-append-message new (plist-get e :message)))
               ("custom_message" (pai-session-append new (list :type "custom_message"
                                                               :customType (plist-get e :customType)
                                                               :content (plist-get e :content)
                                                               :display (plist-get e :display))))
               ("custom"
                (let ((data (run-hook-with-args-until-success
                             'pai-session-fork-custom-functions e id-map)))
                  (when data
                    (pai-session-append-custom new (plist-get e :customType) data))))
               (_ nil))))
        (when copy
          (puthash (plist-get e :id) (plist-get copy :id) id-map))))
    (run-hook-with-args 'pai-session-fork-functions session new)
    new))

(provide 'pai-session)
;;; pai-session.el ends here
