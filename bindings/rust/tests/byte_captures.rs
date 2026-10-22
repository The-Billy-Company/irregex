//! Raw byte capture offsets, context, and native resource refusals.

#![cfg(feature = "source-engine")]

use irgx::{Error, RegexBuilder};

#[test]
fn byte_captures_preserve_full_context_offsets_and_unset_groups() {
    let regex = RegexBuilder::new(r"\G(?<=\xff)(a)|(b)")
        .unicode(false)
        .pcre(true)
        .build()
        .unwrap();
    let source = b"\xffa\xc3\xa9";
    assert_eq!(
        regex.try_capture_ranges_at(source, 1).unwrap(),
        Some(vec![Some(1..2), Some(1..2), None])
    );
    assert_eq!(regex.try_capture_ranges_at(source, 2).unwrap(), None);
    assert!(matches!(
        regex.try_capture_ranges_at(source, 5),
        Err(Error::BadWindow { .. })
    ));
}
#[test]
fn byte_captures_accept_mid_codepoint_and_zero_width() {
    let regex = RegexBuilder::new(r"\G(.)?")
        .unicode(false)
        .pcre(true)
        .build()
        .unwrap();
    assert_eq!(
        regex.try_capture_ranges_at("é".as_bytes(), 1).unwrap(),
        Some(vec![Some(1..2), Some(1..2)])
    );
    assert_eq!(
        regex.try_capture_ranges_at(b"", 0).unwrap(),
        Some(vec![Some(0..0), None])
    );
}
#[test]
fn byte_captures_surface_pcre_match_limits() {
    let regex = RegexBuilder::new(r"(*LIMIT_MATCH=10)\G(?:a+)+$")
        .unicode(false)
        .pcre(true)
        .build()
        .unwrap();
    let mut source = vec![b'a'; 100];
    source.push(b'b');
    assert!(regex.try_capture_ranges_at(&source, 0).is_err());
}

#[test]
fn explicit_capture_limits_survive_clones_and_faults_do_not_poison_clean_calls() {
    let depth = RegexBuilder::new(r"\G(a+)+$")
        .unicode(false)
        .pcre(true)
        .match_limit(1_000_000)
        .depth_limit(1)
        .heap_limit_bytes(1 << 20)
        .build()
        .unwrap();
    let source = b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!";
    assert!(depth.try_capture_ranges_at(source, 0).is_err());
    assert!(depth.clone().try_capture_ranges_at(source, 0).is_err());
    let heap = RegexBuilder::new(r"\G(a+)+$")
        .unicode(false)
        .pcre(true)
        .heap_limit_bytes(0)
        .build()
        .unwrap();
    assert!(heap.try_capture_ranges_at(source, 0).is_err());
    let clean = RegexBuilder::new(r"\G(a)")
        .unicode(false)
        .pcre(true)
        .match_limit(1000)
        .depth_limit(100)
        .heap_limit_bytes(1 << 20)
        .build()
        .unwrap();
    assert_eq!(
        clean.try_capture_ranges_at(b"a", 0).unwrap(),
        Some(vec![Some(0..1), Some(0..1)])
    );
}
