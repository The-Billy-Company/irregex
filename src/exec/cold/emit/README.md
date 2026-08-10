# exec/cold/emit — Match Presentation

Turns match spans into the bytes on stdout. One `Emitter` carries shared
match, context-window, byte-offset, and replacement state across every
byte-compatible ripgrep output mode so heading / content / context lines
cannot disagree with each other.

- **`output.zig`** is the `Emitter` façade — per-file emission state, the
  writer vocabulary every mode frames output with, and the five verbs that
  forward into [`output/`](output/README.md).
- **`output/`** holds the emit modes themselves, one file per output
  model: `grid` (per-line), `skim` (line-free literal), `multibuf`
  (`-U`), `display` (presentation), `replace` (`-r`).
- **`render.zig`** does one file, start to finish: match it, apply the
  `-m` / `-l` / `--count` short-circuits, shard long files across cores,
  and hand the spans to the `Emitter` — the step both cold schedulers call
  instead of each writing their own.
- **`color.zig`** resolves `--color auto|always|never|ansi` (stdout tty +
  `NO_COLOR` / `TERM`) and the highlight palette.
- **`json.zig`** owns the `--json` event stream (rg's `begin` / `match` /
  `end` shapes), including the JSON string encoding it borrows from
  [`surface/cli/jsonstr.zig`](../../../surface/cli/jsonstr.zig) — `text`
  when the bytes are valid UTF-8, base64 `bytes` when they are not.
- **`multiline.zig`** holds the `-U` whole-buffer match model
  (`Emitter.buffer` + `--json` spans), and the two places rg's slice model
  answers differently from its line model: `-c` counts spans, not
  start-lines, and `-v` claims lines by a sequential rescan so a later
  match still hides its own line.
