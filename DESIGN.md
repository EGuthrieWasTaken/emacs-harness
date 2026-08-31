# emacs-harness — design specification

**Status:** design, not implemented.
**Audience:** the agent (or human) implementing this.
**First consumer:** `jsonyter.el` 2.0.0 — see `docs/scenarios-jsonyter.md`.
**Deployment target:** the unRAID server (x86_64, dual Xeon E5-2698 v3, 128 GB
RAM), as a Docker container; reached over SSH, and viewable in a browser
through the existing Cloudflare Tunnel.

---

## 1. The problem

`jsonyter.el` is 5 000+ lines of Emacs Lisp whose most failure-prone behaviour
is *visual and interactive*:

- inline images, inserted **sliced** one slice per line so that ordinary line
  scrolling walks through a tall plot;
- cell output that is **buffer text but read-only**, written without touching
  undo or the modified flag;
- **overlay** cell boundaries, output frames, and a stale-output face that
  changes when a cell's source hash changes;
- **streaming** output and `clear_output(wait=True)` redraws;
- a **mode line** that reports live kernel state pushed from a websocket;
- **scroll discipline** — "insertion never steals point", but a window already
  at the end follows new output.

The existing suite (`test/jsonyter-tests.el`, 49 ERT tests) is excellent and
should stay, but it runs under `emacs -Q --batch`, where there is no redisplay,
no image rasterisation, no window geometry, no real key lookup, and no frame.
It can assert that an `image` display property *exists*; it cannot assert that
the PNG decoded, that slicing produced 12 addressable lines, that the rule is
drawn to the right width, or that `C-c C-e` reaches the command the keymap
claims it does.

This harness closes that gap, and does so in a way an AI agent can operate
unattended.

## 2. Goals

1. **A real GUI Emacs an agent can drive**, with real keystrokes, real mouse
   clicks, real redisplay, and screenshots.
2. **Cheap, precise assertions.** The default assertion mechanism is structured
   introspection of Emacs's own state, not image comparison.
3. **Determinism.** Two runs of the same scenario on the same image produce
   byte-identical screenshots, so pixel regressions mean something.
4. **A browser view** of the live instance, so a human — or an agent using
   Claude-in-Chrome — can watch and click.
5. **Package-agnostic.** jsonyter is a *profile*. Adding another package is
   adding a directory, not editing the core.
6. **One command runs everything**, batch ERT included, and emits a single
   artifact directory an agent can point at when reporting a failure.
7. **Reproducible across Emacs versions** — jsonyter claims 27.1+, so prove it.

## 3. Non-goals

- Not a replacement for the batch ERT suite. It *runs* it, and adds to it.
- Not a general remote-desktop product. The browser view is a debugging
  affordance, not the primary interface.
- Not multi-tenant. One user, one homelab, trusted network.
- Not a Wayland harness on day one (see §13.1 for the pgtk path).
- Not a screenshot-diff-everything system. Pixel baselines are used sparingly
  and deliberately (§8.3).

---

## 4. The central design decision

> **Assert on Emacs's data structures. Screenshot only what redisplay alone knows.**

Emacs is the most introspectable GUI application in existence. An agent driving
a browser has to squint at pixels because the DOM is a poor proxy for what the
user sees. An agent driving Emacs does not: it can ask, precisely and cheaply,

- what text is in the buffer, and what is *visible in the window*;
- every overlay covering a region, with all its properties;
- the face at any position, resolved through overlay and text-property priority;
- the `display` property of a region — including the full image descriptor with
  its `:type`, `:scale`, `:slice` and computed pixel size;
- whether a region is `read-only`, `invisible`, `intangible`, `field`;
- `window-start`, `window-end`, `point`, the scroll position in pixels;
- the rendered mode line as a string, via `format-mode-line`.

A screenshot of "cell 2's output" costs an image round-trip and answers *fuzzily*.
A structured snapshot of the same region costs a few hundred tokens of text and
answers *exactly* — including things the screenshot cannot show, like whether
the region is read-only or whether the border overlay's face is
`jsonyter-output-border-stale-face`.

So the harness offers three tiers, and the agent contract (§11) says to prefer
the cheapest tier that can answer the question:

| Tier | Mechanism | Use it for |
| --- | --- | --- |
| **1 — State** | `eh eval`, `eh snapshot`, `eh describe` | Almost everything. Text, faces, overlays, properties, geometry, mode line. |
| **2 — Input** | `eh keys`, `eh click`, `eh type` | Driving the UI through the real command loop or the real X server. |
| **3 — Pixels** | `eh shot`, `eh video`, `eh diff-shot` | Did the PNG actually rasterise? Did slicing really produce N drawable lines? Does the theme look right? Bug reports for humans. |

The corollary matters for the implementer: **build tier 1 first and build it
well.** A rich, stable `eh snapshot` is worth more than any amount of
screenshot tooling.

---

## 5. System architecture

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │ wherever Claude Code runs (Arch box, MacBook, cloud container)        │
  │                                                                      │
  │   Bash tool ──▶ bin/eh   (thin client, ~200 lines of shell or Python)│
  └───────────────────────────┬──────────────────────────────────────────┘
                              │ transport: ssh (default) │ docker exec (local)
                              │            │ http+token (phase 2, for MCP)
                              ▼
  ┌──────────────────────────────────────────────────────────────────────┐
  │ unRAID host ─ docker container `emacs-harness`                       │
  │                                                                      │
  │   ehd  (dispatcher, Python, listens on /run/eh.sock)                 │
  │    ├── session manager ──┬─ session "s1": Xvfb :99  + Emacs 29.4     │
  │    │                     ├─ session "s2": Xvfb :100 + Emacs 27.2     │
  │    │                     └─ …                                        │
  │    ├── emacsclient --socket-name=/run/eh/<s>/server   (tier 1 + 2a)  │
  │    ├── xdotool -display :<N>                          (tier 2b)      │
  │    ├── x-export-frames / import / ffmpeg              (tier 3)       │
  │    └── artifacts → /var/lib/eh/runs/<run-id>/                        │
  │                                                                      │
  │   side services                                                      │
  │    ├── jupyter-server :8888  (ipykernel, IRkernel, [IJulia])         │
  │    ├── eh-fake-bridge        (scripted jsonyter protocol, §9)        │
  │    ├── x11vnc :5900 → websockify/noVNC :6080   (browser view, §10)   │
  │    └── openbox               (minimal WM, no keybindings, no decor)  │
  └──────────────────────────────────────────────────────────────────────┘
                              ▲
                              │  https, Cloudflare Tunnel + Access
                              │
                        browser (noVNC) / Claude-in-Chrome
