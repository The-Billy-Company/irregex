#!/usr/bin/env python3
"""Generate the cross-check table in ../testdata/python_oracle.json.

The Python binding is the reference implementation for this ABI: it was written
first, it is independently verified, and its test suite pins the semantics. This
script asks it for the match spans of a shared corpus of pattern/flag/text
triples and records them, so the Go test suite can assert that the two bindings
agree without needing Python at test time.

Everything is expressed in bytes, not str. The Python binding reports codepoint
indices for a str pattern and byte offsets for a bytes one; Go strings are
indexed by byte, so the bytes half is the like-for-like comparison and the one
that tells us whether the Go binding needs an offset translation (it does not).

Run it from anywhere:

    IRGX_LIB=/path/to/libirgx.dylib python3 scripts/python_oracle.py

IRGX_LIB is only needed when the Python package was installed without its
bundled shared library, which is the case for a source checkout.
"""

from __future__ import annotations

import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE.parent / "testdata" / "python_oracle.json"
# A source checkout, where the Python package sits beside this binding.
sys.path.insert(0, str(HERE.parent.parent / "python"))

import irgx  # noqa: E402

# Each case is (name, pattern, flags, texts). Flags use the Python binding's
# keyword spelling; the Go side maps them onto CompileOpts.
CASES: list[tuple[str, str, dict[str, bool], list[str]]] = [
    ("literal", "cat", {}, ["cat", "concatenate", "a cat and a cat", ""]),
    ("alternation", "cat|dog", {}, ["a cat, a dog", "catdog", "bird"]),
    ("class", "[0-9]+", {}, ["a1b22c333", "0", "none", "10.20.30"]),
    ("dot_star", "a.*b", {}, ["axxb", "ab", "ba", "aXbXaXb"]),
    # Nullable and zero-width patterns, where an advance loop would go wrong.
    ("star_nullable", "a*", {}, ["abc", "", "aaa", "bbb", "abc\n", "aXaXa"]),
    ("empty_pattern", "", {}, ["", "a", "abc", "\n"]),
    ("word_boundary", r"\b", {}, ["ab cd", "", " ", "a"]),
    ("optional", "x?", {}, ["axbxc", "xxx", ""]),
    ("nullable_group", "(a*)(b*)", {}, ["aabb", "ab", "", "ba"]),
    # Non-ASCII. The engine reports byte offsets, and so does this table.
    ("unicode_literal", "café", {}, ["le café noir", "CAFÉ", "cafe"]),
    ("unicode_icase", "café", {"ignore_case": True}, ["le CAFÉ noir", "Café"]),
    ("unicode_class", r"\w+", {}, ["naïve café", "日本語 text", "a_b-c"]),
    ("unicode_dot", ".", {}, ["é", "日本", "aé"]),
    ("ascii_class", r"\w+", {"unicode": False}, ["naïve café", "abc def"]),
    # Groups, including one that cannot participate.
    ("groups_numbered", r"(\w+)@(\w+)", {}, ["mail bob@host now", "no at sign"]),
    ("groups_named", r"(?P<user>\w+)@(?P<host>\w+)", {}, ["bob@host"]),
    ("groups_optional", r"(a)|(b)", {}, ["a", "b", "ab", "c"]),
    ("groups_nested", r"((a)(b)?)+", {}, ["abaab", "a"]),
    # Flags, each on a text that shows the difference.
    ("fixed", "a.c", {"fixed": True}, ["a.c", "abc", "xa.cx"]),
    ("icase", "abc", {"ignore_case": True}, ["ABC abc AbC"]),
    ("word", "cat", {"word": True}, ["cat concatenate the cat.", "cats"]),
    ("word_group", r"(c\w+)", {"word": True}, ["cat concat cow"]),
    ("smart_lower", "abc", {"smart_case": True}, ["ABC abc"]),
    ("smart_upper", "Abc", {"smart_case": True}, ["ABC abc Abc"]),
    ("pcre_lookahead", r"foo(?=bar)", {"pcre": True}, ["foobar foobaz"]),
    ("pcre_lookbehind", r"(?<=\$)\d+", {"pcre": True}, ["$42 and 43"]),
    ("pcre_backref", r"(\w)\1", {"pcre": True}, ["aa bb ab cc"]),
    # Adjacency and overlap, where the engine's resume rule is visible.
    ("overlapping", "aa", {}, ["aaaa", "aaa"]),
    ("anchored", "^a", {}, ["abc", "bac"]),
    ("end_anchor", "c$", {}, ["abc", "abc\n", "cab"]),
    ("repeat_bound", "a{2,3}", {}, ["a aa aaa aaaa"]),
]


def main() -> None:
    out = []
    for name, pattern, flags, texts in CASES:
        compiled = irgx.compile(pattern.encode(), **flags)
        for text in texts:
            data = text.encode()
            spans = [list(m.span()) for m in compiled.finditer(data)]
            # A group the match did not enter is None in the Python binding and
            # -1, -1 in the Go one; -1 is what the C ABI itself reports.
            groups = [
                [
                    list(m.span(i)) if m.span(i) != (-1, -1) else [-1, -1]
                    for i in range(compiled.groups + 1)
                ]
                for m in compiled.finditer(data)
            ]
            out.append(
                {
                    "name": name,
                    "pattern": pattern,
                    "flags": flags,
                    "text": text,
                    "spans": spans,
                    "groups": groups,
                }
            )
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(
        json.dumps(
            {
                "generator": "bindings/go/scripts/python_oracle.py",
                "reference": "the irregex Python binding",
                "engine_version": irgx.ENGINE_VERSION,
                "cases": out,
            },
            indent=1,
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"{OUT}: {len(out)} cases from engine {irgx.ENGINE_VERSION}")


if __name__ == "__main__":
    main()
