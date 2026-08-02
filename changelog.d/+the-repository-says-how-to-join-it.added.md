The repository had a license, a NOTICE, and eight CI jobs, and nothing that told
an outsider how to participate in any of it. Every fact a contributor needed -
which Zig, how to filter the suite, that a ratchet baseline may only shrink,
that a fragment goes in the same PR, where a security report is supposed to go
instead of the issue tracker - lived in a workflow comment or in nobody's head.

Six files now say it out loud.

**`CONTRIBUTING.md`** is the practical half: the sibling-checkout layout the
bindings path-depend on, the pinned toolchains and what pins them, the test loop
that matters (`-Dtest-filter`, `-Dtest-shards=1`, `BRIGADE_TIMES=1`, and the
direct-binary escape hatch for anything that reads the environment), what each
of the eight CI jobs holds, and the three questions review asks before any
others - what proves this, what does it cost, what did it replace.

**`SECURITY.md`** draws the line this project actually has. Memory safety
anywhere, a loader that trusts a persisted artifact, and superlinear blowup on
the *linear* engine are vulnerabilities. PCRE2 going exponential behind `-P` is
the documented trade you opt into, and cost proportional to input size is
arithmetic. It also states the thing a reporter cannot guess: safety checks are
off in the `ReleaseFast` build the faces ship, so a clean panic on your machine
may be a memory-safety bug on theirs.

**`CODE_OF_CONDUCT.md`** is Contributor Covenant 3.0, with the reporting and
enforcement sections filled in rather than left as the template's bracketed
notes. Its "failing to credit sources" clause is not decoration here; it is the
same rule `NOTICE` and the `research/*/PRIOR_ART.md` dossiers already enforce in
code.

**`.editorconfig`** carries no second opinion: every value is the one the
formatter that gates the file already emits, so an editor save and `zig fmt
--check` cannot disagree. Vendored trees and the pinned UCD tables are exempt,
because re-indenting somebody else's bytes on save turns a re-vendor into an
unreviewable diff.

**`.gitattributes`** normalizes line endings, marks the prebuilt archives
binary, keeps vendored and generated files out of review and out of the language
statistics, and binds git's hunk-header drivers. It deliberately does not use
`export-ignore`: that would change the bytes of the tarball GitHub generates for
a tag, which is exactly what a downstream `zig fetch` pin is a hash of.

**`.mailmap`** collapses eight author spellings into the three people who wrote
them - two laptops that had signed commits as `<user>@<hostname>.local`, and one
personal address that later became a work address.

Alongside them, `.github/` gains a CODEOWNERS routing table, a Dependabot
configuration covering all four manifests (and explaining why Zig is absent:
the `.zon` pins are provenance for bytes already vendored, so bumping one
without re-vendoring would produce a manifest that lies), a pull-request
template, and three issue forms. The first of those forms is the one this
project needs most - a wrong-match report that asks for the pattern, the
subject, the flags, and what an independent engine says, because a divergence
from what a pattern means outranks nearly everything else in the queue.
