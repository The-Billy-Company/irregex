- **A person's home directory is no longer a searchable corpus.** The climb
  that finds a tree's artifact home (`corpus/index/frame/home.zig`) stopped at
  forty levels and nothing else, which is the right rule in a checkout and the
  wrong one everywhere these binaries have since started running - inside a
  product, on a user's machine, pointed at folders nobody ever made a repository
  out of. Two things went wrong there and both were one missing boundary. A
  single stray artifact directory at `$HOME` was then adopted by every climb
  from anywhere beneath it, so every project on the machine silently shared one
  home, one index, and one daemon socket. And with no boundary above, a rootless
  build standing in `$HOME` took the whole tree beneath it as the corpus - mail,
  photo library, every dependency tree ever installed.

  The climb now stops below the dwelling, and a working directory that *is* the
  dwelling (or a filesystem root) reports `home.hosted() == false`: there is no
  project here, so there is nothing to persist an artifact set for. The rule is
  one pure function, `home.confinesOf`, so both edges are pinned by tests rather
  than by a home directory the suite would have to stand in.

  Searching is untouched. It never needed an artifact and the live walk answers
  the same bytes, which is the shape of everything in this family: the
  accelerator declines, the answer does not move.
