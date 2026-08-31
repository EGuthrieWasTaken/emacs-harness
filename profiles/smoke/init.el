;;; init.el --- the sandboxed config for the smoke profile -*- lexical-binding: t; -*-

;; The *only* configuration the session's Emacs sees beyond the core's
;; own determinism block (DESIGN.md §7.1, §8.4).  No external package,
;; no kernel, no bridge -- proof that the harness core is package-agnostic.

(defface smoke-marker-face
  '((t :foreground "red" :weight bold))
  "Face applied to the marker text by `smoke-highlight-marker'.")

(defvar smoke-marker nil "Overlay/text property marker set for tier-1 assertions.")

(defun smoke-highlight-marker ()
  "Find SMOKE-MARKER in the buffer and face it, via a real key binding.
Uses `with-silent-modifications': a face applied to *read output*, say,
is decoration, not a user edit, and must not dirty the buffer or push
an undo entry -- exactly the property this harness exists to assert on
(DESIGN.md's jsonyter example: \"cell output ... written without
touching undo or the modified flag\")."
  (interactive)
  (goto-char (point-min))
  (when (search-forward "SMOKE-MARKER" nil t)
    (with-silent-modifications
      (put-text-property (match-beginning 0) (match-end 0) 'face 'smoke-marker-face)
      (put-text-property (match-beginning 0) (match-end 0) 'smoke-marker t))))

(defun smoke-insert-fixture-image ()
  "Insert the fixed 16x16 PNG fixture at point, via a real key binding."
  (interactive)
  (goto-char (point-max))
  (insert-image (create-image (expand-file-name "tiny.png" eh-profile-fixtures-dir) 'png nil)
                "smoke-image"))

(global-set-key (kbd "C-c C-s") #'smoke-highlight-marker)
(global-set-key (kbd "C-c C-i") #'smoke-insert-fixture-image)
(add-to-list 'auto-mode-alist '("\\.txt\\'" . text-mode))
