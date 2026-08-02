The Windows static archive builds, so `libirgx.a` ships on all five targets.

`libirgx.a` is meant to link standing alone - carrying PCRE2 and libsais rather than naming them and leaving a cgo or `build.rs` consumer to hunt down two more archives this package does not install. Everywhere with a partial link that is bought by packing a partially-linked object, which pulls the C floor in. COFF has no partial link: handed the two floor archives, `zig build-obj` refuses with "coff does not support linking multiple objects into one", and the Windows wheel never built.

But an archive is a bag of members, and the property wanted is about what is in the bag. So Windows splices instead of merging: `zig ar qcsL` adds an input archive's contents rather than the archive itself, and the abi's own objects plus both floors land in one `libirgx.a` with the same closure the merged object gives elsewhere. Thirty-three members, and the symbol index carries `pcre2_compile_8` and `libsais_main_ctx` beside `irgx_engine_open`. Only the assembly differs; what a consumer links does not.

Nothing had caught this because the release workflow had never run - it publishes on a tag, and there has not been one. A manual dry run is what surfaced it.
