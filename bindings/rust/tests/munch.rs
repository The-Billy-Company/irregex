//! `Munch`, asked of a second engine and of its own contract.
//!
//! This is the one type in the crate with no `regex`-crate counterpart to be a
//! drop-in for, which removes the usual witness and does not remove the need for
//! one. So the maximal-munch rule is checked against an **oracle assembled out
//! of the `regex` crate**: anchor each pattern with `^(?:…)`, run it at the
//! caller's offset, and take the longest end anybody reached. That is a second
//! implementation of the rule, in another engine, from the patterns rather than
//! from this crate's answer — which is the whole point, because an oracle built
//! by calling `Munch` twice would agree with itself no matter what it did.
//!
//! The oracle has one honest limit, and the corpus is chosen around it rather
//! than the limit being papered over. `regex` is leftmost-**first**: `a|ab` at
//! offset 0 is `a` there, where a DFA's leftmost-longest reading is `ab`. Those
//! are both correct and they are different conventions, so a pattern whose own
//! alternation is length-ambiguous cannot be arbitrated by this oracle at all.
//! Every pattern below is therefore unambiguous in its own length — literals and
//! greedy quantifiers, the shapes a real lexer's terminals actually have — and
//! the convention difference gets its own explicit test instead of hiding inside
//! a differential that would fail for the wrong reason.
//!
//! Everything else here is contract: that anchoring is real, that a tie is
//! reported rather than arbitrated, that restricting the walk is not filtering
//! the answer, that a partial refusal keeps the rest of the slate lexing, and
//! that the pool underneath survives threads.

use std::collections::BTreeSet;

use irgx::{Error, Munch, MunchBuilder, Pick, Refusal, Why};

// ── the oracle ──────────────────────────────────────────────────────────────

/// The longest anchored match at `at`, and every pattern that reached it, as
/// computed by the `regex` crate one pattern at a time.
///
/// `None` when nothing starts there. The anchoring is `^(?:…)` over the *tail*
/// of the text rather than `find_at`, because `regex`'s `^` means the start of
/// the haystack and `find_at` does not move it — searching `&text[at..]` is what
/// puts the anchor where the caller's offset is.
fn oracle(patterns: &[&str], text: &str, at: usize) -> Option<(usize, Vec<u32>)> {
    let tail = &text[at..];
    let mut best: Option<usize> = None;
    let mut winners = Vec::new();
    for (index, pattern) in patterns.iter().enumerate() {
        let anchored = regex::Regex::new(&format!("^(?:{pattern})")).unwrap();
        let Some(found) = anchored.find(tail) else {
            continue;
        };
        let reach = found.end();
        match best {
            Some(far) if reach < far => continue,
            Some(far) if reach == far => winners.push(index as u32),
            _ => {
                best = Some(reach);
                winners.clear();
                winners.push(index as u32);
            },
        }
    }
    best.map(|len| (len, winners))
}

/// The same answer from this crate, in the oracle's shape.
fn ours(munch: &Munch, text: &str, at: usize) -> Option<(usize, Vec<u32>)> {
    munch
        .token(text, at)
        .map(|token| (token.len(), token.patterns().to_vec()))
}

/// A lexer's terminals: literals, greedy classes, a string with an escape-free
/// body, a comment that runs to end of line. Each unambiguous in its own length,
/// and between them every interesting interaction — a keyword inside an
/// identifier, three operators sharing a prefix, two patterns that can tie.
///
/// `\s+` is here deliberately rather than the `[ \t]+` an earlier draft used. A
/// whitespace class that can cross a line break is what a per-line compilation
/// model silently breaks, and a corpus without one lets that bug through — which
/// is exactly what happened.
const TERMINALS: &[&str] = &[
    "if",
    "in",
    "[a-z_]+",
    "[0-9]+",
    r"\s+",
    ">",
    ">>",
    ">>=",
    "\"[^\"]*\"",
    "//[^\n]*",
    "\n",
];

/// Texts that land on every one of those, and on the seams between them.
const TEXTS: &[&str] = &[
    "if x >>= 12",
    "iffy in\tinner",
    "a >> b > c >>= d",
    "\"quoted\" // trailing\nnext",
    "12345abc",
    "",
    "\n\n",
    ">>>>",
    "in",
    "\"unterminated",
];

