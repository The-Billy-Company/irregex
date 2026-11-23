# Copyright headers

Run the read-only gate from the repository root with Python 3.11 or newer:

```sh
python3 tools/copyright/check.py
python3 -m unittest discover -s tools/copyright -p 'test_*.py'
```

Add missing notices explicitly:

```sh
python3 tools/copyright/check.py --fix --year 2026
```

The gate checks tracked files and new, nonignored files reported by Git. It
accepts existing Billy Company copyright notices in the initial comment header,
including SPDX notices and earlier years. A string in executable code does not
count. It adds only the copyright notice; existing license and ownership text
stays intact. The updater preserves original bytes, encoding declarations,
newlines, executable permissions, shebangs, Swift tools versions, Go build
constraints, HTML doctypes and CSS charset declarations. It does not follow
source symlinks, and it refuses to overwrite a file changed since inspection.

Supported source extensions live in `STYLES` in `check.py`. Build scripts named
`Makefile`, `GNUmakefile`, `CMakeLists.txt`, `Podfile` and `Gemfile`, plus
extensionless scripts with a supported shebang, are also checked. Unknown
interpreters fail before writes until their comment syntax is explicitly supported.
JSON, license documents,
lockfiles, binaries and other non-source formats receive no injected comments.

## Ownership exclusions

Record third-party source, generated output and byte-sensitive fixtures in
`.copyright.json`. Every exception needs a reason:

```json
{
  "exclude": [
    {
      "path": "vendor/**",
      "reason": "Vendored upstream source retains its original notices."
    }
  ]
}
```

Patterns use Python `fnmatchcase` against the whole repository-relative POSIX
path. They are case sensitive, and `*` matches directory separators, so
`vendor/**` includes all descendants. Unknown fields, duplicate keys, absolute
paths and parent traversal are errors.

An exact-file exception may additionally carry a `sha256` field containing 64
lowercase hexadecimal digits. The gate verifies these bytes even if another
broad pattern also matches the file. A mismatch fails before any writes and
requires an ownership review; the updater never silently exempts or stamps the
changed upstream file. Hash exclusions cannot contain glob metacharacters.

Generated source should receive its notice from its generator when practical.
Use a documented exclusion when regeneration or fixture semantics require the
original bytes. A generated marker in file contents never grants an exemption
by itself.

Exit codes are 0 for success, 1 for missing headers, and 2 for configuration,
Git or I/O errors. `--root PATH` selects another repository; otherwise the root
is inferred from this tool's `tools/copyright` location. `--fix` defaults to
the current year and never rewrites an existing notice's year.
