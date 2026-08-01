//! Errors: what a refusal says, and that a negative status never becomes an
//! answer.
//!
//! The C ABI reports failure as a negative status plus per-incident detail in a
//! thread-local fault slot. The binding's job is to never let one of those become
//! a wrong result, and to say something a caller can act on.

use irregex::{Error, Regex, RegexBuilder};

#[test]
fn a_bad_pattern_is_an_error_not_a_panic() {
    for pattern in ["(unclosed", "[z-a]", "a{9,1}", "*", "(?P<", r"\"] {
        let why = Regex::new(pattern).expect_err(pattern);
        assert!(
            matches!(why, Error::Syntax { .. }),
            "{pattern}: expected a syntax error, got {why:?}"
        );
        let said = why.to_string();
        // The message has to name the pattern it is about, because a caller
        // compiling several from a config file has no other way to tell which.
        assert!(said.contains(pattern), "{pattern}: message was {said:?}");
        // And the reason, not just a number. The engine's fault name and its own
        // sentence for the status both have to be in there.
        assert!(said.contains("cannot compile"), "{said:?}");
        assert!(said.len() > 30, "a bare status is not a reason: {said:?}");
        assert!(why.status().is_some());
        assert!(!why.is_out_of_memory());
        // It is a real error type, usable where one is expected.
        let boxed: Box<dyn std::error::Error> = Box::new(why);
        assert!(boxed.source().is_none());
    }
}

/// Lookaround and backreferences are not in the linear grammar, and the engine
/// says so rather than reinterpreting them. This is the error a caller will
/// actually hit, so its message should point at the fix.
#[test]
fn constructs_outside_the_linear_grammar_are_refused() {
    for pattern in ["foo(?=bar)", "(?<=x)y", "(?!x)", "(?i)x"] {
        let why = Regex::new(pattern).expect_err(pattern);
        assert!(
            matches!(why, Error::NeedsPcre { .. }),
            "{pattern}: expected a declinature, got {why:?}"
        );
        // And the same pattern under `pcre` compiles, so the refusal is about
        // the grammar and not the pattern being nonsense.
        RegexBuilder::new(pattern)
            .pcre(true)
            .build()
            .unwrap_or_else(|why| panic!("{pattern} should compile under pcre: {why}"));
    }
}

/// A pattern PCRE2 itself rejects has to come back as an error too, not as a
/// handle that misbehaves later.
#[test]
fn pcre_reports_its_own_refusals() {
    let why = RegexBuilder::new(r"(?<=a+)b")
        .pcre(true)
        .build()
        .expect_err("a variable-length lookbehind is not valid PCRE2");
    assert!(matches!(why, Error::Syntax { .. }), "{why:?}");
    assert!(why.to_string().contains("(?<=a+)b"));
}

// ── the two ways a compile says no ────────────────────────────────────────
//
// The engine tells them apart by asking PCRE2 whether it could express the
// pattern, and answers on the status code. So these tests assert the two
// outcomes and the repair each one implies, which is all a caller can act on.

/// Every pattern the linear grammar declines is one the PCRE2 arm accepts. The
/// declinature is only worth a variant if that promise holds, so it is checked
/// by actually compiling and matching rather than by trusting the status.
#[test]
fn a_declined_pattern_compiles_and_matches_under_pcre() {
    let rescuable = [
        ("(?=x)", "x"),
        ("(?<=x)y", "xy"),
        (r"(a)\1", "aa"),
        ("(?>ab)", "ab"),
    ];
    for (pattern, text) in rescuable {
        let why = Regex::new(pattern).expect_err(pattern);
        assert!(
            matches!(why, Error::NeedsPcre { .. }),
            "{pattern}: expected a declinature, got {why:?}"
        );
        // The message has to name the pattern and the repair, because "this
        // engine cannot" without "that flag can" is not actionable.
        let said = why.to_string();
        assert!(said.contains(pattern), "{pattern}: message was {said:?}");
        assert!(
            said.contains("pcre"),
            "{pattern}: no repair named: {said:?}"
        );

        let re = RegexBuilder::new(pattern)
            .pcre(true)
            .build()
            .unwrap_or_else(|why| panic!("{pattern} should compile under pcre: {why}"));
        assert!(
            re.is_match(text),
            "{pattern} compiled under pcre but did not match {text:?}"
        );
    }
}

