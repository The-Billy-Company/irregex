#!/usr/bin/env python3
"""Zig fault-taxonomy ratchet — no error name outside the declared domains.

Fault-channel law 2: Zig unifies error names **globally**, so `error.Corrupt`,
`error.BadFormat` and `error.CorruptIndex` all meant "these persisted bytes are
untrustworthy" — synonyms that cannot be handled uniformly, and homonyms that
merge silently. Five domains are now declared once in ``src/fault.zig`` and
mirrored as the contract's ``[fault_domains]`` block; this ratchet is what stops
a sixth spelling from accreting the same way.

The rule, stated exactly: **every error name irregex production Zig *produces*
must be a member of a declared fault domain.** A finding is one such name at one
producing site. "Producing" is the decisive word — see below.

The declared vocabulary is read from ``[fault_domains]`` in
``contract/engine.toml``; the driver hardcodes no member list, so extending the
taxonomy is a contract edit and nothing else. A missing or empty block is a hard
error, never an empty allowlist that flags the world.

**"Synonym" is not judged semantically.** No mechanical rule can decide that
`BadFormat` means what `Corrupt` means, and pretending otherwise would make the
ratchet unpredictable. Instead it enforces the property that *makes* synonyms
impossible: the vocabulary is closed. A new spelling of an existing fact is
caught because it is a name outside the declared set — the same way a genuinely
new fact is caught, and the fix differs (map it onto the existing member vs. add
a member to the contract) rather than the detection.

Three structural exclusions, none of them an allowlist of names:

* **Test vocabulary** — ``*_test.zig`` / ``*_fuzz.zig`` files, inline
  ``test "…" { … }`` blocks inside a production file, and ``std.testing``'s own
  sentinel family (``error.SkipZigTest`` plus the ``error.Test*`` names its
  ``expect*`` helpers return). The family is excluded by namespace rather than
  by site because ``std.testing`` mints those names, so irregex cannot own one —
  and because a test *helper* often sits beside the tests it serves in a
  production file where no block encloses it. A fuzz harness's oracle-violation
  errors (``error.LoadersDisagree``) are assertions, not faults, which is why
  the whole ``*_fuzz.zig`` file is out.
* **Private control flow** — a name whose declarations in a file are all inside a
  **non-`pub` named `const` error set** is file-private and cannot reach another
  module's handler, so it cannot become a synonym anyone has to unify. This is the
  PCRE2 shadow rewriter's ``const Err = error{ Bail, OutOfMemory };``, the model
  shape. Deliberately narrow: an *inline* anonymous set in a private function
  signature does **not** qualify, because an inferred error set propagates it out
  of the file regardless.
* **Consuming positions** — a switch prong label (``error.EndOfStream => {}``) or
  a comparison operand (``e == error.Foo``) *handles* a name that came from
  elsewhere, typically ``std``. Only production sites — error-set declarations,
  ``return error.X``, a ``=>`` right-hand side — put a name into irregex's own
  vocabulary. This is what keeps every std error the kernel merely propagates out
  of the count without maintaining a list of std error names.
* **Returning into a std error set** — ``return error.X`` from a function whose
  *declared* error set resolves to one of std's own (``fn ntMap(…)
  MapError!Mapping`` where ``const MapError = std.posix.MMapError``) is
  restating std's vocabulary under compulsion, not minting irregex's. See
  ``_std_returned`` for why the Zig compiler, not this driver, is what makes
  that exclusion sound.

Matching runs on a comment/string-blanked copy of each file (``_lib/zigtext.py``),
so a name quoted in a doc comment is prose, not a declaration.

Scope: ``src/**/*.zig``, excluding the suffixes above, ``*.gen.zig``, and
generated-header files.

Run via ``python3 quality/ratchets/run.py fault-taxonomy``; refresh with the
same command plus ``--refresh``.
"""

import bisect
import re
import sys
import tomllib
from collections.abc import Callable
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from _lib import (  # noqa: E402
    FileCount,
    PatternCount,
    code_only,
    head_lines,
    range_membership,
    run_count_cli,
    test_block_ranges,
    walk_source_files,
)

