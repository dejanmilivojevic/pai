;;; pai-prompt.el --- System prompt assembly -*- lexical-binding: t; -*-

;;; Commentary:

;; Assemble the system prompt from ordered, XML-tagged sections, mirroring
;; packages/coding-agent/src/core/system-prompt.ts.  Sections: preamble, tools,
;; rules, docs, project_context, skills, cwd, addendum, plus any extra named
;; sections supplied by extensions.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pai-tools)
(require 'pai-skills)

(defcustom pai-system-preamble
  "You are pai, an expert coding assistant operating inside Emacs.

You use Emacs itself as your operating system. In addition to running shell
commands and editing files, you can evaluate Emacs Lisp to inspect and drive
the live editor: read and modify buffers, call any Emacs function, query
editor state, and use installed packages. Prefer the dedicated tools for
common file operations, and reach for elisp_eval when Emacs' own facilities
are the most direct way to accomplish a task.

Work carefully: understand before changing, make minimal precise edits, and
verify your work."
  "The opening section of the system prompt."
  :type 'string :group 'pai)

(defcustom pai-system-rules
  '("Use the read tool to inspect files instead of cat or sed."
    "Use edit for precise changes; each oldText must match exactly and uniquely."
    "Use write only for new files or complete rewrites."
    "Use grep and find (or bash) to explore the project."
    "Use elisp_eval to inspect or manipulate Emacs buffers and editor state."
    "Be concise. Show file paths clearly when working with files."
    "After making changes, verify them (run tests or re-read the file).")
  "Default behavioral rules included in the system prompt."
  :type '(repeat string) :group 'pai)

(defun pai-prompt--section (name body)
  "Return an XML section string named NAME wrapping BODY, or nil if BODY empty."
  (when (and body (not (string-empty-p (string-trim body))))
    (format "<%s>\n%s\n</%s>" name (string-trim-right body) name)))

(defun pai-prompt--tools-section (tools)
  "Return the body of the <tools> section for TOOLS."
  (concat
   (mapconcat
    (lambda (tool)
      (or (plist-get tool :prompt-snippet)
          (format "%s: %s" (plist-get tool :name)
                  (car (split-string (or (plist-get tool :description) "") "\\. ")))))
    tools "\n")
   "\nOther custom tools may be available depending on the project."))

(defun pai-prompt--rules-section (rules guidelines)
  "Return the body of the <rules> section from RULES and extra GUIDELINES."
  (mapconcat (lambda (r) (concat "- " r)) (append rules guidelines) "\n"))

(defun pai-prompt--project-context (context-files)
  "Return the <project_context> body for CONTEXT-FILES (alist of PATH . TEXT)."
  (when context-files
    (concat
     "Project-specific instructions and guidelines:\n\n"
     (mapconcat
      (lambda (cf)
        (format "<project_instructions path=\"%s\">\n%s\n</project_instructions>"
                (car cf) (string-trim-right (cdr cf))))
      context-files "\n\n"))))

(cl-defun pai-build-system-prompt (&key (cwd default-directory) tools
                                        (rules pai-system-rules) guidelines
                                        skills context-files sections addendum
                                        (preamble pai-system-preamble) docs)
  "Assemble and return the system prompt string.
TOOLS is a list of tool plists, SKILLS a list of skill plists, CONTEXT-FILES an
alist of (PATH . TEXT), SECTIONS a plist of extra (:name STRING) sections."
  (let ((parts
         (delq nil
               (list
                (pai-prompt--section "preamble" preamble)
                (when tools (pai-prompt--section "tools" (pai-prompt--tools-section tools)))
                (pai-prompt--section "rules" (pai-prompt--rules-section rules guidelines))
                (when docs (pai-prompt--section "docs" docs))
                (when context-files
                  (pai-prompt--section "project_context" (pai-prompt--project-context context-files)))
                (when skills
                  (pai-prompt--section "skills" (pai-skills-prompt-section skills)))
                (pai-prompt--section "cwd" (abbreviate-file-name cwd))))))
    ;; Extra extension-provided sections, in order, after the core sections.
    (let ((rest sections) (extras '()))
      (while rest
        (let ((name (substring (symbol-name (car rest)) 1))
              (body (cadr rest)))
          (when-let ((s (pai-prompt--section name body))) (push s extras)))
        (setq rest (cddr rest)))
      (setq parts (append parts (nreverse extras))))
    (when addendum
      (setq parts (append parts (list (pai-prompt--section "addendum" addendum)))))
    (string-join (delq nil parts) "\n\n")))

(provide 'pai-prompt)
;;; pai-prompt.el ends here