/// The retry a caller writes, in the shape the docs promise it can be written.
#[test]
fn the_retry_idiom_is_two_lines() {
    fn compile(pattern: &str) -> Result<Regex, Error> {
        match Regex::new(pattern) {
            Err(Error::NeedsPcre { .. }) => RegexBuilder::new(pattern).pcre(true).build(),
            other => other,
        }
    }

    // The linear arm answers this one, so the retry never runs.
    assert!(compile(r"\d+").unwrap().is_match("42"));
    // This one only the PCRE2 arm can express, and the retry gets it.
    assert_eq!(
        compile(r"(?<=\$)\d+")
            .unwrap()
            .find("cost $42")
            .unwrap()
            .as_str(),
        "42"
    );
    // And a malformed pattern still fails, rather than being retried into a
    // second identical failure the caller cannot tell apart from the first.
    assert!(matches!(
        compile("(unclosed").unwrap_err(),
        Error::Syntax { .. }
    ));
}

/// A malformed pattern says where. The offset is the one thing a caller can do
/// something with - underline it, point at it in a config file - so it has to
/// be a real index into the pattern they handed over.
#[test]
fn a_malformed_pattern_carries_an_offset_pcre_cannot_rescue() {
    for pattern in ["(unclosed", "a{2,1}", "[z-a]", "*x", "[abc"] {
        let why = Regex::new(pattern).expect_err(pattern);
        let Error::Syntax {
            pattern: reported,
            at,
            status,
            detail,
        } = &why
        else {
            panic!("{pattern}: expected a syntax error, got {why:?}");
        };
        assert_eq!(reported, pattern);
        assert!(
            *at <= pattern.len(),
            "{pattern}: offset {at} is outside a pattern of {} bytes",
            pattern.len()
        );
        // Sliceable, which is what makes it usable for pointing at the problem.
        let _ = &pattern[..*at];
        assert!(status.code() < 0);
        assert!(
            detail.is_some(),
            "{pattern}: the engine names this fault, and the message should carry it"
        );
        let said = why.to_string();
        assert!(said.contains(&format!("byte {at}")), "{said:?}");
        assert!(said.contains(pattern), "{said:?}");

        // And the other arm will not take it either, so retrying is not the
        // repair here. That is the whole difference from `NeedsPcre`.
        let under_pcre = RegexBuilder::new(pattern)
            .pcre(true)
            .build()
            .expect_err("pcre does not rescue a malformed pattern");
        assert!(
            matches!(under_pcre, Error::Syntax { .. }),
            "{pattern} under pcre: {under_pcre:?}"
        );
    }
}

/// The offsets the engine reports, pinned. A test that only checked `at <=
/// len` would pass with every offset collapsed to 0, which is the bogus answer
/// this variant exists to avoid.
#[test]
fn the_offsets_are_where_the_problem_is() {
    let expected = [
        ("(unclosed", 9),
        ("a{2,1}", 5),
        ("[z-a]", 4),
        ("*x", 1),
        ("[abc", 4),
    ];
    let got: Vec<_> = expected
        .iter()
        .map(|(pattern, _)| match Regex::new(pattern) {
            Err(Error::Syntax { at, .. }) => (*pattern, at),
            other => panic!("{pattern}: {other:?}"),
        })
        .collect();
    assert_eq!(got, expected.to_vec());
}

/// The offset is measured in the PATTERN, which the fault now states instead of
/// leaving a reader to infer it from a NULL path.
///
/// A non-ASCII pattern is where losing that would show: the offset has to index
/// these bytes - so it can exceed the character count, land on a `char`
/// boundary, and slice - rather than being a position in some other string. The
/// only other ruler the shared vocabulary declares is a byte in a file, and no
/// verb in this crate opens one, so an offset arriving in that space would be
/// about a subject the caller was never given.
#[test]
fn the_offset_indexes_the_pattern_and_not_some_other_string() {
    for (pattern, want) in [("café(unclosed", 14), ("日本[z-a]", 10)] {
        let why = Regex::new(pattern).expect_err(pattern);
        let Error::Syntax { at, .. } = why else {
            panic!("{pattern}: expected a syntax error, got {why:?}");
        };
        assert_eq!(at, want, "{pattern}");
        assert!(at <= pattern.len(), "{pattern}: {at} is past the end");
        assert!(
            at > pattern.chars().count(),
            "{pattern}: byte {at} should be past the character count, or the offset is being \
             read in the wrong unit"
        );
        // Sliceable is the whole point: this is the text the engine got through.
        assert!(pattern.is_char_boundary(at));
        let _ = &pattern[..at];
    }
}

