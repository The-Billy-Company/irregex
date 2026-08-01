# tests

`cargo test`. No Python, no network, and no engine build: the cross-check corpus
is committed and the library comes from `vendor/`.

| File | What it proves |
|---|---|
| `oracle.rs` | Every span, every group span, and every `is_match` answer agrees with the reference Python binding, over a committed corpus of 94 pattern / flag / text triples. |
| `semantics.rs` | The engine's own rules, spelled out: nullable patterns, zero-width matches, byte offsets over non-ASCII, participating and non-participating groups, and each of the six flags changing an answer. |
| `surface.rs` | The `regex`-shaped API: iteration, split, the three replace verbs, `$name` expansion, closures as replacements, and a `find_all` window shorter than the answer still returning all of it. |
| `threads.rs` | One `static Regex` searched from many threads at once, with every answer checked against what that thread would have got alone. |
| `faults.rs` | A refusal is an error with a reason in it, and a negative status never becomes a wrong answer. The two refusals stay apart: a pattern the linear grammar declines is retryable under `pcre` and installs nothing, a malformed one carries the offset it died at and `pcre` will not rescue it. |
| `contract.rs` | The substrate mirror (`contract/`, generated schema table, grade bands) does not drift from `analytic.toml` / `engine.toml` / `kinship.toml` / gist's `surface.toml`. |

## The oracle is the strongest test here

`oracle.rs` is the one that would catch a plausible-but-wrong implementation. The
Python binding was written against this same C ABI first, is independently
verified, and its own suite pins the semantics, so it is ground truth for
questions this crate cannot answer on its own: whether `a*` over `"abc"` really
is two spans, whether a group that did not participate really is absent rather
than empty, whether `word(true)` filters or stops.

The corpus is generated, not hand-written:

```bash
python3 scripts/python_oracle.py
```

It records offsets in bytes, which is deliberate. The Python binding reports
codepoint indices for a `str` pattern and byte offsets for a `bytes` one; Rust
`str` is indexed by byte, so the bytes half is the like-for-like comparison. If
this crate had copied Python's offset translation, the non-ASCII cases would fail
by several bytes each. `corpus_matches_the_linked_engine` fails first, with a
clear message, if the corpus was generated against a different engine build.

## The anchor grid, and why it is shaped that way

`semantics::anchors_are_text_anchors_and_find_all_is_the_authority` pins the
contract that the buffer is one unit: `^` and `\A` at offset 0, `$` and `\z` at
the end, an interior newline an ordinary byte, and both arms of the engine saying
the same thing.

It is a grid rather than a list of non-matches, because "no match" is a weak
claim. An engine with per-line anchors and an engine whose anchors never match
anything both report no match for `\Aabc\z` over `"x\nabc\ny"`, and only one of
those is a defect worth catching. So every row records what all three readings
predict, the test asserts the engine against the text-anchor column, and two
closing assertions check that the grid still contains rows separating that column
from the other two. Eight rows currently contradict the per-line reading and
seven contradict an engine with dead anchors; watering the grid down below either
floor fails the test rather than quietly making it decorative.

`is_match` used to disagree with `find_all` on exactly those eight rows, because
it ran a boolean document kernel that split the buffer into lines. This file's
oracle test carried an allowlist for it, written to fail in both directions, and
the engine fix made every entry stale, which is what retired it. Agreement is now
asserted plainly across the whole corpus with nowhere to record an exception.
