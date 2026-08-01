"""Shared scaffolding for count-based per-file drift ratchets."""

from .ratchet import (
    DIM,
    GREEN,
    RED,
    RESET,
    YELLOW,
    Diff,
    FileCount,
    PatternCount,
    diff_counts,
    head_lines,
    range_membership,
    read_baseline,
    run_count_cli,
    walk_source_files,
    write_baseline,
)
from .zigtext import code_only, test_block_ranges

__all__ = (
    "DIM",
    "GREEN",
    "RED",
    "RESET",
    "YELLOW",
    "Diff",
    "FileCount",
    "PatternCount",
    "code_only",
    "diff_counts",
    "head_lines",
    "range_membership",
    "read_baseline",
    "run_count_cli",
    "test_block_ranges",
    "walk_source_files",
    "write_baseline",
)
