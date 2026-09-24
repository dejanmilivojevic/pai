;;; pai-compose-test.el --- Tests for editing the prompt in its own buffer -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pai)
(require 'pai-faux)
(require 'pai-compose)

(defmacro pai-compose-test--with-chat (buf &rest body)
  "Run BODY with BUF bound to a fresh pai buffer; windows are never touched."
  (declare (indent 1))
  `(let* ((dir (file-name-as-directory (make-temp-file "pai-compose" t)))
          (pai-directory (expand-file-name ".pai-state" dir))
          (pai-default-model "faux")
          (pai-compose-display-action '(display-buffer-no-window (allow-no-window . t)))
          (,buf (generate-new-buffer "*pai-compose-test*")))
     (unwind-protect
         (progn
           (pai-ext-reset)
           (with-current-buffer ,buf
             (setq default-directory dir)
             (pai--setup dir))
           ,@body)
       (let ((kill-buffer-query-functions nil))
         (dolist (b (buffer-list))
           (when (string-match-p "pai compose" (buffer-name b)) (kill-buffer b)))
         (when (buffer-live-p ,buf) (kill-buffer ,buf)))
       (ignore-errors (delete-directory dir t)))))

(defun pai-compose-test--type (buf text)
  "Type TEXT into BUF's prompt."
  (with-current-buffer buf
    (goto-char (point-max))
    (insert text)))

(defun pai-compose-test--prompt (buf)
  "Return BUF's raw prompt text."
  (with-current-buffer buf
    (buffer-substring-no-properties pai--input-marker (point-max))))

(ert-deftest pai-compose-transfers-typed-input ()
  "What is already typed in the prompt opens in the editor, point included."
  (pai-compose-test--with-chat buf
    (pai-compose-test--type buf "first line\nsecond line")
    (with-current-buffer buf
      (goto-char (+ pai--input-marker 5))         ; after "first"
      (let ((editor (save-window-excursion (pai-edit-input))))
        (with-current-buffer editor
          (should (equal (buffer-string) "first line\nsecond line"))
          (should (= (point) 6))
          (should (derived-mode-p 'pai-compose-mode))
          (should pai-compose-edit-mode)
          (should-not (buffer-modified-p)))))))

(ert-deftest pai-compose-commit-writes-prompt ()
  "C-c C-c replaces the prompt with the edited text (without sending it)."
  (pai-compose-test--with-chat buf
    (pai-compose-test--type buf "draft")
    (let ((editor (with-current-buffer buf (save-window-excursion (pai-edit-input)))))
      (with-current-buffer editor
        (goto-char (point-max))
        (insert "\n```js\nconst x = 1;\n```\n\n")
        (pai-compose-commit))
      (should-not (buffer-live-p editor))
      (should (equal (pai-compose-test--prompt buf) "draft\n```js\nconst x = 1;\n```"))
      (should-not (buffer-local-value 'pai--active buf)))))

(ert-deftest pai-compose-abort-keeps-prompt ()
  "C-c C-k discards the edit and leaves the prompt untouched."
  (pai-compose-test--with-chat buf
    (pai-compose-test--type buf "keep me")
    (let ((editor (with-current-buffer buf (save-window-excursion (pai-edit-input)))))
      (with-current-buffer editor
        (erase-buffer) (insert "thrown away")
        (pai-compose-abort))
      (should-not (buffer-live-p editor))
      (should (equal (pai-compose-test--prompt buf) "keep me")))))

(ert-deftest pai-compose-reuses-open-editor ()
  "Opening twice returns to the same editor instead of a second copy."
  (pai-compose-test--with-chat buf
    (let ((first (with-current-buffer buf (save-window-excursion (pai-edit-input)))))
      (with-current-buffer buf (save-window-excursion (pai-edit-input)))
      (should (eq (buffer-local-value 'pai-compose--buffer buf) first))
      (should (= 1 (seq-count (lambda (b) (string-prefix-p "*pai compose:" (buffer-name b)))
                              (buffer-list)))))))

(ert-deftest pai-compose-asks-when-prompt-changed ()
  "Committing over a prompt edited meanwhile asks first."
  (pai-compose-test--with-chat buf
    (pai-compose-test--type buf "old")
    (let ((editor (with-current-buffer buf (save-window-excursion (pai-edit-input)))))
      (pai-compose-test--type buf " typed meanwhile")
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (with-current-buffer editor
          (erase-buffer) (insert "new")
          (pai-compose-commit)))
      (should (equal (pai-compose-test--prompt buf) "old typed meanwhile")))))

(ert-deftest pai-compose-edits-block-in-its-mode ()
  "C-c C-e in a fenced block edits it in the language's mode and puts it back."
  (pai-compose-test--with-chat buf
    (pai-compose-test--type buf "see:\n```elisp\n(+ 1 2)\n```\ndone")
    (let ((editor (with-current-buffer buf (save-window-excursion (pai-edit-input)))))
      (with-current-buffer editor
        (goto-char (point-min)) (search-forward "(+ 1")
        (let ((block (save-window-excursion (pai-compose-dwim) (current-buffer))))
          (with-current-buffer block
            (should (eq major-mode 'emacs-lisp-mode))
            (should (equal (buffer-string) "(+ 1 2)"))
            (goto-char (point-max)) (insert "\n(* 3 4)")
            (pai-compose-commit)))
        (should (equal (buffer-string) "see:\n```elisp\n(+ 1 2)\n(* 3 4)\n```\ndone"))
        (pai-compose-commit))
      (should (equal (pai-compose-test--prompt buf)
                     "see:\n```elisp\n(+ 1 2)\n(* 3 4)\n```\ndone")))))

(ert-deftest pai-compose-fontifies-fenced-code-natively ()
  "Code in a fence gets its language's faces; Markdown markup does not leak in."
  (with-temp-buffer
    (pai-compose-mode)
    (insert "Some **bold**\n```elisp\n(setq a \"*x*\") ; c\n```\n")
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "**bold")
    (should (memq 'pai-md-bold (ensure-list (get-text-property (1- (point)) 'face))))
    (search-forward "\"*x")
    (let ((face (ensure-list (get-text-property (1- (point)) 'face))))
      (should (memq 'font-lock-string-face face))
      (should-not (memq 'pai-md-italic face)))))

(provide 'pai-compose-test)
;;; pai-compose-test.el ends here
