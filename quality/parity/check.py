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
one. Go and Rust both commit a static archive per platform — Go because it has no
`build.rs`, Rust because its `build.rs` prefers a vendored archive over a source
build, and both because a consumer with no Zig toolchain still has to be able to
`go get` or `cargo add` and build. Those archives are build output under version
control, and the only thing asking them to keep up with the engine was a sentence
in a README. It did not work, twice: they went a release behind the day the munch
plane landed, and the default `go test` and `cargo test` paths — the ones CI and
every consumer take — failed at the linker while the source-built path was green.
Rust's went unnoticed far longer, because this gate was told Rust had no archives
to read. So a declared archive is read for the ABI names
it actually carries, by scanning its bytes: the symbol table spells them in ASCII
in ELF, Mach-O and COFF alike, which keeps this a stdlib check rather than an
`nm` that would have to exist and understand three object formats.

A third lane asks the other half of that question. Symbols say whether a plane is
compiled into the archive; they cannot say which BUILD compiled it, and a release
is exactly when those two answers come apart. Cutting 2.1.0 moved the declared
version and left all twelve committed archives stamped with the one before it —
every symbol present, every one of them the previous engine. Rust caught its six
at test time, because its own contract test asserts the linked engine's version
equals the crate's; Go asserted no such thing, so `go get` would have installed a
module claiming a release it did not contain, and the tests would have agreed.
`tools/version_parity.py` cannot reach either, because it reads marked lines in
manifests and an archive has no line to mark. So the archives are held to the
same authority a different way: `build.zig.zon` declares the number, and every
committed archive has to spell it in its own string table.

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
ZON = REPO / "build.zig.zon"

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
# The leading `_?` is Mach-O's underscore convention, and leaving it out made this
# lane lie in both directions. `_` is a word character, so `\b` never matches
# between it and the `i` that follows: on a darwin archive every symbol is spelled
# `_irgx_foo` in the table and NONE of them were seen there. Most were found
# anyway, elsewhere in the file's bytes — which is worse than missing them all,
# because it produced a plausible 98-of-100 and named two real, present, global
# symbols as absent. ELF and COFF carry no prefix, so `_?` costs them nothing.
SHIPPED = re.compile(rb"\b_?(irgx_\w+)")

# The version authority for the whole package — the number every marked manifest
# mirrors and `tools/version_parity.py` holds them to. An archive cannot carry a
# marked line, so it is held to that number a different way: by the copy the engine
# bakes into its own string table.
ZON_VERSION = re.compile(r"\.version\s*=\s*\"([^\"]+)\"")
# NUL-delimited on both sides, because a loose match reads numbers that are nobody's
# release: every one of the twelve archives carries LLVM's `16.0.0`, and three carry
# a loose `21.1.0`. Delimiting is what separates an entry in the engine's string
# table — where its version sits beside PCRE2's `10.47` — from a version-shaped
# substring of something longer. The trailing NUL is a LOOKAHEAD because adjacent
# entries share one: the Linux archives spell `\0 16.0.0 \0 2.0.0 \0`, so consuming
# the delimiter reads every other entry and misses the engine's own behind LLVM's.
STAMP = re.compile(rb"\x00(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?=\x00)")


# ── the signature lane ──
#
# The lanes above ask which names a binding reaches. Nothing asked whether it
# reaches them with the right ARGUMENTS, and only one binding was ever holding
# that line for itself. Go compiles the real header through cgo, so its
# signatures are checked by a C compiler. Python's suite parses the header and
# audits all hundred ctypes prototypes against it — which is where the lesson
# came from: an unset `restype` truncates a `size_t` on every 64-bit host, a
# wrong answer no test under 2^31 can see.
#
# Rust hand-transcribes ninety `extern "C"` declarations and nothing compared
# them to anything. It is also the binding that links a vendored archive
# statically, so a mistranscribed parameter is not a link error, it is a call
# through a signature the engine never agreed to.
#
# What this proves is SHAPE: the number of parameters, how many levels of
# indirection each one has, and the width of every scalar. Not names, which are
# documentation, and not the pointee of an opaque handle, which each host is
# entitled to spell in its own types.
C_DECL = re.compile(r"\b([A-Za-z_][\w \*]*?)\b(irgx_\w+)\s*\(([^;]*?)\)\s*;", re.S)
RUST_DECL = re.compile(r"\bfn (irgx_\w+)\s*\(([^;]*?)\)\s*(?:->\s*([^;{]+?))?\s*;", re.S)
STARS = re.compile(r"\*")
WORD = re.compile(r"[A-Za-z_]\w*")

