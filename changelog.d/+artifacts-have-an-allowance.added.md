- **The artifact set has a disk allowance, the way a resident session already
  had a memory ration.** Every persisted tier here was individually justified
  and nobody was adding them up. Added up on this repository they came to 635 MB
  against a 300 MB corpus: a 60 MB trigram pair and its 6 MB crest, a 303 MB
  content shard, and - from the kinship package writing into the same home - an
  87 MB codex shelf, a 69 MB atlas, and a 40 MB fragment atlas.

  `corpus/index/frame/allowance.zig` states the ceiling and admits tiers against
  it in priority order. What it rations is deliberately narrow: the tiers whose
  size *is* the corpus rather than a fraction of it - the content shard here,
  the shelf and both atlases next door. Those are the ones that turn a hidden
  directory into a second copy of somebody's files. The trigram pair is never
  declined, because a build that refuses it has not saved anyone disk, it has
  uninstalled the product.

  The default is 512 MiB, chosen as the smallest round number that leaves every
  tier standing on the largest tree we actually index, so the fix costs a
  developer checkout nothing. `GIST_DISK_MB` moves it, in the same units and
  with the same spelling as `GIST_MEMORY_MB`, because it is the same question
  asked of the other resource. Zero is a legitimate answer and means "write no
  corpus-copy artifact on this machine at all".
