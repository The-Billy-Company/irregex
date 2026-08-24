- A search now tells you when its index stopped being an accelerator.

  An index is a bet that most files can be proven out without reading them. When
  the build anchor falls far enough behind the tree, that bet quietly inverts:
  the files it used to spare come back as changed-since-anchor, get re-read
  anyway, and the run is doing bookkeeping for something that is no longer
  buying it anything. Nothing about that is visible. Elision is byte-invisible by
  construction, so the results are identical either way, the exit code is 0, and
  the only way to learn the anchor is days old is to run `gist status` - which
  nobody runs *before* a search, because there is no symptom prompting them to.
  It is the same failure shape the no-match hints exist for: a success with no
  symptom.

  So the walk now counts what the elision oracle actually decided, per cause.
  That distinction is the whole change. `skip` answered as a bool, which is
  everything the walk needs to act on and not enough for the run to say anything
  true about itself afterwards, because it collapsed three very different
  negatives: a file the trigrams admit as a possible match (the index working),
  a file the index never covered (nothing to spare), and an indexed file whose
  clocks reach the anchor (a read the index bought back - the only one that is a
  loss). Separating them means a finished run can report the elision rate it
  actually achieved instead of the one its file count implies.

  One line on stderr, and only when the run can prove it earned it - the counts
  have to show it re-read more than it spared. A healthy index says nothing
  however old its anchor is, because age is not the complaint; being outvoted by
  your own stale set is. The claim is arithmetic on what this run did, not a
  guess about whether the age mattered:

  ```text
  gist: note: the index spared 210 of 2000 reads and bought back 1400 that
        changed since its anchor (set 3.6 days ago) - it is re-reading more
        than it elides
  gist: try: gist index - re-anchoring lets those 1400 files be proven out again
  ```

  Counting is a non-atomic increment on a line each worker already owns, folded
  once at the join, and it rides the lookup an unchanged file always paid. The
  parallel engine only, which is the default path; the serial one partitions its
  candidate set upstream and has no equivalent seam. `GIST_HINTS=0` mutes it with
  the rest of the channel.
