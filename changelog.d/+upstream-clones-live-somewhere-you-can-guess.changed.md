The third-party checkouts the differential tests and research dossiers read
from moved out of a hidden dotfile bucket into `upstream/`. Those are clones of
BurntSushi/ripgrep and rust-lang/regex - the oracle the conformance suite
mines its cases from, and the semantics the regex engine is judged against -
and they are gitignored, so nothing fetches them for you. That was another
convention carried out of the monorepo, and it is a bad one to inherit: it
looks like a dotfile bucket, it sorts out of sight, and nobody guesses that a
clone of somebody else's repository is what belongs there. `upstream/` says
what it holds. If you already have the clones, move the directory; if you do
not, the differential rungs skip themselves the same way they always did.
