;;; init.el --- the sandboxed config for the smoke profile -*- lexical-binding: t; -*-

;; The *only* configuration the session's Emacs sees beyond the core's
;; own determinism block (DESIGN.md §7.1, §8.4).  No external package,
;; no kernel, no bridge -- proof that the harness core is package-agnostic.

;; `profile.el' (the declarative manifest: snapshot props, named waiters,
;; log buffers) is loaded from here, not by the harness core -- see
;; eh-profile.el's own header comment. Skipping this line is a silent
;; trap: every session still starts fine with no error, but
;; `eh-defprofile's :waiters/:snapshot-props/:log-buffers simply never
;; register, so e.g. `eh wait smoke-ready' fails with "no such waiter"
;; forever (found while validating the phase 4 HTTP/MCP work).
(load (expand-file-name "profile.el" eh-profile-dir))

(defface smoke-marker-face
  '((t :foreground "red" :weight bold))
  "Face applied to the marker text by `smoke-highlight-marker'.")

(defvar smoke-marker nil "Overlay/text property marker set for tier-1 assertions.")

(defun smoke-highlight-marker ()
  "Find SMOKE-MARKER in the buffer and face it, via a real key binding.
Uses `with-silent-modifications': a face applied to *read output*, say,
is decoration, not a user edit, and must not dirty the buffer or push
an undo entry -- exactly the property this harness exists to assert on
(DESIGN.md §1: buffer regions that are \"text but read-only, written
without touching undo or the modified flag\")."
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

(defconst smoke-sliced-image-rows 5
  "Number of rows `smoke-insert-sliced-image' slices its fixture into.")

(defun smoke-insert-sliced-image ()
  "Insert the tall five-band PNG fixture, sliced into
`smoke-sliced-image-rows' rows via the built-in `insert-sliced-image' --
no external package needed to exercise real image slicing (DESIGN.md §1,
§14 phase 2's \"click the third slice\" acceptance test)."
  (interactive)
  (goto-char (point-max))
  (insert-sliced-image
   (create-image (expand-file-name "tall-stripes.png" eh-profile-fixtures-dir) 'png nil)
   "smoke-sliced-image" nil smoke-sliced-image-rows))

(global-set-key (kbd "C-c C-s") #'smoke-highlight-marker)
(global-set-key (kbd "C-c C-i") #'smoke-insert-fixture-image)
(global-set-key (kbd "C-c C-l") #'smoke-insert-sliced-image)
(add-to-list 'auto-mode-alist '("\\.txt\\'" . text-mode))
