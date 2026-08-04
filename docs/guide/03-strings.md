# 3. Strings

A `string` is a UTF-8 byte buffer with a length prefix. The idiomatic way to build strings is the
**template literal** (`` `...${expr}...` ``), which stringifies `int`/`long`/`float`/`bool`/`decimal`/
`string` for you. Prefer it over manual `+` concatenation.

```nova
// examples/04_strings.nova
import string;

fn main(): void {
    let a = "Hello";
    let b = "Nova";
    console.log(a + ", " + b + "!");        // concatenation
    console.log(`length of "${a}" = ${a.length}`);

    // Template interpolation stringifies int/long/float/bool/decimal/string
    let n = 7;
    let ok = true;
    console.log(`n=${n} ok=${ok} half=${n / 2}`);

    // string stdlib (ASCII/byte level)
    console.log(`upper: ${string.toUpperCase("nova")}`);
    console.log(`slice(0,3): ${string.slice("hypermedia", 0, 3)}`);
    console.log(`indexOf 'per': ${string.indexOf("hypermedia", "per")}`);
    console.log(`contains 'media': ${string.contains("hypermedia", "media")}`);
}
```

Output:

```
Hello, Nova!
length of "Hello" = 5
n=7 ok=true half=3
upper: NOVA
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

Next: [Control flow](04-control-flow.md)
