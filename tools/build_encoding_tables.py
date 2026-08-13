#!/usr/bin/env python3
r"""Lower the pinned WHATWG Encoding Standard indexes into a Zig decode-table module.

The engine matches UTF-8 bytes; to honor `-E`/`--encoding` for the legacy code pages
the way ripgrep (which rides encoding_rs) does, it transcodes a source encoding to
UTF-8 before matching. This generator is the single source of the *decode* tables:
it reads the vendored WHATWG index files (provenance in tools/whatwg/README.md) and
emits one generated Zig module of pointer -> code point tables plus the authoritative
label -> encoding map from `encodings.json`. The decoder state machines that consume
these tables live in `src/corpus/read/encoding.zig` (one per WHATWG algorithm).

Only the *decode* direction is lowered (the engine never encodes to a legacy page),
so a single dense `pointer -> code point` array per index is all that is needed.
Tables are emitted as little-endian byte blobs (one Zig string literal each) read
back via `std.mem.readInt` — this keeps the generated file compact and fast to
compile while staying endianness-safe and byte-diffable. A code point of 0 marks an
undefined pointer (verified: no index maps any pointer to U+0000), so the decoder
treats 0 as "no mapping" and emits U+FFFD, matching encoding_rs's lossy decode.

stdlib-only and deterministic, so `build_encoding_tables.py --check` is a sound
regenerate-and-diff drift gate (CI-hermetic; no network).

Run: python3 tools/build_encoding_tables.py            # writes the .gen.zig
     python3 tools/build_encoding_tables.py --check    # diff-only (drift gate)
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
WHATWG = HERE / "whatwg"
OUT = HERE.parent / "src" / "corpus" / "read" / "encoding_tables.gen.zig"

# WHATWG single-byte encodings whose 128-entry (0x80..0xFF) index the engine lowers.
# ISO-8859-8-I shares ISO-8859-8's index; x-mac-ukrainian shares x-mac-cyrillic;
# windows-1252 subsumes ISO-8859-1/ASCII; windows-1254 subsumes ISO-8859-9;
# windows-874 subsumes ISO-8859-11/TIS-620 — all handled by the label map below.
SINGLE_BYTE = [
    "ibm866",
    "iso-8859-2",
    "iso-8859-3",
    "iso-8859-4",
    "iso-8859-5",
    "iso-8859-6",
    "iso-8859-7",
    "iso-8859-8",
    "iso-8859-10",
    "iso-8859-13",
    "iso-8859-14",
    "iso-8859-15",
    "iso-8859-16",
    "koi8-r",
    "koi8-u",
    "macintosh",
    "windows-874",
    "windows-1250",
    "windows-1251",
    "windows-1252",
    "windows-1253",
    "windows-1254",
    "windows-1255",
    "windows-1256",
    "windows-1257",
    "windows-1258",
    "x-mac-cyrillic",
]

# Multi-byte decode indexes (dense pointer -> code point). Widths chosen from the
# measured max code point: only Big5 reaches the supplementary planes (U+2F9D4).
MULTI_BYTE = {
    "gb18030": 16,
    "big5": 32,
    "jis0208": 16,
    "jis0212": 16,
    "euc-kr": 16,
}

# WHATWG canonical name -> the engine's Encoding enum tag (see encoding.zig). GBK
# decodes through the gb18030 decoder (spec 10.1.1); the UTF-16 family + auto/none
# are handled by ingest.zig, so their labels are overridden / injected below.
NAME_TO_TAG = {
    "UTF-8": "utf8",
    "IBM866": "ibm866",
    "ISO-8859-2": "iso_8859_2",
    "ISO-8859-3": "iso_8859_3",
    "ISO-8859-4": "iso_8859_4",
    "ISO-8859-5": "iso_8859_5",
    "ISO-8859-6": "iso_8859_6",
    "ISO-8859-7": "iso_8859_7",
    "ISO-8859-8": "iso_8859_8",
    "ISO-8859-8-I": "iso_8859_8",
    "ISO-8859-10": "iso_8859_10",
    "ISO-8859-13": "iso_8859_13",
    "ISO-8859-14": "iso_8859_14",
    "ISO-8859-15": "iso_8859_15",
    "ISO-8859-16": "iso_8859_16",
    "KOI8-R": "koi8_r",
    "KOI8-U": "koi8_u",
    "macintosh": "macintosh",
    "windows-874": "windows_874",
    "windows-1250": "windows_1250",
    "windows-1251": "windows_1251",
    "windows-1252": "windows_1252",
    "windows-1253": "windows_1253",
    "windows-1254": "windows_1254",
    "windows-1255": "windows_1255",
    "windows-1256": "windows_1256",
    "windows-1257": "windows_1257",
    "windows-1258": "windows_1258",
    "x-mac-cyrillic": "x_mac_cyrillic",
    "GBK": "gb18030",
    "gb18030": "gb18030",
    "Big5": "big5",
    "EUC-JP": "euc_jp",
    "ISO-2022-JP": "iso_2022_jp",
    "Shift_JIS": "shift_jis",
    "EUC-KR": "euc_kr",
    "replacement": "replacement",
    "UTF-16BE": "utf16be",
    "UTF-16LE": "utf16le",
    "x-user-defined": "x_user_defined",
}

# The two WHATWG UTF-16LE labels the engine routes to its BOM-choosing `.utf16`
# variant rather than a fixed LE decode (a benign superset of rg: it also corrects a
# BE BOM).
UTF16_BOM_LABELS = {"utf-16", "utf16"}
# The engine's historically accepted dash-free spellings (not WHATWG labels, so no
# clash).
EXTRA_LABELS = [("utf16", "utf16"), ("utf16le", "utf16le"), ("utf16be", "utf16be")]


def parse_index(name: str) -> dict[int, int]:
    """`pointer -> code point` from a WHATWG `index-<name>.txt` (skip `#` headers)."""
    out: dict[int, int] = {}
    # Split on '\n' ONLY: an index maps some pointers to C1 control code points
    # (e.g. U+0085 NEL) whose glyph sits verbatim in the name column, and
    # str.splitlines() would break the row on those Unicode line boundaries.
    for raw in (WHATWG / f"index-{name}.txt").read_text().split("\n"):
        line = raw.strip(" \t\r")
        if not line or line.startswith("#"):
            continue
        cols = line.split()
        out[int(cols[0])] = int(cols[1], 16)
    return out


def dense(idx: dict[int, int]) -> list[int]:
    """Densify a sparse pointer map into `[0..max]`, 0 for undefined pointers."""
    return [idx.get(p, 0) for p in range(max(idx) + 1)] if idx else []


def blob(values: list[int], width: int) -> str:
    r"""Return a Zig `\xNN` string literal of values packed little-endian at `width` bits."""
    nbytes = width // 8
    return "".join(f"\\x{(v >> (8 * k)) & 0xFF:02X}" for v in values for k in range(nbytes))


def blob_decl(name: str, values: list[int], width: int) -> str:
    """Emit Zig `pub const` length + byte-blob declarations for one table."""
    return f'pub const {name}_len: usize = {len(values)};\npub const {name}: []const u8 = "{blob(values, width)}";'


def build() -> str:
    """Lower every pinned WHATWG decode index into the generated Zig module text."""
    lines: list[str] = [
        "//! Code generated by tools/build_encoding_tables.py from the",
        "//! pinned WHATWG Encoding Standard indexes in tools/whatwg/. DO NOT EDIT — edit the",
        "//! generator or the vendored indexes and rerun",
        "//! `python3 tools/build_encoding_tables.py`. The drift",
        "//! gate (`python3 tools/build_encoding_tables.py --check`) re-runs this and diffs.",
        "//!",
        "//! Tables are little-endian byte blobs read via std.mem.readInt (see encoding.zig):",
        "//! a dense `pointer -> code point` map per index, 0 = undefined pointer (→ U+FFFD).",
        "",
    ]

    # ── single-byte indexes: byte 0x80..0xFF → code point (exactly 128 entries) ──
    lines.append("// ── single-byte indexes (byte 0x80..0xFF → code point; 0 = undefined) ──")
    for name in SINGLE_BYTE:
        arr = [parse_index(name).get(p, 0) for p in range(128)]
        ident = "sb_" + name.replace("-", "_")
        lines.append(f'pub const {ident}: []const u8 = "{blob(arr, 16)}"; // 128 u16 LE')
    lines.append("")

    # ── multi-byte indexes: dense pointer → code point ──
    lines.append("// ── multi-byte decode indexes (dense pointer → code point; 0 = undefined) ──")
    for name, width in MULTI_BYTE.items():
        ident = name.replace("-", "_")
        lines.append(blob_decl(ident, dense(parse_index(name)), width))
    lines.append("")

    # ── gb18030 four-byte ranges: (pointer, code point) sorted by pointer ──
    ranges = sorted(parse_index("gb18030-ranges").items())
    flat: list[int] = [v for pair in ranges for v in pair]
    lines.append(
        "// ── gb18030 four-byte ranges: interleaved (pointer, code point) u32 LE, pointer-sorted ──"
    )
    lines.append(blob_decl("gb18030_ranges", flat, 32))
    lines.append("")

    # ── ISO-2022-JP half→full-width katakana (only its own small index) ──
    kata = [parse_index("iso-2022-jp-katakana").get(p, 0) for p in range(63)]
    lines.append("// ── ISO-2022-JP katakana index (pointer 0..62 → code point) ──")
    lines.append(blob_decl("iso_2022_jp_katakana", kata, 16))
    lines.append("")

    # ── label → engine Encoding tag (WHATWG get-an-encoding, ASCII-lowercased) ──
    catalog = json.loads((WHATWG / "encodings.json").read_text())
    entries: list[tuple[str, str]] = []
    for group in catalog:
        for enc in group["encodings"]:
            tag = NAME_TO_TAG.get(enc["name"])
            if tag is None:
                continue
            for label in enc["labels"]:
                if enc["name"] == "UTF-16LE" and label in UTF16_BOM_LABELS:
                    entries.append((label, "utf16"))
                else:
                    entries.append((label, tag))
    entries += EXTRA_LABELS
    entries.sort()
    seen: dict[str, str] = {}
    for label, tag in entries:
        if label in seen and seen[label] != tag:
            msg = f"label collision: {label} -> {seen[label]} vs {tag}"
            raise SystemExit(msg)
        seen[label] = tag
    lines.append("pub const LabelEntry = struct { label: []const u8, tag: []const u8 };")
    body = ", ".join(
        f'.{{ .label = "{lbl}", .tag = "{tag}" }}' for lbl, tag in sorted(seen.items())
    )
    lines.append(f"pub const labels = [_]LabelEntry{{ {body} }};")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    """CLI entry: write the `.gen.zig` artifact or `--check` drift against it."""
    generated = build()
    if "--check" in sys.argv:
        current = OUT.read_text() if OUT.exists() else ""
        if current != generated:
            print(
                f"DRIFT: {OUT} is stale — run `python3 tools/build_encoding_tables.py`",
                file=sys.stderr,
            )
            return 1
        print(f"ok: {OUT} matches the pinned WHATWG indexes")
        return 0
    OUT.write_text(generated)
    print(f"wrote {OUT} ({len(generated)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
