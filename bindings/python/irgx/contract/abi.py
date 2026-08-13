"""Runtime mirror of the contracts this engine is answerable for. The package embeds their load-bearing constants so it has no runtime dependency on a repo file (a wheel ships without them); the package's parity test reads the canonical TOML and asserts this mirror matches it — the standard mirror-plus-parity-test shape, so the two cannot silently drift.

A product's own contract is mirrored in that product's own package (the exact
face's contract module carries its distribution names and tool boundary), for
the same reason its header is: a mirror can only be gated where the canonical
file lives, and a substrate that mirrored its consumers could not be tested
without checking them out.
"""

from __future__ import annotations

import os
from pathlib import Path

# The contracts this package mirrors: `engine` is the kernel's request surface
# and version axes, `analytic` is the ecosystem-wide verb/op plane this engine
# dispatches, and `kinship` is the compression vocabulary its row decoder must
# know to name a grade or a channel. The first two are authored here; `kinship`
# is authored by the kinship package and vendored beside them by
# `tools/sync_contract.py`, under a drift gate in that package's own CI.
CONTRACTS = ("analytic", "engine", "kinship")


# Mirrors `[meta]` in contract/engine.toml (versions).
ABI_VERSION = 2
ENGINE_VERSION = "2.1.1"  # x-release-please-version

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

# The agent / code-place seam that used to be mirrored here moved to the exact
# face's own contract module, beside the `surface.toml` that declares it:
# nothing in this engine reads it, and mirroring it here meant the substrate's
# own parity test could not run without that face's checkout to read the
# canonical file from.


def contract_path(name: str = "engine") -> Path:
    """Path to one canonical contract TOML, in this checkout.

    `IRGX_<NAME>_CONTRACT` overrides. Otherwise the file is looked for at every
    ancestor rather than at a counted depth — a fixed index was already off by
    one before the repositories split, and because an unreadable contract used to
    be a skip rather than a failure, the mirror below went ungated for its whole
    life. It is a hard failure now; see the parity test. Failing that, the path
    this layout would have used is returned anyway, so a caller reporting the miss
    names somewhere real. It may legitimately not exist in an installed wheel.

    It never looks sideways. It used to fall back to `<author>/contract/…` in the
    authoring sibling, which is how a gate ends up passing on whatever happened to
    be cloned beside it; all three contracts are committed here, the kinship
    package's `kinship.toml` included, vendored by `tools/sync_contract.py`.
    """
    if override := os.environ.get(f"IRGX_{name.upper()}_CONTRACT"):
        return Path(override)
    here = Path(__file__).resolve()
    home = f"contract/{name}.toml"
    for base in here.parents:
        if (candidate := base / home).is_file():
            return candidate
    return here.parents[3] / home


# C declarations mirroring `include/irgx.h` — this package's own frozen input,
# and only ever that. The engine handle, the cancellation token, and the status
# vocabulary are the substrate's; a product's session and match record are that
# product's, declared in that product's header and mirrored in that product's
# own package (its native module, for each face). A face's declarations are
# appended to this text at `cdef` time by `runtime.loader`, so cffi still sees
# one type universe while each half is checked against the header that owns it.
CDEF = """
typedef struct irgx_engine irgx_engine;
typedef struct irgx_cancel irgx_cancel;
int32_t irgx_engine_open(const char *const *roots, size_t nroots, irgx_engine **out);
void irgx_engine_close(irgx_engine *engine);
int32_t irgx_cancel_new(irgx_cancel **out);
void irgx_cancel_request(irgx_cancel *token);
void irgx_cancel_free(irgx_cancel *token);
const char *irgx_status_message(int32_t code);
"""

