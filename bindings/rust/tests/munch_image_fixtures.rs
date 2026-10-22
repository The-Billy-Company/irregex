//! Accepted authored Image1 bytes and expected scans; no expected value comes from the loader.
//! The two structural-only graphs deliberately need not match compiled .* source.
#![cfg(feature = "munch-image")]

use irgx::{Error, ImageBudget, ImageError, ImageLimits, Munch, MunchBuilder, Pick};
use std::sync::{Arc, Barrier};

const TEXT: &[u8] = &[0, 0xff, 10, 97];

struct Fixture {
    name: &'static str,
    bytes: &'static [u8],
    patterns: usize,
    flags: u32,
    structural_only: bool,
}
const FIXTURES: &[Fixture] = &[
    // SHA256 b4f7c72b84b8cd06fa6c6fe34fe950eb481c386b91a572208938aad3b4e23af0
    Fixture {
        name: "empty-default",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/empty-default.bin"
        ),
        patterns: 0,
        flags: 0,
        structural_only: false,
    },
    // SHA256 ed921600243a3ce60c558f2a3246b338ad38148d9434b7959cdd552b4e33716e
    Fixture {
        name: "empty-byte-dotall",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/empty-byte-dotall.bin"
        ),
        patterns: 0,
        flags: 1088,
        structural_only: false,
    },
    // SHA256 f31eb95b1f8c5f1a626ca89c763b1777c2579b3d9c7fffc3e592462928c1173a
    Fixture {
        name: "singleton",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/singleton.bin"
        ),
        patterns: 1,
        flags: 1088,
        structural_only: false,
    },
    // SHA256 1a7a2fdf26e1dd7313adad943df9a6cdcc8eaed99569e25a3719ecdecc618b49
    Fixture {
        name: "attributed-two",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/attributed-two.bin"
        ),
        patterns: 2,
        flags: 1088,
        structural_only: false,
    },
    // SHA256 8adae289a0cc208d9725bb9556bab48dfb3822d763a97b5e46e5b1de762ed7b4
    Fixture {
        name: "attributed-all64",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/attributed-all64.bin"
        ),
        patterns: 64,
        flags: 1088,
        structural_only: false,
    },
    // SHA256 cc05a1385e92bbab94c056534a3e4757a8283f2b891c797042a58244573446bc
    Fixture {
        name: "final-only-singleton",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/final-only-singleton.bin"
        ),
        patterns: 1,
        flags: 1088,
        structural_only: true,
    },
    // SHA256 3d8dfc26f19fb37a845399f1baf811d2398f26f45b7a38a9a42581609995b1c1
    Fixture {
        name: "final-only-attributed",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/final-only-attributed.bin"
        ),
        patterns: 2,
        flags: 1088,
        structural_only: true,
    },
];

#[derive(Clone, Copy)]
struct BudgetCase {
    initial: usize,
    remaining: usize,
    exhausted: bool,
}
const BUDGETS: &[[BudgetCase; 4]] = &[
    [
        BudgetCase {
            initial: 0,
            remaining: 0,
            exhausted: false,
        },
        BudgetCase {
            initial: 1,
            remaining: 1,
            exhausted: false,
        },
        BudgetCase {
            initial: 0,
            remaining: 0,
            exhausted: false,
        },
        BudgetCase {
            initial: 0,
            remaining: 0,
            exhausted: false,
        },
    ],
    [
        BudgetCase {
            initial: 0,
            remaining: 0,
            exhausted: true,
        },
        BudgetCase {
            initial: 1,
            remaining: 0,
            exhausted: true,
        },
        BudgetCase {
            initial: 4,
            remaining: 0,
            exhausted: false,
        },
        BudgetCase {
            initial: 3,
            remaining: 0,
            exhausted: true,
        },
    ],
    [
        BudgetCase {
            initial: 0,
            remaining: 0,
            exhausted: true,
        },
        BudgetCase {
            initial: 1,
            remaining: 0,
            exhausted: false,
        },
        BudgetCase {
            initial: 1,
            remaining: 0,
            exhausted: false,
        },
        BudgetCase {
            initial: 0,
            remaining: 0,
            exhausted: true,
        },
    ],
];

