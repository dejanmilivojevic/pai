;;; pai-settings-ui.el --- vui-based settings screen for pai -*- lexical-binding: t; -*-

;;; Commentary:

;; A declarative settings screen rendered with vui.el
;; (https://github.com/d12frosted/vui.el).  The screen is organised as a tree:
;;
;;   section  ->  subsection  ->  individual setting
;;
;; Sections are collapsible; each setting renders a type-appropriate control
;; (checkbox, dropdown, text field, or button) that reads through a `:get'
;; thunk and writes through a `:set' thunk, so the screen always reflects the
;; live, merged settings.
;;
;; The registry is open: `pai-settings-ui-register-section',
;; `pai-settings-ui-register-subsection', and `pai-settings-ui-register-item'
;; let extensions add or override entries.  Re-registering an existing id or
;; item key replaces it, so the API is idempotent and merge-friendly.  The
;; built-in sections below cover the core pai settings.
;;
;; Open it with `M-x pai-settings-ui-open' or the `/menu' slash command.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'vui)
(require 'vui-components)
(require 'pai-core)
(require 'pai-settings)
(require 'pai-models)
(require 'pai-model-resolver)
(require 'pai-trust)
(require 'pai-commands)

(declare-function pai--menu-apply "pai-ui" (setter))
(defvar pai--model)
(declare-function pai--menu-current-model "pai-ui" ())
(declare-function pai--menu-current-thinking "pai-ui" ())
(declare-function pai--set-model-id "pai-ui" (id))
(declare-function pai--set-thinking-level "pai-ui" (level))
(declare-function pai-ext-discover "pai-ext" (&optional dirs))
(declare-function pai-ext-enabled-p "pai-ext" (name))
(declare-function pai-ext-override "pai-ext" (name scope))
(declare-function pai-ext-set-enabled "pai-ext" (name enabled scope))
(declare-function pai-ext-clear-override "pai-ext" (name scope))
(declare-function pai-ext-visible-names "pai-ext" (&optional dirs))
(declare-function pai-ext-section-owner "pai-ext" (section-id &optional dirs))

;;;; Registry data model

(cl-defstruct (pai-settings-ui-section
               (:constructor pai-settings-ui--make-section))
  "A top-level settings section."
  id label order subsections)

(cl-defstruct (pai-settings-ui-subsection
               (:constructor pai-settings-ui--make-subsection))
  "A group of settings inside a section.
ITEMS-FN, when set, is a zero-argument function returning a list of item
property lists generated at render time (for entries not known ahead of time)."
  id label order items items-fn)

(cl-defstruct (pai-settings-ui-item
               (:constructor pai-settings-ui--make-item))
  "A single setting.
TYPE is one of `boolean', `choice', `string', `number', `action', or `custom'.
A `custom' item supplies `:render' (a function of REFRESH returning a vnode);
all others use `:get'/`:set' (and `:choices' for `choice', `:action' for
`action').  LABEL and CHOICES may be values or zero-argument functions resolved
at render.  All thunks run in the originating pai session buffer."
  key label type doc order choices get set action size render)

(defvar pai-settings-ui--sections nil
  "Ordered list of registered `pai-settings-ui-section' structs.")

(defvar pai-settings-ui--seq 0
  "Monotonic counter used to derive stable default ordering.")

(defun pai-settings-ui--next-order ()
  "Return the next default order value."
  (setq pai-settings-ui--seq (+ 10 pai-settings-ui--seq)))

(defun pai-settings-ui-visible-sections ()
  "Return the registered sections to show, in order.
A section registered by an extension is hidden when that extension is
disabled and no enabled extension requires it (see `pai-ext-visible-names');
the Extensions section still lists it, to turn it back on."
  (let ((visible (and (fboundp 'pai-ext-visible-names) (pai-ext-visible-names))))
    (seq-filter (lambda (sec)
                  (let ((owner (and (fboundp 'pai-ext-section-owner)
                                    (pai-ext-section-owner (pai-settings-ui-section-id sec)))))
                    (or (null owner) (member owner visible))))
                (pai-settings-ui--sorted pai-settings-ui--sections
                                         #'pai-settings-ui-section-order))))

;;;; Registration API

(defun pai-settings-ui-register-section (id label &optional order)
  "Ensure a section ID exists with LABEL, updating ORDER when given.
Return the `pai-settings-ui-section'."
  (let ((sec (seq-find (lambda (s) (eq (pai-settings-ui-section-id s) id))
                       pai-settings-ui--sections)))
    (if sec
        (progn
          (when label (setf (pai-settings-ui-section-label sec) label))
          (when order (setf (pai-settings-ui-section-order sec) order)))
      (setq sec (pai-settings-ui--make-section
                 :id id :label (or label (symbol-name id))
                 :order (or order (pai-settings-ui--next-order))))
      (setq pai-settings-ui--sections
            (append pai-settings-ui--sections (list sec))))
    sec))

(defun pai-settings-ui-register-subsection (section-id id label &optional order)
  "Ensure subsection ID exists under SECTION-ID with LABEL and ORDER.
The parent section is created on demand.  Return the subsection."
  (let* ((sec (pai-settings-ui-register-section section-id nil))
         (sub (seq-find (lambda (s) (eq (pai-settings-ui-subsection-id s) id))
                        (pai-settings-ui-section-subsections sec))))
    (if sub
        (progn
          (when label (setf (pai-settings-ui-subsection-label sub) label))
          (when order (setf (pai-settings-ui-subsection-order sub) order)))
      (setq sub (pai-settings-ui--make-subsection
                 :id id :label (or label (symbol-name id))
                 :order (or order (pai-settings-ui--next-order))))
      (setf (pai-settings-ui-section-subsections sec)
            (append (pai-settings-ui-section-subsections sec) (list sub))))
    sub))

(defun pai-settings-ui-register-item (section-id subsection-id &rest props)
  "Register a setting under SECTION-ID/SUBSECTION-ID from PROPS.
PROPS is a plist accepting `pai-settings-ui-item' slots (`:key' required).
Re-registering the same `:key' in the subsection replaces the entry.  Parent
section and subsection are created on demand.  Return the item."
  (let* ((sub (pai-settings-ui-register-subsection
               section-id subsection-id nil))
         (item (apply #'pai-settings-ui--make-item props))
         (key (pai-settings-ui-item-key item))
         (items (pai-settings-ui-subsection-items sub))
         (existing (seq-find (lambda (i) (equal (pai-settings-ui-item-key i) key))
                             items)))
    (unless (pai-settings-ui-item-order item)
      (setf (pai-settings-ui-item-order item) (pai-settings-ui--next-order)))
    (setf (pai-settings-ui-subsection-items sub)
          (if existing
              (mapcar (lambda (i) (if (eq i existing) item i)) items)
            (append items (list item))))
    item))

(defun pai-settings-ui-register-dynamic-items (section-id subsection-id fn)
  "Register FN as the dynamic item generator for SECTION-ID/SUBSECTION-ID.
FN takes no arguments and returns a list of item property lists (as accepted by
`pai-settings-ui-register-item') built fresh on each render.  Use this for
entries not known ahead of time (e.g. one row per discovered item).  Parent
section and subsection are created on demand."
  (let ((sub (pai-settings-ui-register-subsection section-id subsection-id nil)))
    (setf (pai-settings-ui-subsection-items-fn sub) fn)
    sub))

;;;; Rendering helpers

;; The pai settings state (`pai-settings--project', `pai--models', subagent
;; roles, ...) is buffer-local to each pai session (see
;; `pai-ext--instance-variables').  The screen renders in its own buffer, so
;; every get/set/choices/dynamic-item thunk MUST run in the originating session
;; buffer or it would read and write the wrong (global) bindings.
(defvar-local pai-settings-ui--target-buffer nil
  "The pai session buffer whose settings this screen edits.")
;; survive the `kill-all-local-variables' that `vui-mode' runs on mount
(put 'pai-settings-ui--target-buffer 'permanent-local t)

(defun pai-settings-ui--target ()
  "Return the buffer settings thunks should run in."
  (if (buffer-live-p pai-settings-ui--target-buffer)
      pai-settings-ui--target-buffer
    (current-buffer)))

(defun pai-settings-ui--call (fn &rest args)
  "Apply FN to ARGS inside the target session buffer."
  (when fn (with-current-buffer (pai-settings-ui--target) (apply fn args))))

(defun pai-settings-ui--resolve (value)
  "Return VALUE, calling it first (in the target buffer) when it is a function."
  (if (functionp value) (pai-settings-ui--call value) value))

(defun pai-settings-ui--sorted (items order-fn)
  "Return ITEMS sorted ascending by ORDER-FN."
  (sort (copy-sequence items)
        (lambda (a b) (< (funcall order-fn a) (funcall order-fn b)))))

(defun pai-settings-ui--field-display (item)
  "Return the current value of ITEM formatted for a text field."
  (let ((v (pai-settings-ui--call (pai-settings-ui-item-get item))))
    (cond ((null v) "")
          ((numberp v) (number-to-string v))
          (t (format "%s" v)))))

(defun pai-settings-ui--parse (item raw)
  "Coerce RAW field text into a value appropriate for ITEM's type."
  (let ((s (string-trim (or raw ""))))
    (pcase (pai-settings-ui-item-type item)
      ('number (unless (string-empty-p s)
                 (if (string-match-p "\\." s)
                     (string-to-number s)
                   (truncate (string-to-number s)))))
      (_ (if (string-empty-p s) nil s)))))

;;;; Rows
;;
;; One row per setting: a marker (• = saved in a settings file), the label
;; in a column sized to the labels on screen, the control, and the
;; description cut to one line (the full text is the tooltip).

(defcustom pai-settings-ui-start-expanded nil
  "Non-nil to open the settings screen with every section expanded.
By default sections start collapsed, showing how many settings they hold,
and the screen remembers which ones you opened.  A search shows every match."
  :type 'boolean :group 'pai)

(defface pai-settings-ui-section-face '((t :inherit (bold font-lock-function-name-face)))
  "Face of section titles on the settings screen.")

(defface pai-settings-ui-saved-face '((t :inherit warning))
  "Face of the marker of a setting saved in a settings file.")

(defvar pai-settings-ui--label-width 26
  "Width of the label column; set on every render from the labels.")

(defvar pai-settings-ui--doc-width 60
  "Width descriptions are cut to; set on every render from the window.")

(defun pai-settings-ui--one-line (text width)
  "Return TEXT on one line, cut to WIDTH columns with an ellipsis."
  (truncate-string-to-width
   (string-trim (replace-regexp-in-string "[ \t\n]+" " " (or text "")))
   (max 10 width) nil nil "…"))

(defun pai-settings-ui--saved-in (item)
  "Return the settings file ITEM's value is saved in (`project', `global'), or nil.
Only items whose key is itself a settings key can tell."
  (let ((key (pai-settings-ui-item-key item)))
    (and (keywordp key)
         (pai-settings-ui--call
          (lambda ()
            (cond ((plist-member pai-settings--project key) 'project)
                  ((plist-member pai-settings--global key) 'global)))))))

(defun pai-settings-ui--labeled (label control doc &optional item)
  "Lay out LABEL, its CONTROL and DOC (cut to one line) on one row.
ITEM, when given, is marked when its value is saved in a settings file."
  (let* ((saved (and item (pai-settings-ui--saved-in item)))
         (width pai-settings-ui--label-width)
         (shown (truncate-string-to-width (or label "") (- width 2) nil nil "…")))
    (apply #'vui-hstack
           (delq nil
                 (list (vui-text (if saved "•" " ")
                         :face 'pai-settings-ui-saved-face
                         :help-echo (and saved (format "Saved in the %s settings file" saved)))
                       (vui-box (vui-text shown :help-echo (unless (equal shown label) label))
                                :width (1- width) :align :left)
                       control
                       (and doc (not (string-empty-p doc))
                            (vui-text (concat " " (pai-settings-ui--one-line
                                                   doc pai-settings-ui--doc-width))
                              :face 'shadow :help-echo doc)))))))

(defun pai-settings-ui--render-item (item refresh)
  "Render setting ITEM to a vnode.  REFRESH re-renders the screen after edits.
All value reads and writes run in the target session buffer."
  (let* ((type (pai-settings-ui-item-type item))
         (label (pai-settings-ui--resolve (pai-settings-ui-item-label item)))
         (doc (pai-settings-ui-item-doc item))
         (get (pai-settings-ui-item-get item))
         (set (pai-settings-ui-item-set item))
         (setter (lambda (v)
                   (pai-settings-ui--call set v)
                   (funcall refresh))))
    (pcase type
      ('custom
       (pai-settings-ui--call (pai-settings-ui-item-render item) refresh))
      ('action
       (apply #'vui-hstack
              (delq nil
                    (list (vui-text " ")
                          (vui-button label
                                      :on-click (lambda ()
                                                  (pai-settings-ui--call
                                                   (pai-settings-ui-item-action item))
                                                  (funcall refresh)))
                          (and doc (vui-text (concat " " (pai-settings-ui--one-line
                                                          doc pai-settings-ui--doc-width))
                                     :face 'shadow :help-echo doc))))))
      ('boolean
       (pai-settings-ui--labeled
        label
        (vui-checkbox :checked (pai-truthy (pai-settings-ui--call get))
                      :on-change setter)
        doc item))
      ('choice
       (pai-settings-ui--labeled
        label
        (vui-select :value (format "%s" (or (pai-settings-ui--call get) ""))
                    :options (pai-settings-ui--resolve
                              (pai-settings-ui-item-choices item))
                    :on-change setter)
        doc item))
      ((or 'string 'number)
       (let ((fkey (format "pai-set-%s" (pai-settings-ui-item-key item))))
         (pai-settings-ui--labeled
          label
          (vui-field :key fkey
                     :value (pai-settings-ui--field-display item)
                     :size (or (pai-settings-ui-item-size item) 24)
                     :on-submit (lambda (&optional value)
                                  (pai-settings-ui--call
                                   set (pai-settings-ui--parse
                                        item (or value (vui-field-value fkey))))
                                  (funcall refresh)))
          doc item)))
      (_ (vui-text (format "%s: unsupported type %s" label type))))))

(defun pai-settings-ui--subsection-all-items (sub)
  "Return SUB's static items (sorted) followed by its dynamic items.
The dynamic generator runs in the target session buffer."
  (append (pai-settings-ui--sorted (pai-settings-ui-subsection-items sub)
                                   #'pai-settings-ui-item-order)
          (when (pai-settings-ui-subsection-items-fn sub)
            (mapcar (lambda (p) (apply #'pai-settings-ui--make-item p))
                    (pai-settings-ui--call
                     (pai-settings-ui-subsection-items-fn sub))))))

;;;; The tree, searched

(defun pai-settings-ui--tree ()
  "Return the visible settings as ((SECTION (SUB . ITEMS) ...) ...), in order."
  (mapcar (lambda (sec)
            (cons sec
                  (mapcar (lambda (sub) (cons sub (pai-settings-ui--subsection-all-items sub)))
                          (pai-settings-ui--sorted (pai-settings-ui-section-subsections sec)
                                                   #'pai-settings-ui-subsection-order))))
          (pai-settings-ui-visible-sections)))

(defun pai-settings-ui--haystack (sec sub item)
  "Return the lower-case text a search matches ITEM of SEC/SUB against."
  (downcase
   (mapconcat (lambda (x) (format "%s" (or x "")))
              (list (pai-settings-ui--resolve (pai-settings-ui-section-label sec))
                    (pai-settings-ui--resolve (pai-settings-ui-subsection-label sub))
                    (pai-settings-ui--resolve (pai-settings-ui-item-label item))
                    (pai-settings-ui-item-doc item)
                    (pai-settings-ui-item-key item))
              " ")))

(defun pai-settings-ui-matches-p (query sec sub item)
  "Return non-nil when every word of QUERY occurs in ITEM of SEC/SUB.
Label, description, section, subsection and key are searched, ignoring case."
  (let ((hay (pai-settings-ui--haystack sec sub item)))
    (seq-every-p (lambda (w) (string-search w hay))
                 (split-string (downcase query) nil t))))

(defun pai-settings-ui--filter (tree query)
  "Return TREE with only the items matching QUERY; empty groups dropped."
  (delq nil
        (mapcar (lambda (s)
                  (let ((subs (delq nil
                                    (mapcar (lambda (g)
                                              (let ((items (seq-filter
                                                            (lambda (i) (pai-settings-ui-matches-p
                                                                         query (car s) (car g) i))
                                                            (cdr g))))
                                                (and items (cons (car g) items))))
                                            (cdr s)))))
                    (and subs (cons (car s) subs))))
                tree)))

(defun pai-settings-ui--count (entry)
  "Return how many settings tree ENTRY (SECTION (SUB . ITEMS) ...) holds."
  (apply #'+ (mapcar (lambda (g) (length (cdr g))) (cdr entry))))

(defun pai-settings-ui--set-widths (tree)
  "Size the label and description columns for TREE and the window."
  (let ((longest (apply #'max 12
                        (mapcar (lambda (i) (string-width
                                             (format "%s" (or (pai-settings-ui--resolve
                                                               (pai-settings-ui-item-label i))
                                                              ""))))
                                (mapcan (lambda (s) (mapcan (lambda (g) (copy-sequence (cdr g)))
                                                            (cdr s)))
                                        tree))))
        (win (get-buffer-window (current-buffer) t)))
    (setq pai-settings-ui--label-width (min 32 (+ 3 longest))
          pai-settings-ui--doc-width (max 40 (- (if win (window-body-width win) 120)
                                                pai-settings-ui--label-width 24)))))

;;;; Open sections

(defvar-local pai-settings-ui--open :unset
  "Open sections (ids) and advanced subsections ((SECTION . SUB) ids), or t for all.")
(put 'pai-settings-ui--open 'permanent-local t)

(defvar-local pai-settings-ui--query ""
  "The search text of this settings screen.")
(put 'pai-settings-ui--query 'permanent-local t)

(defvar-local pai-settings-ui--instance nil
  "The mounted settings screen of this buffer.")
(put 'pai-settings-ui--instance 'permanent-local t)

(defun pai-settings-ui--open-p (id)
  "Return non-nil when section or subsection ID is expanded."
  (when (eq pai-settings-ui--open :unset)
    (setq pai-settings-ui--open (and pai-settings-ui-start-expanded t)))
  (or (eq pai-settings-ui--open t) (member id pai-settings-ui--open)))

(defun pai-settings-ui--set-open (id open)
  "Expand section or subsection ID when OPEN, else collapse it."
  (let ((cur (if (eq pai-settings-ui--open t)
                 (mapcar #'pai-settings-ui-section-id (pai-settings-ui-visible-sections))
               (and (listp pai-settings-ui--open) pai-settings-ui--open))))
    (setq pai-settings-ui--open (if open (cons id (remove id cur)) (remove id cur)))))

(defun pai-settings-ui--advanced-p (sub)
  "Return non-nil when subsection SUB holds advanced settings (shown collapsed)."
  (string-prefix-p "Advanced" (format "%s" (pai-settings-ui--resolve
                                            (pai-settings-ui-subsection-label sub)))))

;;;; Rendering

(defun pai-settings-ui--render-items (items refresh)
  "Return ITEMS rendered, stacked."
  (apply #'vui-vstack (mapcar (lambda (i) (pai-settings-ui--render-item i refresh)) items)))

(defun pai-settings-ui--render-subsection (sec sub items refresh)
  "Render subsection SUB of SEC with ITEMS; advanced ones collapse."
  (let ((label (pai-settings-ui--resolve (pai-settings-ui-subsection-label sub)))
        (id (cons (pai-settings-ui-section-id sec) (pai-settings-ui-subsection-id sub))))
    (if (pai-settings-ui--advanced-p sub)
        (vui-collapsible
         :title (format "%s  (%d)" label (length items)) :key id :indent 1
         :title-face 'bold
         :expanded (and (pai-settings-ui--open-p id) t)
         :on-toggle (lambda (on) (pai-settings-ui--set-open id on) (funcall refresh))
         ;; rows are only built when shown: some probe the system
         (when (pai-settings-ui--open-p id) (pai-settings-ui--render-items items refresh)))
      (vui-vstack
       (vui-text label :face 'bold)
       (pai-settings-ui--render-items items refresh)))))

(defun pai-settings-ui--render-section (entry refresh)
  "Render tree ENTRY (SECTION (SUB . ITEMS) ...) as a collapsible section."
  (let* ((sec (car entry))
         (id (pai-settings-ui-section-id sec)))
    (apply #'vui-collapsible
           :title (format "%s  (%d)" (pai-settings-ui--resolve (pai-settings-ui-section-label sec))
                          (pai-settings-ui--count entry))
           :key id
           :title-face 'pai-settings-ui-section-face
           :expanded (and (pai-settings-ui--open-p id) t)
           :on-toggle (lambda (on) (pai-settings-ui--set-open id on) (funcall refresh))
           ;; rows are only built when shown: some probe the system
           ;; (executables, libraries) and a collapsed section would pay anyway
           (and (pai-settings-ui--open-p id)
                (mapcar (lambda (g) (pai-settings-ui--render-subsection sec (car g) (cdr g) refresh))
                        (cdr entry))))))

(defun pai-settings-ui--render-matches (entry refresh)
  "Render the search matches of tree ENTRY, grouped as Section › Subsection."
  (let ((sec (car entry)))
    (apply #'vui-vstack
           (mapcan (lambda (g)
                     (list (vui-text (format "%s › %s"
                                             (pai-settings-ui--resolve (pai-settings-ui-section-label sec))
                                             (pai-settings-ui--resolve (pai-settings-ui-subsection-label (car g))))
                             :face 'pai-settings-ui-section-face)
                           (pai-settings-ui--render-items (cdr g) refresh)))
                   (cdr entry)))))

(defconst pai-settings-ui--search-key "pai-settings-search"
  "The `:key' of the search field.")

(defconst pai-settings-ui--help
  "/ search · RET open, toggle, apply · TAB next · E expand/collapse all · g refresh · q quit    • saved in a settings file"
  "The key hints under the search field.")

;;;; Screen component and entry point

(vui-defcomponent pai-settings-screen ()
  "The pai settings screen.  Its `rev' state forces a re-render after edits."
  :state ((rev 0))
  :render
  (let* ((refresh (lambda () (vui-set-state :rev (1+ rev))))
         (raw (or pai-settings-ui--query ""))
         (query (string-trim raw))
         (tree (pai-settings-ui--tree))
         (searching (not (string-empty-p query)))
         (matches (and searching (pai-settings-ui--filter tree query))))
    (pai-settings-ui--set-widths tree)
    (apply #'vui-vstack :spacing 1
           (append
            (list (vui-heading-1
                   (format "pai settings — %s" (abbreviate-file-name default-directory)))
                  (apply #'vui-hstack
                         (delq nil
                               (list (vui-text "Search" :face 'bold)
                                     (vui-field :key pai-settings-ui--search-key
                                                :value raw :size 36
                                                :placeholder "e.g. compact, model, memory budget"
                                                :on-change (lambda (v)
                                                             (setq pai-settings-ui--query (or v ""))
                                                             (funcall refresh)))
                                     (and searching
                                          (vui-muted (format "%d match%s" (apply #'+ (mapcar #'pai-settings-ui--count matches))
                                                             (if (= 1 (apply #'+ (mapcar #'pai-settings-ui--count matches))) "" "es")))))))
                  (vui-muted pai-settings-ui--help))
            (cond
             ((and searching (null matches))
              (list (vui-muted (format "No setting matches \"%s\"." query))))
             (searching
              (mapcar (lambda (e) (pai-settings-ui--render-matches e refresh)) matches))
             (t (mapcar (lambda (e) (pai-settings-ui--render-section e refresh)) tree)))))))

(defun pai-settings-ui-search ()
  "Move to the search field of the settings screen."
  (interactive)
  (when (vui-goto-key pai-settings-ui--search-key)
    (forward-char (length pai-settings-ui--query))))

(defun pai-settings-ui-toggle-all ()
  "Expand every section, or collapse them all when any is open."
  (interactive)
  (setq pai-settings-ui--open
        (if (and (not (eq pai-settings-ui--open :unset)) pai-settings-ui--open) nil t))
  (when pai-settings-ui--instance (vui-rerender pai-settings-ui--instance)))

(defvar pai-settings-ui-keys
  (let ((m (make-sparse-keymap)))
    (define-key m "/" #'pai-settings-ui-search)
    (define-key m "E" #'pai-settings-ui-toggle-all)
    m)
  "Keys of the settings screen, on top of vui's.")

;;;###autoload
(defun pai-settings-ui-open ()
  "Open the pai settings screen rendered with vui.
Edits target the pai session buffer this command was invoked from (or any live
`pai-mode' buffer), whose settings state is buffer-local."
  (interactive)
  (let* ((origin (if (derived-mode-p 'pai-mode)
                     (current-buffer)
                   (and (fboundp 'pai--menu-buffer) (pai--menu-buffer))))
         (dir default-directory)
         (buf (get-buffer-create "*pai settings*")))
    (with-current-buffer buf
      (setq default-directory (if (buffer-live-p origin)
                                  (buffer-local-value 'default-directory origin)
                                dir))
      ;; set the target BEFORE mounting so the first render already reads and
      ;; writes the session's buffer-local settings
      (setq pai-settings-ui--target-buffer origin
            pai-settings-ui--query ""))
    (let ((inst (vui-mount (vui-component 'pai-settings-screen) "*pai settings*")))
      (with-current-buffer (vui-instance-buffer inst)
        (setq pai-settings-ui--instance inst)
        (use-local-map (make-composed-keymap pai-settings-ui-keys (current-local-map))))
      (pop-to-buffer (vui-instance-buffer inst)))))

;;;; Built-in sections

(defun pai-settings-ui--apply (fn)
  "Apply FN inside the live pai session buffer when one exists."
  (if (fboundp 'pai--menu-apply) (pai--menu-apply fn) (funcall fn)))

(defun pai-settings-ui--current-model ()
  "Return the model id to display, preferring the live session buffer."
  (if (fboundp 'pai--menu-current-model)
      (pai--menu-current-model)
    (or (pai-settings-get :model) "none")))

(defun pai-settings-ui--current-thinking ()
  "Return the thinking level to display, preferring the live session buffer."
  (if (fboundp 'pai--menu-current-thinking)
      (pai--menu-current-thinking)
    (pai-settings-get :thinking-level "off")))

(defun pai-settings-ui--scoped-model-items ()
  "Return two settings rows per scoped-model role (built-in and extension).
The first picks a model or `inherit', the second a thinking level or
`inherit'; their notes say what the role is for and what it resolves to
right now."
  (let ((session-model (and (boundp 'pai--model) pai--model (pai-model-key pai--model)))
        (choices (cons pai-scoped-model-inherit (pai-model-keys)))
        (levels (cons pai-scoped-model-inherit pai-thinking-levels)))
    (mapcan
     (lambda (role)
       (let ((name (pai-model-role-name role)))
         (list
          (list :key (intern (concat ":scoped-" name))
                :type 'choice
                :label name
                :doc (concat (or (alist-get role pai-model-role-descriptions) "")
                             (unless (pai-scoped-model-explicit role)
                               (concat " · " (pai-scoped-model-describe role session-model))))
                :choices choices
                :get (lambda () (or (pai-scoped-model-explicit role) pai-scoped-model-inherit))
                :set (lambda (v) (pai-scoped-model-set role v)))
          (list :key (intern (concat ":scoped-thinking-" name))
                :type 'choice
                :label (concat name " thinking")
                :doc (concat "Thinking level of " name " runs"
                             (unless (pai-scoped-thinking-explicit role)
                               (concat " · " (pai-scoped-thinking-describe role))))
                :choices levels
                :get (lambda () (or (pai-scoped-thinking-explicit role) pai-scoped-model-inherit))
                :set (lambda (v) (pai-scoped-thinking-set role v))))))
     pai-model-roles)))

(defun pai-settings-ui--register-builtins ()
  "Register the built-in settings sections.  Idempotent."
  (pai-settings-ui-register-section 'model "Model & Reasoning" 10)
  (pai-settings-ui-register-subsection 'model 'model "Model" 10)
  (pai-settings-ui-register-subsection 'model 'scoped "Scoped models (per role)" 15)
  (pai-settings-ui-register-dynamic-items 'model 'scoped #'pai-settings-ui--scoped-model-items)
  (pai-settings-ui-register-subsection 'model 'sampling "Sampling" 20)
  (pai-settings-ui-register-item
   'model 'model
   :key :model :type 'choice :label "Model"
   :doc "Active model for this project"
   :choices (lambda () (pai-model-keys))
   :get #'pai-settings-ui--current-model
   :set (lambda (v)
          (pai-settings-set :model v 'project)
          (pai-settings-ui--apply (lambda () (pai--set-model-id v)))))
  (pai-settings-ui-register-item
   'model 'model
   :key :thinking-level :type 'choice :label "Thinking level"
   :doc "Reasoning effort"
   :choices (lambda () pai-thinking-levels)
   :get #'pai-settings-ui--current-thinking
   :set (lambda (v)
          (pai-settings-set :thinking-level v 'project)
          (pai-settings-ui--apply (lambda () (pai--set-thinking-level v)))))
  (pai-settings-ui-register-item
   'model 'sampling
   :key :temperature :type 'number :label "Temperature"
   :doc "Sampling temperature; blank = provider default"
   :get (lambda () (pai-settings-get :temperature))
   :set (lambda (v) (pai-settings-set :temperature v 'project)))
  (pai-settings-ui-register-item
   'model 'sampling
   :key :max-tokens :type 'number :label "Max tokens"
   :doc "Maximum output tokens; blank = provider default"
   :get (lambda () (pai-settings-get :max-tokens))
   :set (lambda (v) (pai-settings-set :max-tokens v 'project)))

  (pai-settings-ui-register-section 'session "Session" 20)
  (pai-settings-ui-register-subsection 'session 'execution "Execution" 10)
  (pai-settings-ui-register-subsection 'session 'context "Context" 20)
  (pai-settings-ui-register-subsection 'session 'output "Output" 30)
  (pai-settings-ui-register-item
   'session 'execution
   :key :tool-execution :type 'choice :label "Tool execution"
   :doc "Run tool calls in parallel or one at a time"
   :choices '("parallel" "sequential")
   :get (lambda () (or (pai-settings-get :tool-execution) "parallel"))
   :set (lambda (v) (pai-settings-set :tool-execution v 'project)))
  (pai-settings-ui-register-item
   'session 'context
   :key :auto-compact :type 'boolean :label "Auto-compact"
   :doc "Automatically compact context when it grows large"
   :get (lambda () (pai-settings-get :auto-compact t))
   :set (lambda (v) (pai-settings-set :auto-compact (if v t :false) 'project)))
  (pai-settings-ui-register-item
   'session 'context
   :key :compact-threshold :type 'number :label "Compact threshold"
   :doc "Fraction of the context window that triggers compaction"
   :get (lambda () (pai-settings-get :compact-threshold))
   :set (lambda (v) (pai-settings-set :compact-threshold v 'project)))
  (pai-settings-ui-register-item
   'session 'output
   :key :stream-chunks :type 'boolean :label "Stream chunks"
   :doc "Render assistant output incrementally as it streams"
   :get (lambda () (pai-settings-get :stream-chunks t))
   :set (lambda (v) (pai-settings-set :stream-chunks (if v t :false) 'project)))
  (pai-settings-ui-register-item
   'session 'output
   :key :preview-resume :type 'boolean :label "Preview in /resume"
   :doc "Show the session under the cursor while choosing (C-c C-f toggles it there)"
   :get (lambda () (pai-truthy (pai-settings-get :preview-resume nil)))
   :set (lambda (v) (pai-settings-set :preview-resume (if v t :false))))
  (pai-settings-ui-register-item
   'session 'output
   :key :preview-tree :type 'boolean :label "Preview in /tree"
   :doc "Scroll to where the turn under the cursor ends while choosing (C-c C-f toggles it there)"
   :get (lambda () (pai-truthy (pai-settings-get :preview-tree nil)))
   :set (lambda (v) (pai-settings-set :preview-tree (if v t :false))))
  (pai-settings-ui-register-item
   'session 'output
   :key :footer-position :type 'choice :label "Footer position"
   :doc "Where status widgets and the extension footer show: mode line or above the prompt"
   :choices '("mode-line" "above-prompt")
   :get (lambda () (or (pai-settings-get :footer-position) "mode-line"))
   :set (lambda (v) (pai-settings-set :footer-position v 'project)))
  (pai-settings-ui-register-item
   'session 'output
   :key :theme :type 'string :label "Theme"
   :doc "Named pai theme"
   :get (lambda () (pai-settings-get :theme))
   :set (lambda (v) (pai-settings-set :theme v 'project)))

  (pai-settings-ui-register-section 'project "Project" 30)
  (pai-settings-ui-register-subsection 'project 'trust "Trust" 10)
  (pai-settings-ui-register-item
   'project 'trust
   :key :trust :type 'boolean :label "Trust this project"
   :doc "Allow tool execution without per-action prompts"
   :get (lambda () (eq (pai-trust-get default-directory) 'yes))
   :set (lambda (v) (pai-trust-set default-directory v)))

  (pai-settings-ui-register-section 'files "Files" 40)
  (pai-settings-ui-register-subsection 'files 'actions "JSON files" 10)
  (pai-settings-ui-register-item
   'files 'actions
   :key 'edit-global :type 'action :label "Edit global settings file"
   :action (lambda () (find-file (pai-settings-global-file))))
  (pai-settings-ui-register-item
   'files 'actions
   :key 'edit-project :type 'action :label "Edit project settings file"
   :action (lambda () (find-file (pai-settings-project-file)))))

;;;; Extensions section

(defun pai-settings-ui--ext-label (entry)
  "Return a display label for discovered extension ENTRY."
  (let ((name (plist-get entry :name)))
    (format "%s  (%s, effective: %s)"
            name (plist-get entry :source)
            (if (pai-ext-enabled-p name) "enabled" "disabled"))))

(defun pai-settings-ui--ext-global-items ()
  "Return one global on/off item per discovered extension."
  (mapcar
   (lambda (entry)
     (let ((name (plist-get entry :name)))
       (list :key (intern (format ":ext-global/%s" name))
             :type 'boolean
             :label (pai-settings-ui--ext-label entry)
             :get (lambda () (if (eq (pai-ext-override name 'global) 'disabled) :false t))
             :set (lambda (v) (pai-ext-set-enabled name (pai-truthy v) 'global)))))
   (pai-ext-discover)))

(defun pai-settings-ui--ext-project-items ()
  "Return one project override item per discovered extension (project only)."
  (when pai-settings--project-dir
    (mapcar
     (lambda (entry)
       (let ((name (plist-get entry :name)))
         (list :key (intern (format ":ext-project/%s" name))
               :type 'choice
               :label name
               :choices '("inherit" "enabled" "disabled")
               :get (lambda () (pcase (pai-ext-override name 'project)
                                 ('enabled "enabled") ('disabled "disabled") (_ "inherit")))
               :set (lambda (v) (pcase v
                                  ("enabled" (pai-ext-set-enabled name t 'project))
                                  ("disabled" (pai-ext-set-enabled name nil 'project))
                                  (_ (pai-ext-clear-override name 'project)))))))
     (pai-ext-discover))))

(defun pai-settings-ui--register-extensions ()
  "Register the Extensions section (global toggles + project overrides)."
  (pai-settings-ui-register-section 'extensions "Extensions" 45)
  (pai-settings-ui-register-subsection 'extensions 'overview "Overview" 5)
  (pai-settings-ui-register-item
   'extensions 'overview
   :key :ext-note :type 'custom :order 1
   :render (lambda (_refresh)
             (vui-muted (concat "New extensions are enabled by default. "
                                "Changes apply on the next session or /reload. "
                                "Project overrides take priority over global."))))
  (pai-settings-ui-register-subsection 'extensions 'global "Global (all projects)" 10)
  (pai-settings-ui-register-dynamic-items
   'extensions 'global #'pai-settings-ui--ext-global-items)
  (pai-settings-ui-register-subsection 'extensions 'project "Project overrides (priority)" 20)
  (pai-settings-ui-register-dynamic-items
   'extensions 'project #'pai-settings-ui--ext-project-items))

(pai-settings-ui--register-extensions)

(pai-settings-ui--register-builtins)

(provide 'pai-settings-ui)
;;; pai-settings-ui.el ends here