/// A refusal with no position says nothing about one, rather than reporting the
/// zero that "no offset" is spelled as. Byte 0 is a real place in a pattern, so
/// the two facts cannot share a number and the seam keeps them apart.
#[test]
fn a_refusal_without_a_position_reports_none() {
    let declined = Regex::new("(?=x)").expect_err("outside the linear grammar");
    assert!(matches!(declined, Error::NeedsPcre { .. }), "{declined:?}");
    assert!(
        !declined.to_string().contains("byte"),
        "a declinature has no offset to name: {declined}"
    );

    // And where there is one, byte 0 survives being reported rather than reading
    // as absence.
    let at_the_start = Regex::new("*x").expect_err("a leading quantifier");
    assert!(
        matches!(at_the_start, Error::Syntax { at: 1, .. }),
        "{at_the_start:?}"
    );
}

/// A declinature is not a compile: nothing is handed back, and nothing is kept.
///
/// The C ABI leaves its out-parameter untouched on this path, so a binding that
/// read it would keep whatever was already in that slot. Looping proves both
/// halves - that no iteration ever yields a handle, and, under the sanitizer
/// lane, that no iteration allocates one nobody frees.
#[test]
fn a_declinature_yields_no_handle_and_keeps_nothing() {
    for _ in 0..10_000 {
        let outcome = Regex::new("(?=x)");
        assert!(
            matches!(outcome, Err(Error::NeedsPcre { .. })),
            "a declinature must not produce a Regex"
        );
    }
    // The pattern that *is* compilable still is, so the loop above did not
    // leave the engine in a state where nothing works.
    assert!(Regex::new(r"\d+").unwrap().is_match("42"));
}

/// A declinature carries no fault detail, and in particular not the detail
/// belonging to whatever failed before it.
///
/// The fault slot holds this thread's *last* failure. A binding that read it on
/// the declinature path - the path where the seam installs nothing - would dress
/// a pattern that merely needs another arm in the name and offset of an
/// unrelated malformed one. Asserted through what a caller can see: the message.
#[test]
fn a_declinature_does_not_borrow_the_previous_failures_detail() {
    let earlier = Regex::new("(unclosed").expect_err("malformed");
    let Error::Syntax { at, detail, .. } = &earlier else {
        panic!("expected a syntax error, got {earlier:?}");
    };
    let (at, named) = (*at, detail.clone().expect("the engine names this fault"));

    let declined = Regex::new("(?=x)").expect_err("outside the linear grammar");
    assert!(matches!(declined, Error::NeedsPcre { .. }), "{declined:?}");
    let said = declined.to_string();
    assert!(
        !said.contains(&named),
        "the declinature inherited the previous fault name: {said:?}"
    );
    assert!(
        !said.contains(&format!("byte {at}")),
        "the declinature inherited the previous offset: {said:?}"
    );
    assert!(!said.contains("unclosed"), "{said:?}");
}

/// The variants a caller is expected to branch on stay distinguishable, because
/// "out of memory" and "your pattern is wrong" call for different handling.
#[test]
fn variants_are_distinguishable() {
    let pattern = Regex::new("(").unwrap_err();
    assert!(!pattern.is_out_of_memory());

    let oom = Error::OutOfMemory { detail: None };
    assert!(oom.is_out_of_memory());
    assert_eq!(oom.status(), Some(irregex::Status::OUT_OF_MEMORY));
    assert_eq!(oom.status().unwrap().code(), -2);
    assert!(oom.to_string().contains("out of memory"));
    assert!(!oom.status().unwrap().message().is_empty());

    let boundary = Error::NotCharBoundary { offset: 1 };
    assert_eq!(
        boundary.status(),
        None,
        "no status crossed the seam for this"
    );
    assert!(!boundary.is_out_of_memory());
    assert_ne!(pattern, boundary);

    // The two refusals a compile can produce, told apart from each other and
    // from a failure that is about neither the pattern nor the grammar. A
    // caller branching on these is choosing between retrying, reporting an
    // offset, and giving up, so collapsing any pair would cost a repair.
    let declined = Regex::new("(?=x)").unwrap_err();
    let malformed = Regex::new("(?=x").unwrap_err();
    assert!(matches!(declined, Error::NeedsPcre { .. }), "{declined:?}");
    assert!(matches!(malformed, Error::Syntax { .. }), "{malformed:?}");
    assert_ne!(declined, malformed);
    assert_ne!(declined, boundary);
    assert_ne!(declined, oom);
    assert_ne!(malformed, boundary);
    assert_ne!(declined.status(), malformed.status());
    assert_eq!(declined.status(), Some(irregex::Status::DECLINED));
    assert_eq!(declined.status().unwrap().code(), -1);
    assert!(!declined.is_out_of_memory());
    // Distinguishable at a glance too: the declinature names the repair and the
    // syntax error names a place, and neither says the other's thing.
    assert!(declined.to_string().contains("pcre"));
    assert!(!malformed.to_string().contains("pcre"));
}

