//! Replacement: the [`Replacer`] trait, `$name` expansion, and the three verbs.
//!
//! The trait is the `regex` crate's shape, so `re.replace_all(text, "$1")`, a
//! `String`, and a `|caps: &Captures| -> String` closure all work where a Rust
//! programmer expects them to.
//!
//! One thing here is more than convenience. A replacement with no `$` in it
//! needs no capture groups, so [`Replacer::no_expansion`] lets the whole
//! substitution run off the match spans alone. That is what makes
//! `re.replace_all(text, "x")` work for a pattern whose capture arm the engine
//! refused - the case where asking for groups would fail but nothing in the
//! request actually wanted them.

use std::borrow::Cow;

use crate::error::Error;
use crate::matches::Captures;
use crate::pattern::{Regex, expect};

impl Regex {
    /// `text` with the leftmost match replaced by `rep`.
    ///
    /// # Panics
    ///
    /// On an engine fault, or if `rep` needs capture groups this pattern cannot
    /// provide. See [`Regex::try_replacen`].
    #[must_use]
    pub fn replace<'t, R: Replacer>(&self, text: &'t str, rep: R) -> Cow<'t, str> {
        expect(self.try_replacen(text, 1, rep))
    }

    /// `text` with every match replaced by `rep`.
    ///
    /// # Panics
    ///
    /// On an engine fault, or if `rep` needs capture groups this pattern cannot
    /// provide. See [`Regex::try_replacen`].
    #[must_use]
    pub fn replace_all<'t, R: Replacer>(&self, text: &'t str, rep: R) -> Cow<'t, str> {
        expect(self.try_replacen(text, 0, rep))
    }

    /// `text` with at most `limit` matches replaced by `rep`; `0` means all of
    /// them, as in the `regex` crate.
    ///
    /// # Panics
    ///
    /// On an engine fault, or if `rep` needs capture groups this pattern cannot
    /// provide. See [`Regex::try_replacen`].
    #[must_use]
    pub fn replacen<'t, R: Replacer>(&self, text: &'t str, limit: usize, rep: R) -> Cow<'t, str> {
        expect(self.try_replacen(text, limit, rep))
    }

    /// [`Regex::replacen`], reporting a fault instead of panicking.
    ///
    /// # Errors
    ///
    /// Everything [`Regex::try_find_iter`] can report, plus [`Error::Groups`]
    /// when `rep` needs capture groups and this pattern has none available.
    pub fn try_replacen<'t, R: Replacer>(
        &self,
        text: &'t str,
        limit: usize,
        mut rep: R,
    ) -> Result<Cow<'t, str>, Error> {
        let found = self.try_find_iter(text)?;
        if found.len() == 0 {
            return Ok(Cow::Borrowed(text));
        }
        let ceiling = if limit == 0 { usize::MAX } else { limit };

        // Resolved before the loop: a literal replacement is the same bytes every
        // time, and knowing that keeps the whole pass off the capture arm.
        let literal = rep.no_expansion().map(Cow::into_owned);

        let mut out = String::with_capacity(text.len());
        let mut cut = 0;
        for span in found.take(ceiling) {
            out.push_str(&text[cut..span.start()]);
            match &literal {
                Some(text) => out.push_str(text),
                None => {
                    let caps = self.captures_at(text, span.start(), span.end())?;
                    rep.replace_append(&Captures::new(self, text, caps), &mut out);
                },
            }
            cut = span.end();
        }
        out.push_str(&text[cut..]);
        Ok(Cow::Owned(out))
    }
}

/// What a replacement is made of.
///
/// Implemented for `&str` / `String` / `Cow<str>` (with `$name` expansion), for
/// [`NoExpand`] (without), and for any `FnMut(&Captures) -> impl AsRef<str>`.
pub trait Replacer {
    /// Append this match's replacement to `dst`.
    fn replace_append(&mut self, caps: &Captures<'_, '_>, dst: &mut String);

