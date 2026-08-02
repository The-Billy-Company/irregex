The test runner is pinned by url and hash instead of assumed to sit beside this
repository.

`.brigade = .{ .path = "../brigade" }` resolves on a machine that happens to have
the sibling checked out, and nowhere else - so a fresh clone, and CI, could not
build this package at all. brigade is a published package now
(github.com/The-Billy-Company/brigade), pinned the way pcre2 and libsais already
were, though not `.lazy` like those two: the vendored engines are never fetched,
and the runner really is.
