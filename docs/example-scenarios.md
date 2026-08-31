# Example scenario catalogue

Companion to [`../DESIGN.md`](../DESIGN.md). This is a fully worked *example*
of the kind of scenario list an implementer writes when building a real
profile: what to test, why a GUI is required to test it, and which tier of
assertion (DESIGN §4) each scenario uses.

**Nothing here names a real package.** Every scenario below is for a
fictional `demo` package — the same one used for the worked examples in
DESIGN.md §6.2, §8.2 and §8.4 — chosen because its imagined behaviour (inline
images, framed read-only output, overlay-based structural editing, streaming
updates, mode-line state, embedded blocks inside another major mode, a
REPL) happens to cover the categories of visual/interactive behaviour that
motivate this harness (DESIGN §1). A real profile's catalogue will look
structurally like this one, but every ID, face, key binding and fixture in
it will be that package's own.

## Scope: what belongs here, and what does not

**Stays in the package's existing batch ERT suite.** Pure data
transformations — file save round-trips and byte-identity, session-table
bookkeeping, event routing by id, mode-line *string* construction (as
opposed to mode-line *display*), undo-entry classification, and similar —
are pure data transformations; batch is faster, and duplicating them here
buys nothing. `eh run <profile> --batch` runs them, so one command still
covers everything.

**Belongs here.** Anything where the answer is produced by redisplay, by the
keymap, by the command loop, or by the passage of real time.

---

## 1. Images and slicing

The highest-value group: batch ERT can assert that a `display` property holds
an image descriptor, but not that the image decoded, that it is the right
size, or that slicing produced separately addressable lines.

| ID | What it proves | Bridge | Tier |
| --- | --- | --- | --- |
| `img/rendered-region-rasterises` | A real image arrives from the backend and **renders** — not a broken-image placeholder. Assert non-uniform pixel content in the cropped region, plus `(image-size … t)` matching the descriptor. | real | 3 + 1 |
| `img/slices-are-addressable` | A tall image is inserted sliced, one slice per line. Assert *N* consecutive positions each carry an `image` display with a distinct `:slice`, and that `goto-char` + `vertical-motion` stops inside it — the actual point of slicing. | fake (fixed PNG) | 1 |
| `img/scrolls-a-line-at-a-time` | With a tall image on screen, `C-n`/`scroll-up-line` advances `window-start` by one line, not past the whole image. Assert the `window-start` sequence numerically. | fake | 1 |
| `img/inline-elsewhere-is-whole` | In a context where the package documents that images are *not* sliced (e.g. inline in prose), assert one slice-less image and a `window-vscroll` change with `PIXELS-P`. | fake | 1 |
| `img/slice-opt-out` | A user option that disables slicing actually results in one image everywhere. | fake | 1 |
| `img/max-width-and-height` | Size-limiting options actually resize. Assert computed pixel size, and pixel-verify aspect ratio is preserved. | fake | 1 + 3 |
| `img/multiple-formats` | Every image format the package claims to support renders where Emacs supports it; skip cleanly where it does not (`image-type-available-p`). | fake | 1 |

**Determinism note.** These are the scenarios that break if
`image-scaling-factor` is left on `auto` or the font is not pinned (DESIGN §7.2).
Every image scenario should assert the frame's font first, as a guard.

## 2. Output framing, faces and staleness

| ID | What it proves | Bridge | Tier |
| --- | --- | --- | --- |
| `frame/output-is-framed` | A run region's output gets a labelled rule above and below; a region with no output gets none. Assert `demo-output-border-face` at both boundaries. | fake | 1 |
| `frame/stale-on-edit` | Typing in a region's source **via real keystrokes** flips its frame to `demo-output-border-stale-face` and the label to "output (stale)". Uses `eh-type`, not `insert`, because the invalidation hangs off a per-edit source hash. | fake | 1 |
| `frame/stale-cleared-by-rerun` | Re-running clears the stale marking. | fake | 1 |
| `frame/stale-cleared-by-undo` | Undoing back to the source that produced the output also clears it — the interesting half, and one that needs a real command-loop `undo`. | fake | 1 |
| `frame/rule-width` | The rule is drawn to the package's configured separator width, pixel-verified once as a baseline. | fake | 3 |
| `frame/highlighting-leaves-output-alone` | Highlighted output text is not re-coloured as source after `font-lock-ensure` and a full redisplay. Assert resolved faces across the output region. | fake | 1 |
| `frame/themes` | Render the same populated buffer under a light and a dark theme; two baselines. Catches hardcoded colours across the package. | fake | 3 |

## 3. Read-only output, editable source