#[test]
fn the_longest_reading_agrees_with_the_regex_crate_at_every_offset() {
    let munch = Munch::new(TERMINALS).unwrap();
    assert!(munch.declined().is_empty(), "{:?}", munch.declined());
    for text in TEXTS {
        // `..=len` deliberately: the end of the input is an offset a lexer
        // reaches and asks about, and it is where a nullable pattern is the only
        // possible answer.
        for at in 0..=text.len() {
            assert_eq!(
                ours(&munch, text, at),
                oracle(TERMINALS, text, at),
                "at byte {at} of {text:?}"
            );
        }
    }
}

#[test]
fn a_whole_text_tokenizes_the_same_way_both_engines_read_it() {
    // The differential above is per offset, which cannot catch a token whose
    // length is right and whose *successor* is wrong. Driving the loop is what
    // does: a lexer advances by the length it was told, so one wrong length
    // desynchronizes every token after it.
    let munch = Munch::new(TERMINALS).unwrap();
    let text = "if x >>= 12 // done\n\"str\" inner";

    let mut mine = Vec::new();
    let mut at = 0;
    while at < text.len() {
        let token = munch
            .token(text, at)
            .expect("every byte here starts a token");
        assert!(!token.is_empty(), "a zero-length token would not advance");
        mine.push((at..at + token.len(), token.patterns()[0]));
        at += token.len();
    }

    let mut theirs = Vec::new();
    let mut at = 0;
    while at < text.len() {
        let (len, winners) = oracle(TERMINALS, text, at).expect("as above");
        theirs.push((at..at + len, winners[0]));
        at += len;
    }

    assert_eq!(mine, theirs);
    // And the tokenization actually covers the text, rather than both engines
    // agreeing on a truncated read.
    assert_eq!(mine.last().unwrap().0.end, text.len());
}

#[test]
fn leftmost_longest_is_this_engine_and_leftmost_first_is_the_regex_crate() {
    // The oracle's limit, stated as a fact instead of avoided silently. A DFA
    // reads `a|ab` as the longer branch; `regex` commits to the first that
    // matches. Both are correct, and a lexer author needs to know which they got.
    let munch = Munch::new(["a|ab"]).unwrap();
    assert_eq!(munch.token("ab", 0).unwrap().len(), 2);
    assert_eq!(
        regex::Regex::new("^(?:a|ab)")
            .unwrap()
            .find("ab")
            .unwrap()
            .end(),
        1
    );
}

// ── anchoring ───────────────────────────────────────────────────────────────

#[test]
fn a_scan_never_finds_a_token_that_starts_later() {
    // The property that separates this from every search verb in the crate, and
    // the reason the type exists: `Regex::find` would happily report the `ab` at
    // offset 2.
    let munch = Munch::new(["ab"]).unwrap();
    assert!(munch.token("xxab", 0).is_none());
    assert!(munch.token("xxab", 1).is_none());
    assert_eq!(munch.token("xxab", 2).unwrap().len(), 2);
    assert_eq!(
        irgx::Regex::new("ab")
            .unwrap()
            .find("xxab")
            .unwrap()
            .start(),
        2
    );
}

#[test]
fn the_end_of_the_input_is_a_legal_offset() {
    let munch = Munch::new(["a+", "b*"]).unwrap();
    let token = munch.token("aa", 2).expect("`b*` accepts the empty string");
    assert!(token.is_empty());
    assert_eq!(token.patterns(), &[1]);
}

#[test]
fn an_offset_past_the_end_is_an_error_rather_than_a_panic_or_an_answer() {
    let munch = Munch::new(["a"]).unwrap();
    assert!(matches!(
        munch.try_token("ab", 3),
        Err(Error::Inconsistent { .. })
    ));
}

#[test]
fn a_zero_length_token_is_a_result_and_not_an_absence() {
    // A lexer advancing on one would not terminate, so the two have to be
    // distinguishable from the outside.
    let munch = Munch::new(["a*"]).unwrap();
    let token = munch
        .token("bbb", 0)
        .expect("`a*` accepts the empty string");
    assert!(token.is_empty());
    assert_eq!(token.range(0), 0..0);

    let nothing = Munch::new(["a+"]).unwrap();
    assert!(nothing.token("bbb", 0).is_none());
}

// ── ties ────────────────────────────────────────────────────────────────────

