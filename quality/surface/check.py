#!/usr/bin/env python3
"""The export gate: does `src/root.zig` hand out exactly what was promised?

`contract/irregex.ward` governs what a file inside this package may reach.
Nothing governed what the package hands out, which is how seventeen `regex_*`
names shaped by one bench harness ended up in the public surface with no note
saying who they were for. This closes the other side: every top-level `pub` in
the root must have a row in `contract/exports.toml` stating its tier and its
reason, and every row must name something the root still exports.

Text over toolchain, like the ratchets beside it. The question is what the file
says, so compiling the engine to answer it would tie a millisecond check to a
Zig install it has no other use for.

Exit 0 clean, 1 on drift, 2 on a malformed contract.
"""

from __future__ import annotations

import re
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

import tomllib

# Reads one `src/`-relative module, or returns None when it cannot be read.
Read = Callable[[str], str | None]

REPO = Path(__file__).resolve().parents[2]
CONTRACT = REPO / "contract" / "exports.toml"
FACADE = REPO / "src" / "root.zig"
MANIFEST = REPO / "build.zig.zon"
TIERS = ("stable", "provisional", "internal")

# Top-level only: an indented `pub` is inside some struct, and what a namespace
# exposes under its own door is that namespace's business, not this gate's.
DECL = re.compile(r"^pub (?:const|fn) (\w+)", re.M)
ZON_VERSION = re.compile(r'\.version\s*=\s*"([^"]+)"')


IMPORT = re.compile(r'^pub const (\w+) = @import\("([^"]+)"\);', re.M)


def exports(root_src: str) -> set[str]:
    """The names `root.zig` hands a consumer."""
    return set(DECL.findall(root_src))


def behind(root_src: str, door: str, read: Read | None) -> set[str] | None:
    """What `<door>.…` resolves to, or None when the address can't be followed.

    A door is either an `@import` of a tier's entry file or a `struct { … }`
    literal grouping several. Both are addresses a `now` can name, so both have
    to be answerable — otherwise the check silently passes exactly the rows it
    cannot read.
    """
    path = dict(IMPORT.findall(root_src)).get(door)
    if path is not None:
        if read is None:
            return None
        src = read(path)
        return None if src is None else set(DECL.findall(src))
    block = re.search(rf"pub const {re.escape(door)} = struct \{{(.*?)\n\}};", root_src, re.S)
    return set(re.findall(r"pub const (\w+)", block.group(1))) if block else None


def release(text: str) -> tuple[int, ...]:
    """`build.zig.zon`'s `.version` as comparable numbers."""
    found = ZON_VERSION.search(text)
    if not found:
        raise ValueError("build.zig.zon declares no .version")
    core = found.group(1).split("-", 1)[0].split("+", 1)[0]
    return tuple(int(p) for p in core.split("."))


def promises(released_src: str, root_src: str, contract: dict) -> list[str]:
    """Every name the last release exported and this tree does not must be declared.

    A tier table cannot answer this. It says what the surface IS, and a breaking
    change is a claim about how it CHANGED — so a contract can be internally
    perfect while the package silently drops nineteen names a consumer pinned.
    That is not hypothetical: it is what this pass did, and the only thing that
    noticed was a downstream bench failing to compile, one name per build.

    The check is `[removed]`, not the version number, because release-please owns
    the version: the working tree stays at the last released number until the
    release PR moves it. Gating on "has the major bumped yet" would therefore be
    red for the entire development window by construction, which is how a gate
    teaches people to ignore it. Declaring the removal is something a change can
    actually do on the day it happens; the `!` in the commit footer follows from
    the same decision.

    The block ends by itself. Once the major ships, the released surface no
    longer exports those names either, so every row goes stale and the gate says
    to delete them.
    """
    gone = exports(released_src) - exports(root_src)
    rows = contract.get("removed", {})
    faults = []

    undeclared = sorted(gone - set(rows))
    if undeclared:
        faults.append(
            f"{len(undeclared)} name(s) the last release exported are gone and "
            f"undeclared — restore them, or add a [removed] row saying what "
            f"replaced each: {', '.join(undeclared)}"
        )
    stale = sorted(set(rows) - gone)
    if stale:
        faults.append(
            f"{len(stale)} [removed] row(s) name something the last release did "
            f"not export — the break already shipped, so delete them: {', '.join(stale)}"
        )
    faults += [
        f"[removed] {name}: no `why` — say what replaced it"
        for name, row in sorted(rows.items())
        if not isinstance(row, dict) or not str(row.get("why", "")).strip()
    ]
    return faults


def ver(v: tuple[int, ...]) -> str:
    return ".".join(str(p) for p in v)


def schedule(contract: dict, current: tuple[int, ...]) -> list[str]:
    """A retired spelling must be scheduled for a version that has not shipped.

    A removal target behind the live version is a deprecation that reads like a
    plan and is a no-op: nothing will ever come due, so the block is carried
    forever while looking temporary. Prose cannot notice that. This can.
    """
    block = contract.get("deprecation")
    retired = [
        n for n, r in contract.get("internal", {}).items() if isinstance(r, dict) and "now" in r
    ]
    if not retired:
        return []
    if not isinstance(block, dict) or not str(block.get("remove_in", "")).strip():
        return [
            f"{len(retired)} retired spellings with no [deprecation] remove_in — "
            f"say which version may delete them"
        ]
    target = str(block["remove_in"])
    try:
        parsed = tuple(int(p) for p in target.split("-", 1)[0].split("."))
    except ValueError:
        return [f"[deprecation] remove_in is not a version: {target!r}"]
    if parsed <= current:
        shipped = ".".join(str(p) for p in current)
        return [
            f"[deprecation] remove_in is {target}, which {shipped} has already "
            f"reached — the retired spellings are scheduled for a release that "
            f"cannot come"
        ]
    return []


