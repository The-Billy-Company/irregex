#!/usr/bin/env python3
"""Mine a multi-pattern slate of arbitrary width from the packed corpus.

The per-byte race needs a slate that can grow to ~1024 literals, because that is
where the two gist tiers and Vectorscan actually separate. Three properties make
such a slate measure scaling rather than luck, and a hand-written list of a
thousand identifiers satisfies none of them:

  * **Real.** Every literal is an identifier that genuinely occurs in the corpus,
    at least `--min-count` times. Invented needles that never match would exercise
    only the miss path -- the easy one, and the one where every matcher looks good.
  * **Nested.** The ordering is fixed, so `slate(2)` is a prefix of `slate(4)` is a
    prefix of `slate(1024)`. Growing N is then purely additive, and a step in the
    curve is attributable to N. Drawing a fresh strided sample per N instead makes
    the curve non-monotonic in a way that reads as a scaling effect but is really
    just a change of vocabulary -- Vectorscan measured 1.1, 2.7, 1.8 GB/s at
    N = 48, 64, 128 under per-N sampling, which is unreadable as a claim.
  * **Spread at every width, not just the widest.** Picks are strided across the
    frequency ranking rather than taken from its head, so the full slate spans
    selectivities. Nesting and spread fight each other naively -- if the ordering
    is by frequency, then `slate(10)` is the ten MOST COMMON tokens, which is
    unrepresentative in the worst possible direction: they match nearly every
    file, so an index has nothing to skip and a corpus-scale run measures line
    emission instead of search. That is not hypothetical; it took the end-to-end
    arm from a 4.3x win to 1.02x purely by changing which ten words it asked for.
    So the strided picks are then reordered by the **van der Corput sequence**
    (bit-reversal permutation), which makes every prefix quasi-uniform over the
    frequency range while keeping the prefixes nested.


Deterministic: same corpus bytes in, same slate out, no RNG. Emits one literal per
line, so the caller reads it with `mapfile`.

Usage: slate.py --corpus DIR [-n 1024] [--min-count 4] [--digest]
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

# Long enough that a literal is a discriminating stem rather than a digram, and
# capped so one freak token cannot dominate the automaton's depth.
IDENT = re.compile(rb"[A-Za-z_][A-Za-z0-9_]{5,23}")


def vdc_order(n: int) -> list[int]:
    """Indices `0..n-1` in van der Corput (bit-reversed) order.

    The property that matters: every prefix is spread roughly uniformly over
    `0..n-1`, so taking the first k of a frequency-ordered list yields k literals
    spanning the whole selectivity range rather than k near-ubiquitous ones --
    while still being a prefix, hence nested.
    """
    bits = max(1, (n - 1).bit_length())
    # Reversed bit pattern is the sort key; the index breaks ties so the order is
    # total and reproducible for non-power-of-two n.
    return sorted(range(n), key=lambda i: (int(f"{i:0{bits}b}"[::-1], 2), i))


def canonical(blob: bytes, want: int, min_count: int, max_count: int | None = None) -> list[str]:
    freq: dict[bytes, int] = {}
    for m in IDENT.finditer(blob):
        tok = m.group()
        freq[tok] = freq.get(tok, 0) + 1
    # Ranked by descending frequency, ties broken by the bytes themselves so the
    # ordering is total and platform-independent (dict order never leaks in).
    ranked = [
        t
        for _, t in sorted(
            (
                (c, t)
                for t, c in freq.items()
                if c >= min_count and (max_count is None or c <= max_count)
            ),
            key=lambda p: (-p[0], p[1]),
        )
    ]
    if not ranked:
        return []
    stride = max(1, len(ranked) // want)
    picked = ranked[::stride][:want]
    if len(picked) < want:  # stride overshot; fall back to the dense head
        picked = ranked[:want]
    return [picked[i].decode("ascii") for i in vdc_order(len(picked))]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True, type=Path)
    ap.add_argument("-n", type=int, default=1024)
    ap.add_argument("--min-count", type=int, default=4)
    ap.add_argument(
        "--max-count",
        type=int,
        default=None,
        help="drop literals occurring more than this often -- the SELECTIVITY "
        "band. Corpus token frequency is not query frequency: an agent "
        "sweeps for `WalletService`, never for `string`, so a slate drawn "
        "from the raw token distribution measures line emission rather "
        "than search. Capping the count models a symbol query.",
    )
    ap.add_argument(
        "--digest",
        action="store_true",
        help="print 'COUNT SHA256' instead of the slate, for the record",
    )
    args = ap.parse_args()

    blob_path = args.corpus / "corpus.bin"
    if not blob_path.is_file():
        print(f"slate.py: no packed corpus at {blob_path} (run pack.py first)", file=sys.stderr)
        return 2

    slate = canonical(blob_path.read_bytes(), args.n, args.min_count, args.max_count)
    if len(slate) < args.n:
        print(
            f"slate.py: corpus yielded only {len(slate)} usable literals "
            f"(wanted {args.n}); widen the corpus or lower --min-count",
            file=sys.stderr,
        )
        if not slate:
            return 2

    if args.digest:
        h = hashlib.sha256("\n".join(slate).encode()).hexdigest()
        print(f"{len(slate)} {h}")
    else:
        print("\n".join(slate))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
