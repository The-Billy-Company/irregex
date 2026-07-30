#!/usr/bin/env python3
r"""Lower the analytic-plane row schemas into one generated table per language.

The analytic C ABI (ADR-377) returns ONE self-describing row for all seventeen
verbs: a schema id, a presence mask, and a flat `irregex_value` array. What that
array MEANS lives in `contract/search_api.toml` — `[row_enums]`, `[row_schemas]`,
`[analytic.verbs]`. This generator is the single source that lowers those tables
into every consumer, so a decoder is never hand-mirrored:

    src/surface/ffi/schema.gen.zig          the engine's own table (+ digest)
    bindings/python/irregex/schema.gen.py   the Python decoder's table
    bindings/rust/src/schema.gen.rs         the Rust decoder's table
    bindings/go/schema_gen.go               the Go decoder's table

All four carry the SAME digest — a sha256 over the canonical serialization of
the whole table. `irregex_schema_digest()` returns the engine's; a binding
compares it to its own generated constant at load, so a stale shared library is
a loud startup failure rather than a silently mis-decoded row.

stdlib-only and deterministic, so `--check` is a sound regenerate-and-diff drift
gate (CI-hermetic; no network), exactly like the sibling table generators here.

Run: python3 pkg/kernels/irregex/tools/build_schema_tables.py           # write
     python3 pkg/kernels/irregex/tools/build_schema_tables.py --check   # diff only
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path
import sys
import tomllib

HERE = Path(__file__).resolve().parent
KERNEL = HERE.parent
CONTRACT = KERNEL / "contract" / "search_api.toml"

# Value tags — the wire discriminant, mirrored in include/irregex.h. Order IS
# the numbering, so this tuple is append-only.
TAGS = ("text", "i64", "f64", "bool", "enum", "texts", "rows")
MAX_FIELDS = 64  # the row presence mask is one u64

BANNER = "build_schema_tables.py"


@dataclass(frozen=True, slots=True)
class Field:
    name: str
    tag: int
    nested: int  # rows: schema id · enum: enum id · else 0
    optional: bool


@dataclass(frozen=True, slots=True)
class Schema:
    id: int
    name: str
    detail: str
    fields: tuple[Field, ...]


@dataclass(frozen=True, slots=True)
class Enum:
    id: int
    name: str
    variants: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Verb:
    op: int
    name: str
    params: str
    schema: int
    stream: str


@dataclass(frozen=True, slots=True)
class Table:
    enums: tuple[Enum, ...]
    schemas: tuple[Schema, ...]
    verbs: tuple[Verb, ...]
    digest: str


def load(path: Path = CONTRACT) -> Table:
    """Parse the contract into the resolved table, or die with the drift."""
    doc = tomllib.loads(path.read_text(encoding="utf-8"))
    raw_enums, raw_schemas = doc["row_enums"], doc["row_schemas"]
    raw_verbs, raw_params = doc["analytic"]["verbs"], doc["analytic"]["params"]

    enums = tuple(
        sorted(
            (Enum(e["id"], name, tuple(e["variants"])) for name, e in raw_enums.items()),
            key=lambda e: e.id,
        )
    )
    enum_id = {e.name: e.id for e in enums}
    schema_id = {name: s["id"] for name, s in raw_schemas.items()}

    schemas: list[Schema] = []
    for name, s in raw_schemas.items():
        fields: list[Field] = []
        for f in s["fields"]:
            kind, _, arg = f["type"].partition(":")
            if kind not in TAGS:
                _die(f"row_schemas.{name}.{f['name']}: unknown type {f['type']!r}")
            nested = 0
            if kind == "enum":
                nested = enum_id.get(arg, 0) or _die(f"{name}.{f['name']}: unknown enum {arg!r}")
            elif kind == "rows":
                nested = schema_id.get(arg, 0) or _die(f"{name}.{f['name']}: unknown schema {arg!r}")
            fields.append(Field(f["name"], TAGS.index(kind), nested, bool(f.get("optional"))))
        if len(fields) > MAX_FIELDS:
            _die(f"row_schemas.{name}: {len(fields)} fields exceeds the {MAX_FIELDS}-bit presence mask")
        schemas.append(Schema(s["id"], name, s["detail"], tuple(fields)))
    schemas.sort(key=lambda s: s.id)

    verbs: list[Verb] = []
    for name, v in raw_verbs.items():
        if v["params"] not in raw_params:
            _die(f"analytic.verbs.{name}: unknown params family {v['params']!r}")
        if v["schema"] not in schema_id:
            _die(f"analytic.verbs.{name}: unknown schema {v['schema']!r}")
        if v["stream"] not in ("one", "many"):
            _die(f"analytic.verbs.{name}: stream must be one|many, got {v['stream']!r}")
        verbs.append(Verb(v["op"], name, v["params"], schema_id[v["schema"]], v["stream"]))
    verbs.sort(key=lambda v: v.op)

    _contiguous("row_schemas", [s.id for s in schemas])
    _contiguous("analytic.verbs", [v.op for v in verbs])
    _contiguous("row_enums", [e.id for e in enums])
    return Table(enums, tuple(schemas), tuple(verbs), _digest(enums, schemas, verbs))


def _die(msg: str) -> int:
    raise SystemExit(f"build_schema_tables: {msg}")


def _contiguous(label: str, ids: list[int]) -> None:
    if ids != list(range(1, len(ids) + 1)):
        _die(f"{label}: ids must be contiguous from 1 (append-only), got {ids}")


def _digest(enums: tuple[Enum, ...], schemas: tuple[Schema, ...], verbs: tuple[Verb, ...]) -> str:
    """A canonical fingerprint of the WHOLE table.

    Deliberately covers every wire-visible property (ids, order, tags, nesting,
    optionality, op codes) and nothing human (`detail` prose), so re-wording a
    comment does not invalidate every shipped binding while retyping a field
    does.
    """
    lines = [f"enum {e.id} {e.name} {','.join(e.variants)}" for e in enums]
    lines += [
        "schema {} {} {}".format(
            s.id, s.name, "|".join(f"{f.name}:{f.tag}:{f.nested}:{int(f.optional)}" for f in s.fields)
        )
        for s in schemas
    ]
    lines += [f"verb {v.op} {v.name} {v.params} {v.schema} {v.stream}" for v in verbs]
    return sha256("\n".join(lines).encode()).hexdigest()[:32]


# ── emitters ────────────────────────────────────────────────────────────────
# One per consumer. Each emits the SAME table in the target's idiom: the point
# is that a decoder switches on `schema_id` and reads positionally, never that
# it re-declares a struct per verb.


def _zig(t: Table) -> str:
    out = [
        f"//! Generated by tools/{BANNER} from contract/search_api.toml — DO NOT EDIT.",
        "//!",
        "//! The analytic plane's row-schema table (ADR-377). `rows.zig` builds rows",
        "//! against it and `irregex_schema_get` hands it to a host verbatim, so the",
        "//! engine and every binding answer to one declaration.",
        "",
        'const rows = @import("rows.zig");',
        "",
        "/// A sha256 over the canonical table — `irregex_schema_digest`. A binding",
        "/// compares its own generated constant to this at load.",
        f'pub const digest: [*:0]const u8 = "{t.digest}";',
        "",
        "pub const Tag = enum(u32) { " + ", ".join(_zid(tag) for tag in TAGS) + " };",
        "",
    ]
    for e in t.enums:
        variants = ", ".join(_zid(v) for v in e.variants)
        out.append(f"pub const {_pascal(e.name)} = enum(u32) {{ {variants} }};")
    out += ["", "/// Schema ids — the wire discriminant, append-only.", "pub const Id = enum(u32) {"]
    out += [f"    {s.name} = {s.id}," for s in t.schemas]
    out += ["};", "", "/// Verb op codes for `irregex_analytic_run`.", "pub const Op = enum(u32) {"]
    out += [f"    {v.name} = {v.op}," for v in t.verbs]
    out += [
        "};",
        "",
        "/// Which params family a verb's `params` pointer must be.",
        "pub const Params = enum { " + ", ".join(sorted({v.params for v in t.verbs})) + " };",
        "",
        "/// Whether a verb streams rows or answers with exactly one.",
        "pub const Stream = enum { one, many };",
        "",
        "pub const Verb = struct { op: Op, params: Params, schema: Id, stream: Stream };",
        "",
        "/// Indexed by `op - 1`.",
        "pub const verbs = [_]Verb{",
    ]
    out += [
        f"    .{{ .op = .{v.name}, .params = .{v.params}, .schema = .{t.schemas[v.schema - 1].name}, .stream = .{v.stream} }},"
        for v in t.verbs
    ]
    out += [
        "};",
        "",
        "/// Indexed by `id - 1`; the field order IS the row's value order.",
        "pub const schemas = [_]rows.Schema{",
    ]
    for s in t.schemas:
        out.append(f"    .{{ .struct_size = @sizeOf(rows.Schema), .id = {s.id}, .name = \"{s.name}\", .nfields = {len(s.fields)}, .reserved = 0, .fields = &fields_{s.name} }},")
    out += ["};", ""]
    for s in t.schemas:
        out.append(f"const fields_{s.name} = [_]rows.Field{{")
        for f in s.fields:
            out.append(
                f'    .{{ .name = "{f.name}", .tag = @intFromEnum(Tag.{_zid(TAGS[f.tag])}), '
                f".nested = {f.nested}, .optional = {int(f.optional)}, .reserved = 0 }},"
            )
        out += ["};", ""]
    return "\n".join(out)


def _python(t: Table) -> str:
    out = [
        f'"""Generated by tools/{BANNER} from contract/search_api.toml — DO NOT EDIT.',
        "",
        "The analytic plane's row-schema table (ADR-377). `relate/decode.py` walks",
        "it to turn an `irregex_row` into a typed record; nothing here is",
        "hand-written, so a new verb cannot drift from the engine.",
        '"""',
        "",
        "from __future__ import annotations",
        "",
        "from typing import Final",
        "",
        f'DIGEST: Final = "{t.digest}"',
        f"TAGS: Final = {TAGS!r}",
        f"MAX_FIELDS: Final = {MAX_FIELDS}",
        "",
        "# name -> ordinal -> variant. An ordinal past the end is UNKNOWN, never guessed.",
        "ENUMS: Final[dict[str, tuple[str, ...]]] = {",
    ]
    out += [f"    {e.name!r}: {e.variants!r}," for e in t.enums]
    out += [
        "}",
        "",
        "# id -> (name, ((field, tag, nested, optional), ...)). Field order is value order.",
        "SCHEMAS: Final[dict[int, tuple[str, tuple[tuple[str, int, int, bool], ...]]]] = {",
    ]
    for s in t.schemas:
        fields = ", ".join(f"({f.name!r}, {f.tag}, {f.nested}, {f.optional})" for f in s.fields)
        out.append(f"    {s.id}: ({s.name!r}, ({fields},)),")
    out += [
        "}",
        "",
        "ENUM_BY_ID: Final[dict[int, str]] = {" + ", ".join(f"{e.id}: {e.name!r}" for e in t.enums) + "}",
        "",
        "# verb -> (op, params family, schema id, streams many rows)",
        "VERBS: Final[dict[str, tuple[int, str, int, bool]]] = {",
    ]
    out += [
        f"    {v.name!r}: ({v.op}, {v.params!r}, {v.schema}, {v.stream == 'many'})," for v in t.verbs
    ]
    out += ["}", ""]
    return "\n".join(out)