/// `Status` is public so a caller can log the number the engine used together
/// with the library's own sentence for it, rather than a bare integer.
#[test]
fn status_carries_the_engines_own_sentence() {
    let refused = Regex::new("(").unwrap_err().status().expect("a status");
    assert!(refused.code() < 0);
    assert!(
        !refused.message().is_empty(),
        "the library has a sentence for every status it returns"
    );
    assert!(format!("{refused}").contains(&format!("status {}", refused.code())));

    let oom = irregex::Status::OUT_OF_MEMORY;
    assert_eq!(oom.code(), -2);
    assert!(oom.message().to_lowercase().contains("memory"));
    assert!(format!("{oom}").contains("status -2"));
    assert!(format!("{oom:?}").contains("Status(-2"));
}

/// `fixed(true)` means the pattern is data, so nothing about it can be a syntax
/// error. A binding that ran the grammar anyway would reject strings a user is
/// entitled to search for.
#[test]
fn a_fixed_pattern_cannot_be_invalid() {
    for pattern in ["(unclosed", "[z-a]", "*", r"\", "a{9,1}"] {
        let re = RegexBuilder::new(pattern)
            .fixed(true)
            .build()
            .unwrap_or_else(|why| panic!("{pattern} as a literal: {why}"));
        let text = format!("x{pattern}y");
        assert_eq!(re.find(&text).map(|m| m.as_str()), Some(pattern));
    }
}

/// The one thing that must never happen: a negative status read as "no match".
/// Every verb either answers or errors, and the empty pattern over empty text is
/// the case where "no match" is genuinely the right answer, so it is the control.
#[test]
fn no_match_and_failure_are_different_answers() {
    let re = Regex::new("a").unwrap();
    assert!(!re.try_is_match("").unwrap());
    assert_eq!(re.try_find("").unwrap(), None);
    assert_eq!(re.try_find_iter("").unwrap().count(), 0);
    assert!(re.try_captures("").unwrap().is_none());
    assert_eq!(re.try_captures_iter("").unwrap().count(), 0);
    // And an empty text is not a failure to search, so nothing errors.
    assert_eq!(re.split("").collect::<Vec<_>>(), [""]);
    assert_eq!(re.replace_all("", "x"), "");
}

/// The name table holds exactly what the engine declared, so a name nobody
/// declared has no number - including the near misses a caller is most likely to
/// hand over by accident.
#[test]
fn unknown_names_do_not_resolve() {
    let re = Regex::new(r"(?P<real>a)(b)").unwrap();
    assert_eq!(re.group_index("real"), Some(1));
    assert_eq!(re.group_index("nope"), None);
    assert_eq!(re.group_index(""), None);
    assert_eq!(re.group_index("REAL"), None, "names are case sensitive");

    let caps = re.captures("ab").unwrap();
    assert_eq!(caps.name("nope"), None);
    assert_eq!(caps.get(9), None);
}

#[test]
#[should_panic(expected = "no group named")]
fn indexing_an_unknown_name_says_so() {
    let re = Regex::new("(a)").unwrap();
    let _ = &re.captures("a").unwrap()["nope"];
}

/// The number is load-bearing rather than decorative: ABI 2 is the revision
/// where the fault started naming which ruler its offset is measured in and
/// `find_all` started reporting the text's own count. A library still speaking 1
/// would answer both questions in a shape this crate reads wrong, and it looks
/// identical from the outside, so the version gate is the only thing standing
/// between that and a silently misread struct.
#[test]
fn abi_version_is_checked() {
    // Compiling anything at all forces the check, and a mismatch would be an
    // `Error::Abi` rather than a struct read against the wrong layout.
    assert!(Regex::new("a").is_ok());
    assert_eq!(irregex::ABI_VERSION, 2);

    let stale = irregex::ABI_VERSION - 1;
    let mismatch = Error::Abi {
        expected: irregex::ABI_VERSION,
        found: stale,
    };
    let said = mismatch.to_string();
    assert!(
        said.contains(&format!("ABI {}", irregex::ABI_VERSION)),
        "{said:?}"
    );
    assert!(said.contains(&format!("ABI {stale}")), "{said:?}");
    // The message has to name the lever that causes it, because the usual reason
    // is a stale library on a search path.
    assert!(said.contains("IRREGEX_LIB_DIR"));
}
