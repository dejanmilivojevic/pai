;;; pai-markdown-test.el --- Tests for markdown table alignment -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pai-markdown)

(defun pai-md-test--lines (text) (split-string text "\n"))

(ert-deftest pai-md-aligns-basic-table ()
  (let* ((input (string-join
                 '("| Name | Age |"
                   "|---|---|"
                   "| Alice | 30 |"
                   "| Bob | 100 |") "\n"))
         (out (pai-md-align-tables input))
         (lines (pai-md-test--lines out)))
    (should (equal (nth 0 lines) "| Name  | Age |"))
    (should (equal (nth 1 lines) "| ----- | --- |"))
    (should (equal (nth 2 lines) "| Alice | 30  |"))
    (should (equal (nth 3 lines) "| Bob   | 100 |"))
    ;; every rendered row has the same length (columns line up)
    (should (apply #'= (mapcar #'length lines)))))

(ert-deftest pai-md-right-align ()
  (let* ((input (string-join
                 '("| Item | Qty |"
                   "|:---|---:|"
                   "| apples | 5 |") "\n"))
         (lines (pai-md-test--lines (pai-md-align-tables input))))
    ;; right column: value padded on the LEFT
    (should (equal (nth 2 lines) "| apples |   5 |"))
    ;; separator encodes right alignment with a trailing colon in the cell
    (should (string-match-p "--: |" (nth 1 lines)))))

(ert-deftest pai-md-center-align ()
  (let* ((input (string-join
                 '("| A | B |"
                   "|:-:|:-:|"
                   "| xx | yyyy |") "\n"))
         (lines (pai-md-test--lines (pai-md-align-tables input))))
    (should (string-match-p "\\`| :-* | :-*: |\\|:.*:" (nth 1 lines)))
    (should (apply #'= (mapcar #'length lines)))))

(ert-deftest pai-md-non-table-unchanged ()
  (let ((text "Just some prose.\n\nWith a paragraph and a | pipe but no table.\n"))
    (should (equal (pai-md-align-tables text) text))))

(ert-deftest pai-md-table-surrounded-by-prose ()
  (let* ((input (string-join
                 '("Here is a table:"
                   "| K | V |"
                   "|---|---|"
                   "| a | 1 |"
                   "Done.") "\n"))
         (lines (pai-md-test--lines (pai-md-align-tables input))))
    (should (equal (nth 0 lines) "Here is a table:"))
    (should (equal (nth 1 lines) "| K   | V   |"))
    (should (equal (nth 2 lines) "| --- | --- |"))
    (should (equal (car (last lines)) "Done."))))

(ert-deftest pai-md-wide-chars ()
  ;; Wide (double-width) characters are measured with string-width so columns
  ;; still line up.
  (let* ((input (string-join
                 '("| A | B |"
                   "|---|---|"
                   "| 世界 | x |") "\n"))
         (lines (pai-md-test--lines (pai-md-align-tables input))))
    (should (apply #'= (mapcar #'string-width lines)))))

(ert-deftest pai-md-render-heading-face ()
  (let ((out (pai-markdown-render "# Hello world")))
    (should (string-match-p "Hello world" out))
    ;; No leading '#'.
    (should-not (string-match-p "#" out))
    ;; A character of the heading carries the heading face.
    (let ((pos (string-match "Hello" out)))
      (should (eq (get-text-property pos 'face out) 'pai-md-heading)))))

(ert-deftest pai-md-render-bold ()
  (let ((out (pai-markdown-render "this is **bold** text")))
    (should-not (string-match-p "\\*" out))
    (let ((pos (string-match "bold" out)))
      (should pos)
      (should (eq (get-text-property pos 'face out) 'pai-md-bold)))))

(ert-deftest pai-md-render-italic ()
  (let ((out (pai-markdown-render "an *italic* word")))
    (let ((pos (string-match "italic" out)))
      (should pos)
      (should (eq (get-text-property pos 'face out) 'pai-md-italic)))))

(ert-deftest pai-md-render-inline-code ()
  (let ((out (pai-markdown-render "call `foo()` now")))
    (should-not (string-match-p "`" out))
    (let ((pos (string-match "foo" out)))
      (should pos)
      (should (eq (get-text-property pos 'face out) 'pai-md-code)))))

(ert-deftest pai-md-render-fenced-code-block ()
  (let ((out (pai-markdown-render
              (string-join '("```elisp" "(message \"hi\")" "```") "\n"))))
    ;; Fences are gone.
    (should-not (string-match-p "```" out))
    ;; Inner code carries the language's syntax faces over the code-block face.
    (let ((face (get-text-property (string-match "message" out) 'face out))
          (string-face (get-text-property (string-match "\"hi\"" out) 'face out)))
      (should (memq 'pai-md-code-block (ensure-list face)))
      (should (memq 'font-lock-string-face (ensure-list string-face))))
    ;; The block is marked verbatim for later passes.
    (should (get-text-property (string-match "message" out) 'pai-md-verbatim out))))

(ert-deftest pai-md-lang-mode-resolution ()
  "Fence names resolve through the alist, NAME-mode and auto-mode-alist."
  (should (eq (pai-md-lang-mode "elisp") 'emacs-lisp-mode))
  (should (eq (pai-md-lang-mode "JS") 'js-mode))
  (should (eq (pai-md-lang-mode "c") (pai-md--usable-mode 'c-mode)))
  (should (eq (pai-md-mode-for-file "/x/y.el") 'emacs-lisp-mode))
  (should-not (pai-md-lang-mode "no-such-language"))
  (should-not (pai-md-lang-mode "")))

(ert-deftest pai-md-fontify-unknown-is-plain ()
  "Unknown languages and nil modes leave the code untouched."
  (should (equal (pai-md-fontify "x = 1" nil) "x = 1"))
  (should-not (text-properties-at 0 (pai-md-fontify-lang "x = 1" "nope"))))

(ert-deftest pai-md-highlight-fences-keeps-text ()
  "Only code between fences gains faces; the text itself is unchanged."
  (let* ((text "see:\n```elisp\n(setq a \"b\")\n```\ndone")
         (out (pai-md-highlight-fences text)))
    (should (equal (substring-no-properties out) text))
    (should (eq (get-text-property (string-match "\"b\"" out) 'face out)
                'font-lock-string-face))
    (should-not (get-text-property 0 'face out))))

(ert-deftest pai-markdown-fill-keeps-layout ()
  "Long prose lines wrap; short lines, lists and code are never joined."
  (let* ((rendered (pai-markdown-render
                    (concat "short one\nshort two\n- item\n"
                            (make-string 30 ?w) " " (make-string 30 ?w) "\n"
                            "```js\nconst aVeryLongName = anotherVeryLongName + yetAnotherVeryLongName;\n```")))
         (out (substring-no-properties (pai-markdown-fill rendered 40)))
         (lines (split-string out "\n")))
    (should (member "short one" lines))
    (should (member "short two" lines))
    (should (member "• item" lines))
    (should (member (make-string 30 ?w) lines))
    (should (member "const aVeryLongName = anotherVeryLongName + yetAnotherVeryLongName;" lines))))

(ert-deftest pai-md-render-code-block-no-inline ()
  ;; Inline markers inside a fenced block are NOT interpreted.
  (let ((out (pai-markdown-render
              (string-join '("```" "a **b** c" "```") "\n"))))
    (should (string-match-p "\\*\\*b\\*\\*" out))))

(ert-deftest pai-md-render-link ()
  (let ((out (pai-markdown-render "see [text](http://x) here")))
    (should-not (string-match-p "\\[text\\]" out))
    (let ((pos (string-match "text" out)))
      (should pos)
      (should (equal (get-text-property pos 'pai-md-url out) "http://x")))))

(ert-deftest pai-md-render-unordered-list ()
  (let ((out (pai-markdown-render "- item one")))
    (should (string-prefix-p "•" out))
    (should (string-match-p "item one" out))))

(ert-deftest pai-md-render-ordered-list ()
  (let ((out (pai-markdown-render "1. first")))
    (should (string-match-p "\\`1\\. first" out))))

(ert-deftest pai-md-render-blockquote ()
  (let ((out (pai-markdown-render "> quoted")))
    (should (string-match-p "quoted" out))
    (should (eq (get-text-property 0 'face out) 'pai-md-quote))))

(ert-deftest pai-md-render-horizontal-rule ()
  (let ((out (pai-markdown-render "---")))
    (should (> (length out) 0))
    (should (eq (get-text-property 0 'face out) 'pai-md-rule))))

(ert-deftest pai-md-render-table-aligned ()
  (let* ((input (string-join
                 '("| Name | Age |"
                   "|---|---|"
                   "| Alice | 30 |"
                   "| Bob | 100 |") "\n"))
         (out (pai-markdown-render input))
         (lines (pai-md-test--lines out)))
    ;; Alignment preserved: all rows same display width.
    (should (apply #'= (mapcar #'string-width lines)))
    ;; Header row carries bold face.
    (should (eq (get-text-property 0 'face (nth 0 lines)) 'pai-md-bold))))

(ert-deftest pai-md-render-malformed-passthrough ()
  ;; Unmatched markers do not signal and pass through literally.
  (let ((out (pai-markdown-render "an **unclosed bold and `code")))
    (should (string-match-p "unclosed" out))))

(provide 'pai-markdown-test)
;;; pai-markdown-test.el ends here