#[test]
fn a_tie_is_reported_rather_than_arbitrated() {
    // Longest is only half a lexer's rule; the tie-break belongs to the grammar.
    // So all three of these have to come back, ascending, and none of them may
    // be silently preferred.
    let munch = Munch::new(["[a-z]+", "abc", "a.c"]).unwrap();
    let token = munch.token("abc", 0).unwrap();
    assert_eq!(token.len(), 3);
    assert_eq!(token.patterns(), &[0, 1, 2]);
    // Which is exactly the width the type promised a buffer would need.
    assert_eq!(munch.admitted(), 3);
}

#[test]
fn a_repeated_pattern_is_two_terminals_and_ties_with_itself() {
    // A real grammar does this: two named terminals with the same body and
    // different meanings. Neither may be deduplicated away.
    let munch = Munch::new(["let", "let"]).unwrap();
    assert_eq!(munch.token("let", 0).unwrap().patterns(), &[0, 1]);
}

// ── the permitted set ───────────────────────────────────────────────────────

#[test]
fn restricting_the_walk_is_not_filtering_the_answer() {
    // The single most important property of `token_among`, and the one a
    // convenience wrapper over the unrestricted answer would get wrong: `[a-z]+`
    // reaches further than `if` here, so filtering afterwards yields nothing
    // where the correct answer is the two-byte keyword.
    let munch = Munch::new(["if", "[a-z]+"]).unwrap();

    let free = munch.token("iffy", 0).unwrap();
    assert_eq!((free.len(), free.patterns()), (4, &[1][..]));

    let keyword_only = munch.token_among("iffy", 0, &[0]).unwrap();
    assert_eq!((keyword_only.len(), keyword_only.patterns()), (2, &[0][..]));

    // Stated as the adverse case too, so the test fails if someone reimplements
    // `token_among` as a filter: that implementation returns `None` here.
    assert!(
        free.patterns().iter().all(|p| *p != 0),
        "the unrestricted answer contains nothing to filter down to pattern 0, \
         which is why the restriction has to ride the walk"
    );
}

#[test]
fn permitting_nothing_answers_instead_of_erroring() {
    // A lexer state can legitimately reach a point where no terminal is legal.
    // Hearing "nothing starts here" is what lets it report the error against the
    // bytes rather than against its own tables.
    let munch = Munch::new(["a", "b"]).unwrap();
    assert!(munch.token_among("aaa", 0, &[]).is_none());
}

#[test]
fn permitting_an_unknown_or_declined_ordinal_is_a_no_op() {
    // So a caller with a fallback engine for its blind terminals does not also
    // have to remember which ordinals those were, and so an out-of-range ordinal
    // cannot become an out-of-bounds anything.
    let munch = Munch::new(["[a-z]+", r"(a)\1"]).unwrap();
    assert_eq!(munch.declined().len(), 1, "{:?}", munch.declined());

    assert_eq!(
        munch.token_among("abc", 0, &[0, 1]).unwrap().patterns(),
        &[0]
    );
    assert!(munch.token_among("abc", 0, &[1]).is_none());
    assert!(munch.token_among("abc", 0, &[9_999]).is_none());
}

#[test]
fn a_state_directed_lexer_reads_what_a_free_one_cannot() {
    // The whole reason the permitted set is per call: the same bytes tokenize
    // differently depending on what the parser will accept next. `in` is a
    // keyword after a value and an identifier after `let`.
    let munch = Munch::new(["in", "[a-z]+"]).unwrap();
    const KEYWORD: &[u32] = &[0];
    const IDENTIFIER: &[u32] = &[1];

    let as_keyword = munch.token_among("inx", 0, KEYWORD).unwrap();
    assert_eq!((as_keyword.len(), as_keyword.patterns()), (2, &[0][..]));

    let as_name = munch.token_among("inx", 0, IDENTIFIER).unwrap();
    assert_eq!((as_name.len(), as_name.patterns()), (3, &[1][..]));
}

// ── shortest ────────────────────────────────────────────────────────────────