# The analytic plane: one dispatch, one self-describing row type, and
# schema introspection. Declared separately because these symbols may be absent
# from a library built before the plane landed — a declinature (answer through
# the subprocess tier), not a failure — while cffi fixes a library's type
# universe at `cdef` time and so must be told about them regardless.
ANALYTIC_CDEF = """
typedef struct { const uint8_t *ptr; size_t len; } irgx_text;
typedef struct irgx_row irgx_row;
typedef struct {
  uint32_t tag; uint32_t reserved; int64_t integer; double real;
  const void *ptr; size_t len;
} irgx_value;
struct irgx_row {
  uint32_t schema_id; uint32_t nvalues; uint64_t present; const irgx_value *values;
};
typedef struct {
  const char *name; uint32_t tag; uint32_t nested; int32_t optional; int32_t reserved;
} irgx_field;
typedef struct {
  uint32_t struct_size; uint32_t id; const char *name;
  uint32_t nfields; uint32_t reserved; const irgx_field *fields;
} irgx_schema;
typedef struct {
  uint32_t struct_size; uint32_t source; uint64_t elapsed_ns;
  uint64_t files_considered; uint64_t refreshed; uint64_t foreign;
  uint64_t omitted; uint64_t rows;
} irgx_stats;
/* The five analytic parameter layouts. They are the SUBSTRATE's types — one
 * definition each in `src/surface/ffi/rows.zig`, which is why one dispatch can
 * lower every verb — and each product header re-declares the family its own
 * verbs take under its own prefix (a kinship-params, a compose-params, and a
 * rank-params spelling, one per face). Named `irgx_*` here because a mirror
 * should say who owns the layout; an earlier spelling gave all five the exact
 * face's prefix, which named a struct that face's header does not declare and
 * implied the search face owned the other two faces' parameters. A cffi struct
 * name is local to this type universe and ABI mode matches on layout, so the
 * name is free to be the true one. */
typedef struct {
  uint32_t struct_size; uint32_t flags; const uint8_t *target; size_t target_len;
  uint32_t channel; uint32_t unit; double max_distance; double min_echo;
  uint32_t min_grade; uint32_t min_size; uint32_t min_lines; uint32_t top;
} irgx_kinship_params;
typedef struct {
  uint32_t struct_size; uint32_t flags; const uint8_t *query; size_t query_len;
  uint32_t top; uint32_t reserved;
} irgx_retrieval_params;
typedef struct {
  uint32_t struct_size; uint32_t flags; const irgx_text *patterns; size_t npatterns;
  const uint8_t *under; size_t under_len; uint32_t top; uint32_t reserved;
} irgx_sweep_params;
typedef struct {
  uint32_t struct_size; uint32_t flags; const uint8_t *text; size_t text_len;
  const irgx_text *patterns; size_t npatterns; double max_distance; double min_echo;
  uint32_t budget; uint32_t top;
} irgx_compose_params;
typedef struct {
  uint32_t struct_size; uint32_t flags; const uint8_t *pattern; size_t pattern_len;
  uint32_t top; uint32_t reserved;
} irgx_rank_params;
typedef struct irgx_rows irgx_rows;
/* No producer is declared here. `<face>_run` is EXPORTED by a product library
 * and declared in that product's own header, so its mirror travels with that
 * face — in that face's own native module — and `runtime.loader` appends it
 * to this text before the `cdef`. What is the substrate's is the plane the
 * producers hand rows back through: the cursor, the stats, the schema table,
 * and the five parameter layouts above. That split is why this mirror can be
 * checked against `irgx.h` alone, with no product checked out beside it.
 *
 * The dispatch stays expressible because `analytic._in_process` reads the entry
 * symbol from the generated verb table and resolves it on the loaded library —
 * a symbol the process has not mapped is a declinature, one tier down, not an
 * error. */
int32_t irgx_rows_next(irgx_rows *rows, irgx_row *out);
int32_t irgx_rows_next_batch(irgx_rows *rows, irgx_row *out, size_t cap,
                                size_t *written);
int32_t irgx_rows_stats(irgx_rows *rows, irgx_stats *out);
void irgx_rows_close(irgx_rows *rows);
const char *irgx_schema_digest(void);
uint32_t irgx_schema_count(void);
int32_t irgx_schema_get(uint32_t id, irgx_schema *out);
"""