# One C scalar, and every Rust spelling of it this crate is allowed to use. A
# pointer to one of these is checked to its pointee too, because `*const u32`
# where the header says `const uint8_t *` reads a quarter of the bytes it should.
SCALARS = {
    "uint8_t": {"u8"},
    "uint16_t": {"u16"},
    "uint32_t": {"u32"},
    "uint64_t": {"u64"},
    "int32_t": {"i32"},
    "int64_t": {"i64"},
    "size_t": {"usize"},
    "int": {"c_int", "i32"},
    "char": {"c_char", "i8", "u8"},
    "void": {"c_void"},
}


def split_params(text: str) -> list[str]:
    """One C or Rust parameter list, split on the commas that separate arguments."""
    body = " ".join(text.replace("\n", " ").split()).strip().rstrip(",")
    if body in ("", "void"):
        return []
    return [p for p in re.split(r",(?![^<(]*[>)])", body) if p.strip()]


def c_shape(decl: str) -> tuple[str, int]:
    """A C type as (base, indirections). The base of a `const irgx_walk *` is its struct."""
    words = WORD.findall(re.sub(r"\bconst\b|\bstruct\b", " ", decl))
    return (words[0] if words else "", len(STARS.findall(decl)))


# The binding-name separator, and not the `::` of a path. Splitting on the last
# colon instead read `out: *mut sys::Text` as the type `Text`, which is depth 0 —
# so the lane reported seven correct declarations as passing a struct by value.
BINDS = re.compile(r":(?!:)")


def rust_shape(decl: str) -> tuple[str, int]:
    """A Rust type as (base, indirections), reading the type half of `name: type`."""
    parts = BINDS.split(decl, maxsplit=1)
    typed = parts[1] if len(parts) > 1 else parts[0]
    words = WORD.findall(re.sub(r"\bconst\b|\bmut\b|\bdyn\b", " ", typed))
    return (words[-1] if words else "", len(STARS.findall(typed)))


def agrees(c: tuple[str, int], rust: tuple[str, int]) -> bool:
    """Whether one Rust type could be the C type it stands for."""
    if c == rust:
        return True
    if c[1] != rust[1]:
        return False
    # An opaque handle is the host's own type to name; a scalar never is.
    allowed = SCALARS.get(c[0])
    return allowed is None or rust[0] in allowed


Shapes = dict[str, tuple[tuple[str, int], list[tuple[str, int]]]]


def prototypes(header: str) -> Shapes:
    """Every function the header declares, as (return shape, parameter shapes)."""
    body = COMMENT.sub(" ", header)
    return {
        m.group(2): (c_shape(m.group(1)), [c_shape(p) for p in split_params(m.group(3))])
        for m in C_DECL.finditer(body)
    }


def transcribed(sources: list[str]) -> Shapes:
    """Every `extern "C"` function a Rust binding declares, in the same shape."""
    found: Shapes = {}
    for src in sources:
        for m in RUST_DECL.finditer(code(src, ".rs")):
            ret = rust_shape(m.group(3)) if m.group(3) else ("void", 0)
            found[m.group(1)] = (
                ("void", 0) if ret == ("", 0) else ret,
                [rust_shape(p) for p in split_params(m.group(2))],
            )
    return found