#[test]
fn shortest_is_the_other_reading_of_the_same_offset() {
    let munch = Munch::new(["[a-z]", "[a-z]+"]).unwrap();
    // Longest: only `[a-z]+` can reach three bytes.
    let greedy = munch.token("abc", 0).unwrap();
    assert_eq!((greedy.len(), greedy.patterns()), (3, &[1][..]));
    // Shortest: one byte — and BOTH patterns reach it, because `[a-z]+` accepts
    // a single letter too. A tie at the winning length is still a tie.
    let brief = munch.shortest_among("abc", 0, &[0, 1]).unwrap();
    assert_eq!((brief.len(), brief.patterns()), (1, &[0, 1][..]));
}

// ── partial refusal ─────────────────────────────────────────────────────────

#[test]
fn one_undeterminizable_terminal_does_not_cost_the_others() {
    // The property the engine's bisection exists for, asserted from the outside.
    // A backreference is not a regular language, so no DFA can hold it — and a
    // lexer with a hundred and fifty terminals must not lose all of them to one.
    let munch = Munch::new(["[a-z]+", r"(a)\1", "[0-9]+", r"(?<=x)y"]).unwrap();

    let declined: BTreeSet<usize> = munch.declined().iter().map(|r| r.pattern).collect();
    assert_eq!(declined, BTreeSet::from([1, 3]));
    assert!(
        munch.declined().iter().all(|r| r.why == Why::Syntax),
        "{:?}",
        munch.declined()
    );

    // The survivors answer in the CALLER's ordinals, not in whatever seats the
    // bisection gave them.
    assert_eq!(munch.token("123", 0).unwrap().patterns(), &[2]);
    assert_eq!(munch.token("abc", 0).unwrap().patterns(), &[0]);

    // And the counts describe the same compile from both ends.
    assert_eq!(munch.len(), 4);
    assert_eq!(munch.admitted(), 2);
    assert_eq!(munch.patterns().len(), 4);
    assert_eq!(munch.patterns()[1], r"(a)\1");
}

#[test]
fn a_slate_that_takes_everything_declines_nothing() {
    let munch = Munch::new(["a", "b+", "[cd]"]).unwrap();
    assert!(munch.declined().is_empty());
    assert_eq!(munch.admitted(), munch.len());
}

#[test]
fn losing_every_pattern_is_the_one_refusal_this_plane_has() {
    // A partial refusal is success; a total one leaves nothing to read a refusal
    // list off of, so it has to cross as an error. And it must not arrive as
    // `NeedsPcre`, which would send a caller to retry on an arm that has no
    // anchored plane to retry with.
    let refused = Munch::new([r"(a)\1", r"(?<=x)y"]).unwrap_err();
    assert_eq!(refused, Error::NothingLexable { offered: 2 });
    assert!(refused.to_string().contains("2 patterns"));
}

#[test]
fn a_malformed_pattern_alone_is_a_total_refusal_and_not_a_panic() {
    assert!(matches!(
        Munch::new(["(unclosed"]),
        Err(Error::NothingLexable { offered: 1 })
    ));
}

#[test]
fn an_empty_slate_is_a_working_slate_that_matches_nothing() {
    // Not `NothingLexable`: a config file that listed no terminals is a real
    // state with a real answer, exactly as an empty `RegexSet` is.
    let munch = Munch::new(Vec::<&str>::new()).unwrap();
    assert!(munch.is_empty());
    assert_eq!(munch.admitted(), 0);
    assert!(munch.declined().is_empty());
    assert!(munch.token("anything", 0).is_none());
    assert!(munch.token("", 0).is_none());
}

// ── flags ───────────────────────────────────────────────────────────────────

#[test]
fn the_flags_this_plane_honors_change_what_a_terminal_means() {
    assert!(Munch::new(["abc"]).unwrap().token("ABC", 0).is_none());
    let folded = MunchBuilder::new(["abc"])
        .ignore_case(true)
        .build()
        .unwrap();
    assert_eq!(folded.token("ABC", 0).unwrap().len(), 3);

    // `.` and a newline, which is the flag `RegexSet` cannot take and this can —
    // and which has to work on its own, without a second flag propping it up.
    let strict = MunchBuilder::new(["a.b"]).build().unwrap();
    assert!(strict.token("a\nb", 0).is_none());
    let loose = MunchBuilder::new(["a.b"])
        .dot_matches_new_line(true)
        .build()
        .unwrap();
    assert_eq!(loose.token("a\nb", 0).unwrap().len(), 3);
}

