# emacs-harness

A GUI Emacs test harness that an AI coding agent can drive: a real, graphical
Emacs running on a headless X display inside a container, with a command-line
control surface for evaluating Lisp, sending real keystrokes and mouse clicks,
taking screenshots, and asserting on what Emacs actually drew — plus a browser
view of the same live instance for point-and-click work and human eyeballs.

Built for *any* Emacs package whose interesting behaviour is invisible to
`emacs --batch` — sliced inline images, output overlays, read-only regions,
streaming redraws, mode-line state pushed from a subprocess, scroll and
point discipline, and anything else that only exists once there is real
redisplay. Nothing in the core knows about any specific package: a package
under test is described by a **profile** (a directory — see DESIGN.md §8.4),
and the core is deliberately generic — proven by the fact that
`profiles/smoke/` needs none of it (§8.5).

## Status

**Phases 0-3 implemented, and phases 2-3's own DESIGN §14 acceptance tests
now formally proven end-to-end** against a live `emacs-gtk` + `Xvfb` +
`openbox` (not just wired up and assumed correct — see below). Phase 0-1:
the container image, the `ehd` dispatcher, the `eh` client, the Elisp driver
(`eh-driver.el`), the scenario DSL (`eh-scenario.el`), and the `smoke`
profile that proves the core is package-agnostic. Phase 2: `eh
click`/`eh drag`/`eh scroll`/`eh keys --x`, `eh video` (including `--gif`),
and pixel baselines via `eh diff-shot`/`eh baseline accept` with
`.mask.json` sidecar support, all wired end-to-end including the
scenario-level `eh-expect-no-visual-drift`. **Phase 2's own acceptance
test** — "a scenario clicks on the third slice of a tall inline image by
buffer position... and `eh diff-shot` fails on a one-pixel change and
passes on a rerun" — is now proven directly, not just plumbed: see
`smoke/image-slices-are-addressable` and
`smoke/diff-shot-detects-pixel-change` under "What's been validated" below.
Phase 3: the `--emacs V,...` matrix flag on `eh run` and a GitHub Actions
workflow (`.github/workflows/ci.yml`) that builds the image and runs `eh
doctor` + `eh run smoke` headlessly. **Phase 3's matrix mechanism** is now
verified against the real dispatcher (previously only exercised with a
mocked `SessionManager` — see below for a real bug that mock missed). Not
yet built: any profile beyond `smoke` itself (so the matrix flag's second
acceptance test, "`eh run <profile> --emacs 27.2,29.4` for a real profile",
can't be run end-to-end until one exists), pinned multi-version Emacs
*images* (the matrix flag's own control flow is now proven against two
distinctly-named binaries, but this environment — like every environment
this harness has been driven in so far — has exactly one real Emacs release
installed, so *different Emacs versions actually disagreeing on something*
remains unexercised; see DESIGN §13.3 open question 1), and the MCP server
(Phase 4).

Diff-shot's pixel comparison (ImageMagick `compare`/`identify`, plus mask
rectangles applied via `convert -draw`) is implemented once, in Elisp
(`eh-diff-shot` in `eh-driver.el`), and called both by the CLI (`eh
diff-shot`/`eh baseline accept`, via a thin `emacs_eval` wrapper in
`ehd.py`) and by scenarios (`eh-expect-no-visual-drift`) — not
reimplemented per caller, since a scenario running inside Emacs has no
channel back out to `ehd` mid-test (see DESIGN §8.1).

The container image itself (`container/Dockerfile`, i.e. the `docker build`)
has **not** been built in this environment: this sandbox's egress policy
blocks Docker Hub's CDN (`production.cloudfront.docker.com`) with a policy
403, so `docker build` fails on the base `FROM debian:bookworm-slim` layer
before reaching any of this repo's own steps — a genuine egress restriction,
not something fixable from inside the build. The GitHub Actions workflow
above will be the first place the image itself actually builds.

**The runtime it builds has, however, now been validated directly**: this
sandbox does allow installing `emacs-gtk`, `Xvfb`, `openbox`, ImageMagick
and `xdotool` via `apt` outside Docker, which is enough to run `ehd.py` and
`bin/eh` exactly as the container would — a real cairo-enabled GTK Emacs on
a real (virtual) X display, driven by the real dispatcher, with no mocks.
Doing this for the first time surfaced several real, previously-latent bugs
that no amount of batch-mode or unit-level testing could have caught (see
below); all are now fixed and reverified. `eh doctor` reports fully green
and `eh run smoke` passes all 3 scenarios end-to-end, repeatedly, from a
cold start — DESIGN's own Phase 0 acceptance test (`eh shot` producing an
exact 1280×800 PNG) and Phase 1 acceptance test (a real scenario passing
against a real graphical frame) both hold. Build and run `eh doctor` (§12)
as the first acceptance check in any environment with normal Docker Hub
access — it should already be all green.