    /// The replacement as a fixed string, when it holds no group reference.
    ///
    /// Answering `Some` is what lets a substitution skip the capture engine
    /// entirely, so an implementation that can be literal should say so.
    fn no_expansion(&mut self) -> Option<Cow<'_, str>> {
        None
    }
}

/// A replacement string with no `$` expansion: every byte of it is literal.
#[derive(Clone, Copy, Debug)]
pub struct NoExpand<'a>(pub &'a str);

impl Replacer for NoExpand<'_> {
    fn replace_append(&mut self, _caps: &Captures<'_, '_>, dst: &mut String) {
        dst.push_str(self.0);
    }

    fn no_expansion(&mut self) -> Option<Cow<'_, str>> {
        Some(Cow::Borrowed(self.0))
    }
}

/// A replacement holding no `$` at all is already its own answer.
fn literal<T: AsRef<str> + ?Sized>(replacement: &T) -> Option<Cow<'_, str>> {
    let text = replacement.as_ref();
    (!text.contains('$')).then_some(Cow::Borrowed(text))
}

/// The string-like replacements, which all behave identically: expand `$name`
/// references, and report themselves literal when there is nothing to expand.
macro_rules! string_replacer {
    ($($ty:ty),+ $(,)?) => { $(
        impl Replacer for $ty {
            fn replace_append(&mut self, caps: &Captures<'_, '_>, dst: &mut String) {
                expand(caps, self.as_ref(), dst);
            }

            fn no_expansion(&mut self) -> Option<Cow<'_, str>> {
                literal(&**self)
            }
        }
    )+ };
}

string_replacer!(&str, String, &String, Cow<'_, str>);

impl<F, T> Replacer for F
where
    F: FnMut(&Captures<'_, '_>) -> T,
    T: AsRef<str>,
{
    fn replace_append(&mut self, caps: &Captures<'_, '_>, dst: &mut String) {
        dst.push_str(self(caps).as_ref());
    }
}

/// Write `template` into `dst`, resolving group references against `caps`.
///
/// `$$` is a literal `$`. `${name}` names a group explicitly; `$name` takes the
/// longest run of `[0-9A-Za-z_]`. A name that is all digits is a group number.
/// A reference to a group that does not exist, or that this match did not enter,
/// expands to nothing - the same rule the `regex` crate follows, and the reason
/// `$1` in a template is not a way to discover a typo.
pub(crate) fn expand(caps: &Captures<'_, '_>, template: &str, dst: &mut String) {
    let bytes = template.as_bytes();
    let mut at = 0;
    while at < bytes.len() {
        let Some(offset) = bytes[at..].iter().position(|b| *b == b'$') else {
            dst.push_str(&template[at..]);
            return;
        };
        dst.push_str(&template[at..at + offset]);
        at += offset + 1;
        if bytes.get(at) == Some(&b'$') {
            dst.push('$');
            at += 1;
            continue;
        }
        match reference(&template[at..]) {
            // A `$` that starts nothing is a `$`, so a template holding a price
            // survives being used as a replacement.
            None => dst.push('$'),
            Some((name, taken)) => {
                at += taken;
                if let Some(found) = lookup(caps, name) {
                    dst.push_str(found.as_str());
                }
            },
        }
    }
}

/// The group reference at the start of `rest`, and how many bytes it spans.
fn reference(rest: &str) -> Option<(&str, usize)> {
    if let Some(body) = rest.strip_prefix('{') {
        let close = body.find('}')?;
        return Some((&body[..close], close + 2));
    }
    let taken = rest
        .bytes()
        .take_while(|b| b.is_ascii_alphanumeric() || *b == b'_')
        .count();
    (taken > 0).then(|| (&rest[..taken], taken))
}

fn lookup<'t>(caps: &Captures<'_, 't>, name: &str) -> Option<crate::Match<'t>> {
    match name.parse::<usize>() {
        Ok(index) => caps.get(index),
        Err(_) => caps.name(name),
    }
}
