package irgx_test

import (
	"errors"
	"fmt"
	"log"
	"regexp"

	irgx "github.com/The-Billy-Company/irregex/bindings/go"
)

func ExampleRegexp_FindAllString() {
	re := irgx.MustCompile(`\w+`)
	fmt.Println(re.FindAllString("naïve café", -1))
	// Output: [naïve café]
}

func ExampleRegexp_FindStringIndex() {
	// The offsets are byte offsets, so they slice the string you passed.
	const text = "le CAFÉ noir"
	loc := irgx.CompileOpts{IgnoreCase: true}.MustCompile("café").FindStringIndex(text)
	fmt.Println(loc, text[loc[0]:loc[1]])
	// Output: [3 8] CAFÉ
}

func ExampleCompileOpts() {
	// Fixed makes the pattern a literal, so metacharacters are just characters.
	re := irgx.CompileOpts{Fixed: true}.MustCompile("a.c")
	fmt.Println(re.FindAllString("a.c abc", -1))
	// Output: [a.c]
}

func ExampleRegexp_FindStringSubmatchIndex() {
	// A group that did not participate is -1, -1, which an empty match never is.
	re := irgx.MustCompile(`(a)|(b)`)
	fmt.Println(re.FindStringSubmatchIndex("b"))
	// Output: [0 1 -1 -1 0 1]
}

func ExampleRegexp_ReplaceAllString() {
	re := irgx.MustCompile(`(?P<user>\w+)@(\w+)`)
	fmt.Println(re.ReplaceAllString("bob@host and eve@box", "$2/${user}"))
	// Output: host/bob and box/eve
}

// A pattern that can match nothing follows the standard library's rules, so
// swapping regexp for this package does not change which matches you get: the
// empty match at 1 is dropped for abutting the "a", and the one at the end of
// the text is kept.
func ExampleRegexp_FindAllStringIndex_nullable() {
	fmt.Println(irgx.MustCompile(`a*`).FindAllStringIndex("abc", -1))
	fmt.Println(regexp.MustCompile(`a*`).FindAllStringIndex("abc", -1))
	// Output:
	// [[0 1] [2 2] [3 3]]
	// [[0 1] [2 2] [3 3]]
}

func ExampleCompile_error() {
	_, err := irgx.Compile(`foo(?=bar)`)
	fmt.Println(err != nil)
	// Lookaround needs the PCRE2 grammar; the default one is linear time.
	re := irgx.CompileOpts{PCRE: true}.MustCompile(`foo(?=bar)`)
	fmt.Println(re.FindAllString("foobar foobaz", -1))
	// Output:
	// true
	// [foo]
}

// A refusal a caller can act on: the linear grammar declined a construct the
// vendored PCRE2 has, so the same text compiles with one flag set.
func ExampleErrNeedsPCRE() {
	const pattern = `foo(?=bar)`
	re, err := irgx.Compile(pattern)
	if errors.Is(err, irgx.ErrNeedsPCRE) {
		re, err = irgx.CompileOpts{PCRE: true}.Compile(pattern)
	}
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(re.FindAllString("foobar foobaz", -1))
	// Output: [foo]
}

// Which of many patterns match, in one pass over the text, keeping which one it
// was. The indices are positions in the compiled list, so Patterns() names them.
func ExampleSet() {
	kinds := irgx.MustCompileSet(`^func `, `^type `, `^var `, `^const `)
	for _, decl := range []string{"type Set struct {", "x := 1"} {
		fmt.Println(decl, kinds.MatchString(decl), kinds.WhichString(decl))
	}
	// Output:
	// type Set struct { true [1]
	// x := 1 false []
}

// A set refuses as a unit and says which pattern caused it, because "one of them
// is unsupported" is not something a caller with two hundred patterns can act on.
func ExampleSetError() {
	_, err := irgx.CompileSet(`^func `, `c(?=at)`, `\d+`)
	var refused *irgx.SetError
	if errors.As(err, &refused) {
		fmt.Println(refused.Index, refused.Expr, errors.Is(err, irgx.ErrNeedsPCRE))
	}
	// Output: 1 c(?=at) true
}

// The other refusal, which no flag rescues. It carries the offset, so a caller
// can point at the byte the engine stopped on.
func ExampleSyntaxError() {
	_, err := irgx.Compile(`[abc`)
	var bad *irgx.SyntaxError
	if errors.As(err, &bad) {
		fmt.Printf("%s\n%*s\n", bad.Expr, bad.At+1, "^")
	}
	fmt.Println(err)
	// Output:
	// [abc
	//     ^
	// irregex: compile "[abc": BadPattern at byte 4
}
