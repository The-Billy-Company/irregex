# kernel/regex/glean — the consumer face

Every other tier here is named for what it *is* — the syntax, the ast, the linear engines, the caliper, the ladder. This one is named for what a caller *does*: hold a compiled pattern and take matches out of a haystack, with their groups, replacing or splitting on the way. It is the only tier in this package whose shape is set by the person asking rather than by the automaton answering, which is why it did not exist until the export surface was audited and the largest audience turned out to be the one with no door.

## Files

- **`pattern.zig`** defines `Pattern`, the handle: `compile`, `isMatch`, `find`/`findIn`, `matches`/`matchesIn`, `findAt`/`isMatchAt`/`matchesAt`, `earliest`/`earliestIn`, `walk`, `count`, `groups`, `replace*`, `split*`. It owns its scratch, compiles the capture arm lazily, reaches both backends, and hands the engine back through `engineOf` for a planner.
- **`pool.zig`** decides who owns the memory a search reuses. It shelves `Matcher.Sim`/`Matcher.SpanSim`/`Matcher.Probe` behind `math.lease.Latch` so no consumer signature says `Sim`, and holds no pointer to its matcher, which is the reason a `Pattern` is a plain movable value.
- **`cursor.zig`** defines `Cursor`, successive non-overlapping matches carrying the empty-match rule a library caller expects — the one ripgrep deliberately does not use. Its `Mode` is where the two questions leftmost-first cannot answer enter: **anchored** (each match begins where the last ended) and **earliest** (the match that ends first). Both consult a halting walk from `../linear/dfa/onset.zig`; anchored also stands without one, earliest does not and refuses instead.
- **`groups.zig`** defines `Groups`, what a capture caught, by ordinal or by name, as a view over the engine's flat `[]isize` slot vector. It owns nothing and copies nothing.
- **`rewrite.zig`** implements `replace`, `replaceWith`, and `split`, all one walk over a `Cursor` with different bookkeeping.

This package depends on `../matcher.zig` (the engine-neutral seam), `../compile/captures.zig` (the opt-in capture arm), and the package vocabulary in `../../../mark.zig`.

It adds no engine: every verb lowers to a call `exec`/`cold` already makes on the same `Matcher`, so where this door and `gist` both report a match they agree by construction rather than by agreement. The one thing they do not share is which zero-width positions get reported — see below — and that fork is in the walk that drives the engine, never in the engine being driven.

## The Handle As A Second Type

`Regex` is copied by value in this tree — `Matcher` holds one, the differential tests hold two side by side — so an owned scratch pool inside it would turn every one of those copies into a double free. The type that owns scratch is therefore the type you must not copy, and it is separate so that rule attaches to it alone: move a `Pattern`, never copy one.

The split is also the honest one. `Regex` answers the walk planner's questions — `bufPrefixClosed`, `countRunFused`, `claimsNewline`, the prefilter literals — and every one of those earns its place, because they are how the cold pipeline decides what work to skip. None of them is a question a person with a pattern and a string is asking. Two audiences, two faces, one engine.

## The Zero-Width Rule

Resuming a walk at `span.end` is correct for a match that consumed something and an infinite loop for one that did not: `a*` accepts the empty string at every position, so `end == start` and the next search starts where the last one did. `Cursor` steps one byte past an empty match, always a byte, in the same coordinate system the span was reported in. A codepoint-sized step reads as the more principled choice and is wrong: `l*` over `héllo` has an empty match at byte 2, the continuation byte of `é`, and stepping a whole character loses it. Python, `rust-regex`, and ripgrep all report it.

Where the walk genuinely forks is what to do with an empty match that is adjacent to the previous one, or that sits at the very end of the haystack. This package answers that twice, on purpose.

- **Audience.** `Cursor` here serves a library caller with a haystack; `kernel/query`'s `walk` serves the `gist` CLI and the C ABI over it.
- **Bar.** `Cursor` matches Python `re`, `rust-regex`, and JS byte-identically; `walk` matches ripgrep byte-identically.
- **An empty match adjacent to the last.** `Cursor` reports it; `walk` suppresses it.
- **An empty match at the very end.** `Cursor` reports it; `walk` reports it only on a newline-terminated line.

`b*` over `abcb` is `(0,0) (1,2) (2,2) (3,4) (4,4)` here and `(0,0) (1,2) (3,4)` there. rg drops the adjacent and unterminated empties because it prints line-oriented rows and those two are noise on a page; a library that dropped them would disagree with every other regex library its caller has used. `../../query/zero_width_test.zig` holds both sequences side by side with the external authority for each, so neither can be "fixed" into the other.

This is a fork in the reporting rule, not a duplicated loop: the C ABI does not re-implement anything. `irgx_find_all` hands the host's buffer to that same `walk` as one unterminated unit and returns the whole answer, and all three language bindings iterate the sequence it returns rather than calling `find(from)` in a loop of their own.

## What Is Deliberately Absent

- **A `$1` template grammar for replacement.** It would need its own parser, its own escaping rule, and its own error channel to express something the host language already says better. `replaceWith` takes a callback that is handed the match and writes what it likes, and costs no grammar.
- **A fused capture engine.** The primary engine stays capture-free — a byte-class DFA cannot track groups — so `Pattern` compiles the capture arm only when a group is actually asked for. Matching never pays for a VM nobody wanted.
- **An approximated bound.** PCRE2's subject has one length, so honoring a window bound there would mean shortening the subject, which also moves `$`, `\z`, `\b`, and every lookahead. `matchesIn`/`findIn` raise `BoundUnsupported` rather than quietly answer a different question.
- **An earliest span filtered out of the leftmost one.** There is no such filter: leftmost-first picks a match by where it starts and extends it by priority, so `a+` over `aaa` is one span there and three here, and the second sequence has spans the first never reported. A compile with no halting machine — the PCRE2 arm, or a pattern carrying a positional assertion — raises `Unsupported` from `earliest`/`walk`, and `Pattern.halts` says so before the ask.

## When To Edit

Add a verb here when a caller genuinely cannot express it with the ones already present, or fix the advance/bookkeeping rules the tests in `glean_test.zig` pin. Engine behavior changes belong in `../linear/` or `../compile/`; a new name at the package root also needs a row in `contract/exports.toml`, which the surface gate enforces.
