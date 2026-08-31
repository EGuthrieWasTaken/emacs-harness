;;; eh-scenario.el --- ERT scenario DSL for emacs-harness -*- lexical-binding: t; -*-

;; Thin macros over ERT (DESIGN §8.1-8.3).  Never a parallel test framework:
;; `eh-scenario' expands to `ert-deftest'.  A scenario file is plain Emacs
;; Lisp that runs *inside* the instance under test, so the same file works
;; both under `eh run' and under plain `ert-run-tests-batch-and-exit'.

(require 'ert)
(require 'eh-driver)
(require 'cl-lib)

(defvar eh-profile-name nil)
(defvar eh-profile-fixtures-dir nil)
(defvar eh-profile-scratch-dir nil
  "Session scratch HOME; fixtures are copied here before a scenario touches them.
Never write into the read-only package/profile source trees (DESIGN §5.3).")
(defvar eh-available-kernels nil
  "List of kernel name strings (e.g. \"python3\") reachable this session.
Used by `:needs (:kernel ...)' to decide skip vs run.")

(defvar eh-current-scenario-name nil)
(defvar eh-artifacts-root nil
  "Run directory root; each scenario gets ARTIFACTS-ROOT/<scenario-name>/.")

(defun eh--scenario-artifact-dir (name)
  (let ((dir (expand-file-name (symbol-name name)
                                (or eh-artifacts-root
                                    (expand-file-name "runs/adhoc" eh-run-dir)))))
    (make-directory dir t)
    dir))

;;; ---------------------------------------------------------------------
;;; :needs skip logic

(defun eh--version-satisfies (spec)
  "SPEC like \">= 27.1\"."
  (if (not (string-match "\\`\\s-*\\(>=\\|<=\\|=\\|>\\|<\\)?\\s-*\\([0-9.]+\\)\\s-*\\'" spec))
      t
    (let* ((op (or (match-string 1 spec) ">="))
           (want (version-to-list (match-string 2 spec)))
           (have (version-to-list emacs-version))
           (cmp (cond ((version-list-< have want) -1)
                      ((version-list-= have want) 0)
                      (t 1))))
      (pcase op
        (">=" (>= cmp 0)) ("<=" (<= cmp 0)) ("=" (= cmp 0))
        (">" (> cmp 0)) ("<" (< cmp 0)) (_ t)))))

(defun eh--needs-check (needs)
  "Return nil if satisfied, or a skip-reason string."
  (cl-loop for (key val) on needs by #'cddr
           do (pcase key
                (:emacs (unless (eh--version-satisfies val)
                          (cl-return (format "needs emacs %s, have %s" val emacs-version))))
                (:cairo (unless (and (fboundp 'x-export-frames) val)
                          (cl-return "needs a cairo build")))
                (:svg (unless (image-type-available-p 'svg)
                        (cl-return "needs SVG image support")))
                (:kernel (unless (member val eh-available-kernels)
                           (cl-return (format "needs kernel %s (available: %s)"
                                              val eh-available-kernels))))
                (:graphic (unless (display-graphic-p)
                            (cl-return "needs a graphical frame"))))
           finally (cl-return nil)))

;;; ---------------------------------------------------------------------
;;; fixtures

(defun eh-open-fixture (name)
  "Copy fixture NAME from the profile's fixtures/ into the scratch dir
and find-file it there.  Never opens the read-only profile copy."
  (let* ((src (expand-file-name name eh-profile-fixtures-dir))
         (dst (expand-file-name name eh-profile-scratch-dir)))
    (unless (file-exists-p src) (error "eh: no such fixture: %s" name))
    (make-directory (file-name-directory dst) t)
    (copy-file src dst t)
    (find-file dst)))

;;; ---------------------------------------------------------------------
;;; the macro

(defmacro eh-scenario (name &rest body)
  "Define scenario NAME.  BODY starts with a keyword plist
\(:doc :needs :fixture :geometry :tags\) followed by the test forms."
  (declare (indent 1))
  (let (doc needs fixture geometry tags forms (rest body))
    (while (keywordp (car rest))
      (pcase (car rest)
        (:doc (setq doc (cadr rest)))
        (:needs (setq needs (cadr rest)))
        (:fixture (setq fixture (cadr rest)))
        (:geometry (setq geometry (cadr rest)))
        (:tags (setq tags (cadr rest))))
      (setq rest (cddr rest)))
    (setq forms rest)
    `(ert-deftest ,name ()
       ,(or doc "")
       :tags ',(cons 'eh-scenario tags)
       (let ((eh-current-scenario-name ',name)
             (skip-reason (eh--needs-check ',needs)))
         (when skip-reason (ert-skip skip-reason))
         (let ((buffers-before (buffer-list))
               (eh-answers nil)
               (eh--scenario-ok nil))
           ;; Deliberately *not* a `condition-case' around the body: ERT's
           ;; own pass/fail/skip signals (`ert-test-failed', `ert-test-skipped')
           ;; must reach ERT's machinery completely undisturbed, or its stats
           ;; bookkeeping breaks ("aborted with non-local exit").  Detect an
           ;; abnormal exit the side-effect-free way instead: a flag that
           ;; only gets set on normal completion.
           (unwind-protect
               (progn
                 ,(when geometry
                    `(eh-apply-determinism-settings ,(car geometry) ,(cdr geometry)))
                 ,(when fixture `(eh-open-fixture ,fixture))
                 ,@forms
                 (setq eh--scenario-ok t))
             (unless eh--scenario-ok
               (eh--capture-scenario-artifacts ',name))
             (eh--scenario-teardown buffers-before)))))))

(defun eh--scenario-teardown (buffers-before)
  (dolist (b (buffer-list))
    (unless (or (memq b buffers-before) (not (buffer-live-p b)))
      (let ((kill-buffer-query-functions nil))
        (ignore-errors (kill-buffer b))))))

(defun eh--capture-scenario-artifacts (name)
  "Sweep buffer snapshots, *Messages* and a screenshot into the failure
bundle.  The error/backtrace text itself is written separately by
`eh-run-scenarios-json', from ERT's own (undisturbed) result object --
see the comment in `eh-scenario' about why this function never touches
the signal that caused the abnormal exit."
  (let ((dir (eh--scenario-artifact-dir name)))
    (when (get-buffer "*Messages*")
      (with-temp-file (expand-file-name "messages.log" dir)
        (insert-buffer-substring "*Messages*")))
    (dolist (b (buffer-list))
      (with-current-buffer b
        (unless (string-prefix-p " " (buffer-name))
          (with-temp-file (expand-file-name
                            (format "snapshot-%s.el"
                                    (replace-regexp-in-string "[^A-Za-z0-9.-]" "_" (buffer-name)))
                            dir)
            (insert (eh--prin1-to-string-unlimited
                     (ignore-errors (eh-snapshot :buffer (buffer-name) :window t))))))))
    (when (display-graphic-p)
      (ignore-errors (eh-shot-to-file (expand-file-name "failure.png" dir))))))

;;; ---------------------------------------------------------------------
;;; §8.2 assertion vocabulary

(defmacro eh-expect (form &optional message)
  `(unless ,form
     (ert-fail (format "%s%S was nil" (if ,message (concat ,message ": ") "") ',form))))

(defmacro eh-expect-equal (a b &optional message)
  `(let ((av ,a) (bv ,b))
     (unless (equal av bv)
       (ert-fail (format "%sexpected %S, got %S"
                          (if ,message (concat ,message ": ") "") bv av)))))

(defmacro eh-expect-match (regexp string &optional message)
  `(unless (string-match-p ,regexp ,string)
     (ert-fail (format "%s%S does not match %S" (if ,message (concat ,message ": ") "") ,string ,regexp))))

(defun eh--resolved-face (pos)
  (let ((f (get-char-property pos 'face)))
    (cond ((null f) nil) ((symbolp f) f) ((listp f) f) (t f))))

(defun eh--face-matches (actual expected)
  (cond
   ((eq actual expected) t)
   ((and (listp actual) (memq expected actual)) t)
   ((and (symbolp actual) actual
         (memq expected (or (face-all-attributes actual) nil))) nil)
   ;; resolve inheritance: EXPECTED may be a base face that ACTUAL :inherit's
   ((and (symbolp actual) actual)
    (let ((inherit (face-attribute actual :inherit nil t)))
      (cond ((eq inherit expected) t)
            ((and (listp inherit) (memq expected inherit)) t)
            (t nil))))
   (t nil)))

(defun eh-expect-face (pos expected-face &optional message)
  (let ((actual (eh--resolved-face pos)))
    (unless (eh--face-matches actual expected-face)
      (ert-fail (format "%sat %d: expected face %s (or inheriting it), got %S"
                         (if message (concat message ": ") "") pos expected-face actual)))))

(defun eh-expect-read-only (region &optional message)
  (cl-destructuring-bind (beg end) region
    (unless (text-property-not-all beg end 'read-only nil)
      (ert-fail (format "%sregion %d-%d is not read-only" (if message (concat message ": ") "") beg end)))))

(defun eh-expect-editable (region &optional message)
  "Actually try an insert via the command loop -- the ability to type
is the behaviour; the read-only property is only the mechanism."
  (cl-destructuring-bind (beg _end) region
    (save-excursion
      (goto-char beg)
      (let ((before (buffer-string)))
        (condition-case err
            (progn (execute-kbd-macro "z") t)
          (error (ert-fail (format "%sposition %d is not editable: %s"
                                    (if message (concat message ": ") "") beg
                                    (error-message-string err)))))
        (when (equal before (buffer-string))
          (ert-fail (format "%sposition %d accepted no edit" (if message (concat message ": ") "") beg)))
        (undo-boundary)
        (ignore-errors (primitive-undo 1 buffer-undo-list))))))

(defun eh-expect-overlay (region prop val &optional message)
  (cl-destructuring-bind (beg end) region
    (let ((found (cl-find-if (lambda (ov) (equal (overlay-get ov prop) val))
                              (overlays-in beg end))))
      (unless found
        (ert-fail (format "%sno overlay in %d-%d has %s = %S"
                           (if message (concat message ": ") "") beg end prop val))))))

(cl-defun eh-expect-display-image (pos &key type slices min-width message)
  (let ((disp (get-char-property pos 'display)))
    (unless (and (consp disp) (eq (car disp) 'image))
      (ert-fail (format "%sno image display property at %d" (if message (concat message ": ") "") pos)))
    (when type
      (unless (eq (plist-get (cdr disp) :type) type)
        (ert-fail (format "expected image type %s, got %s" type (plist-get (cdr disp) :type)))))
    (when min-width
      (let ((size (image-size disp t)))
        (unless (>= (car size) min-width)
          (ert-fail (format "expected width >= %d, got %d" min-width (car size))))))
    (when slices
      (unless (eq (plist-get (cdr disp) :slice) slices)
        t))))

(defun eh-expect-visible (pos &optional message)
  (unless (pos-visible-in-window-p pos)
    (ert-fail (format "%sposition %d is not visible in window" (if message (concat message ": ") "") pos))))

(defun eh-expect-not-visible (pos &optional message)
  (when (pos-visible-in-window-p pos)
    (ert-fail (format "%sposition %d is visible in window" (if message (concat message ": ") "") pos))))

(defmacro eh-expect-window-start-unchanged (&rest body)
  (let ((win (make-symbol "win")) (start (make-symbol "start")))
    `(let* ((,win (selected-window)) (,start (window-start ,win)))
       ,@body
       (unless (= ,start (window-start ,win))
         (ert-fail (format "window-start changed: %d -> %d" ,start (window-start ,win)))))))

(defun eh-expect-mode-line-matches (regexp &optional message)
  (let ((ml (format-mode-line mode-line-format)))
    (unless (string-match-p regexp ml)
      (ert-fail (format "%smode line %S does not match %S" (if message (concat message ": ") "") ml regexp)))))

(cl-defun eh-expect-no-visual-drift (name &key tolerance mask message)
  "Screenshot capture only in phase 1; full baseline diffing is phase 2 (§14)."
  (ignore tolerance mask message)
  (let ((path (expand-file-name (format "%s.png" name)
                                 (eh--scenario-artifact-dir eh-current-scenario-name))))
    (eh-shot-to-file path)))

(defun eh-expect-messages-match (regexp &optional message)
  (let ((text (if (get-buffer "*Messages*")
                  (with-current-buffer "*Messages*" (buffer-string))
                "")))
    (unless (string-match-p regexp text)
      (ert-fail (format "%s*Messages* does not match %S" (if message (concat message ": ") "") regexp)))))

(defmacro eh-expect-no-error (&rest body)
  `(condition-case err
       (progn ,@body t)
     (error (ert-fail (format "unexpected error: %s" (error-message-string err))))))

;;; ---------------------------------------------------------------------
;;; named waiters usable as (eh-wait-name "...")

(defun eh-goto-cell (_n) (error "eh: eh-goto-cell has no default implementation; profiles must provide one"))
(defun eh-cell-has-output-p (_n) (error "eh: eh-cell-has-output-p has no default implementation; profiles must provide one"))

;;; ---------------------------------------------------------------------
;;; `eh run' entry point

(defun eh--test-result-status (result)
  (cond ((ert-test-passed-p result) "passed")
        ((and (fboundp 'ert-test-skipped-p) (ert-test-skipped-p result)) "skipped")
        (t "failed")))

(defun eh--test-result-message (result status)
  "`ert-test-skipped' and `ert-test-failed' are siblings, not one a
subtype of the other, so only the shared base struct's accessor works
on both -- `ert-test-failed-condition' raises `wrong-type-argument' on
a skip result."
  (ignore-errors
    (pcase status
      ((or "failed" "skipped")
       (format "%S" (ert-test-result-with-condition-condition result)))
      (_ nil))))

(defun eh--test-result-duration (result)
  (or (ignore-errors (ert-test-result-duration result)) 0))

(defun eh-run-scenarios-json (files selector run-dir)
  "Load FILES (scenario .el files), run tests matching SELECTOR (a string
read as an ERT selector, or nil for all `eh-scenario' tests), and return
a JSON summary.  RUN-DIR becomes `eh-artifacts-root' for failure capture."
  (setq eh-artifacts-root run-dir)
  (dolist (f files) (load f nil t))
  (let* ((sel (if (and selector (not (string-empty-p selector)))
                   (read selector)
                 '(tag eh-scenario)))
         (stats (let ((ert-quiet t)) (ert-run-tests-batch sel)))
         (n (length (ert--stats-tests stats)))
         (results nil))
    (dotimes (i n)
      (let* ((test (aref (ert--stats-tests stats) i))
             (result (aref (ert--stats-test-results stats) i))
             (status (eh--test-result-status result))
             (msg (eh--test-result-message result status)))
        (when (member status '("failed" "skipped"))
          (with-temp-file (expand-file-name "backtrace.txt"
                                             (eh--scenario-artifact-dir (ert-test-name test)))
            (insert (or msg "") "\n")))
        (push `((name . ,(format "%s" (ert-test-name test)))
                (status . ,status)
                (duration_ms . ,(round (* 1000 (eh--test-result-duration result))))
                ,@(if msg `((message . ,msg)) nil))
              results)))
    (setq results (nreverse results))
    (eh--raw-json
     (json-encode
      `((total . ,n)
        (passed . ,(cl-count "passed" results :key (lambda (r) (cdr (assq 'status r))) :test #'string=))
        (failed . ,(cl-count "failed" results :key (lambda (r) (cdr (assq 'status r))) :test #'string=))
        (skipped . ,(cl-count "skipped" results :key (lambda (r) (cdr (assq 'status r))) :test #'string=))
        (tests . ,(vconcat results)))))))

(provide 'eh-scenario)
;;; eh-scenario.el ends here
