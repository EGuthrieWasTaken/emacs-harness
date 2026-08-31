# The jsonyter profile — first scenario catalogue

Companion to [`../DESIGN.md`](../DESIGN.md). This is the concrete work list for
the `profiles/jsonyter/` profile: what to test, why a GUI is required to test
it, which bridge it runs against, and which tier of assertion it uses.

Everything here is grounded in jsonyter.el 2.0.0 as it stands — the symbols,
faces, keys and behaviours named below were read out of the source, not
invented. Where a name could not be confirmed it is flagged.

## Scope: what belongs here, and what does not

**Stays in `test/jsonyter-tests.el` (batch ERT, 49 tests).** Notebook save
round-trips and byte-identity, session-table bookkeeping, event routing by
kernel id, mode-line *string* construction, undo-entry classification, org
commit/stamp mechanics. These are pure data transformations; batch is faster,
and duplicating them here buys nothing. `eh run jsonyter --batch` runs them, so
one command still covers everything.

**Belongs here.** Anything where the answer is produced by redisplay, by the
keymap, by the command loop, or by the passage of real time.

---

## 1. Images and slicing

The highest-value group: batch ERT can assert that a `display` property holds
an image descriptor, but not that the PNG decoded, that it is the right size,
or that slicing produced separately addressable lines.

| ID | What it proves | Bridge | Tier |
| --- | --- | --- | --- |
| `img/notebook-plot-rasterises` | A real `matplotlib` figure arrives over the websocket and **renders** — not a broken-image placeholder. Assert non-uniform pixel content in the cropped region, plus `(image-size … t)` matching the descriptor. | real | 3 + 1 |
| `img/notebook-slices-are-addressable` | A tall image is inserted sliced, one slice per line. Assert *N* consecutive positions each carry an `image` display with a distinct `:slice`, and that `goto-char` + `vertical-motion` stops inside it — the actual point of slicing. | fake (fixed PNG) | 1 |
| `img/notebook-scrolls-a-line-at-a-time` | With a tall plot on screen, `C-n`/`scroll-up-line` advances `window-start` by one line, not past the whole image. Assert the `window-start` sequence numerically. | fake | 1 |
| `img/script-image-is-whole` | In a `# %%` script buffer the same image is *not* sliced (overlay strings are one buffer position) and scrolls by pixel. Assert one slice-less image and a `window-vscroll` change with `PIXELS-P`. | fake | 1 |
| `img/slice-opt-out` | `jsonyter-slice-images` nil ⇒ one image everywhere, notebook included. | fake | 1 |
| `img/max-width-and-height` | `jsonyter-image-max-width` / `-max-height` actually resize. Assert computed pixel size, and pixel-verify aspect ratio is preserved. | fake | 1 + 3 |
| `img/svg-and-jpeg` | `image/svg+xml` and `image/jpeg` mimebundles render where Emacs supports them; skip cleanly where it does not (`image-type-available-p`). | fake | 1 |
| `img/repl-image-is-sliced` | Same slicing in a REPL buffer. | fake | 1 |

**Determinism note.** These are the scenarios that break if
`image-scaling-factor` is left on `auto` or the font is not pinned (DESIGN §7.2).
Every image scenario should assert the frame's font first, as a guard.

## 2. Output framing, faces and staleness

| ID | What it proves | Bridge | Tier |
| --- | --- | --- | --- |
| `frame/output-is-framed` | A run cell's output gets a labelled rule above and below; a cell with no output gets none. Assert `jsonyter-output-border-face` at both boundaries. | fake | 1 |
| `frame/stale-on-edit` | Typing in a cell's source **via real keystrokes** flips its frame to `jsonyter-output-border-stale-face` and the label to `output (stale)`. Uses `eh-type`, not `insert`, because the invalidation hangs off the per-edit source hash. | fake | 1 |
| `frame/stale-cleared-by-rerun` | Re-running clears the stale marking. | fake | 1 |
| `frame/stale-cleared-by-undo` | Undoing back to the source that produced the output also clears it — the interesting half, and one that needs a real command-loop `undo`. | fake | 1 |
| `frame/rule-width` | The rule is drawn to `jsonyter-notebook-separator-width`, pixel-verified once as a baseline. | fake | 3 |
| `frame/font-lock-leaves-output-alone` | A Python traceback in output is not recoloured as code after `font-lock-ensure` and a full redisplay. Assert resolved faces across the traceback region. | fake | 1 |
| `frame/cell-type-labels` | `code`/`Markdown`/`Raw` boundary labels carry `jsonyter-code-cell-face`, `jsonyter-markdown-cell-face`, `jsonyter-raw-cell-face`. | none | 1 |
| `frame/themes` | Render the same three-cell notebook under a light and a dark theme; two baselines. Catches hardcoded colours across the package. | fake | 3 |

