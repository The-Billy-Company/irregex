On Windows the serial engine silently ignored your `.gitignore`, and miscounted
`--max-depth`.

`std.Io.Dir.Walker` joins with the platform's separator, so on Windows it hands
back `sub\a.txt`. gist's serial walk passed that straight through to three
consumers that all speak `/`: the gitignore protocol (a rule is *written* with
`/`, so `sub/ignored.txt` matched nothing), `pathDepth` (which counts `/`, so
every entry read as depth 1 and `--max-depth` stopped bounding anything), and the
rendered output. The parallel swarm joins with `/` itself and was always correct,
which is exactly why this survived: the two engines disagreed, and the engine the
portability slate exercises was the right one.

So the same query answered differently depending on which engine ran it — and the
flags that route to serial are ordinary ones: `--files`, `-L`, `-q`, `-r`,
`--max-filesize`, `--include-zero`, `--one-file-system`, a time-keyed `--sort`.
Reproduced under Wine on a three-file tree: default engine returned `sub/kept.txt`
alone, `GIST_NO_PARALLEL=1` returned `sub\ignored.txt` and `sub\kept.txt`.

Normalized at the two seams a walker path can enter - gist's serial walk and the
corpus `Haystack` - by one `paths.slashed`, beside the `stripDot`/`rootDepth`
helpers whose module header already promised that per-file copies of this
vocabulary are a parity bug by construction.

The seam sits on the walk's hot path, so it is free where nothing needs doing: on
a platform already spelling `/` it is comptime the identity and hands the input
straight back, and where it must rewrite it does so in place. The walk gets its
own buffer there (the walker lends bytes it then overwrites), and the `Haystack`
gets none at all - it joins root and entry first, then fixes up the join's own
buffer, which is why `joinRoot` now returns the `[]u8` it always allocated
instead of narrowing it to const on the way out.

That `/` render is a deliberate divergence from ripgrep, which renders the native
separator while normalizing internally for matching. Same matching, different
render: one spelling on every platform is what lets a captured expectation, a
script, and an agent read identically everywhere — and it is already a *gated*
claim, because `bench/conformance/targets` hashes Windows stdout and diffs it
against the native oracle. Verified byte-identical against that oracle across all
eight engine × flag combinations above, four of which the slate never reached.

Nobody loses the native spelling by it: `--path-separator '\'` renders
`.\sub\a.txt`, and that flag is rg's own. It also only started working on Windows
with this change - replacing `/` in a path that already held `\` did half a job.
So the platform default is the invariant one and the platform spelling is one flag
away, where rg fixes the render per platform and offers the same flag to leave it.

Wine proved the fix; it can't prove the platform. So each of these behaviors is now
asserted on a real kernel too, in the native Windows lane
(`.github/workflows/gist-windows.yml`) on both x64 and arm64: the `/` render, an
ignore rule spelled through a separator, `--max-depth`'s component count,
`--one-file-system` over a single volume, `--color=always` without a `TERM`, and
`%LOCALAPPDATA%\gist\preferences` being found but staying out of force in a pipe.
Contract facts over a purpose-built tree, so a concurrently edited checkout can't
make them flaky.
