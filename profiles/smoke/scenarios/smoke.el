;;; smoke.el --- proves the core is package-agnostic (DESIGN.md §8.5) -*- lexical-binding: t; -*-

(eh-scenario smoke/open-file-and-screenshot
  :doc "Opening a fixture and pressing a key is visible in the buffer and
        the frame actually rasterises."
  :fixture "hello.txt"
  :tags (smoke)
  :needs (:cairo t)

  (eh-expect-match "line one" (buffer-string))
  (goto-char (point-min))
  (eh-expect-no-error (eh-shot-to-file
                        (expand-file-name "open-file.png"
                                           (eh--scenario-artifact-dir
                                            'smoke/open-file-and-screenshot)))))

(eh-scenario smoke/face-assertion
  :doc "A key binding that faces text is exercised through the real
        command loop, and the resolved face is asserted -- tier 1, no
        pixels."
  :fixture "hello.txt"
  :tags (smoke)

  (eh-send-keys "C-c C-s")
  (goto-char (point-min))
  (search-forward "SMOKE-MARKER")
  (eh-expect-face (match-beginning 0) 'smoke-marker-face)
  (eh-expect-equal (buffer-modified-p) nil
                    "facing text via text properties must not mark the buffer modified"))

(eh-scenario smoke/image-renders
  :doc "A fixed PNG fixture, inserted via a real key binding, actually
        decodes: assert the image display property and its pixel size."
  :fixture "hello.txt"
  :tags (smoke)
  :needs (:cairo t)

  (eh-send-keys "C-c C-i")
  (goto-char (point-max))
  (let ((pos (1- (point))))
    (eh-expect-display-image pos :type 'png :min-width 16)))

(eh-scenario smoke/image-slices-are-addressable
  :doc "A tall image inserted via the built-in `insert-sliced-image'
        (no external package needed) produces one separately
        addressable run per slice, each with distinct, computable
        geometry -- proves `eh-snapshot's :slice reporting and gives
        durable regression coverage for the position math `eh click'
        depends on (DESIGN.md §14 phase 2's slicing acceptance test)."
  :fixture "hello.txt"
  :tags (smoke slicing)
  :needs (:cairo t)

  (eh-send-keys "C-c C-l")
  (let* ((runs (alist-get 'runs (eh-snapshot :images t)))
         (slice-runs (seq-filter
                      (lambda (r) (consp (alist-get 'slice (alist-get 'display r))))
                      runs)))
    (eh-expect-equal (length slice-runs) smoke-sliced-image-rows
                      "expected one run per slice row")
    (let* ((hashes (delete-dups
                     (mapcar (lambda (r) (alist-get 'sha256 (alist-get 'display r))) slice-runs)))
           (ys (mapcar (lambda (r) (alist-get 'y_px (alist-get 'slice (alist-get 'display r))))
                       slice-runs)))
      (eh-expect-equal (length hashes) 1
                        "every slice must come from the same source image")
      (eh-expect-equal ys (sort (copy-sequence ys) #'<)
                        "slice y offsets must be in top-to-bottom order")
      (eh-expect-equal (length (delete-dups (copy-sequence ys))) smoke-sliced-image-rows
                        "slice y offsets must all be distinct"))
    ;; the third slice (1-indexed) is what `eh click' targets interactively
    ;; (DESIGN's own phrasing); assert its buffer position and geometry are
    ;; exactly what a click needs to resolve a pixel coordinate from.
    (let* ((third (nth 2 slice-runs))
           (slice (alist-get 'slice (alist-get 'display third))))
      (eh-expect (>= (alist-get 'beg third) 1) "third slice has a buffer position")
      (eh-expect-equal (alist-get 'y_px slice) 200
                        "third slice starts 2 rows (400px) into a 500px, 5-row image"))))

(eh-scenario smoke/diff-shot-detects-pixel-change
  :doc "Freezes `eh-diff-shot's pass/fail contract (DESIGN.md §14 phase 2:
        \"eh diff-shot fails on a one-pixel change and passes on a
        rerun\").  Baselines are keyed per Emacs-version/geometry/theme
        (§8.4), so a baseline PNG committed to the repo would only ever
        match the one environment it was captured in and would silently
        skip everywhere else -- proving nothing in CI.  Instead this
        scenario points `eh-baseline-dir' at a scratch directory for its
        own duration, accepts a screenshot of the *current* frame as that
        scratch baseline, and then asserts against it: unchanged, it must
        pass; after a real, visible edit, it must fail.  Same production
        code path (`eh-diff-shot'/`eh-baseline-accept'), fully
        environment-independent."
  :fixture "hello.txt"
  :tags (smoke visual)
  :needs (:cairo t)

  (let* ((scratch (make-temp-file "eh-diff-shot-selftest" t))
         (eh-profile-dir scratch)
         (name "self-test"))
    (unwind-protect
        (progn
          (let ((r0 (eh-diff-shot name)))
            (eh-expect (plist-get r0 :no-baseline)
                       "a name with no accepted baseline yet must be reported as such, not as a mismatch"))
          (eh-baseline-accept name)
          (let ((r1 (eh-diff-shot name)))
            (eh-expect (plist-get r1 :ok)
                       (format "an unchanged frame must diff-shot clean against its own just-accepted baseline: %S" r1))
            (eh-expect-equal (plist-get r1 :changed-pixels) 0
                              "an identical rerun must show zero changed pixels"))
          (eh-send-keys "C-c C-l")
          (eh-settle)
          (let ((r2 (eh-diff-shot name)))
            (eh-expect (not (plist-get r2 :ok))
                       "a real, visible frame change must fail diff-shot against the prior baseline")
            (eh-expect (> (plist-get r2 :changed-pixels) 0)
                       "a real, visible frame change must report a nonzero changed-pixel count")))
      (delete-directory scratch t))))

(eh-scenario smoke/visual-drift-skips-without-baseline
  :doc "`eh-expect-no-visual-drift', the scenario-facing wrapper around
        `eh-diff-shot', must `ert-skip' -- not fail and not silently pass
        -- when nobody has ever run `eh baseline accept' for a name under
        the current Emacs-version/geometry/theme (§8.4).  Uses a name no
        profile will ever accept a baseline for, so this scenario reports
        `skipped' in `eh run's summary on every environment, forever;
        that is the correct, expected outcome, not a regression."
  :fixture "hello.txt"
  :tags (smoke visual)
  :needs (:cairo t)

  (eh-expect-no-visual-drift "never-baselined-by-design"))
