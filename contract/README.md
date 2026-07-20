---
doc_radar:
  sentinels:
    - description: "unified search contract keeps request options + transports + relate verbs"
      file: pkg/kernels/irregex/contract/search_api.toml
      contains: ["[request_options]", "[transports]", "[irregex.verbs]", "abi_version"]
---

# `contract/` — unified search-API contract

[`search_api.toml`](search_api.toml) is the single source of truth for irregex's
**unified search contract**
([ADR-352](../../../../docs/architecture/3-decisions/352-gist-unified-search-api.md)):

- `SearchRequest` options every face accepts
- `Match` kinds it returns
- Process exit codes
- C ABI version
- Transports (subprocess authoritative; UDS / FFI accelerators)
- Relate verbs + lifecycle
- Session eligibility rules
- Tool-boundary mapping notes

## Why it exists

The `gist` CLI, `billy-irregex` Python package, Rust `gist` crate, and Billy's
agent code-search tool all speak **one** request shape over **one** engine.
This file freezes the enumerations they share so a package constant and the
binary's version can never silently diverge. Widening `[request_options]` is
an interface change — review it like an ABI bump, not a casual edit.

## Who reads it

| Consumer | How |
| -------- | --- |
| Python [`../bindings/python/irregex`](../bindings/python) | `irregex.contract` + parity tests |
| Rust [`../bindings/rust`](../bindings/rust) | `gist::contract` + `tests/contract.rs` |
| CLI `--schema` | Flag rows name the rg-parity flags in `runtime/cold/argv` `flag_catalog` |
| Reviewers | Decide deep contract vs CLI-only presentation flag |

## When to edit

- New matcher controls that every face must honor → add here first.
- Transport status / session eligibility / relate verb changes.
- Then update bindings + Zig `flag_catalog` / relate dispatch in the same PR.

Flag *parsing* still lives in
[`../src/runtime/cold/argv/args.zig`](../src/runtime/cold/argv/args.zig);
each `flag = …` here names the rg-parity flag a request option lowers into.
