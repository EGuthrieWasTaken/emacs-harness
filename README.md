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

**Phases 0-2 implemented, phase 3 mostly implemented** (see DESIGN.md §14).
Phase 0-1: the container image, the `ehd` dispatcher, the `eh` client, the
Elisp driver (`eh-driver.el`), the scenario DSL (`eh-scenario.el`), and the
`smoke` profile that proves the core is package-agnostic. Phase 2: `eh
click`/`eh drag`/`eh scroll`/`eh keys --x`, `eh video` (including `--gif`),
and pixel baselines via `eh diff-shot`/`eh baseline accept` with
`.mask.json` sidecar support, all wired end-to-end including the
scenario-level `eh-expect-no-visual-drift`. Phase 3: the `--emacs V,...`
matrix flag on `eh run` and a GitHub Actions workflow
(`.github/workflows/ci.yml`) that builds the image and runs `eh doctor` +
`eh run smoke` headlessly. Not yet built: any profile beyond `smoke` itself
(so the matrix flag's second acceptance test, "`eh run <profile> --emacs
27.2,29.4` for a real profile", can't be run end-to-end until one exists),
pinned multi-version Emacs *images* (the matrix flag works against whatever
binaries you point it at, but this repo doesn't build or ship `27.2`/`29.4`
binaries — see DESIGN §13.3 open question 1), and the MCP server (Phase 4).

Diff-shot's pixel comparison (ImageMagick `compare`/`identify`, plus mask
rectangles applied via `convert -draw`) is implemented once, in Elisp
(`eh-diff-shot` in `eh-driver.el`), and called both by the CLI (`eh
diff-shot`/`eh baseline accept`, via a thin `emacs_eval` wrapper in
`ehd.py`) and by scenarios (`eh-expect-no-visual-drift`) — not
reimplemented per caller, since a scenario running inside Emacs has no
channel back out to `ehd` mid-test (see DESIGN §8.1).

The container image itself (`container/Dockerfile`) has **not** been
build-tested in this environment: this sandbox's egress policy blocks
Docker Hub's CDN (`production.cloudfront.docker.com`), so `docker build`
fails on the base `FROM debian:bookworm-slim` layer before reaching any of
this repo's own steps. The GitHub Actions workflow above will be the first
place this actually builds and runs headlessly, once it's on GitHub's own
runners. Build and run `eh doctor` (§12) as the first acceptance check in
any environment with normal Docker Hub access.

### What's been validated

- All Python (`bin/eh`, `ehd/ehd.py`, `ehd/ehd_cli.py`) compiles cleanly and
  passes `pyflakes` (one pre-existing unused import, `socket` in `ehd.py`,
  predates this pass and is unrelated to it).
- All Elisp (`elisp/*.el`) byte-compiles cleanly (only benign warnings for
  GUI-only primitives and variables defined via `require` at runtime).
- The full `eh-run-scenarios-json` pipeline was run against `profiles/smoke/`
  under `emacs -Q --batch` (no GUI available in this sandbox): fixture
  loading, `eh-scenario`'s skip logic (`:needs`), `eh-expect-face`,
  `with-silent-modifications` interaction with `buffer-modified-p`, artifact
  capture, and JSON summary generation all behave correctly.
- `eh-diff-shot`/`eh-baseline-accept` (and their JSON wrappers) were
  exercised directly under `emacs -Q --batch` with `eh-shot-to-file` mocked
  out (frame export needs a real cairo GUI frame, unavailable here) and a
  real ImageMagick `compare`/`convert`/`identify`: missing-baseline
  reporting, identical-image pass, beyond-tolerance failure with correct
  changed/total pixel counts, both explicit `:mask` and a `NAME.mask.json`
  sidecar excluding a changed region from the diff, and `baseline accept
  --all` all behave correctly.
- `_translate_key` (the `eh keys --x` Emacs-key-description → xdotool
  translator in `ehd.py`) had a real bug: it translated only a single key
  chord, so the design's own primary example, `eh keys "C-c C-e"` — one
  string containing *two* chords — produced garbage xdotool syntax instead
  of `ctrl+c ctrl+e`. Fixed to split on whitespace and translate each chord
  separately; re-verified against the design's own worked examples
  (`C-c C-e`, `<C-return>`, `S-RET`).
- `eh scroll --pixels` called `pixel-scroll-precision-scroll-up`
  unconditionally, which is Emacs 29+ only (confirmed: even Emacs 29.3 in
  batch mode reports it as not `fboundp` until `pixel-scroll` is loaded) and
  would `void-function` on the 27.1+ matrix this harness targets. Replaced
  with `eh-scroll-pixels`, which falls back to `set-window-vscroll` (24+)
  when the precision-scroll functions aren't available.
- The `--emacs V,...` matrix control flow in `ehd.py` (`handle_run` /
  `_run_one_version`) was exercised with a mocked `SessionManager`: a single
  version still returns the old flat (non-`matrix`) response shape; a
  matrix with one version whose Emacs binary doesn't exist still runs and
  reports the other versions rather than aborting the whole matrix; a
  scenario failure (not a session-creation failure) still cleans up its
  session; and `mgr.rm` failures during cleanup no longer escape the
  `finally` block and clobber a good result (a latent bug in the original
  single-version code path, fixed as part of this change since both paths
  now share the same function).
- What's *not* validated here: anything requiring a real X display, cairo,
  `x-export-frames`, `xdotool`, `ffmpeg` video/gif capture, or the `ehd`
  session-manager's subprocess orchestration (Xvfb/openbox/emacs
  lifecycle) — none of that runs without the container.

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
