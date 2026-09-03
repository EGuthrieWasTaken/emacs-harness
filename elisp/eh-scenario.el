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
(defvar eh-profile-bridge-scripts-dir nil
  "Directory holding this profile's `eh-fake-bridge' scripts (DESIGN 9.2).
A profile whose package talks to a backend process points that package's
own \"how do I launch my backend\" option at `eh-fake-bridge-command',
which resolves a script name against this directory.")

(defvar eh-profile-scratch-dir nil
  "Session scratch HOME; fixtures are copied here before a scenario touches them.
Never write into the read-only package/profile source trees (DESIGN §5.3).")
(defvar eh-available-kernels nil
  "List of kernel name strings (e.g. \"python3\") reachable this session.
Used by `:needs (:kernel ...)' to decide skip vs run.")

(defvar eh-scenario-setup-functions nil
  "Functions run with no arguments before every scenario body.

The place a profile puts \"put my package back the way a fresh session
found it\".  A profile's own globals -- which backend a package is
pointed at, a mode a scenario turned on -- are not buffers, so the
buffer teardown below does not touch them, and a scenario that changed
one silently changes every scenario that runs after it.  That is the
single most common source of \"passes alone, fails in the suite\"
(DESIGN 5.2), and it is invisible: the leak shows up as an unrelated
scenario failing for a reason that makes no sense where it is.")

(defvar eh-profile-log-buffers nil
  "Buffer names a profile declared worth sweeping into a failure bundle.
Set by `eh-defprofile'; declared here too so this file compiles alone.")

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
                (:cairo (unless (and (fboundp 'x-export-frames) (display-graphic-p) val)
                          (cl-return "needs a cairo build with a live graphical frame")))
                (:svg (unless (image-type-available-p 'svg)
                        (cl-return "needs SVG image support")))
                (:kernel (unless (member val eh-available-kernels)
                           (cl-return (format "needs kernel %s (available: %s)"
                                              val eh-available-kernels))))
                ;; A package's real backend, where the profile keeps a
                ;; tier of scenarios against it alongside the fake
                ;; (DESIGN 9.1/9.2).  The fake cannot answer everything:
                ;; anything whose result is a *file the backend wrote*
                ;; needs the real one, and skipping legibly where it is
                ;; not installed is what keeps that tier optional.
                (:executable (unless (executable-find val)
                               (cl-return (format "needs %s on PATH" val))))
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
;;; the scriptable fake backend (DESIGN 9.2)

(defvar eh-fake-bridge (if (boundp 'eh-bin-dir)
                            (expand-file-name "eh-fake-bridge" eh-bin-dir)
                          "/opt/eh/bin/eh-fake-bridge")
  "Path to the scriptable stand-in for a package's backend process.
Derived from `eh-bin-dir' (set by the generated per-session init file
from the same EH_ROOT/EH_BIN_DIR ehd itself resolved), falling back to
the container image path for direct `--eval'/`-l' loading.")

(defun eh-fake-bridge-command (&rest args)
  "Command list running `eh-fake-bridge' with ARGS.
A string ending in `.jsonl' names a script in the profile's
`bridge-scripts/' directory and expands to `--script <abspath>';
everything else is passed through untouched, so faults and key overrides
read as themselves:

  (eh-fake-bridge-command \"base.jsonl\" \"python.jsonl\" \"--fault\" \"slow-drip\")

The result is what a profile assigns to the package's own \"how do I
launch my backend\" option, which is the whole point: the package
launches its backend exactly as it always does, and never learns that
the thing on the other end of the pipe is a fixture."
  (cons eh-fake-bridge
        (mapcan (lambda (arg)
                  ;; Keyed off the extension, not off "does not start with
                  ;; a dash": the latter swallows a flag's *argument*
                  ;; ("--fault" "stderr-noise") as a script name, and the
                  ;; bridge then dies on a missing file with the fault
                  ;; silently never applied.
                  (if (and (stringp arg) (string-suffix-p ".jsonl" arg))
                      (list "--script"
                            (expand-file-name arg eh-profile-bridge-scripts-dir))
                    (list arg)))
                args)))

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
                 (run-hooks 'eh-scenario-setup-functions)
                 ,(when geometry
                    `(eh-apply-determinism-settings ,(car geometry) ,(cdr geometry)))
                 ,(when fixture `(eh-open-fixture ,fixture))
                 ,@forms
                 (setq eh--scenario-ok t))
             (unless eh--scenario-ok
               (eh--capture-scenario-artifacts ',name))
             (eh--scenario-teardown buffers-before)))))))

(defun eh--scenario-teardown (buffers-before)
  "Kill every buffer the scenario created.  A fixture buffer is disposable
scratch state by design (DESIGN §5.3/§8.2: fixtures are copied into
scratch precisely so they are safe to discard), so this must be
unconditional: `kill-buffer' on a modified buffer would otherwise ask
\"kill anyway?\" via `yes-or-no-p', which the prompt guard (§6.5) turns
into a signalled error under `eh-strict-prompts' -- and the old
`ignore-errors' here swallowed exactly that error, leaving the buffer
alive and modified for the *next* scenario's same-named fixture to
collide with (`find-file' on an externally-touched file with unsaved
edits triggers `ask-user-about-supersession-threat', which hits the
guard again, this time uncaught)."
  (dolist (b (buffer-list))
    (unless (or (memq b buffers-before) (not (buffer-live-p b)))
      (with-current-buffer b (set-buffer-modified-p nil))
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
          ;; Capture the name and snapshot *before* `with-temp-file' below,
          ;; which rebinds (current-buffer) to its own internal " *temp
          ;; file*" buffer for the extent of its body -- calling
          ;; `(buffer-name)'/`eh-snapshot' from inside that body silently
          ;; snapshots the wrong buffer instead of B.
          (let ((name (buffer-name))
                (snapshot (ignore-errors (eh-snapshot :buffer (buffer-name) :window t))))
            (with-temp-file (expand-file-name
                              (format "snapshot-%s.el"
                                      (replace-regexp-in-string "[^A-Za-z0-9.-]" "_" name))
                              dir)
              (insert (eh--prin1-to-string-unlimited snapshot)))))))
    ;; A profile's declared log buffers, by name.  The sweep above skips
    ;; every buffer whose name starts with a space, which is exactly
    ;; where a package hides a subprocess's stderr -- and that is usually
    ;; the one place a failure's actual reason is written down.  Nothing
    ;; used `:log-buffers' before this, so declaring them did nothing.
    (dolist (name eh-profile-log-buffers)
      (let ((buffer (get-buffer name)))
        (when (buffer-live-p buffer)
          (with-temp-file (expand-file-name
                            (format "log-%s.txt"
                                    (replace-regexp-in-string "[^A-Za-z0-9.-]" "_" name))
                            dir)
            (insert-buffer-substring buffer)))))
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
  "Assert POS carries an image display property.  Recognizes both Emacs
display-property shapes for a sliced image: a plain image spec with its
own :slice plist key, and `insert-sliced-image''s `((slice X Y W H)
IMAGE-SPEC)' wrapper form.  With SLICES non-nil, additionally assert POS
is part of a sliced sequence (either shape)."
  (let* ((disp (get-char-property pos 'display))
         (wrapper-sliced (and (consp disp) (consp (car disp)) (eq (caar disp) 'slice)
                               (consp (cadr disp)) (eq (car (cadr disp)) 'image)))
         (image-spec (cond (wrapper-sliced (cadr disp))
                            ((and (consp disp) (eq (car disp) 'image)) disp))))
    (unless image-spec
      (ert-fail (format "%sno image display property at %d" (if message (concat message ": ") "") pos)))
    (when type
      (unless (eq (plist-get (cdr image-spec) :type) type)
        (ert-fail (format "expected image type %s, got %s" type (plist-get (cdr image-spec) :type)))))
    (when min-width
      (let ((size (image-size image-spec t)))
        (unless (>= (car size) min-width)
          (ert-fail (format "expected width >= %d, got %d" min-width (car size))))))
    (when slices
      (unless (or wrapper-sliced (plist-get (cdr image-spec) :slice))
        (ert-fail (format "%sposition %d is not part of a sliced image"
                           (if message (concat message ": ") "") pos))))))

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
  "Screenshot the frame and assert it matches the profile's baseline for
NAME under the session's Emacs version/geometry/theme (§6.4, §8.3).
Artifacts (actual/diff PNGs) land in this scenario's artifact directory,
so a failure's screenshots are in the same place as its other artifacts.

A missing baseline `ert-skip's rather than fails: a baseline is keyed
per Emacs-version/geometry/theme (§8.4), and the same profile is
routinely run across several of each (§14 phase 3's matrix), so \"no
baseline for this combination yet\" is an expected, unestablished
state -- not a regression -- until an agent runs `eh baseline accept'
for it. A real pixel mismatch against an *existing* baseline still
fails, same as always."
  (let ((r (eh-diff-shot name :tolerance tolerance :mask mask
                          :out-dir (eh--scenario-artifact-dir eh-current-scenario-name))))
    (when (plist-get r :no-baseline)
      (ert-skip (format "%s%s" (if message (concat message ": ") "") (plist-get r :error))))
    (unless (plist-get r :ok)
      (ert-fail
       (format "%svisual drift in %s: %s"
               (if message (concat message ": ") "") name
               (or (plist-get r :error)
                   (format "ratio %.4f exceeds tolerance (%s/%s px changed); see %s vs %s"
                           (plist-get r :ratio) (plist-get r :changed-pixels)
                           (plist-get r :total-pixels) (plist-get r :actual)
                           (plist-get r :baseline))))))))

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

(defun eh-run-scenarios-json (files selector run-dir)
  "Load FILES (scenario .el files), run tests matching SELECTOR (a string
read as an ERT selector, or nil for all `eh-scenario' tests), and return
a JSON summary.  RUN-DIR becomes `eh-artifacts-root' for failure capture.

Deliberately does *not* delegate to `ert-run-tests-batch': that relies on
ERT's own per-test catching, which installs a custom `debugger' binding
around each test body (see `ert--run-test-internal').  That mechanism is
never reached here -- `eh run' arrives via `emacsclient --eval', which
executes inside `server-process-filter''s dynamic extent, and that
function wraps the whole request in its own blanket `condition-case'
\(`(t (server-return-error proc err))'); Emacs resolves a signal to the
*nearest enclosing `condition-case'*, found before `debug-on-error' or
`debugger' is ever consulted, so server.el's handler always wins first
and every test's failure or skip -- not just this run's, the *entire*
`ert-run-tests-batch' call -- would escape uncaught, killing the whole
session instead of landing in the JSON below.  This is a known upstream
limitation, not a bug in that Emacs's own ERT carries a FIXME about
(Bug#24402, Bug#11218): it plans to move off the `debugger' hook onto
`signal-hook-function' but has not, as of this Emacs, done so.  A plain
`condition-case' *does* resolve correctly in this context (it is what
server.el's own handler uses), so tests are selected via
`ert-select-tests' and run one at a time, each wrapped in one here."
  (setq eh-artifacts-root run-dir)
  (dolist (f files) (load f nil t))
  (let* ((sel (if (and selector (not (string-empty-p selector)))
                   (read selector)
                 '(tag eh-scenario)))
         (tests (ert-select-tests sel t))
         (results nil))
    (dolist (test tests)
      (let ((name (ert-test-name test))
            (start (float-time))
            status msg)
        (condition-case err
            (progn (funcall (ert-test-body test)) (setq status "passed"))
          (ert-test-skipped (setq status "skipped" msg (format "%S" err)))
          (error (setq status "failed" msg (format "%S" err))))
        (let ((duration-ms (round (* 1000 (- (float-time) start)))))
          (when (member status '("failed" "skipped"))
            (with-temp-file (expand-file-name "backtrace.txt"
                                               (eh--scenario-artifact-dir name))
              (insert (or msg "") "\n")))
          (push `((name . ,(format "%s" name))
                  (status . ,status)
                  (duration_ms . ,duration-ms)
                  ,@(if msg `((message . ,msg)) nil))
                results))))
    (setq results (nreverse results))
    (eh--raw-json
     (json-encode
      `((total . ,(length results))
        (passed . ,(cl-count "passed" results :key (lambda (r) (cdr (assq 'status r))) :test #'string=))
        (failed . ,(cl-count "failed" results :key (lambda (r) (cdr (assq 'status r))) :test #'string=))
        (skipped . ,(cl-count "skipped" results :key (lambda (r) (cdr (assq 'status r))) :test #'string=))
        (tests . ,(vconcat results)))))))

(provide 'eh-scenario)
;;; eh-scenario.el ends here
