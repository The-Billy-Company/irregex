`[status_codes]`, `[decline_reasons]` and `[fault_domains]` are declared here
again, in `contract/engine.toml`. The ecosystem split had carried them out to
`gist/contract/surface.toml` along with the row schemas that genuinely belong
there, and it was the wrong home for a reason worth naming: `include/irregex.h`
is what returns those codes and that fault struct, so a host linking only
libirregex — the entire point of shipping this library separately — received a
vocabulary that no contract in this repository declared. librelate, libgist and
libblast speak it by linking it, not by redeclaring it.

The file said so itself the whole time. Its own section header still argued that
the in-process vocabulary "lives here because it is otherwise hand-copied four
times", and promised "the three tables after it" — and after `[exit_codes]` the
file simply ended. Nothing had gone wrong at runtime; the tables were fine where
they sat. What had gone wrong is that the contract was describing a shape it no
longer had.

Two other things it claimed are now true rather than aspirational. It carried a
second, pre-split table of contents advertising twelve tables and describing
`irregex` as "the composed face" — that binary has since been renamed `blast` —
so a reader learning the ownership model from this file learned the old one. And
it said the bindings work from a vendored copy of it; they don't, and never did
here: each one resolves this file from the authoring sibling checkout, which is
why `tools/sync_contract.py` checks that the sibling exists instead of copying
anything.

Table contents are byte-identical to the pre-split declaration, verified against
the monolithic `search_api.toml` still in git history: same six statuses, same
five domains with the same members, same five decline reasons.
