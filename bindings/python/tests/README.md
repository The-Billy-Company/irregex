# Tests

Run the whole suite from this directory:

```bash
python3 -m pytest
```

From a source checkout there is no bundled library yet - that is placed by the
build hook when a wheel is built - so `conftest.py` points `IRGX_LIB` at the
engine's own `zig-out` build, using exactly the override a user would. Build it
first with `zig build` from the engine root. Against an installed wheel the
bundled library is already there and nothing in `conftest.py` fires, which is
what makes the same suite valid in both places.

- **`test_iteration.py`** proves zero-width and nullable patterns follow the
  two rules that produce the engine's answer, against the hand-rolled loop
  that would give a different one. The same sequence is held to `gist
  --json`, the authority the header names, in gist's own suite - that
  comparison needs gist's binary, so it lives where the binary is built.
- **`test_unicode.py`** covers codepoint indices versus byte offsets, case
  folding past ASCII, and the `str`/`bytes` wall.
- **`test_threads.py`** holds one module-level `Pattern` live across many
  threads searching different texts.
- **`test_groups.py`** covers numbered, named, and non-participating groups,
  and the short-window `captures` contract.
- **`test_flags.py`** proves every flag by a behavior that changes when it is
  set.
- **`test_errors.py`** covers refused patterns - both kinds, told apart by
  class - mixed domains, and the load-time failures, which need a fresh
  interpreter.
- **`test_substitution.py`** covers `sub`, `subn`, `split`, and the template
  grammar.
- **`test_parity.py`** runs side by side with `re`: agreement where they
  agree, and our answer asserted as a literal where they do not.
- **`test_contract.py`** asserts the in-process status and fault vocabulary
  agrees across every artifact that restates it: `contract/engine.toml`, the
  `Status`/`AtSpace` enums in `contract.zig`, the `IRGX_*` defines in
  `include/irgx.h`, the error sets in `fault.zig`, and the constants in
  `irgx._abi` this binding switches on.
- **`test_cdef_header_parity.py`** checks that every function
  `irgx.contract.abi.CDEF` declares is spelled, typed, and returns exactly
  what `include/irgx.h` says it does, so a renamed C symbol fails here
  instead of staying invisible until a call nobody happened to make.
- **`test_contract_substrate.py`** asserts the `irgx.contract` mirror has not
  drifted from the canonical `engine.toml` and `analytic.toml`, from relate's
  vendored `kinship.toml`, or from which library each verb actually routes
  to.
- **`test_rows.py`** decodes the analytic row plane against synthesized value
  arrays rather than a captured answer, so it can force the cases a real
  cursor rarely hits: an absent field, an ordinal newer than this table
  knows, nested rows, and a deliberately drifted schema digest.
- **`test_packaging.py`** asserts the published package ships `py.typed`,
  without which a consumer's type checker silently ignores every annotation
  here.
- **`test_description.py`** checks the README used as the PyPI long
  description: every relative link must resolve against the page displaying
  it, not against the repository, and it needs no built library or network.

## How These Are Written

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
  is the behavioral proof that the class comes from the status code and not
  from a fault name, since there is no fault to name.
- `test_parity.py` computes `re`'s answer live for the patterns where the two
  are specified to agree, so it fails if either side moves. Where they diverge
  it states our answer as a literal and says in a comment why; making that a
  comparison would turn a documented divergence into whatever the code does.