def signature_drift(binding: str, protos: Shapes, decls: Shapes) -> list[str]:
    """Every declaration whose shape is not the shape the header publishes.

    Only names both sides have: coverage is the lane above, and a symbol the
    header does not declare is already a failure there.
    """
    drift = []
    for name in sorted(decls):
        want = protos.get(name)
        if want is None:
            continue
        got = decls[name]
        if len(want[1]) != len(got[1]):
            drift.append(
                f"{binding}: `{name}` takes {len(want[1])} argument(s) in "
                f"include/irgx.h and is declared with {len(got[1])}"
            )
            continue
        for i, (c, rust) in enumerate(zip(want[1], got[1], strict=True), start=1):
            if not agrees(c, rust):
                drift.append(
                    f"{binding}: `{name}` argument {i} is `{c[0]}`{'*' * c[1]} in "
                    f"include/irgx.h and is declared `{rust[0]}` behind "
                    f"{rust[1]} pointer(s)"
                )
        # A declaration with no `->` reads as `void`, which is the one pair that
        # agrees by absence — both sides arrive here as ("void", 0).
        if not agrees(want[0], got[0]):
            drift.append(
                f"{binding}: `{name}` returns `{want[0][0]}`{'*' * want[0][1]} in "
                f"include/irgx.h and is declared to return `{got[0][0]}` behind "
                f"{got[0][1]} pointer(s)"
            )
    return drift


# ── the vendored-header lane ──
#
# Go's cgo compiles `bindings/go/irgx.h`, not `include/irgx.h`. That copy is
# build output under version control, exactly like the archives beside it, and it
# had none of the two lanes they got. A copy that misses a declaration fails loud
# at the compiler; a copy whose STRUCT grew a field in the engine and not here
# links fine and reads the wrong bytes, which is the hazard this header's own
# "gate on the ABI integer, never on a struct size" note is about.
#
# Declarations only. The prose diverges on purpose — the vendored copy is scrubbed
# of the sibling libraries' names — and a lane that read comments would fail on a
# paragraph nobody links against.
def declarations(header: str) -> str:
    """One header reduced to what a compiler reads: no comments, one space."""
    return " ".join(COMMENT.sub(" ", header).split())


def stale_headers(
    canonical: str, copies: dict[str, str], contract: dict | None = None
) -> list[str]:
    """Any committed header copy whose declarations are not the published ones."""
    want = declarations(canonical)
    rows = (contract or {}).get("bindings", {})
    drift = []
    for binding in sorted(copies):
        if declarations(copies[binding]) == want:
            continue
        fix = str(rows.get(binding, {}).get("rebuild", "")).strip()
        how = f"; refresh it with `{fix}`" if fix else ""
        drift.append(
            f"{binding}: the committed header copy declares something other than "
            f"include/irgx.h does — it is the text this binding actually compiles "
            f"against{how}"
        )
    return drift


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
    """Every `irgx_*` name a committed object archive spells in its own bytes.

    Reported under the C name, so a Mach-O `_irgx_foo` and an ELF `irgx_foo` are
    the one symbol they are, and the caller never has to know which format it is
    holding.
    """
    return {m.group(1).decode() for m in SHIPPED.finditer(blob)}


def stamped(blob: bytes) -> set[str]:
    """Every version a committed archive spells in its own string table.

    A set rather than one value, because an archive is a partial link of many
    objects and several of them name a version: PCRE2's, the C compiler's, and the
    engine's own. Which entry is this package's release is not something the bytes
    can say, so the only claim worth making of the set is whether the declared
    version is in it.
    """
    return {m.group(1).decode() for m in STAMP.finditer(blob)}