#[test]
fn a_whitespace_terminal_can_match_a_line_break_with_no_flag_at_all() {
    // The bug the first draft of this plane had, and the reason it is a test with
    // no flag in it: the engine's internal `multiline` is the statement "the
    // haystack is a buffer rather than one line", and under the per-line model it
    // drops `\n` from every class run. Routing the ABI's line-anchor flag into it
    // left every lexer's whitespace terminal unable to see a line break — a wrong
    // tokenization of every multi-line input, and nothing a caller could fix.
    for pattern in [r"\s+", "[ \t\n]+", "[^x]+"] {
        let munch = Munch::new([pattern]).unwrap();
        for text in ["\n", " \n ", "\t\n\t"] {
            let token = munch
                .token(text, 0)
                .unwrap_or_else(|| panic!("{pattern:?} found nothing in {text:?}"));
            assert_eq!(token.len(), text.len(), "{pattern:?} over {text:?}");
        }
    }
}

#[test]
fn an_anchor_is_the_scan_offset_which_is_why_there_is_no_multi_line_knob() {
    // The behavior that makes `(?m)` unanswerable here, so the absent builder
    // method has a reason on record. The automaton starts where the caller
    // pointed, so `^` is satisfied at every offset that a scan can begin at,
    // and `$` is reachable from nowhere — a longest-match walk stops at its
    // furthest accepting reach and never learns where the buffer ended.
    let munch = Munch::new(["^b", "a$"]).unwrap();
    assert!(munch.declined().is_empty(), "{:?}", munch.declined());
    assert_eq!(munch.token_among("a\nb", 2, &[0]).unwrap().len(), 1);
    assert!(munch.token_among("a\nb", 0, &[1]).is_none());
}

#[test]
fn a_buffer_anchor_is_refused_as_a_wall_and_not_as_a_budget() {
    // `\A`/`\z` are the one refusal a caller cannot fix by asking for a bigger
    // build, and telling it apart from `States` is the whole point of carrying a
    // reason: the two were one value until this test asked why `\Ab` reported a
    // size problem. The engine lowers a buffer anchor to a position no automaton
    // determinized over the pattern alone can observe, so it declines outright.
    let munch = Munch::new(["b", r"\Ab", r"a\z"]).unwrap();
    assert_eq!(
        munch.declined(),
        [
            Refusal {
                pattern: 1,
                why: Why::BufferAnchor
            },
            Refusal {
                pattern: 2,
                why: Why::BufferAnchor
            },
        ]
    );

    // And, as ever, one refused terminal does not cost its neighbors.
    assert_eq!(munch.admitted(), 1);
    assert_eq!(munch.token("b", 0).unwrap().len(), 1);
}

#[test]
fn unicode_off_matches_bytes() {
    // Byte semantics are a choice with a visible consequence: `.` becomes one
    // byte rather than one codepoint, so it stops mid-character in `é`.
    let bytes = MunchBuilder::new(["."]).unicode(false).build().unwrap();
    assert_eq!(bytes.token("é", 0).unwrap().len(), 1);
    assert_eq!(Munch::new(["."]).unwrap().token("é", 0).unwrap().len(), 2);
}

// ── the allocation-free form ────────────────────────────────────────────────

#[test]
fn scan_into_answers_exactly_what_the_owning_form_does() {
    // The two must not be allowed to drift, because one is the hot path and the
    // other is what everybody reads the documentation of.
    let munch = Munch::new(TERMINALS).unwrap();
    let mut winners = Vec::with_capacity(munch.admitted());
    for text in TEXTS {
        for at in 0..=text.len() {
            let raw = munch
                .scan_into(text, at, None, Pick::Longest, &mut winners)
                .unwrap();
            assert_eq!(
                raw.map(|len| (len, winners.clone())),
                ours(&munch, text, at),
                "at byte {at} of {text:?}"
            );
        }
    }
}

#[test]
fn scan_into_clears_the_buffer_even_when_nothing_matches() {
    // Otherwise a lexer reusing one buffer reads the previous token's winners as
    // this offset's, which is the exact bug the reuse is meant to be free of.
    let munch = Munch::new(["ab"]).unwrap();
    let mut winners = vec![7, 7, 7];
    assert_eq!(
        munch
            .scan_into("ab", 0, None, Pick::Longest, &mut winners)
            .unwrap(),
        Some(2)
    );
    assert_eq!(winners, vec![0]);
    assert_eq!(
        munch
            .scan_into("zz", 0, None, Pick::Longest, &mut winners)
            .unwrap(),
        None
    );
    assert!(winners.is_empty());
}

