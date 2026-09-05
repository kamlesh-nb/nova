# 5. Functions & closures

## Functions

A function is declared with `fn`. Parameters are typed, and the return type follows the parameter
list. A function that returns nothing is annotated `void`. Generic functions take type parameters in
angle brackets; at the call site the type argument is written **explicitly** (`identity<int>(...)`).

```kyte
// examples/08_functions.ky

// A plain function: typed parameters, a declared return type.
fn add(a: int, b: int): int {
    return a + b;
}

// `void` means "returns nothing".
fn greet(name: string): void {
    console.log(`hello, ${name}`);
}

// A generic function. The type argument is written explicitly at the call site:
// `identity<int>(...)`.
fn identity<T>(x: T): T {
    return x;
}

// Generics let one body serve many types.
fn firstOf<T>(a: T, b: T): T {
    return a;
}

// A struct with a method. Methods take `self` as the first parameter;
// free functions do not. (Full struct coverage is in chapter 7.)
struct Counter {
    value: int,
    init(start: int) { self.value = start; }
    fn bumped(self: Counter): int { return self.value + 1; }
}

fn main(): void {
    console.log(`add(2, 3) = ${add(2, 3)}`);
    greet("Kyte");

    // identity works at any type; each call is a distinct instantiation.
    console.log(`identity<int>(42) = ${identity<int>(42)}`);
    console.log(`identity<string>("hi") = ${identity<string>("hi")}`);
    console.log(`firstOf<int>(10, 20) = ${firstOf<int>(10, 20)}`);

    // Method call vs free-function call.
    let c = Counter(41);
    console.log(`c.bumped() = ${c.bumped()}`);
}
```

Output:

```
add(2, 3) = 5
hello, Kyte
identity<int>(42) = 42
identity<string>("hi") = hi
firstOf<int>(10, 20) = 10
c.bumped() = 42
```

| Form | Example |
|------|---------|
| Free function | `fn add(a: int, b: int): int { ... }` |
| No return value | `fn greet(name: string): void { ... }` |
| Generic | `fn identity<T>(x: T): T { ... }`, called `identity<int>(42)` |
| Method | `fn bumped(self: Counter): int { ... }`, called `c.bumped()` |

Generics are **monomorphized**: `identity<int>` and `identity<string>` compile to separate
specialized bodies, not one type-erased routine. Full struct methods (including visibility and
`init`) are covered in [chapter 7](07-structs.md).

## Closures

A closure is an anonymous function written `(params) => body`. The body is either a single expression
(`(x) => x + 1`) or a block (`(a, b) => { ... }`). Closure parameters are **untyped**, and their types are
inferred from how the closure is used. A closure captures variables from the enclosing scope **by
value** (a snapshot at creation time).

The most common use is passing a closure to a higher-order method such as `List.map`, `filter`, or
`reduce`.

```kyte
// examples/09_closures.ky
import collections.list;

fn main(): void {
    // A closure literal. Parameters are UNTYPED, their types are inferred.
    let inc = (x) => x + 1;
    console.log(`inc(9) = ${inc(9)}`);

    // Closures capture variables from the surrounding scope (by value).
    let base = 100;
    let addBase = (x) => x + base;
    console.log(`addBase(5) = ${addBase(5)}`);

    // Higher-order use: pass closures to List.map / filter / reduce.
    let nums = list.List<int>();
    nums.push(1); nums.push(2); nums.push(3); nums.push(4);

    // An expression-bodied closure transforms each element.
    let doubled = nums.map((n) => n * 2);
    console.log(`doubled = ${doubled.get(0) ?? 0}, ${doubled.get(1) ?? 0}, ${doubled.get(2) ?? 0}, ${doubled.get(3) ?? 0}`);

    // filter keeps elements for which the predicate is true.
    let evens = nums.filter((n) => n % 2 == 0);
    console.log(`even count = ${evens.size()}`);

    // A block-bodied, two-parameter closure `(a, b) => { ... }` folds the list.
    let sum = nums.reduce(0, (acc, n) => {
        let next = acc + n;
        return next;
    });
    console.log(`sum = ${sum}`);
}
```

Output:

```
inc(9) = 10
addBase(5) = 105
doubled = 2, 4, 6, 8
even count = 2
sum = 10
```

Notes:

- **Untyped parameters**: `(x) => x + 1`, not `(x: int) => ...`. The type is inferred from the call
  site or the expected callback signature.
- **Capture is by value**: `addBase` snapshots `base`; a later reassignment of `base` would not
  change what `addBase` adds. (See [chapter 13](13-ownership.md) for the memory model.)
- **`map` / `filter` / `reduce`** are the workhorses: `map` transforms, `filter` selects, `reduce`
  folds a list to a single value with an accumulator.

Next: [Collections](06-collections.md)
