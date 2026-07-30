`--stats` no longer faults in a whole binary file to re-find a NUL it already
found. Stage 1 reads the first 64 KiB of every file to decide binary-ness, and a
plain run stops there. Under `--stats` the run reads on, because the tally has to
report bytes searched and the emitter has to name the file - but everything either
one needs is bounded by that first NUL. `committedPrefix` returns at the fill that
read it, so both the searched region and `handleBinary`'s emitted region lie inside
the prefix, and `multilineBinary`'s verdict (`nul < min(len, BUFCAP)`) answers the
same for the prefix as for the whole file, so even the `-U` arm is unchanged. The
tail was paying for nothing.

It was paying a lot. `gist -uu --stats` over `.git` cost 2.26 s against 0.02 s for
the same query without the flag - a 100x tax on asking for a byte count - because
every pack file in the repository was read end to end. It is now 0.02 s either
way, and the tally is byte-identical to ripgrep's on the same tree: 1218 files
searched, 2,048,128 bytes searched, matching and non-matching patterns alike.
