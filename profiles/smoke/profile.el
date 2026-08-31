;;; profile.el --- the trivial profile that proves the core is generic -*- lexical-binding: t; -*-

;; DESIGN.md §8.5: no external services, three scenarios (open a file,
;; press a key, take a screenshot; assert a face; assert an image
;; renders).  If `eh run smoke' ever needs Jupyter, the profile
;; abstraction has broken.

(eh-defprofile smoke
  :requires ()
  :snapshot-props (smoke-marker)
  :waiters ((smoke-ready . (lambda () t)))
  :log-buffers ("*Messages*"))
