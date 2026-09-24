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

(defun pai-settings-ui--labeled (label control doc)
  "Lay out a fixed-width LABEL, its CONTROL, and optional DOC on one row."
  (apply #'vui-hstack
         (delq nil
               (list (vui-box (vui-text label) :width 22 :align :left)
                     control
                     (and doc (vui-muted (concat "  " doc)))))))

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
                    (list (vui-button label
                                      :on-click (lambda ()
                                                  (pai-settings-ui--call
                                                   (pai-settings-ui-item-action item))
                                                  (funcall refresh)))
                          (and doc (vui-muted (concat "  " doc)))))))
      ('boolean
       (pai-settings-ui--labeled
        label
        (vui-checkbox :checked (pai-truthy (pai-settings-ui--call get))
                      :on-change setter)
        doc))
      ('choice
       (pai-settings-ui--labeled
        label
        (vui-select :value (format "%s" (or (pai-settings-ui--call get) ""))
                    :options (pai-settings-ui--resolve
                              (pai-settings-ui-item-choices item))
                    :on-change setter)
        doc))
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
          (concat (or doc "") (and doc "  ") "(RET applies)"))))
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

(defun pai-settings-ui--render-subsection (sub refresh)
  "Render subsection SUB (heading plus its items).  REFRESH re-renders."
  (vui-vstack
   (vui-heading-2 (pai-settings-ui--resolve
                   (pai-settings-ui-subsection-label sub)))
   (apply #'vui-vstack :indent 2
          (mapcar (lambda (i) (pai-settings-ui--render-item i refresh))
                  (pai-settings-ui--subsection-all-items sub)))))

(defun pai-settings-ui--render-section (sec refresh)
  "Render section SEC as a collapsible containing its subsections."
  (apply #'vui-collapsible
         :title (pai-settings-ui--resolve (pai-settings-ui-section-label sec))
         :key (pai-settings-ui-section-id sec)
         :initially-expanded t
         (mapcar (lambda (s) (pai-settings-ui--render-subsection s refresh))
                 (pai-settings-ui--sorted
                  (pai-settings-ui-section-subsections sec)
                  #'pai-settings-ui-subsection-order))))

;;;; Screen component and entry point

(vui-defcomponent pai-settings-screen ()
  "The pai settings screen.  Its `rev' state forces a re-render after edits."
  :state ((rev 0))
  :render
  (let ((refresh (lambda () (vui-set-state :rev (1+ rev)))))
    (apply #'vui-vstack :spacing 1
           (append
            (list (vui-heading-1
                   (format "pai settings — %s"
                           (abbreviate-file-name default-directory)))
                  (vui-muted "TAB/S-TAB move · RET toggle/apply · g refresh · q quit"))
            (mapcar (lambda (sec) (pai-settings-ui--render-section sec refresh))
                    (pai-settings-ui-visible-sections))))))

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
      (setq pai-settings-ui--target-buffer origin))
    (let ((inst (vui-mount (vui-component 'pai-settings-screen) "*pai settings*")))
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
  "Return one settings row per scoped-model role (built-in and extension).
Each row picks a model or `inherit'; its note says what the role is for and
which model it resolves to right now."
  (let ((session-model (and (boundp 'pai--model) pai--model (pai-model-key pai--model)))
        (choices (cons pai-scoped-model-inherit (pai-model-keys))))
    (mapcar
     (lambda (role)
       (list :key (intern (concat ":scoped-" (pai-model-role-name role)))
             :type 'choice
             :label (pai-model-role-name role)
             :doc (concat (or (alist-get role pai-model-role-descriptions) "")
                          (unless (pai-scoped-model-explicit role)
                            (concat " · " (pai-scoped-model-describe role session-model))))
             :choices choices
             :get (lambda () (or (pai-scoped-model-explicit role) pai-scoped-model-inherit))
             :set (lambda (v) (pai-scoped-model-set role v))))
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