REPO = Path(__file__).resolve().parents[3]
BASELINE = Path(__file__).resolve().parent / "fault-taxonomy.baseline"

CONTRACT = REPO / "contract" / "engine.toml"
DOMAINS_TABLE = "fault_domains"
STATUS_TABLE = "status_codes"

ROOTS = (REPO / "src",)
SKIP_DIR_PARTS = {"zig-out", ".zig-cache", "node_modules", "target"}
SKIP_NAME_SUFFIXES = ("_test.zig", "_fuzz.zig", ".gen.zig")

# An `error{ A, B }` set literal — members, and the statement prefix that says
# whether the declaration is `pub` and whether it is a named `const`.
SET_RE = re.compile(r"\berror\s*\{([^}{]*)\}")
IDENT_RE = re.compile(r"[A-Za-z_]\w*")
NAMED_CONST_RE = re.compile(r"\bconst\s+\w+\s*=\s*$")
STATEMENT_BOUNDARY = ";{}"

# A reference to one error name.
REF_RE = re.compile(r"\berror\.([A-Za-z_]\w*)")
# `error.A` / `error.A, error.B` immediately in front of a `=>` — a switch prong
# label list, i.e. names flowing IN.
PRONG_TAIL_RE = re.compile(r"\s*(?:,\s*error\.\w+\s*)*=>")
# …unless the ref is itself a value (a prong's right-hand side, a `return`), in
# which case the `=>` it precedes belongs to the NEXT prong.
VALUE_LEAD_RE = re.compile(r"(?:=>|\breturn|\borelse|\bbreak\s+:\w+)\s*$")
# `e == error.Foo` / `e != error.Foo` — also a name flowing in.
COMPARE_RE = re.compile(r"[=!]=\s*(error\.\w+)")

# `return error.X` — the one producing form whose membership the compiler checks
# against the enclosing function's declared error set. The two spellings are the
# same predicate: one as a whole-file precheck, one behind a match at an offset.
RETURN_ERROR_RE = re.compile(r"\breturn\s*error\.")
RETURN_LEAD_RE = re.compile(r"\breturn\s*\Z")
# Any `const std = <rhs>;` binding, and the only right-hand side that may be one.
STD_BIND_RE = re.compile(r"\bconst\s+std\s*=\s*([^;{}]+);")
STD_IMPORT_RE = re.compile(r'\A@import\(\s*"std"\s*\)\Z')
# `const Name = <dotted.path>;` — the one alias shape resolvable without a compiler.
CONST_ALIAS_RE = re.compile(r"\bconst\s+([A-Za-z_]\w*)\s*=\s*([^;{}]+);")
DOTTED_RE = re.compile(r"\A[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*\Z")
ALIAS_HOPS = 4

FN_KW_RE = re.compile(r"\bfn\b")
PAIR_RE = {"()": re.compile(r"[()]"), "{}": re.compile(r"[{}]")}
# Return-type modifiers that carry their own parens; erased before the `!` split.
RET_MODIFIER_RE = re.compile(r"\b(?:callconv|align|addrspace|linksection)\s*\([^()]*\)")
# A container keyword right before a `{` — that brace opens a type, not a body.
CONTAINER_LEAD_RE = re.compile(r"\b(?:error|struct|union|enum|opaque|packed|extern)\s*\Z")

# `std.testing`'s own sentinels: the skip marker plus the `Test…` family its
# `expect*` helpers return. std.testing mints these, so irregex cannot own one —
# and no fault could plausibly be named `Test…`, so this cannot launder drift.
STD_TESTING_RE = re.compile(r"SkipZigTest\Z|Test[A-Z]\w*\Z")

GENERATED_HEADER_RE = re.compile(
    r"^\s*//\s*Code generated\b|^\s*//\s*@generated\b",
    re.IGNORECASE,
)


