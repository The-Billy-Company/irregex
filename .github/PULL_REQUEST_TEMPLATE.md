<!--
Thanks for sending this. Delete any section that does not apply rather than
writing "n/a" in all of them - a short, honest PR body beats a filled-in form.
CONTRIBUTING.md has the long version of everything below.
-->

## What changed

<!-- One or two sentences in the voice of the change. What is different now? -->

## Why

<!-- The problem, not the patch. If there is an issue, link it. -->

## What proves it

<!--
The question review asks first. Name the test, the harness, the fixture, or
the oracle - and what it would have done before this change. "Existing tests
pass" is not proof that a new behaviour is right.

For a performance claim: the harness under bench/, the numbers before and
after, and the machine. An absent number beats an invented one.
-->

## What it costs

<!--
Allocation, syscalls, a new dependency, a wider public surface, a slower cold
path. If the answer is genuinely nothing, say so - that is an answer.
-->

## What it replaces

<!--
If a newer path supersedes an older one, the older one should be gone in this
same PR. Two spellings of the same thing is how a codebase grows two spellings
of the same bug.
-->

---

- [ ] `zig build test` passes, and `zig fmt .` leaves the tree clean
- [ ] A news fragment is in `changelog.d/` (`+<slug>.<type>.md`), unless this is
      comment-only, format-only, or genuinely invisible
- [ ] No ratchet baseline was raised to make a gate pass
- [ ] `contract/irregex.ward` is updated in this PR if a new import edge was needed
- [ ] Third-party code, data, or a published algorithm is credited in `NOTICE`
      and at the call site
- [ ] The public C ABI in `include/irgx.h` is unchanged, or the change is
      described above and the bindings move with it
