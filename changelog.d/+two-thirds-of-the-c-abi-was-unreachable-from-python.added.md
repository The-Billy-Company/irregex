The Python binding reaches the whole engine now, not just the regex plane. It
named 38 of the C ABI's 100 symbols; it names all 100.

The 62 that were missing are not odds and ends - they are six whole planes the
binding had no word for. `irgx.walk` decides which files a search may read.
`irgx.corpus` searches a tree instead of a buffer. `irgx.sieve` narrows against a
persisted artifact so most files are never opened. `irgx.build_codex` answers
`count` and `locate` about a text it does not keep. `irgx.line_context` puts the
byte-offset-to-row conversion in one place instead of in every caller.
`irgx.literals` says what a pattern promises before it runs, and
`irgx.compile_needles` sweeps N literals in one pass while keeping which one hit -
the fact an alternation throws away. Each is one module that declares its own
prototypes beside the wrappers calling them, loaded lazily, so a program that only
calls `search` still pays for nothing else and a wheel built against an older
engine still imports - the absent plane raises when it is reached for, naming the
symbol it wanted.

Two hazards specific to a ctypes host got closed rather than avoided.

ctypes defaults an unset `restype` to `c_int`, and seven verbs return `size_t`,
so an unset one truncates on any 64-bit host - a wrong answer, not a crash, and
invisible to any test whose numbers stay under 2^31. Every prototype now declares
`argtypes` and `restype`, and `declare()` records what it bound into a table the
suite audits: all 100 symbols compared against the types parsed out of
`include/irgx.h`, plus a test that derives the seven `size_t` verbs from the
header rather than listing them, so a new one is covered the day it lands. The
audit is also demonstrated rather than asserted - one test borrows libc's
`strtoull`, parses `4294967296` with `restype = c_size_t` and gets it back, then
parses it again through a handle with the restype left at its default and gets 0.
The reason for the rule, in the test file, next to the rule.

Borrowed bytes look exactly like owned bytes in Python, so every borrowed range
is copied at the boundary - tree record paths and lines, walk entry paths, sieve
candidates and literals - with one decoder, `borrowed()`, doing it. A keepalive
reference only works if the discipline is total, and Python offers no way to make
it total: a `str` that escapes into a set or a log line takes its arena's last
reference with it and faults a week later somewhere else. The copies are tens of
bytes against the `stat` or the file read that produced them. Two tests close the
handle, `gc.collect()`, and only then read the values.

`IRGX_STALE` is a declinature, so it returns `None` and never raises - for a PCRE
pattern with no inspectable program, a tree with no artifact, a codex built with no
locate layer. `Sieve.candidates` keeps `None` and `()` distinct, because "nothing
narrowed" and "narrowed to nothing" are different answers and collapsing them is
how a fallback ends up never running.

`match` and `fullmatch` arrive with them, and neither is faked. `match` is a
leftmost search plus a start comparison, which is exact rather than approximate
because this engine is leftmost-first exactly as `re` is. `fullmatch` asks
`irgx_munch_scan` under `IRGX_MUNCH_LONGEST` for the longest match beginning at
one offset - a real anchored automaton, since `a|ab` proves an unanchored search
cannot answer it. Where the full span and the leftmost span disagree and the
pattern declares groups, there is no anchored capture verb to ask, so it refuses
loudly at match time rather than reporting groups from the wrong span.