## 3. Read-only output, editable source

| ID | What it proves | Bridge | Tier |
| --- | --- | --- | --- |
| `ro/typing-into-output-fails` | Point inside output + `eh-type "x"` signals, and the buffer text is unchanged. The property is the mechanism; **the failed keystroke is the behaviour**. | fake | 1 + 2 |
| `ro/source-stays-editable-beside-output` | Typing at the last source position, immediately before the output, inserts into the source. Boundary case; batch covers the property, this covers the keystroke. | fake | 1 + 2 |
| `ro/copy-still-works` | Selecting output and `kill-ring-save` yields the text — read-only must not mean unselectable. | fake | 1 + 2 |
| `ro/output-not-undoable` | Run a cell, then `undo`: the undo walks the user's earlier edit, never the output. Real `undo` through the command loop, which is where `pending-undo-list` behaviour actually lives. | fake | 1 + 2 |
| `ro/buffer-not-modified-by-a-run` | Running a cell leaves `buffer-modified-p` nil. | fake | 1 |

## 4. Cell surgery — including the known bug

`jsonyter-insert-cell-below` / `-above` place a new cell at `(overlay-end cell)`
/ `(overlay-start cell)`. A cell-overlay boundary bug — **inserting a cell
corrupts a neighbouring cell's source** — is known and queued for fixing. This
group is where it gets pinned down, and the first of these should be written
*before* the fix, so it fails, and then passes.

| ID | What it proves | Bridge | Tier |
| --- | --- | --- | --- |
| `cell/insert-below-leaves-neighbours-intact` | ⚠️ **The known bug.** After `C-c C-i` between two cells, assert every other cell's source text is byte-identical to before, and that each cell overlay's `jsonyter-source-end` marker still sits at that cell's real source end. | none | 1 |
| `cell/insert-above-leaves-neighbours-intact` | Same for `C-c C-a`. | none | 1 |
| `cell/insert-clears-output` | Inserting clears the affected cell's output (batch covers this; keep the GUI version because the overlay geometry is the suspect). | fake | 1 |
| `cell/delete-takes-its-output` | `C-c C-w` removes source and output together — and prompts with `yes-or-no-p` when the cell is non-blank, so this is the scenario that exercises the **prompt guard** (`eh-answers`). | fake | 1 + 2 |
| `cell/move-carries-output` | `C-c <up>` / `C-c <down>` moves a cell with its output, boundaries following. Assert overlay order and source text after the move. | fake | 1 |
| `cell/toggle-type-clears-output` | `C-c C-t` code ⇄ markdown, output cleared, boundary label and face updated. | fake | 1 |
| `cell/boundaries-back-to-back` | Cells that sit with no blank line between them still render two distinct boundaries. Pixel baseline — this is a redisplay question. | none | 1 + 3 |
| `cell/public-names-are-bound` | Every command in the README's public table is bound to the key the README claims, in a real notebook buffer: assert `(key-binding (kbd "C-c C-i"))` etc. Cheap, and catches documentation drift. | none | 1 |

## 5. Scrolling and point discipline

The README makes a specific promise: *"Insertion never steals point: a window
scrolls with new output only if it was already at the end."* That is a pure
redisplay property and is untestable in batch.

| ID | What it proves | Bridge | Tier |
| --- | --- | --- | --- |
| `scroll/output-does-not-steal-point` | Point parked mid-buffer, a long streaming cell runs; `point` and `window-start` are unchanged throughout. Sample repeatedly during the stream, not just at the end. | fake (slow drip) | 1 |
| `scroll/window-at-end-follows` | Same run with the window already at `point-max`: it follows the new output. | fake | 1 |
| `scroll/reading-back-while-running` | Scroll up mid-stream; the window stays where the user put it. | fake | 1 |

## 6. Streaming, `clear_output`, interrupt

| ID | What it proves | Bridge | Tier |
| --- | --- | --- | --- |
| `stream/live-not-one-dump` | Output appears incrementally: assert the buffer grows across ≥3 samples during a single execute, rather than once at the end. | fake (slow drip) | 1 |
| `stream/clear-output-wait` | A progress bar redraws in place rather than accumulating frames. Assert line count stays constant while text changes; capture a short video for the human. | fake | 1 + 3 |
| `stream/reconciled-by-count` | The bridge repeats every streamed output in the final `outputs` list; jsonyter must render only the tail past what it drew. Assert no duplication. This one is *only* reachable with byte control of the reply. | fake | 1 |
| `stream/interrupt-mid-run` | `C-c C-c` during a long run is delivered on the same pipe; the buffer shows the `KeyboardInterrupt` and returns to `:idle`. | real | 1 + 2 |
| `stream/stderr-face` | stderr renders in `jsonyter-stderr-face`, ANSI escapes rendered not literal. | fake | 1 |