def declared_members(contract: Path = CONTRACT) -> frozenset[str]:
    """The union of every ``[fault_domains]`` member — the closed vocabulary.

    Fails closed: without the contract block there is no taxonomy to enforce
    against, and treating that as "nothing is declared" would flag every error
    name in the kernel.
    """
    try:
        data = tomllib.loads(contract.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise SystemExit(f"zig-fault-taxonomy: cannot read {contract}: {exc}") from exc
    table = data.get(DOMAINS_TABLE)
    if not isinstance(table, dict) or not table:
        raise SystemExit(f"zig-fault-taxonomy: {contract} declares no [{DOMAINS_TABLE}]")
    members = {m for row in table.values() for m in row.get("members", ())}
    if not members:
        raise SystemExit(f"zig-fault-taxonomy: [{DOMAINS_TABLE}] in {contract} declares no members")
    _check_domain_status_cover(data, contract)
    return frozenset(members)


def _check_domain_status_cover(data: dict[str, object], contract: Path) -> None:
    """Every fault domain must be carried by exactly one ``fault`` status row.

    The five domains fold onto three C-ABI statuses, so the mapping is a
    judgment the contract has to state rather than each reader re-deriving it.
    Fails closed on a domain with no status home — otherwise a sixth domain
    would silently report as whichever neighbor a translator's ``switch``
    happened to reach first.
    """
    domains = data.get(DOMAINS_TABLE)
    statuses = data.get(STATUS_TABLE)
    if not isinstance(domains, dict) or not isinstance(statuses, dict):
        raise SystemExit(f"zig-fault-taxonomy: {contract} declares no [{STATUS_TABLE}]")
    carried: dict[str, list[str]] = {}
    for name, row in statuses.items():
        if not isinstance(row, dict) or row.get("disposition") != "fault":
            continue
        listed = row.get("domains")
        if not isinstance(listed, list) or not listed:
            raise SystemExit(
                f"zig-fault-taxonomy: [{STATUS_TABLE}].{name} has disposition "
                f'"fault" but declares no `domains` in {contract}'
            )
        for d in listed:
            carried.setdefault(str(d), []).append(name)
    if unknown := sorted(set(carried) - set(domains)):
        raise SystemExit(
            f"zig-fault-taxonomy: [{STATUS_TABLE}] carries unknown fault "
            f"domain(s) {', '.join(unknown)} — not in [{DOMAINS_TABLE}]"
        )
    if orphans := sorted(set(domains) - set(carried)):
        raise SystemExit(
            f"zig-fault-taxonomy: fault domain(s) {', '.join(orphans)} are "
            f"carried by no [{STATUS_TABLE}] row — a fault in them has no C-ABI "
            f"status to cross as; add the domain to a `fault` row's `domains`"
        )
    if doubled := sorted(d for d, rows in carried.items() if len(rows) > 1):
        raise SystemExit(
            f"zig-fault-taxonomy: fault domain(s) {', '.join(doubled)} are "
            f"carried by more than one [{STATUS_TABLE}] row — the fold must be "
            f"unambiguous so one fault cannot cross as two statuses"
        )


def _set_literals(code: str) -> list[tuple[re.Match[str], bool, bool]]:
    """Each ``error{…}`` literal with ``(match, is_pub, is_named_const)``.

    The declaration prefix runs back to the previous statement boundary, so a
    wrapped ``pub fn f(…) error{…}!void`` signature is still seen as ``pub``.
    """
    out: list[tuple[re.Match[str], bool, bool]] = []
    for m in SET_RE.finditer(code):
        bound = max(code.rfind(c, 0, m.start()) for c in STATEMENT_BOUNDARY)
        prefix = code[bound + 1 : m.start()]
        out.append((m, bool(re.search(r"\bpub\b", prefix)), bool(NAMED_CONST_RE.search(prefix))))
    return out


def _private_names(sets: list[tuple[re.Match[str], bool, bool]]) -> frozenset[str]:
    """Names this file keeps to itself — declared only in a private `const` set.

    A private named set is deliberate control-flow vocabulary (`error.Bail`); an
    inline set in a private signature is not, because an inferred error set
    carries it out of the file anyway.
    """
    private: set[str] = set()
    public: set[str] = set()
    for m, is_pub, is_named_const in sets:
        names = {i.group(0) for i in IDENT_RE.finditer(m.group(1))}
        (public if is_pub or not is_named_const else private).update(names)
    return frozenset(private - public)


def _consuming_offsets(code: str) -> frozenset[int]:
    """Start offsets of every ``error.X`` that handles a name rather than minting one."""
    out: set[int] = set()
    for ref in REF_RE.finditer(code):
        if PRONG_TAIL_RE.match(code, ref.end()) and not VALUE_LEAD_RE.search(
            code[max(0, ref.start() - 32) : ref.start()]
        ):
            out.add(ref.start())
    out.update(m.start(1) for m in COMPARE_RE.finditer(code))
    return frozenset(out)


def _std_aliases(code: str, text: str) -> dict[str, str] | None:
    """File-local ``const Name = <dotted.path>;`` bindings, or None if `std` isn't std.

    Returns None — meaning "resolve nothing" — unless the file binds ``std``
    itself, in real code, and binds it *only* to ``@import("std")``. Without
    that anchor a file could rebind ``std`` to its own module and every path
    below would be a lie. The literal is read out of the raw `text` at the
    blanked copy's own offsets, because `code_only` has already erased the
    string it turns on.

    A name bound twice is dropped rather than resolved: a second
    ``const MapError = error{ Sneaky };`` inside some function must not be able
    to shelter under the first binding's warrant.
    """
    anchored = False
    for m in STD_BIND_RE.finditer(code):
        if not STD_IMPORT_RE.match(text[m.start(1) : m.end(1)].strip()):
            return None
        anchored = True
    if not anchored:
        return None
    bound: dict[str, set[str]] = {}
    for m in CONST_ALIAS_RE.finditer(code):
        bound.setdefault(m.group(1), set()).add(m.group(2).strip())
    once = {name: rhs.pop() for name, rhs in bound.items() if len(rhs) == 1}
    return {name: rhs for name, rhs in once.items() if DOTTED_RE.match(rhs)}


def _resolves_to_std(path: str, aliases: dict[str, str], hops: int = ALIAS_HOPS) -> bool:
    """Is `path` a declaration *inside* the std module, after local aliasing?

    One hop is the shape that matters (``MapError`` → ``std.posix.MMapError``),
    but a head alias (``const posix = std.posix;`` → ``posix.MMapError``) is the
    same fact spelled one level up, so heads are followed too — bounded, so a
    cyclic pair of aliases terminates instead of recursing.

    Anything that reaches ``std.<something>`` is std's vocabulary by
    construction: there is no way to smuggle a private set in under that root,
    because the root itself is pinned to ``@import("std")`` by `_std_aliases`.
    """
    if not DOTTED_RE.match(path):
        return False
    head, dot, rest = path.partition(".")
    if head == "std":
        return bool(dot)
    target = aliases.get(head)
    return bool(target) and hops > 0 and _resolves_to_std(target + dot + rest, aliases, hops - 1)


def _closing(code: str, open_at: int, pair: str) -> int:
    """Index of the delimiter closing `pair` opened at `open_at`, or -1.

    Hops delimiter to delimiter rather than character to character: a body scan
    is otherwise O(file) per function in interpreted Python, and functions nest.
    """
    depth = 0
    for m in PAIR_RE[pair].finditer(code, open_at):
        depth += 1 if m.group() == pair[0] else -1
        if depth == 0:
            return m.start()
    return -1


def _return_type(code: str, start: int) -> tuple[str, int]:
    """The return type after a parameter list, and the offset of the body's `{`.

    ``("", -1)`` for anything that is not a function *definition*: a prototype
    or a ``fn (u8) void`` type sitting in a struct field or a parameter list
    ends at a ``;``/``,``/unbalanced ``)`` before any body brace. A container
    literal in the return position (``error{…}!void``) is stepped over, so its
    brace is not mistaken for the body.
    """
    depth, i = 0, start
    while i < len(code):
        ch = code[i]
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
            if depth < 0:
                return "", -1
        elif depth == 0 and ch in ";,":
            return "", -1
        elif depth == 0 and ch == "{":
            if not CONTAINER_LEAD_RE.search(code[start:i]):
                return code[start:i], i
            close = _closing(code, i, "{}")
            if close < 0:
                return "", -1
            i = close
        i += 1
    return "", -1


def _fn_bodies(code: str, aliases: dict[str, str]) -> list[tuple[int, int, bool]]:
    """``(body_start, body_end, declares_a_std_error_set)`` per function, in order.

    Nested functions are kept — that is the whole point of resolving the
    *innermost* enclosing body — while a ``fn`` appearing inside a parameter
    list (a function-typed parameter) is skipped, since it declares no body.
    """
    out: list[tuple[int, int, bool]] = []
    cursor = 0
    for m in FN_KW_RE.finditer(code):
        if m.start() < cursor:
            continue
        lp = code.find("(", m.end())
        if lp < 0:
            break
        rp = _closing(code, lp, "()")
        if rp < 0:
            break
        cursor = rp
        ret, brace = _return_type(code, rp + 1)
        end = _closing(code, brace, "{}") if brace >= 0 else -1
        if end < 0:
            continue
        ret = RET_MODIFIER_RE.sub(" ", ret)
        bang = ret.find("!")
        std_set = bang > 0 and _resolves_to_std(ret[:bang].strip(), aliases)
        out.append((brace, end + 1, std_set))
    return sorted(out)


def _never(_off: int) -> bool:
    """The `_std_returned` predicate for a file the rule cannot apply to."""
    return False


def _std_returned(code: str, text: str) -> Callable[[int], bool]:
    """``offset → True`` when that ``error.X`` is returned into a std error set.

    **Why this cannot be gamed while the code compiles.** A function declaring
    an explicit error set may only ``return`` a member of it — the Zig compiler
    rejects anything else at that very token. So the exclusion never has to know
    what std's members *are*: it only has to be sure the declared set is std's,
    and the compiler supplies the rest. Minting a private name here is not a
    finding this rule hides, it is a build failure.

    Everything about the rule is chosen to keep that guarantee load-bearing:

    * **Per function, innermost.** A nested ``fn`` inside a std-set body is
      judged on its own signature, so wrapping new vocabulary in a closure buys
      nothing, and the rest of the file is untouched.
    * **``return error.X`` only.** An ``error.X`` that is bound to a local, or
      handed to a helper, or listed in an ``error{…}`` declaration inside the
      body, is not coerced into the declared set, so the compiler proves
      nothing about it and neither does this.
    * **An explicit set only.** ``!T`` infers its error set from whatever the
      body returns, which is the opposite of a closed vocabulary, so an
      inferred signature is never excluded.
    """
    # Two cheap prechecks before any brace matching: the file must contain the
    # only form this can exclude, and must bind `std` to std. Almost every file
    # leaves here, so the scan pays for function bodies where they can matter.
    aliases = _std_aliases(code, text) if RETURN_ERROR_RE.search(code) else None
    if aliases is None:
        return _never
    bodies = _fn_bodies(code, aliases)
    if not any(std_set for _s, _e, std_set in bodies):
        return _never
    starts = [s for s, _e, _std in bodies]

    def excluded(off: int) -> bool:
        if not RETURN_LEAD_RE.search(code[max(0, off - 16) : off]):
            return False
        # Bodies nest or are disjoint, so the first span containing `off` found
        # while walking back from the latest start is the innermost one.
        for i in range(bisect.bisect_right(starts, off) - 1, -1, -1):
            _s, e, std_set = bodies[i]
            if off < e:
                return std_set
        return False

    return excluded


def count_undeclared(text: str, declared: frozenset[str]) -> PatternCount:
    """Per-name count of undeclared error names produced by one Zig source text."""
    code = code_only(text)
    in_test = range_membership(test_block_ranges(code))
    sets = _set_literals(code)
    private = _private_names(sets)
    consuming = _consuming_offsets(code)
    std_returned = _std_returned(code, text)

    by_name: dict[str, int] = {}

    def hit(name: str, offset: int) -> None:
        if name in declared or name in private or in_test(offset) or STD_TESTING_RE.match(name):
            return
        by_name[name] = by_name.get(name, 0) + 1

    for m, _is_pub, _is_named_const in sets:
        base = m.start(1)
        for ident in IDENT_RE.finditer(m.group(1)):
            hit(ident.group(0), base + ident.start())
    for ref in REF_RE.finditer(code):
        if ref.start() not in consuming and not std_returned(ref.start()):
            hit(ref.group(1), ref.start())

    return PatternCount(dict(sorted(by_name.items())))


def _scan_one(path: Path, declared: frozenset[str]) -> FileCount | None:
    # Fail closed: an unreadable source file is an error, never a silent pass —
    # the ratchet must not report green over unscanned code.
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise SystemExit(f"zig-fault-taxonomy: cannot scan {path}: {exc}") from exc
    if any(GENERATED_HEADER_RE.match(line) for line in head_lines(text)):
        return None
    detail = count_undeclared(text, declared)
    if detail.total == 0:
        return None
    return FileCount(rel_path=str(path.relative_to(REPO)), count=detail.total, detail=detail)


def scan() -> list[FileCount]:
    declared = declared_members()
    files = walk_source_files(
        ROOTS,
        exts=frozenset({".zig"}),
        skip_dirs=SKIP_DIR_PARTS,
        skip_name_suffixes=SKIP_NAME_SUFFIXES,
    )
    return [fc for fc in (_scan_one(p, declared) for p in files) if fc]


_HEADER = """\
# zig-fault-taxonomy ratchet baseline — undeclared error names per Zig file.
#
# Fault-channel law 2: the fault vocabulary is closed. Every error name irregex
# PRODUCES must be a member of a [fault_domains] domain in
# contract/engine.toml (mirrored by src/fault.zig), so a sixth spelling of
# `Corrupt` cannot accrete the way BadFormat / CorruptIndex did.
#
# Excluded structurally: test vocabulary (*_test.zig, *_fuzz.zig, inline `test`
# blocks, and std.testing's own SkipZigTest / Test… family), file-private control
# flow (a non-pub named `const` error set — the shadow rewriter's `error.Bail`),
# consuming positions (a `=>` prong label or an `==` operand handles a std
# error, it does not mint one), and `return error.X` from a function whose
# declared error set resolves to std's own (portal's `MapError!Mapping`, where
# the compiler already forbids returning anything std did not name).
#
# Update rule: monotonically decrease only. Refresh after cleanup:
#     python3 quality/ratchets/run.py fault-taxonomy --refresh
"""

_FIX_HINT = """\
Fix by naming the fact once, in the declared vocabulary:
  • a new spelling of an existing fact (BadFormat/CorruptIndex → Corrupt)
      → import src/fault.zig and return the declared member
  • a declinature ("a slower tier can answer this") — unsupported_syntax,
    freshness_unprovable, index_absent, not_worthwhile, capability_missing
      → it is not a fault at all; return fault.Answer(T){ .declined = … }
  • a genuinely new fault the taxonomy lacks
      → add the member to the right domain in src/fault.zig AND to
        [fault_domains] in contract/engine.toml
  • file-private recursive-descent control flow
      → declare it as a non-pub `const Err = error{…}` and convert it at the
        module boundary, exactly as the PCRE2 shadow rewriter does
"""


def main(argv: list[str] | None = None) -> int:
    return run_count_cli(
        scan=scan,
        baseline_path=BASELINE,
        header=_HEADER,
        label="undeclared Zig fault names",
        refresh_cmd="python3 quality/ratchets/run.py fault-taxonomy --refresh",
        fix_hint=_FIX_HINT,
        argv=argv,
    )


if __name__ == "__main__":
    sys.exit(main())