# rustfmt's width heuristics, from the workspace `rustfmt.toml`: `max_width =
# 100` with `use_small_heuristics = "Default"` scales `struct_lit_width` to 18%
# and `fn_call_width` (which also governs tuple and array literals) to 60%.
# Emitting the shape rustfmt would produce keeps this file `cargo fmt
# --check`-clean by construction, so the formatter and the drift gate can't pull
# the generated table in opposite directions. `format_generated_files` would say
# this declaratively, but it is nightly-only and the workspace pins stable —
# this mirrors the netcfg and sandbox-tier Rust emitters.
RUST_STRUCT_LIT_WIDTH = 18
RUST_FN_CALL_WIDTH = 60


def _rust_lit(name: str, fields: tuple[tuple[str, str], ...], indent: str = "    ") -> list[str]:
    """One struct literal, wrapped exactly where rustfmt would wrap it."""
    body = ", ".join(f"{k}: {v}" for k, v in fields)
    if len(body) <= RUST_STRUCT_LIT_WIDTH:
        return [f"{indent}{name} {{ {body} }},"]
    return [
        f"{indent}{name} {{",
        *(f"{indent}    {k}: {v}," for k, v in fields),
        f"{indent}}},",
    ]


def _rust_tuple(*parts: str, indent: str = "    ") -> list[str]:
    """One tuple literal, wrapped exactly where rustfmt would wrap it."""
    flat = "(" + ", ".join(parts) + ")"
    if len(flat) <= RUST_FN_CALL_WIDTH:
        return [f"{indent}{flat},"]
    return [f"{indent}(", *(f"{indent}    {p}," for p in parts), f"{indent}),"]


