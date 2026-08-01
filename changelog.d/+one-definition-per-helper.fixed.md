Three helper bodies were living in two files each, which is the shape a parity
bug arrives in: a fix lands in one twin and quietly misses the other, and
nothing fails until the two answers are compared.

The watcher's POSIX arms each kept their own `wallNowNs`, so Linux and macOS
could drift on what instant a delivery is stamped with. That is not cosmetic;
the annals date every observed change against that clock, and a held answer is
trusted purely on the epoch it mints. The reading now lives in
`watch/stamp.zig` and both arms read it. Windows is not a third copy of it -
its notify records carry the changed file's timestamps in-band, so it stamps
from those and reaches for a clock only on a removal.

The cover calculus was the worse one, because it had already started to drift.
`analysis.zig` derives the required-literal cover by recursive descent and
`ast/ast.zig` derives it by a forward sweep over the interned DAG; the whole
point is that both reach the identical verdict, and yet each carried its own
`thinner` and `weakest`, with the two `weakest` bodies already written
differently while still agreeing. Both now read the rule from `analysis.zig`,
which the DAG side already imports, so there is exactly one definition of which
of two covers is more selective. Same story for the single-codepoint `uclass`
literal, which the sweep spelled `litOfUclass` and the analysis spelled
`uclassLiteral`: one question deserves one answer, and it kept the name that
reads like what it returns.

No behavior moved; the surviving bodies are the ones that were already there.