- **`hints.zig`** is the stderr guidance channel, on two triggers: a
  notable outcome (`gist: no matches …` plus up to three ranked `gist:
  try` / `gist: note:` lines) and a notable duration (`Vigil` — a walk
  still running past its patience reports progress instead of looking
  hung). The outcome arm reads an `Evidence` value probed from the bytes
  the run actually searched rather than from the query's spelling, so a
  suggestion is withheld unless the corpus backs it — see [A Hint Has to
  Be Earned](#a-hint-has-to-be-earned). Muted by `GIST_HINTS=0`, never
  touches stdout.

The warm session's line renderer
([`exec/session/facet/render.zig`](../../session/facet/render.zig))
deliberately drives this `Emitter` rather than a re-derived formatter —
warm `path:line:text` frames are cold frames by construction.

## Clickable Rows

The click target itself is decided one directory up, in
[`cli/beacon.zig`](../../../surface/cli/beacon.zig), because `relate` and
`irregex` print paths too. What lives here is only the framing: `linkOpen`
/ `linkClose` bracket text a row was going to print anyway, so the anchor
is whatever the reader already sees — the whole `path:line` locator, or
just the path under `--heading` and `-l`.

Every one of those calls is a null check when the run resolved no beacon,
which is why links-off output stays byte-identical to ripgrep's. Under
`--null` no posture links at all: that list's payload is the filename's
bytes, bound for `xargs -0`.

## Why the Vigil Is Gated Harder Than a Hint

A long walk is indistinguishable from a hung process, so it gets killed
like one — the run that motivated `Vigil` (`gist -uu` over a tree carrying
gigabytes of vendored clones) walked for well over a minute in complete
silence and was killed early. The fix is for the walk to say it is alive.

But every other line on this channel is a pure function of the query, and
a progress line is a function of the clock. So the vigil speaks only when
stderr is a terminal: a pipe, a redirect, a captured stderr, and every
parity harness sit outside its reach by construction. That is the same
destination-conditional posture headings and hyperlinks already take — a
human learns the walk is alive, and nothing an agent or a gate captures
moves a byte.

The counters it reports (`Queue.walked`, `Queue.live`) are two atomics the
work-stealing walk already maintains, so arming a vigil cannot slow the
walk it watches.

## A Hint Has to Be Earned

Every line on the outcome arm used to be a pure function of the pattern
text, and a pure function of the pattern text cannot know whether its
advice helps. `gist -n 'KEY_THREAD_ID|__all__|globals\(\)' attrs.py`
answered with three suggestions and all three were wrong: `-i` on a file
holding no case variant of any branch, `-F` because `\(` looked like a
metacharacter when the backslash is what makes it literal, and `-uu` on a
path the caller had named explicitly. Meanwhile the fact worth saying —
the string lives in `attrs.gen.py`, one directory entry over — was not
sayable at all, because nothing on this channel had ever looked at a byte
of the corpus.

So the channel takes evidence now. `Shape` is still what the query says;
`Evidence` is what the corpus says, and `noMatches` only renders the
second. Four probes fill it, in the order they get cheap:

- **A counterfactual for `-i`.** The `-i` line claims a caseless retry
  would find something, which is a claim about the bytes. `probe` runs the
  caseless match over the same resident bytes and sets `caseless_dead`
  when it also finds nothing, which retires the suggestion instead of
  printing it. This is the single largest source of the old noise.
- **The longest live prefix.** A dead literal usually dies at a specific
  byte, and saying where is worth more than saying it is absent: `KEY_T`
  is here on 2 lines, so `KEY_THREAD_ID` stops matching after it. That
  locates a typo or a rename to the character, and it is a fact about the
  file rather than a guess about the caller.
- **Per-branch attribution.** `A|B|C` is three questions bundled into one
  answer, and "no matches" collapses them. Each branch is probed on its
  own, so the report can name which of them the corpus never held.
- **Scope versus corpus.** Resident bytes can say a string is absent
  *here*; they structurally cannot say it exists somewhere the walk never
  visited. That question goes to [`quarry/witness.zig`](../quarry/witness.zig),
  which asks the trigram index and then reads the candidates back to
  confirm them, so the file it names is a file that currently holds the
  bytes. A generic "try a wider scope" becomes a scope to widen *to*.

The budget is deliberate, and it makes the first three probes' reach
uneven on purpose. They run over bytes already resident and already paid
for, on a run that came back empty — so a scope of named files is
re-readable inside a fixed budget, while a directory or tree scope is not,
and re-walking one to explain a miss would make the courtesy cost more
than the search. That scope declines the byte probes and the affected line
falls back to its old syntactic form rather than vanishing. The index side
is capped at a handful of confirming reads and is unaffected either way,
since the sighting never needed the scope's bytes. Nothing here can fail a
search: a missing index, an unreadable candidate, or a scope too broad to
materialize each drop their own hint and leave the rest standing.

### The One Hint That Fires on a Successful Run

`A|B|C` where only `A` and `C` matched exits 0, prints rows, and looks
complete. It answered two of three questions and said nothing about the
third. `deadBranches` closes that: on a run with matches, a branch whose
bytes appear nowhere in the output earns a note.

It is gated on `results_faithful`, because the check reads the printed
results and only some modes print enough to read. `-l` prints paths, `-c`
prints numbers, `--json` reshapes the text, `-r` rewrites it, and `-m`
truncates it — in every one of those a branch can match without leaving a
trace in `out`, so the absence of its bytes proves nothing and the note is
withheld rather than guessed.

## One Owner for "Which Literals May I Sweep For?"

Before any mode walks a body, it can mark which lines are even worth
looking at: a match must contain one of the pattern's literals, so one
fused whole-buffer sweep rejects most lines and the engine confirms only
the survivors. The mark is a necessary condition, never a sufficient one —
every consumer re-runs the matcher on a line it kept, so a false positive
costs a confirm and nothing else.

That asymmetry is what makes the set-selection question subtle. A
pure-literal equivalence set (the pattern *is* this alternation) may
decide outright; a per-branch alternation cover may only nominate. Both
are legal to sweep for, and the cover is the one worth having — it is
what a class-led pattern like `[A-Z]+_TYPE|[a-z]+_kind` has instead of
literals. But it is unsound under `-i` (a match may hold a case variant of
the bytes) and `-U` (a match may cross the line the mark is about), and
unsound under `-v`, where a match lacks the literals entirely.

Three sites ask that question — the line-mode mask, the `--json` mask, and
`--json`'s solo-shard jump — and for a while they each answered it
themselves, which meant two of them took the cover and one silently
didn't. `maskLiterals` in [`output.zig`](output.zig) is now the only one
that answers, ranking the pure-literal set first and falling back to the
cover where it is sound. A new mode that wants to skip lines should call
it rather than reach for `re.lits()`.

## When to Edit

Output framing, color policy, `--json` event shapes, multiline buffer
model, hyperlink destination/emulator detection, or either arm of the
coaching channel (no-match hints, the long-walk vigil). Changing *what*
matched belongs in `kernel/regex/`; changing *which files* were searched
belongs in walk/engine.
