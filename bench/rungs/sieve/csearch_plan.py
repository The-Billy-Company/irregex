#!/usr/bin/env python3
"""gist bench — lift csearch's OWN trigram formula out of csearch, verbatim.

Layer L's whole point is to compare two *planners*, not two machines: the same
corpus, the same postings, the same evaluator — only the boolean formula over
trigrams differs. `csearch -verbose` prints exactly that formula
(`cmd/csearch/csearch.go`: `log.Printf("query: %s", q)`, where `q` is
`index.RegexpQuery(re.Syntax)` rendered by `Query.String()` in
`index/regexp.go`), plus the candidate count csearch's own index resolved it to.
So nothing here is a proxy and nothing is re-derived: csearch states its plan,
this script parses it, and `indexq.zig` runs it against gist's index.

`Query.String()` renders an AND as space-joined terms and an OR as
`(a)|(b)|(c)` — unambiguous under "split top-level whitespace ⇒ AND, then split
top-level `|` ⇒ OR", because csearch's `andOr` never nests a node under a node
of its own op. `+` is QAll (no filter at all) and `-` is QNone.

The formula is emitted in gist's plan shape — AND over clauses, OR over the
atoms of a clause, AND over the trigrams of an atom (`Index.queryPlan`) — which
covers csearch's tree exactly: its OR-of-ANDs alternations become one clause of
multi-trigram atoms, its AND-of-ORs boundary products become several clauses.

stdlib only. Probe rows come from `slate.py`, which reads the same Zig registries
Layers A and D import, so this slate cannot drift from theirs.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

# A clause whose DNF-of-atoms exceeds this is DROPPED rather than expanded.
# Dropping a conjunct only widens the candidate set, so this can never cost
# csearch a match — it can only make csearch's measured arm look *worse*, which
# is why the report prints how many clauses were dropped (zero on this slate).
MAX_ATOMS = 4096

# The slate is `slate.py`'s to define — it owns both the registry rows and the
# judgement of whether a corpus exercises them, and two parsers for one Zig
# literal is exactly the drift this whole layer exists to rule out.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from slate import read_probes  # noqa: E402


# ── csearch Query.String() → tree ────────────────────────────────────────────
# atom := '"' go-quoted '"' | '(' expr ')' | '+' | '-'
# term := atom ('|' atom)*      → OR when > 1
# expr := term (WS term)*       → AND when > 1


class Parser:
    """Recursive descent over one rendered `Query.String()`."""

    def __init__(self, src: str) -> None:
        self.s, self.i = src, 0

    def expr(self) -> tuple:
        parts = [self.term()]
        while self.skip_ws() and self.i < len(self.s) and self.s[self.i] != ")":
            parts.append(self.term())
        return parts[0] if len(parts) == 1 else ("and", parts)

    def term(self) -> tuple:
        parts = [self.atom()]
        while self.i < len(self.s) and self.s[self.i] == "|":
            self.i += 1
            parts.append(self.atom())
        return parts[0] if len(parts) == 1 else ("or", parts)

    def atom(self) -> tuple:
        c = self.s[self.i]
        if c == "+":
            self.i += 1
            return ("all",)
        if c == "-":
            self.i += 1
            return ("none",)
        if c == "(":
            self.i += 1
            inner = self.expr()
            if self.i >= len(self.s) or self.s[self.i] != ")":
                raise ValueError(f"unbalanced ( at {self.i} in {self.s!r}")
            self.i += 1
            return inner
        if c == '"':
            return ("tri", self.quoted())
        raise ValueError(f"unexpected {c!r} at {self.i} in {self.s!r}")

    def quoted(self) -> bytes:
        """One Go `strconv.Quote`d string → its raw bytes."""
        self.i += 1  # opening quote
        out = bytearray()
        while self.s[self.i] != '"':
            c = self.s[self.i]
            if c != "\\":
                out += c.encode()
                self.i += 1
                continue
            esc = self.s[self.i + 1]
            self.i += 2
            if esc in "abfnrtv":
                out.append(b"\a\b\f\n\r\t\v"["abfnrtv".index(esc)])
            elif esc in "\\'\"":
                out += esc.encode()
            elif esc == "x":
                out.append(int(self.s[self.i : self.i + 2], 16))
                self.i += 2
            elif esc in "uU":
                n = 4 if esc == "u" else 8
                out += chr(int(self.s[self.i : self.i + n], 16)).encode()
                self.i += n
            else:  # octal \nnn
                out.append(int(self.s[self.i - 1 : self.i + 2], 8))
                self.i += 2
        self.i += 1  # closing quote
        return bytes(out)

    def skip_ws(self) -> bool:
        while self.i < len(self.s) and self.s[self.i] == " ":
            self.i += 1
        return True


def to_plan(node: tuple) -> tuple[list[list[list[bytes]]], bool, int]:
    """Tree → (clauses, filterable, dropped). A clause is a list of atoms; an atom a list of trigrams."""
    dropped = 0

    def atoms(n: tuple) -> list[list[bytes]] | None:
        """The DNF-of-atoms of `n`, or None when it admits everything."""
        nonlocal dropped
        kind = n[0]
        if kind == "tri":
            return [[n[1]]]
        if kind == "all":
            return None
        if kind == "none":
            return []
        if kind == "or":
            acc: list[list[bytes]] = []
            for sub in n[1]:
                got = atoms(sub)
                if got is None:
                    return None  # one unfiltered branch ⇒ the whole OR is unfiltered
                acc += got
            return acc
        # AND: cross-product the children's atom sets.
        acc = [[]]
        for sub in n[1]:
            got = atoms(sub)
            if got is None:
                continue  # ALL is the AND identity
            nxt = [a + b for a in acc for b in got]
            if len(nxt) > MAX_ATOMS:
                dropped += 1
                return None
            acc = nxt
        return acc

    def clauses_of(n: tuple) -> list[list[list[bytes]]]:
        if n[0] == "and":
            out: list[list[list[bytes]]] = []
            for sub in n[1]:
                out += clauses_of(sub)
            return out
        got = atoms(n)
        return [] if got is None else [got]

    cl = clauses_of(node)
    return cl, bool(cl), dropped


def csearch_query(pattern: str, idx: Path, exe: str) -> tuple[str, int]:
    """Run csearch and lift (rendered query, its own candidate-file count)."""
    env = {**os.environ, "CSEARCHINDEX": str(idx)}
    p = subprocess.run(
        [exe, "-verbose", "-l", pattern],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    q, n = "", -1
    for line in p.stderr.splitlines():
        if " query: " in line:
            q = line.split(" query: ", 1)[1].strip()
        elif "possible files" in line:
            n = int(line.split("identified", 1)[1].split("possible", 1)[0].strip())
    if not q:
        raise SystemExit(f"csearch printed no query for {pattern!r}:\n{p.stderr}")
    return q, n


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser(description="lift csearch's trigram plan per probe class")
    ap.add_argument(
        "--probes",
        type=Path,
        required=True,
        action="append",
        help="a Zig probe registry; repeatable (shared bench/apparatus/harness/probes.zig, then stress.zig)",
    )
    ap.add_argument("--index", type=Path, required=True, help="the csearch .idx")
    ap.add_argument("--out", type=Path, required=True, help="plan TSV for indexq.zig")
    ap.add_argument("--csearch", default="csearch")
    args = ap.parse_args()

    slate = [row for p in args.probes for row in read_probes(p)]
    rows, total_dropped = [], 0
    for cls, kind, pattern in slate:
        # A `.literal` probe is gist's `-F` fixed string; csearch's equivalent is
        # the quoted-literal form `_compete.sh` already races it on, so `.` and
        # `)` stay bytes rather than becoming regex syntax.
        rendered, own = csearch_query(
            rf"\Q{pattern}\E" if kind == "literal" else pattern, args.index, args.csearch
        )
        clauses, filterable, dropped = to_plan(Parser(rendered).expr())
        total_dropped += dropped
        rows.append((cls, own, rendered, clauses, filterable))
        print(f"  {cls:<18} {own:>7} files · {rendered[:88]}", file=sys.stderr)

    lines = ["# class\tcsearch_own_docs\tclause (atoms joined by |, hex literals joined by ,)"]
    for cls, own, _rendered, clauses, filterable in rows:
        if not filterable:
            lines.append(f"{cls}\t{own}\t")  # empty ⇒ no filter, whole corpus
            continue
        for clause in clauses:
            body = "|".join(",".join(t.hex() for t in atom) for atom in clause)
            lines.append(f"{cls}\t{own}\t{body}")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(lines) + "\n")
    if total_dropped:
        print(
            f"  NOTE: {total_dropped} clause(s) past the {MAX_ATOMS}-atom cap were dropped",
            file=sys.stderr,
        )
    print(f"wrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
