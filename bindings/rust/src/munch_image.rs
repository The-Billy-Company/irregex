//! Owned Image1 persistence and the one shared outer allocation/work allowance.

use std::fmt;
use std::mem::size_of;
use std::sync::Mutex;

use crate::error::Error;
use crate::munch::{Anchored, Munch, MunchBuilder, Refusal, Why};
use crate::pool::{Handle, Pool};
use crate::sys;

/// Finite ceilings for one Image1 machine. Zero is an actual zero ceiling.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ImageLimits {
    /// Maximum encoded frame bytes, including its seal.
    pub encoded_bytes: u64,
    /// Maximum canonical expanded-data bytes, separate from allocator overhead.
    pub decoded_bytes: u64,
    /// Maximum offered pattern count.
    pub patterns: u64,
    /// Maximum voice count.
    pub voices: u64,
    /// Maximum aggregate DFA states.
    pub states: u64,
    /// Maximum aggregate interior and final transition entries.
    pub transition_entries: u64,
    /// Maximum aggregate canonical auxiliary entries.
    pub auxiliary_entries: u64,
    /// Maximum newly live requested native bytes for one call.
    pub live_owned_bytes: u64,
}

impl Default for ImageLimits {
    fn default() -> Self {
        Self {
            encoded_bytes: 67_108_864,
            decoded_bytes: 134_217_728,
            patterns: 4096,
            voices: 4096,
            states: 1_048_576,
            transition_entries: 16_777_216,
            auxiliary_entries: 4_194_304,
            live_owned_bytes: 268_435_456,
        }
    }
}

impl ImageLimits {
    fn native(&self) -> sys::MunchImageLimits {
        sys::MunchImageLimits {
            struct_size: 80,
            version: 1,
            reserved0: 0,
            reserved1: 0,
            encoded_bytes: self.encoded_bytes,
            decoded_bytes: self.decoded_bytes,
            patterns: self.patterns,
            voices: self.voices,
            states: self.states,
            transition_entries: self.transition_entries,
            auxiliary_entries: self.auxiliary_entries,
            live_owned_bytes: self.live_owned_bytes,
        }
    }
}

/// One cumulative, nonrefundable allowance shared across tiers and members.
///
/// Construct this once at the outer operation. Destruction and failure never
/// refund it; later worker clones are outside a completed image-load allowance.
#[derive(Debug)]
pub struct ImageBudget {
    native: sys::MunchImageBudget,
}

impl ImageBudget {
    /// Start an outer allowance, clamping allocation to the chosen live ceiling
    /// exactly once. Native records themselves accept larger allocation values.
    #[must_use]
    pub fn new(allocation: u64, work: u64, limits: &ImageLimits) -> Self {
        Self {
            native: sys::MunchImageBudget {
                struct_size: 32,
                version: 1,
                reserved0: 0,
                reserved1: 0,
                allocation_left: allocation.min(limits.live_owned_bytes),
                work_left: work,
            },
        }
    }

    /// Remaining cumulative requested-allocation bytes.
    #[must_use]
    pub fn allocation_left(&self) -> u64 {
        self.native.allocation_left
    }

    /// Remaining work units, including Rust metadata and native image work.
    #[must_use]
    pub fn work_left(&self) -> u64 {
        self.native.work_left
    }

    /// Debit caller-owned image metadata before allocating it. No refund occurs
    /// if the allocator subsequently fails or the data is later dropped.
    ///
    /// # Errors
    /// Returns [`ImageError::BudgetExceeded`] without a partial debit.
    pub fn charge_allocation(&mut self, bytes: u64) -> Result<(), ImageError> {
        self.native.allocation_left = self
            .native
            .allocation_left
            .checked_sub(bytes)
            .ok_or(ImageError::BudgetExceeded)?;
        Ok(())
    }

    /// Debit actual metadata/copy/hash work before performing it.
    ///
    /// # Errors
    /// Returns [`ImageError::BudgetExceeded`] without a partial debit.
    pub fn charge_work(&mut self, work: u64) -> Result<(), ImageError> {
        self.native.work_left = self
            .native
            .work_left
            .checked_sub(work)
            .ok_or(ImageError::BudgetExceeded)?;
        Ok(())
    }

