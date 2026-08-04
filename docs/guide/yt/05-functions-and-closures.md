# Video 05: Functions and closures

- Chapter: [05-functions-and-closures.md](../05-functions-and-closures.md)
- Estimated length: ~10 minutes
- You will need: the `nova` compiler installed, a terminal, and the guide's `examples/` folder open

## Hook (0:00)

**Say:** Functions are how you name and reuse work, and closures are functions you can pass around like values. In this video we will write plain functions, generic functions that work at many types, a struct method, and then closures that transform lists with `map`, `filter`, and `reduce`. By the end you will be comfortable writing both, and you will know the one gotcha about how closures capture variables.

## What we will cover (0:25)

- Declaring functions with `fn`, typed parameters and return types
- `void` functions
- Generic functions and monomorphization
- Methods with `self` versus free functions
- Closures, untyped parameters, and capture by value
- `map`, `filter`, and `reduce`

## Segment: plain and generic functions (0:55)

**Say:** A function is declared with `fn`. Parameters are typed, and the return type comes after the parameter list. If a function returns nothing you annotate it `void`. Generics take type parameters in angle brackets, and at the call site you write the type argument explicitly. Let us look at one program that shows all of these together.

**On screen:**
```nova
// examples/08_functions.nova

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
    greet("Nova");

    // identity works at any type; each call is a distinct instantiation.
    console.log(`identity<int>(42) = ${identity<int>(42)}`);
    console.log(`identity<string>("hi") = ${identity<string>("hi")}`);
    console.log(`firstOf<int>(10, 20) = ${firstOf<int>(10, 20)}`);

    // Method call vs free-function call.
    let c = Counter(41);
    console.log(`c.bumped() = ${c.bumped()}`);
}
```

**Say:** Start at the top. `add` takes two `int` parameters and returns an `int`. `greet` takes a string and returns `void`, meaning it does its work and hands nothing back. Then `identity` is generic: the `<T>` after the name is a type parameter, and the function returns whatever type it was given. `firstOf` is generic too and shows that one body can serve many types. Down in the struct, `Counter` has a method `bumped` that takes `self` as its first parameter. That `self` is the difference between a method and a free function.

**Say:** Now look at `main`. Notice how we call the generics: `identity<int>(42)` and `identity<string>("hi")`. The type argument is written explicitly at the call site. And `c.bumped()` is a method call on the instance `c`, so there is no `self` passed by hand, the receiver fills it in.

**Run it:**
```
nova examples/08_functions.nova -o out && ./out
```

```
add(2, 3) = 5
hello, Nova
identity<int>(42) = 42
identity<string>("hi") = hi
firstOf<int>(10, 20) = 10
c.bumped() = 42
```

**Say:** Everything lines up. `Counter(41)` starts the value at 41, and `bumped` returns 41 plus 1, which is 42. One important note on generics: Nova monomorphizes them. That means `identity<int>` and `identity<string>` compile to separate specialised bodies, not one type-erased routine. You get the convenience of generics with the performance of hand-written specialised code.

## Segment: closures (5:00)

**Say:** Now to closures. A closure is an anonymous function written with the fat arrow: params, then `=>`, then a body. The body is either a single expression, like `(x) => x + 1`, or a block wrapped in braces. Two things make closures special. First, their parameters are untyped, the types are inferred from how the closure is used. Second, a closure captures variables from the surrounding scope by value, meaning it takes a snapshot at creation time. Here they are in action, mostly feeding higher-order list methods.

**On screen:**
```nova
// examples/09_closures.nova
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

**Say:** Line by line. `inc` is a one-expression closure that adds 1. `addBase` captures the variable `base`, which is 100, so `addBase(5)` gives 105. Then we build a list of numbers 1 through 4 and put the workhorse methods to use. `map` transforms every element, here doubling each one. `filter` keeps only the elements where the predicate is true, so we count the evens. And `reduce` folds the whole list down to one value using an accumulator, here summing everything. Notice `reduce` uses a block-bodied, two-parameter closure with `acc` and `n`.

**Run it:**
```
nova examples/09_closures.nova -o out && ./out
```

```
inc(9) = 10
addBase(5) = 105
doubled = 2, 4, 6, 8
even count = 2
sum = 10
```

**Say:** Two things to lock in here. Parameters are untyped: we write `(x) => x + 1`, not `(x: int)`. And capture is by value. `addBase` snapshots `base` at the moment it is created, so if you reassigned `base` later, `addBase` would still add the old 100. That snapshot behaviour is worth remembering, and the ownership chapter explains the memory model behind it.

## Recap (9:00)

**Say:** Let us recap:

- Functions use `fn` with typed parameters and a return type after the list, and `void` when nothing is returned.
- Generics take `<T>` and are called with an explicit type argument like `identity<int>(42)`, and Nova monomorphizes them into specialised bodies.
- Methods take `self`; free functions do not.
- Closures use the fat arrow, have untyped parameters, and capture surrounding variables by value.
- `map` transforms, `filter` selects, and `reduce` folds a list to a single value.

## Outro (9:40)

**Say:** Next we will dig into collections proper: `List`, `Map`, and `Set`, where these closures really earn their keep. If you are finding this useful, a quick like or subscribe helps a lot. See you there.
