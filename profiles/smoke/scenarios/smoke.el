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