## 7. Mode line and kernel state

Assert on `(format-mode-line mode-line-format)` — tier 1, exact — and never on
pixels. The point of these is that the *state machine* is reachable, which is
what the fake bridge is for.

| ID | State | Bridge |
| --- | --- | --- |
| `state/idle-and-run` | `:idle` → `:run` → `:idle` across one execute | real |
| `state/starting` | `:starting` while the kernel comes up | real |
| `state/run-ext` | `:run[ext]` — busy for another client | fake |
| `state/offline` | `:offline` after a half-open websocket; `C-c C-l` recovers | fake |
| `state/dead` | `:dead` after the kernel is killed out from under the buffer; the next execute reports dead instead of hanging | fake |
| `state/many-sessions` | An Org buffer with Python + R sessions summarises both in the mode line, and a `dead` event for one does not disturb the other | fake |

## 8. Org-mode blocks

| ID | What it proves | Bridge | Tier |
| --- | --- | --- | --- |
| `org/overlay-output-touches-no-text` | Running a `jy:` block with `C-RET` leaves buffer text byte-identical; output lives in an overlay. | fake | 1 |
| `org/conditional-keys-fall-through` | ⭐ The binding table says every shadowing key is conditional: inside a `jy:` block `C-c C-c` runs `jsonyter-org-C-c-C-c`, outside it falls through to Org's own. **Only reachable through the keymap** — call the function directly and you prove nothing. Assert with `eh keys` at three positions: inside a `jy:` block, inside a non-`jy:` block, and in prose. | none | 1 + 2 |
| `org/commit-writes-stamped-drawer` | `C-c C-s` writes `#+RESULTS[<hash>]:` with a `:results:` drawer. (Batch covers the mechanics; keep a GUI version that asserts the overlay disappears and the committed text renders.) | fake | 1 |
| `org/committed-image-file` | A committed figure lands in `.jsonyter/plot-<hash>.png` and the `[[file:…]]` link **renders as an inline image** after `org-display-inline-images`. The rendering half is GUI-only. | fake | 1 + 3 |
| `org/stale-before-any-kernel` | Reopen a file whose block was edited since its `#+RESULTS[hash]`: the result is framed stale *before any kernel starts*. Needs no bridge at all — a fast, high-value scenario. | none | 1 |
| `org/folding-hides-overlay-output` | Folding the subtree hides overlay output. Batch asserts the invisibility property; the GUI version asserts it is not on screen (`pos-visible-in-window-p`) and pixel-verifies once. | fake | 1 + 3 |
| `org/two-languages-one-buffer` | Python and R blocks in one file, both live, events routed per session. The multi-session claim of 2.0, end to end. | real (needs `ir`) | 1 |

## 9. REPL

| ID | What it proves | Bridge | Tier |
| --- | --- | --- | --- |
| `repl/return-vs-newline` | `RET` submits complete input, `C-j` inserts a literal newline, `M-RET` force-sends. Real keys; the `is_complete` round-trip decides. | real | 2 |
| `repl/is-complete-multiline` | `def f():` + newline + indented body is held as incomplete then submitted. | real | 2 |
| `repl/is-complete-sas-quirk` | A kernel that calls anything without a trailing newline incomplete (SAS) still submits, because jsonyter terminates the code first. | fake (`--script sas`) | 2 |
| `repl/is-complete-gives-up` | Two consecutive `is_complete` failures ⇒ `RET` always sends thereafter. | fake | 2 |
| `repl/history-walk` | `M-p`/`M-n` walk input history. **Depends on `last-command`**, so it is only meaningful through the command loop — a direct `funcall` passes while the feature is broken. | fake | 2 |
| `repl/completion-at-point` | `TAB` produces a completion UI with kernel-supplied candidates; assert the `*Completions*` window appears and its contents. Window layout is GUI-only. | real | 1 + 2 |
| `repl/inspect-popup` | `C-c C-d` opens a help buffer with kernel documentation. | real | 1 |
| `repl/input-function` | A cell calling `input()` prompts and accepts an answer. Exercises the prompt path end to end. | real | 2 |
| `repl/request-timeout-does-not-wedge` | A kernel that never answers `history` must not block later executes: `jsonyter-request-timeout` bounds it. Assert a subsequent execute completes. | fake (`never_reply`) | 1 |