| ID | What it proves | Bridge | Tier |
| --- | --- | --- | --- |
| `ro/typing-into-output-fails` | Point inside output + `eh-type "x"` signals, and the buffer text is unchanged. The property is the mechanism; **the failed keystroke is the behaviour**. | fake | 1 + 2 |
| `ro/source-stays-editable-beside-output` | Typing at the last source position, immediately before the output, inserts into the source. Boundary case; batch covers the property, this covers the keystroke. | fake | 1 + 2 |
| `ro/copy-still-works` | Selecting output and `kill-ring-save` yields the text — read-only must not mean unselectable. | fake | 1 + 2 |
| `ro/output-not-undoable` | Run a region, then `undo`: the undo walks the user's earlier edit, never the output. Real `undo` through the command loop, which is where `pending-undo-list` behaviour actually lives. | fake | 1 + 2 |
| `ro/buffer-not-modified-by-a-run` | Running a region leaves `buffer-modified-p` nil. | fake | 1 |

## 4. Structural editing of overlay-bounded regions

Any package that tracks regions with overlays (cells, blocks, folds, …) has
a class of bug that only shows up as **overlay-boundary corruption**:
inserting or moving one region silently damages a neighbour's boundary,
because a boundary marker landed on the wrong side of an insertion. Batch
ERT can assert the property in isolation; it is much less likely to catch
the boundary math actually going wrong under a real edit.

| ID | What it proves | Bridge | Tier |
| --- | --- | --- | --- |
| `region/insert-below-leaves-neighbours-intact` | After inserting a new region between two others, assert every other region's source text is byte-identical to before, and that each region's own boundary marker still sits at that region's real source end. | none | 1 |
| `region/insert-above-leaves-neighbours-intact` | Same, inserting above instead of below. | none | 1 |
| `region/insert-clears-output` | Inserting clears the affected region's output (batch covers this; keep the GUI version because overlay geometry is the suspect). | fake | 1 |
| `region/delete-takes-its-output` | Deleting removes source and output together — and, if the package prompts for non-blank regions, this is the scenario that exercises the **prompt guard** (`eh-answers`). | fake | 1 + 2 |
| `region/move-carries-output` | Moving a region carries its output with it, boundaries following. Assert overlay order and source text after the move. | fake | 1 |
| `region/boundaries-back-to-back` | Regions that sit with no blank line between them still render two distinct boundaries. Pixel baseline — this is a redisplay question. | none | 1 + 3 |
| `region/public-names-are-bound` | Every command in the package's own documented key table is bound to the key the documentation claims, in a real buffer: assert `(key-binding (kbd "C-c C-i"))` etc. Cheap, and catches documentation drift. | none | 1 |

## 5. Scrolling and point discipline

Many packages that write output in place make a specific promise along the
lines of *"insertion never steals point: a window scrolls with new output
only if it was already at the end."* That is a pure redisplay property and
is untestable in batch.

| ID | What it proves | Bridge | Tier |
| --- | --- | --- | --- |
| `scroll/output-does-not-steal-point` | Point parked mid-buffer, a long streaming region runs; `point` and `window-start` are unchanged throughout. Sample repeatedly during the stream, not just at the end. | fake (slow drip) | 1 |
| `scroll/window-at-end-follows` | Same run with the window already at `point-max`: it follows the new output. | fake | 1 |
| `scroll/reading-back-while-running` | Scroll up mid-stream; the window stays where the user put it. | fake | 1 |

## 6. Streaming and interrupt

| ID | What it proves | Bridge | Tier |
| --- | --- | --- | --- |
| `stream/live-not-one-dump` | Output appears incrementally: assert the buffer grows across ≥3 samples during a single run, rather than once at the end. | fake (slow drip) | 1 |
| `stream/clears-in-place` | A progress-style output redraws in place rather than accumulating frames. Assert line count stays constant while text changes; capture a short video for the human. | fake | 1 + 3 |
| `stream/reconciled-by-count` | If the backend repeats every streamed chunk in its final combined reply, the package must render only the tail past what it already drew. Assert no duplication. This one is *only* reachable with byte control of the reply. | fake | 1 |
| `stream/interrupt-mid-run` | An interrupt key during a long run is delivered on the same channel; the buffer shows the interruption and returns to idle. | real | 1 + 2 |
| `stream/error-output-face` | Error/stderr-style output renders in its own face, with any escape sequences rendered, not literal. | fake | 1 |

## 7. Mode line and external state

Assert on `(format-mode-line mode-line-format)` — tier 1, exact — and never on
pixels. The point of these is that the *state machine* is reachable, which is
what the fake bridge is for.

| ID | State | Bridge |
| --- | --- | --- |
| `state/idle-and-run` | idle → running → idle across one run | real |
| `state/starting` | starting, while the backend comes up | real |
| `state/busy-for-another-client` | busy on behalf of another client | fake |
| `state/offline` | offline after a half-open connection; a reconnect command recovers | fake |
| `state/dead` | dead after the backend is killed out from under the buffer; the next request reports dead instead of hanging | fake |
| `state/many-sessions` | A buffer with two live sessions summarises both in the mode line, and a `dead` event for one does not disturb the other | fake |

## 8. Regions embedded inside another major mode

If a package works inside *someone else's* major mode (a special block type,
a fenced region, …), its keymap and faces must coexist with that mode's own.

