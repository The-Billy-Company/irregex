#!/usr/bin/env python3
"""Re-mint the committed artifacts a version bump invalidates.

`tools/version_parity.py` governs the mirrors a person types: a line carrying an
`x-release-please-version` marker, which the release bot rewrites in the same
commit that moves `build.zig.zon`. Three kinds of committed file carry the
version without carrying that marker, because no line in them was typed by
anybody:

  * the **vendored engine archives** - build output, one per target, with the
    version compiled into their string tables;
  * the **oracle corpora** under each binding's `testdata/` - generated against
    a linked engine, which records the version it linked;
  * the **lockfiles** - resolver output, pinning this package's own name at
    whatever its manifest declared the last time the resolver ran.

The bot cannot rewrite any of them, so a release PR bumps to X.Y.Z and leaves
all three describing the release before it. Nothing failed early: the archives
still carry every symbol, so the parity gate's symbol lane passed, and each
binding's suite failed later on a version contract instead. v2.1.0 shipped only
because all three were minted by hand after the fact. This is that hand.

Discovery rather than a list, like the gates it sits beside. Archives and the
command that rebuilds each come from `contract/bindings.toml`; a corpus names
its own generator by lying next to it (`testdata/x.json` beside `scripts/x.py`);
a lockfile names its package through the manifest beside it. A fourth binding
is covered the day it commits an artifact, not the day someone remembers this
file.

    python3 tools/mint_artifacts.py --check   # what is stale; exit 1 if any
    python3 tools/mint_artifacts.py           # refresh exactly those

Rebuilding an archive needs a Zig toolchain, and regenerating a corpus needs
`zig build` to have installed a library the Python binding can load. Both fail
loudly rather than skipping, because a mint that quietly did nothing is how the
stale bytes got committed in the first place.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import shlex
import subprocess
import sys
import tomllib
from typing import NamedTuple

# The parity gate already knows how to ask an archive which build it came out of,
# and what this tree declares. Importing it keeps ONE definition of stale: its
# NUL-delimited stamp regex is the difference between reading the engine's
# version and reading LLVM's, and a second copy here would drift from the gate
# that actually fails CI.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "quality" / "parity"))

import check as parity  # noqa: E402

# Two ecosystems, one shape: a TOML lockfile holding an array of `[[package]]`
# tables, beside the manifest that says which of those packages is ours. The
# refresh command is the irreducible per-ecosystem half - `--workspace` is what
# keeps cargo re-resolving this crate's own entry without moving a single
# third-party pin.
LOCKS = {
    "Cargo.lock": ("Cargo.toml", "cargo update --workspace"),
    "uv.lock": ("pyproject.toml", "uv lock"),
}


class Chore(NamedTuple):
    """One stale artifact, what it says instead, and the command that fixes it."""

    what: str
    said: str
    fix: str
    cwd: pathlib.Path


def rel(path: pathlib.Path) -> str:
    """A path as the repository spells it."""
    return str(path.relative_to(parity.REPO)) if path.is_relative_to(parity.REPO) else str(path)


def normalized(name: str) -> str:
    """A package name as a lockfile spells it, so `a_b` and `A-B` are one name."""
    return name.strip().lower().replace("_", "-")


def archives(version: str, contract: dict) -> list[Chore]:
    """Every binding whose vendored engine came out of some earlier build.

    Per binding, not per file: the six targets are one build and one command
    refreshes them, so six lines saying the same thing would only bury it.
    """
    chores = []
    for binding, row in sorted(contract.get("bindings", {}).items()):
        carried = parity.versions_of(row)
        behind = sorted(name for name, found in carried.items() if version not in found)
        if not behind:
            continue
        # What they do carry, deduplicated: the set holds the C compiler's
        # version too, so this is evidence rather than a claim about which entry
        # was the engine's.
        found = sorted({v for name in behind for v in carried[name]})
        chores.append(
            Chore(
                f"{binding}: {len(behind)} vendored archive(s) under {row['archives']}",
                ", ".join(found) or "no version string at all",
                str(row["rebuild"]),
                parity.REPO,
            )
        )
    return chores


def corpora(version: str) -> list[Chore]:
    """Every oracle corpus generated against an engine other than this one."""
    chores = []
    for corpus in sorted(parity.REPO.glob("bindings/*/testdata/*_oracle.json")):
        said = str(json.loads(corpus.read_text(encoding="utf-8")).get("engine_version", ""))
        if said == version:
            continue
        # The corpus names its generator: same stem, in the `scripts/` sibling of
        # the `testdata/` it was written into. Missing is a fault, never a skip -
        # a corpus nothing can regenerate is a release that stops here.
        generator = corpus.parent.parent / "scripts" / f"{corpus.stem}.py"
        if not generator.is_file():
            raise SystemExit(f"mint: {rel(corpus)} has no generator at {rel(generator)}")
        chores.append(
            Chore(
                rel(corpus), said or "no engine version", f"python3 {rel(generator)}", parity.REPO
            )
        )
    return chores


def locks(version: str) -> list[Chore]:
    """Every lockfile still pinning this package at the version before the bump."""
    chores = []
    for name, (manifest, fix) in sorted(LOCKS.items()):
        for lock in sorted(parity.REPO.glob(f"bindings/*/{name}")):
            beside = lock.parent / manifest
            if not beside.is_file():
                raise SystemExit(f"mint: {rel(lock)} has no {manifest} beside it")
            declared = tomllib.loads(beside.read_text(encoding="utf-8"))
            # `[package]` in a Cargo manifest, `[project]` in a Python one; the
            # question is the same one, so neither gets its own branch.
            ours = normalized(
                str((declared.get("package") or declared.get("project") or {}).get("name", ""))
            )
            pinned = {
                normalized(str(row.get("name", ""))): str(row.get("version", ""))
                for row in tomllib.loads(lock.read_text(encoding="utf-8")).get("package", [])
            }
            said = pinned.get(ours, "")
            if said == version:
                continue
            chores.append(Chore(rel(lock), said or f"no entry for {ours}", fix, lock.parent))
    return chores


def stale(version: str) -> list[Chore]:
    """Everything committed that describes a version other than this tree's."""
    contract = tomllib.loads(parity.CONTRACT.read_text(encoding="utf-8"))
    return archives(version, contract) + corpora(version) + locks(version)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="report staleness, change nothing")
    args = parser.parse_args()

    version = parity.declared_version()
    if not version:
        print(
            f"mint: {parity.ZON.name} declares no version — the authority is broken",
            file=sys.stderr,
        )
        return 2

    chores = stale(version)
    if not chores:
        print(f"mint: every committed artifact already carries {version}")
        return 0
    for chore in chores:
        print(f"mint: {chore.what} carries {chore.said}, not {version}", file=sys.stderr)
    if args.check:
        print(f"mint: `python3 tools/mint_artifacts.py` refreshes {len(chores)}", file=sys.stderr)
        return 1

    for chore in chores:
        print(f"mint: {chore.fix} (in {rel(chore.cwd)})", flush=True)
        if code := subprocess.run(shlex.split(chore.fix), cwd=chore.cwd, check=False).returncode:
            print(f"mint: `{chore.fix}` exited {code} — nothing further was run", file=sys.stderr)
            return 2

    # Asked again rather than assumed: a rebuild that succeeds and emits the same
    # stale bytes is the one failure a mint cannot self-report, and committing
    # that would look exactly like the release this file exists to prevent.
    if left := stale(version):
        for chore in left:
            print(
                f"mint: {chore.what} still carries {chore.said} after `{chore.fix}`",
                file=sys.stderr,
            )
        return 2
    print(f"mint: {len(chores)} artifact(s) refreshed to {version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
