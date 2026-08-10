`deadBranches` - the note on a SUCCESSFUL run whose alternation was partly dead.

`A|B|C` where `B` matches nothing exits 0, prints rows, and looks like a complete
answer. It is the failure mode of asking three questions at once: the run reports
matches, so nothing prompts you to notice that a third of what you asked was
never found, and the usual next step is to trust a set you have not got. Every
line on this channel had until now been reserved for empty runs, which is exactly
why the case was invisible.

A branch whose bytes appear nowhere in the printed results now earns one note. The
check reads `out` rather than the corpus, so it costs one pass over bytes already
in hand and cannot claim anything the caller did not just see.

It is gated on `results_faithful`, which is the soundness condition rather than a
preference: `-l` prints paths, `-c` prints counts, `--json` reshapes the text, `-r`
rewrites it, and `-m` truncates it. In each of those a branch can match without
leaving its bytes in the output, so absence proves nothing and the note is
withheld instead of guessed. Tested on both sides of that line - a partly dead
alternation in a faithful mode must speak, the same alternation under `-l` / `-c`
/ `-r` must stay silent, and an alternation whose every branch landed must stay
silent in every mode.
