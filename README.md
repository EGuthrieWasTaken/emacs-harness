# emacs-harness

A GUI Emacs test harness that an AI coding agent can drive: a real, graphical
Emacs running on a headless X display inside a container, with a command-line
control surface for evaluating Lisp, sending real keystrokes and mouse clicks,
taking screenshots, and asserting on what Emacs actually drew — plus a browser
view of the same live instance for point-and-click work and human eyeballs.

Built first for [jsonyter.el](https://github.com/EGuthrieWasTaken/jsonyter.el),
whose interesting behaviour — sliced inline images, output overlays, read-only
result regions, streaming redraws, mode-line kernel state — is invisible to
`emacs --batch`. Nothing in the core knows about jsonyter: packages are
described by **profiles**, and jsonyter is simply the first one.

## Status

**Phases 0-1 implemented** (see DESIGN.md §14): the container image, the `ehd`
dispatcher, the `eh` client, the Elisp driver (`eh-driver.el`), the scenario
DSL (`eh-scenario.el`), and the `smoke` profile that proves the core is
package-agnostic. Phase 2 (`eh click`/`eh drag`/`eh video`, pixel baselines
via `eh diff-shot`), the `jsonyter` profile itself, and the MCP server
(Phase 4) are not yet built — `profiles/jsonyter/` is a placeholder pending
the actual package repo.

The `eh-driver.el`/`eh-scenario.el` runtime logic (the file-based eval
protocol, `eh-snapshot`, the `eh-scenario` macro, and the ERT batch-result
pipeline `eh-run-scenarios-json`) has been validated end-to-end against a
real Emacs (batch-mode, non-GUI, so cairo/image-dependent scenarios
correctly skip) — see "What's been validated" below. The container image
itself (`container/Dockerfile`) has **not** been build-tested in this
environment: this sandbox's egress policy blocks Docker Hub's CDN
(`production.cloudfront.docker.com`), so `docker build` fails on the base
`FROM debian:bookworm-slim` layer before reaching any of this repo's own
steps. Build and run `eh doctor` (§12) as the first acceptance check in an
environment with normal Docker Hub access.

### What's been validated

- All Python (`bin/eh`, `ehd/ehd.py`, `ehd/ehd_cli.py`) compiles cleanly.
- All Elisp (`elisp/*.el`) byte-compiles cleanly (only benign warnings for
  GUI-only primitives and variables defined via `require` at runtime).
- The full `eh-run-scenarios-json` pipeline was run against `profiles/smoke/`
  under `emacs -Q --batch` (no GUI available in this sandbox): fixture
  loading, `eh-scenario`'s skip logic (`:needs`), `eh-expect-face`,
  `with-silent-modifications` interaction with `buffer-modified-p`, artifact
  capture, and JSON summary generation all behave correctly. This caught and
  fixed two real bugs along the way: (1) the scenario macro's original
  catch-and-resignal error handling corrupted ERT's own pass/fail bookkeeping
  — fixed by detecting an abnormal exit via a completion flag instead of
  intercepting the signal; (2) `ert-test-skipped` and `ert-test-failed` are
  sibling structs, not one derived from the other, so only their shared base
  accessor works on both.
- What's *not* validated here: anything requiring a real X display, cairo,
  `x-export-frames`, `xdotool`, or the `ehd` session-manager's subprocess
  orchestration (Xvfb/openbox/emacs lifecycle) — none of that runs without
  the container.

The repository name and the `eh` command name are placeholders — rename
freely, but rename consistently.

## The one-paragraph version

A container runs `Xvfb`, a pinned cairo-enabled GNU Emacs, a Jupyter server
with real kernels, and a scriptable fake `jsonyter` bridge. A small in-container
dispatcher (`ehd`) exposes that Emacs over a Unix socket; a thin client (`eh`)
reaches it over SSH from wherever the agent is running. The agent's default
move is **not** to look at pixels: it asks Emacs for a structured dump of buffer
text, overlays, text properties, faces and image descriptors, and asserts on
that. Screenshots (`x-export-frames`, taken from inside Emacs — no window
manager races) are the backstop for the handful of things only redisplay knows.
Scenarios are ERT tests written in Emacs Lisp that run *inside* the instance
under test, so the same file works both under the agent's hand and in CI.

## Layout

```
emacs-harness/
├── DESIGN.md                  ← the spec
├── AGENTS.md / CLAUDE.md      ← the agent operating contract (DESIGN §11)
├── docs/scenarios-jsonyter.md ← the first suite (not yet implemented)
├── bin/eh                     ← thin client (runs on your laptop)
├── container/                 ← Dockerfile, supervisord, entrypoint
├── compose.yaml                ← local-dev wrapper around the one image
├── ehd/                       ← in-container dispatcher (ehd.py) + bridge (ehd_cli.py)
├── elisp/                     ← eh-driver.el, eh-scenario.el, eh-profile.el, eh-init-core.el
├── profiles/
│   ├── jsonyter/               ← placeholder; needs the jsonyter.el repo
│   └── smoke/                 ← trivial profile that proves the core is generic
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