    /// Restrict the remaining work to an enclosing Reader's current allowance.
    /// This discards excess allowance; it neither reports that excess as actual
    /// work nor permits replenishment after a child call.
    pub fn clamp_work_left(&mut self, maximum: u64) {
        self.native.work_left = self.native.work_left.min(maximum);
    }

    fn vector<T>(&mut self, count: usize, limits: &ImageLimits) -> Result<Vec<T>, ImageError> {
        let bytes = bytes_for::<T>(count)?;
        if bytes > limits.live_owned_bytes {
            return Err(ImageError::Oversized);
        }
        self.charge_allocation(bytes)?;
        let mut values = Vec::new();
        values
            .try_reserve_exact(count)
            .map_err(|_| ImageError::OutOfMemory)?;
        Ok(values)
    }
}

fn bytes_for<T>(count: usize) -> Result<u64, ImageError> {
    count
        .checked_mul(size_of::<T>())
        .filter(|n| *n <= isize::MAX as usize)
        .and_then(|n| u64::try_from(n).ok())
        .ok_or(ImageError::Oversized)
}

fn visits_and_bytes<T>(count: usize) -> Result<u64, ImageError> {
    bytes_for::<T>(count)?
        .checked_add(u64::try_from(count).map_err(|_| ImageError::Oversized)?)
        .ok_or(ImageError::Oversized)
}

/// A typed image failure. Native persistence/resource faults remain distinct
/// from an empty result and from a successful zero-length match.
#[derive(Clone, Debug, PartialEq, Eq)]
#[non_exhaustive]
pub enum ImageError {
    /// An invalid record/argument was rejected before image processing.
    InvalidArgument,
    /// Unsafe or inconsistent bytes, including a bad unkeyed seal.
    Corrupt,
    /// A frame is shorter than its required declared structure.
    Truncated,
    /// A safe encoding violates Image1's unique representation rules.
    NonCanonical,
    /// Unsupported image, Unicode or behavior epoch.
    VersionMismatch,
    /// Expected source/order/flags differ from this image's identity.
    GenerationMismatch,
    /// A shape, byte ceiling or checked representation bound was exceeded.
    Oversized,
    /// The shared finite allocation/work allowance was exhausted.
    BudgetExceeded,
    /// A real Rust or native allocation failed after its request was debited.
    OutOfMemory,
    /// This host or native machine shape cannot be represented by Image1.
    Unsupported,
    /// Another native or ABI error, retained without inventing an image verdict.
    Native(Error),
}

impl fmt::Display for ImageError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Native(error) => fmt::Display::fmt(error, f),
            other => write!(f, "Munch image {other:?}"),
        }
    }
}
impl std::error::Error for ImageError {}

fn native_error(status: i32) -> ImageError {
    image_error(crate::error::static_fault(status), status)
}

fn image_error(error: Error, status: i32) -> ImageError {
    let detail = match &error {
        Error::NativeStatic { name, .. } => name.map(std::ffi::CStr::to_bytes),
        _ => None,
    };
    match detail {
        Some(b"Corrupt") => ImageError::Corrupt,
        Some(b"Truncated") => ImageError::Truncated,
        Some(b"NonCanonical") => ImageError::NonCanonical,
        Some(b"VersionMismatch") => ImageError::VersionMismatch,
        Some(b"GenerationMismatch") => ImageError::GenerationMismatch,
        Some(b"Oversized") => ImageError::Oversized,
        Some(b"BudgetExceeded") => ImageError::BudgetExceeded,
        Some(b"OutOfMemory") => ImageError::OutOfMemory,
        Some(b"Unsupported") => ImageError::Unsupported,
        None if status == sys::INVALID => ImageError::InvalidArgument,
        None if status == sys::OOM => ImageError::OutOfMemory,
        _ => ImageError::Native(error),
    }
}

/// Immutable owned encoded bytes. Owning them does not independently establish
/// regex equivalence; every load validates the frame against expected source.
#[derive(PartialEq, Eq)]
pub struct MunchImage(Vec<u8>);

