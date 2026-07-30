`--one-file-system` does something on Windows now.

The Windows stat leg reports every field `RawStat` projects except a volume id, so
it reported a constant `0` and the flag compared `0 == 0` forever: never pruning,
on any tree. Documented as a deliberate under-filter, which is the right failure
direction and still leaves the flag inert on a platform where ripgrep's walker
honors it — `walkdir` compares the volume serial there.

Volume identity is now its own entry point, `inode.devicePath`, rather than a
`RawStat` field. That is what keeps it free: Windows answers it from a *different*
query than the rest of the projection, so folding it in would have taxed every stat
in the walk — and the freshness overlay's — to serve a flag that is off by default
and, when on, is consulted once per directory. POSIX keeps paying nothing, since
`st_dev` already rode along.

It reads `FILE_ID_INFORMATION`, not `FileFsVolumeInformation`. The latter is the
obvious choice and is the one Wine answers `STATUS_NOT_IMPLEMENTED` — which the
first cut shipped, and which a unit test running under the Wine lane caught as a
null id, i.e. as the same silently-inert flag in a new disguise. It is also the
better id on its merits: 64 bits where the volume-information struct carries 32,
and one fixed-size query where that struct trails a variable-length label. A
volume that declines to answer still yields null, so the failure mode stays "stops
pruning" rather than "prunes wrongly".

Both halves are asserted, because a platform query that quietly stops answering
breaks this flag invisibly: an id must exist, and it must be the *same* id for two
paths on one volume. Cross-volume discrimination stays a real-Windows claim — Wine
reports serial 0 for every drive in the container, so the lane can prove the call
answers and cannot prove it discriminates.