struct Question {
    fixture: usize,
    at: usize,
    pick: Pick,
    allow: Option<&'static [u32]>,
    answer: Option<usize>,
    winners: &'static [u32],
    budgets: usize,
}
const QUESTIONS: &[Question] = &[
    Question {
        fixture: 0,
        at: 0,
        pick: Pick::Longest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 0,
        at: 0,
        pick: Pick::Longest,
        allow: None,
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 0,
        at: 0,
        pick: Pick::Longest,
        allow: Some(&[0, 0, 999, 0]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 0,
        at: 4,
        pick: Pick::Longest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 0,
        at: 4,
        pick: Pick::Longest,
        allow: None,
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 0,
        at: 4,
        pick: Pick::Longest,
        allow: Some(&[0, 0, 999, 0]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 0,
        at: 0,
        pick: Pick::Shortest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 0,
        at: 0,
        pick: Pick::Shortest,
        allow: None,
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 0,
        at: 0,
        pick: Pick::Shortest,
        allow: Some(&[0, 0, 999, 0]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 0,
        at: 4,
        pick: Pick::Shortest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 0,
        at: 4,
        pick: Pick::Shortest,
        allow: None,
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 0,
        at: 4,
        pick: Pick::Shortest,
        allow: Some(&[0, 0, 999, 0]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 1,
        at: 0,
        pick: Pick::Longest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 1,
        at: 0,
        pick: Pick::Longest,
        allow: None,
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 1,
        at: 0,
        pick: Pick::Longest,
        allow: Some(&[0, 0, 999, 0]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 1,
        at: 4,
        pick: Pick::Longest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 1,
        at: 4,
        pick: Pick::Longest,
        allow: None,
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 1,
        at: 4,
        pick: Pick::Longest,
        allow: Some(&[0, 0, 999, 0]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 1,
        at: 0,
        pick: Pick::Shortest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 1,
        at: 0,
        pick: Pick::Shortest,
        allow: None,
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 1,
        at: 0,
        pick: Pick::Shortest,
        allow: Some(&[0, 0, 999, 0]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 1,
        at: 4,
        pick: Pick::Shortest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 1,
        at: 4,
        pick: Pick::Shortest,
        allow: None,
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 1,
        at: 4,
        pick: Pick::Shortest,
        allow: Some(&[0, 0, 999, 0]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 2,
        at: 0,
        pick: Pick::Longest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 2,
        at: 0,
        pick: Pick::Longest,
        allow: None,
        answer: Some(4),
        winners: &[0],
        budgets: 1,
    },
    Question {
        fixture: 2,
        at: 0,
        pick: Pick::Longest,
        allow: Some(&[0, 0, 999, 0]),
        answer: Some(4),
        winners: &[0],
        budgets: 1,
    },
    Question {
        fixture: 2,
        at: 4,
        pick: Pick::Longest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 2,
        at: 4,
        pick: Pick::Longest,
        allow: None,
        answer: Some(0),
        winners: &[0],
        budgets: 0,
    },
    Question {
        fixture: 2,
        at: 4,
        pick: Pick::Longest,
        allow: Some(&[0, 0, 999, 0]),
        answer: Some(0),
        winners: &[0],
        budgets: 0,
    },
    Question {
        fixture: 2,
        at: 0,
        pick: Pick::Shortest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 2,
        at: 0,
        pick: Pick::Shortest,
        allow: None,
        answer: Some(1),
        winners: &[0],
        budgets: 2,
    },
    Question {
        fixture: 2,
        at: 0,
        pick: Pick::Shortest,
        allow: Some(&[0, 0, 999, 0]),
        answer: Some(1),
        winners: &[0],
        budgets: 2,
    },
    Question {
        fixture: 2,
        at: 4,
        pick: Pick::Shortest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 2,
        at: 4,
        pick: Pick::Shortest,
        allow: None,
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 2,
        at: 4,
        pick: Pick::Shortest,
        allow: Some(&[0, 0, 999, 0]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 3,
        at: 0,
        pick: Pick::Longest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 3,
        at: 0,
        pick: Pick::Longest,
        allow: None,
        answer: Some(4),
        winners: &[0, 1],
        budgets: 1,
    },
    Question {
        fixture: 3,
        at: 0,
        pick: Pick::Longest,
        allow: Some(&[0, 1, 999, 0]),
        answer: Some(4),
        winners: &[0, 1],
        budgets: 1,
    },
    Question {
        fixture: 3,
        at: 4,
        pick: Pick::Longest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 3,
        at: 4,
        pick: Pick::Longest,
        allow: None,
        answer: Some(0),
        winners: &[0, 1],
        budgets: 0,
    },
    Question {
        fixture: 3,
        at: 4,
        pick: Pick::Longest,
        allow: Some(&[0, 1, 999, 0]),
        answer: Some(0),
        winners: &[0, 1],
        budgets: 0,
    },
    Question {
        fixture: 3,
        at: 0,
        pick: Pick::Shortest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 3,
        at: 0,
        pick: Pick::Shortest,
        allow: None,
        answer: Some(1),
        winners: &[0, 1],
        budgets: 2,
    },
    Question {
        fixture: 3,
        at: 0,
        pick: Pick::Shortest,
        allow: Some(&[0, 1, 999, 0]),
        answer: Some(1),
        winners: &[0, 1],
        budgets: 2,
    },
    Question {
        fixture: 3,
        at: 4,
        pick: Pick::Shortest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 3,
        at: 4,
        pick: Pick::Shortest,
        allow: None,
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 3,
        at: 4,
        pick: Pick::Shortest,
        allow: Some(&[0, 1, 999, 0]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 4,
        at: 0,
        pick: Pick::Longest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 4,
        at: 0,
        pick: Pick::Longest,
        allow: None,
        answer: Some(4),
        winners: &[
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
            24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45,
            46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
        ],
        budgets: 1,
    },
    Question {
        fixture: 4,
        at: 0,
        pick: Pick::Longest,
        allow: Some(&[0, 63, 999, 0]),
        answer: Some(4),
        winners: &[0, 63],
        budgets: 1,
    },
    Question {
        fixture: 4,
        at: 4,
        pick: Pick::Longest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 4,
        at: 4,
        pick: Pick::Longest,
        allow: None,
        answer: Some(0),
        winners: &[
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
            24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45,
            46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
        ],
        budgets: 0,
    },
    Question {
        fixture: 4,
        at: 4,
        pick: Pick::Longest,
        allow: Some(&[0, 63, 999, 0]),
        answer: Some(0),
        winners: &[0, 63],
        budgets: 0,
    },
    Question {
        fixture: 4,
        at: 0,
        pick: Pick::Shortest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 4,
        at: 0,
        pick: Pick::Shortest,
        allow: None,
        answer: Some(1),
        winners: &[
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
            24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45,
            46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
        ],
        budgets: 2,
    },
    Question {
        fixture: 4,
        at: 0,
        pick: Pick::Shortest,
        allow: Some(&[0, 63, 999, 0]),
        answer: Some(1),
        winners: &[0, 63],
        budgets: 2,
    },
    Question {
        fixture: 4,
        at: 4,
        pick: Pick::Shortest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 4,
        at: 4,
        pick: Pick::Shortest,
        allow: None,
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 4,
        at: 4,
        pick: Pick::Shortest,
        allow: Some(&[0, 63, 999, 0]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 5,
        at: 0,
        pick: Pick::Longest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 5,
        at: 0,
        pick: Pick::Longest,
        allow: None,
        answer: Some(4),
        winners: &[0],
        budgets: 1,
    },
    Question {
        fixture: 5,
        at: 0,
        pick: Pick::Longest,
        allow: Some(&[0, 0, 999, 0]),
        answer: Some(4),
        winners: &[0],
        budgets: 1,
    },
    Question {
        fixture: 5,
        at: 4,
        pick: Pick::Longest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 5,
        at: 4,
        pick: Pick::Longest,
        allow: None,
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 5,
        at: 4,
        pick: Pick::Longest,
        allow: Some(&[0, 0, 999, 0]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 5,
        at: 0,
        pick: Pick::Shortest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 5,
        at: 0,
        pick: Pick::Shortest,
        allow: None,
        answer: Some(4),
        winners: &[0],
        budgets: 1,
    },
    Question {
        fixture: 5,
        at: 0,
        pick: Pick::Shortest,
        allow: Some(&[0, 0, 999, 0]),
        answer: Some(4),
        winners: &[0],
        budgets: 1,
    },
    Question {
        fixture: 5,
        at: 4,
        pick: Pick::Shortest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 5,
        at: 4,
        pick: Pick::Shortest,
        allow: None,
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 5,
        at: 4,
        pick: Pick::Shortest,
        allow: Some(&[0, 0, 999, 0]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 6,
        at: 0,
        pick: Pick::Longest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 6,
        at: 0,
        pick: Pick::Longest,
        allow: None,
        answer: Some(4),
        winners: &[0, 1],
        budgets: 1,
    },
    Question {
        fixture: 6,
        at: 0,
        pick: Pick::Longest,
        allow: Some(&[0, 1, 999, 0]),
        answer: Some(4),
        winners: &[0, 1],
        budgets: 1,
    },
    Question {
        fixture: 6,
        at: 4,
        pick: Pick::Longest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 6,
        at: 4,
        pick: Pick::Longest,
        allow: None,
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 6,
        at: 4,
        pick: Pick::Longest,
        allow: Some(&[0, 1, 999, 0]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 6,
        at: 0,
        pick: Pick::Shortest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 6,
        at: 0,
        pick: Pick::Shortest,
        allow: None,
        answer: Some(4),
        winners: &[0, 1],
        budgets: 1,
    },
    Question {
        fixture: 6,
        at: 0,
        pick: Pick::Shortest,
        allow: Some(&[0, 1, 999, 0]),
        answer: Some(4),
        winners: &[0, 1],
        budgets: 1,
    },
    Question {
        fixture: 6,
        at: 4,
        pick: Pick::Shortest,
        allow: Some(&[]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 6,
        at: 4,
        pick: Pick::Shortest,
        allow: None,
        answer: None,
        winners: &[],
        budgets: 0,
    },
    Question {
        fixture: 6,
        at: 4,
        pick: Pick::Shortest,
        allow: Some(&[0, 1, 999, 0]),
        answer: None,
        winners: &[],
        budgets: 0,
    },
];

fn builder(f: &Fixture) -> MunchBuilder {
    let mut builder = MunchBuilder::new(std::iter::repeat(".*").take(f.patterns));
    builder.unicode(f.flags & 0x40 == 0);
    builder.dot_matches_new_line(f.flags & 0x400 != 0);
    builder
}

fn load(f: &Fixture) -> Munch {
    let limits = ImageLimits::default();
    let mut budget = ImageBudget::new(268_435_456, 128_000_000, &limits);
    builder(f)
        .load_image(f.bytes, &limits, &mut budget)
        .expect(f.name)
}

/// Caller image, source strings and builder disappear before first lease.
fn load_from_poisoned_inputs(f: &Fixture) -> Munch {
    let limits = ImageLimits::default();
    let mut budget = ImageBudget::new(268_435_456, 128_000_000, &limits);
    let mut image = f.bytes.to_vec();
    let mut patterns = vec![String::from(".*"); f.patterns];
    let mut builder = MunchBuilder::new(&patterns);
    builder.unicode(f.flags & 0x40 == 0);
    builder.dot_matches_new_line(f.flags & 0x400 != 0);
    let loaded = builder
        .load_image(&image, &limits, &mut budget)
        .expect(f.name);
    image.fill(0xa5);
    drop(image);
    patterns
        .iter_mut()
        .for_each(|p| p.replace_range(.., "poison"));
    drop(patterns);
    drop(builder);
    loaded
}

fn assert_budget_exhausted(error: Error) {
    match error {
        Error::OutOfMemory { detail } => assert_eq!(detail.as_deref(), Some("BudgetExceeded")),
        other => panic!("scan exhaustion lost its native fault: {other:?}"),
    }
}

fn final_only(machine: &Munch, patterns: usize) {
    for pick in [Pick::Longest, Pick::Shortest] {
        let mut winners = vec![999];
        let mut remaining = 4;
        assert_eq!(
            machine
                .scan_bytes_metered_into(TEXT, 0, None, pick, &mut remaining, &mut winners)
                .unwrap(),
            Some(4)
        );
        assert_eq!(remaining, 0);
        assert_eq!(winners, if patterns == 1 { vec![0] } else { vec![0, 1] });
        assert_eq!(
            machine
                .scan_bytes_into(TEXT, TEXT.len(), None, pick, &mut winners)
                .unwrap(),
            None
        );
        assert!(winners.is_empty());
    }
}

#[test]
fn authored_goldens_own_inputs_and_roundtrip_all_seven_canonical_frames() {
    assert_eq!(FIXTURES.len(), 7);
    for f in FIXTURES {
        let machine = load_from_poisoned_inputs(f);
        assert_eq!(machine.len(), f.patterns, "{}", f.name);
        assert_eq!(machine.admitted(), f.patterns, "{}", f.name);
        assert!(machine.declined().is_empty(), "{}", f.name);
        assert!(machine.patterns().iter().all(|p| p == ".*"));
        let limits = ImageLimits::default();
        let mut budget = ImageBudget::new(268_435_456, 128_000_000, &limits);
        let image = machine.save_image(&limits, &mut budget).expect(f.name);
        assert_eq!(image.as_bytes(), f.bytes, "{}", f.name);
    }
}

#[test]
fn authored_questions_preserve_all_84_answers_and_336_remaining_budgets() {
    let machines: Vec<_> = FIXTURES.iter().map(load).collect();
    let mut questions = 0;
    let mut cases = 0;
    for q in QUESTIONS {
        let machine = &machines[q.fixture];
        let mut winners = vec![0xdecafbad];
        let answer = machine
            .scan_bytes_into(TEXT, q.at, q.allow, q.pick, &mut winners)
            .unwrap();
        assert_eq!(answer, q.answer, "{}", FIXTURES[q.fixture].name);
        assert_eq!(winners, q.winners);
        questions += 1;
        for case in BUDGETS[q.budgets] {
            winners.clear();
            winners.push(0xdecafbad);
            let mut remaining = case.initial;
            let result = machine.scan_bytes_metered_into(
                TEXT,
                q.at,
                q.allow,
                q.pick,
                &mut remaining,
                &mut winners,
            );
            assert_eq!(remaining, case.remaining, "{}", FIXTURES[q.fixture].name);
            if case.exhausted {
                assert_budget_exhausted(result.expect_err("one-short scan must refuse"));
                assert!(winners.is_empty(), "refusal published partial winners");
            } else {
                assert_eq!(result.unwrap(), q.answer);
                assert_eq!(winners, q.winners);
            }
            cases += 1;
        }
    }
    assert_eq!(questions, 84);
    assert_eq!(cases, 336);
}

#[test]
fn structural_only_images_preserve_first_lease_clone_chain_and_source_first_drop() {
    let mut controls = 0;
    for f in FIXTURES.iter().filter(|f| f.structural_only) {
        let original = load_from_poisoned_inputs(f);
        // Recompiling the declared .* would accept EOF and shortest length1.
        // Cold first lease must preserve the authored final-only behavior.
        final_only(&original, f.patterns);
        let first = original.try_clone().unwrap();
        let second = first.try_clone().unwrap();
        drop(original);
        drop(first);
        let third = second.clone();
        drop(second);
        final_only(&third, f.patterns);
        controls += 1;
    }
    assert_eq!(controls, 2);
}

#[test]
fn structural_only_workers_keep_concurrent_permissions_independent() {
    let f = FIXTURES
        .iter()
        .find(|f| f.name == "final-only-attributed")
        .unwrap();
    let machine = Arc::new(load_from_poisoned_inputs(f));
    let body = Arc::new(vec![0xff; 8192]);
    let barrier = Arc::new(Barrier::new(8));
    std::thread::scope(|scope| {
        for id in 0..8 {
            let machine = Arc::clone(&machine);
            let body = Arc::clone(&body);
            let barrier = Arc::clone(&barrier);
            scope.spawn(move || {
                let allowed = [id % 2];
                let mut winners = Vec::new();
                barrier.wait();
                for round in 0..16 {
                    let pick = if round % 2 == 0 {
                        Pick::Longest
                    } else {
                        Pick::Shortest
                    };
                    let mut remaining = body.len();
                    assert_eq!(
                        machine
                            .scan_bytes_metered_into(
                                &body,
                                0,
                                Some(&allowed),
                                pick,
                                &mut remaining,
                                &mut winners
                            )
                            .unwrap(),
                        Some(body.len())
                    );
                    assert_eq!(winners, allowed);
                    assert_eq!(remaining, 0);
                    assert_eq!(
                        machine
                            .scan_bytes_into(&body, body.len(), None, pick, &mut winners)
                            .unwrap(),
                        None
                    );
                    assert!(winners.is_empty());
                }
            });
        }
    });
    // The private held-lease test covers deterministic pool growth. This public
    // control asserts concurrency outcomes without claiming observed pool size.
}

struct NegativeFixture {
    name: &'static str,
    bytes: &'static [u8],
    patterns: &'static [&'static str],
    flags: u32,
    expected: ImageError,
}
const NEGATIVE_FIXTURES: &[NegativeFixture] = &[
    // SHA256 8662233bb445438651bf8a982c962e293d3754afe50bed52560bdd1496f5c0d9
    NegativeFixture {
        name: "image-version",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/image-version.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::VersionMismatch,
    },
    // SHA256 2cf3d20552106e315e09065064ca221d8775a129dd3220cce7a199edca73a08c
    NegativeFixture {
        name: "scan-epoch",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/scan-epoch.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::VersionMismatch,
    },
    // SHA256 c584995114291c6d231214f1067b72b7a0a32da239757ce70276f7ce655f043d
    NegativeFixture {
        name: "header-reserved",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/header-reserved.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 9a888c2021164d40cd297e0a7aadeae416a50476953a3a772f7b5e424b9012da
    NegativeFixture {
        name: "unknown-image-flags",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/unknown-image-flags.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 7a3089101389769132dfbbad21041cd0942a7e38c298e47e0e6ef677754f7a6e
    NegativeFixture {
        name: "bad-magic",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/bad-magic.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::Corrupt,
    },
    // SHA256 c7e82087be05d4c7961202e6893d7668bf100af921c5cd2405887604ac2cee6d
    NegativeFixture {
        name: "declared-long",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/declared-long.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::Truncated,
    },
    // SHA256 6202922007bb1e1e3672e8b8da6bd04a8e86e2cde82e25059f057c1da1b66544
    NegativeFixture {
        name: "declared-short",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/declared-short.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 0c44bb2dfbff798053ca6df55badf0bd9d44e0a75c4294c1c5a7d907ff3cdbe1
    NegativeFixture {
        name: "trailing-byte",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/trailing-byte.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 a82b1770b92ee9199a3c3a6acfe1a2d52d3e6cfe9ef489a43020ab220c348b2f
    NegativeFixture {
        name: "truncated-trailer",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/truncated-trailer.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::Truncated,
    },
    // SHA256 370165de3c32226f9611c93e749f07865bc9a4d8b25df643101b9fcf00a1fc5f
    NegativeFixture {
        name: "bad-seal",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/bad-seal.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::Corrupt,
    },
    // SHA256 19001dbdbc626e730e4e72a4874851c07ae2f1e72833bb65086d84126e599927
    NegativeFixture {
        name: "roster-digest",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/roster-digest.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::Corrupt,
    },
    // SHA256 72322d0ad7934e69146b00cc40afaf0acd7c3404158cfacf6f9707b0cdd7c488
    NegativeFixture {
        name: "source-digest",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/source-digest.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::GenerationMismatch,
    },
    // SHA256 5c3d8a4d44624871a55e110c569730b13e0cf13b1d9110b63c5e9d2acce960bf
    NegativeFixture {
        name: "supported-flags-differ",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/supported-flags-differ.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::GenerationMismatch,
    },
    // SHA256 f31eb95b1f8c5f1a626ca89c763b1777c2579b3d9c7fffc3e592462928c1173a
    NegativeFixture {
        name: "expected-text-differs",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/expected-text-differs.bin"
        ),
        patterns: &[".+"],
        flags: 1088,
        expected: ImageError::GenerationMismatch,
    },
    // SHA256 b292446896cdb6c3464591452734c78c77d76bd37a7f2775db107fb68efc3609
    NegativeFixture {
        name: "voice-reserved",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/voice-reserved.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 48638bcc4708caa6f9eee109c451c53b329900a11ff56bc12298da1ef63920de
    NegativeFixture {
        name: "class-count-zero",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/class-count-zero.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 f109d496a254119f2d372ff0a237f2e786b6cefab01393935331112981f46937
    NegativeFixture {
        name: "class-byte-outside",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/class-byte-outside.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::Corrupt,
    },
    // SHA256 042ab4cb83a296524355035c905dd9f682e99b720c3f48a5ef3681a8ee65da9a
    NegativeFixture {
        name: "interior-target-outside",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/interior-target-outside.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::Corrupt,
    },
    // SHA256 095b314242d5c9cff899b23ff868acbc800e60db59a3d04a64e2014d62c55758
    NegativeFixture {
        name: "partial-sentinel-row",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/partial-sentinel-row.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::Corrupt,
    },
    // SHA256 9419e51f5bd31e6909dce1cc7b62a6aaef72f6690c670fa8b20bce18fe5c3d86
    NegativeFixture {
        name: "unfilled-interior-start",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/unfilled-interior-start.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::Corrupt,
    },
    // SHA256 afed8749a7bc53dc22c4b7ae0a7b07eca0ce0f606d12788d66dfbb160899c32e
    NegativeFixture {
        name: "match-prefix-outside",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/match-prefix-outside.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 17cf997229f4ec345f48b5f61f5666d147d0b543e3357f73ceaafc5520692945
    NegativeFixture {
        name: "attribution-mode-wrong",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/attribution-mode-wrong.bin"
        ),
        patterns: &[".*", ".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 7efe0e0bd61578cc789b9371858df6df941dea13d7faa1fcd964f6891b67812b
    NegativeFixture {
        name: "empty-mask-outside",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/empty-mask-outside.bin"
        ),
        patterns: &[".*", ".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 5b78a0b30a1adbb6e062dae32b98e1a62eb4241646a49fe48ad3e05254ea3487
    NegativeFixture {
        name: "run-high-zero",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/run-high-zero.bin"
        ),
        patterns: &[".*", ".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 9be9c2876aeb9548a8e95b5047f1e0e9d7151dc4912ca54ee4b0f4872fa1ecea
    NegativeFixture {
        name: "run-mask-zero",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/run-mask-zero.bin"
        ),
        patterns: &[".*", ".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 f874858eb6e6c49f151088ed0de880b1f62753d31eb503b66d8a8510add58e68
    NegativeFixture {
        name: "run-mask-outside",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/run-mask-outside.bin"
        ),
        patterns: &[".*", ".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 d09974e0ce73f5292e09c5c2eb0b45d0c201255b850fab1f07a6c4939f7d2343
    NegativeFixture {
        name: "reach-not-fixpoint",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/reach-not-fixpoint.bin"
        ),
        patterns: &[".*", ".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 dec774be495f112f4828664861bc1539b35442ef22a432e13ab28e71a16c414c
    NegativeFixture {
        name: "missing-reach",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/missing-reach.bin"
        ),
        patterns: &[".*", ".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 36c32214f735140d2e840495a915d0c63d5178d063ae8f0bceba8c6fae7ee5d1
    NegativeFixture {
        name: "ordinal-outside",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/ordinal-outside.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 cc3a5623c780206edbe264f858653968286a54f291da3e3c73b13635ebae27f6
    NegativeFixture {
        name: "ordinal-duplicate",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/ordinal-duplicate.bin"
        ),
        patterns: &[".*", ".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 19c5eebc5d97f1de3d8dc3651bd5bde60fa3a7f249e6a1d6274b544b318841d9
    NegativeFixture {
        name: "unknown-refusal-reason",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/unknown-refusal-reason.bin"
        ),
        patterns: &[".*", ".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 10805c4fae67b6240d2a817063bef4950001953761d459263236e6c77a420e2e
    NegativeFixture {
        name: "nonempty-all-declined",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/nonempty-all-declined.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 c4da33dbf9ff389a31371b7de954ddea024e4c76eb032e951b790874395b0bab
    NegativeFixture {
        name: "adjacent-equal-runs",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/adjacent-equal-runs.bin"
        ),
        patterns: &[".*", ".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
    // SHA256 cf60c7d92eb478714998b8c73be72ee82863cb1ee545c0a57c1b2d0d4822ac5b
    NegativeFixture {
        name: "final-only-now-interior-reachable",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/final-only-now-interior-reachable.bin"
        ),
        patterns: &[".*"],
        flags: 1088,
        expected: ImageError::Corrupt,
    },
    // SHA256 57acf80fcecb211b1b1aaa91682606ce1796b71db2caeeec6f726ee7a7fe1c74
    NegativeFixture {
        name: "final-edge-reach-not-propagated",
        bytes: include_bytes!(
            "../../../src/kernel/regex/linear/program/testdata/munch-image1/final-edge-reach-not-propagated.bin"
        ),
        patterns: &[".*", ".*"],
        flags: 1088,
        expected: ImageError::NonCanonical,
    },
];

#[test]
fn authored_negative_frames_keep_all_35_typed_safe_api_failures() {
    assert_eq!(NEGATIVE_FIXTURES.len(), 35);
    for f in NEGATIVE_FIXTURES {
        let mut builder = MunchBuilder::new(f.patterns.iter().copied());
        builder.unicode(f.flags & 0x40 == 0);
        builder.dot_matches_new_line(f.flags & 0x400 != 0);
        let limits = ImageLimits::default();
        let mut budget = ImageBudget::new(268_435_456, 128_000_000, &limits);
        match builder.load_image(f.bytes, &limits, &mut budget) {
            Err(error) => assert_eq!(error, f.expected, "{}", f.name),
            Ok(_) => panic!("{} unexpectedly published a safe Munch", f.name),
        }
    }
}