impl MunchImage {
    /// The complete Image1 frame, including its unkeyed seal.
    #[must_use]
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }

    /// Transfer the existing allocation without copying it.
    #[must_use]
    pub fn into_bytes(self) -> Vec<u8> {
        self.0
    }
}
impl fmt::Debug for MunchImage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MunchImage")
            .field("bytes", &self.0.len())
            .finish()
    }
}

fn copy_patterns(
    patterns: &[String],
    limits: &ImageLimits,
    budget: &mut ImageBudget,
) -> Result<Vec<String>, ImageError> {
    let mut owned = budget.vector::<String>(patterns.len(), limits)?;
    for pattern in patterns {
        budget.charge_work(visits_and_bytes::<String>(1)?)?;
        let bytes = u64::try_from(pattern.len()).map_err(|_| ImageError::Oversized)?;
        if bytes > limits.live_owned_bytes {
            return Err(ImageError::Oversized);
        }
        budget.charge_allocation(bytes)?;
        let mut copy = String::new();
        copy.try_reserve_exact(pattern.len())
            .map_err(|_| ImageError::OutOfMemory)?;
        budget.charge_work(bytes)?;
        copy.push_str(pattern);
        owned.push(copy);
    }
    Ok(owned)
}

fn survey_loaded(
    prototype: &Handle<Anchored>,
    total: usize,
    limits: &ImageLimits,
    budget: &mut ImageBudget,
) -> Result<(Vec<Refusal>, usize), ImageError> {
    // SAFETY: the just-loaded prototype is owned and never scanned or shared.
    let admitted = unsafe { sys::irgx_munch_len(prototype.raw()) };
    let count = total.checked_sub(admitted).ok_or_else(|| {
        ImageError::Native(Error::NativeInvariant {
            message: "loaded Munch admitted more than its expected source count",
        })
    })?;
    let mut raw = budget.vector::<sys::MunchRefusal>(count, limits)?;
    budget.charge_work(bytes_for::<sys::MunchRefusal>(count)?)?;
    raw.resize(count, sys::MunchRefusal::default());
    // The native query visits and writes exactly the validated refusal count.
    budget.charge_work(visits_and_bytes::<sys::MunchRefusal>(count)?)?;
    let mut written = 0;
    // SAFETY: prototype is exclusive and raw/written are live exact-capacity
    // output buffers; native publication is bounded by raw.len().
    let status = unsafe {
        sys::irgx_munch_declined(
            prototype.raw(),
            raw.as_mut_ptr(),
            raw.len(),
            &raw mut written,
        )
    };
    if status < 0 {
        return Err(native_error(status));
    }
    if written != count {
        return Err(ImageError::Native(Error::NativeInvariant {
            message: "loaded Munch refusal count changed during its immutable survey",
        }));
    }
    let mut refused = budget.vector::<Refusal>(count, limits)?;
    for record in raw {
        budget.charge_work(visits_and_bytes::<Refusal>(1)?)?;
        refused.push(Refusal {
            pattern: record.pattern as usize,
            why: Why::of(record.why),
        });
    }
    Ok((refused, admitted))
}

