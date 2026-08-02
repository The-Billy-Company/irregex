"""The kernel's declared surface, mirrored — never restated.

Everything a caller can rely on that is *decided in the contract* rather than in
Python: the ABI and engine versions, the request options and exit codes
(`abi`), the calibration bands a distance or a coding gain is graded against
(`grades`), and the analytic row-schema table the decoder walks (`table`).

`../schema.gen.py` is lowered from `contract/analytic.toml` by
`tools/build_schema_tables.py` and stays where the generator puts it; `table` loads it and adds the
indexes a decoder needs. Nothing in this package computes a threshold — Zig owns
calibration, and a second opinion here would be a second answer.
"""

from __future__ import annotations

from .abi import (
    ABI_VERSION,
    ENGINE_VERSION,
    EXIT_ERROR,
    EXIT_MATCHED,
    EXIT_NO_MATCH,
    MATCH_KINDS,
    REQUEST_OPTIONS,
    contract_path,
)
from .grades import Channel, Grade, grade_of
from .table import DIGEST, ENUMS, SCHEMAS, VERBS, Field, Tag

__all__ = [
    "ABI_VERSION",
    "DIGEST",
    "ENGINE_VERSION",
    "ENUMS",
    "EXIT_ERROR",
    "EXIT_MATCHED",
    "EXIT_NO_MATCH",
    "MATCH_KINDS",
    "REQUEST_OPTIONS",
    "SCHEMAS",
    "VERBS",
    "Channel",
    "Field",
    "Grade",
    "Tag",
    "contract_path",
    "grade_of",
]