### What's been validated

- All Python (`bin/eh`, `ehd/ehd.py`, `ehd/ehd_cli.py`) compiles cleanly and
  passes `pyflakes` (one pre-existing unused import, `socket` in `ehd.py`,
  predates this pass and is unrelated to it).
- All Elisp (`elisp/*.el`) byte-compiles cleanly (only benign warnings for
  GUI-only primitives and variables defined via `require` at runtime).
- **`eh doctor` and `eh run smoke` now both pass end-to-end against a real
  `emacs-gtk` + `Xvfb` + `openbox`**, run directly via `ehd.py`/`bin/eh`
  outside Docker (see above) — repeatedly, from a fully cold process state,
  not once by chance. Getting there found and fixed real bugs, all in code
  that had never actually been run against a live display before this pass:
  - **Session directories were created world-readable (mode 755).** Emacs's
    own `server-ensure-safe-dir` refuses to bind the Unix-domain server
    socket in a directory that isn't 0700, so `eh-driver-start-server`
    silently failed on every single session — the socket never appeared,
    every `eh` command timed out with "emacs server socket never appeared",
    and nothing in the harness had ever run far enough to notice. Fixed by
    `chmod`ing the run directory to 0700 right after creation (`ehd.py`).
  - **The openbox config force-maximized every window** (`<maximized>yes</maximized>`
    alongside `<decor>no</decor>`), fighting Emacs's own pixel-exact
    `set-frame-size` call — exactly the WM interference DESIGN §7.2 exists
    to prevent. Removed.
  - **`eh-apply-determinism-settings` resized the frame *before* disabling
    the tool bar/menu bar/scroll bars**, so removing that chrome afterward
    perturbed the geometry the resize had just set. Reordered: strip chrome
    first, resize last.
  - **The GTK toolkit reserves `scroll-bar-width` pixels of gutter even
    with scroll bars hidden**, and neither `set-frame-parameter` nor
    setting `scroll-bar-width` to 0 in a *fresh* frame's own creation alist
    can get it below that floor (both tried and measured) — so a requested
    width of 1280 reliably came out as 1296. Fixed by querying the
    toolkit's actual (non-zero) floor and undersizing the request by
    exactly that amount, so the final reported width lands on the target.
  - **`set-frame-size` only *requests* a resize** — on X11/GTK the frame's
    reported pixel dimensions don't update until Emacs processes the
    window manager's confirmation, which needs the event loop pumped.
    `eh doctor`'s very first check ran before anything else had incidentally
    pumped it, so it sometimes saw a stale pre-resize size (`eh run`'s
    scenario bodies masked this, since fixture-opening/keyboard-macro
    execution pump events as a side effect). Fixed with a short bounded
    settle loop after the resize.
  - **`eh--scenario-teardown` silently swallowed a real failure.** Killing
    a *modified* scratch buffer normally asks "kill anyway?", which the
    prompt guard turns into a signalled error under `eh-strict-prompts` —
    and the old code wrapped that kill in `ignore-errors`, discarding the
    error and leaving the buffer alive and modified. The *next* scenario
    reusing the same fixture filename then hit
    `ask-user-about-supersession-threat` on an externally-touched file with
    unsaved edits, this time uncaught, aborting the whole run. Fixed by
    clearing the modified flag before every teardown kill, since a fixture
    buffer is disposable scratch state by design — there is nothing to ask
    about.
  - **`eh--capture-scenario-artifacts` snapshotted the wrong buffer.** It
    called `(buffer-name)` *inside* `with-temp-file`'s body, which rebinds
    the current buffer to its own internal temp buffer for that extent —
    so every failure snapshot was silently mislabeled (and its `eh-snapshot`
    content came from the wrong buffer entirely). Fixed by capturing the
    name and the snapshot before entering `with-temp-file`.
  - **`eh-doctor`'s own checks had three bugs**, all invisible until the
    checks actually ran against a live frame: the cairo check compared
    against `"cairo"` while `system-configuration-features` reports
    `"CAIRO"` (case-sensitive `member`, so it always missed, even on a
    cairo build); the image-scaling check used `eq` on floats (which
    compares object identity, not value, so `(eq 1.0 1.0)` isn't reliably
    true); and the frame-geometry check compared pixel width against a
    char-count×char-width *approximation* instead of the actually-requested
    pixel size, which DESIGN §12 itself specifies and which doesn't suffer
    the same rounding.
  - **The `:cairo` `:needs` guard only checked `(fboundp 'x-export-frames)`**,
    which is true on any cairo-enabled build *even under `-Q --batch` with
    no display* — so a cairo-requiring scenario didn't skip cleanly in
    batch mode as DESIGN promises, it hard-failed with "Window system frame
    should be used". Fixed by also requiring `(display-graphic-p)`.
