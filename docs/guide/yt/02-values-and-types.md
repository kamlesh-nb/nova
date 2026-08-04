# Video 02: Values and types

- Chapter: [02-values-and-types.md](../02-values-and-types.md)
- Estimated length: ~9 minutes
- You will need: Nova installed, and the first video watched so you know how to compile and run.

## Hook (0:00)

**Say:** Nova is statically typed, which means every value has a type the compiler knows about before your program ever runs. In this video we will walk through the scalar types, the operators you use on them, how to cast between numeric types, and the two ways to declare variables. By the end you will be comfortable writing real expressions and binding values to names.

## What we will cover (0:25)

- The scalar types: `int`, `long`, `float`, `bool`, `string`
- Operators: arithmetic, bitwise, and shifts
- Casting between numeric types with `as`
- Variables: `let` versus `const`
- Tuple destructuring
- Value types versus reference types

## Segment: The scalar types (0:50)

**Say:** Nova's scalar types are `int`, which is a 32-bit signed integer, `long`, which is 64-bit, `float`, which is an IEEE-754 double, `bool`, and `string`. There is also a `decimal` type for exact base-10 arithmetic, and `ptr` for low-level code, but we will leave those for later chapters. One thing worth burning into memory now: `int` is honestly 32-bit, so its arithmetic wraps at 2 to the power 31. If you need 64-bit values, reach for `long`.

**On screen:**
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
```

**Say:** Here we declare one of each type with an explicit annotation after the colon. Notice `big` holds ten billion, which is far past the 32-bit range, so it has to be a `long`. Then we print each one using template literals with the `${...}` interpolation we saw in the last video.

## Segment: Operators (2:40)

**Say:** Now let us look at operators. Nova has the arithmetic, bitwise, and shift operators you would expect. Here is the second half of the same file.

**On screen:**
```nova
    // Operators
    console.log(`7 / 2   = ${7 / 2}`);      // integer division -> 3
    console.log(`7 % 2   = ${7 % 2}`);      // modulo -> 1
    console.log(`2 ** via mul 2*2*2 = ${2 * 2 * 2}`);
    console.log(`1 << 4  = ${1 << 4}`);     // bit shift -> 16
    console.log(`6 & 3   = ${6 & 3}`);      // bitwise AND -> 2
    console.log(`6 | 1   = ${6 | 1}`);      // bitwise OR  -> 7
    console.log(`5 ^ 1   = ${5 ^ 1}`);      // XOR -> 4
```

**Say:** A few things to point out. `7 / 2` is integer division, so it gives 3, not 3.5, because both operands are integers. `7 % 2` is modulo, the remainder, which is 1. Then we have the bitwise operators: `<<` shifts bits left, so `1 << 4` is 16, `&` is bitwise AND, `|` is bitwise OR, and `^` is XOR. To round out the set: comparison is `== != < > <= >=`, logical is `&&` and `||`, `~x` is bitwise NOT, and there are compound assignment forms like `+=` and `<<=`.

## Segment: Casting with `as` (4:15)

**Say:** Nova does not silently convert between numeric types. When you want to convert, you say so explicitly with the `as` keyword.

**On screen:**
```nova
    // Casts with `as`
    let f: float = i as float;
    let back: int = pi as int;              // truncates -> 3
    console.log(`42 as float = ${f}, 3.14159 as int = ${back}`);
}
```

**Say:** Here `i as float` turns our integer 42 into a float. Going the other way, `pi as int` truncates 3.14159 down to 3, dropping the fractional part. The `as` keyword is also what you use for trait downcasts later on.

**Run it:** `nova docs/guide/examples/02_primitives.nova -o /tmp/primitives && /tmp/primitives`

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

**Say:** There it all is. Integer division gives 3, the shifts and bitwise ops match the comments, and the casts behave exactly as promised.

## Segment: Variables, let and const (5:55)

**Say:** Now, variables. Nova has exactly two binding keywords. `let` is mutable, meaning you can reassign it. `const` is immutable, and trying to reassign a `const` is a compile error. That is it, there is no `var`, it was removed. And when the compiler can work out the type for you, the annotation is optional.

**On screen:**
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

**Say:** Look at `count`. We wrote `let count = 0` with no type, and the compiler infers `int`. Because it is a `let`, we can reassign it, so `count = count + 5` is fine. Then `const pi` is immutable, reassigning it would not compile. `x` shows an explicit annotation, `let x: int = 10`. And at the bottom we have tuple destructuring: `pair` returns a tuple of two ints, and `let (a, b) = pair()` unpacks them straight into two names.

**Run it:** `nova docs/guide/examples/03_variables.nova -o /tmp/variables && /tmp/variables`

```
count = 5
pi = 3.14159
x = 10
a = 1, b = 2
```

**Say:** `count` became 5 after the reassignment, and `a` and `b` came out as 1 and 2 from the tuple.

## Segment: Value versus reference (7:45)

**Say:** One last concept. Some types are value types and some are reference types, and this matters for how they are stored and copied. The primitives, `int`, `long`, `float`, `bool`, `ptr`, and enums, are value types and live on the stack. Things like `string`, `decimal`, lists, maps, sets, structs, tuples, and closures are reference types: heap objects managed by automatic reference counting, or ARC. The syntax you write is the same either way, the type decides. And importantly, you never call `free` yourself. There is a whole chapter on ownership and memory later if you want the details.

## Recap (8:20)

**Say:** Let us recap.

- The scalar types are `int` (32-bit), `long` (64-bit), `float`, `bool`, and `string`.
- Operators cover arithmetic, comparison, logical, bitwise, and shifts, plus compound assignment.
- Numeric conversions are explicit with `x as T`.
- `let` is mutable, `const` is immutable; there is no `var`.
- Tuples can be destructured with `let (a, b) = ...`.
- Primitives are value types; strings, collections, and structs are reference types managed by ARC.

## Outro (8:55)

**Say:** That gives you a solid grip on Nova's values and types. Next up we look at strings in detail: template literals, concatenation, and the string standard library. If this helped, do drop a like and subscribe. See you there.
