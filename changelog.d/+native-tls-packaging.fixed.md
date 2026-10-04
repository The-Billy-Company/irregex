We keep native symbols through compilation and remove debug sections after
linking. This avoids a Windows ARM64 thread-local relocation defect in older
linkers, including consumers linking the exported Go and Rust archives. Wheels
still omit debug sections, and Linux libraries keep their build IDs. Every
release platform now checks malformed patterns and recovery in the installed
wheel too.
