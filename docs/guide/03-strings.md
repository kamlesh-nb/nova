# 3. Strings

A `string` is a UTF-8 byte buffer with a length prefix. The idiomatic way to build strings is the
**template literal** (`` `...${expr}...` ``), which stringifies `int`/`long`/`float`/`bool`/`decimal`/
`string` for you. Prefer it over manual `+` concatenation.

```kyte
// examples/04_strings.ky
import string;

fn main(): void {
    let a = "Hello";
    let b = "Kyte";
    console.log(a + ", " + b + "!");        // concatenation
    console.log(`length of "${a}" = ${a.length}`);

    // Template interpolation stringifies int/long/float/bool/decimal/string
    let n = 7;
    let ok = true;
    console.log(`n=${n} ok=${ok} half=${n / 2}`);

    // string stdlib (ASCII/byte level)
    console.log(`upper: ${string.toUpperCase("kyte")}`);
    console.log(`slice(0,3): ${string.slice("hypermedia", 0, 3)}`);
    console.log(`indexOf 'per': ${string.indexOf("hypermedia", "per")}`);
    console.log(`contains 'media': ${string.contains("hypermedia", "media")}`);
}
```

Output:

```
Hello, Kyte!
length of "Hello" = 5
n=7 ok=true half=3
upper: KYTE
slice(0,3): hyp
indexOf 'per': 2
contains 'media': true
```

## The `string` module

`import string;` brings the standard string functions. They operate at the byte/ASCII level:

| Function | Result |
|----------|--------|
| `string.toUpperCase(s)` / `toLowerCase(s)` | case conversion |
| `string.slice(s, start, end)` | substring `[start, end)` |
| `string.indexOf(s, sub)` / `lastIndexOf` | first/last index, or `-1` |
| `string.contains(s, sub)` / `startsWith` / `endsWith` | membership predicates |
| `string.split(s, sep)` | `List<string>` |
| `string.trim(s)` | strip surrounding whitespace |
| `string.replace(s, old, new)` | substitution |
| `s.length` | byte length (a property, not a call) |

For real Unicode codepoint iteration (rather than bytes), use `text.utf8`.

## Borrowed views: `Str`

A `string` OWNS its bytes: it is heap-allocated, reference-counted, and copied when you slice it. Most of
the time that is exactly what you want. But on a hot path, minting a fresh owned `string` for every
substring adds allocations you do not need. For that, Kyte has a borrowed view type, `Str`, from the
`str` module. It is Kyte's equivalent of Rust's `&str`.

A `Str` is just a `{ ptr, len }` pair: an address and a byte count that BORROW a run of UTF-8 bytes it
does not own. There is no allocation, no reference count, and no retain or release traffic. It is a value
struct, so passing or copying a `Str` copies only the two fields, never the bytes, and every copy shares
the same backing store.

```kyte
import str;

let owner = "hypermedia";           // an owned string; it holds the bytes
let view  = str.sub(owner, 0, 5);   // a Str borrowing "hyper", no copy
console.log(`${view.size()} bytes`);// 5
```

You create a view from an owned `string` with `str.of(s)` (the whole string) or `str.sub(s, start, end)`
(a half-open slice), and directly from a raw span with `str.raw(ptr, n)`. A view exposes `size()` (the
byte length) and `byteAt(i)` (the byte at an offset).

The one rule that matters: **a `Str` must not outlive the bytes it borrows.** There is no borrow checker
to enforce this, so the guarantee is yours: keep the backing `string` (or buffer) alive for as long as
any view into it is used, and never store a `Str` in a field, a list, or a return value that escapes that
scope. When a value genuinely has to escape, copy it into an owned `string` with `toOwned()`:

```kyte
fn keep(v: str.Str): string {
    return v.toOwned();   // copies the borrowed bytes into a fresh, self-owned string
}
```

Where you meet `Str` in practice is the zero-copy paths in the standard library: response rendering reads
straight out of a borrowed buffer into the output, and the database ORM can surface a row's raw wire
bytes as a `Str` (through `DbValue.asView`) so a read binds without allocating an intermediate string.
That is also the caveat behind the sound-versus-zero-copy read distinction in the data-access chapter: a
`Str` that points into a result-set buffer is only valid while that buffer lives, so a DTO of `Str` fields
must be consumed before the buffer is freed, or its fields turned into owned strings with `toOwned()`.

Reach for `Str` when profiling shows substring allocations hurting a hot loop. Everywhere else, plain
owned `string` is simpler and always safe.

Next: [Control flow](04-control-flow.md)
