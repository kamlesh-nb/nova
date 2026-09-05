# Video 03: Strings

- Chapter: [03-strings.md](../03-strings.md)
- Estimated length: ~8 minutes
- You will need: Kyte installed, and the previous two videos watched.

## Hook (0:00)

**Say:** Strings are everywhere in real programs, so let us get comfortable with them. In this video you will learn what a Kyte string actually is, the idiomatic way to build strings with template literals, and the string standard library that gives you things like uppercasing, slicing, and searching. By the end you will be formatting and manipulating text like it is second nature.

## What we will cover (0:25)

- What a `string` is under the hood
- Concatenation and the `.length` property
- Template literals, the canonical way to format
- The `string` standard library module

## Segment: What a string is (0:45)

**Say:** A Kyte `string` is a UTF-8 byte buffer with a length prefix. The idiomatic way to build strings is the template literal, those backtick strings with `${...}` holes in them. A template literal will stringify an `int`, `long`, `float`, `bool`, `decimal`, or `string` for you automatically. You should prefer it over gluing strings together with plus signs. Let us look at the full example, and we will use the `string` module, so we import it at the top.

**On screen:**
```kyte
// examples/04_strings.ky
import string;

fn main(): void {
    let a = "Hello";
    let b = "Kyte";
    console.log(a + ", " + b + "!");        // concatenation
    console.log(`length of "${a}" = ${a.length}`);
```

**Say:** At the top, `import string;` brings in the standard string functions. Inside `main`, `a` and `b` are two string literals. The first `console.log` shows concatenation with the plus operator, joining `"Hello"`, `", "`, `"Kyte"`, and `"!"` into one string. The second line shows two things: a template literal with `${a}` interpolated inside quotes, and `a.length`, which is the byte length of the string. Note that `length` is a property, not a method call, so there are no parentheses after it.

## Segment: Template interpolation (2:30)

**Say:** Template literals are not just for strings. They will stringify numbers and booleans and more, and you can even put whole expressions inside the `${...}`.

**On screen:**
```kyte
    // Template interpolation stringifies int/long/float/bool/decimal/string
    let n = 7;
    let ok = true;
    console.log(`n=${n} ok=${ok} half=${n / 2}`);
```

**Say:** Here `n` is 7 and `ok` is true. In the template we interpolate `n` directly, we interpolate the boolean `ok`, and then `${n / 2}` is an actual expression evaluated inside the braces. Since `n` is an integer, `n / 2` is integer division, so half comes out as 3, not 3.5. This is why template literals are the canonical formatter in Kyte: they handle the stringifying and let you drop expressions right in.

## Segment: The string standard library (3:55)

**Say:** Now the `string` module. Once you have imported it, you get a set of functions that operate at the byte and ASCII level. Here are four of them in action.

**On screen:**
```kyte
    // string stdlib (ASCII/byte level)
    console.log(`upper: ${string.toUpperCase("kyte")}`);
    console.log(`slice(0,3): ${string.slice("hypermedia", 0, 3)}`);
    console.log(`indexOf 'per': ${string.indexOf("hypermedia", "per")}`);
    console.log(`contains 'media': ${string.contains("hypermedia", "media")}`);
}
```

**Say:** `string.toUpperCase` uppercases the text, so `"kyte"` becomes `KYTE`. `string.slice` takes a start and an end and returns the substring in that half-open range, so slicing `"hypermedia"` from 0 to 3 gives `hyp`. `string.indexOf` returns the first index where a substring appears, or -1 if it is not found, so `"per"` is found at index 2. And `string.contains` is a simple yes or no, does the string contain this substring, so `"media"` gives true.

**Run it:** `kyte docs/guide/examples/04_strings.ky -o /tmp/strings && /tmp/strings`

```
Hello, Kyte!
length of "Hello" = 5
n=7 ok=true half=3
upper: KYTE
slice(0,3): hyp
indexOf 'per': 2
contains 'media': true
```

**Say:** Everything lines up. The concatenation produced `Hello, Kyte!`, the length of `Hello` is 5, half of 7 is 3, uppercasing gave KYTE, the slice gave hyp, indexOf found per at 2, and contains returned true.

## Segment: More of the module (6:00)

**Say:** There is more in the `string` module than the four we ran. Here is the wider set you will use day to day.

**On screen:**
```
string.toUpperCase(s) / toLowerCase(s)           case conversion
string.slice(s, start, end)                      substring [start, end)
string.indexOf(s, sub) / lastIndexOf             first/last index, or -1
string.contains(s, sub) / startsWith / endsWith  membership predicates
string.split(s, sep)                             List<string>
string.trim(s)                                   strip surrounding whitespace
string.replace(s, old, new)                      substitution
s.length                                          byte length (a property, not a call)
```

**Say:** So you have case conversion, slicing, index searching from the front or the back, membership predicates like `contains`, `startsWith`, and `endsWith`, `split` which returns a `List<string>`, `trim` to strip surrounding whitespace, and `replace` for substitution. And remember `s.length` is a property giving the byte length. One important caveat: all of these work at the byte and ASCII level. If you need real Unicode codepoint iteration rather than bytes, you use `text.utf8` instead.

## Recap (7:10)

**Say:** Let us recap.

- A `string` is a UTF-8 byte buffer with a length prefix.
- Template literals with backticks and `${...}` are the idiomatic formatter; they stringify numbers, booleans, and more, and can hold whole expressions.
- `s.length` is a property, not a method call.
- `import string;` gives you toUpperCase, slice, indexOf, contains, split, trim, replace, and friends, all at the byte and ASCII level.
- For real Unicode codepoints, reach for `text.utf8`.

## Outro (7:45)

**Say:** That is strings covered. Next we move on to control flow: if, else, loops, and how you steer your program. If you are getting value from this series, a like and subscribe helps it reach more people. See you in the next video.
