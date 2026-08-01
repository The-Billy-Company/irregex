`--files-without-match` now exits 0 over a tree whose only walked file is
binary, which is what ripgrep does. It used to exit 1.

I had this one filed as a ripgrep self-contradiction, and it is not. rg prints
no path for a walked NUL-bearing file - its Summary printer refuses to list a
file whose search it abandoned - and yet exits 0, so the stream says "none" while
the code says "found". Read as "0 iff a path was listed", that is incoherent, and
gist's exit 1 looked like the coherent answer.

But that is not the question rg's exit code answers. `SummarySink::has_match` for
`PathWithoutMatch` is `match_count == 0`: the success condition is "some file's
search found no match". An abandoned binary search found none, so it counts. The
printer's refusal to LIST an unproven file is a separate rule, which is exactly
why the two part company on this one file shape and agree everywhere else. rg is
answering a different question, coherently, and gist was answering the wrong one.

So the verdict now rides back from the per-file decider rather than being read off
the emitted bytes. `render.fileWithoutMatch` returns whether the file's search
found no match - true for the suppressed binary, true for a listed text file,
false only for a file that HAS the pattern - and both engines fold it: the serial
loop ORs it across files (and through the sharded driver, where a shard holding
only binaries emits nothing yet still carries the run), and the parallel engine
banks it in a `Sink.unlisted` counter kept apart from `matched_files`, because
that counter doubles as `--stats`'s `files_with_match` and a suppressed binary
contained no match. `Sink.succeeded()` is the one place the two are read together.

Fixing this also surfaced that `--files-without-match -q --stats` printed nothing
at all: the quiet branch cleared the whole stream, block included, where rg prints
its trailing block under `-q` in every mode. The path list is what `-q` drops.
