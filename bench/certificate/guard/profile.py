#!/usr/bin/env python3
"""What **irregex** certifies — the one file in `guard/` that is not vendored.

Every other module here is byte-identical across the four packages and holds the
*method*: what makes a bundle reproducible, what a ledger drift looks like, when
a release may be cut. This file holds the *claim*, and it is irregex's alone.

irregex is the engine and the `libirgx` C-ABI floor — a library, no CLI. What it
can certify is therefore not "faster than a rival product" but something the
products downstream cannot even ask: **how close the engine runs to the physical
and information-theoretic limits of the machine it is on.** Every layer here is
a bound with a measured distance to it, so the honest answer is sometimes "there
is no headroom left" and sometimes "there is, and here is how much":

    B / B′  port-optimality — the static µarch issue bound, then the same bound
            measured on this machine's counters
    C       roofline — the memory ceiling and the fraction of it reached
    D       the information-theoretic floor a trigram directory can reach
    E       crest sieve — the one place the index math is new rather than
            borrowed, and fail-closed on `matched ⇒ ¬pruned`
    J       substring/positional index tiers at scale, including the tier
            measured and DECLINED
    L       index quality head-to-head against csearch

Layer A and the CLI surface (H, I) belong to the exact-search face, and the
retrieval and multi-pattern layers (F, G, K) to the kinship package, on the rule
the bench charters state:
**a package certifies what it builds.** A claim measurable by linking the engine
belongs here; a claim needing a running product binary belongs to whichever
package can execute it. Those layers are not missing — they are published by
their owners, over their own corpora, with their own ledgers.

No headline number is scraped yet. A ledger headline is a promise that the
number appears in the same shape in every future mint, and these layers report
distances-to-bound in units that differ per layer (issue slots, GB/s, candidate
bytes). Until the mint stabilizes what it prints, the ledger tracks which layers
shipped — which is the drop it exists to catch — and nothing it would have to
guess at.

Shell reads the roster from this file rather than re-deriving it::

    python3 bench/certificate/guard/profile.py headers
    python3 bench/certificate/guard/profile.py sidecars
"""

from __future__ import annotations

import sys

from charter import Charter, Layer, main

#: Tools that appear as a timed or measured column somewhere in the bundle. The
#: two indexed rivals are here because J and L race real index builds against
#: them; there is no column for a product binary, because irregex ships none to
#: time.
BENCH_TOOLS = frozenset({"csearch", "zoekt"})
#: Tools that build or drive a measurement but are never themselves measured.
#: `llvm-mca` is Layer B's static analyzer and `hyperfine` the wall-clock timer.
SUPPORT_TOOLS = frozenset({"zig", "llvm-mca", "hyperfine"})


CHARTER = Charter(
    package="irregex",
    # The ecosystem's artifact home (`assay/brand.zig`), not a per-package one:
    # every lab binary here writes its layer receipt through the engine's own
    # `home.outDir()`, and a gate that looked somewhere else would judge an empty
    # directory. Separate checkouts already make the artifact home per-package.
    artifact_dir=".gist",
    roster=(
        Layer(
            "B",
            "Layer B — port-optimality",
            "## Layer B — port-optimality (static µarch bound)",
            "portcert.json",
        ),
        # B′ is a `###` subsection spliced by Layer B's own reporter when the
        # machine exposes counters, so it rides B's sidecar and has no header of
        # its own — but the ledger still records whether it was measured.
        Layer("B'", "Layer B′ — port bound, measured"),
        Layer(
            "C",
            "Layer C — roofline",
            "## Layer C — roofline (measured headroom)",
            "roofline.json",
        ),
        Layer(
            "D",
            "Layer D — algorithmic lower bound",
            "## Layer D — algorithmic lower bound (information-theoretic floor)",
            "lowerbound.csv",
        ),
        Layer(
            "E",
            "Layer E — crest sieve",
            "## Layer E — crest sieve (the trigram blind spot, measured)",
            "crest.csv",
        ),
        Layer(
            "J",
            "Layer J — positional + substring index tiers",
            "## Layer J — positional + substring index tiers at scale (vs zoekt)",
            "scale.csv",
        ),
        Layer(
            "L",
            "Layer L — index quality",
            "## Layer L — index quality head-to-head (vs csearch)",
            "indexq.csv",
        ),
    ),
    required_files=(
        "CERTIFICATE.md",
        "machine.json",
        "tool-versions.txt",
        "corpus-manifest.tsv",
    ),
    required_machine_keys=(
        "cpu_model",
        "cpu_count",
        "ram_bytes",
        "os",
        "kernel",
        "filesystem",
        "corpus_id",
        "corpus_file_count",
        "corpus_total_bytes",
        "runs",
        "warmup",
        "roots",
    ),
    required_tools=("zig", "csearch", "zoekt"),
    support_tools=SUPPORT_TOOLS,
    bench_tools=BENCH_TOOLS,
)


if __name__ == "__main__":
    raise SystemExit(main(CHARTER, sys.argv))
