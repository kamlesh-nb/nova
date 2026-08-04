# 2. Values & types

Nova is statically typed. The scalar types are `int` (32-bit signed), `long` (64-bit), `float` (a.k.a.
`f64`/`double`, IEEE-754), `bool`, and `string`. There is also `decimal` (exact base-10, see
[chapter 12](12-decimal.md)) and `ptr` (an opaque machine word for low-level code).

> **`int` is honestly 32-bit**: its arithmetic wraps at 2^31. Use `long` for 64-bit values.

## Primitives, operators, and casts

```nova
// examples/02_primitives.nova
fn main(): void {
    let i: int = 42;              // 32-bit signed
    let big: long = 10000000000;  // 64-bit
    let pi: float = 3.14159;      // IEEE-754 double
    let ok: bool = true;
    let name: string = "Nova";

    console.log(`int:    ${i}`);
    console.log(`long:   ${big}`);
    console.log(`float:  ${pi}`);
    console.log(`bool:   ${ok}`);
    console.log(`string: ${name}`);

    // Operators
    console.log(`7 / 2   = ${7 / 2}`);      // integer division -> 3
    console.log(`7 % 2   = ${7 % 2}`);      // modulo -> 1
    console.log(`2 ** via mul 2*2*2 = ${2 * 2 * 2}`);
    console.log(`1 << 4  = ${1 << 4}`);     // bit shift -> 16
    console.log(`6 & 3   = ${6 & 3}`);      // bitwise AND -> 2
    console.log(`6 | 1   = ${6 | 1}`);      // bitwise OR  -> 7
    console.log(`5 ^ 1   = ${5 ^ 1}`);      // XOR -> 4

    // Casts with `as`
    let f: float = i as float;
    let back: int = pi as int;              // truncates -> 3
    console.log(`42 as float = ${f}, 3.14159 as int = ${back}`);
}
```

Output:

```
int:    42
long:   10000000000
float:  3.14159
bool:   true
string: Nova
7 / 2   = 3
7 % 2   = 1
2 ** via mul 2*2*2 = 8
1 << 4  = 16
6 & 3   = 2
6 | 1   = 7
5 ^ 1   = 4
42 as float = 42, 3.14159 as int = 3
```

**Operators at a glance:** arithmetic `+ - * / %`; comparison `== != < > <= >=`; logical `&& ||`; bitwise
`& ^ |` with shifts `<< >>` (`^` is XOR; `~x` is bitwise NOT); compound assignment `+= -= *= /= %=` and
`&= |= ^= <<= >>=`. Conversions between numeric types (and trait downcasts) use `x as T`.

## Variables: `let` and `const`

There are exactly two binding keywords (`var` was removed):

- `let x = ...`: **mutable**.
- `const x = ...`: **immutable**; reassigning it is a compile error.

Type annotations are optional when the type can be inferred. Tuples can be **destructured**.

```nova
// examples/03_variables.nova
fn main(): void {
    let count = 0;          // inferred int, mutable
    count = count + 5;      // ok, let is mutable
    console.log(`count = ${count}`);

    const pi = 3.14159;     // immutable; reassigning is a compile error
    console.log(`pi = ${pi}`);

    let x: int = 10;        // explicit annotation
    console.log(`x = ${x}`);

    // Tuple destructuring
    let (a, b) = pair();
    console.log(`a = ${a}, b = ${b}`);
}

fn pair(): (int, int) { return (1, 2); }
```

Output:

```
count = 5
pi = 3.14159
x = 10
a = 1, b = 2
```

## Value vs reference

Primitives (`int`/`long`/`float`/`bool`/`ptr`/enums) are **value types** on the stack. `string`,
`decimal`, `List`/`Map`/`Set`, structs, tuples, and closures are **reference types**: heap objects
managed by automatic reference counting (ARC). The syntax is the same; the type decides. You never call
`free`; see [Ownership & memory](13-ownership.md).

Next: [Strings](03-strings.md)
