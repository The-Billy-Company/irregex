"""Runtime mirror of the three search contracts. The package embeds their load-bearing constants so it has no runtime dependency on a repo file (a wheel ships without them); the package's parity test reads the canonical TOML and asserts this mirror matches it — the standard mirror-plus-parity-test shape, so the two cannot silently drift."""

from __future__ import annotations

import os
from pathlib import Path

# The three contracts, split by who authors the thing described: `engine` is the
# kernel's request surface and version axes, `kinship` is relate's compression
# vocabulary, `surface` is this repo's own wire schema and ABI vocabulary. All
# three are present in a `gist` checkout — the two it does not author are
# vendored beside its own by `tools/sync_contract.py`.
CONTRACTS = ("analytic", "engine", "kinship", "surface")

# Where a contract can be: beside a repo root (this checkout, and the monorepo)
# or in the authoring sibling. Probed at every ancestor rather than at a counted
# depth — a fixed index was already off by one before the split, and because an
# unreadable contract used to be a skip rather than a failure, the mirror below
# went ungated for its whole life. It is a hard failure now; see the parity test.
_AUTHORS = {"analytic": "irregex", "engine": "irregex", "kinship": "relate", "surface": "gist"}


# Mirrors `[meta]` in contract/engine.toml (versions) and `[package]` in
# contract/surface.toml (dist / import names).
ABI_VERSION = 2
ENGINE_VERSION = "0.3.0"
PACKAGE_DIST = "gist"
PACKAGE_IMPORT = "gist"

# Mirrors `[request_options]` keys in irregex/contract/engine.toml.
REQUEST_OPTIONS: frozenset[str] = frozenset(
    {
        "pattern",
        "paths",
        "fixed",
        "ignore_case",
        "smart_case",
        "word",
        "quiet",
        "invert",
        "globs",
        "iglobs",
        "types",
        "not_types",
        "before",
        "after",
        "context",
        "max_count",
        "max_depth",
        "hidden",
        "no_ignore",
        "follow",
        "no_index",
        "engine",
        "multiline",
        "multiline_dotall",
        "unicode",
    }
)

# Mirrors `[match_kinds]` and `[exit_codes]` in irregex/contract/engine.toml.
MATCH_KINDS: frozenset[str] = frozenset({"match", "context"})
EXIT_MATCHED = 0
EXIT_NO_MATCH = 1
EXIT_ERROR = 2

# Mirrors `[tool_boundary]` in contract/surface.toml — the agent / code-place seam. `ALIASES`
# rename a tool-boundary param onto its canonical request option; `ROUTING_KEYS`
# are recognized-but-ignored (place/transport routing stays outside GIST).
ALIASES: dict[str, str] = {
    "query": "pattern",
    "glob": "globs",
    "context_lines": "context",
}
ROUTING_KEYS: frozenset[str] = frozenset({"place", "at", "semantic"})


def contract_path(name: str = "engine") -> Path:
    """Path to one canonical contract TOML; may not exist in an installed wheel.

    `IRREGEX_<NAME>_CONTRACT` overrides. Otherwise the file is looked for at
    every ancestor, in this checkout first and then in the sibling that authors
    it. Failing both, the path this layout would have used is returned anyway,
    so a caller reporting the miss names somewhere real.
    """
    if override := os.environ.get(f"IRREGEX_{name.upper()}_CONTRACT"):
        return Path(override)
    here = Path(__file__).resolve()
    homes = (f"contract/{name}.toml", f"{_AUTHORS[name]}/contract/{name}.toml")
    for base in here.parents:
        for home in homes:
            if (candidate := base / home).is_file():
                return candidate
    return here.parents[3] / homes[0]


# C declarations mirroring `include/gist.h` — the other frozen input this
# package mirrors. cffi ABI mode needs no struct field layout beyond what we
# read, but the full structs let it compute offsets for the callback's
# `gist_match *`. Kept here rather than in the loader so the header has one
# mirror site, next to the contract's.
CDEF = """
typedef struct gist_session gist_session;
typedef struct {
  const uint8_t *text; size_t len; size_t start; size_t end;
} gist_submatch;
typedef struct {
  const uint8_t *path; size_t path_len; uint64_t line_number;
  const uint8_t *line; size_t line_len;
  const gist_submatch *submatches; size_t nsubmatches;
  uint32_t kind;
} gist_match;
typedef int32_t (*gist_match_fn)(void *ctx, const gist_match *m);
typedef struct {
  uint32_t struct_size; uint32_t flags; uint64_t max_count;
  uint64_t before_context; uint64_t after_context;
} gist_search_options;
uint32_t gist_abi_version(void);
int32_t gist_open(const char *const *roots, size_t nroots, gist_session **out);
int32_t gist_search(gist_session *s, const uint8_t *pattern,
                    size_t pattern_len, const gist_search_options *options,
                    gist_match_fn on_match, void *ctx);
void gist_close(gist_session *s);

/* the pull-cursor surface: open an engine, materialize a cursor,
   walk it with next / next_batch — no C-to-Python callback, so cffi releases
   the GIL for the duration of each native pull. */
typedef struct irregex_engine irregex_engine;
typedef struct gist_cursor gist_cursor;
typedef struct irregex_cancel irregex_cancel;
typedef struct {
  uint32_t struct_size; uint32_t flags; uint64_t max_count;
  uint64_t before_context; uint64_t after_context;
  const uint8_t *pattern; size_t pattern_len;
  uint64_t timeout_ns; size_t max_results; irregex_cancel *cancel;
} gist_search_request;
int32_t irregex_engine_open(const char *const *roots, size_t nroots, irregex_engine **out);
void irregex_engine_close(irregex_engine *engine);
int32_t irregex_cancel_new(irregex_cancel **out);
void irregex_cancel_request(irregex_cancel *token);
void irregex_cancel_free(irregex_cancel *token);
int32_t gist_search_cursor(irregex_engine *engine, const gist_search_request *request,
                              gist_cursor **out);
int32_t gist_cursor_next(gist_cursor *cursor, gist_match *out);
int32_t gist_cursor_next_batch(gist_cursor *cursor, gist_match *out, size_t cap,
                                  size_t *written);
int32_t gist_cursor_matched(gist_cursor *cursor);
void gist_cursor_close(gist_cursor *cursor);
const char *irregex_status_message(int32_t code);
"""

