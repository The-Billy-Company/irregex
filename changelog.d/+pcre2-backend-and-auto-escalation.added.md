`-P`/`--pcre2` selects a vendored PCRE2 10.47 JIT backend
(`src/regex/pcre2.zig`) for the constructs the linear engine can't express —
lookaround, backreferences, named captures — with per-thread match scratch and
fail-closed resource ceilings (10M match / 10k depth) so pathological input
trips a clean no-match instead of hanging. `--engine auto` (and rg's deprecated
`--auto-hybrid-regex` alias) is the hybrid: compile the linear engine first for
its speed + trigram AST, escalate to PCRE2 only for a pattern the linear engine
declines. Crucially, PCRE2 patterns are **trigram-prefiltered** too — sound
required-literal extraction (`src/regex/pcre2/literal.zig`) skips files that
provably can't match before PCRE2 runs, making gist the only *indexed* PCRE
search in the field: it wins the `bench/races/pcre_headtohead.sh` lookaround /
backreference slate against every PCRE-capable competitor (rg -P, ugrep, ag,
grep -P, git grep -P), with rg -P as the correctness oracle. `--rank` and
template replace remain linear-engine-only. The flag catalog, `--schema`,
`README.md`, and `.cursor/rules/gist.mdc` now reflect that no ripgrep long flag
is unsupported-fail-loud any more; the fail-loud contract now guards unknown
flags and patterns outside the chosen engine, always naming the `-P` / `--engine
auto` fallback.