impl MunchBuilder {
    /// Load one Image1 against this builder's exact ordered source and flags.
    /// The builder and image remain borrowed; the returned Munch owns all data.
    ///
    /// Rust descriptor preparation is paid before the native call, so its
    /// resource failure may precede a native malformed-frame error. This never
    /// compiles or falls back, and construction does not eagerly clone a worker.
    ///
    /// # Errors
    /// Returns typed validation/resource failures; consumed debits remain spent.
    pub fn load_image(
        &self,
        bytes: &[u8],
        limits: &ImageLimits,
        budget: &mut ImageBudget,
    ) -> Result<Munch, ImageError> {
        sys::abi_ok().map_err(ImageError::Native)?;
        if size_of::<usize>() != 8 {
            return Err(ImageError::Unsupported);
        }
        if self.patterns.len() > u32::MAX as usize {
            return Err(ImageError::Oversized);
        }
        let mut descriptors = budget.vector::<sys::MunchPattern>(self.patterns.len(), limits)?;
        for pattern in &self.patterns {
            budget.charge_work(visits_and_bytes::<sys::MunchPattern>(1)?)?;
            descriptors.push(sys::MunchPattern {
                pattern: pattern.as_ptr(),
                len: pattern.len(),
            });
        }
        let native_limits = limits.native();
        let mut out = std::ptr::null_mut();
        // SAFETY: every descriptor borrows a live String; image, limits, budget
        // and publication slot are live for this call. Native code owns copies.
        let status = unsafe {
            sys::irgx_munch_load(
                descriptors.as_ptr(),
                descriptors.len(),
                self.flags,
                bytes.as_ptr(),
                bytes.len(),
                &native_limits,
                &raw mut budget.native,
                &raw mut out,
            )
        };
        if status < 0 {
            return Err(native_error(status));
        }
        let prototype = Handle::owned(std::ptr::NonNull::new(out).ok_or(ImageError::Native(
            Error::NativeInvariant {
                message: "irgx_munch_load reported success without an owned handle",
            },
        ))?);
        if status != 0 {
            return Err(ImageError::Native(Error::NativeInvariant {
                message: "Munch load did not return its handle-publication status",
            }));
        }
        // Every failure below drops the owned native prototype and leaves the
        // shared counters spent. No pool or cache is published before success.
        let patterns = copy_patterns(&self.patterns, limits, budget)?;
        let (declined, admitted) = survey_loaded(&prototype, patterns.len(), limits, budget)?;
        Ok(Munch {
            pool: Pool::empty(Anchored {
                patterns,
                flags: self.flags,
                prototype: Mutex::new(prototype),
            }),
            declined,
            admitted,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Pick;
    use std::mem::{align_of, offset_of};

    const SINGLE: &[u8] = include_bytes!(
        "../../../src/kernel/regex/linear/program/testdata/munch-image1/singleton.bin"
    );
    const FINAL: &[u8] = include_bytes!(
        "../../../src/kernel/regex/linear/program/testdata/munch-image1/final-only-attributed.bin"
    );

    fn expected(count: usize) -> MunchBuilder {
        let mut builder = MunchBuilder::new(vec![".*"; count]);
        builder.unicode(false).dot_matches_new_line(true);
        builder
    }

    fn allowance(limits: &ImageLimits) -> ImageBudget {
        ImageBudget::new(268_435_456, 128_000_000, limits)
    }

    #[test]
    fn image_fault_classification_keeps_static_names_without_owned_error_strings() {
        use crate::Status;
        assert_eq!(
            image_error(
                Error::NativeStatic {
                    status: Status::OUT_OF_MEMORY,
                    name: Some(c"BudgetExceeded")
                },
                sys::OOM
            ),
            ImageError::BudgetExceeded
        );
        assert_eq!(
            image_error(
                Error::NativeStatic {
                    status: Status::OUT_OF_MEMORY,
                    name: Some(c"OutOfMemory")
                },
                sys::OOM
            ),
            ImageError::OutOfMemory
        );
        let unknown = Error::NativeStatic {
            status: Status::INVALID,
            name: Some(c"FutureImageFault"),
        };
        assert_eq!(
            image_error(unknown.clone(), sys::INVALID),
            ImageError::Native(unknown)
        );
        assert_eq!(
            image_error(
                Error::NativeStatic {
                    status: Status::INVALID,
                    name: None
                },
                sys::INVALID
            ),
            ImageError::InvalidArgument
        );
    }

    #[test]
    fn image_records_have_all_eighteen_exact_c_offsets() {
        assert_eq!(
            (
                size_of::<sys::MunchImageLimits>(),
                align_of::<sys::MunchImageLimits>()
            ),
            (80, 8)
        );
        assert_eq!(
            (
                size_of::<sys::MunchImageBudget>(),
                align_of::<sys::MunchImageBudget>()
            ),
            (32, 8)
        );
        assert_eq!(
            [
                offset_of!(sys::MunchImageLimits, struct_size),
                offset_of!(sys::MunchImageLimits, version),
                offset_of!(sys::MunchImageLimits, reserved0),
                offset_of!(sys::MunchImageLimits, reserved1),
                offset_of!(sys::MunchImageLimits, encoded_bytes),
                offset_of!(sys::MunchImageLimits, decoded_bytes),
                offset_of!(sys::MunchImageLimits, patterns),
                offset_of!(sys::MunchImageLimits, voices),
                offset_of!(sys::MunchImageLimits, states),
                offset_of!(sys::MunchImageLimits, transition_entries),
                offset_of!(sys::MunchImageLimits, auxiliary_entries),
                offset_of!(sys::MunchImageLimits, live_owned_bytes),
            ],
            [0, 4, 8, 12, 16, 24, 32, 40, 48, 56, 64, 72]
        );
        assert_eq!(
            [
                offset_of!(sys::MunchImageBudget, struct_size),
                offset_of!(sys::MunchImageBudget, version),
                offset_of!(sys::MunchImageBudget, reserved0),
                offset_of!(sys::MunchImageBudget, reserved1),
                offset_of!(sys::MunchImageBudget, allocation_left),
                offset_of!(sys::MunchImageBudget, work_left),
            ],
            [0, 4, 8, 12, 16, 24]
        );
        let raw = ImageLimits::default().native();
        assert_eq!(
            (raw.struct_size, raw.version, raw.reserved0, raw.reserved1),
            (80, 1, 0, 0)
        );
    }

    #[test]
    fn image_outer_counter_charges_are_nonrefundable_and_restriction_only_decreases() {
        let limits = ImageLimits {
            live_owned_bytes: 7,
            ..ImageLimits::default()
        };
        let mut budget = ImageBudget::new(99, 11, &limits);
        assert_eq!(budget.allocation_left(), 7);
        budget.charge_allocation(4).unwrap();
        assert_eq!(budget.charge_allocation(4), Err(ImageError::BudgetExceeded));
        assert_eq!(budget.allocation_left(), 3);
        budget.charge_work(3).unwrap();
        budget.clamp_work_left(5);
        budget.clamp_work_left(99);
        assert_eq!(budget.work_left(), 5);
        assert_eq!(budget.charge_work(6), Err(ImageError::BudgetExceeded));
        budget.charge_work(5).unwrap();
        assert_eq!(budget.work_left(), 0);
        let mut zero = ImageBudget::new(0, 0, &limits);
        assert!(zero.charge_allocation(0).is_ok() && zero.charge_work(0).is_ok());
        assert_eq!(zero.charge_allocation(1), Err(ImageError::BudgetExceeded));
        let mut big = ImageBudget::new(
            u64::MAX,
            u64::MAX,
            &ImageLimits {
                live_owned_bytes: u64::MAX,
                ..limits
            },
        );
        assert_eq!(
            big.vector::<u64>(usize::MAX, &limits),
            Err(ImageError::Oversized)
        );
        assert_eq!(big.allocation_left(), u64::MAX);
    }

    #[test]
    fn image_descriptor_preparation_errors_precede_native_decode_without_a_refund() {
        let limits = ImageLimits::default();
        let mut budget = ImageBudget::new(1024, 0, &limits);
        assert!(matches!(
            expected(1).load_image(&[], &limits, &mut budget),
            Err(ImageError::BudgetExceeded)
        ));
        assert_eq!(
            budget.allocation_left(),
            1024 - size_of::<sys::MunchPattern>() as u64
        );
        assert_eq!(budget.work_left(), 0);
        let mut full = allowance(&limits);
        assert!(matches!(
            expected(1).load_image(&[], &limits, &mut full),
            Err(ImageError::Truncated)
        ));
    }

    #[test]
    fn image_loaded_metadata_and_native_work_share_exact_and_one_short_counters() {
        let limits = ImageLimits::default();
        let mut measured = allowance(&limits);
        let first = expected(1)
            .load_image(SINGLE, &limits, &mut measured)
            .unwrap();
        assert_eq!(first.pool.idle_count(), 0);
        let allocation = 268_435_456 - measured.allocation_left();
        let work = 128_000_000 - measured.work_left();
        drop(first);
        let mut exact = ImageBudget::new(allocation, work, &limits);
        let second = expected(1).load_image(SINGLE, &limits, &mut exact).unwrap();
        assert_eq!((exact.allocation_left(), exact.work_left()), (0, 0));
        drop(second);
        for (a, w) in [(allocation - 1, work), (allocation, work - 1)] {
            let mut short = ImageBudget::new(a, w, &limits);
            assert!(matches!(
                expected(1).load_image(SINGLE, &limits, &mut short),
                Err(ImageError::BudgetExceeded)
            ));
        }
        let mut shared = ImageBudget::new(allocation * 2 - 1, work * 2, &limits);
        let one = expected(1)
            .load_image(SINGLE, &limits, &mut shared)
            .unwrap();
        drop(one);
        assert!(matches!(
            expected(1).load_image(SINGLE, &limits, &mut shared),
            Err(ImageError::BudgetExceeded)
        ));
        assert!(shared.allocation_left() < allocation);
    }

    #[test]
    fn image_holding_a_loaded_lease_forces_growth_without_recompilation() {
        let limits = ImageLimits::default();
        let mut budget = allowance(&limits);
        let munch = expected(2).load_image(FINAL, &limits, &mut budget).unwrap();
        let first = munch.pool.lease().unwrap();
        let second = munch.pool.lease().unwrap();
        assert_ne!(first.raw(), second.raw());
        for lease in [&first, &second] {
            let mut token = sys::MunchToken::default();
            let mut winners = [99; 2];
            let mut remaining = 4;
            let text = b"\0\xff\na";
            // SAFETY: each lease is exclusive; buffers/records are live and
            // text length, offset and capacities match their actual slices.
            let status = unsafe {
                sys::irgx_munch_scan_metered(
                    lease.raw(),
                    text.as_ptr(),
                    text.len(),
                    0,
                    std::ptr::null(),
                    0,
                    sys::MUNCH_SHORTEST,
                    &raw mut token,
                    winners.as_mut_ptr(),
                    winners.len(),
                    &raw mut remaining,
                )
            };
            assert_eq!(
                (status, token.len, token.count, remaining),
                (sys::MATCH, 4, 2, 0)
            );
            assert_eq!(winners, [0, 1]);
        }
        assert_eq!(munch.pool.idle_count(), 0);
        drop(first);
        drop(second);
        assert_eq!(munch.pool.idle_count(), 2);
    }

    #[test]
    fn image_rust_failures_after_sizing_discard_pending_workers() {
        let limits = ImageLimits::default();
        for allocation_failure in [true, false] {
            let mut load_budget = allowance(&limits);
            let munch = expected(1)
                .load_image(SINGLE, &limits, &mut load_budget)
                .unwrap();
            let lease = munch.pool.lease().unwrap();
            let mut native_budget = allowance(&limits);
            let mut needed = 0;
            // SAFETY: this exclusive lease and live records request only sizing.
            let status = unsafe {
                sys::irgx_munch_save(
                    lease.raw(),
                    &limits.native(),
                    &raw mut native_budget.native,
                    std::ptr::null_mut(),
                    0,
                    &raw mut needed,
                )
            };
            assert_eq!(status, sys::MATCH);
            drop(lease);
            assert_eq!(munch.pool.idle_count(), 1);
            let mut short = ImageBudget::new(
                if allocation_failure {
                    needed as u64 - 1
                } else {
                    needed as u64
                },
                if allocation_failure {
                    128_000_000
                } else {
                    needed as u64 - 1
                },
                &limits,
            );
            assert_eq!(
                munch.save_image(&limits, &mut short),
                Err(ImageError::BudgetExceeded)
            );
            assert_eq!(munch.pool.idle_count(), 0);
            let mut full = allowance(&limits);
            assert_eq!(
                munch.save_image(&limits, &mut full).unwrap().as_bytes(),
                SINGLE
            );
        }
    }

    #[test]
    fn image_source_over64_partial_declines_roundtrip_exact_tokens_and_transition_allowance() {
        let mut patterns = vec!["a+"; 74];
        patterns[70] = "a*";
        patterns[71] = "(";
        patterns[72] = r"\Afoo";
        patterns[73] = r"\bfoo";
        let builder = MunchBuilder::new(patterns);
        let source = builder.build().unwrap();
        assert_eq!(
            source
                .declined()
                .iter()
                .map(|r| r.pattern)
                .collect::<Vec<_>>(),
            [71, 72, 73]
        );
        let limits = ImageLimits::default();
        let mut save_budget = allowance(&limits);
        let image = source.save_image(&limits, &mut save_budget).unwrap();
        let mut load_budget = allowance(&limits);
        let loaded = builder
            .load_image(image.as_bytes(), &limits, &mut load_budget)
            .unwrap();
        assert_eq!(source.declined(), loaded.declined());
        for text in [b"".as_slice(), b"a", b"aaaa", b"\xffa"] {
            for at in [0, text.len()] {
                for allow in [
                    None,
                    Some([].as_slice()),
                    Some([0, 64, 70, 73, 999].as_slice()),
                ] {
                    for pick in [Pick::Longest, Pick::Shortest] {
                        let mut winners = Vec::new();
                        let mut unlimited = usize::MAX;
                        source
                            .scan_bytes_metered_into(
                                text,
                                at,
                                allow,
                                pick,
                                &mut unlimited,
                                &mut winners,
                            )
                            .unwrap();
                        let spent = usize::MAX - unlimited;
                        for initial in [0, 1, spent, spent.saturating_sub(1)] {
                            let (mut a, mut b) = (initial, initial);
                            let (mut x, mut y) = (Vec::new(), Vec::new());
                            assert_eq!(
                                source
                                    .scan_bytes_metered_into(text, at, allow, pick, &mut a, &mut x),
                                loaded
                                    .scan_bytes_metered_into(text, at, allow, pick, &mut b, &mut y)
                            );
                            assert_eq!((a, x), (b, y));
                        }
                    }
                }
            }
        }
    }
}

impl Munch {
    /// Save one canonical Image1 while holding one exclusive native worker.
    /// Existing Program/worker storage and lease growth precede image accounting;
    /// output and native image allocations share this same mutable budget.
    ///
    /// # Errors
    /// Native failures preserve their typed fault. Rust failures after sizing
    /// discard the lease, freeing any retained native pending image.
    pub fn save_image(
        &self,
        limits: &ImageLimits,
        budget: &mut ImageBudget,
    ) -> Result<MunchImage, ImageError> {
        let lease = self.pool.lease().map_err(ImageError::Native)?;
        let native_limits = limits.native();
        let mut needed = 0;
        // SAFETY: lease is exclusive, records/needed are live, and null/zero
        // output requests the native bounded pending-image sizing operation.
        let status = unsafe {
            sys::irgx_munch_save(
                lease.raw(),
                &native_limits,
                &raw mut budget.native,
                std::ptr::null_mut(),
                0,
                &raw mut needed,
            )
        };
        if status < 0 {
            return Err(native_error(status));
        }
        let mut finish = || -> Result<MunchImage, ImageError> {
            if status != sys::MATCH || needed < 208 || needed as u64 > limits.encoded_bytes {
                return Err(ImageError::Native(Error::NativeInvariant {
                    message: "Munch save returned an invalid sizing result",
                }));
            }
            let mut output = budget.vector::<u8>(needed, limits)?;
            budget.charge_work(needed as u64)?;
            output.resize(needed, 0);
            let mut written = 0;
            // SAFETY: the same exclusive lease still owns its pending image;
            // output is initialized live storage of the exact reported size.
            let status = unsafe {
                sys::irgx_munch_save(
                    lease.raw(),
                    &native_limits,
                    &raw mut budget.native,
                    output.as_mut_ptr(),
                    output.len(),
                    &raw mut written,
                )
            };
            if status < 0 {
                return Err(native_error(status));
            }
            if status != sys::MATCH || written != needed {
                return Err(ImageError::Native(Error::NativeInvariant {
                    message: "Munch save changed its pending output size",
                }));
            }
            Ok(MunchImage(output))
        };
        match finish() {
            Ok(image) => Ok(image),
            Err(error) => {
                lease.discard();
                Err(error)
            },
        }
    }
}
