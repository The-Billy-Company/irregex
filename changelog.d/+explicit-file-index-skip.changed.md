Stop loading the persisted trigram index when every positional root is an
explicit regular file (`gist PAT file.txt`, or several named files). The index
answers exactly one question — _which of the WALKED files can't match, so skip
reading them_ — but a named file is read no matter what the trigrams say, so
loading + decompressing the index and reading the freshness anchor was pure
launch-time tax that only a directory walk ever amortizes. `indexElisionWanted`
now stats each root up front (one syscall apiece, dwarfed by the load it
avoids) and declines the oracle when all roots are regular files; the mixed,
directory, and implicit-CWD-walk cases keep it unchanged. The companion
`file_needle` whole-file presence gate is likewise dropped for a lone explicit
file, where it only re-faulted the body the mode's own scan already reads.

Output-neutral by construction — index elision only ever ELIDES reads that
provably can't match, so reading the named file instead changes cost, never
results (`--files-without-match` still lists a no-match named file either way).
`bench/rgsuite` `run.py` stays 409/409 on both engines.

Measured on a 48 MB single-file corpus (warm page cache, resident daemon off),
gist vs `rg` — the index-load tax was ~1.5 ms of every explicit-file query:

- `-c pgvector` (sparse): rg was 1.29× FASTER → now gist **1.80×** faster.
- `pgvector` matches (sparse): rg was 1.32× faster → now gist **1.77×** faster.
- `-c CREATE` (dense): **2.33×**; plain matches **2.01×**; `-n` **1.88×**.
- `--json` clears the same bar it did on the walk: single-file dense
  **5.26–6.60×**, 48 MB sparse **~1.98×**; repo-wide **3.17–4.22×**.

Startup-bound tiny/sparse single-file queries stay below 2× because there the
whole cost is the OS process spawn both tools pay identically — and gist's cold
start is now already under `rg`'s (`--version` 1.6 ms vs 2.1 ms; tiny-file
search 1.9 ms vs 2.8 ms, **1.49×**).
