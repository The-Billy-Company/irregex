`gist -l` no longer skips the first 64 KiB of a file whose first 64 KiB holds no
newline, and `--files-without-match` no longer swears such a file has no match
when it does.

One 100 KB line with `fn` near the front, and `rg -l` listed it while gist said
nothing; inverted, gist affirmatively published the file under
`--files-without-match`. The cutover bisected to exactly `BUFCAP - 1` for a
two-byte literal - found at offset 65535, missed at 65534 - which is the tell
that a gate was starting at 65535 rather than 0.

The cause is two questions with one answer between them. Stage 1 runs two scans
over the first `BUFCAP` bytes: a NUL sniff across the whole prefix, and the `-l`
literal proof across only `provableRegion`, the prefix cut at its LAST newline.
That cut is right and stays - a stage-1 proof must not claim to have reached
past the last terminator ripgrep committed. But `covered` recorded the NUL
sniff's extent, and the whole-file literal gate derived its start from
`covered` too. With no newline in the prefix, `provableRegion` returns null, the
literal proof reads zero bytes, and the gate was still told to begin at 65535 -
skipping 64 KiB nobody had looked at. Only `-l` and `--files-without-match` ride
that gate offset, which is why `-c`, `-n`, `-o` and the default mode were fine.

I did not fix this by computing `provableRegion` a second time at the gate. Two
derivations of one fact drifting apart is the bug, and writing a second one down
just arms it again. Stage 1 now reports what it read: `provePrefix` returns a
`Proof` of `{ matched, read }`, and `read` - raw prefix bytes the proof actually
looked at, zero when nothing was provable - is the only thing the gate is
allowed to skip past. `covered` and the new `proven` now sit next to each other
with a comment saying out loud that they answer different questions.

Instrumented, a file whose prefix has terminators still reports
`covered=65536 proven=65520 gate_from=65518`, so the optimization is intact and
this is not a "rescan everything" retreat; the same file with no newline in its
prefix reports `proven=0 gate_from=0`, which is the only sound answer. Every
offset from 65400 to 65700 now agrees with real rg for `-l` and
`--files-without-match`, as do an eight-byte literal across the straddle window,
caseless, pure alternations, `-F`, `-U`, a leading UTF-8 BOM (the offset shifts
by three, and it now shifts correctly), and the no-match control. The stage-1
terminator-bound test this sits beside still passes.
