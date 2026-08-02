#!/usr/bin/env python3
"""Vendor the sibling-authored contract this package's bindings mirror.

irregex owns the row protocol — the analytic row enums, the grade bands, the
channel vocabulary — because it owns the decode and transport layer every face
reads rows through. It does not *author* all of the calibration that gives those
numbers meaning: `kinship.toml` is relate's. The bindings mirror it, and a
parity test asserts the mirror still matches what its author wrote.

Before the split those contracts sat in one tree. Now they do not, and the
alternative to vendoring is a CI job that clones the authoring repository to
read one file. For gist that is fine — it is public, so CI checks it out and
reads `surface.toml` from the original. relate is internal, and a public package
whose own tests need a clone of a private one is a package the public cannot
test. So exactly one file is vendored, and the drift gate lives where the
original does: relate can read this package, because this package is public.

    python3 tools/sync_contract.py            # refresh the vendored copies
    python3 tools/sync_contract.py --check    # fail if a copy has drifted

`--check` is what an author's CI runs. Refreshing needs the sibling on disk in
the flat layout every checkout here already assumes; `--root` points elsewhere.
"""

from __future__ import annotations

import argparse
import difflib
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent

# Which sibling authors each contract this package vendors.
#
# Only `kinship`. The two contracts this package authors itself — analytic.toml,
# engine.toml — are absent because a file cannot drift from itself, and listing
# them would invite someone to overwrite an original with a copy. `surface` is
# absent for a different reason: gist is a public repository, so CI can simply
# check it out and read the original. relate is internal, and a public package
# whose tests need a clone of a private one is a package the public cannot test.
# So the rule is narrow on purpose — vendor only what a stranger cannot fetch.
AUTHORS = {"kinship": "relate"}

BANNER = "# Vendored from {author}/contract/{name}.toml — do not edit here.\n"


def sibling(name: str, root: Path) -> Path:
    return root / AUTHORS[name] / "contract" / f"{name}.toml"


def vendored(name: str) -> Path:
    return HERE / "contract" / f"{name}.toml"


def authored_text(path: Path) -> str:
    """The author's bytes, with the vendoring banner prepended.

    The banner is the whole reason a reader who opens the copy learns it is a
    copy. It is added on write and stripped on compare, so drift is judged on
    the contract itself rather than on a line this tool controls.
    """
    return path.read_text()


def strip_banner(text: str) -> str:
    first, sep, rest = text.partition("\n")
    return rest if first.startswith("# Vendored from ") and sep else text


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--check",
        action="store_true",
        help="report drift instead of fixing it; exit 1 if a copy is stale",
    )
    ap.add_argument(
        "--root",
        type=Path,
        default=HERE.parent,
        help="directory holding the sibling checkouts (default: this one's parent)",
    )
    args = ap.parse_args()

    missing, drifted, wrote = [], [], []
    for name, author in sorted(AUTHORS.items()):
        src, dst = sibling(name, args.root), vendored(name)
        if not src.is_file():
            missing.append(f"{author}/contract/{name}.toml (looked in {src})")
            continue
        want = authored_text(src)
        have = strip_banner(dst.read_text()) if dst.is_file() else None
        if have == want:
            continue
        if args.check:
            drifted.append((name, author, have, want))
        else:
            dst.write_text(BANNER.format(author=author, name=name) + want)
            wrote.append(f"contract/{name}.toml ← {author}")

    if missing:
        # A refresh cannot invent the source, and a check cannot clear a copy it
        # never compared. Either way this is inconclusive, not a pass: exit 2 so
        # a CI step cannot read "no drift found" out of "nothing was read".
        for m in missing:
            print(f"sync_contract: no sibling checkout for {m}", file=sys.stderr)
        print(
            "sync_contract: expected the flat layout every checkout here assumes "
            f"({args.root}/{{irregex,gist,relate,blast}}), or pass --root",
            file=sys.stderr,
        )
        return 2

    for name, author, have, want in drifted:
        print(f"::error::contract/{name}.toml has drifted from {author}'s original")
        if have is None:
            print("  the vendored copy is missing entirely; run: python3 tools/sync_contract.py")
            continue
        diff = difflib.unified_diff(
            have.splitlines(True),
            want.splitlines(True),
            fromfile=f"irregex/contract/{name}.toml (vendored)",
            tofile=f"{author}/contract/{name}.toml (authored)",
        )
        sys.stdout.writelines(diff)

    if drifted:
        print(
            "\nRefresh them in the irregex checkout and commit the result:\n"
            "  python3 tools/sync_contract.py",
            file=sys.stderr,
        )
        return 1

    for w in wrote:
        print(f"sync_contract: wrote {w}")
    print(
        "sync_contract: every vendored contract matches its author"
        if args.check
        else "sync_contract: up to date"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
