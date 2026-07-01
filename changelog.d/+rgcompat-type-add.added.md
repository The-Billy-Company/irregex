**`rg --type-add` defines and composes custom file types** (`bench/rgargs.zig`).
The type surface already resolved built-in names (`-t go`); ripgrep also lets a
caller *mint* a type on the command line, and its tests exercise both forms — so
the parser now accepts them instead of erroring on an unknown type.

- **`--type-add 'name:glob'`** registers a user type from one or more globs
  (`--type-add web:*.html --type-add web:*.css`, accumulated in order), usable
  immediately via `-t name`/`-T name`. Bare extensions are lifted to `*.ext`.
- **`--type-add 'name:include:t1,t2'`** composes an existing set of types into a
  new alias, resolving each member (custom-first, then the built-in table)
  recursively.
- **Resolution order fixed**: `-t <name>` checks `--type-add` definitions before
  the built-in `pathfilter` table, so a redefinition wins. (Along the way this
  fixed a Zig control-flow bug where an `else die` bound to a `for`'s `else`
  clause mis-reported valid built-in types like `py` as "unrecognized".)

Proven against real ripgrep as the oracle: the `--type-add` single-glob and
`:include:` composition cases (`file_type_add`, `file_type_add_compose`) diff to
**0 bytes** vs `rg`. `--type-list` itself stays a documented NA (gist's type table
is a distinct catalogue, not rg's exact list).