```

### 5.1 One image, three run modes

A single Docker image, with the entrypoint selecting a mode:

| Mode | What it does | Who uses it |
| --- | --- | --- |
| `server` | Long-lived. Starts one default session, Jupyter, VNC, and `ehd`. Stays up. | The agent exploring; the human watching. |
| `run` | One-shot. Starts a session, runs the named profile/scenarios, writes artifacts, exits with the suite's status. | CI, and `eh run` when it wants a clean instance. |
| `doctor` | Runs the environment self-check (§12) and exits. | First thing after a build. |

Rationale for one image over compose: unRAID's container UI is happiest with a
single container, and the services are tightly coupled (they share an X display
and a filesystem). Use `supervisord` inside. A `compose.yaml` should still exist
for local development and CI, splitting Jupyter into its own service so kernel
restarts don't take the harness with them — but the single-container path is
the supported deployment.

### 5.2 Sessions

A **session** is `(Xvfb display, window manager, one Emacs process, one scratch
HOME, one server socket)`. Sessions are the unit of isolation and of the
version matrix. `ehd` owns their lifecycle:

```
eh session new  --emacs 29.4 --profile jsonyter --geometry 1280x800 --name s1
eh session list
eh session reset s1        # kill Emacs, wipe scratch HOME, restart clean
eh session rm   s1
```

Every other command takes `--session` (defaulting to the only one, or to
`$EH_SESSION`). A scenario run always gets a fresh session unless
`--reuse-session` is passed — state leaking between scenarios is the single
most common source of "passes alone, fails in the suite".

Sessions are cheap: an Xvfb plus an Emacs frame is ~150–250 MB. On 128 GB,
running the whole version matrix in parallel is fine.

### 5.3 Filesystem layout inside the container

```
/opt/eh/                     harness code (baked into the image)
/opt/emacs/<version>/        pinned Emacs builds (or system emacs at /usr/bin)
/srv/package/                the package under test, bind-mounted READ-ONLY
/srv/profiles/               profiles, bind-mounted read-only (or baked)
/var/lib/eh/elpa-cache/      pinned dependency checkout, populated at build time
/var/lib/eh/runs/<run-id>/   artifacts, bind-mounted to unRAID appdata
/run/eh/<session>/           per-session: server socket, scratch HOME, fixtures
/tmp/eh-scratch-<session>/   the session's HOME (see §7.1)
```

**The package under test is mounted read-only.** A scenario that needs to edit
files copies fixtures into the session scratch dir first. This is not paranoia:
a notebook-saving test that writes into a bind-mounted source tree will
eventually eat an uncommitted change on the host.

---

## 6. The control surface

### 6.1 `eh` — the client

`bin/eh` is a thin client. It does no work itself: it serialises the subcommand
to JSON, ships it to `ehd`, prints the response, and exits with a meaningful
code. Keep it dependency-free (POSIX shell + `ssh`, or a single-file Python
script) so it drops onto a laptop, a container, or a CI runner unchanged.

Transport is chosen by `$EH_TRANSPORT` / `~/.config/eh/config`:

| Transport | Invocation | When |
| --- | --- | --- |
| `ssh` (default) | `ssh $EH_HOST -- docker exec -i emacs-harness ehd-cli …` | Agent on a laptop, harness on unRAID. Works today through the existing Cloudflare-Tunnel SSH path via a `ProxyCommand cloudflared access ssh --hostname …`. |
| `docker` | `docker exec -i emacs-harness ehd-cli …` | Agent on the unRAID host itself. |
| `local` | direct Unix socket | Inside the container, e.g. from a scenario shelling out. |
| `http` | `POST https://…/v1/<cmd>` + `CF-Access-Client-{Id,Secret}` | Phase 2. Needed for the MCP server; not needed before that. |

**Do not build the HTTP API in phase 1.** SSH + `docker exec` is one line, has
no auth surface of its own, and inherits an SSH path that is already known to
work through the tunnel. The HTTP layer earns its place only when the MCP
server arrives (§14, phase 4), and should then be a shim over the same
dispatcher, not a second implementation.

Global flags on every subcommand: `--session NAME`, `--timeout SECONDS`
(default 30), `--json` (machine-readable envelope, the default when stdout is
not a tty), `--run-dir` (write artifacts into a specific run directory).

Exit codes: `0` success · `1` assertion/scenario failure · `2` usage error ·
`3` timeout · `4` Emacs signalled an error · `5` session unreachable/dead.
An agent should be able to branch on these without parsing prose.

### 6.2 Tier 1 — state

#### `eh eval FORM`

Evaluates `FORM` in the session's Emacs and returns a JSON envelope.

The naive implementation — `emacsclient --eval` and parse stdout — is a trap:
`emacsclient` escapes newlines, truncates, and gives you no way to distinguish
a string result containing `"error"` from an actual error. Do this instead:

1. `ehd` writes the form to `/run/eh/<s>/in/<req-id>.el`.
2. It calls `emacsclient --socket-name=… --eval '(eh-driver-run "<req-id>")'`.
3. `eh-driver-run` reads the file, evaluates it under `condition-case` with a
   backtrace handler, captures new `*Messages*` lines and anything written to
   `standard-output`, and writes a JSON object to
   `/run/eh/<s>/out/<req-id>.json`. It returns only the request id.
4. `ehd` reads and returns that file.

This sidesteps every escaping and size problem, and gives you a place to put
structured error data. The envelope:

```json
{ "ok": true,
  "value": "(1 2 3)",            // prin1 form, print-level/length nil, print-circle t
  "value_type": "cons",
  "messages": ["Kernel started"], // *Messages* lines added during the call
  "stdout": "",
  "elapsed_ms": 12 }

{ "ok": false,
  "error": { "symbol": "wrong-type-argument",
             "data": ["stringp", "nil"],
             "message": "Wrong type argument: stringp, nil",
             "backtrace": "…full backtrace-to-string…" },
  "messages": [ … ], "elapsed_ms": 4 }
```

Cap `value` at ~64 KB; past that, write it to the run directory and return
`{"value_file": "…"}` so the agent can `Read` it selectively.

#### `eh snapshot` — the workhorse

Returns a structured, diffable description of a buffer or window. This is the
single most important thing in the harness; design it carefully and version it.

```
eh snapshot [--buffer NAME] [--window] [--region BEG END] [--visible-only]
            [--props P1,P2,…] [--no-text] [--images] [--format sexp|json]
```

Output is a list of **runs** — maximal spans over which every reported
attribute is constant — which keeps a 10 000-line buffer's snapshot small
while staying exact:

```elisp
((:version 1
  :buffer "analysis.ipynb"
  :point 412
  :mark nil
  :modified nil
  :major-mode python-mode
  :minor-modes (jsonyter-mode jsonyter-notebook-mode)
  :mode-line "  analysis.ipynb   py:idle [main]   (Python/Jsonyter)"
  :window (:start 1 :end 980 :height-lines 44 :width-cols 120
           :vscroll 0 :point-visible t))
 (:beg 1   :end 34  :text "# code · python\n"
  :face jsonyter-code-cell-face
  :overlays ((:id "ov1" :props (jsonyter-cell 0 jsonyter-cell-type "code"
                                before-string "…" evaporate t))))
 (:beg 34  :end 47  :text "x = 1\n"
  :face nil :read-only nil
  :text-props nil)                      ; source carries no properties
 (:beg 47  :end 48  :text "\n"
  :face jsonyter-output-border-face :read-only t
  :display (:kind rule :width-px 620))
 (:beg 48  :end 60  :text " "                     ; sliced image, 12 rows
  :read-only t
  :display (:kind image :type png :bytes 20481 :sha256 "9f2c…"
            :width-px 640 :height-px 480 :scale 1.0
            :slices 12 :slice-height-px 40 :ascent 100))
 …)
```

Rules for the implementer:

- **`:face` is the *resolved* face at the position**, computed with
  `get-char-property` semantics (overlay wins over text property, higher
  `priority` wins), not just the text property. Report the symbol, or a list of
  symbols, or an anonymous plist — whatever `face-at-point` would see.
- **`:display` decodes image descriptors.** Do not dump the raw base64 string.
  Report type, intrinsic and computed pixel size, `:scale`, and — crucially for
  jsonyter — whether the region is a *sequence of slices* and how many. Include
  a `sha256` of the image data so a scenario can assert "the same plot" without
  storing pixels. `(image-size IMG t)` gives the pixel size; `create-image`
  descriptors carry `:slice`.
- **`--window` reports what is on screen**, not what is in the buffer:
  `window-start`, `window-end`, `pos-visible-in-window-p` for point, the
  vertical scroll in pixels (`window-vscroll` with `PIXELS-P`), and the
  rendered `mode-line`/`header-line` via `format-mode-line`. jsonyter's scroll
  discipline and mode-line states are asserted from here.
