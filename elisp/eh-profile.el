;;; eh-profile.el --- declarative profile manifest -*- lexical-binding: t; -*-

;; A profile is a directory (DESIGN §8.4).  `eh-defprofile' is the
;; in-Emacs half of a profile's manifest: it registers snapshot
;; properties, named waiters, and log buffers/files to sweep into the
;; failure bundle.  It is loaded as part of `profiles/<name>/init.el'.
;;
;; Orchestration metadata that `ehd' needs *before* Emacs starts
;; (geometry, theme, which services to bring up, the batch test file)
;; lives in the sibling `profile.json', which `ehd' reads directly --
;; asking a not-yet-started Emacs to parse its own manifest would be
;; circular.

(require 'eh-driver)

(defvar eh-profile-plist nil)

(defmacro eh-defprofile (name &rest kvs)
  (declare (indent 1))
  `(progn
     (setq eh-profile-name ',name)
     (setq eh-profile-plist ',kvs)
     ,(let ((snapshot-props (plist-get kvs :snapshot-props))
            (waiters (plist-get kvs :waiters))
            (log-buffers (plist-get kvs :log-buffers)))
        `(progn
           ,(when snapshot-props
              `(setq eh-default-snapshot-props ',snapshot-props))
           ,(when log-buffers
              `(setq eh-profile-log-buffers ',log-buffers))
           ,@(mapcar (lambda (w) `(eh-register-waiter ',(car w) ,(cdr w))) waiters)))))

(defvar eh-default-snapshot-props nil)
(defvar eh-profile-log-buffers nil)

(provide 'eh-profile)
;;; eh-profile.el ends here
