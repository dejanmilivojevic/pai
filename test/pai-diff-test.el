;;; pai-diff-test.el --- Tests for pai-diff -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for unified diff generation, rendering, and stats.

;;; Code:

(require 'ert)
(require 'pai-diff)

(defconst pai-diff-test--old "a\nb\nc\n")
(defconst pai-diff-test--new "a\nB\nc\n")

(ert-deftest pai-diff-unified-shows-change ()
  "A changed line appears as a removed `-b' and an added `+B'."
  (let ((diff (pai-diff-unified pai-diff-test--old pai-diff-test--new)))
    (should (string-match-p "^-b$" diff))
    (should (string-match-p "^\\+B$" diff))))

(ert-deftest pai-diff-unified-default-and-custom-names ()
  "Headers use default a/b names, and custom names when supplied."
  (let ((diff (pai-diff-unified pai-diff-test--old pai-diff-test--new)))
    (should (string-match-p "^--- a" diff))
    (should (string-match-p "^\\+\\+\\+ b" diff)))
  (let ((diff (pai-diff-unified pai-diff-test--old pai-diff-test--new
                                "old.txt" "new.txt")))
    (should (string-match-p "^--- old.txt" diff))
    (should (string-match-p "^\\+\\+\\+ new.txt" diff))))

(ert-deftest pai-diff-unified-identical-has-no-content-lines ()
  "Identical inputs produce empty or header-only diff (no +/- content)."
  (let ((diff (pai-diff-unified pai-diff-test--old pai-diff-test--old)))
    (dolist (line (split-string diff "\n"))
      (should-not (pai-diff--content-line-p line)))))

(ert-deftest pai-diff-unified-trailing-newline ()
  "A trailing-newline difference does not crash and stays valid."
  (let ((diff (pai-diff-unified "a\nb" "a\nb\n")))
    (should (stringp diff))))

(ert-deftest pai-diff-stat-counts ()
  "Stat counts one added and one removed line for the b->B change."
  (let ((stat (pai-diff-stat pai-diff-test--old pai-diff-test--new)))
    (should (= (plist-get stat :added) 1))
    (should (= (plist-get stat :removed) 1))))

(ert-deftest pai-diff-stat-identical ()
  "Identical inputs count zero added and zero removed."
  (let ((stat (pai-diff-stat pai-diff-test--old pai-diff-test--old)))
    (should (= (plist-get stat :added) 0))
    (should (= (plist-get stat :removed) 0))))

(defun pai-diff-test--face-on-line (rendered prefix)
  "Return the `face' text property on the line in RENDERED starting with PREFIX."
  (let ((face nil))
    (dolist (line (split-string rendered "\n"))
      (when (and (null face)
                 (string-prefix-p prefix line)
                 (> (length line) 0))
        (setq face (get-text-property 0 'face line))))
    face))

(ert-deftest pai-diff-render-faces ()
  "Added/removed/hunk/header lines carry their respective faces."
  (let ((rendered (pai-diff-render pai-diff-test--old pai-diff-test--new)))
    (should (eq (pai-diff-test--face-on-line rendered "+B") 'pai-diff-added))
    (should (eq (pai-diff-test--face-on-line rendered "-b") 'pai-diff-removed))
    (should (eq (pai-diff-test--face-on-line rendered "@@") 'pai-diff-hunk))
    (should (eq (pai-diff-test--face-on-line rendered "---") 'pai-diff-header))
    (should (eq (pai-diff-test--face-on-line rendered "+++") 'pai-diff-header))))

(ert-deftest pai-diff-render-header-not-content-face ()
  "The `+++' header is not mistaken for an added content line."
  (let ((rendered (pai-diff-render pai-diff-test--old pai-diff-test--new)))
    (should-not (eq (pai-diff-test--face-on-line rendered "+++")
                    'pai-diff-added))))

(ert-deftest pai-diff-fallback-produces-valid-diff ()
  "The fallback path emits -/+ content lines when `diff' is absent."
  (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
    (let ((diff (pai-diff-unified pai-diff-test--old pai-diff-test--new)))
      (should (string-match-p "^-b$" diff))
      (should (string-match-p "^\\+B$" diff))
      (should (string-match-p "^@@" diff)))
    (should (equal (pai-diff-unified pai-diff-test--old pai-diff-test--old) ""))))

(provide 'pai-diff-test)

;;; pai-diff-test.el ends here
