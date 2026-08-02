Every job in CI judged the code. Nothing judged the surface a stranger actually
arrives at - the README, the fragments, the manifests, the workflows themselves.
That is a strange gap for a repository whose whole pitch is that it explains
itself, and it had been quietly collecting drift the entire time.

So there is a `discipline` job now, and a matching set of checked-in configs:
markdownlint for layout, typos for spelling, yamllint and taplo for the
configuration that is executable here, editorconfig-checker for the byte shape
underneath both, shellcheck for the bench scripts, ruff for the Python, and
zizmor for the Actions perimeter. golangci-lint went into the `go` job instead,
where the toolchain it needs is already standing up. It is one job because it is
one kind of news, and it is a separate job because none of it needs Zig - a
mistyped heading should cost you seconds, not a matrix build.

It was not clean. Twenty-one code fences carried no language, so nothing was
syntax-highlighting them and nothing had noticed; a comment in `scan/lanes.zig`
had drifted into British spelling; `bar.py` zipped two lists it had just proven
equal-length without saying `strict=True`; and twenty-two Python files had never
been through the formatter that now gates them.

The workflow findings were the ones worth having. Twenty-seven actions were
pinned to a movable tag, ten checkouts left the repository token sitting in
`.git/config` for every later step to read, and the release job - the one job
whose output gets published - was restoring a cache any workflow on any branch
can write to.

One trap deserves writing down, because I walked into it before the gate did.
Pinning an action to a commit is the standard advice, and `git ls-remote --tags
--refs` looks like the way to get one. It is not: `--refs` strips the peeled
`^{}` entries, so for an annotated tag you are handed the *tag object's* hash
rather than the commit it points at. GitHub answers `No commit found for SHA`,
and the workflow fails to resolve before it runs a step. Take the `^{}` line.

`ruff` skips `*.gen.py`. A generated table is its generator's output, and
`tools/build_schema_tables.py` does not emit the shape a formatter wants - left
alone, the two gates would each demand the file the other rejects. The generator
holds a contract, so it wins, and its own `--check` is what guards that file.
