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
remains unexercised; see DESIGN §13.3 open question 1).

**Phase 4 (the MCP server) is now implemented and proven end-to-end**: the
HTTP transport in `ehd.py` (`POST /v1/<cmd>`, DESIGN §6.1 — a shim over the
exact same `handle()` dispatcher the Unix socket uses, not a second
implementation), the `http` branch of `bin/eh`'s transport dispatch, and
`mcp-server/eh_mcp_server.py`, an MCP server exposing the eight tools DESIGN
§14 names (`emacs_eval`, `emacs_snapshot`, `emacs_keys`, `emacs_click`,
`emacs_screenshot`, `emacs_wait`, `emacs_run_scenario`, `emacs_session`),
each a thin translation of one MCP tool call into one HTTP round trip to
`ehd`. Auth is `CF-Access-Client-Id`/`CF-Access-Client-Secret` header
matching against `EH_HTTP_CLIENT_ID`/`EH_HTTP_CLIENT_SECRET`, defense in
depth for whatever reaches the origin directly — the real access boundary,
per DESIGN §10.2, is the Cloudflare Tunnel + Access application in front of
it. **Phase 4's own acceptance test** — "Claude Code with the MCP server
configured can, in one session and with no Bash calls, open a fixture
notebook, run a cell, wait for idle, and report the resolved face of the
output border" — is proven directly in `mcp-server/test_acceptance.py`
(committed, and run in CI): it drives `eh_mcp_server.py` exactly as a real
MCP client would, over real stdio JSON-RPC via the official `mcp` SDK's own
`ClientSession`, against `smoke`'s `hello.txt` fixture and marker-facing key
binding standing in for the fictional notebook/cell/output-border example,
the same substitution every other acceptance test in this repo makes.

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
- **Phase 4's HTTP transport and MCP server were validated live**, the same
  way (`ehd.py` run directly against a real display, not mocked), and doing
  so surfaced three real, previously-latent bugs in the *core* eval bridge —
  not new code this pass wrote, code every `eh` command has depended on
  since phase 1, just never driven this way (one CLI invocation at a time,
  the way an interactive agent actually uses it) until now:
  - **`eh--eval-capturing` could not actually catch a Lisp error.** It used
    a `debug-on-error`+custom-`debugger` substitution to turn a signalled
    error into the JSON error envelope DESIGN §6.2 promises. That technique
    silently does nothing here: `eh-driver-run` is invoked via `emacsclient
    --eval`, which server.el evaluates inside its own blanket
    `condition-case` (`(t (server-return-error proc err))`), and Emacs
    resolves a signal to the *nearest enclosing `condition-case`* before
    ever consulting `debug-on-error`/`debugger` — so server.el's own handler
    always won first. Concretely, `eh eval '(error "boom")'` used to kill
    the whole session (`emacsclient` exits nonzero, `ehd.py` marks the
    session dead) instead of returning `{"ok": false, "error": {...}}`.
    This is exactly the defect already found and fixed for
    `eh-run-scenarios-json` (see the phase 1-3 entry above) — just never
    applied to the bridge every other `eh` command goes through. Fixed by
    switching `eh--eval-capturing` to a plain `condition-case` (which *does*
    resolve correctly here, per the same reasoning), using
    `signal-hook-function` — which still runs at the point of the signal,
    before the stack unwinds — to keep capturing a real backtrace without
    reintroducing the `debug-on-error` problem. That fix had its own bug on
    the first attempt: the naive `signal-hook-function` handler recurses
    into itself (`backtrace`/`with-output-to-string` can themselves signal)
    and blows the C stack, hanging the whole session at 100% CPU — caught
    live, fixed by rebinding `signal-hook-function` to nil for the handler's
    own extent.
  - **Named waiters (`eh wait NAME`) never matched.** `ehd.py` sends the
    waiter name as an Elisp *string* (the file-based eval protocol has no
    way to send a bare symbol); `eh-register-waiter` keys `eh-waiters` by
    *symbols*. `assoc` on a string against symbol keys never matches, so
    every named-waiter lookup failed with "no such waiter" — for every
    profile, always, since day one; nothing had ever exercised this path
    end-to-end before (the smoke scenarios use `eh-wait-for` with a lambda
    directly, not the CLI's named-waiter string path). Fixed by interning
    the name in `eh-wait-name` before the lookup.
  - **`profiles/<name>/profile.el` — the declarative manifest that
    registers named waiters, default snapshot props and log buffers — was
    never actually loaded by any session.** `eh-profile.el`'s own header
    comment says it "is loaded as part of `profiles/<name>/init.el`", but
    `profiles/smoke/init.el` never did that load, and neither `ehd.py`'s
    generated `session-init.el` nor anything else did it on the profile's
    behalf. So every `eh-defprofile` declaration was dead code in every
    real session — compounding the bug above, since even a correct
    string→symbol lookup would still have found nothing registered. Fixed
    by adding the missing `(load (expand-file-name "profile.el"
    eh-profile-dir))` to `profiles/smoke/init.el`, per the convention
    `eh-profile.el` already documented; any future profile needs the same
    line.
  - **A buffer-less `eh snapshot`/`eh click --at-point` silently operated
    on the wrong buffer across separate `eh` invocations.** Both defaulted
    to `(current-buffer)`/`(point)`, which is *not* stable across
    `emacsclient --eval` calls the way it would be for one continuous
    scenario body: server.el resets `current-buffer` to its own connection
    buffer around every request, so a bare `(current-buffer)` evaluated in
    one `eh` call never reflects what an *earlier*, separate `eh` call left
    on screen — verified directly: right after `find-file` switches to a
    fixture buffer, the very next, separate `eh eval` call reports
    server.el's own connection buffer as current, even though the frame
    still correctly shows the fixture. This meant the exact interactive,
    one-command-at-a-time usage pattern the whole harness's agent contract
    is built around silently broke the two conveniences DESIGN documents as
    not requiring an explicit buffer. Fixed with a new `eh-selected-buffer`
    (the selected window's buffer in the session's frame, not
    `current-buffer`) and `eh-selected-point`, used by `eh-snapshot`'s
    default and by `eh click --at-point`'s position resolution.
  - All four were caught, root-caused and reverified using the exact
    end-to-end flow phase 4's own acceptance test needs — open a fixture,
    press a key, wait on a named waiter, snapshot with no `--buffer`,
    resolve a click `--at-point` — over the real HTTP transport, then again
    through the real MCP server via the official SDK's stdio client. None
    of the four are HTTP- or MCP-specific; every one also affects the
    ssh/docker/local transports and `bin/eh` used directly, just never
    surfaced there because interactive, separate-invocation usage (as
    opposed to one continuous scenario body) hadn't been exercised this
    thoroughly before.
- What's *still not* validated here: `docker build` itself — reproduced
  again this pass (Docker Hub's CDN, `production.cloudfront.docker.com`,
  still answers 403 through this sandbox's egress policy, on the very first
  `FROM debian:bookworm-slim` layer, before reaching anything in this repo)
  — `ffmpeg` video/gif capture, and the browser view
  (x11vnc/websockify/noVNC). Also still unvalidated: the actual Cloudflare
  Tunnel + Access path in front of the HTTP API (DESIGN §10.2) — the
  `CF-Access-Client-Id`/`Secret` header check in `ehd.py` is proven, but
  there is no Cloudflare account in this environment to prove the tunnel
  itself terminates there correctly.

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
├── mcp-server/                ← MCP server (eh_mcp_server.py): runs where Claude Code
│                                 runs, not in the container -- a thin shim over ehd's
│                                 HTTP API (DESIGN §14 phase 4); test_acceptance.py is
│                                 phase 4's own acceptance test, frozen and run in CI
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

### The HTTP API and the MCP server (phase 4)

Off by default. Enable it at `docker run` time, publish 8080 alongside
6080, and set the same `CF-Access-Client-Id`/`Secret` pair on both sides —
`ehd` checks them as defense in depth; the real access boundary is a
Cloudflare Tunnel + Access application on its own hostname in front of
8080, same pattern DESIGN §10.2 already uses for the noVNC view:

```
docker run -d --name emacs-harness -p 6080:6080 -p 8080:8080 \
    -e EH_HTTP_ENABLE=1 -e EH_HTTP_CLIENT_ID=<id> -e EH_HTTP_CLIENT_SECRET=<secret> \
    emacs-harness:dev server

curl https://emacs-harness-api.example.com/health   # once the tunnel is up
```

Point `bin/eh` at it directly:

```
EH_TRANSPORT=http EH_HOST=https://emacs-harness-api.example.com \
EH_CF_ACCESS_CLIENT_ID=<id> EH_CF_ACCESS_CLIENT_SECRET=<secret> \
    bin/eh doctor
```

Or run the MCP server (`pip install -r mcp-server/requirements.txt`) and
point Claude Code (or any MCP client) at it over stdio, with the same
`EH_HOST`/`EH_CF_ACCESS_CLIENT_ID`/`EH_CF_ACCESS_CLIENT_SECRET` set in its
environment:

```json
{
  "mcpServers": {
    "emacs-harness": {
      "command": "python3",
      "args": ["/path/to/emacs-harness/mcp-server/eh_mcp_server.py"],
      "env": {
        "EH_HOST": "https://emacs-harness-api.example.com",
        "EH_CF_ACCESS_CLIENT_ID": "<id>",
        "EH_CF_ACCESS_CLIENT_SECRET": "<secret>"
      }
    }
  }
}
```
