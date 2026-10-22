Rust's source-engine build uses one Zig build job, matching the native archive
producers and bounding compiler concurrency on Windows ARM64. Windows binding
checks show verbose Cargo build output so a stalled source build can be diagnosed.
