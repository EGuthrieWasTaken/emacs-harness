# Driving the harness

This file is the operating discipline for an agent using `eh` against a
running `emacs-harness` container. See [`DESIGN.md`](DESIGN.md) for the
full specification; this is the abridged, load-bearing subset.

1. **`eh doctor` first**, whenever you are not sure what state a session
   is in, and always right after a fresh image build.
2. **Assert on snapshots, not screenshots.** `eh snapshot --buffer X`
   answers almost every question about text, faces, overlays,
   properties, geometry and the mode line — exactly, cheaply, and in a
   form you can diff. Take a screenshot (`eh shot`) only to answer "did
   this actually rasterise / lay out", or to show a human.
3. **Never assert without waiting.** Every action that touches a kernel,
   a subprocess, or redisplay is asynchronous. Use `eh wait <predicate>`
   or a named waiter, always. A test that passes because a fixed sleep
   happened to be long enough is a test that will fail in CI.
4. **Crop and scale screenshots.** Prefer `eh shot --region '(...)'`
   or a cropped capture over a full-frame PNG when you only need to see
   one region — it costs far fewer tokens.
5. **Drive with keys, not function calls.** `eh keys "C-c C-e"` exercises
   the keymap, the command loop, and `last-command`;
   `eh eval '(some-package-run-cell)'` exercises none of them and will
   pass while the binding itself is broken.
6. **On failure, read the run directory.** Every `eh run` writes
   `runs/<id>/<scenario>/` with screenshots, snapshots, `*Messages*`,
   and a backtrace. Quote the path in your report; don't re-derive it.
7. **Freeze what you learn.** If you investigated a bug interactively
   with `eh eval` / `eh keys` / `eh shot`, add a scenario under
   `profiles/<name>/scenarios/` before you close it out. Exploration is
   disposable; scenarios accumulate.
8. **Do not edit `/srv/package`.** It is the package under test, mounted
   read-only on purpose. Fix code on the host, then `eh session reset`.
9. **A scenario run gets a fresh session by default.** State leaking
   between scenarios is the single most common source of "passes alone,
   fails in the suite." Pass `--reuse-session` only when you have a
   specific reason to keep state around (e.g. iterating on one scenario).

## Quick reference

```
eh doctor
eh session new --name s1 --profile smoke [--geometry WxH] [--theme T]
eh eval FORM
eh snapshot [--buffer B] [--window] [--props P,...]
eh describe
eh keys "C-c C-e" ["more keys..."] [--x]
eh type TEXT
eh click --at-point | --at FORM | --at-text STR | --xy X,Y
eh wait NAME-OR-FORM [--timeout S]
eh settle
eh shot [--out PATH] [--display]
eh run PROFILE [--scenario NAME...] [--tag TAG] [--reuse-session]
```

Exit codes: `0` success · `1` assertion/scenario failure · `2` usage
error · `3` timeout · `4` Emacs signalled an error · `5` session
unreachable/dead. Branch on these; don't parse prose.
