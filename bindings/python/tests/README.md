# Tests

```bash
python3 -m pytest
```

From a source checkout there is no bundled library yet - that is placed by the
build hook when a wheel is built - so `conftest.py` points `IRREGEX_LIB` at the
engine's own `zig-out` build, using exactly the override a user would. Build it
first with `zig build` from the engine root. Against an installed wheel the
bundled library is already there and nothing in `conftest.py` fires, which is
what makes the same suite valid in both places.

| File | What it is for |
|---|---|
| `test_iteration.py` | Zero-width and nullable patterns, cross-checked against `gist --json` where the tool is available. |
| `test_unicode.py` | Codepoint indices versus byte offsets, case folding past ASCII, and the `str`/`bytes` wall. |
| `test_threads.py` | One module-level `Pattern`, many threads, different texts. |
| `test_groups.py` | Numbered, named, and non-participating groups; the short-window `captures` contract. |
| `test_flags.py` | Every flag, proved by a behaviour that changes when it is set. |
| `test_errors.py` | Refused patterns - both kinds, told apart by class - mixed domains, and the load-time failures, which need a fresh interpreter. |
| `test_substitution.py` | `sub`, `subn`, `split`, and the template grammar. |
| `test_parity.py` | Side by side with `re`: agreement where they agree, our answer asserted as a literal where they do not. |

## How these are written

A test that passes whatever the code does is worse than no test, so the ones
that carry weight are written against a plausible wrong implementation rather
than against the current one.

- `test_iteration.py` contains `_naive_walk`, the hand-rolled advance loop this
  binding refuses to use, and asserts the engine's sequence differs from it.
  If someone replaced `find_all` with that loop, the suite would say so.
- `test_threads.py` reads the C handle address from eight threads held live at
  once by a barrier. Let them run one at a time and the allocator hands the
  same address back, so the test would report sharing where there is none.
- `test_unicode.py` asserts `text[m.start():m.end()] == m.group()` on text
  where byte offsets and codepoint indices actually differ, which is the single
  line that catches every mistake in the translation.
- `test_errors.py` does not stop at "the right class came out": for every
  pattern it calls `UnsupportedPattern` it then compiles that pattern with
  `pcre=True`, and for every one it calls malformed it proves `pcre=True` still
  refuses. A binding that mislabelled one would pass the class assertions and
  fail these. It also fails a pattern *first*, so the thread's fault slot holds
  something, and then asserts a declined pattern leaves that slot empty - which
  is the behavioural proof that the class comes from the status code and not
  from a fault name, since there is no fault to name.
- `test_parity.py` computes `re`'s answer live for the patterns where the two
  are specified to agree, so it fails if either side moves. Where they diverge
  it states our answer as a literal and says in a comment why; making that a
  comparison would turn a documented divergence into whatever the code does.