#[test]
fn scan_into_leaves_the_buffer_empty_on_an_error_too() {
    let munch = Munch::new(["a"]).unwrap();
    let mut winners = vec![7];
    assert!(
        munch
            .scan_into("a", 9, None, Pick::Longest, &mut winners)
            .is_err()
    );
    assert!(winners.is_empty());
}

#[test]
fn scan_into_takes_the_restriction_and_the_pick_like_its_wrappers() {
    let munch = Munch::new(["if", "[a-z]+"]).unwrap();
    let mut winners = Vec::new();
    assert_eq!(
        munch
            .scan_into("iffy", 0, Some(&[0]), Pick::Longest, &mut winners)
            .unwrap(),
        Some(2)
    );
    assert_eq!(winners, vec![0]);
    // Shortest over both: one byte, which only the identifier can be.
    assert_eq!(
        munch
            .scan_into("iffy", 0, Some(&[0, 1]), Pick::Shortest, &mut winners)
            .unwrap(),
        Some(1)
    );
    assert_eq!(winners, vec![1]);
}

// ── the type itself ─────────────────────────────────────────────────────────

#[test]
fn a_clone_reads_the_same_way_the_original_does() {
    // A clone recompiles, so this is the check that it recompiles the same thing
    // — the flags included, which a naive clone of the pattern list would lose.
    let munch = MunchBuilder::new(["abc", r"(a)\1"])
        .ignore_case(true)
        .build()
        .unwrap();
    let copy = munch.clone();
    assert_eq!(copy.patterns(), munch.patterns());
    assert_eq!(copy.declined(), munch.declined());
    assert_eq!(copy.admitted(), munch.admitted());
    assert_eq!(copy.token("ABC", 0).unwrap().len(), 3);
}

#[test]
fn many_threads_scanning_one_munch_read_what_one_thread_does() {
    // The C handle underneath owns the winner buffer every scan rewrites, so the
    // type keeps a pool. This is the test that the pool is doing its job: without
    // it, concurrent scans corrupt each other's answers rather than racing a
    // counter, and the corruption is silent.
    let munch = Munch::new(TERMINALS).unwrap();
    let alone: Vec<_> = TEXTS
        .iter()
        .map(|text| {
            (0..=text.len())
                .map(|at| ours(&munch, text, at))
                .collect::<Vec<_>>()
        })
        .collect();

    let together: Vec<Vec<_>> = std::thread::scope(|scope| {
        let handles: Vec<_> = TEXTS
            .iter()
            .map(|text| {
                let munch = &munch;
                scope.spawn(move || {
                    // Repeated, so a lease that leaked state between scans shows
                    // up rather than being one unlucky interleaving away.
                    (0..64)
                        .map(|_| {
                            (0..=text.len())
                                .map(|at| ours(munch, text, at))
                                .collect::<Vec<_>>()
                        })
                        .last()
                        .unwrap()
                })
            })
            .collect();
        handles.into_iter().map(|h| h.join().unwrap()).collect()
    });

    assert_eq!(together, alone);
}

#[test]
fn a_munch_is_send_and_sync_so_it_can_live_in_a_static() {
    const fn assert_shareable<T: Send + Sync>() {}
    assert_shareable::<Munch>();

    static OPERATORS: std::sync::LazyLock<Munch> =
        std::sync::LazyLock::new(|| Munch::new([">", ">>", ">>="]).unwrap());
    assert_eq!(OPERATORS.token(">>=", 0).unwrap().patterns(), &[2]);
}

#[test]
fn debug_names_the_patterns_and_what_was_lost() {
    let munch = Munch::new(["a", r"(a)\1"]).unwrap();
    let rendered = format!("{munch:?}");
    assert!(rendered.contains("Munch"), "{rendered}");
    // The pattern as `Debug` escapes it, which is the point of using `Debug` for
    // it: a terminal whose body is a backslash reads unambiguously.
    assert!(rendered.contains(r#""(a)\\1""#), "{rendered}");
    assert!(rendered.contains("Syntax"), "{rendered}");
}