def declared_version() -> str:
    """The number `build.zig.zon` declares, or empty if it declares none."""
    found = ZON_VERSION.search(ZON.read_text(encoding="utf-8"))
    return found.group(1) if found else ""


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
        # Reporting a stale archive without the command that refreshes it leaves
        # the reader to guess, and the guess used to be wired into this file as
        # Go's script — which was the wrong answer for every other binding.
        if glob and not str(row.get("rebuild", "")).strip():
            faults.append(
                f"[bindings] {name}: declares `archives` and no `rebuild` — "
                f"a staleness this gate cannot tell you how to fix"
            )
        # A dialect nothing can parse is the same false pass as a glob matching
        # nothing: the lane reads no declarations and approves them all.
        dialect = str(row.get("declares", "")).strip()
        if dialect and dialect not in DIALECTS:
            faults.append(
                f"[bindings] {name}: `declares` is {dialect!r}, which no parser here "
                f"reads — known dialects are {', '.join(sorted(DIALECTS))}"
            )
        copy = str(row.get("header", "")).strip()
        if copy and not (REPO / copy).is_file():
            faults.append(
                f"[bindings] {name}: `header` names {copy!r}, which is not a file — "
                f"a lane that reads nothing passes everything"
            )
        if copy and not str(row.get("rebuild", "")).strip():
            faults.append(
                f"[bindings] {name}: declares `header` and no `rebuild` — "
                f"a staleness this gate cannot tell you how to fix"
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


# Which languages this gate can read declarations out of. Go is absent on
# purpose: cgo compiles `include/irgx.h` itself, so a C compiler already holds
# its signatures to the header on every build, and Python's own suite audits all
# hundred ctypes prototypes against the same file. Rust is the binding that
# transcribes them by hand with nothing watching.
DIALECTS = {"rust": lambda sources: transcribed(sources)}


def stale_archives(
    abi: set[str],
    shipped: dict[str, dict[str, set[str]]],
    contract: dict | None = None,
) -> list[str]:
    """Any committed archive that is older than the ABI it ships.

    Reported per archive rather than per symbol: the whole file is one build, so a
    hundred missing names are one fact and one command fixes them. Naming the
    first few is enough to recognize which plane is absent.

    The command comes from the binding's own `rebuild`, never from here. Every
    binding that ships an engine has its own vendoring script, and this message
    naming Go's was wrong the moment a second binding was looked at.
    """
    rows = (contract or {}).get("bindings", {})
    drift = []
    for binding in sorted(shipped):
        fix = str(rows.get(binding, {}).get("rebuild", "")).strip()
        how = f"; rebuild it with `{fix}`" if fix else ""
        for name in sorted(shipped[binding]):
            missing = sorted(abi - shipped[binding][name])
            if not missing:
                continue
            shown = ", ".join(f"`{s}`" for s in missing[:4])
            more = f" (+{len(missing) - 4} more)" if len(missing) > 4 else ""
            drift.append(
                f"{binding}: the committed `{name}` is missing {len(missing)} ABI "
                f"symbol(s) — {shown}{more}. It is build output that went behind "
                f"the engine{how}"
            )
    return drift


def stale_stamps(
    want: str,
    stamps: dict[str, dict[str, set[str]]],
    contract: dict | None = None,
) -> list[str]:
    """Any committed archive that came out of a build before the declared version.

    The complement of `stale_archives`, and the half that release nearly shipped
    without: symbols say whether a PLANE is compiled in, the version says WHICH
    BUILD compiled it. An archive re-minted mid-cycle carries every symbol and the
    previous number, so it passes the symbol lane and fails this one — which is the
    exact state a release branch is in after the bot moves the number and nothing
    re-mints the build output that number describes.
    """
    rows = (contract or {}).get("bindings", {})
    drift = []
    for binding in sorted(stamps):
        fix = str(rows.get(binding, {}).get("rebuild", "")).strip()
        how = f"; rebuild it with `{fix}`" if fix else ""
        for name in sorted(stamps[binding]):
            found = stamps[binding][name]
            if want in found:
                continue
            # What it does carry, not what it was built at: the set holds the C
            # compiler's version too, and guessing which entry is the engine's is
            # how a report starts being wrong.
            said = ", ".join(sorted(found)) or "no version string at all"
            drift.append(
                f"{binding}: the committed `{name}` does not carry {want} — it carries "
                f"{said}. It is build output the release bot cannot rewrite{how}"
            )
    return drift


def audit(
    abi: set[str],
    header: str,
    per_binding: dict[str, set[str]],
    contract: dict,
    shipped: dict[str, dict[str, set[str]]] | None = None,
    stamps: dict[str, dict[str, set[str]]] | None = None,
    version: str = "",
    declares: dict[str, Shapes] | None = None,
    copies: dict[str, str] | None = None,
) -> list[str]:
    """Every way the ABI and its bindings currently disagree.

    Seven questions, in the order a symbol travels: does the header declare what
    the linker publishes, does every binding reach it, does every waiver still
    name a real gap, does a hand-transcribed declaration have the shape the
    header publishes, does a committed header copy still declare it, and — for a
    binding that ships its own engine — does that engine carry the whole ABI, and
    did it come out of the build this tree declares. The stale waiver matters as
    much as the first — a waiver kept after the gap closed reads as a live design
    decision and is a stale note, which is how a reviewer learns to skim the
    block.

    The version lane runs only when a version is given, so a caller holding a
    fixture rather than a tree still gets the other four.
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
    protos = prototypes(header)
    for binding, decls in sorted((declares or {}).items()):
        drift += signature_drift(binding, protos, decls)
    drift += stale_headers(header, copies or {}, contract)
    drift += stale_archives(abi, shipped or {}, contract)
    return drift + (stale_stamps(version, stamps or {}, contract) if version else [])


def sources_of(row: dict) -> list[str]:
    """Every language file under a binding's source root."""
    root = REPO / str(row["sources"])
    return [
        p.read_text(encoding="utf-8", errors="replace")
        for p in sorted(root.rglob(f"*{row['suffix']}"))
    ]


def archive_paths(row: dict) -> list[Path]:
    """Every archive a binding commits, or none at all if it ships no engine.

    By PATH, not by filename: Go names its six for their platforms, but Rust puts
    six identically-named `libirgx.a` under `vendor/<target>/`, so a filename key
    collapses them to one and silently stops reading the other five. A path also
    says which target is stale, which is the thing you need to know next.
    """
    glob = str(row.get("archives", "")).strip()
    return sorted(REPO.glob(glob)) if glob else []


def archives_of(row: dict) -> dict[str, set[str]]:
    """Which ABI names each archive a binding commits actually carries."""
    return {str(p.relative_to(REPO)): carried(p.read_bytes()) for p in archive_paths(row)}


def versions_of(row: dict) -> dict[str, set[str]]:
    """Which build each archive a binding commits came out of."""
    return {str(p.relative_to(REPO)): stamped(p.read_bytes()) for p in archive_paths(row)}


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
    stamps = {
        name: found for name, row in contract["bindings"].items() if (found := versions_of(row))
    }
    declares = {
        name: DIALECTS[str(row["declares"]).strip()](sources_of(row))
        for name, row in contract["bindings"].items()
        if str(row.get("declares", "")).strip()
    }
    copies = {
        name: (REPO / str(row["header"]).strip()).read_text(encoding="utf-8")
        for name, row in contract["bindings"].items()
        if str(row.get("header", "")).strip()
    }
    version = declared_version()
    if not version:
        print(f"parity: {ZON.name} declares no version — the authority is broken", file=sys.stderr)
        return 2

    drift = audit(
        abi,
        HEADER.read_text(encoding="utf-8"),
        per_binding,
        contract,
        shipped,
        stamps,
        version,
        declares,
        copies,
    )
    for line in drift:
        print(f"parity: {line}", file=sys.stderr)
    if drift:
        return 1

    waived = contract.get("waived", {})
    per = " · ".join(
        f"{name} {len(abi) - len(waived.get(name, {}))}/{len(abi)}" for name in sorted(per_binding)
    )
    carrying = sum(len(found) for found in shipped.values())
    ships = f", {carrying} committed archive(s) whole and stamped {version}" if carrying else ""
    shaped = sum(len(d) for d in declares.values())
    shapes = f", {shaped} transcribed declaration(s) shaped like the header" if shaped else ""
    plural = "" if len(copies) == 1 else "s"
    vendored = f", {len(copies)} vendored header{plural} current" if copies else ""
    print(
        f"parity: {len(abi)} ABI symbols reached by every binding ({per}){shapes}{vendored}{ships}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
