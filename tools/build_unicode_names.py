#!/usr/bin/env python3
r"""Lower the pinned UCD character names into src/kernel/regex/unicode/names.gen.zig.

`\N{LATIN SMALL LETTER A}` is a name lookup, so the engine needs the Unicode
character-name database — 40k names, ~1 MB of text if stored plainly. This
generator lowers it to ~430 KB by front-coding the *sorted* name list: a sorted
neighbor shares a long byte prefix ("LATIN SMALL LETTER A" then "LATIN SMALL
LETTER A WITH ACUTE"), so each entry stores only the prefix length it shares
with the entry before it plus its own differing tail. That beat a word-lexicon
encoding by 2x when both were measured against the real data (431 KB vs 831 KB),
and it is also simpler: comparisons are plain byte compares with no indirection.

Names are stored in blocks of 32. The first entry of a block is written in full,
so a lookup binary-searches the block heads and then scans one block forward,
reconstructing at most 31 names. That is the whole index — no hash, no perfect
hash, and therefore no chance that a typo'd name silently resolves to some other
character, which a hash-only table could not rule out.

Every byte of the emitted stream is printable: the two length fields are biased
by 0x20, and a name's own charset is only `A-Z 0-9 SPACE HYPHEN`. So the
generated Zig holds one readable string literal in which the names are legible
in a diff, rather than a wall of hex escapes or an opaque embedded binary.

Three name families are NOT stored, because they are computed: Hangul syllables
(UAX #44 rule NR1) and the `PREFIX-XXXX` ideograph ranges (rule NR2) would add
~97k entries that a dozen lines of arithmetic reproduce exactly. Surrogates and
private-use codepoints have no names at all and must stay unresolvable.

The emitted text is passed through `zig fmt` before it is compared or written.
This file is checked by `zig fmt --check` like every other `.zig` in the tree,
and the formatter owns decisions no generator should try to predict — where `++`
sits relative to its operands, and the column widths it pads a numeric grid to.
Asking it is exact; reimplementing it would drift the first time it changed.

It is stdlib-only and deterministic, so
`python3 tools/build_unicode_names.py --check` is a sound drift gate.

Run: python3 tools/build_unicode_names.py           # writes the .gen.zig
     python3 tools/build_unicode_names.py --check   # diff-only (drift gate)
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

UNICODE_VERSION = "16.0.0"
HERE = Path(__file__).resolve().parent
UCD = HERE / "ucd"
OUT = HERE.parent / "src" / "kernel" / "regex" / "unicode" / "names.gen.zig"

BLOCK = 32
LEN_BIAS = 0x20  # keeps both length fields printable (max name is 88 bytes)

# UAX #44 Table 4 — the NR2 prefixes, paired with the UnicodeData range labels
# that carry them. A range whose label is absent here is deliberately nameless
# (surrogates, private use): `\N{}` must not resolve those.
NR2_PREFIXES = {
    "CJK Ideograph": "CJK UNIFIED IDEOGRAPH-",
    "CJK Ideograph Extension A": "CJK UNIFIED IDEOGRAPH-",
    "CJK Ideograph Extension B": "CJK UNIFIED IDEOGRAPH-",
    "CJK Ideograph Extension C": "CJK UNIFIED IDEOGRAPH-",
    "CJK Ideograph Extension D": "CJK UNIFIED IDEOGRAPH-",
    "CJK Ideograph Extension E": "CJK UNIFIED IDEOGRAPH-",
    "CJK Ideograph Extension F": "CJK UNIFIED IDEOGRAPH-",
    "CJK Ideograph Extension G": "CJK UNIFIED IDEOGRAPH-",
    "CJK Ideograph Extension H": "CJK UNIFIED IDEOGRAPH-",
    "CJK Ideograph Extension I": "CJK UNIFIED IDEOGRAPH-",
    "Tangut Ideograph": "TANGUT IDEOGRAPH-",
    "Tangut Ideograph Supplement": "TANGUT IDEOGRAPH-",
}
HANGUL_LABEL = "Hangul Syllable"


def read_unicode_data() -> tuple[dict[str, int], list[tuple[int, int, str]]]:
    """`{NAME: cp}` for explicitly named codepoints, plus the algorithmic ranges.

    A `<...>` name is not a name — it is UnicodeData's marker for a codepoint
    with none (`<control>`) or for the endpoints of a range whose names are
    derived (`<CJK Ideograph, First>`).
    """
    names: dict[str, int] = {}
    ranges: list[tuple[int, int, str]] = []
    pending: tuple[int, str] | None = None
    for raw in (UCD / "UnicodeData.txt").read_text().splitlines():
        if not raw:
            continue
        fields = raw.split(";")
        cp, name = int(fields[0], 16), fields[1]
        if name.startswith("<") and name.endswith(">"):
            label = name[1:-1]
            if label.endswith(", First"):
                pending = (cp, label[: -len(", First")])
            elif label.endswith(", Last") and pending is not None:
                ranges.append((pending[0], cp, pending[1]))
                pending = None
            continue
        names[name] = cp
    return names, ranges


def read_aliases(names: dict[str, int]) -> int:
    """Fold NameAliases into `names`, returning how many were new.

    All five alias types are included, because `re` resolves all five — `\\N{NULL}`
    and `\\N{LF}` both work there, and a control character has no other spelling.
    A real name always wins a collision: an alias may add a way to say a
    character, never take one over.
    """
    added = 0
    for raw in (UCD / "NameAliases.txt").read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [f.strip() for f in line.split(";")]
        if len(fields) < 2:
            continue
        alias = fields[1]
        if alias in names:
            continue
        names[alias] = int(fields[0], 16)
        added += 1
    return added


def front_code(sorted_names: list[str]) -> tuple[bytes, list[int]]:
    """Front-code the sorted names into one printable stream + block offsets.

    Per block: `[len+bias][head bytes]`, then up to 31 entries of
    `[shared+bias][tail_len+bias][tail bytes]`.
    """
    out = bytearray()
    offsets: list[int] = []
    prev = ""
    for i, name in enumerate(sorted_names):
        if i % BLOCK == 0:
            offsets.append(len(out))
            out.append(len(name) + LEN_BIAS)
            out += name.encode("ascii")
            prev = name
            continue
        shared = 0
        limit = min(len(prev), len(name))
        while shared < limit and prev[shared] == name[shared]:
            shared += 1
        tail = name[shared:]
        out.append(shared + LEN_BIAS)
        out.append(len(tail) + LEN_BIAS)
        out += tail.encode("ascii")
        prev = name
    return bytes(out), offsets


def zig_string(blob: bytes, chunk: int = 4096) -> str:
    """`blob` as `++`-joined Zig string literals. Every byte is printable by
    construction, so only `"` and `\\` need escaping. The operator trails its
    left operand because that is where `zig fmt` puts it, and this file is
    checked by `zig fmt --check` like any other."""
    pieces = []
    for start in range(0, len(blob), chunk):
        buf = []
        for b in blob[start : start + chunk]:
            ch = chr(b)
            buf.append("\\" + ch if ch in '"\\' else ch)
        pieces.append('    "' + "".join(buf) + '"')
    return " ++\n".join(pieces)


def render(names: dict[str, int], ranges: list[tuple[int, int, str]], alias_count: int) -> str:
    sorted_names = sorted(names)
    blob, offsets = front_code(sorted_names)
    cps = [names[n] for n in sorted_names]
    longest = max(len(n) for n in sorted_names)

    nr2: list[tuple[int, int, str]] = [
        (lo, hi, NR2_PREFIXES[label]) for lo, hi, label in ranges if label in NR2_PREFIXES
    ]
    hangul = next(((lo, hi) for lo, hi, label in ranges if label == HANGUL_LABEL), None)
    if hangul is None:
        raise SystemExit("UnicodeData.txt has no Hangul Syllable range — refusing to emit")

    lines: list[str] = []
    add = lines.append
    add(
        "//! GENERATED by tools/build_unicode_names.py from the pinned UCD "
        f"{UNICODE_VERSION}. DO NOT EDIT."
    )
    add("//!")
    add(f"//! {len(sorted_names)} names ({alias_count} of them NameAliases), front-coded in")
    add(f"//! blocks of {BLOCK}. See the generator's docstring for the encoding and why it")
    add("//! is this one; `names.zig` is the lookup over it.")
    add("")
    add(f'pub const unicode_version = "{UNICODE_VERSION}";')
    add("")
    add("/// Entries per block: the first is stored whole, the rest front-coded against")
    add("/// the entry before them.")
    add(f"pub const block = {BLOCK};")
    add("/// Both length fields are biased by this so every byte of `blob` is printable.")
    add(f"pub const len_bias = 0x{LEN_BIAS:02X};")
    add("/// The longest name in the database — a query longer than this cannot match.")
    add(f"pub const longest_name = {longest};")
    add(f"pub const count = {len(sorted_names)};")
    add("")
    add("/// Sorted, front-coded name stream. Byte-sorted order is also *name* order,")
    add("/// which is what makes the block heads binary-searchable.")
    add("pub const blob: []const u8 =")
    add(zig_string(blob))
    add(";")
    add("")
    add("/// Byte offset of each block's head entry within `blob`.")
    add("pub const block_offsets = [_]u32{")
    for i in range(0, len(offsets), 16):
        add("    " + " ".join(f"{v}," for v in offsets[i : i + 16]))
    add("};")
    add("")
    add("/// The codepoint each name denotes, in the same sorted order.")
    add("pub const codepoints = [_]u32{")
    for i in range(0, len(cps), 16):
        add("    " + " ".join(f"0x{v:X}," for v in cps[i : i + 16]))
    add("};")
    add("")
    add("/// UAX #44 rule NR2: ranges whose names are `PREFIX` + the codepoint in hex.")
    add("pub const derived = [_]struct { lo: u21, hi: u21, prefix: []const u8 }{")
    for lo, hi, prefix in nr2:
        add(f'    .{{ .lo = 0x{lo:X}, .hi = 0x{hi:X}, .prefix = "{prefix}" }},')
    add("};")
    add("")
    add("/// UAX #44 rule NR1: the Hangul syllable block, whose names are composed from")
    add("/// the jamo short names below.")
    add(f"pub const hangul_lo: u21 = 0x{hangul[0]:X};")
    add(f"pub const hangul_hi: u21 = 0x{hangul[1]:X};")
    add("")
    add("/// Jamo short names, in Unicode's own order — index IS the jamo index. The")
    add("/// empty leading-consonant slot is real (ieung is written as nothing).")
    add("pub const jamo_l = [_][]const u8{")
    add('    "G", "GG", "N", "D", "DD", "R", "M", "B", "BB", "S", "SS", "",')
    add('    "J", "JJ", "C", "K", "T", "P", "H",')
    add("};")
    add("pub const jamo_v = [_][]const u8{")
    add('    "A", "AE", "YA", "YAE", "EO", "E", "YEO", "YE", "O", "WA", "WAE",')
    add('    "OE", "YO", "U", "WEO", "WE", "WI", "YU", "EU", "YI", "I",')
    add("};")
    add("pub const jamo_t = [_][]const u8{")
    add('    "", "G", "GG", "GS", "N", "NJ", "NH", "D", "L", "LG", "LM", "LB",')
    add('    "LS", "LT", "LP", "LH", "M", "B", "BS", "S", "SS", "NG", "J", "C",')
    add('    "K", "T", "P", "H",')
    add("};")
    add("")
    return "\n".join(lines)


def zig_fmt(text: str) -> str:
    """`text` as `zig fmt` would write it. Fails loud rather than emitting
    unformatted Zig, which would only surface later as a `zig fmt --check` CI
    failure over a file nobody is supposed to hand-edit."""
    zig = shutil.which("zig")
    if zig is None:
        print("zig is not on PATH, and it formats what this writes", file=sys.stderr)
        raise SystemExit(1)
    done = subprocess.run(
        [zig, "fmt", "--stdin"], input=text, capture_output=True, text=True, check=False
    )
    if done.returncode != 0:
        print(f"zig fmt refused the generated source:\n{done.stderr}", file=sys.stderr)
        raise SystemExit(1)
    return done.stdout


def main() -> int:
    check = "--check" in sys.argv[1:]
    names, ranges = read_unicode_data()
    alias_count = read_aliases(names)
    text = zig_fmt(render(names, ranges, alias_count))
    if check:
        if not OUT.exists():
            print(f"drift: {OUT} does not exist", file=sys.stderr)
            return 1
        if OUT.read_text() != text:
            print(f"drift: {OUT} does not match the pinned UCD {UNICODE_VERSION}", file=sys.stderr)
            return 1
        print(f"ok: {OUT} matches the pinned UCD {UNICODE_VERSION}")
        return 0
    OUT.write_text(text)
    print(f"wrote {OUT} ({len(text):,} bytes source, {len(names):,} names)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