def tiers(contract: dict) -> tuple[dict[str, str], list[str]]:
    """Name → tier, plus whatever is wrong with the contract itself."""
    faults, tier_of = [], {}
    for tier in TIERS:
        rows = contract.get(tier)
        if rows is None:
            faults.append(f"contract has no [{tier}] table")
            continue
        for name, row in rows.items():
            if name in tier_of:
                faults.append(f"{name}: declared in both [{tier_of[name]}] and [{tier}]")
            if not isinstance(row, dict) or not str(row.get("why", "")).strip():
                faults.append(f"{name}: no `why` — a public name that answers nobody")
            elif "now" in row and not str(row["now"]).strip():
                faults.append(f"{name}: `now` is empty — say where the spelling went")
            tier_of[name] = tier
    return tier_of, faults


def audit(
    root_src: str,
    contract: dict,
    manifest: str | None = None,
    shipped: str | None = None,
    read: Read | None = None,
) -> tuple[list[str], list[str]]:
    """(drift, faults) — the first is a surface that moved, the second a broken contract."""
    tier_of, faults = tiers(contract)
    if manifest is not None:
        try:
            faults += schedule(contract, release(manifest))
        except ValueError as e:
            faults.append(str(e))
    if shipped is not None:
        faults += promises(shipped, root_src, contract)
    if faults:
        return [], faults

    have = exports(root_src)
    drift = [
        f"`{name}` is exported but undeclared — add a row to contract/exports.toml "
        f"saying who it is for"
        for name in sorted(have - set(tier_of))
    ]
    drift += [
        f"`{name}` is declared [{tier_of[name]}] but the root does not export it — "
        f"delete the row or restore the name"
        for name in sorted(set(tier_of) - have)
    ]
    # Wherever a row says where a name went, that address must still answer.
    # A migration note pointing at a door that was itself renamed is worse than
    # none: it reads authoritative and sends its reader nowhere. Checked to the
    # member, not just the door — `regex.dfa` is only useful if `dfa` is still
    # in there, and a re-namespacing pass is exactly when it stops being.
    for table in ("internal", "removed"):
        for name, row in sorted(contract.get(table, {}).items()):
            if not isinstance(row, dict) or "now" not in row:
                continue
            door, _, member = str(row["now"]).partition(".")
            if door not in have:
                drift.append(f"`{name}` points at `{row['now']}`, which the root does not export")
                continue
            if not member:
                continue
            inside = behind(root_src, door, read)
            if inside is not None and member not in inside:
                drift.append(f"`{name}` points at `{row['now']}`, but `{door}` has no `{member}`")
    return drift, []


def last_release() -> tuple[str, str] | None:
    """(tag, its `root.zig`) for the newest `vX.Y.Z`, or None when no tag is reachable.

    Degrades rather than fails: a shallow clone and a fork without tags are both
    normal, and a gate that red-Xes on the checkout depth teaches people to
    ignore it. The compatibility arm is then simply not asked — every other arm
    still is, and CI fetches tags so the arm runs where it decides a merge.
    """

    def git(*args: str) -> str | None:
        out = subprocess.run(("git", "-C", str(REPO), *args), capture_output=True, text=True)
        return out.stdout if out.returncode == 0 else None

    tags = git("tag", "--list", "v[0-9]*", "--sort=-v:refname")
    if not tags or not tags.split():
        return None
    tag = tags.split()[0]
    src = git("show", f"{tag}:src/root.zig")
    return None if src is None else (tag, src)


def main() -> int:
    if not CONTRACT.is_file():
        print(f"surface: no contract at {CONTRACT}", file=sys.stderr)
        return 2
    try:
        contract = tomllib.loads(CONTRACT.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as e:
        print(f"surface: {CONTRACT.name} is malformed — {e}", file=sys.stderr)
        return 2

    def read(rel: str) -> str | None:
        path = FACADE.parent / rel
        return path.read_text(encoding="utf-8") if path.is_file() else None

    shipped = last_release()
    drift, faults = audit(
        FACADE.read_text(encoding="utf-8"),
        contract,
        MANIFEST.read_text(encoding="utf-8"),
        shipped[1] if shipped else None,
        read,
    )
    for line in faults + drift:
        print(f"surface: {line}", file=sys.stderr)
    if faults:
        return 2
    if drift:
        return 1

    tier_of, _ = tiers(contract)
    counts = " · ".join(f"{sum(t == tier for t in tier_of.values())} {tier}" for tier in TIERS)
    removed = len(contract.get("removed", {}))
    against = f"checked against {shipped[0]}" if shipped else "no release tag reachable"
    breaks = f", {removed} declared removal(s)" if removed else ""
    print(f"surface: {len(tier_of)} exports, all declared ({counts}){breaks} · {against}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
