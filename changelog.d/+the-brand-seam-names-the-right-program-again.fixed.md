The root declaration the brand seam looks for is `irgx_brand`, not `irregex_brand`.

`relate` and `blast` had already renamed theirs, so `@hasDecl(root, "irregex_brand")` was answering false for both and each binary silently fell back to the default `gist` identity. Running `relate`, a bad knob was reported as `gist: note: ...` - naming a program the user was not running, which is the exact failure the seam was built to end. It compiled clean either way, which is how it survived a rename that touched everything around it.

Only the declaration moved. The type is still `irregex.Brand`, because that is the Zig package name and consumers still write `@import("irregex")`.
