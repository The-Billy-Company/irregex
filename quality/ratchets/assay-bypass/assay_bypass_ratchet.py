#!/usr/bin/env python3
"""Zig assay-bypass ratchet — no ``std.debug.print`` in production code.

Fault-channel law 6: ``assay`` is the package's one diagnostic channel. It
exists because ~90 scattered ``std.debug.print`` calls made the never-write
contract ("an embedding host must never see us write to stdout/stderr") an audit
instead of a property of one routing point. Every surviving bypass is three live
defects at once:

* under a ``dark`` sink it escapes to the host's **real** stderr, breaking the
  never-write contract outright;
* under a ``buffer`` sink it lands on the daemon's stderr instead of the
  connected client's, so the diagnostic is written where nobody reads it;
* during a ``--json`` run it emits English prose into a stream a consumer is
  parsing as NDJSON.

The rule: one finding per ``std.debug.print(`` call in production Zig. Two
exclusions are structural rather than preferences:

* ``src/assay/assay.zig`` and ``src/assay/channel.zig`` **are** the sink — the
  stderr arm of the channel is literally ``.stderr => std.debug.print(fmt, args)``.
  Counting them would make the ratchet circular, so it would either always fail
  or be silenced by lifting its own baseline.
* ``*_test.zig`` / ``*_fuzz.zig`` files and inline ``test "…" { … }`` blocks — a
  test writing to stderr is fine; there is no embedding host to protect and no
  ``--json`` consumer to corrupt.

Matching runs on a comment/string-blanked copy of each file
(``_lib/zigtext.py``), so ``std.debug.print`` *named in a doc comment* — as
``src/surface/cli/outcome.zig`` does, precisely to record that it routes through
``assay.diag`` instead — is prose and does not count.

Scope: ``src/**/*.zig``, minus the exclusions above, ``*.gen.zig``, and
generated-header files.

Run via ``python3 quality/ratchets/run.py assay-bypass``; refresh with the same
command plus ``--refresh``.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from _lib import (  # noqa: E402
    FileCount,
    code_only,
    head_lines,
    range_membership,
    run_count_cli,
    test_block_ranges,
    walk_source_files,
)

REPO = Path(__file__).resolve().parents[3]
BASELINE = Path(__file__).resolve().parent / "assay-bypass.baseline"

SRC = REPO / "src"
ROOTS = (SRC,)
SKIP_DIR_PARTS = {"zig-out", ".zig-cache", "node_modules", "target"}
SKIP_NAME_SUFFIXES = ("_test.zig", "_fuzz.zig", ".gen.zig")

# The channel's own implementation — exempt or the ratchet is circular.
SINK_FILES = frozenset({SRC / "assay" / "assay.zig", SRC / "assay" / "channel.zig"})

PRINT_RE = re.compile(r"\bstd\.debug\.print\s*\(")
GENERATED_HEADER_RE = re.compile(
    r"^\s*//\s*Code generated\b|^\s*//\s*@generated\b",
    re.IGNORECASE,
)


def count_bypasses(text: str) -> int:
    """``std.debug.print(`` calls in one Zig source text, outside inline tests."""
    code = code_only(text)
    in_test = range_membership(test_block_ranges(code))
    return sum(1 for m in PRINT_RE.finditer(code) if not in_test(m.start()))


def _scan_one(path: Path) -> FileCount | None:
    # Fail closed: an unreadable source file is an error, never a silent pass.
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise SystemExit(f"zig-assay-bypass: cannot scan {path}: {exc}") from exc
    if any(GENERATED_HEADER_RE.match(line) for line in head_lines(text)):
        return None
    count = count_bypasses(text)
    if count == 0:
        return None
    return FileCount(rel_path=str(path.relative_to(REPO)), count=count)


def scan() -> list[FileCount]:
    files = walk_source_files(
        ROOTS,
        exts=frozenset({".zig"}),
        skip_dirs=SKIP_DIR_PARTS,
        skip_name_suffixes=SKIP_NAME_SUFFIXES,
    )
    return [fc for p in files if p not in SINK_FILES and (fc := _scan_one(p))]


_HEADER = """\
# zig-assay-bypass ratchet baseline — std.debug.print sites per Zig file.
#
# Fault-channel law 6: assay owns the one diagnostic channel. A direct
# std.debug.print escapes a `dark` sink (breaking the never-write contract),
# lands on the daemon's stderr instead of the client's under a `buffer` sink,
# and emits prose during a --json run. Route it through `assay.diag` instead.
#
# Exempt structurally: src/assay/assay.zig + src/assay/channel.zig ARE the sink
# (`.stderr => std.debug.print`), and *_test.zig / *_fuzz.zig / inline `test`
# blocks are out of scope. A mention inside a comment is prose, not a call.
#
# Update rule: monotonically decrease only. Refresh after cleanup:
#     python3 quality/ratchets/run.py assay-bypass --refresh
"""

_FIX_HINT = """\
Route the write through the one channel:
  • a diagnostic / note / hint  → `assay.diag(...)` (honors sink + --json + GIST_TRACE)
  • a rendered stdout payload   → write to the caller's own writer, not stderr
  • a fatal message             → the command plane's `die()` / `oom()`, which
                                  themselves route through assay
Never re-add std.debug.print outside src/assay/{assay,channel}.zig — that file
pair is the sink, and everything else has a channel to use.
"""


def main(argv: list[str] | None = None) -> int:
    return run_count_cli(
        scan=scan,
        baseline_path=BASELINE,
        header=_HEADER,
        label="Zig assay-channel bypasses",
        refresh_cmd="python3 quality/ratchets/run.py assay-bypass --refresh",
        fix_hint=_FIX_HINT,
        argv=argv,
    )


if __name__ == "__main__":
    sys.exit(main())
