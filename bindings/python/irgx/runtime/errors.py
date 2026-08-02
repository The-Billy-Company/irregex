"""Typed failures for the GIST search API. Every failure is a value a caller can catch — a bad pattern never terminates the host process the way the engine's own CLI `die()`/exit would in-process."""

from __future__ import annotations


class GistError(Exception):
    """Base for every GIST search failure."""


class GistNotFoundError(GistError):
    """The `gist` binary could not be located (env `GIST_BIN`, PATH, or the repo's `zig-out/bin/gist`). Build it with `zig build -Doptimize=ReleaseFast`."""


class UnsupportedPatternError(GistError):
    """The pattern is outside the selected matcher; choose ``engine="auto"`` or ``"pcre2"`` for lookaround/backreferences."""


class BadPatternError(GistError):
    """The pattern is malformed in EVERY grammar the engine has — the message names the defect and points at the offending byte. A sibling of :class:`UnsupportedPatternError` rather than a subclass, because the two ask for opposite responses: that one says *retry on another engine*, this one says *fix the pattern*, and no ``engine=`` choice lifts it."""


class SearchFailedError(GistError):
    """The engine exited 2 for an I/O or walk reason (an unreadable directory, a missing explicit path) — fail-loud, never a silent empty result."""


class SchemaDriftError(GistError):
    """The loaded library's row-schema digest disagrees with the table this binding was generated from, so a decoded row would be a plausible lie. Names the schemas that differ. Rebuild the library and rerun `python3 tools/build_schema_tables.py`; never decode past this."""


class RowDecodeError(GistError):
    """A row did not honor its declared schema — a required field arrived absent, or the value count disagreed with the field count. A kernel or transport bug, not a caller's."""