def _rust(t: Table) -> str:
    out = [
        f"//! Generated by tools/{BANNER} from contract/search_api.toml — DO NOT EDIT.",
        "//!",
        "//! The analytic plane's row-schema table (ADR-377). `relate::decode` walks it",
        "//! to turn an `irregex_row` into a typed record.",
        "",
        "/// Compared to `irregex_schema_digest()` at load — a stale `.so` is a loud",
        "/// failure, not a mis-decoded row.",
        f'pub const DIGEST: &str = "{t.digest}";',
        f"pub const MAX_FIELDS: usize = {MAX_FIELDS};",
        "",
        "#[derive(Debug, Clone, Copy, PartialEq, Eq)]",
        "pub struct FieldDef {",
        "    pub name: &'static str,",
        "    pub tag: u32,",
        "    pub nested: u32,",
        "    pub optional: bool,",
        "}",
        "",
        "#[derive(Debug, Clone, Copy)]",
        "pub struct SchemaDef {",
        "    pub id: u32,",
        "    pub name: &'static str,",
        "    pub fields: &'static [FieldDef],",
        "}",
        "",
        "#[derive(Debug, Clone, Copy)]",
        "pub struct VerbDef {",
        "    pub op: u32,",
        "    pub name: &'static str,",
        "    pub params: &'static str,",
        "    pub schema: u32,",
        "    pub many: bool,",
        "}",
        "",
        "/// Ordinal -> variant, per enum. An ordinal past the end is unknown.",
        "pub const ENUMS: &[(&str, &[&str])] = &[",
    ]
    for e in t.enums:
        variants = "&[" + ", ".join(f'"{v}"' for v in e.variants) + "]"
        out += _rust_tuple(f'"{e.name}"', variants)
    out += ["];", "", "/// Indexed by `id - 1`.", "pub const SCHEMAS: &[SchemaDef] = &["]
    for s in t.schemas:
        out += _rust_lit(
            "SchemaDef",
            (("id", str(s.id)), ("name", f'"{s.name}"'), ("fields", f"FIELDS_{s.name.upper()}")),
        )
    out += ["];", ""]
    for s in t.schemas:
        out.append(f"const FIELDS_{s.name.upper()}: &[FieldDef] = &[")
        for f in s.fields:
            out += _rust_lit(
                "FieldDef",
                (
                    ("name", f'"{f.name}"'),
                    ("tag", str(f.tag)),
                    ("nested", str(f.nested)),
                    ("optional", str(f.optional).lower()),
                ),
            )
        out += ["];", ""]
    out += ["/// Indexed by `op - 1`.", "pub const VERBS: &[VerbDef] = &["]
    for v in t.verbs:
        out += _rust_lit(
            "VerbDef",
            (
                ("op", str(v.op)),
                ("name", f'"{v.name}"'),
                ("params", f'"{v.params}"'),
                ("schema", str(v.schema)),
                ("many", str(v.stream == "many").lower()),
            ),
        )
    out += ["];", ""]
    return "\n".join(out)


