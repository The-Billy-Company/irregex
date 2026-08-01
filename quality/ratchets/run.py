#!/usr/bin/env python3
"""Run the Zig ratchets — all of them, or one by name.

There is no build-system entry point on purpose. A ratchet is stdlib-only
Python over the working tree, it needs no Zig toolchain, and making it a
`zig build` step would tie a text scan to a compile the scan does not need.
So this file is the entry point: one command, discoverable by being the only
thing here that is not a ratchet.

    python3 quality/ratchets/run.py                      # all four
    python3 quality/ratchets/run.py oom                  # just one
    python3 quality/ratchets/run.py oom fault-taxonomy   # a couple
    python3 quality/ratchets/run.py --list               # what exists
    python3 quality/ratchets/run.py --json               # machine-readable

Discovery is structural rather than a hardcoded roster: every directory beside
this file holds exactly one ``*_ratchet.py``, and that file's ``main(argv)`` is
the contract. Adding a ratchet is adding a directory.

``--refresh`` rewrites a baseline from the current scan and is deliberately
awkward to reach for — see the README. It is correct after a cleanup that
*lowered* a count, and it is the one forbidden move when a gate has gone red.

Exit code is 1 if any selected ratchet failed, 0 otherwise.
"""

import argparse
import importlib.util
import sys
from pathlib import Path
from types import ModuleType

RATCHETS = Path(__file__).resolve().parent


def drivers() -> dict[str, Path]:
    """``{ratchet name: driver path}``, discovered from the directory layout."""
    out: dict[str, Path] = {}
    for d in sorted(RATCHETS.iterdir()):
        if not d.is_dir() or d.name.startswith((".", "_")):
            continue
        found = [p for p in sorted(d.glob("*_ratchet.py")) if not p.name.startswith("test_")]
        if len(found) != 1:
            raise SystemExit(
                f"ratchets: {d.name}/ must hold exactly one *_ratchet.py, found {len(found)}"
            )
        out[d.name] = found[0]
    return out


def _load(path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(path.stem, path)
    if spec is None or spec.loader is None:  # pragma: no cover — unreachable for a real file
        raise SystemExit(f"ratchets: cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def main(argv: list[str] | None = None) -> int:
    known = drivers()
    ap = argparse.ArgumentParser(
        prog="quality/ratchets/run.py",
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    # Not `choices=`: argparse validates a `nargs="*"` default against choices,
    # so declaring them would reject the bare "run everything" invocation.
    ap.add_argument("name", nargs="*", help=f"ratchet(s) to run — {', '.join(known)}; default all")
    ap.add_argument("--list", action="store_true", help="print the known ratchets and exit")
    ap.add_argument(
        "--refresh", action="store_true", help="rewrite baselines from the current scan"
    )
    ap.add_argument("--json", action="store_true", help="machine-readable diff per ratchet")
    args = ap.parse_args(argv)

    if args.list:
        for name, path in known.items():
            print(f"{name:16} {path.relative_to(RATCHETS.parents[1])}")
        return 0

    if unknown := [n for n in args.name if n not in known]:
        ap.error(f"no such ratchet: {', '.join(unknown)} (have {', '.join(known)})")
    selected = args.name or list(known)
    passthrough = [f"--{f}" for f in ("refresh", "json") if getattr(args, f)]

    failed: list[str] = []
    for i, name in enumerate(selected):
        if not args.json:
            if i:
                print()
            print(f"── {name} ──")
        if _load(known[name]).main(passthrough):
            failed.append(name)

    if failed and not args.json:
        print(f"\n{len(failed)} of {len(selected)} ratchet(s) failed: {', '.join(failed)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