- **Stability over prettiness.** The output is diffed across runs and pasted
  into agent context. Sort overlays deterministically (by `overlay-start`, then
  `overlay-end`, then a stable hash of properties — *never* by the order
  `overlays-in` happens to return, which is unspecified). Elide huge property
  values behind a length + hash. Keep the key order fixed.
- **Overlay properties and text properties are different things, and jsonyter
  uses both.** Its cell metadata (`jsonyter-cell`, `jsonyter-cell-type`,
  `jsonyter-source-end`, `jsonyter-source-hash`, `jsonyter-output-stale`,
  `jsonyter-exec-count`, …) lives entirely in **overlay** properties, while
  `read-only` is applied as a **text** property
  (`add-text-properties … '(read-only t front-sticky (read-only) rear-nonsticky t)`).
  Report the two separately — `:overlays` and `:text-props` — and never
  collapse them into one bag, or a scenario asserting "the output is read-only"
  will silently pass on an overlay that says nothing of the kind.

- **`--props`** lets a scenario ask for exactly the properties it cares about,
  e.g. `--props jsonyter-cell,jsonyter-cell-type,jsonyter-source-hash,jsonyter-output-stale`.
  Default to a profile-declared list (§8.2) rather than dumping everything.

#### `eh describe`

A one-screen orientation dump: session name, Emacs version and build features
(`cairo`, `pgtk`, image types available), frame geometry in pixels and
characters, the window tree, every live buffer with its modes and size, and the
profile's own status line (for jsonyter: the session table, kernel ids, and
bridge process state). This is what an agent should call first when it does not
know where it is.

### 6.3 Tier 2 — input

#### `eh keys KEYS…`

```
eh keys "C-c C-e"                  # through the command loop (default)
eh keys --x "C-c C-e"              # through the X server via xdotool
eh keys "C-c C-i" "x = 2" "RET"    # sequence; strings are key descriptions
```

**Default path — `execute-kbd-macro` inside Emacs.** This is the right default
and the reason matters:

- it performs real keymap lookup, so a broken or shadowed binding fails the
  test the way it fails the user;
- it runs the real command loop, so `this-command` / `last-command` chains work
  — jsonyter's history walking (`jsonyter-repl-previous-input`) and Org's
  conditional key fallthrough (`C-RET` inside a `jy:` block vs. outside) both
  depend on this, and neither is exercised by calling the function directly;
- it is **synchronous** and returns errors to the caller.

Two caveats to encode in the driver:

1. During `execute-kbd-macro`, `executing-kbd-macro` is non-nil and
   `y-or-n-p`/`read-from-minibuffer` consume from the macro. Feed answers as
   part of the key sequence, or use the prompt guard (§6.5).
2. Code that branches on `executing-kbd-macro` or `noninteractive` behaves
   differently. When testing such a path, use `--x`.

**`--x` path — `xdotool key --clearmodifiers --window <win> …`.** Goes through
the real X input stack: keyboard mapping, `input-decode-map`,
`function-key-map`, GTK's key handling. Slower, asynchronous (always follow it
with `eh wait`), and the only way to prove that `<C-return>` — a key that
famously does not exist on a terminal — actually arrives as `C-<return>`. Have
the driver translate Emacs key descriptions to xdotool syntax
(`C-c C-e` → `ctrl+c ctrl+e`, `<C-return>` → `ctrl+Return`, `S-RET` →
`shift+Return`) and *test that translator*, because it will be wrong at first.

#### `eh click`

```
eh click --at-point                       # click where point already is
eh click --at '(eh-cell-output-start 2)'  # elisp evaluating to a buffer position
eh click --at-text "Out[1]:"              # first match in the visible window
eh click --xy 640,480                     # raw display coordinates
   [--button 1|2|3] [--double] [--session s1] [--modifiers ctrl,shift]
eh drag --from '(point-min)' --to '(point-max)'
eh scroll --lines 5 | --pixels 40
```

Position → coordinate translation happens **inside Emacs**, which is the whole
trick:

```elisp
(defun eh--display-xy (pos &optional window)
  "Display pixel coordinates of buffer POS, or nil if not visible."
  (let ((p (window-absolute-pixel-position pos window)))
    (when p (cons (+ (car p) (/ (default-font-width) 2))
                  (+ (cdr p) (/ (default-line-height) 2))))))
```

`window-absolute-pixel-position` returns display-relative pixels for a visible
buffer position, which is exactly what `xdotool mousemove` wants. Offsetting to
the middle of the glyph avoids landing on a boundary. If it returns nil, the
position is scrolled off screen — the driver must `recenter` (or fail loudly)
rather than clicking at (0,0).

*Verify this API on the target Emacs during `doctor`* — see §12. It is
documented in the Elisp manual under Coordinates and Windows, but confirm the
return shape on 27.2 as well as 31.x rather than trusting this document.

#### `eh type TEXT`

Literal self-inserting text, via `execute-kbd-macro` on
`(string-to-vector TEXT)` or `insert` for speed. Prefer the macro path when the
test cares about `post-self-insert-hook`, electric modes, or jsonyter's
per-edit source-hash invalidation — which it usually does.

### 6.4 Tier 3 — pixels

#### `eh shot`

```
eh shot [--out PATH] [--frame|--display] [--crop x,y,w,h]
        [--region '(a . b)'] [--scale 0.5] [--no-cursor] [--label NAME]
```

Two capture paths, and the default matters:

- **`--frame` (default): `(x-export-frames nil 'png)` from inside Emacs.**
  Emacs renders the frame to a cairo surface and hands back the bytes. There is
  no window-manager race, no "which window was on top", no compositing, no
  stale-damage artefact, and it works identically headless. It requires a
  **cairo-enabled build** — assert that in `doctor`. It also works on a pgtk
  build, which is what makes this harness survive a future move to Wayland.
  `'svg` is also available and is worth capturing alongside PNG for text-heavy
  frames: an SVG diff tells you *what* changed, not merely *that* it did.
- **`--display`: `import -window root` (ImageMagick) or a single-frame
  `ffmpeg -f x11grab`.** Needed for anything outside the frame's own export:
  tooltips, GTK menus, child frames, multiple frames, and any case where you
  suspect the frame export itself is lying.

`--region` crops to the display rectangle of a buffer region (computed in
Emacs via `window-absolute-pixel-position` on both ends) — the cheap way to
screenshot "cell 2's output" without shipping a 1280×800 PNG into agent
context. `--scale` downsamples server-side. Both exist to keep image tokens
down; encourage their use in the agent contract.

`--no-cursor` sets `cursor-type` to nil for the duration. The blinking cursor
is the number-one cause of spurious pixel diffs; `blink-cursor-mode` is off
globally (§7.2), but a solid cursor still lands wherever point is.

#### `eh video start|stop`

`ffmpeg -f x11grab -framerate 10 -video_size <geom> -i :<N> … out.mp4`, plus a
`--gif` variant. Not for assertions — for the failure bundle. A 20-second GIF
of a streaming-output bug is worth a page of prose to a human, and an agent can
attach it to a report.

#### `eh diff-shot NAME`

Compare against `profiles/<p>/baselines/<emacs-version>/<geometry>/<NAME>.png`.

- Compare with ImageMagick `compare -metric AE -fuzz 1%` or a small
  Python/Pillow pixel counter; fail on `changed_pixels / total > tolerance`.
- Support **masks**: rectangles excluded from comparison, declared per baseline
  in a sidecar `NAME.mask.json`. The mode line contains kernel state, execution
  counts and sometimes a clock — mask it, or better, assert on it in tier 1 and
  mask it out of every pixel comparison by default.