def _go(t: Table) -> str:
    out = [
        f"// Code generated by tools/{BANNER} from contract/search_api.toml. DO NOT EDIT.",
        "",
        "package irregex",
        "",
        "// Digest is compared to irregex_schema_digest() at load — a stale library is a",
        "// loud failure, not a mis-decoded row.",
        f'const Digest = "{t.digest}"',
        "",
        f"const maxFields = {MAX_FIELDS}",
        "",
        "// FieldDef is one declared field of one row schema.",
        "type FieldDef struct {",
        "\tName     string",
        "\tTag      uint32",
        "\tNested   uint32",
        "\tOptional bool",
        "}",
        "",
        "// SchemaDef is one declared row schema; Fields order is value order.",
        "type SchemaDef struct {",
        "\tID     uint32",
        "\tName   string",
        "\tFields []FieldDef",
        "}",
        "",
        "// VerbDef binds a verb to its op code, params family, and row schema.",
        "type VerbDef struct {",
        "\tOp     uint32",
        "\tName   string",
        "\tParams string",
        "\tSchema uint32",
        "\tMany   bool",
        "}",
        "",
        "// enums maps an enum name to its variants; an ordinal past the end is unknown.",
        "var enums = map[string][]string{",
    ]
    # gofmt aligns map-literal values on the longest key, and the generator must
    # emit gofmt-clean bytes without shelling gofmt (CI-hermetic, stdlib-only).
    pad = max(len(e.name) for e in t.enums) + 3
    out += [
        "\t" + f'"{e.name}":'.ljust(pad) + " {" + ", ".join(f'"{v}"' for v in e.variants) + "},"
        for e in t.enums
    ]
    out += ["}", "", "// enumByID resolves a field's Nested back to its enum name.", "var enumByID = map[uint32]string{"]
    out += [f'\t{e.id}: "{e.name}",' for e in t.enums]
    out += ["}", "", "// schemas is indexed by ID-1.", "var schemas = []SchemaDef{"]
    for s in t.schemas:
        fields = ", ".join(
            f'{{"{f.name}", {f.tag}, {f.nested}, {str(f.optional).lower()}}}' for f in s.fields
        )
        out.append(f'\t{{{s.id}, "{s.name}", []FieldDef{{{fields}}}}},')
    out += ["}", "", "// verbs is indexed by Op-1.", "var verbs = []VerbDef{"]
    out += [
        f'\t{{{v.op}, "{v.name}", "{v.params}", {v.schema}, {str(v.stream == "many").lower()}}},'
        for v in t.verbs
    ]
    out += ["}", ""]
    return "\n".join(out)