| ID | What it proves | Bridge | Tier |
| --- | --- | --- | --- |
| `embed/overlay-output-touches-no-text` | Running an embedded region leaves buffer text byte-identical; output lives in an overlay. | fake | 1 |
| `embed/conditional-keys-fall-through` | ⭐ A key that the package rebinds only *inside* its own regions must fall through to the host mode's own binding everywhere else. **Only reachable through the keymap** — call the function directly and you prove nothing. Assert with `eh keys` at three positions: inside a region, outside one, and in prose. | none | 1 + 2 |
| `embed/commit-writes-stamped-result` | Committing a result writes it back into the buffer in the host mode's own syntax, hashed/stamped so staleness can be detected on reopen. | fake | 1 |
| `embed/committed-image-renders` | A committed image file renders as an inline image once the host mode's own image-display feature runs. The rendering half is GUI-only. | fake | 1 + 3 |
| `embed/stale-before-any-backend` | Reopening a file whose embedded region was edited since its last committed result shows it framed stale *before any backend starts*. Needs no bridge at all — a fast, high-value scenario. | none | 1 |
| `embed/folding-hides-overlay-output` | Folding the surrounding structure hides overlay output. Batch asserts the invisibility property; the GUI version asserts it is not on screen (`pos-visible-in-window-p`) and pixel-verifies once. | fake | 1 + 3 |

## 9. REPL-style interaction

| ID | What it proves | Bridge | Tier |
| --- | --- | --- | --- |
| `repl/return-vs-newline` | Submit-key sends complete input, a literal-newline key inserts a newline, a force-send key always sends. Real keys; a completeness check decides. | real | 2 |
| `repl/is-complete-multiline` | A multi-line construct is held as incomplete until finished, then submitted. | real | 2 |
| `repl/is-complete-backend-quirk` | A backend with an unusual completeness signal still submits correctly, because the package handles that quirk. | fake (named script) | 2 |
| `repl/is-complete-gives-up` | Enough consecutive completeness-check failures make the submit key always send thereafter. | fake | 2 |
| `repl/history-walk` | History-previous/-next walk input history. **Depends on `last-command`**, so it is only meaningful through the command loop — a direct `funcall` passes while the feature is broken. | fake | 2 |
| `repl/completion-at-point` | A completion key produces a completion UI with backend-supplied candidates; assert the completions window appears and its contents. Window layout is GUI-only. | real | 1 + 2 |
| `repl/request-timeout-does-not-wedge` | A backend that never answers one request must not block later ones: a configured timeout bounds it. Assert a subsequent request completes. | fake (`never_reply`) | 1 |

## 10. Cross-version and packaging

| ID | What it proves |
| --- | --- |
| `pkg/loads-clean-on-every-version` | `(require '<package>)` on every Emacs version the package claims to support, with `-Q`, no warnings, no errors, `display-graphic-p` true. |
| `pkg/no-obsolete-warnings` | Any obsolete aliases the package still ships still resolve and still warn. |
| `pkg/reference-frame` | One full-frame baseline per Emacs version of the package's main populated view. The cheapest possible "did a version bump change how this looks" check. |

---

## Suggested implementation order

The first three are the ones that prove the harness is worth building, for
any real package:

1. **A structural-editing scenario from §4**, ideally one that reproduces a
   real bug you already suspect — write it red against the current code,
   fix the bug, watch it go green. Needs no backend and no bridge, so it is
   also the simplest possible end-to-end exercise of the harness.
2. **A slicing/scrolling scenario from §1**, if the package inserts tall
   images — completely untestable in batch, and usually the flagship visual
   claim of a package like this.
3. **A conditional-key scenario from §8**, if the package embeds inside
   another major mode — the newest, least-covered code path, and one that
   *only* a real keymap lookup can test.

Then §7 (mode-line states, which forces the fake bridge into existence, if
the package has one), then §5 (scrolling), then the rest.

---

## Fixtures needed

Reuse the package's existing batch suite's fixture text verbatim where
possible — well-maintained fixtures already have fixed ids, which the
harness needs for determinism (DESIGN §7.4).

```
fixtures/
  three-regions.demo        two source regions + one prose region, fixed
                             ids, no outputs
  with-outputs.demo         the same, with stored stream + image outputs
  tall-image.png            a fixed PNG, for slice-count assertions
  wide-image.png            for max-width scaling
  error-output.txt          a real backend error, with escape sequences
  embedded-blocks.host-mode a host-mode file with the package's own
                             embedded regions, plus a non-embedded region
                             and prose, for the conditional-key scenario
  committed.host-mode       a committed result whose region has since
                             been edited
bridge-scripts/
  streaming.jsonl           slow-drip stdout, for scroll and streaming tests
  progress.jsonl            clear-in-place redraws
  quirky-backend.jsonl      a named behaviour bundle for a real backend's
                             known protocol quirks
  offline.jsonl             half-open connection → offline state
  dead.jsonl                backend killed out from under the buffer
  external.jsonl            busy on behalf of another client
  hostile.jsonl             truncated JSON, stderr noise, invalid UTF-8
```
