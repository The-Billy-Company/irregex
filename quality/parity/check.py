#!/usr/bin/env python3
"""The cross-binding gate: does every binding reach the whole ABI?

Every other gate in this package is VERTICAL — one artifact judged against one
contract. `quality/surface/check.py` asks whether the Zig root exports what it
promised; each binding's own tests ask whether it works. Nothing ever compared
the bindings to EACH OTHER, and that is exactly the shape of the drift it let
through: three bindings each independently correct against the header, with Go
missing the whole windowed-search plane, Rust missing the three functions that
make the cancellation token its own request struct has a field for, and Python
complete — so at any moment some binding could do the thing and none of them
could all do it.

So this gate is horizontal. The authority is `src/surface/ffi/exports.zig`,
because that is what the linker actually publishes; the header is checked against
it too, since a symbol no header declares is unreachable by any C host at all.
Then every binding is asked for the same list, and a gap has to be a waiver with
a reason in `contract/bindings.toml` or it fails.

Text over toolchain, like the gates beside it. The question is which names a
source file mentions, so compiling three toolchains to answer it would tie a
millisecond check to an installed Go, Python, and Rust it has no other use for.

What it proves is REACHABILITY, and not one step further: that a host writing
this binding's language can get at the symbol. Whether the binding's ergonomic
wrapper then chooses to use it is a deeper question, and deliberately not this
one — Python binds `irgx_pattern_windows` in its ctypes table and implements
`endpos` by truncating the haystack instead, which is a defensible design and
not a gap. The failure this catches is the other thing: a symbol no code in the
binding could call at all, however unsafe it was willing to be.

There is a second lane, for a binding that ships the engine rather than linking
one. The Go module commits a static archive per platform, because Go has no
`build.rs` and a consumer with no Zig has to be able to `go get` and build; those
archives are build output under version control, and the only thing asking them to
keep up with the engine was a sentence in a README. It did not work: the archives
went a release behind the day the munch plane landed, and the default `go test`
path — the one CI and every consumer takes — failed at the linker while the
source-built path was green. Same species as the Rust `build.rs` watching a
directory whose mtime never moved. So a declared archive is read for the ABI names
it actually carries, by scanning its bytes: the symbol table spells them in ASCII
in ELF, Mach-O and COFF alike, which keeps this a stdlib check rather than an
`nm` that would have to exist and understand three object formats.

Exit 0 clean, 1 on drift, 2 on a malformed contract.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import tomllib

REPO = Path(__file__).resolve().parents[2]
CONTRACT = REPO / "contract" / "bindings.toml"
EXPORTS = REPO / "src" / "surface" / "ffi" / "exports.zig"
HEADER = REPO / "include" / "irgx.h"

# The linker's own list. `export fn` is the only thing that produces a C symbol,
# so this is the ABI by construction rather than by description.
EXPORTED = re.compile(r"^\s*export fn (irgx_\w+)", re.M)
# Any mention of the name, in any language. A binding that names a symbol it does
# not really call is conceivable; a binding that calls one it never names is not.
MENTION = re.compile(r"\birgx_\w+")

# Comments are stripped before a binding is asked what it names, because prose
# ABOUT a symbol is the false pass this gate would otherwise hand itself: Rust's
# `sys.rs` carries the sentence "`irgx_find_all` is deliberately not declared",
# and a mention rule that reads it concludes the symbol is bound. A deliberate
# omission is exactly what a [waived] row is for, so the sentence should fail and
# the row should pass. Line comments in all three languages plus C-style blocks;
# a symbol only reachable inside a comment is not reachable.
COMMENT = re.compile(r"//[^\n]*|#[^\n]*|/\*.*?\*/", re.S)

# ...with one exception, which is not an exception to the reasoning at all. cgo's
# preamble is SPELLED as a block comment and COMPILED as C, and in this Go
# binding it is the only place the engine is called at all: `bridge.go` wraps
# each `irgx_*` in a static C shim so the fault read lands on the same pinned
# thread as the call. Blanking it reported a binding with a complete ABI as
# reaching none of it — the inverse of the Rust false pass, from the same rule.
# So the preamble is read back as code. A `/* */` genuinely used as prose in Go
# is still blanked, since only the block adjacent to `import "C"` is compiled.
CGO_PREAMBLE = re.compile(r"/\*(.*?)\*/\s*import\s+\"C\"", re.S)

# The same name rule against object bytes. Waivers do not apply on this lane and
# it needs no per-binding spelling: an archive is not a host reaching for a symbol,
# it is the engine, and the engine either has the plane compiled into it or is
# older than the tree that ships it.
SHIPPED = re.compile(rb"\birgx_\w+")


def code(src: str, suffix: str) -> str:
    """`src` with its comments blanked, newlines kept so nothing else shifts."""
    body = COMMENT.sub(lambda m: "\n" * m.group().count("\n"), src)
    if suffix == ".go":
        body += "".join(m.group(1) for m in CGO_PREAMBLE.finditer(src))
    return body


def exported(src: str) -> set[str]:
    """The symbols `exports.zig` publishes to the linker."""
    return set(EXPORTED.findall(src))


def mentioned(sources: list[str], suffix: str) -> set[str]:
    """Every `irgx_*` name a binding's own sources name in code."""
    return {name for src in sources for name in MENTION.findall(code(src, suffix))}


