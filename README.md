# emacs-harness

A GUI Emacs test harness that an AI coding agent can drive: a real, graphical
Emacs running on a headless X display inside a container, with a
control surface for evaluating Lisp, sending real keystrokes and mouse
clicks, taking screenshots, and asserting on what Emacs actually drew —
plus a browser view of the same live instance for point-and-click work and
human eyeballs.

> The repository name and the `eh` command name are placeholders — rename
> freely, but rename consistently.

## What this is for

Plenty of Emacs packages are 1,000+ lines of Emacs Lisp whose most
failure-prone behaviour is *visual and interactive*: inline images (some
sliced one slice per line, so ordinary scrolling has to walk through a tall
image correctly), buffer regions that are text but read-only, overlay
boundaries and faces that change when some underlying state goes stale,
streaming or asynchronous output that redraws in place, a mode line that
reports live state pushed from a subprocess, and scroll/point discipline
("insertion never steals point, but a window already at the end follows new
output").

A package like that usually already has a decent batch ERT suite, and that
suite should stay — but it runs under `emacs -Q --batch`, where there is no
redisplay, no image rasterisation, no real window geometry, and no real key
lookup. Batch ERT can assert that an `image` display property *exists*; it
cannot assert that the image actually decoded, that slicing produced the
right number of addressable lines, or that a key sequence actually reaches
the command the keymap claims it does.

This harness closes that gap. It runs a real, graphical Emacs on a headless
X display and gives an agent (or a human) a control surface to drive it and
assert on it precisely:

- **Structured introspection, not pixel-squinting.** The default assertion
  mechanism is `eh snapshot` — a diffable dump of buffer text, resolved
  faces, overlays, text properties, image descriptors and window geometry —
  not a screenshot comparison. Screenshots exist for the handful of
  questions only redisplay itself can answer ("did this actually
  rasterise").
- **Real input.** Keys go through `execute-kbd-macro` by default (the real
  keymap, the real command loop, `last-command` chains all work) or through
  a real X server via `xdotool` when you specifically need to prove a key
  like `<C-return>` arrives correctly.
- **Determinism.** Two runs of the same scenario on the same image produce
  byte-identical screenshots — one pinned font, one pinned theme, no window
  manager interference, a frozen clock.
- **Package-agnostic core.** The core knows nothing about any specific
  package under test; what it knows about a package lives entirely in a
  **profile** (a directory — see `DESIGN.md` §8.4). `profiles/smoke/` is a
  trivial profile with no external dependencies that exists purely to prove
  the core doesn't secretly assume anything about a "real" profile.
- **One command runs everything**, batch ERT included, and writes a single
  artifact directory (screenshots, snapshots, `*Messages*`, backtraces) an
  agent can point at when reporting a failure.

See [`DESIGN.md`](DESIGN.md) for the full specification this was built
against, and [`docs/example-scenarios.md`](docs/example-scenarios.md) for a
fully worked, fictional-package scenario catalogue that illustrates the
categories of behaviour a real profile would target.

## When to reach for this

Use this when you maintain (or are evaluating a PR against) an Emacs
package where the interesting bugs live in things `emacs --batch` cannot
see: a mode that inserts and slices images, a package with output overlays
or read-only regions, anything that talks to a subprocess or a network
connection and needs its mode-line/redraw behaviour tested under real
async conditions, or a UI surface (clicking, dragging, scrolling) that a
batch test simply cannot exercise.

Don't reach for this to replace your batch ERT suite — it *runs* that
suite unchanged (`eh run <profile> --batch`) and adds to it; it isn't a
rewrite. And it isn't a general remote-desktop product — the noVNC browser
view is a debugging affordance for a human or for Claude-in-Chrome, not the
primary way an agent is meant to drive it.

## How it works

```
  agent (Claude Code, a human, CI) ──▶ bin/eh  (thin client)
                                          │
                     ssh / docker exec / http (§ Setup below)
                                          ▼
                     docker container `emacs-harness`
                         │
                         ├── ehd — dispatcher (Unix socket + optional HTTP API)
                         │     └── one Xvfb + openbox + Emacs process per session
                         ├── x11vnc + websockify → noVNC browser view (:6080)
                         └── artifacts → runs/<run-id>/<scenario>/
```

A container runs `Xvfb`, a pinned cairo-enabled GNU Emacs, and (per-profile)
whatever side services a package needs — DESIGN §9 covers the pattern for a
package that talks to a subprocess: a real instance of it, plus a
scriptable fake speaking the same protocol for the failure modes a real
backend can't produce on demand. A small in-container dispatcher (`ehd`)
owns session lifecycle and exposes that Emacs over a Unix socket (and,
optionally, over an HTTP API — see below); a thin client (`bin/eh`) reaches
it from wherever the agent is running. The agent's default move is **not**
to look at pixels: it asks Emacs for a structured dump of buffer text,
overlays, text properties, faces and image descriptors, and asserts on
that. Screenshots (`x-export-frames`, taken from inside Emacs — no window
manager races) are the backstop for the handful of things only redisplay
knows. Scenarios are ERT tests written in Emacs Lisp that run *inside* the
instance under test, so the same file works both under an agent's hand and
in CI.

## Repository layout

```
emacs-harness/
├── DESIGN.md                  ← the spec
├── AGENTS.md / CLAUDE.md      ← the agent operating contract (DESIGN §11)
├── docs/example-scenarios.md  ← a fully worked, fictional-package scenario
│                                 catalogue illustrating the categories of
│                                 behaviour a real profile would target
├── docs/profiles-for-your-package.md
│                              ← how to add your own package: profile layout,
│                                 out-of-tree profiles, eh-fake-bridge, CI
├── .github/workflows/ci.yml   ← builds the image, runs the smoke profile
│                                 and the HTTP/MCP acceptance test headlessly
├── bin/eh                     ← thin client (runs wherever the agent runs)
├── bin/eh-fake-bridge         ← scriptable stand-in for a package's backend
│                                 process (DESIGN §9.2); package-agnostic
├── container/                 ← Dockerfile, supervisord, entrypoint
├── compose.yaml                ← local-dev wrapper around the one image
├── ehd/                       ← in-container dispatcher (ehd.py) + bridge (ehd_cli.py)
├── elisp/                     ← eh-driver.el, eh-scenario.el, eh-profile.el, eh-init-core.el
├── mcp-server/                ← MCP server (eh_mcp_server.py): runs where Claude Code
│                                 runs, not in the container -- a thin shim over ehd's
│                                 HTTP API (DESIGN §14 phase 4); test_acceptance.py is
│                                 phase 4's own acceptance test, frozen and run in CI
├── profiles/
│   └── smoke/                 ← trivial profile that proves the core is generic,
│                                 and eh-fake-bridge's own coverage
│       (no other profiles live here -- a profile for a real package belongs
│        in that package's own repository, mounted in; see
│        docs/profiles-for-your-package.md and DESIGN.md §8.4)
└── runs/                      ← per-run artifacts (gitignored)
```

---

## Setup

There are two sides to set up: the **Docker side** (the container that
actually runs Emacs) and the **agent side** (whatever runs `bin/eh` or the
MCP server and talks to that container).

### Docker side

Build the image and check it with `eh doctor` (DESIGN §12 — the first thing
to run after any build, and the first thing to run whenever you're not sure
what state something is in):

```sh
docker build -f container/Dockerfile -t emacs-harness:dev .
docker run --rm -it emacs-harness:dev doctor
```

`doctor` exits non-zero and prints a red/green table if anything about the
image is wrong (missing cairo support, wrong font, a bad frame geometry,
…) — it should be all green on a normal build.

The image has three run modes, selected by the first argument to the
entrypoint (DESIGN §5.1):

| Mode | What it does | When to use it |
| --- | --- | --- |
| `server` | Long-lived: brings up one default session, the noVNC browser view, and `ehd`. Stays up. | An agent exploring interactively, or a human watching. |
| `run` | One-shot: starts a session, runs the named profile's scenarios (and/or its batch suite), writes artifacts, exits with the suite's status. | CI, or a clean one-off scenario run. |
| `doctor` | Runs the environment self-check and exits. | Right after every build. |

Bring up a long-lived instance and give it a name so `bin/eh` can reach it:

```sh
docker run -d --name emacs-harness -p 6080:6080 emacs-harness:dev server
```

That publishes the noVNC browser view at `http://localhost:6080` (a human,
or Claude-in-Chrome, can watch or click there — see DESIGN §10). For
day-to-day development on a laptop, `compose.yaml` wraps the same image:

```sh
docker compose up -d
```

**Deploying this for real** (e.g. on a homelab server, reached over SSH,
with the browser view exposed through a Cloudflare Tunnel) is the target
deployment DESIGN.md was written against (see its header and §10.2): run
the container on the server, `ssh -L 6080:localhost:6080 <host>` while
developing (zero exposure, zero configuration), and when you do want it
reachable from outside, put a Cloudflare Tunnel + Access application in
front of it on its own hostname rather than exposing the port directly —
Access service tokens are the "machine" auth path (SSH, and the HTTP API
below); an Access application with an identity-login policy is what
protects the *browser* view, since a browser can't send service-token
headers.

#### Optional: the HTTP API (for the MCP server)

Off by default. It exists so a client with no `ssh`/`docker` access — most
notably the MCP server below — can still reach `ehd`. Enable it at
`docker run` time, publish 8080 alongside 6080, and set a
`CF-Access-Client-Id`/`Secret` pair (`ehd` checks these itself as defense
in depth; the real access boundary should still be a Cloudflare Tunnel +
Access application on its own hostname in front of 8080, same pattern as
above):

```sh
docker run -d --name emacs-harness -p 6080:6080 -p 8080:8080 \
    -e EH_HTTP_ENABLE=1 -e EH_HTTP_CLIENT_ID=<id> -e EH_HTTP_CLIENT_SECRET=<secret> \
    emacs-harness:dev server

curl http://localhost:8080/health          # locally
curl https://emacs-harness-api.example.com/health   # once a tunnel is up
```

### Agent side

`bin/eh` is a thin, dependency-free client: it builds a JSON request, ships
it to `ehd` over whichever transport you configure, prints the response,
and exits with a code you can branch on (`0` success, `1` assertion/scenario
failure, `2` usage error, `3` timeout, `4` Emacs signalled an error, `5`
session unreachable/dead).

Pick a transport with `$EH_TRANSPORT` (or `~/.config/eh/config`, INI-style
`[eh] transport=...`):

| Transport | Set | When |
| --- | --- | --- |
| `docker` (default) | `EH_CONTAINER=emacs-harness` | The agent runs on the same host as Docker. |
| `ssh` | `EH_HOST=<ssh-host>` (plus `EH_CONTAINER` if not the default name) | The agent runs elsewhere and reaches the Docker host over SSH. |
| `local` | `EH_SOCK=/run/eh/eh.sock` | Running *inside* the container (this is what `entrypoint.sh` itself uses for `run`/`doctor` mode). |
| `http` | `EH_HOST=https://...`, plus `EH_CF_ACCESS_CLIENT_ID`/`EH_CF_ACCESS_CLIENT_SECRET` if the origin checks them | The MCP server, or any client with only network access, no `ssh`/`docker` CLI. |

```sh
EH_TRANSPORT=docker EH_CONTAINER=emacs-harness bin/eh doctor
EH_TRANSPORT=ssh EH_HOST=myhomelab bin/eh doctor
EH_TRANSPORT=http EH_HOST=https://emacs-harness-api.example.com \
  EH_CF_ACCESS_CLIENT_ID=<id> EH_CF_ACCESS_CLIENT_SECRET=<secret> bin/eh doctor
```

If you're driving this with Claude Code (or any coding agent) over Bash,
that's it — put `bin/eh` on `PATH`, set the transport env vars, and read
[`AGENTS.md`](AGENTS.md) (symlinked as `CLAUDE.md`) for the operating
discipline: snapshot over screenshot, always wait rather than sleep, read
the run directory on failure, and freeze what you learn into a scenario.

#### The MCP server (no Bash calls)

`mcp-server/eh_mcp_server.py` is a separate, small deliverable that runs
*wherever Claude Code runs* — not inside the container — and exposes eight
MCP tools (`emacs_eval`, `emacs_snapshot`, `emacs_keys`, `emacs_click`,
`emacs_screenshot`, `emacs_wait`, `emacs_run_scenario`, `emacs_session`),
each a thin shim that makes one HTTP call to `ehd`'s HTTP API above. Use
this when you want Claude Code to drive the harness as first-class tool
calls instead of shelling out to `bin/eh`.

```sh
pip install -r mcp-server/requirements.txt
```

Then point an MCP client at it over stdio, with the same HTTP credentials
as above in its environment:

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

Every tool takes an optional `session` argument; when you omit it, `ehd`
falls back to its own `$EH_SESSION` or the sole running session — but that
fallback is evaluated in `ehd`'s environment inside the container, not the
MCP server's, since the HTTP transport (unlike SSH/`docker exec`) doesn't
share an environment with `ehd`. Pass `session` explicitly unless the
harness has exactly one session running (e.g. `server` mode's own
`"default"` session).

---

## Usage examples

These were captured against a real session (`eh doctor` all green, a real
cairo-enabled GTK Emacs on a real X display) — not invented output.

### A CLI walkthrough

Bring up a session against the `smoke` profile (the trivial profile that
ships with the harness — swap in your own once you've written one):

```
$ eh session new --name demo --profile smoke
{
  "ok": true,
  "session": "demo",
  "display": 105,
  "exit_code": 0
}
```

Evaluate Lisp directly (tier 1 — cheap, exact, and the JSON envelope always
tells you what happened, success or Lisp error):

```
$ eh --session demo eval '(+ 1 2)'
3
```

Open a fixture and drive it with a real key sequence rather than calling
the underlying function (so the keymap and command loop are actually
exercised — DESIGN §6.3):

```
$ eh --session demo eval \
    '(find-file (expand-file-name "hello.txt" eh-profile-fixtures-dir))'
#<buffer hello.txt>

$ eh --session demo keys "C-c C-s"
{
  "ok": true,
  "exit_code": 0
}
```

Assert on the result with a snapshot instead of a screenshot — this is the
tier-1 workhorse, and answers "did the key binding actually face the
marker text, without dirtying the buffer" exactly, in one call:

```
$ eh --session demo snapshot --props smoke-marker
{
    "version": 1,
    "buffer": "hello.txt",
    "point": 31,
    "mark": false,
    "modified": false,
    "major-mode": "text-mode",
    "mode-line": " -:---  hello.txt      All L2       (Text) ",
    "runs": [
        { "beg": 1,  "end": 19, "text": "line one\nline two ",
          "face": false, "read-only": false, "invisible": false, "overlays": [] },
        { "beg": 19, "end": 31, "text": "SMOKE-MARKER",
          "face": "smoke-marker-face", "read-only": false, "invisible": false,
          "overlays": [] },
        { "beg": 31, "end": 53, "text": " line three\nline four\n",
          "face": false, "read-only": false, "invisible": false, "overlays": [] }
    ]
}
```

`"face": "smoke-marker-face"` on exactly the `SMOKE-MARKER` run and
`"modified": false` on the whole buffer — that's the assertion, no pixels
needed. Take a screenshot only when you specifically need to prove
something rasterised:

```
$ eh --session demo shot --out /tmp/frame.png
{
  "ok": true,
  "path": "/tmp/frame.png",
  "bytes": 18962,
  "sha256": "21f423b6b633bed1a7f6b7fbf636e131c0216103c239ea68013fab205e5d7b4d",
  "exit_code": 0
}
```

And run the profile's whole scenario suite in one shot (a fresh session by
default — DESIGN §5.2 — writing a single artifact directory an agent can
point at when reporting a failure):

```
$ eh run smoke
PASSED   smoke/diff-shot-detects-pixel-change
PASSED   smoke/face-assertion
PASSED   smoke/image-renders
PASSED   smoke/image-slices-are-addressable
PASSED   smoke/open-file-and-screenshot
SKIPPED  smoke/visual-drift-skips-without-baseline
/tmp/runs/20260901T153911Z-smoke-9a44ac
```

That last line is the run directory (`report.json`, `junit.xml`,
screenshots, snapshots, `*Messages*`, a backtrace on any failure) — quote
it in a bug report rather than re-deriving it.

### Writing a scenario for your own package

Scenarios are Emacs Lisp, and they run *inside* the instance under test —
not shell scripts full of `eh` calls (DESIGN §8.1). The intended loop:
explore a bug interactively with `eh eval`/`eh keys`/`eh shot`, work out
what's actually wrong, fix it, then freeze what you learned into a scenario
under `profiles/<name>/scenarios/` so it can never come back silently.
`profiles/smoke/scenarios/smoke.el` is a small, real example to read first;
`docs/example-scenarios.md` is a longer, fully worked catalogue against a
fictional package covering the categories DESIGN §1 calls out (sliced
images, output overlays, streaming redraws, mode-line state, scroll
discipline). Adding a package to the harness is adding a profile
directory (`profile.el`, `init.el`, `fixtures/`, `scenarios/*.el` — see
DESIGN §8.4) — never editing the core.

**[`docs/profiles-for-your-package.md`](docs/profiles-for-your-package.md)
is the practical guide to doing that**, and covers the two things this
section skips: keeping the profile in the *package's* repository and
mounting it in, so scenarios change in the same pull request as the code
they test; and `bin/eh-fake-bridge`, the scriptable stand-in for a
package's backend process (DESIGN §9.2) that makes a wedged request, a
truncated reply, or a kernel dying mid-run something a scenario can ask
for by name.

### From Claude Code, via MCP

With the MCP server configured (see Setup above), an agent drives the same
surface as first-class tool calls instead of Bash — for example, opening a
fixture, exercising a key binding, waiting for the session to settle, and
reading back the resolved face, with zero shell calls:

```
emacs_session(action="new", name="demo", profile="smoke")
emacs_eval(session="demo",
           form='(find-file (expand-file-name "hello.txt" eh-profile-fixtures-dir))')
emacs_keys(session="demo", keys=["C-c C-s"])
emacs_wait(session="demo", what="smoke-ready", timeout=10)
emacs_snapshot(session="demo", props=["smoke-marker"])
# -> the same JSON envelope as the CLI walkthrough above
emacs_screenshot(session="demo")
# -> the metadata envelope as text, plus the actual PNG as image content
```

`mcp-server/test_acceptance.py` is exactly this flow, committed and run in
CI as phase 4's own acceptance test — read it for a complete, working
example of driving the MCP server from Python.

---

## Is this ready to deploy as-is?

Implementation-wise: yes, all five phases in `DESIGN.md` §14 are built, and
every phase's own acceptance test has been proven against a real,
graphical `emacs-gtk` + `Xvfb` + `openbox` stack — not mocked, not just
"wired up and assumed correct" (see the validation log below for exactly
what was run and what it found).

One honest caveat: `docker build` itself has **never completed** in any
environment this harness has been developed in so far — every sandbox used
so far blocks Docker Hub's CDN at the network-policy level, so the build
fails on the base `FROM debian:bookworm-slim` layer before reaching
anything in this repo. Everything above was validated by installing the
same packages (`emacs-gtk`, `Xvfb`, `openbox`, ImageMagick, `xdotool`, …)
directly on a host and running `ehd.py`/`bin/eh` exactly as the container
would, which is enough to prove the *logic* is correct against a real
display but is **not** the same as a clean `docker build` succeeding. The
GitHub Actions workflow (`.github/workflows/ci.yml`, which does have normal
Docker Hub access from a hosted runner) is the first place the actual image
build gets exercised — treat a green run there, plus its `eh doctor` step,
as the real "does this deploy" signal before trusting it on a homelab
server.

A few other things are implemented but not yet exercised anywhere: `ffmpeg`
video/gif capture, the noVNC browser view chain (`x11vnc`/`websockify`),
the real Cloudflare Tunnel + Access path in front of either 6080 or 8080,
and a genuine multi-version Emacs matrix (the `--emacs V,...` control flow
is proven, but every environment this has run in so far has exactly one
real Emacs release installed). There is also, deliberately, only one
profile so far (`smoke`) — DESIGN §8.5's own next step, once the core is
proven generic, is adding a small profile for a package you actually use,
to sanity-check the harness is usable by someone who didn't build it.

None of that blocks trying it — building the image for real and running
`eh doctor` against it is the right first step in any environment with
normal Docker Hub access, and it should already be all green.

## Implementation status and validation notes

**All five phases are implemented.** Phase 0-1: the container image, the
`ehd` dispatcher, the `eh` client, the Elisp driver (`eh-driver.el`), the
scenario DSL (`eh-scenario.el`), and the `smoke` profile that proves the
core is package-agnostic. Phase 2: `eh click`/`eh drag`/`eh scroll`/`eh
keys --x`, `eh video` (including `--gif`), and pixel baselines via `eh
diff-shot`/`eh baseline accept` with `.mask.json` sidecar support, wired
end-to-end including the scenario-level `eh-expect-no-visual-drift`. Phase
3: the `--emacs V,...` matrix flag on `eh run` and the GitHub Actions
workflow that builds the image and runs the smoke profile headlessly.
Phase 4: the HTTP transport in `ehd.py` and the MCP server — see below.

Diff-shot's pixel comparison (ImageMagick `compare`/`identify`, plus mask
rectangles applied via `convert -draw`) is implemented once, in Elisp
(`eh-diff-shot` in `eh-driver.el`), and called both by the CLI (`eh
diff-shot`/`eh baseline accept`, via a thin `emacs_eval` wrapper in
`ehd.py`) and by scenarios (`eh-expect-no-visual-drift`) — not
reimplemented per caller, since a scenario running inside Emacs has no
channel back out to `ehd` mid-test (see DESIGN §8.1).

### What's been validated

- All Python (`bin/eh`, `ehd/ehd.py`, `ehd/ehd_cli.py`,
  `mcp-server/eh_mcp_server.py`, `mcp-server/test_acceptance.py`) compiles
  cleanly and passes `pyflakes` (one pre-existing unused import, `socket`
  in `ehd.py`, predates this and is unrelated to it).
- All Elisp (`elisp/*.el`) byte-compiles cleanly (only benign warnings for
  GUI-only primitives and variables defined via `require` at runtime).
- **`eh doctor` and `eh run smoke` pass end-to-end against a real
  `emacs-gtk` + `Xvfb` + `openbox`**, run directly via `ehd.py`/`bin/eh`
  outside Docker — repeatedly, from a fully cold process state, not once by
  chance. Getting there found and fixed real bugs, all in code that had
  never actually been run against a live display before:
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
- Two permanent scenarios in `profiles/smoke/scenarios/smoke.el` prove
  DESIGN §14 phase 2's literal acceptance test:
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
  so surfaced four real, previously-latent bugs in the *core* eval bridge —
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
    `eh-run-scenarios-json` above — just never applied to the bridge every
    other `eh` command goes through. Fixed by switching
    `eh--eval-capturing` to a plain `condition-case` (which *does* resolve
    correctly here, per the same reasoning), using `signal-hook-function`
    — which still runs at the point of the signal, before the stack
    unwinds — to keep capturing a real backtrace without reintroducing the
    `debug-on-error` problem. That fix had its own bug on the first
    attempt: the naive `signal-hook-function` handler recurses into itself
    (`backtrace`/`with-output-to-string` can themselves signal) and blows
    the C stack, hanging the whole session at 100% CPU — caught live,
    fixed by rebinding `signal-hook-function` to nil for the handler's own
    extent.
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

### What's still not validated

`docker build` itself — reproduced again during the phase 4 pass (Docker
Hub's CDN, `production.cloudfront.docker.com`, still answers 403 through
this sandbox's egress policy, on the very first `FROM debian:bookworm-slim`
layer, before reaching anything in this repo); `ffmpeg` video/gif capture;
the browser view (`x11vnc`/`websockify`/noVNC); the actual Cloudflare
Tunnel + Access path in front of either port (the `CF-Access-Client-Id`/
`Secret` header check in `ehd.py` is proven, but there is no Cloudflare
account in any environment this has run in to prove a tunnel itself
terminates there correctly); any profile beyond `smoke` itself; and pinned
multi-version Emacs *images* (the `--emacs V,...` control flow is proven
against two distinctly-named binaries, but every environment this harness
has been driven in so far has exactly one real Emacs release installed, so
*different Emacs versions actually disagreeing on something* remains
unexercised — see DESIGN §13.3 open question 1).