def _pascal(name: str) -> str:
    return "".join(part.capitalize() for part in name.split("_"))


# Contract names are chosen for the contract, not for Zig — `enum` is both a
# perfectly good value tag and a Zig keyword. `@"…"` is the language's own
# escape, so the table keeps the contract's spelling rather than the emitter
# inventing a mangled one that no other binding would share.
ZIG_KEYWORDS = frozenset(
    """addrspace align allowzero and anyframe anytype asm async await break callconv catch
    comptime const continue defer else enum errdefer error export extern fn for if inline
    linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct
    suspend switch test threadlocal try union unreachable usingnamespace var volatile while""".split()
)


def _zid(name: str) -> str:
    return f'@"{name}"' if name in ZIG_KEYWORDS else name


TARGETS: tuple[tuple[str, str], ...] = (
    ("src/surface/ffi/schema.gen.zig", "zig"),
    ("bindings/python/irregex/schema.gen.py", "python"),
    ("bindings/rust/src/schema.gen.rs", "rust"),
    ("bindings/go/schema_gen.go", "go"),
)
EMIT = {"zig": _zig, "python": _python, "rust": _rust, "go": _go}


def main(argv: list[str]) -> int:
    check = "--check" in argv
    table = load()
    drift: list[str] = []
    for rel, lang in TARGETS:
        path, body = KERNEL / rel, EMIT[lang](table)
        current = path.read_text(encoding="utf-8") if path.exists() else None
        if current == body:
            continue
        if check:
            drift.append(rel)
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
        print(f"wrote {rel}")
    if drift:
        print("schema tables are stale — rerun `make gen-gist-schema`:", file=sys.stderr)
        for rel in drift:
            print(f"  • {rel}", file=sys.stderr)
        return 1
    print(
        f"schema table: {len(table.schemas)} schemas · {len(table.verbs)} verbs · "
        f"{len(table.enums)} enums · digest {table.digest}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
