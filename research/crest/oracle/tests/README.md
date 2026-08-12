# CREST oracle tests

Adversarial refusals, frozen production-projection checks, and exhaustive
finite-language differentials for the independent exact automata oracle.
Expected languages and ranked run spectra come from the tiny denotational
interpreter in `test_oracle.py`, not irregex's parser, CREST calculus, or NFA.
Focused export tests also prove that the checked Zig fixture is byte-identical
to a fresh generation, `--check` rejects drift, `--write` repairs it, and all
32 selected templates remain assertion-free consuming patterns across the
15 contract-derived projections.
