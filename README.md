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

**Design only. No code yet.** The complete, implementable specification is in
[`DESIGN.md`](DESIGN.md); the concrete first test suite is in
[`docs/scenarios-jsonyter.md`](docs/scenarios-jsonyter.md). Hand `DESIGN.md` to
an implementing agent and start at §14 (Milestones).

The repository name and the `eh` command name are placeholders — rename freely
before the first commit of real code, but rename consistently.

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

## Layout once implemented

```
emacs-harness/
├── DESIGN.md                  ← the spec
├── docs/scenarios-jsonyter.md ← the first suite
├── bin/eh                     ← thin client (runs on your laptop)
├── container/                 ← Dockerfile, supervisord, entrypoint
├── ehd/                       ← in-container dispatcher
├── elisp/                     ← eh-driver.el, eh-scenario.el, eh-report.el
├── profiles/
│   ├── jsonyter/              ← deps, init, fixtures, scenarios, baselines
│   └── smoke/                 ← trivial profile that proves the core is generic
└── runs/                      ← per-run artifacts (gitignored)
```
