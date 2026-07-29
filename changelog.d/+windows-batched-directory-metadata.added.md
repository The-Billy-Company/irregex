Windows now walks with batched directory metadata instead of a stat per file.
`NtQueryDirectoryFile` hands back the name, the attributes, and both change
clocks in one call, so `bulkstat.supported` and `names_supported` are finally
true there — the freshness overlay, the cold descent, the parallel loader, and
the phantom treemap all take the accelerated path they already take on Darwin.

The old portable path was not merely slower, it was asking twice for something
the kernel had already said: `std.Io.Dir.Iterator` requests a metadata-bearing
information class, keeps the name and the kind, and drops the timestamps — and
the freshness walk then re-opened every file to ask for them again. Per file
that is an `NtCreateFile` + `NtQueryInformationFile` + `NtClose`, and on Windows
an open is the expensive operation, because it is the one every filesystem
filter driver (Defender included) sits on.

The syscalls moved out of `bulkstat.zig` into a new `sheaf.zig` beside it, so
the three platform ABIs live together and the policy — which entries a freshness
walk cares about, how a declined batch degrades, how a listing outlives its
buffer — reads as one rule rather than one per platform. Same fail-soft posture
as before on every arm: a refusing batch declines and that subtree falls back to
the proven per-entry stat walk, so uncertain metadata costs speed and never the
conservative live-read decision.

Two latent bugs fell out on the way. `portal.scratchDir` had no callers and had
rotted against Zig 0.16 on *both* arms (`std.posix.getenv`, `std.mem.trimRight`)
— unreferenced, so nothing ever Sema'd it; the bulkstat tests now call it instead
of hardcoding `/tmp`, which is also what lets them run on the native Windows
lane at all. And the Windows drain drops reparse points rather than reporting
them as neither-file-nor-directory, because it serves as the names-only drain
too and the phantom treemap records every row it is handed — returning one there
would have made a Windows snapshot count links a POSIX snapshot of the same tree
does not.