- `eh-diff-shot`/`eh-baseline-accept` (and their JSON wrappers) were
  exercised directly under `emacs -Q --batch` with `eh-shot-to-file` mocked
  out (frame export needs a real cairo GUI frame; validated separately, see
  above) and a real ImageMagick `compare`/`convert`/`identify`:
  missing-baseline reporting, identical-image pass, beyond-tolerance
  failure with correct changed/total pixel counts, both explicit `:mask`
  and a `NAME.mask.json` sidecar excluding a changed region from the diff,
  and `baseline accept --all` all behave correctly.
- `_translate_key` (the `eh keys --x` Emacs-key-description → xdotool
  translator in `ehd.py`) had a real bug: it translated only a single key
  chord, so the design's own primary example, `eh keys "C-c C-e"` — one
  string containing *two* chords — produced garbage xdotool syntax instead
  of `ctrl+c ctrl+e`. Fixed to split on whitespace and translate each chord
  separately; re-verified against the design's own worked examples
  (`C-c C-e`, `<C-return>`, `S-RET`).
- `eh scroll --pixels` called `pixel-scroll-precision-scroll-up`
  unconditionally, which is Emacs 29+ only (confirmed: even Emacs 29.3
  reports it as not `fboundp` until `pixel-scroll` is loaded) and would
  `void-function` on the 27.1+ matrix this harness targets. Replaced with
  `eh-scroll-pixels`, which falls back to `set-window-vscroll` (24+) when
  the precision-scroll functions aren't available.
- The `--emacs V,...` matrix control flow in `ehd.py` (`handle_run` /
  `_run_one_version`) was originally exercised only with a mocked
  `SessionManager`. Re-run against the *real* dispatcher (two names on
  `PATH` pointing at the one real Emacs binary available, since no second
  genuine release is installed anywhere this harness has been driven so
  far) it found a real bug the mock's abstraction had hidden: a bad
  `--emacs` binary makes `subprocess.Popen` raise a plain `OSError`
  (`FileNotFoundError`), which isn't an `EhError`, so `_run_one_version`'s
  `except EhError` didn't catch it — it escaped uncaught and killed the
  *entire* matrix response (`internal ehd error`) instead of reporting that
  one version's failure and continuing, exactly contradicting the mock
  test's own (now corrected) claim and the code's own comment. It also
  leaked the Xvfb/openbox processes that version's session had already
  started, since nothing killed them on the way out. Fixed by catching
  `OSError` around the Emacs launch in `SessionManager.new`, killing the
  orphaned Xvfb/openbox first. Re-verified for real: `eh run smoke --emacs
  A,B` runs the full suite independently under both names and reports a
  per-version `matrix`; `eh run smoke --emacs A,bogus-binary` now correctly
  reports one version's real results alongside the other's clean failure,
  with the top-level `ok` false and the run continuing rather than dying.