# The analytic plane: one dispatch, one self-describing row type, and
# schema introspection. Declared separately because these symbols may be absent
# from a library built before the plane landed — a declinature (answer through
# the subprocess tier), not a failure — while cffi fixes a library's type
# universe at `cdef` time and so must be told about them regardless.
ANALYTIC_CDEF = """
typedef struct { const uint8_t *ptr; size_t len; } irregex_text;
typedef struct irregex_row irregex_row;
typedef struct {
  uint32_t tag; uint32_t reserved; int64_t integer; double real;
  const void *ptr; size_t len;
} irregex_value;
struct irregex_row {
  uint32_t schema_id; uint32_t nvalues; uint64_t present; const irregex_value *values;
};
typedef struct {
  const char *name; uint32_t tag; uint32_t nested; int32_t optional; int32_t reserved;
} irregex_field;
typedef struct {
  uint32_t struct_size; uint32_t id; const char *name;
  uint32_t nfields; uint32_t reserved; const irregex_field *fields;
} irregex_schema;
typedef struct {
  uint32_t struct_size; uint32_t source; uint64_t elapsed_ns;
  uint64_t files_considered; uint64_t refreshed; uint64_t foreign;
  uint64_t omitted; uint64_t rows;
} irregex_stats;
typedef struct {
  uint32_t struct_size; uint32_t flags; const uint8_t *target; size_t target_len;
  uint32_t channel; uint32_t unit; double max_distance; double min_echo;
  uint32_t min_grade; uint32_t min_size; uint32_t min_lines; uint32_t top;
} gist_kinship_params;
typedef struct {
  uint32_t struct_size; uint32_t flags; const uint8_t *query; size_t query_len;
  uint32_t top; uint32_t reserved;
} gist_retrieval_params;
typedef struct {
  uint32_t struct_size; uint32_t flags; const irregex_text *patterns; size_t npatterns;
  const uint8_t *under; size_t under_len; uint32_t top; uint32_t reserved;
} gist_sweep_params;
typedef struct {
  uint32_t struct_size; uint32_t flags; const uint8_t *text; size_t text_len;
  const irregex_text *patterns; size_t npatterns; double max_distance; double min_echo;
  uint32_t budget; uint32_t top;
} gist_compose_params;
typedef struct {
  uint32_t struct_size; uint32_t flags; const uint8_t *pattern; size_t pattern_len;
  uint32_t top; uint32_t reserved;
} gist_rank_params;
typedef struct irregex_rows irregex_rows;
int32_t gist_run(irregex_engine *engine, uint32_t op, const void *params,
                             irregex_cancel *cancel, irregex_rows **out);
/* Kinship / sweep / compose left with the libraries that own them. Layouts
 * of the params structs above match relate_* / blast_* in those headers —
 * only the producer symbol moved. Declared, never dlopened here: cffi fixes a
 * type universe at cdef time, so the shared substrate must name every producer
 * it may describe, while which library a process actually opens stays that
 * package's own decision. */
int32_t relate_run(irregex_engine *engine, uint32_t op, const void *params,
                   irregex_cancel *cancel, irregex_rows **out);
int32_t blast_run(irregex_engine *engine, uint32_t op, const void *params,
                  irregex_cancel *cancel, irregex_rows **out);
int32_t irregex_rows_next(irregex_rows *rows, irregex_row *out);
int32_t irregex_rows_next_batch(irregex_rows *rows, irregex_row *out, size_t cap,
                                size_t *written);
int32_t irregex_rows_stats(irregex_rows *rows, irregex_stats *out);
void irregex_rows_close(irregex_rows *rows);
const char *irregex_schema_digest(void);
uint32_t irregex_schema_count(void);
int32_t irregex_schema_get(uint32_t id, irregex_schema *out);
"""
