;;; fake-bridge.el --- eh-fake-bridge's own coverage (DESIGN 9.2) -*- lexical-binding: t; -*-

;; `eh-fake-bridge' is core, not profile code: any profile whose package
;; fronts a backend process depends on it, so a regression in it would
;; show up as a mystery failure in *someone else's* profile, far from the
;; cause.  These scenarios live in `smoke' -- the profile whose whole job
;; is proving the core is package-agnostic (DESIGN 8.5) -- and drive the
;; bridge over a made-up protocol via plain `make-process', so they need
;; no package, no service and no kernel.

(defvar smoke-bridge--lines nil
  "Every complete line the bridge under test has written, oldest first.")

(defun smoke-bridge--filter (proc chunk)
  "Split CHUNK from PROC into lines, parse each, and append it."
  (let ((pending (concat (or (process-get proc 'pending) "") chunk)))
    (while (string-match "\n" pending)
      (let ((line (substring pending 0 (match-beginning 0))))
        (setq pending (substring pending (match-end 0)))
        (unless (string-blank-p line)
          (push (condition-case err
                    (json-parse-string line :object-type 'plist
                                       :array-type 'list
                                       :false-object nil :null-object nil)
                  ;; A truncated or garbled line is a *result* here, not
                  ;; an error: proving the bridge can produce one is the
                  ;; entire point of the `truncate-json' fault.
                  (error (list :unparseable line :why (error-message-string err))))
                smoke-bridge--lines))))
    (process-put proc 'pending pending)))

(defun smoke-bridge-start (&rest args)
  "Start `eh-fake-bridge' on the selftest script plus ARGS.
Resets the collected output, so each scenario reads only its own."
  (setq smoke-bridge--lines nil)
  (let* ((stderr (generate-new-buffer " *smoke bridge stderr*"))
         (proc (make-process :name "smoke-fake-bridge"
                             :command (apply #'eh-fake-bridge-command
                                             "selftest.jsonl" args)
                             :connection-type 'pipe
                             :noquery t
                             :coding 'utf-8-unix
                             :stderr stderr
                             :filter #'smoke-bridge--filter)))
    ;; Emacs gives the stderr pipe its own process; left alone it asks
    ;; "still has a process, kill it?" on exit and, under the prompt
    ;; guard, that question is a signalled error in an unrelated place.
    (let ((stderr-proc (get-buffer-process stderr)))
      (when stderr-proc (set-process-query-on-exit-flag stderr-proc nil)))
    (process-put proc 'stderr-buffer stderr)
    proc))

(defun smoke-bridge-send (proc request)
  "Send REQUEST (a plist) to PROC as one JSON line."
  (process-send-string proc (concat (json-serialize request) "\n")))

(defun smoke-bridge-reply (id)
  "The line answering request ID, or nil if none has arrived."
  (seq-find (lambda (l) (and (equal (plist-get l :id) id)
                             (or (plist-member l :result) (plist-member l :error))))
            (reverse smoke-bridge--lines)))

(defun smoke-bridge-outputs (id)
  "Every out-of-band `output' line for request ID, in arrival order."
  (mapcar (lambda (l) (plist-get l :output))
          (seq-filter (lambda (l) (and (equal (plist-get l :id) id)
                                       (plist-member l :output)))
                      (reverse smoke-bridge--lines))))

(defun smoke-bridge-wait (predicate &optional timeout)
  "Pump process output until PREDICATE returns non-nil, or TIMEOUT (5s).
Never a fixed sleep: what is being tested here is precisely a component
whose whole job is to make timing controllable, so a scenario that
passed because a sleep happened to be long enough would be worthless."
  (let ((deadline (+ (float-time) (or timeout 5))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall predicate)))

(eh-scenario smoke/fake-bridge-replies-to-a-request
  :doc "The base case: a scripted rule answers a matching request with
        its `reply', correlated by the request's own id."
  :tags (smoke bridge)

  (let ((proc (smoke-bridge-start)))
    (unwind-protect
        (progn
          (smoke-bridge-send proc '(:id 1 :method "ping"))
          (eh-expect (smoke-bridge-wait (lambda () (smoke-bridge-reply 1)))
                     "no reply to `ping' within the timeout")
          (eh-expect-equal (plist-get (plist-get (smoke-bridge-reply 1) :result) :pong) t))
      (delete-process proc))))

(eh-scenario smoke/fake-bridge-streams-then-repeats-in-the-reply
  :doc "Scheduled `emit' items arrive as out-of-band output lines in
        their scripted order and *before* the reply, and
        `<repeat-all-emitted>' expands to exactly those payloads --
        the streaming-reconciliation case a client has to get right."
  :tags (smoke bridge)

  (let ((proc (smoke-bridge-start)))
    (unwind-protect
        (progn
          (smoke-bridge-send proc '(:id 7 :method "run" :params (:code "count to three")))
          (eh-expect (smoke-bridge-wait (lambda () (smoke-bridge-reply 7)))
                     "no reply to the streaming request within the timeout")
          (let ((chunks (mapcar (lambda (o) (plist-get o :chunk))
                                (smoke-bridge-outputs 7)))
                (result (plist-get (smoke-bridge-reply 7) :result)))
            (eh-expect-equal chunks '("one" "two" "three")
                             "streamed chunks must arrive in scripted order")
            (eh-expect-equal (mapcar (lambda (o) (plist-get o :chunk))
                                     (plist-get result :chunks))
                             '("one" "two" "three")
                             "<repeat-all-emitted> must expand to the emitted payloads")
            ;; Ordering, not just membership: a reply that overtook its
            ;; own stream would break every client that renders as it goes.
            (let ((lines (reverse smoke-bridge--lines)))
              (eh-expect (< (seq-position lines (car (last (seq-filter
                                                            (lambda (l) (plist-member l :output))
                                                            lines))))
                            (seq-position lines (smoke-bridge-reply 7)))
                         "the reply must come after the last streamed chunk"))))
      (delete-process proc))))

(eh-scenario smoke/fake-bridge-matches-on-a-regexp-and-can-error
  :doc "A `~regexp~' value selects a different rule for the same method,
        and a rule may answer with an `error' object instead of a result."
  :tags (smoke bridge)

  (let ((proc (smoke-bridge-start)))
    (unwind-protect
        (progn
          (smoke-bridge-send proc '(:id 3 :method "run" :params (:code "make it boom")))
          (eh-expect (smoke-bridge-wait (lambda () (smoke-bridge-reply 3)))
                     "no reply to the erroring request within the timeout")
          (let ((err (plist-get (smoke-bridge-reply 3) :error)))
            (eh-expect err "expected an error object, got a result")
            (eh-expect-equal (plist-get err :status) 500)
            (eh-expect-match "bang" (plist-get err :message))))
      (delete-process proc))))

(eh-scenario smoke/fake-bridge-can-refuse-to-answer
  :doc "`never_reply' leaves a request hanging while the bridge stays
        live and keeps serving others -- the wedged-request state that
        cannot be staged against a real backend on demand.  Asserted as
        a *later* request being answered, not as a bare sleep: that is
        what proves the bridge is alive rather than merely slow."
  :tags (smoke bridge)

  (let ((proc (smoke-bridge-start)))
    (unwind-protect
        (progn
          (smoke-bridge-send proc '(:id 4 :method "wedge"))
          (smoke-bridge-send proc '(:id 5 :method "ping"))
          (eh-expect (smoke-bridge-wait (lambda () (smoke-bridge-reply 5)))
                     "the bridge stopped serving other requests while one was wedged")
          (eh-expect-equal (smoke-bridge-reply 4) nil
                           "a `never_reply' request must never be answered")
          (eh-expect (process-live-p proc) "the bridge must stay alive"))
      (delete-process proc))))

(eh-scenario smoke/fake-bridge-can-truncate-a-reply
  :doc "The `truncate-json' fault produces a line that is genuinely not
        parseable JSON.  A client's line parser has to survive this;
        without the fault there is no way to make a real backend do it."
  :tags (smoke bridge)

  (let ((proc (smoke-bridge-start)))
    (unwind-protect
        (progn
          (smoke-bridge-send proc '(:id 8 :method "truncated"))
          (eh-expect (smoke-bridge-wait
                      (lambda () (seq-find (lambda (l) (plist-member l :unparseable))
                                           smoke-bridge--lines)))
                     "expected an unparseable line from the truncate-json fault")
          (eh-expect-equal (smoke-bridge-reply 8) nil
                           "a truncated reply must not parse as a reply"))
      (delete-process proc))))

(eh-scenario smoke/fake-bridge-injects-unsolicited-events
  :doc "A top-level `at'/`inject' entry fires on a wall clock with no
        request to correlate against -- the \"something else killed the
        backend\" case."
  :tags (smoke bridge)

  (let ((proc (smoke-bridge-start)))
    (unwind-protect
        (eh-expect (smoke-bridge-wait
                    (lambda ()
                      (seq-find (lambda (l)
                                  (equal (plist-get (plist-get l :event) :type) "gone"))
                                smoke-bridge--lines)))
                   "the scheduled injection never arrived")
      (delete-process proc))))

(eh-scenario smoke/fake-bridge-keeps-stderr-out-of-the-protocol
  :doc "The `stderr-noise' fault chatters on stderr throughout.  None of
        it may appear on stdout: a package that lets a backend's warnings
        reach its protocol parser is broken, and this is what proves the
        claim either way."
  :tags (smoke bridge)

  (let ((proc (smoke-bridge-start "--fault" "stderr-noise")))
    (unwind-protect
        (progn
          (smoke-bridge-send proc '(:id 9 :method "ping"))
          (eh-expect (smoke-bridge-wait (lambda () (smoke-bridge-reply 9)))
                     "no reply while stderr was noisy")
          (eh-expect-equal
           (seq-filter (lambda (l) (plist-member l :unparseable)) smoke-bridge--lines)
           nil
           "stderr noise must never reach stdout")
          (eh-expect (smoke-bridge-wait
                      (lambda ()
                        (with-current-buffer (process-get proc 'stderr-buffer)
                          (> (buffer-size) 0)))
                      2)
                     "the stderr-noise fault produced no stderr at all"))
      (delete-process proc))))

(eh-scenario smoke/fake-bridge-reacts-to-what-the-client-answers
  :doc "A backend that asks its client a question gets the answer back on
        stdin with no method of its own, correlated only by id.  An
        `on_input' rule matches that line, so a scenario can assert on
        what the client actually sent -- the half of the exchange that is
        otherwise invisible."
  :tags (smoke bridge)

  (let ((proc (smoke-bridge-start)))
    (unwind-protect
        (progn
          (smoke-bridge-send proc '(:id 11 :method "ask"))
          (eh-expect (smoke-bridge-wait
                      (lambda ()
                        (seq-find (lambda (l) (plist-member l :input_request))
                                  smoke-bridge--lines)))
                     "the bridge never asked its question")
          ;; Answer it the way a client would: same id, no method.
          (smoke-bridge-send proc '(:id 11 :input "Dave"))
          (eh-expect (smoke-bridge-wait
                      (lambda ()
                        (seq-find (lambda (l)
                                    (equal (plist-get (plist-get l :event) :type) "heard"))
                                  smoke-bridge--lines)))
                     "the bridge did not react to the client's answer")
          (eh-expect-equal (smoke-bridge-reply 11) nil
                           "answering a prompt must not complete the request by itself"))
      (delete-process proc))))