- Emit `NAME.actual.png`, `NAME.diff.png` (highlighted) into the run directory
  on failure.
- `eh baseline accept NAME [--all]` updates baselines deliberately. Baselines
  are committed to git; the review of a baseline diff is a human's job.

Use pixel baselines for a small, curated set (§8.3), not everywhere.

### 6.5 Tier 0 — synchronisation, the thing that actually decides whether this works

Every flaky GUI test is a missing wait. jsonyter is asynchronous end to end —
subprocess, websocket, streamed outputs reconciled by count — so the harness
must make waiting the easy path.

#### `eh wait FORM [--timeout N] [--poll MS]`

Polls `FORM` **inside Emacs**, in a loop that lets Emacs actually make
progress:

```elisp
(defun eh-wait (pred &optional timeout poll)
  "Block until PRED returns non-nil.  Signal `eh-timeout' otherwise."
  (let ((deadline (+ (float-time) (or timeout 30)))
        (poll (or poll 0.05)))
    (catch 'done
      (while t
        (when (funcall pred) (throw 'done t))
        (when (> (float-time) deadline)
          (signal 'eh-timeout (list (eh-snapshot-current))))
        (accept-process-output nil poll)
        (sit-for 0)))))
```

`accept-process-output` runs process filters — without it the bridge's output
never arrives. `sit-for 0` runs timers and redisplay. Getting these two right
is most of the battle.

**On timeout, the error payload carries a full snapshot**, so a failure tells
the agent *what the buffer looked like when it gave up* rather than just
"timed out". This one detail will save more agent round-trips than anything
else in the harness.

#### `eh settle`

Spin until quiescent: no pending process output for N ms, no pending timers
that will fire within N ms, and two consecutive `x-export-frames` hashes equal.
Call it before every screenshot. Also expose `--frames-stable 3` for animated
cases (progress bars) where you want a *changing* frame to be the assertion.

#### Named waiters

Profiles register their own, so scenarios read well and the knowledge lives in
one place:

```
eh wait kernel-idle --session s1        # (not (jsonyter-current-kernel-busy-p))
eh wait bridge-ready
eh wait cell-output --cell 2            # cell 2 has non-empty output
eh wait mode-line-matches ':idle'
```

Implement generic ones in the core (`buffer-matches`, `mode-line-matches`,
`window-start-changed`, `frame-stable`) and let profiles add the rest.

#### Hang recovery

If `emacsclient` does not return within the command timeout, Emacs is blocked —
almost always in a minibuffer prompt. `ehd` escalates:

1. `xdotool key --window <win> ctrl+g` (three times, 200 ms apart);
2. `kill -SIGUSR2 <emacs-pid>` — Emacs enters the debugger, which unwinds the
   blocking read and makes the backtrace available;
3. capture a `--display` screenshot and the process tree into the run dir;
4. mark the session dead, exit 5, and *say which prompt was on screen*.

#### The prompt guard

Load into every session's init:

```elisp
(defvar eh-answers nil "Queue of scripted answers for interactive prompts.")
(define-advice y-or-n-p (:around (orig prompt) eh-guard)
  (if eh-answers (eq (pop eh-answers) 'yes)
    (if eh-strict-prompts (error "eh: unexpected prompt: %s" prompt)
      (funcall orig prompt))))
```

…and the same for `yes-or-no-p`, `read-string`, `read-from-minibuffer`,
`completing-read`, and `password-read`. With `eh-strict-prompts` on (the
default in `run` mode), an unexpected prompt is an immediate, legible failure
instead of a 30-second hang. In `server` mode leave it off so a human at the
browser view can answer normally.

---

## 7. Determinism

A pixel baseline is worthless if the same input produces different pixels. This
section is a checklist; treat it as acceptance criteria for phase 0.

### 7.1 Isolation

- Emacs starts `-Q --no-site-file -nsl` and loads exactly one file: the
  profile's generated init.
- **Never inherit the developer's config.** On Emacs 29+ use
  `--init-directory=/run/eh/<s>/emacs.d`. On 27/28 that flag does not exist, so
  set `HOME=/tmp/eh-scratch-<s>` for the process — which is required anyway, so
  that `~/.jupyter`, `~/.ipython`, `~/.local` and jsonyter's own scratch files
  land somewhere disposable. Doing both on all versions keeps the matrix
  uniform.
- No `~/.authinfo`, no GPG agent, no real Jupyter token file. The harness's
  Jupyter token is a fixed constant baked into the image.
- `eh session reset` wipes the scratch HOME. Scenarios get a fresh session by
  default.

### 7.2 Frame, font and rendering

The single largest source of "it looks different on my machine":

```elisp
;; geometry: set in pixels, not characters — character geometry depends on font
(set-frame-size (selected-frame) 1280 800 t)
(set-frame-font "DejaVu Sans Mono-11" t t)     ; font baked into the image
(setq-default line-spacing nil)
(setq face-font-rescale-alist nil)
(setq frame-resize-pixelwise t)
(setq image-scaling-factor 1.0)                ; ← see below
(setq inhibit-startup-screen t
      initial-scratch-message nil
      ring-bell-function #'ignore
      use-dialog-box nil
      use-file-dialog nil
      x-gtk-use-system-tooltips nil)
(blink-cursor-mode -1) (tool-bar-mode -1) (menu-bar-mode -1)
(scroll-bar-mode -1) (horizontal-scroll-bar-mode -1) (tooltip-mode -1)
(setq make-backup-files nil auto-save-default nil create-lockfiles nil)
(setq scroll-conservatively 0 scroll-step 0 scroll-margin 0
      auto-window-vscroll nil)
```

`image-scaling-factor` deserves emphasis: it defaults to `auto`, which scales
images by the frame's font size relative to 11 points. Leave it on `auto` and
the *same plot renders at different pixel sizes* depending on the font that
happened to be found — which silently invalidates every jsonyter image
assertion, including the slice count. Pin it, and pin the font that feeds it.

Bake **exactly one** monospace font into the image (DejaVu Sans Mono is a safe,
ubiquitous choice) and make `fontconfig` deterministic: no user fonts, a fixed
`fonts.conf`, `Xft.dpi: 96` in `~/.Xresources`, and `Xvfb -screen 0
1920x1080x24 -dpi 96`.

Also pin, in the environment: `TZ=UTC`, `LANG=C.UTF-8`, `LC_ALL=C.UTF-8`,
`COLORTERM` unset, `NO_AT_BRIDGE=1` (silences GTK accessibility warnings that
otherwise pollute stderr).

### 7.3 Theme

Pin one theme explicitly (`(load-theme 'modus-operandi t)` or plain default
faces) and make it a profile setting. Two useful extras:

- A `--theme` flag on `eh session new`, so the same scenario can be run under a
  light and a dark theme. Rendering a jsonyter notebook under both is a
  ten-line scenario that catches hardcoded colours across the whole package.
- Baselines are keyed by theme as well as by Emacs version and geometry.

### 7.4 Time, randomness and counters

- `TZ=UTC` and, where a test's output embeds a timestamp, freeze it: advise
  `current-time` / `format-time-string`, or mask the region.
- `(random "emacs-harness")` seeds Emacs's PRNG reproducibly.
- Cell ids in `.ipynb` files are random by spec. jsonyter merges by id on save,
  so scenarios must use **fixtures with fixed ids** (the existing test suite
  already does this — reuse its fixture text verbatim) and, where new cells are
  created, either mask the id or stub the id generator.
- Execution counts (`In[3]`) depend on kernel history. Always start from a
  fresh kernel in scenarios that assert on them.

### 7.5 Concurrency

Sessions must not share an X display, a scratch HOME, a Jupyter kernel, or a
run directory. Give each a display number derived from its index, and have
`ehd` allocate them from a pool with a lock — `Xvfb` failing to start because
`:99` is taken produces a confusing downstream failure.

---

## 8. Scenarios and profiles

### 8.1 Scenarios are Emacs Lisp, and run inside the instance under test

Not shell scripts full of `eh` calls. Reasons:

- Everything in tiers 0–2a is Lisp anyway; going out to a shell and back for
  each step multiplies latency by three orders of magnitude and makes waits
  racy.
- Assertions want Lisp values, not JSON round-trips.
- The same file can run under plain `ert-run-tests-batch-and-exit` in CI.
- The existing 49-test suite can be lifted into a profile with no rewriting.

`eh run` therefore means: start a session, load the profile init, load
`eh-scenario.el` and the scenario files, run the selected ERT tests, collect
artifacts, report. The `eh` CLI's per-step commands (§6) exist for the *other*
mode — an agent poking at a live instance by hand.

**The intended workflow, and the reason the harness pays for itself:**

> The agent explores a bug interactively against a live session (`eh eval`,
> `eh keys`, `eh shot`), works out what is actually wrong, fixes it, then
> **freezes what it learned into a scenario file** so the bug can never come
> back silently. Exploration is disposable; scenarios accumulate.

### 8.2 Scenario DSL

Thin macros over ERT — never a parallel test framework:

```elisp
;;; profiles/jsonyter/scenarios/notebook-output.el -*- lexical-binding: t; -*-

(eh-scenario jsonyter/notebook-output-is-framed-and-read-only
  :doc     "A run cell's output is framed, read-only, and not undoable."
  :needs   (:kernel "python3" :emacs ">= 27.1")
  :fixture "three-cells.ipynb"
  :geometry (1280 . 800)
  :tags    (notebook output)

  (eh-open-fixture "three-cells.ipynb")          ; copies to scratch, opens it
  (eh-keys "C-c C-k")                            ; start the kernel explicitly
  (eh-wait-for 'jsonyter-kernel-live :timeout 90)

  (eh-goto-cell 0)
  (eh-keys "<C-return>")
  (eh-wait-for 'jsonyter-kernel-idle)
  (eh-wait-for (lambda () (eh-cell-has-output-p 0)))

  (eh-expect-face (eh-cell-output-border-start 0) 'jsonyter-output-border-face)
  (eh-expect-read-only (eh-cell-output-region 0))
  (eh-expect-editable  (eh-cell-source-region 0))
  (eh-expect-equal (eh-buffer-modified-p) nil
                   "running a cell must not mark the buffer modified")

  (eh-shot "notebook-cell0-output")              ; baseline compare
  (eh-expect-no-visual-drift "notebook-cell0-output" :tolerance 0.002))
```

`eh-scenario` expands to an `ert-deftest` plus:

- **skip logic** from `:needs` — missing kernel, wrong Emacs version, no cairo,
  no SVG support → `ert-skip` with a legible reason, never a failure;
- **setup/teardown** — fresh scratch dir, fixture copy, buffer cleanup, kernel
  shutdown, `eh-answers` reset;
- **artifact capture on failure** — screenshot (frame *and* display), full
  snapshot of every jsonyter buffer, `*Messages*`, the bridge's
  ` *jsonyter stderr*` buffer, the Jupyter log tail, and the ERT backtrace, all
  into `runs/<id>/<scenario>/`;
- **timing** into the report.

Core assertion vocabulary (profile-independent):

```
eh-expect-equal / eh-expect / eh-expect-match
eh-expect-face POS FACE            ; resolved face, overlay priority respected
eh-expect-read-only REGION
eh-expect-editable REGION          ; actually tries an insert via the command loop
eh-expect-overlay REGION PROP VAL
eh-expect-display-image POS &key type slices min-width
eh-expect-visible POS / eh-expect-not-visible POS
eh-expect-window-start-unchanged BODY…
eh-expect-mode-line-matches REGEXP
eh-expect-no-visual-drift NAME &key tolerance mask
eh-expect-messages-match REGEXP
eh-expect-no-error BODY…
```

Note `eh-expect-editable` *tries the edit* rather than reading the `read-only`
property — the property is the mechanism, the ability to type is the behaviour.

### 8.3 Which assertions get pixel baselines

Pixel baselines are expensive to review and easy to make flaky. Use them only
where redisplay is the thing under test:

**Yes:** a rasterised plot in a notebook (proves the PNG decoded and is not a
placeholder); a tall sliced image (proves N drawable rows, not one blob); the
output frame rules; a rendered `text/html` block through `shr`; the same
buffer under light and dark themes; a full-frame "here is what a notebook looks
like" reference shot per Emacs version.

**No:** anything about text content, faces, properties, overlays, mode-line
text, point, scroll position, read-only-ness, saved file bytes. All of that is
tier 1, where the assertion is exact and the failure message is legible.

Budget: **on the order of 10–15 baselines for the whole jsonyter profile.**
If it grows past that, something that should have been a tier-1 assertion is
being done with pixels.

### 8.4 The profile model

A profile is a directory. The core knows nothing about the package.

```
profiles/jsonyter/
├── profile.el          declarative manifest, evaluated by the harness
├── init.el             the sandboxed Emacs config for the SUT
├── deps.lock           pinned dependency revisions
├── fixtures/           .ipynb, .py, .org, .R files copied per scenario
├── bridge-scripts/     fake-bridge fixtures (§9)
├── scenarios/*.el
├── baselines/<emacs>/<geometry>/<theme>/*.png (+ .mask.json)
└── services.yaml       which side services this profile needs
```

`profile.el` sketch:

```elisp
(eh-defprofile jsonyter
  :package-path  "/srv/package"                 ; bind-mounted repo
  :load-path     ("/srv/package")
  :requires      (jsonyter)
  :emacs-versions ("27.2" "28.2" "29.4" "30.2" "31.1")
  :system-packages ()                           ; extra apt packages
  :python-packages ("jsonyter>=1.0.0" "jupyter-server" "ipykernel"
                    "matplotlib" "numpy")
  :elisp-deps    ((ess . "24.01.0"))            ; for ess-r-mode notebooks
  :services      (jupyter)
  :theme         modus-operandi
  :geometry      (1280 . 800)

  ;; properties eh-snapshot reports by default for this package
  :snapshot-props (jsonyter-cell jsonyter-cell-id jsonyter-cell-type
                   jsonyter-source-end jsonyter-source-hash
                   jsonyter-output-stale jsonyter-exec-count
                   jsonyter-output-string jsonyter-raw-outputs
                   jsonyter-script-cell jsonyter-org-cell
                   jsonyter-org-committed jsonyter-running)

  ;; named waiters usable as `eh wait <name>`
  :waiters ((jsonyter-kernel-live . (lambda () (jsonyter-current-kernel-id)))
            (jsonyter-kernel-idle . (lambda () (not (jsonyter-current-kernel-busy-p))))
            (jsonyter-bridge-ready . (lambda () (get-buffer " *jsonyter stderr*"))))

  ;; extra logs to sweep into the failure bundle
  :log-buffers (" *jsonyter stderr*" "*Messages*")
  :log-files   ("/var/log/eh/jupyter.log"))
```

`init.el` is the *only* configuration the SUT sees, and should be the minimum
the README tells a user to write plus the harness's determinism block:

```elisp
(add-to-list 'load-path "/srv/package")
(require 'jsonyter)
(add-to-list 'auto-mode-alist '("\\.ipynb\\'" . jsonyter-notebook-open))
(add-hook 'python-mode-hook #'jsonyter-script-mode-maybe)
(add-hook 'org-mode-hook    #'jsonyter-org-mode-maybe)
(setq jsonyter-server-url  "http://127.0.0.1:8888"
      jsonyter-server-token "eh-harness-fixed-token"
      jsonyter-token-transport 'env
      jsonyter-startup-timeout 120)
```

### 8.5 Proving the core is generic

Ship a second, trivial profile — `profiles/smoke/` — with no external services
and three scenarios: open a file, press a key, take a screenshot; assert a
face; assert an image renders. Its purpose is a build-time guarantee that
nothing jsonyter-specific has leaked into the core. If `eh run smoke` needs a
Jupyter server, the abstraction has broken.

The third profile to add, when the harness is proven, is the one that will find
real bugs in *someone else's* code: a small profile for a package Ethan
actually uses, to sanity-check that the harness is usable by a stranger.

---

## 9. Kernels: real Jupyter plus a scriptable fake bridge

Both, because they answer different questions.

### 9.1 Real Jupyter

Baked into the image: `jupyter-server`, `ipykernel`, `matplotlib`, `numpy`, and
`IRkernel` for R (worth the build cost — jsonyter's multi-session Org support
is only meaningfully exercised with two languages live at once). IJulia is
optional and slow to build; make it a build arg, default off. **SAS is not
available** — every SAS scenario runs against the fake bridge, which is fine,
because what the SAS scenarios test is jsonyter's handling of SAS's protocol
misbehaviour, not SAS itself.

The server starts on `127.0.0.1:8888` with a fixed token, and is reachable only
from inside the container.

Real-kernel scenarios are the end-to-end proof: the bridge subprocess starts,
the websocket connects, a real `matplotlib` figure arrives as base64 PNG over
the wire and rasterises in a frame. Keep a handful of these and accept that
they are slower.

### 9.2 The fake bridge

`eh-fake-bridge` is a Python script speaking the same line-oriented JSON
protocol over stdin/stdout that the `jsonyter` package speaks. A profile points
`jsonyter-command` at it:

```elisp
(setq jsonyter-command (list "/opt/eh/bin/eh-fake-bridge"
                             "--script" "/srv/profiles/jsonyter/bridge-scripts/streaming.jsonl"))
```

It exists because a large class of jsonyter behaviour is **impossible or
miserable to trigger against a real kernel**:

| Behaviour to test | Why a real kernel can't do it on demand |
| --- | --- |
| `:offline` mode line — half-open websocket | Requires actually breaking the network mid-request |
| `:dead` — kernel killed from another client | Racy, and destroys the session you were testing |
| `:run[ext]` — busy on behalf of another client | Needs a second client attached at the right moment |
| SAS's `is_complete` "incomplete for anything without a newline" | No SAS kernel |
| SAS never answering `history`; answering `inspect` with `aborted` | Same |
| `jsonyter-request-timeout` bounding a wedged request | Needs a kernel that hangs deliberately |
| Streaming reconciliation ("the bridge repeats every streamed output in the final `outputs` list") | Needs byte-level control of the reply |
| Exact ANSI tracebacks, exact mimebundle shapes | Kernel-version dependent |
| A 200 MB image, a malformed mimebundle, invalid UTF-8 | Hostile inputs a kernel won't produce |

Script format — one JSON object per line, matched in order against incoming
requests, with timed event emission:

```jsonl
{"on":{"method":"start_kernel"},"reply":{"kernel_id":"k1"},"delay_ms":50}
{"on":{"method":"execute","code":"~^for i in~"},
 "emit":[{"after_ms":0,   "event":"status","state":"busy"},
         {"after_ms":100, "event":"stream","name":"stdout","text":"step 1\n"},
         {"after_ms":200, "event":"stream","name":"stdout","text":"step 2\n"},
         {"after_ms":300, "event":"clear_output","wait":true},
         {"after_ms":310, "event":"display_data","file":"fixtures/plot.png"},
         {"after_ms":400, "event":"status","state":"idle"}],
 "reply":{"outputs":["<repeat-all-emitted>"],"execution_count":1}}
{"on":{"method":"history"},"never_reply":true}          // SAS emulation
{"on":{"method":"is_complete"},"script":"sas"}          // named behaviour bundle
{"at":"t+2000","inject":{"event":"status","state":"dead","kernel_id":"k1"}}
```

Two features that make this genuinely useful rather than a toy:

1. **Record mode.** `eh-fake-bridge --record out.jsonl -- <real bridge command>`
   proxies stdin/stdout to the real bridge and writes a replayable script,
   with image payloads spilled to files. Every fixture then starts as *real
   traffic from a real kernel*, hand-edited afterwards. Building fixtures by
   hand from the protocol spec is how fixtures end up subtly wrong and tests
   end up passing against a fiction.
2. **A `--fault` flag** for the hostile cases: `--fault truncate-json`,
   `--fault stderr-noise` (verifies the claim that "the bridge's stderr goes to
   a hidden buffer so Python warnings cannot corrupt the JSON protocol on
   stdout"), `--fault slow-drip`, `--fault die-mid-reply`.

The fake bridge must be kept honest: one scenario runs the *same* script
against both bridges where the real kernel can produce the same traffic, and
compares the resulting snapshots. If they diverge, the fake has drifted.

---

## 10. The browser view

Purpose: a human watching the agent work; an agent (via Claude-in-Chrome)
clicking through a UI it cannot reason about from a snapshot; and a shareable
"here is the bug happening" link.

### 10.1 Stack

**Default: `Xvfb` + `x11vnc` + `websockify`/`noVNC`.** Three processes, all
permissively licensed, in every distro, and the most documented path in
existence. `x11vnc -display :99 -forever -shared -nopw -localhost` behind
`websockify --web /usr/share/novnc 6080 localhost:5900`.

**Worth switching to if the trio annoys you: KasmVNC.** It replaces *both*
Xvfb and x11vnc and has a built-in browser client, so three processes and the
websockify hop collapse into one, with better compression. Evaluate it in
phase 2; do not start there, because the frame-export screenshot path (§6.4)
must be proven against a plain X server first.

Two endpoints, two passwords:

- `:6080/view` — `x11vnc -viewonly` password. Safe to leave open on the LAN,
  safe to hand to a watcher.
- `:6080/control` — full control. This is what a human or Claude-in-Chrome uses
  to click.

A minimal window manager (`openbox`) runs on the display so frames size
correctly and menus/tooltips behave. Configure it with **no keybindings at
all** — a WM that grabs `C-c` or `M-x` will eat exactly the keystrokes under
test — and no decorations.

### 10.2 Reaching it from outside

Through the existing Cloudflare Tunnel, on its own hostname, e.g.
`emacs-harness.guthrieec.dev` → `http://localhost:6080`.

Two specific warnings, both learned the hard way in this homelab:

1. **noVNC is WebSocket-only.** Cloudflare supports WebSockets, but a proxy
   misconfiguration shows up as a page that loads and then does nothing — the
   same shape as the unRAID webGUI buttons that work on the LAN and not through
   the tunnel. If the canvas stays grey, check the WS upgrade before checking
   anything else. `cloudflared` ingress needs no special flag for WS, but
   `noTLSVerify: true` is required if the origin is HTTPS with a self-signed
   cert; here the origin is plain HTTP on localhost, so keep it HTTP.
2. **Access service tokens do not work for a browser.** A browser cannot send
   `CF-Access-Client-Id` / `CF-Access-Client-Secret` headers. Protect the *web
   view* with an Access application whose policy allows your identity (email
   login), and reserve service tokens for the *machine* path — the SSH
   transport and, later, the HTTP API. Putting a service-token-only policy in
   front of noVNC produces a 403 that looks like a VNC failure.

The low-friction alternative, and the right default while developing: don't
expose it at all. `ssh -L 6080:localhost:6080 unraid` and open
`http://localhost:6080`. Zero configuration, zero exposure.

### 10.3 Agent use of the browser view

Claude-in-Chrome can drive the noVNC canvas: `navigate` to the control URL,
`computer` screenshots, clicks and key events. It works, and it is the *wrong
default* — a click on a canvas is a click at a pixel the agent guessed, and a
screenshot of a browser showing a VNC canvas showing an Emacs frame is three
layers of lossy indirection.

Use it when: the human asks for a demo; a GTK menu or a native dialog is
involved (nothing else can reach those); or the agent is genuinely stuck and
wants to look at the whole screen.

Otherwise `eh click --at '(…)'` — which computes the pixel from a buffer
position — is both more precise and cheaper.

---

## 11. The agent contract

Ship this as `AGENTS.md` (and symlink `CLAUDE.md`) in the harness repo, and
have `eh --help` print an abridged form. The whole design assumes an agent is
the primary operator, so the operating discipline is part of the deliverable.

```markdown
## Driving the harness

1. `eh describe` first, whenever you are not sure what state a session is in.
2. **Assert on snapshots, not screenshots.** `eh snapshot --buffer X` answers
   almost every question about text, faces, overlays, properties, geometry and
   the mode line — exactly, cheaply, and in a form you can diff. Take a
   screenshot only to answer "did this actually rasterise / lay out", or to
   show a human.
3. **Never assert without waiting.** Every action that touches a kernel is
   asynchronous. `eh wait <predicate>` or a named waiter, always. A test that
   passes because a `sleep 2` happened to be long enough is a test that will
   fail in CI.
4. **Crop and scale screenshots.** `eh shot --region '(eh-cell-output-region 2)'
   --scale 0.5` instead of a full 1280×800 frame.
5. **Drive with keys, not function calls.** `eh keys "C-c C-e"` exercises the
   keymap, the command loop, and `last-command`; `eh eval '(jsonyter-notebook-run-cell)'`
   exercises none of them and will pass while the binding is broken.
6. **On failure, read the run directory.** Every failure writes
   `runs/<id>/<scenario>/` with screenshots, snapshots, `*Messages*`, the
   bridge stderr, and a backtrace. Quote the path in your report.
7. **Freeze what you learn.** If you investigated a bug interactively, add a
   scenario before you close it out. Exploration is disposable; scenarios
   accumulate.
8. **Do not edit `/srv/package`.** It is the user's working tree, mounted
   read-only on purpose. Fix code on the host, then `eh session reset`.
```

---

## 12. `eh doctor` — the environment self-check

The first thing to implement after the container boots, and the first thing to
run after every image build. It prints a table and exits non-zero on any red.
Several of the assumptions this document makes are load-bearing and must be
*verified on the actual image* rather than trusted:

| Check | How | Why it matters |
| --- | --- | --- |
| X display alive | `xdpyinfo -display :99` | everything |
| Emacs is a GUI build | `(display-graphic-p)` | batch Emacs silently passes half the tests and fails the rest confusingly |
| **cairo present** | `(memq 'cairo (split-string system-configuration-features))` and `(fboundp 'x-export-frames)` | the default screenshot path (§6.4) needs it |
| `x-export-frames` really returns PNG bytes | export, check the 8-byte PNG magic, check size > 1 KB | a cairo build can still be built without the export |
| pgtk or X11 | `(featurep 'pgtk)` | decides whether `xdotool` works (§13.1) |
| `window-absolute-pixel-position` | call it on `(point-min)` in a visible window; assert a `(X . Y)` cons | the click path depends on its exact return shape; **verify per Emacs version**, 27.2 included |
| image types | `(image-type-available-p 'png)`, `'svg`, `'jpeg` | jsonyter renders all three |
| image scaling pinned | `image-scaling-factor` is `1.0`, not `auto` | §7.2 |
| font resolved | `(font-get (face-attribute 'default :font) :name)` matches the pinned font | pixel baselines are meaningless otherwise |
| frame geometry exact | `(frame-pixel-width)` / `(frame-pixel-height)` equal the requested values | WM interference |
| xdotool reaches the frame | send `C-g`, confirm `(this-command-keys)` or a `keyboard-quit` in `*Messages*` | the `--x` input path |
| Jupyter reachable | `GET /api/kernelspecs` with the token | real-kernel scenarios |
| kernels present | list of kernelspecs; report which of python3/ir/julia/sas exist | drives `:needs` skipping |
| `jsonyter` python package | `python3 -m jsonyter --version` | the real bridge |
| fake bridge | round-trip one request | the fake bridge |
| ImageMagick / ffmpeg | `convert -version`, `ffmpeg -version` | tier 3 |
| writable run dir | touch a file in `/var/lib/eh/runs` | artifacts, and unRAID permission mapping |
| clock is UTC | `date +%Z` | determinism |

Output as both a human table and `--json`, so a scenario's `:needs` clause and
CI can read the same data.

---

## 13. Risks, gotchas, and open questions

### 13.1 pgtk vs X11 — the one to think about now

Arch's official Emacs package is a **pgtk** (pure-GTK, Wayland-native) build.
The container should deliberately use an **X11 + cairo GTK** build (Debian's
`emacs-gtk`, or a pinned source build), because:

- `xdotool` speaks X11. On a pgtk Emacs running under XWayland it mostly works;
  on a pgtk Emacs on a real Wayland compositor it does not work at all.
- The X11 path is the well-trodden one for headless CI.

But note the good news, and design for it: **`x-export-frames` is
backend-independent** (it is cairo, not X). So the primary screenshot path
survives a move to Wayland unchanged, and so does all of tier 1 and the
`execute-kbd-macro` half of tier 2. Only `--x` input and `--display` capture
are X-specific.

If Ethan later wants to test *his actual* pgtk build — and he should, since
that is what he runs — add a session backend: `cage` (a kiosk Wayland
compositor) or headless `sway`, `wayvnc` for the browser view, and
`ydotool`/`wtype` in place of `xdotool`. Structure `ehd`'s session manager with
this in mind from day one: a `backend` field on the session, `x11` first,
`wayland` later. Do not hardcode `DISPLAY` throughout.

Concretely: verify at build time that the container's Emacs reports
`(featurep 'pgtk)` → nil, and make `doctor` fail loudly if a future base-image
bump silently switches it.

### 13.2 Other risks

| Risk | Mitigation |
| --- | --- |
| A scenario hangs Emacs in a minibuffer prompt | Prompt guard + SIGUSR2 escalation (§6.5). Non-negotiable; build it in phase 1. |
| Pixel baselines drift on every base-image rebuild (font/freetype/cairo version bumps) | Pin the base image by digest. Keep baselines few (§8.3). Treat a mass baseline diff after a rebuild as expected, and review it once. |
| `overlays-in` returns overlays in unspecified order | Sort deterministically in `eh-snapshot` (§6.2). This *will* cause phantom diffs if skipped. |
| Kernel startup is slow and variable; SAS is ~17 s to first output by design | Generous `:needs`-aware timeouts; never a fixed sleep; keep real-kernel scenarios few. |
| unRAID file ownership on the bind-mounted repo and run dir | Run the container with `--user $(id -u):$(id -g)` matching the host user, or set `PUID`/`PGID` the unRAID way. Getting this wrong leaves root-owned files in `~/git`. |
| Container has network access to the internet | It does not need it at runtime. Build-time only; run with a restricted network, and never mount the real `~/.authinfo.d` or GPG keys. |
| The RockPro64 (arm64, Alpine) as a host | Don't. IRkernel and Julia on arm64/musl are a build project of their own, and 4 GB of RAM will not host an Emacs matrix. Use unRAID; leave the RockPro64 for Bitwarden. |
| Emacs 27.2 lacks `--init-directory` | Set `HOME` instead, on all versions (§7.1). |
| jsonyter mounts and the notebook `.ipynb` fixtures share cell ids across scenarios | Fresh scratch dir per scenario (§8.2 teardown). |
| Frame export includes the cursor | `--no-cursor` (§6.4). |

### 13.3 Open questions for the implementer

1. **How many Emacs versions in the default matrix?** The package claims 27.1+.
   Suggest running 29.4 (or whatever Debian stable ships) on every scenario,
   and the full matrix `{27.2, 28.2, 29.4, 30.2, 31.1}` nightly or on tags.
   Building five Emacsen from source makes a slow image; using distro packages
   across several base images makes five images. Recommend the latter:
   `emacs-harness:29.4` etc., sharing everything above the Emacs layer.
2. **Does `eh run` need its own session or can scenarios share one?** Default to
   fresh-per-scenario; measure, and add `--reuse-session` only if setup
   dominates runtime.
3. **Should the snapshot format be stabilised as v1 immediately?** Yes — put
   `:version 1` in it from the first commit and treat it as an interface.
   Scenario files, baselines and agent habits all depend on it.
4. **Where do baselines live?** In the harness repo under `profiles/jsonyter/`,
   or in the jsonyter repo? Recommend the harness repo while the harness is
   young (one place to review), with a documented move if the profile is later
   vendored into jsonyter itself.

---

## 14. Milestones

Each phase has an acceptance test that is a single command producing a single
verifiable artifact. Do not start a phase before its predecessor's acceptance
test passes.

### Phase 0 — a frame on a screen (½ day)

Container with Xvfb + openbox + a cairo GUI Emacs + `eh doctor`.

**Done when:** `eh doctor` is all green on the built image, and
`eh shot --out /tmp/hello.png` produces a PNG of an Emacs frame showing
`*scratch*` at exactly 1280×800.

### Phase 1 — the control surface (2–3 days)

`ehd` with sessions; `eh eval`, `snapshot`, `describe`, `keys` (command-loop
path), `wait`, `settle`, `shot`; the prompt guard and hang recovery; the run
directory and failure bundle; `eh run` executing ERT.

**Done when:** `eh run jsonyter --scenario notebook-output-is-framed-and-read-only`
passes against a real Python kernel, and deliberately breaking
`jsonyter-output-border-face` produces a failure whose run directory contains a
screenshot, a snapshot, and a backtrace that names the face.

Also in this phase: `eh run jsonyter --batch` runs the existing
`test/jsonyter-tests.el` unchanged, so one command covers everything.

### Phase 2 — input and pixels (2 days)

`eh keys --x`, `eh click`, `eh drag`, `eh scroll`, `eh type`; `eh video`;
`eh diff-shot` with baselines and masks; the noVNC view.

**Done when:** a scenario clicks on the third slice of a tall inline image by
buffer position and asserts point landed inside the output region; and
`eh diff-shot` fails on a one-pixel change and passes on a rerun.

### Phase 3 — generality and the matrix (2 days)

The profile abstraction extracted and proven; `profiles/smoke/`; the Emacs
version matrix; `compose.yaml` and a GitHub Actions workflow running the same
image headlessly.

**Done when:** `eh run smoke` passes in an image built with **no** Python,
Jupyter or jsonyter installed; and `eh run jsonyter --emacs 27.2,29.4` runs the
same scenarios on both and reports per-version results.

### Phase 4 — the MCP server (1–2 days)

An MCP server exposing `emacs_eval`, `emacs_snapshot`, `emacs_keys`,
`emacs_click`, `emacs_screenshot`, `emacs_wait`, `emacs_run_scenario`,
`emacs_session`. A thin shim over the same `ehd` dispatcher, reached over the
HTTP transport with a Cloudflare Access service token.

**Done when:** Claude Code with the MCP server configured can, in one session
and with no Bash calls, open a fixture notebook, run a cell, wait for idle, and
report the resolved face of the output border.

Existing prior art to look at rather than reinvent: several `emacs-mcp` servers
exist and all share the `emacs_eval` + `emacs_get_context` shape; none of them
handle headless sessions, waiting, or screenshots, which is precisely the value
this adds.

---

## 15. `eh` command reference (target surface)

```
eh doctor [--json]
eh session new|list|reset|rm|logs [--emacs V] [--profile P] [--geometry WxH]
                                  [--theme T] [--backend x11|wayland] [--name N]

eh eval FORM [--out FILE]
eh snapshot [--buffer B] [--window] [--region BEG END] [--props P,…]
            [--visible-only] [--no-text] [--format sexp|json]
eh describe

eh keys KEYS… [--x]
eh type TEXT
eh click [--at-point|--at FORM|--at-text STR|--xy X,Y] [--button N] [--double]
eh drag --from FORM --to FORM
eh scroll [--lines N|--pixels N]
eh answer yes|no|TEXT               # push onto the scripted-answer queue

eh wait FORM|NAME [--timeout S] [--poll MS]
eh settle [--frames-stable N]

eh shot [--out PATH] [--frame|--display] [--region FORM] [--crop …]
        [--scale F] [--no-cursor] [--label NAME]
eh video start|stop [--gif]
eh diff-shot NAME [--tolerance F]
eh baseline accept NAME|--all

eh run PROFILE [--scenario NAME…] [--tag TAG] [--emacs V,…] [--batch]
               [--reuse-session] [--junit PATH] [--json]
eh logs [--service jupyter|bridge|emacs|x] [--tail N]
eh artifacts [--run ID] [--open]
```

---

## 16. Reporting and artifacts

Every `eh run` creates `runs/<utc-timestamp>-<profile>-<shortid>/`:

```
report.json          machine-readable: per scenario status, duration, skip reason
junit.xml            for CI
index.html           a static page: every scenario, its screenshots side by
                     side with baselines, expandable snapshots and logs
summary.txt          one line per scenario; the last line is the overall verdict
<scenario>/
    before.png after.png diff.png
    frame.svg                       (text-searchable render, see §6.4)
    snapshot-<buffer>.el
    messages.log
    jsonyter-stderr.log
    jupyter.log.tail
    backtrace.txt
    video.mp4                       (if enabled)
    steps.jsonl                     every eh action with a timestamp
```

`index.html` costs an afternoon and pays for itself the first time a pixel
diff needs reviewing. `steps.jsonl` is what lets an agent reconstruct what it
did after a long exploration.

The final line printed to stdout is always the run directory path, so an agent
can quote it without parsing anything.

---

## 17. References

- GNU Emacs Lisp Reference — *Coordinates and Windows*
  (`window-absolute-pixel-position`, `pos-visible-in-window-p`), *Frame Layout*,
  *Frame Position*: <https://www.gnu.org/software/emacs/manual/html_node/elisp/Coordinates-and-Windows.html>
- `x-export-frames` and the cairo requirement — emacs-devel, "x-export-frames
  for non-Cairo builds": <https://lists.gnu.org/archive/html/emacs-devel/2018-01/msg00749.html>
- Automating Emacs screenshots, including the Xvfb + cairo + `x-export-frames`
  recipe: <https://emacsredux.com/blog/2026/07/03/automating-emacs-screenshots/>
- Emacs Docker images, version matrix: <https://github.com/Silex/docker-emacs>
  (CI-oriented) and <https://github.com/JAremko/docker-emacs> (GUI-oriented)
- KasmVNC, browser-native VNC with no separate noVNC/websockify:
  <https://kasm.com/kasmvnc>
- Prior art for the MCP shape: <https://github.com/keegancsmith/emacs-mcp-server>,
  <https://github.com/dangerzig/emacs-mcp>
- The package under test: <https://github.com/EGuthrieWasTaken/jsonyter.el>
