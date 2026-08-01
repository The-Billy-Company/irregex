The two-byte block filter can now price its anchor pair against the buffer in
hand instead of a byte-frequency table shipped in the binary. `calibrate.zig`
samples 64 KB in 256-byte stratified windows over up to 16 candidate offsets and
returns the cheapest pair. Against the best pair that exists it lands at 1.04x on
code, 1.03x on prose, and 1.03x on a heterogeneous base64+code+prose buffer,
where the static table reads 1.50x / 2.21x / 1.39x - for 0.19% of a 213 MB scan.

Stratification is the whole design and it is measured, not assumed: on the
heterogeneous buffer a prefix sample lands at 4.30x and *does not improve with
budget* (4.33x at 256 KB, 3.62x at 1 MB) because the bias is systematic, while
stratified sampling lands at 1.04x. On homogeneous prose a prefix is fine
(1.05x), which is exactly why measuring only prose would have shipped the bug.

**The gate it needs is a claim about a document, not about a call.** `len >= 16 * k
* budget` is 3.1 MB at a 3-byte needle, and the obvious call site cannot satisfy
that: `query.zig` calls `simd.contains(line, needle)` once per *line*, so the gate
declines on every real call, while removing the gate would re-pay 3.5-36.8 us per
line. The 1.04x figures above were taken calibrating once over a 213 MB buffer,
which is not a shape production had. So the module lands with the per-scan plan that
gives it one - calibrate once per admitted document, thread the pair through every
line of it, leave `indexOfPos` static so the roofline control cannot drift out of
sync with the kernel - and the wiring, its two recorded surprises, and the
end-to-end numbers are the companion "anchor decision is now a value" entry.