def declared(header: str) -> set[str]:
    """Every `irgx_*` name the public header mentions."""
    return set(MENTION.findall(header))


def carried(blob: bytes) -> set[str]:
    """Every `irgx_*` name a committed object archive spells in its own bytes."""
    return {m.group().decode() for m in SHIPPED.finditer(blob)}


def contract_faults(contract: dict) -> list[str]:
    """Whatever is wrong with the contract itself, before it is used to judge."""
    faults = []
    bindings = contract.get("bindings")
    if not isinstance(bindings, dict) or not bindings:
        return ["contract has no [bindings] table"]
    for name, row in bindings.items():
        if not isinstance(row, dict):
            faults.append(f"[bindings] {name}: not a table")
            continue
        for key in ("sources", "suffix", "why"):
            if not str(row.get(key, "")).strip():
                faults.append(f"[bindings] {name}: no `{key}`")
        # A glob matching nothing is the false pass this lane is most exposed to:
        # rename the archives and the check keeps passing, having read none of
        # them. Optional key, but a present one has to find something.
        glob = str(row.get("archives", "")).strip()
        if glob and not any(REPO.glob(glob)):
            faults.append(
                f"[bindings] {name}: `archives` glob {glob!r} matches no file — "
                f"a lane that reads nothing passes everything"
            )
    waived = contract.get("waived", {})
    if not isinstance(waived, dict):
        return [*faults, "[waived] is not a table"]
    for binding, rows in waived.items():
        if binding not in bindings:
            faults.append(f"[waived.{binding}] is not a binding in [bindings]")
            continue
        if not isinstance(rows, dict):
            faults.append(f"[waived.{binding}] is not a table")
            continue
        faults += [
            f"[waived.{binding}] {symbol}: no `why` — a waiver that cannot say "
            f"what the host does instead is the gap, not a decision"
            for symbol, row in sorted(rows.items())
            if not isinstance(row, dict) or not str(row.get("why", "")).strip()
        ]
    return faults


def stale_archives(abi: set[str], shipped: dict[str, dict[str, set[str]]]) -> list[str]:
    """Any committed archive that is older than the ABI it ships.

    Reported per archive rather than per symbol: the whole file is one build, so a
    hundred missing names are one fact and one command fixes them. Naming the
    first few is enough to recognize which plane is absent.
    """
    drift = []
    for binding in sorted(shipped):
        for name in sorted(shipped[binding]):
            missing = sorted(abi - shipped[binding][name])
            if not missing:
                continue
            shown = ", ".join(f"`{s}`" for s in missing[:4])
            more = f" (+{len(missing) - 4} more)" if len(missing) > 4 else ""
            drift.append(
                f"{binding}: the committed `{name}` is missing {len(missing)} ABI "
                f"symbol(s) — {shown}{more}. It is build output that went behind the "
                f"engine; rebuild it (Go: `python3 scripts/vendor_libraries.py`)"
            )
    return drift