- **`eh-run-scenarios-json` (the Elisp side of `eh run`, in
  `eh-scenario.el`) could not survive a single scenario failing or
  skipping.** It delegated to `ert-run-tests-batch`, which relies on ERT
  installing its own `debugger` binding around each test
  (`ert--run-test-internal`) to catch `ert-fail`/`ert-skip` without
  unwinding the stack. That binding is never consulted here: `eh run`
  arrives over `emacsclient --eval`, which runs inside
  `server-process-filter`'s dynamic extent, and `server.el` wraps that
  whole call in its own blanket `condition-case` (`(t (server-return-error
  proc err))`) — Emacs resolves a signal to the nearest enclosing
  `condition-case` *before* ever consulting `debug-on-error`/`debugger`, so
  server.el's handler always won first. In practice this meant *any*
  scenario failure or skip — not just a misreported result, the entire
  batch — escaped uncaught, killing the whole session with "session
  unreachable" instead of landing in the JSON summary. Every scenario
  written before this pass happened to pass, so this had never fired.
  (This is a known upstream ERT limitation, not specific to this harness —
  `ert.el` itself carries a FIXME citing Bug#24402/Bug#11218 about moving
  off the `debugger` hook onto `signal-hook-function`, which as of the
  Emacs used here it has not done.) Fixed by no longer delegating to
  `ert-run-tests-batch` at all: `eh-run-scenarios-json` now selects tests
  via `ert-select-tests` and runs each one directly, wrapped in a plain
  `condition-case` — which *does* resolve correctly in this context, since
  it is the same mechanism server.el's own handler uses and Emacs finds the
  innermost one first. Re-verified with a live daemon (bypassing `ehd.py`
  entirely, driving `emacsclient --eval` by hand against a from-scratch
  `server-start`'d Emacs) on a synthetic pass/fail/skip mix, then against
  the real `smoke` suite twice from cold sessions.
- Two new permanent scenarios in `profiles/smoke/scenarios/smoke.el` prove
  DESIGN §14 phase 2's literal acceptance test, which had only been
  plumbed, not exercised, before this pass:
  - `smoke/image-slices-are-addressable` inserts a real tall PNG fixture
    (`tall-stripes.png`, five distinct 100px bands) via the built-in
    `insert-sliced-image` and asserts, via `eh-snapshot`, that each slice
    is a separately addressable run with correct, monotonically increasing
    pixel geometry — the position math `eh click`'s "click the third slice"
    interactive test (separately verified live via real `xdotool` clicks,
    not scenario-expressible per DESIGN §8.1 tier 2b) depends on. Getting
    the assertions right surfaced and fixed a real decoding gap:
    `eh--display-descriptor` didn't recognise the `((slice X Y W H) (image
    ...))` wrapper form `insert-sliced-image` actually produces (only the
    `(image :slice ...)` plist form), and `eh-expect-display-image`'s
    `:slices` check was a silent no-op that never actually failed on a
    mismatch.
  - `smoke/diff-shot-detects-pixel-change` proves `eh-diff-shot` "fails on
    a one-pixel change and passes on a rerun" without committing a baseline
    PNG to the repo: baselines are keyed per Emacs-version/geometry/theme
    (§8.4), so a baseline captured in any one sandbox would only ever match
    that exact environment and silently skip everywhere else, proving
    nothing in CI. Instead it points `eh-baseline-dir` at a scratch
    directory for its own duration, accepts a screenshot of the current
    frame as that scratch baseline via the real `eh-baseline-accept`, then
    asserts against it with the real `eh-diff-shot`: unchanged, it passes
    with zero changed pixels; after a real, visible edit, it fails with a
    nonzero count. A companion scenario,
    `smoke/visual-drift-skips-without-baseline`, asserts that
    `eh-expect-no-visual-drift` itself `ert-skip`s (not fails, not silently
    passes) for a name that will never have an accepted baseline — the
    ordinary case for a freshly-run profile.
- What's *still not* validated here: `docker build` itself (blocked by
  egress policy, see above), `ffmpeg` video/gif capture, and the browser
  view (x11vnc/websockify/noVNC) — none of those were exercised in this
  pass.

The repository name and the `eh` command name are placeholders — rename
freely, but rename consistently.

## The one-paragraph version

A container runs `Xvfb`, a pinned cairo-enabled GNU Emacs, and whatever side
services a given profile declares (DESIGN §9 covers the pattern for a
package that talks to a subprocess: a real instance of it plus a scriptable
fake speaking the same protocol). A small in-container dispatcher (`ehd`)
exposes that Emacs over a Unix socket; a thin client (`eh`) reaches it over
SSH from wherever the agent is running. The agent's default move is **not**
to look at pixels: it asks Emacs for a structured dump of buffer text,
overlays, text properties, faces and image descriptors, and asserts on
that. Screenshots (`x-export-frames`, taken from inside Emacs — no window
manager races) are the backstop for the handful of things only redisplay
knows. Scenarios are ERT tests written in Emacs Lisp that run *inside* the
instance under test, so the same file works both under the agent's hand and
in CI.

## Layout

```
emacs-harness/
├── DESIGN.md                  ← the spec
├── AGENTS.md / CLAUDE.md      ← the agent operating contract (DESIGN §11)
├── docs/example-scenarios.md  ← a fully worked, fictional-package scenario
│                                 catalogue illustrating the categories of
│                                 behaviour a real profile would target
├── .github/workflows/ci.yml   ← builds the image, runs `eh doctor` + `eh run smoke` headlessly
├── bin/eh                     ← thin client (runs on your laptop)
├── container/                 ← Dockerfile, supervisord, entrypoint
├── compose.yaml                ← local-dev wrapper around the one image
├── ehd/                       ← in-container dispatcher (ehd.py) + bridge (ehd_cli.py)
├── elisp/                     ← eh-driver.el, eh-scenario.el, eh-profile.el, eh-init-core.el
├── profiles/
│   └── smoke/                 ← trivial profile that proves the core is generic
│       (no other profiles exist yet -- add one for whatever package you
│        want to test, see DESIGN.md §8.4)
└── runs/                      ← per-run artifacts (gitignored)
```

## Quickstart (once built)

```
docker build -f container/Dockerfile -t emacs-harness:dev .
docker run --rm -it emacs-harness:dev doctor
docker run -d --name emacs-harness -p 6080:6080 emacs-harness:dev server
EH_TRANSPORT=docker EH_CONTAINER=emacs-harness bin/eh doctor
EH_TRANSPORT=docker EH_CONTAINER=emacs-harness bin/eh run smoke
```
