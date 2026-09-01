# Testing your own package with the harness

The core knows nothing about any package (DESIGN.md §8.4). Adding one is
adding a **profile** — a directory of configuration, fixtures and
scenarios — and never editing the core. This is the practical guide to
doing that, including the two things a package that fronts a backend
process needs: an out-of-tree profile directory, and `eh-fake-bridge`.

`profiles/jsonyter/` does not exist in this repository, and deliberately
so — see [Where a profile should live](#where-a-profile-should-live).

---

## The shape of a profile

```
<profile>/
├── profile.el         declarative manifest: snapshot props, named
│                      waiters, log buffers to sweep into failures
├── init.el            the ONLY Emacs config the package under test sees
├── fixtures/          files a scenario opens (copied to scratch first)
├── bridge-scripts/    eh-fake-bridge fixtures, if the package talks to
│                      a backend process
└── scenarios/*.el     the tests, as Emacs Lisp running inside the SUT
```

`ehd` binds four variables before loading `init.el`, and scenarios use
them rather than hardcoding paths:

| Variable | Points at |
| --- | --- |
| `eh-profile-dir` | the profile directory itself |
| `eh-profile-fixtures-dir` | `<profile>/fixtures/` |
| `eh-profile-bridge-scripts-dir` | `<profile>/bridge-scripts/` |
| `eh-profile-scratch-dir` | a writable scratch dir, per session |

`init.el` must `(load (expand-file-name "profile.el" eh-profile-dir))`
itself. Skipping that line is a silent trap: every session still starts
with no error, but the manifest's waiters and snapshot properties simply
never register, and `eh wait <name>` fails with "no such waiter"
forever.

---

## Where a profile should live

Two supported answers, and the second is usually right.

**In this repository, under `profiles/<name>/`.** Baked into the image
by `COPY profiles/`. Right for a profile that belongs to the harness
itself — `profiles/smoke/` is one.

**In the package's own repository, mounted in.** Right for testing a
real package, because scenarios and the code they test then change in
the same commit and the same pull request. A profile that lives here
while its package lives elsewhere cannot do that: every behaviour change
becomes a two-repository dance, and the profile drifts.

Nothing in the harness needs to change to support this. Mount the
package's profile directory over `/srv/profiles/<name>` and the package
itself over `/srv/package`, both read-only:

```bash
docker run --rm --shm-size=1gb \
  -v "$PWD:/srv/package:ro" \
  -v "$PWD/harness/profile:/srv/profiles/mypkg:ro" \
  -v "$PWD/runs:/var/lib/eh/runs" \
  emacs-harness:dev run mypkg
```

The package is mounted **read-only on purpose** (DESIGN §5.3): a
scenario that can edit the code it is testing will eventually do so by
accident, and the run after that is testing something nobody wrote.

---

## Packages that talk to a backend process

Many packages worth testing this way front an external process — a
language server, a REPL, a kernel, a daemon they spawn and talk to over
a pipe. The harness supports two kinds of scenario for them, because
they answer different questions (DESIGN §9).

### The real backend

If it is cheap enough to bake into an image layer, start a real one and
run true end-to-end scenarios. Keep a handful; accept that they are slow.
Gate them with `:needs` so they skip — legibly, not silently — where the
backend isn't installed:

```elisp
(eh-scenario mypkg/real-backend-round-trip
  :needs (:kernel "python3")
  ...)
```

### The fake — `eh-fake-bridge`

`bin/eh-fake-bridge` is a scriptable stand-in that speaks a
line-oriented JSON protocol on stdin/stdout and does exactly what a
`.jsonl` fixture tells it to. A profile points the package's *own*
"how do I launch my backend" option at it, so the package launches its
backend exactly as it always does and never learns the difference:

```elisp
;; in the profile's init.el or a scenario
(setq mypkg-backend-command
      (eh-fake-bridge-command "base.jsonl" "streaming.jsonl"))
```

`eh-fake-bridge-command` resolves any `.jsonl` argument against
`eh-profile-bridge-scripts-dir` and passes everything else through
untouched, so faults read as themselves:

```elisp
(eh-fake-bridge-command "base.jsonl" "--fault" "slow-drip")
```

It exists because a large class of backend-talking behaviour is
impossible or miserable to trigger against a real backend on demand:

| Behaviour to test | Why a real backend can't do it on demand |
| --- | --- |
| An "offline" mode line from a half-open connection | Requires actually breaking the network mid-request |
| A "dead" state from the backend being killed by something else | Racy, and destroys the session you were testing |
| A request that never gets answered | Needs a backend that hangs deliberately |
| A reply truncated mid-JSON, or invalid UTF-8 | Hostile inputs a well-behaved backend won't produce |
| Streaming reconciliation (the backend repeats every streamed chunk in its combined reply) | Needs byte-level control of the reply |
| Backend stderr noise racing the protocol on stdout | Needs a backend that chatters on demand |

Run `bin/eh-fake-bridge --help` for the full script format. The short
version — one JSON object per line (an object may span lines), `#` and
`//` comments, first matching rule wins:

```jsonl
{"on": {"method": "start"}, "reply": {"session_id": "k1"}}

{"on": {"method": "execute", "code": "~^for i in~"},
 "emit": [{"after_ms":   0, "event":  {"type": "status", "state": "busy"}},
          {"after_ms": 100, "output": {"type": "stream", "text": "step 1\n"}},
          {"after_ms": 310, "output": {"type": "display_data",
                                       "data": {"image/png": {"$file": "plot.png"}}}}],
 "reply": {"outputs": "<repeat-all-emitted>", "execution_count": 1}}

{"on": {"method": "history"}, "never_reply": true}
{"on": {"method": "inspect"}, "error": {"message": "Forbidden", "status": 403}}
{"at": "t+2000", "inject": {"event": {"type": "dead"}, "session_id": "k1"}}
```

- `~...~` is a regular expression; anything else must be equal.
- `{"on_input": {...}}` instead of `{"on": {...}}` matches a line the
  *client* sent that is not a request — the answer to an
  `input_request`, correlated by id alone — so the reply side of a
  prompt exchange is assertable too.
- `{"$file": "PATH"}` anywhere in a payload is replaced by the file's
  contents — base64 if it isn't valid UTF-8, so a real PNG fixture goes
  in as a real base64 mimebundle.
- `<repeat-all-emitted>` expands to the payloads that rule actually
  emitted for that request.
- `--id-key` / `--method-key` / `--params-key` adapt the correlation
  keys to a protocol that names them differently.
- Any unrecognised command-line argument is ignored, deliberately: the
  package will append its own flags (a URL, a token, a timeout) for the
  real backend, and ignoring them is what keeps the substitution
  invisible.
- An unmatched request gets a loud `501` error reply by default, so a
  gap in a fixture surfaces as a failure rather than as a silent pass.
  `--unmatched empty|never` changes that where you want it.

**Keep the fake honest.** Build fixtures with record mode rather than
from a protocol spec — fixtures written from a spec are how a suite ends
up passing against a fiction:

```bash
eh-fake-bridge --record fixtures.jsonl -- <the real backend command>
```

It proxies stdin/stdout to the real backend, passing everything through
unchanged, and writes a replayable script of what actually crossed the
wire with binary payloads spilled to `fixtures.jsonl.d/`. Hand-edit
afterwards.

`profiles/smoke/scenarios/fake-bridge.el` is the fake bridge's own
coverage — seven scenarios over a deliberately made-up protocol — and
the shortest complete example of driving it from Emacs.

---

## Running scenarios in batch, without the container

Scenario files are plain Emacs Lisp and run inside the instance under
test, so the same file also runs under `ert-run-tests-batch-and-exit`
(DESIGN §8.1). That is much faster to iterate against, and it works with
a terminal Emacs — but it is **not** a substitute for a container run:
every `:needs (:cairo t)` scenario skips, which is to say everything the
harness exists for. Use it to shorten the edit/run loop on tier-1
assertions, then run the real thing before you believe it.

```bash
emacs -Q --batch -L /path/to/emacs-harness/elisp \
  --eval '(setq eh-run-dir "/tmp/eh" eh-profile-dir "…" eh-profile-fixtures-dir "…" eh-profile-bridge-scripts-dir "…" eh-profile-scratch-dir "/tmp/eh/work" eh-fake-bridge "/path/to/bin/eh-fake-bridge")' \
  -l eh-driver -l eh-scenario -l eh-profile \
  -l <profile>/init.el -l <profile>/scenarios/*.el \
  -f ert-run-tests-batch-and-exit
```

---

## Continuous integration

The pattern for a package repository's own workflow: check out the
package and the harness, build the image once, then run the profile with
the package and its profile directory mounted in.

```yaml
- uses: actions/checkout@v4
- uses: actions/checkout@v4
  with: { repository: you/emacs-harness, path: .harness, ref: main }
- run: docker build -f .harness/container/Dockerfile -t emacs-harness:ci .harness
- run: |
    docker run --rm --shm-size=1gb \
      -v "$PWD:/srv/package:ro" \
      -v "$PWD/harness/profile:/srv/profiles/mypkg:ro" \
      -v "$PWD/runs:/var/lib/eh/runs" \
      emacs-harness:ci run mypkg
- uses: actions/upload-artifact@v4
  if: always()
  with: { name: harness-runs, path: runs/ }
```

Pin the harness `ref` to a tag or commit rather than tracking `main`, so
a harness change can never turn a package's CI red on its own.

Two things worth doing on top:

- **`--shm-size=1gb` is not optional.** X servers use shared memory; the
  Docker default of 64MB is enough to make Xvfb fall over intermittently,
  which reads as a flaky test suite.
- **Upload `runs/` on failure.** Every scenario failure writes
  screenshots, buffer snapshots, `*Messages*` and a backtrace to
  `runs/<id>/<scenario>/`. Without the upload step, a CI failure is a
  one-line assertion message; with it, it is the frame the failure
  happened in.