def audit(
    abi: set[str],
    header: str,
    per_binding: dict[str, set[str]],
    contract: dict,
    shipped: dict[str, dict[str, set[str]]] | None = None,
) -> list[str]:
    """Every way the ABI and its bindings currently disagree.

    Four questions, in the order a symbol travels: does the header declare what
    the linker publishes, does every binding reach it, does every waiver still
    name a real gap, and does a binding that ships its own engine ship a current
    one. The stale waiver matters as much as the first — a waiver kept after the
    gap closed reads as a live design decision and is a stale note, which is how
    a reviewer learns to skim the block.
    """
    drift = [
        f"`{name}` is exported but `include/irgx.h` never declares it — no C host "
        f"can reach it, so either declare it or stop exporting it"
        for name in sorted(abi - declared(header))
    ]

    waived = contract.get("waived", {})
    for binding in sorted(per_binding):
        excused = set(waived.get(binding, {}))
        missing = abi - per_binding[binding] - excused
        drift += [
            f"{binding}: `{name}` is in the ABI and this binding never names it — "
            f"bind it, or add a [waived.{binding}] row saying what the host does instead"
            for name in sorted(missing)
        ]
        stale = sorted(excused & per_binding[binding])
        drift += [
            f"{binding}: `{name}` is waived but the binding does bind it — "
            f"delete the [waived.{binding}] row"
            for name in stale
        ]
        gone = sorted(excused - abi)
        drift += [
            f"{binding}: `{name}` is waived but the ABI no longer exports it — "
            f"delete the [waived.{binding}] row"
            for name in gone
        ]
    return drift + stale_archives(abi, shipped or {})


def sources_of(row: dict) -> list[str]:
    """Every language file under a binding's source root."""
    root = REPO / str(row["sources"])
    return [
        p.read_text(encoding="utf-8", errors="replace")
        for p in sorted(root.rglob(f"*{row['suffix']}"))
    ]


def archives_of(row: dict) -> dict[str, set[str]]:
    """What each archive a binding commits actually carries, keyed by filename."""
    glob = str(row.get("archives", "")).strip()
    if not glob:
        return {}
    return {p.name: carried(p.read_bytes()) for p in sorted(REPO.glob(glob))}


def main() -> int:
    if not CONTRACT.is_file():
        print(f"parity: no contract at {CONTRACT}", file=sys.stderr)
        return 2
    try:
        contract = tomllib.loads(CONTRACT.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as e:
        print(f"parity: {CONTRACT.name} is malformed — {e}", file=sys.stderr)
        return 2

    faults = contract_faults(contract)
    if faults:
        for line in faults:
            print(f"parity: {line}", file=sys.stderr)
        return 2

    abi = exported(EXPORTS.read_text(encoding="utf-8"))
    if not abi:
        print(f"parity: {EXPORTS} exports nothing — the extractor is broken", file=sys.stderr)
        return 2

    per_binding = {
        name: mentioned(sources_of(row), str(row["suffix"]))
        for name, row in contract["bindings"].items()
    }
    shipped = {
        name: found for name, row in contract["bindings"].items() if (found := archives_of(row))
    }
    drift = audit(abi, HEADER.read_text(encoding="utf-8"), per_binding, contract, shipped)
    for line in drift:
        print(f"parity: {line}", file=sys.stderr)
    if drift:
        return 1

    waived = contract.get("waived", {})
    per = " · ".join(
        f"{name} {len(abi) - len(waived.get(name, {}))}/{len(abi)}" for name in sorted(per_binding)
    )
    carrying = sum(len(found) for found in shipped.values())
    ships = f", {carrying} committed archive(s) current" if carrying else ""
    print(f"parity: {len(abi)} ABI symbols reached by every binding ({per}){ships}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
