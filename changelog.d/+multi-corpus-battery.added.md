Multi-corpus differential battery (`bench/corpora/`): a pinned fetcher installs
five foreign trees (linux v6.10 · cpython v3.13.0 · typescript v5.8.3 ·
OpenSubtitles en+ru 256 MiB prefixes · a deterministic adversarial `torture`
generator) under `.local/gist-corpora/`, and `sweep.py` replays an rg-oracle
slate on each — 472 cases across both engines, all green. The first runs
flushed out and fixed at the root: JSON base64 `bytes` for invalid UTF-8 ·
full `--crlf` terminator parity · rg's implicit-path "No files were searched"
exit-2 heuristic · `-L` dangling-symlink reporting + ancestor-loop detection
with rg's message · Unicode-aware `-w` word boundaries · `-M` terminator-
inclusive width · rg's full binary model (the line-buffer **committed-prefix**
geometry — 3-byte BOM-sniff read, per-fill commit at the last newline, the
NUL-bearing fill discarded — plus the `-U` slice-vs-line routing keyed on
whether the pattern can actually match `\n`, explicit-file convert semantics,
and the byte-count clamps in `--json`/`--stats`) · an uninitialized generation
array in the capture VM that made `-r` nondeterministic under ReleaseFast.
