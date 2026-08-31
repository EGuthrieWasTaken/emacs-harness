;;; eh-init-core.el --- shared init loaded by every session -*- lexical-binding: t; -*-

;; Loaded by the per-session generated init file (written by ehd at
;; `eh session new' time) *before* the profile's own init.el.  That
;; generated file sets `eh-session-name', `eh-run-dir' and `eh-strict-prompts'
;; as plain `setq' forms, then does:
;;
;;   (load "/opt/eh/elisp/eh-init-core.el")
;;   (load "<profile>/init.el")
;;   (eh-driver-start-server)
;;
;; This file is the *only* thing between "-Q" and the profile's own config,
;; per DESIGN.md §7.1 ("Never inherit the developer's config").

(add-to-list 'load-path "/opt/eh/elisp")
(require 'eh-driver)
(require 'eh-scenario)
(require 'eh-profile)

(eh-apply-determinism-settings
 (and (boundp 'eh-frame-width) eh-frame-width)
 (and (boundp 'eh-frame-height) eh-frame-height)
 (and (boundp 'eh-frame-font) eh-frame-font))

(setq-default indent-tabs-mode nil)

(setenv "NO_AT_BRIDGE" "1")

(provide 'eh-init-core)
;;; eh-init-core.el ends here