## 10. Cross-version and packaging

| ID | What it proves |
| --- | --- |
| `pkg/loads-clean-on-every-version` | `(require 'jsonyter)` on 27.2 / 28.2 / 29.4 / 30.2 / 31.1 with `-Q`, no warnings, no errors, `display-graphic-p` true. |
| `pkg/no-obsolete-warnings` | The obsolete aliases (`jsonyter-notebook-insert-cell-below`, `jsonyter--kernel-id`, …) still resolve and still warn. |
| `pkg/reference-frame` | One full-frame baseline per Emacs version of a rendered three-cell notebook with output. The cheapest possible "did a version bump change how this looks" check. |

---

## Suggested implementation order

The first three are the ones that prove the harness is worth building:

1. **`cell/insert-below-leaves-neighbours-intact`** — the known bug. Write it
   red, fix the bug, watch it go green. Needs no kernel and no bridge, so it is
   also the simplest possible end-to-end exercise of the harness.
2. **`img/notebook-slices-are-addressable`** — the flagship claim of the
   notebook renderer, and completely untestable in batch.
3. **`org/conditional-keys-fall-through`** — the newest, least-covered code
   path, and one that *only* a real keymap lookup can test.

Then §7 (mode line states, which forces the fake bridge into existence), then
§5 (scrolling), then the rest.

---

## Fixtures needed

Reuse the existing suite's fixture text verbatim where possible — its notebooks
already have fixed cell ids, which the harness needs for determinism (DESIGN
§7.4).

```
fixtures/
  three-cells.ipynb          two code cells + one markdown, fixed ids, no outputs
  with-outputs.ipynb         the same, with stored stream + image outputs
  tall-plot.png              a fixed PNG, ~640×1200, for slice-count assertions
  wide-plot.png              for max-width scaling
  traceback.txt              a real ANSI-coloured Python traceback
  script-cells.py            # %% cells
  blocks.org                 jy:python and jy:R blocks, plus a non-jy: block
                             and prose, for the conditional-key scenario
  committed.org              a #+RESULTS[hash] whose block has since been edited
bridge-scripts/
  streaming.jsonl            slow-drip stdout, for scroll and streaming tests
  progress.jsonl             clear_output(wait=True) redraws
  sas.jsonl                  is_complete quirk, never answers history,
                             inspect → aborted
  offline.jsonl              half-open websocket → :offline
  dead.jsonl                 kernel killed out from under the buffer
  external.jsonl             :run[ext]
  hostile.jsonl              truncated JSON, stderr noise, invalid UTF-8
```

## Names to re-verify before writing scenarios

Read out of jsonyter.el 2.0.0 and believed current, but confirm against the
working tree at implementation time:

- Faces: `jsonyter-prompt-face`, `jsonyter-output-prompt-face`,
  `jsonyter-stderr-face`, `jsonyter-note-face`, `jsonyter-code-cell-face`,
  `jsonyter-markdown-cell-face`, `jsonyter-raw-cell-face`,
  `jsonyter-notebook-rule-face`, `jsonyter-output-border-face`,
  `jsonyter-output-border-stale-face`. Note also `jsonyter-notebook-cell-face`
  and `jsonyter-notebook-markdown-face`: they are absent from the README's face
  table but are live — they are the base faces that `jsonyter-code-cell-face`
  and `jsonyter-markdown-cell-face` inherit from, so a face assertion must
  resolve inheritance rather than compare symbols naively.
- Overlay / text properties: `jsonyter-cell`, `jsonyter-cell-id`,
  `jsonyter-cell-type`, `jsonyter-source-end`, `jsonyter-source-hash`,
  `jsonyter-output-stale`, `jsonyter-exec-count`, `jsonyter-output-string`,
  `jsonyter-raw-outputs`, `jsonyter-outputs-touched`, `jsonyter-running`,
  `jsonyter-script-cell`, `jsonyter-org-cell`, `jsonyter-org-committed`.
- Public accessors for waiters: `jsonyter-current-session`,
  `jsonyter-current-kernel-id`, `jsonyter-current-session-name`,
  `jsonyter-current-kernel-busy-p` — all documented as nil-safe.
- The hidden stderr buffer is ` *jsonyter stderr*` (leading space).
- Cell metadata is held in **overlay** properties; `read-only` is a **text**
  property. Assertions must not confuse the two (DESIGN §6.2).
- The pre-2.0 scalars are marked with `make-obsolete-variable`, not
  `define-obsolete-variable-alias`, so `pkg/no-obsolete-warnings` should assert
  `(get 'jsonyter--kernel-id 'byte-obsolete-variable)`, mirroring the existing
  batch test.
