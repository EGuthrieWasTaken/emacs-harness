;;; eh-driver.el --- in-Emacs driver for the emacs-harness control surface -*- lexical-binding: t; -*-

;; Loaded into every session via the per-session generated init file
;; (see DESIGN.md §7.1).  Implements tier 0/1/2 mechanics: the file-based
;; eval protocol (§6.2), eh-snapshot (§6.2), eh-describe, eh-wait/eh-settle
;; (§6.5), the prompt guard (§6.5), SIGUSR2 hang recovery (§6.5), frame
;; export (§6.4) and the click coordinate helper (§6.3).
;;
;; Nothing here knows about any particular package under test; that is
;; what profiles are for (§8.4).

(require 'json)
(require 'cl-lib)

(defvar eh-session-name nil
  "Set by the per-session generated init file before loading this file.")
(defvar eh-run-dir nil
  "Per-session scratch directory, e.g. /run/eh/<session>.  Holds in/, out/.")

(defvar eh-profile-dir nil
  "Set by the per-session generated init file: the profile's directory
root, e.g. /srv/profiles/jsonyter.  Baselines live under
<eh-profile-dir>/baselines/<emacs-version>/<geometry>/<theme>/ (§8.4).")
(defvar eh-session-theme nil
  "Set by the per-session generated init file: the --theme value passed
to `eh session new', or nil for the profile's default faces.")
(defvar eh-session-geometry nil
  "Set by the per-session generated init file: \"WIDTHxHEIGHT\", used to
key baselines by geometry alongside Emacs version and theme (§7.3).")

(defvar eh-strict-prompts t
  "When non-nil, an unscripted interactive prompt is an error, not a hang.
The default in `run' mode; server mode should set this to nil so a human
at the browser view can answer prompts normally.")

(defvar eh-answers nil
  "Queue of scripted answers for interactive prompts, consumed FIFO.")

(defvar eh-waiters nil
  "Alist of (NAME . PREDICATE-FUNCTION) registered by the core and profiles.
Looked up by `eh wait NAME'.")

(defvar eh--messages-mark 0
  "Position in *Messages* before the current request began.")

;;; ---------------------------------------------------------------------
;;; §7.2 Determinism

(defun eh-apply-determinism-settings (&optional width height font)
  "Apply the determinism checklist from DESIGN.md §7.2."
  (let ((width (or width 1280))
        (height (or height 800))
        (font (or font "DejaVu Sans Mono-11")))
    (when (display-graphic-p)
      (set-frame-size (selected-frame) width height t)
      (ignore-errors (set-frame-font font t t))
      (setq frame-resize-pixelwise t))
    (setq-default line-spacing nil)
    (setq face-font-rescale-alist nil)
    (setq image-scaling-factor 1.0)
    (setq inhibit-startup-screen t
          initial-scratch-message nil
          ring-bell-function #'ignore
          use-dialog-box nil
          use-file-dialog nil)
    (when (boundp 'x-gtk-use-system-tooltips)
      (setq x-gtk-use-system-tooltips nil))
    (when (fboundp 'blink-cursor-mode) (blink-cursor-mode -1))
    (when (fboundp 'tool-bar-mode) (tool-bar-mode -1))
    (when (fboundp 'menu-bar-mode) (menu-bar-mode -1))
    (when (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
    (when (fboundp 'horizontal-scroll-bar-mode) (horizontal-scroll-bar-mode -1))
    (when (fboundp 'tooltip-mode) (tooltip-mode -1))
    (setq make-backup-files nil
          auto-save-default nil
          create-lockfiles nil)
    (setq scroll-conservatively 0
          scroll-step 0
          scroll-margin 0
          auto-window-vscroll nil)
    (random "emacs-harness")))

;;; ---------------------------------------------------------------------
;;; §6.5 The prompt guard

(defun eh--consume-answer (prompt)
  (if eh-answers
      (pop eh-answers)
    (if eh-strict-prompts
        (error "eh: unexpected prompt: %s" prompt)
      :eh-fallthrough)))

(define-advice y-or-n-p (:around (orig prompt) eh-guard)
  (let ((a (eh--consume-answer prompt)))
    (if (eq a :eh-fallthrough) (funcall orig prompt) (eq a 'yes))))

(define-advice yes-or-no-p (:around (orig prompt) eh-guard)
  (let ((a (eh--consume-answer prompt)))
    (if (eq a :eh-fallthrough) (funcall orig prompt) (eq a 'yes))))

(define-advice read-from-minibuffer (:around (orig prompt &rest args) eh-guard)
  (let ((a (eh--consume-answer prompt)))
    (if (eq a :eh-fallthrough) (apply orig prompt args) (format "%s" a))))

(define-advice completing-read (:around (orig prompt collection &rest args) eh-guard)
  (let ((a (eh--consume-answer prompt)))
    (if (eq a :eh-fallthrough) (apply orig prompt collection args) (format "%s" a))))

(when (fboundp 'read-string)
  (define-advice read-string (:around (orig prompt &rest args) eh-guard)
    (let ((a (eh--consume-answer prompt)))
      (if (eq a :eh-fallthrough) (apply orig prompt args) (format "%s" a)))))

(defun eh-push-answer (answer)
  "Push ANSWER (`yes', `no', or a string) onto the scripted-answer queue."
  (setq eh-answers (append eh-answers (list answer))))

;;; ---------------------------------------------------------------------
;;; §6.5 SIGUSR2 hang recovery

(defun eh--sigusr2-handler (&rest _)
  "Unwind whatever blocking read Emacs is stuck in, via the debugger."
  (debug 'eh-sigusr2))

(define-key special-event-map [sigusr2] #'eh--sigusr2-handler)

;;; ---------------------------------------------------------------------
;;; §6.2 the file-based eval protocol

(defun eh--read-form-from-file (path)
  (with-temp-buffer
    (insert-file-contents path)
    (goto-char (point-min))
    (read (current-buffer))))

(defun eh--type-name (value)
  (cond
   ((null value) "null")
   ((eq value t) "boolean")
   ((integerp value) "integer")
   ((floatp value) "float")
   ((stringp value) "string")
   ((symbolp value) "symbol")
   ((consp value) "cons")
   ((vectorp value) "vector")
   ((hash-table-p value) "hash-table")
   (t (symbol-name (type-of value)))))

(defconst eh--value-cap-bytes 65536
  "Cap on the size of a prin1'd :value before it is spilled to a file.")

(defun eh--prin1-to-string-unlimited (value)
  (let ((print-level nil) (print-length nil) (print-circle t))
    (prin1-to-string value)))

(defvar eh--captured-backtrace nil)

(defun eh--eval-capturing (form)
  "Evaluate FORM.  Return (:ok VALUE) or (:error ERR :backtrace STRING)."
  (let ((tag (make-symbol "eh-eval-done"))
        (eh--captured-backtrace nil))
    (catch tag
      (let ((debug-on-error t)
            (debug-on-quit t)
            (debugger
             (lambda (&rest args)
               (setq eh--captured-backtrace (with-output-to-string (backtrace)))
               (throw tag (list :error
                                 (if (eq (car args) 'error) (cadr args) args)
                                 :backtrace eh--captured-backtrace)))))
        (throw tag (list :ok (eval form t)))))))

(defun eh--new-messages (mark)
  (if (not (get-buffer "*Messages*"))
      []
    (with-current-buffer "*Messages*"
      (let ((text (buffer-substring-no-properties
                    (min mark (point-max)) (point-max))))
        (vconcat (split-string text "\n" t))))))

(defun eh--error-payload (err)
  (let ((symbol (if (consp err) (car err) err))
        (data (if (consp err) (cdr err) nil)))
    `((symbol . ,(format "%s" symbol))
      (data . ,(vconcat (mapcar (lambda (d) (format "%s" d)) data)))
      (message . ,(error-message-string err)))))

(defun eh-driver-run (req-id)
  "Entry point called via `emacsclient --eval'.  Reads in/REQ-ID.el,
evaluates it, writes out/REQ-ID.json.  Returns REQ-ID."
  (let* ((in-file (expand-file-name (format "in/%s.el" req-id) eh-run-dir))
         (out-file (expand-file-name (format "out/%s.json" req-id) eh-run-dir))
         (value-file (expand-file-name (format "out/%s.value" req-id) eh-run-dir))
         (form (eh--read-form-from-file in-file))
         (messages-before (if (get-buffer "*Messages*")
                               (with-current-buffer "*Messages*" (point-max))
                             0))
         (start (float-time))
         (stdout-buf (generate-new-buffer " *eh-stdout*"))
         result stdout envelope)
    (unwind-protect
        (progn
          (setq result (let ((standard-output stdout-buf)) (eh--eval-capturing form)))
          (setq stdout (with-current-buffer stdout-buf (buffer-string)))
          (let ((elapsed (round (* 1000 (- (float-time) start)))))
            (setq envelope
                  (pcase result
                    (`(:ok ,value)
                     (if (and (consp value) (eq (car value) :eh-raw-json))
                         `((ok . t)
                           (value . ,(let ((json-object-type 'alist)
                                            (json-array-type 'vector)
                                            (json-key-type 'symbol))
                                       (json-read-from-string (cdr value))))
                           (value_type . "json")
                           (messages . ,(eh--new-messages messages-before))
                           (stdout . ,stdout)
                           (elapsed_ms . ,elapsed))
                       (let ((text (eh--prin1-to-string-unlimited value)))
                         (if (> (length text) eh--value-cap-bytes)
                             (progn
                               (with-temp-file value-file (insert text))
                               `((ok . t)
                                 (value_file . ,value-file)
                                 (value_type . ,(eh--type-name value))
                                 (messages . ,(eh--new-messages messages-before))
                                 (stdout . ,stdout)
                                 (elapsed_ms . ,elapsed)))
                           `((ok . t)
                             (value . ,text)
                             (value_type . ,(eh--type-name value))
                             (messages . ,(eh--new-messages messages-before))
                             (stdout . ,stdout)
                             (elapsed_ms . ,elapsed))))))
                    (`(:error ,err :backtrace ,bt)
                     `((ok . :json-false)
                       (error . ,(append (eh--error-payload err) `((backtrace . ,bt))))
                       (messages . ,(eh--new-messages messages-before))
                       (stdout . ,stdout)
                       (elapsed_ms . ,elapsed))))))
          (with-temp-file out-file
            (insert (let ((json-encoding-pretty-print nil)) (json-encode envelope)))))
      (kill-buffer stdout-buf))
    req-id))

(defun eh--raw-json (str)
  "Mark STR as already-JSON text so `eh-driver-run' inlines it verbatim."
  (cons :eh-raw-json str))

;;; ---------------------------------------------------------------------
;;; §6.2 eh-snapshot -- the workhorse

(defun eh--face-at (pos)
  (let ((f (get-char-property pos 'face)))
    (cond ((null f) nil)
          ((symbolp f) (symbol-name f))
          ((listp f) (mapcar (lambda (x) (format "%s" x)) f))
          (t (format "%s" f)))))

(defun eh--overlays-at-sorted (pos)
  (sort (overlays-at pos)
        (lambda (a b)
          (or (< (overlay-start a) (overlay-start b))
              (and (= (overlay-start a) (overlay-start b))
                   (< (overlay-end a) (overlay-end b)))))))

(defun eh--overlay-props (ov props)
  (let (out)
    (dolist (p (or props (eh--overlay-all-prop-names ov)))
      (let ((v (overlay-get ov p)))
        (when v (push (cons p (eh--prop-value->json v)) out))))
    (nreverse out)))

(defun eh--overlay-all-prop-names (ov)
  (let (names (plist (overlay-properties ov)))
    (while plist (push (car plist) names) (setq plist (cddr plist)))
    (nreverse names)))

(defconst eh--prop-value-cap 512)

(defun eh--prop-value->json (v)
  (cond
   ((stringp v)
    (if (> (length v) eh--prop-value-cap)
        (format "<%d bytes, sha256:%s>" (length v) (secure-hash 'sha256 v))
      v))
   ((or (symbolp v) (numberp v)) (format "%s" v))
   (t (eh--prin1-to-string-unlimited v))))

(defun eh--display-descriptor (pos)
  (let ((disp (get-char-property pos 'display)))
    (cond
     ((null disp) nil)
     ((and (consp disp) (eq (car disp) 'image))
      (let* ((size (ignore-errors (image-size disp t)))
             (data (plist-get (cdr disp) :data))
             (file (plist-get (cdr disp) :file))
             (bytes (cond (data data)
                          (file (ignore-errors
                                  (with-temp-buffer
                                    (insert-file-contents-literally file)
                                    (buffer-string))))
                          (t nil))))
        `((kind . "image")
          (type . ,(format "%s" (plist-get (cdr disp) :type)))
          (width_px . ,(if size (car size) :json-false))
          (height_px . ,(if size (cdr size) :json-false))
          (scale . ,(or (plist-get (cdr disp) :scale) 1.0))
          (slice . ,(if (plist-get (cdr disp) :slice)
                        (format "%s" (plist-get (cdr disp) :slice))
                      :json-false))
          (sha256 . ,(if bytes (secure-hash 'sha256 bytes) :json-false))
          (bytes . ,(if bytes (length bytes) 0)))))
     ((stringp disp) `((kind . "rule") (text . ,disp)))
     (t `((kind . "other") (repr . ,(eh--prin1-to-string-unlimited disp)))))))

(defun eh--run-boundaries (beg end)
  "Return the sorted list of positions in [BEG,END] where any of
face/display/read-only/invisible/the overlay set changes."
  (let ((pos beg) (marks (list beg)))
    (while (< pos end)
      (setq pos (next-single-char-property-change pos 'face nil end))
      (push pos marks))
    (setq pos beg)
    (while (< pos end)
      (setq pos (next-single-char-property-change pos 'display nil end))
      (push pos marks))
    (setq pos beg)
    (while (< pos end)
      (setq pos (next-single-char-property-change pos 'read-only nil end))
      (push pos marks))
    (setq pos beg)
    (while (< pos end)
      (setq pos (next-overlay-change pos))
      (when (<= pos end) (push pos marks)))
    (push end marks)
    (sort (delete-dups marks) #'<)))

(cl-defun eh-snapshot (&key buffer window region props visible-only no-text images)
  "Structured, diffable description of a buffer or window.  See DESIGN §6.2."
  (let* ((buf (if buffer (get-buffer buffer) (current-buffer))))
    (unless buf (error "eh: no such buffer: %s" buffer))
    (with-current-buffer buf
      (let* ((win (get-buffer-window buf))
             (beg (if region (car region)
                    (if (and visible-only win) (window-start win) (point-min))))
             (end (if region (cadr region)
                    (if (and visible-only win) (window-end win t) (point-max))))
             (header
              `((version . 1)
                (buffer . ,(buffer-name buf))
                (point . ,(point))
                (mark . ,(if (mark t) (mark t) :json-false))
                (modified . ,(if (buffer-modified-p) t :json-false))
                (major-mode . ,(format "%s" major-mode))
                (minor-modes . ,(vconcat (mapcar #'symbol-name
                                                  (eh--active-minor-modes))))
                (mode-line . ,(format-mode-line mode-line-format nil win buf))))
             (win-info
              (when (and window win)
                `((window . ((start . ,(window-start win))
                             (end . ,(window-end win t))
                             (height-lines . ,(window-body-height win))
                             (width-cols . ,(window-body-width win))
                             (vscroll . ,(window-vscroll win t))
                             (point-visible . ,(if (pos-visible-in-window-p (point) win)
                                                    t :json-false)))))))
             runs)
        (unless no-text
          (let ((bounds (eh--run-boundaries beg end)))
            (cl-loop for (a b) on bounds while b do
                     (when (< a b)
                       (push (eh--describe-run a b props images) runs)))))
        (append header win-info `((runs . ,(vconcat (nreverse runs)))))))))

(defun eh--active-minor-modes ()
  (let (out)
    (dolist (m minor-mode-list)
      (when (and (boundp m) (symbol-value m)) (push m out)))
    (nreverse out)))

(defun eh--describe-run (beg end props images)
  (let* ((text (buffer-substring-no-properties beg end))
         (face (eh--face-at beg))
         (ro (get-char-property beg 'read-only))
         (invisible (get-char-property beg 'invisible))
         (disp (and images (eh--display-descriptor beg)))
         (ovs (eh--overlays-at-sorted beg)))
    `((beg . ,beg) (end . ,end) (text . ,text)
      (face . ,(or face :json-false))
      (read-only . ,(if ro t :json-false))
      (invisible . ,(if invisible t :json-false))
      ,@(if disp `((display . ,disp)) nil)
      (overlays . ,(vconcat
                    (mapcar (lambda (ov)
                              `((start . ,(overlay-start ov))
                                (end . ,(overlay-end ov))
                                (props . ,(eh--overlay-props ov props))))
                            ovs))))))

(defun eh-snapshot-json (&rest args)
  (eh--raw-json (let ((json-encoding-pretty-print nil))
                  (json-encode (apply #'eh-snapshot args)))))

;;; ---------------------------------------------------------------------
;;; eh-describe

(defun eh-describe ()
  `((session . ,(or eh-session-name "?"))
    (emacs-version . ,emacs-version)
    (features . ,(vconcat (mapcar #'symbol-name
                                  (cl-remove-if-not
                                   (lambda (f) (memq f features))
                                   '(cairo pgtk x xwidgets)))))
    (graphic . ,(if (display-graphic-p) t :json-false))
    (frame . ,(if (display-graphic-p)
                  `((width-px . ,(frame-pixel-width))
                    (height-px . ,(frame-pixel-height))
                    (width-cols . ,(frame-width))
                    (height-lines . ,(frame-height)))
                :json-false))
    (buffers . ,(vconcat
                 (mapcar (lambda (b)
                           `((name . ,(buffer-name b))
                             (mode . ,(with-current-buffer b (format "%s" major-mode)))
                             (size . ,(buffer-size b))))
                         (buffer-list))))
    (window-tree . ,(eh--prin1-to-string-unlimited
                     (window-tree)))))

(defun eh-describe-json () (eh--raw-json (json-encode (eh-describe))))

;;; ---------------------------------------------------------------------
;;; §6.5 eh-wait / eh-settle

(define-error 'eh-timeout "eh: wait timed out")

(defun eh-wait (predicate &optional timeout poll)
  "Block until PREDICATE returns non-nil.  Signal `eh-timeout' otherwise."
  (let ((deadline (+ (float-time) (or timeout 30)))
        (poll (or poll 0.05)))
    (catch 'eh-wait-done
      (while t
        (when (funcall predicate) (throw 'eh-wait-done t))
        (when (> (float-time) deadline)
          (signal 'eh-timeout (list (eh-snapshot :window t))))
        (accept-process-output nil poll)
        (sit-for 0)))))

(defun eh-wait-form (form-text &optional timeout poll)
  (eh-wait (lambda () (eval (read form-text) t)) timeout poll))

(defun eh-wait-name (name &optional timeout poll)
  (let ((cell (assoc name eh-waiters)))
    (unless cell (error "eh: no such waiter: %s" name))
    (eh-wait (cdr cell) timeout poll)))

(defun eh-register-waiter (name predicate)
  (setq eh-waiters (cons (cons name predicate)
                          (assoc-delete-all name eh-waiters))))

(defun eh--frame-hash ()
  (secure-hash 'sha256 (eh--export-frame-bytes 'png)))

(cl-defun eh-settle (&key (timeout 5) (quiet-ms 150) (frames-stable 2))
  "Spin until quiescent: no pending process output, no imminent timers,
and FRAMES-STABLE consecutive frame-export hashes equal."
  (let ((deadline (+ (float-time) timeout))
        (last-hash nil) (stable-count 0))
    (catch 'done
      (while t
        (when (> (float-time) deadline) (throw 'done nil))
        (accept-process-output nil (/ quiet-ms 1000.0))
        (sit-for 0)
        (if (display-graphic-p)
            (let ((h (eh--frame-hash)))
              (if (equal h last-hash) (cl-incf stable-count) (setq stable-count 1))
              (setq last-hash h)
              (when (>= stable-count frames-stable) (throw 'done t)))
          (throw 'done t))))))

;;; ---------------------------------------------------------------------
;;; §6.3 click coordinate helper

(defun eh-display-xy (pos &optional window)
  "Display pixel coordinates of buffer POS, or nil if not visible."
  (let ((p (window-absolute-pixel-position pos window)))
    (when p
      (cons (+ (car p) (/ (default-font-width) 2))
            (+ (cdr p) (/ (default-line-height) 2))))))

(defun eh-display-xy-json (pos)
  (let ((xy (eh-display-xy pos)))
    (eh--raw-json (json-encode (if xy `((x . ,(car xy)) (y . ,(cdr xy))) :json-false)))))

;;; ---------------------------------------------------------------------
;;; §6.3 eh keys / eh type (command-loop path)

(defun eh-send-keys (&rest key-descriptions)
  (dolist (k key-descriptions)
    (execute-kbd-macro (kbd k)))
  t)

(defun eh-type-text (text)
  (execute-kbd-macro (string-to-vector text))
  t)

(defun eh-scroll-pixels (n)
  "Scroll the selected window by N pixels.  `pixel-scroll-precision-mode'
only exists on Emacs 29+; fall back to `set-window-vscroll' (available
since Emacs 24) so this works across the whole 27.1+ matrix (§13.3)."
  (if (fboundp 'pixel-scroll-precision-scroll-up)
      (if (>= n 0)
          (pixel-scroll-precision-scroll-up n)
        (pixel-scroll-precision-scroll-down (- n)))
    (set-window-vscroll nil (max 0 (+ (window-vscroll nil t) n)) t))
  t)

;;; ---------------------------------------------------------------------
;;; §6.4 frame export

(defun eh--export-frame-bytes (type)
  (unless (fboundp 'x-export-frames)
    (error "eh: x-export-frames unavailable (not a cairo build?)"))
  (x-export-frames nil type))

(defun eh-shot-to-file (path &optional type)
  (let* ((type (or type 'png))
         (bytes (eh--export-frame-bytes type))
         (cursor-type nil))
    (with-temp-file path
      (set-buffer-multibyte nil)
      (insert bytes))
    `((path . ,path)
      (bytes . ,(length bytes))
      (sha256 . ,(secure-hash 'sha256 bytes)))))

(defun eh-shot-to-file-json (path &optional type)
  (eh--raw-json (json-encode (eh-shot-to-file path type))))

;;; ---------------------------------------------------------------------
;;; §6.4/§8.3 baselines and pixel diff
;;;
;;; Pixel comparison happens *inside Emacs*, via `call-process' to
;;; ImageMagick, for the same reason scenarios run inside Emacs (§8.1):
;;; `eh-expect-no-visual-drift' is called mid-scenario, with no channel
;;; back out to `ehd'.  The CLI-level `eh diff-shot'/`eh baseline accept'
;;; commands are thin `emacs_eval' wrappers around these same functions
;;; (see ehd.py), so there is exactly one implementation of the compare.

(defun eh--emacs-version-dir ()
  (format "%d.%d" emacs-major-version emacs-minor-version))

(defun eh-baseline-dir ()
  "Directory holding baselines for the current profile, Emacs version,
geometry and theme (DESIGN §8.4: baselines/<emacs>/<geometry>/<theme>/)."
  (unless eh-profile-dir (error "eh: eh-profile-dir is unset"))
  (expand-file-name
   (format "%s/%s/%s" (eh--emacs-version-dir)
           (or eh-session-geometry "unknown-geometry")
           (or eh-session-theme "default"))
   (expand-file-name "baselines" eh-profile-dir)))

(defun eh-baseline-path (name)
  (expand-file-name (format "%s.png" name) (eh-baseline-dir)))

(defun eh-baseline-mask-path (name)
  (expand-file-name (format "%s.mask.json" name) (eh-baseline-dir)))

(defun eh--read-mask-json (path)
  "Read a NAME.mask.json baseline sidecar: a JSON array of rectangles
\[{\"x\":..,\"y\":..,\"w\":..,\"h\":..}, ...] excluded from pixel comparison
\(DESIGN §6.4).  Each rectangle comes back as a list (X Y W H)."
  (when (file-exists-p path)
    (let* ((json-object-type 'alist) (json-array-type 'list) (json-key-type 'symbol)
           (rects (json-read-file path)))
      (mapcar (lambda (r) (list (cdr (assq 'x r)) (cdr (assq 'y r))
                                 (cdr (assq 'w r)) (cdr (assq 'h r))))
              rects))))

(defun eh--masked-copy (src masks dest)
  "Copy image SRC to DEST with each (X Y W H) rect in MASKS blacked out,
so masked regions read as identical in both images being compared and so
contribute nothing to the pixel-diff count."
  (let ((args (list src)))
    (dolist (m masks)
      (cl-destructuring-bind (x y w h) m
        (setq args (append args
                            (list "-fill" "black" "-draw"
                                  (format "rectangle %d,%d,%d,%d" x y (+ x w) (+ y h)))))))
    (setq args (append args (list dest)))
    (let ((code (apply #'call-process "convert" nil nil nil args)))
      (unless (zerop code) (error "eh: convert (mask) exited %d" code)))
    dest))

(defun eh--png-pixel-count (path)
  (with-temp-buffer
    (call-process "identify" nil t nil "-format" "%w %h" path)
    (let ((parts (split-string (buffer-string))))
      (* (string-to-number (or (nth 0 parts) "0"))
         (string-to-number (or (nth 1 parts) "0"))))))

(defun eh--compare-ae (actual baseline diff-out)
  "Run ImageMagick `compare -metric AE', return the changed-pixel count.
Signals an error on a real comparison failure (size mismatch, missing
file); exit 1 -- \"images differ\" -- is the expected common case, not
an error."
  (with-temp-buffer
    (let ((code (call-process "compare" nil t nil
                               "-metric" "AE" "-fuzz" "1%" actual baseline diff-out)))
      (let* ((s (string-trim (buffer-string)))
             (n (and (string-match-p "\\`[0-9.]+\\'" s) (string-to-number s))))
        (if (memq code '(0 1))
            (or n (error "eh: compare produced no AE value: %s" s))
          (error "eh: compare exited %d: %s" code s))))))

(cl-defun eh-diff-shot (name &key tolerance mask out-dir)
  "Screenshot the frame and compare it against the profile's baseline for
NAME under the session's Emacs version/geometry/theme (§6.4, §8.3).
MASK, given, overrides the baseline's own NAME.mask.json sidecar; each
entry is a (X Y W H) rectangle.  Returns a plist:
\(:ok BOOL :changed-pixels N :total-pixels N :ratio F
 :actual PATH :diff PATH-OR-NIL :baseline PATH :error STRING-OR-NIL\)."
  (let* ((tolerance (or tolerance 0.002))
         (out-dir (or out-dir eh-run-dir))
         (actual (expand-file-name (format "%s.actual.png" name) out-dir))
         (baseline (eh-baseline-path name)))
    (make-directory out-dir t)
    (eh-shot-to-file actual)
    (if (not (file-exists-p baseline))
        (list :ok nil :changed-pixels nil :total-pixels nil :ratio nil
              :actual actual :diff nil :baseline baseline
              :error (format "no baseline for %s at %s -- run `eh baseline accept %s'"
                              name baseline name))
      (condition-case err
          (let* ((diff (expand-file-name (format "%s.diff.png" name) out-dir))
                 (masks (or mask (eh--read-mask-json (eh-baseline-mask-path name))))
                 (cmp-actual (if masks
                                 (eh--masked-copy actual masks
                                                   (expand-file-name (format "%s.actual-masked.png" name) out-dir))
                               actual))
                 (cmp-baseline (if masks
                                    (eh--masked-copy baseline masks
                                                      (expand-file-name (format "%s.baseline-masked.png" name) out-dir))
                                  baseline))
                 (changed (eh--compare-ae cmp-actual cmp-baseline diff))
                 (total (eh--png-pixel-count actual))
                 (ratio (if (> total 0) (/ (float changed) total) 1.0)))
            (list :ok (<= ratio tolerance) :changed-pixels changed :total-pixels total
                  :ratio ratio :actual actual :diff diff :baseline baseline :error nil))
        (error (list :ok nil :changed-pixels nil :total-pixels nil :ratio nil
                      :actual actual :diff nil :baseline baseline
                      :error (error-message-string err)))))))

(defun eh-diff-shot-json (name &optional tolerance)
  (let ((r (eh-diff-shot name :tolerance tolerance)))
    (eh--raw-json
     (json-encode
      `((ok . ,(if (plist-get r :ok) t :json-false))
        (changed_pixels . ,(or (plist-get r :changed-pixels) :json-false))
        (total_pixels . ,(or (plist-get r :total-pixels) :json-false))
        (ratio . ,(or (plist-get r :ratio) :json-false))
        (actual . ,(plist-get r :actual))
        (diff . ,(or (plist-get r :diff) :json-false))
        (baseline . ,(plist-get r :baseline))
        (error . ,(or (plist-get r :error) :json-false)))))))

(cl-defun eh-baseline-accept (name &key all out-dir)
  "Copy actual screenshot(s) captured by a prior `eh-diff-shot' into the
baseline directory for the current Emacs version/geometry/theme.  With
ALL non-nil, accept every *.actual.png found in OUT-DIR (default
`eh-run-dir'), ignoring NAME.  Returns the list of names accepted."
  (let* ((out-dir (or out-dir eh-run-dir))
         (names (if all
                    (mapcar (lambda (f) (string-remove-suffix ".actual.png" (file-name-nondirectory f)))
                            (directory-files out-dir nil "\\.actual\\.png\\'"))
                  (list name))))
    (make-directory (eh-baseline-dir) t)
    (let (accepted)
      (dolist (n names)
        (let ((src (expand-file-name (format "%s.actual.png" n) out-dir)))
          (when (and n (file-exists-p src))
            (copy-file src (eh-baseline-path n) t)
            (push n accepted))))
      (nreverse accepted))))

(defun eh-baseline-accept-json (name all)
  (let ((accepted (eh-baseline-accept (unless (or (null name) (string-empty-p name)) name)
                                       :all (and all t))))
    (eh--raw-json (json-encode `((ok . t) (accepted . ,(vconcat accepted)))))))

;;; ---------------------------------------------------------------------
;;; §12 eh doctor

(defun eh--check (label ok detail)
  `((check . ,label) (ok . ,(if ok t :json-false)) (detail . ,detail)))

(defun eh-doctor ()
  (let* ((graphic (display-graphic-p))
         (cairo (and (fboundp 'x-export-frames)
                     (member "cairo" (split-string system-configuration-features))))
         (export-ok
          (and (fboundp 'x-export-frames)
               (ignore-errors
                 (let ((bytes (x-export-frames nil 'png)))
                   (and bytes (> (length bytes) 1024)
                        (string-prefix-p "\x89PNG" bytes))))))
         (coord (ignore-errors (eh-display-xy (point-min))))
         (scaling (eq image-scaling-factor 1.0))
         (font-name (ignore-errors
                      (font-get (face-attribute 'default :font) :name))))
    (vconcat
     (list
      (eh--check "graphic-display" graphic (format "%s" graphic))
      (eh--check "cairo" (and cairo t) (format "%s" system-configuration-features))
      (eh--check "x-export-frames-produces-png" export-ok "png magic + size")
      (eh--check "pgtk" t (format "%s" (and (featurep 'pgtk) t)))
      (eh--check "window-absolute-pixel-position"
                 (consp coord) (format "%s" coord))
      (eh--check "image-types"
                 (image-type-available-p 'png)
                 (format "png=%s svg=%s jpeg=%s"
                         (image-type-available-p 'png)
                         (image-type-available-p 'svg)
                         (image-type-available-p 'jpeg)))
      (eh--check "image-scaling-factor-pinned" scaling (format "%s" image-scaling-factor))
      (eh--check "font-resolved" (and font-name t) (format "%s" font-name))
      (eh--check "frame-geometry"
                 (and graphic (= (frame-pixel-width) (* (frame-width)
                                                         (default-font-width))
                                 ))
                 "best-effort; see eh describe for exact pixel geometry")
      (eh--check "clock-is-utc" (equal (getenv "TZ") "UTC") (format "%s" (getenv "TZ")))))))

(defun eh-doctor-json () (eh--raw-json (json-encode (eh-doctor))))

;;; ---------------------------------------------------------------------
;;; server startup

(defun eh-driver-start-server ()
  (require 'server)
  (setq server-use-tcp nil)
  (setq server-name (or (getenv "EH_SOCKET_NAME") "server"))
  (when (boundp 'server-socket-dir)
    (setq server-socket-dir eh-run-dir))
  (unless (process-live-p (and (boundp 'server-process) server-process))
    (server-start)))

(provide 'eh-driver)
;;; eh-driver.el ends here
