# Video 08: Enums

- Chapter: [08-enums.md](../08-enums.md)
- Estimated length: ~9 minutes
- You will need: Kyte installed and on your PATH, a terminal, and the file `examples/14_enums.ky` from the guide.

## Hook (0:00)

**Say:** In this video we meet enums, which are one of the most useful shapes in a statically typed language. An enum lets you say a value is exactly one of a fixed set of options, and each option can even carry data with it. By the end you will be able to declare payload-less and payload-carrying enums, match on them with `switch`, bind the payload, and add methods that dispatch per variant. Let us dive in.

## What we will cover (0:20)

- What a tagged union is
- Payload-less variants, like `Color.Red`
- Payload variants, like `Node.Leaf(3)`
- Matching and binding with `switch`
- Methods on an enum that dispatch on `self`

## Segment: What an enum is (0:45)

**Say:** An `enum` is a tagged union. That is a fancy way of saying a value that is exactly one of a fixed set of variants, never more than one, and never something outside the set. Variants come in two flavours. Some are payload-less, they are just a plain named value. Others carry a payload, some extra data that rides along. We will build one of each.

## Segment: Payload-less variants with a method (1:30)

**Say:** First a colour type. Three plain variants: Red, Green, Blue. You refer to one as `Color.Red`. And an enum can carry methods too, declared after the variants. This one returns a numeric code, and it dispatches on `self` using a `switch`.

**On screen:**
```kyte
// Payload-less variants, plus a method that dispatches on the value.
enum Color {
    Red,
    Green,
    Blue,

    pub fn code(self: Color): int {
        switch (self) {
            case Color.Red:   { return 1; }
            case Color.Green: { return 2; }
            case Color.Blue:  { return 3; }
        }
        return 0;
    }
}
```

**Say:** So `code` looks at `self`, and for each variant it returns a different number. Notice the `return 0` sitting after the `switch`. A method must return on every path, and the compiler is happy to see that fallback there. A `switch` over an enum should cover every variant, and this one does.

## Segment: Payload variants (3:00)

**Say:** Now a type where each variant carries data. Here `Node` has a `Leaf` and a `Branch`, and each one holds an `int`. You construct a payload variant like a function call, so `Node.Leaf(3)`. The `describe` method matches each variant and binds the payload into a name we can use, here called `v`.

**On screen:**
```kyte
// Payload variants: each carries an int. `sum` folds the tree recursively,
// binding the payload in each `case`.
enum Node {
    Leaf(int),
    Branch(int),

    pub fn describe(self: Node): string {
        switch (self) {
            case Node.Leaf(v):   { return `leaf(${v})`; }
            case Node.Branch(v): { return `branch(${v})`; }
        }
        return "?";
    }
}
```

**Say:** Look at the `case` lines. `case Node.Leaf(v)` does two jobs at once: it matches the Leaf variant, and it binds the payload to `v`, which we then drop into the string with `${v}`. Same for Branch. And again there is a fallback `return "?"` after the switch so every path returns.

## Segment: Using the enums in main (4:45)

**Say:** Let us use both types. Payload-less variants are just plain values, so we can store `Color.Green` in a variable and call a method on it, and we can even call a method straight on a literal like `Color.Blue`.

**On screen:**
```kyte
fn main(): void {
    // Payload-less variants are plain values: `Color.Green`.
    let c = Color.Green;
    console.log(`green code = ${c.code()}`);
    console.log(`blue  code = ${Color.Blue.code()}`);   // method on a literal
```

**Say:** So `c` holds Green and `c.code()` gives 2, and calling `code` directly on `Color.Blue` gives 3. Now the payload side.

**On screen:**
```kyte
    // Payload variants are constructed like a call: `Node.Leaf(3)`.
    let leaf = Node.Leaf(3);
    let branch = Node.Branch(10);
    console.log(leaf.describe());
    console.log(branch.describe());
```

**Say:** We build a Leaf holding 3 and a Branch holding 10, then ask each to describe itself. Finally, let us match on them outside a method and add the payloads up.

**On screen:**
```kyte
    // Match and bind the payload directly at the case site.
    let total = 0;
    switch (leaf)   { case Node.Leaf(v): { total = total + v; } case Node.Branch(v): { total = total + v; } }
    switch (branch) { case Node.Leaf(v): { total = total + v; } case Node.Branch(v): { total = total + v; } }
    console.log(`total payload = ${total}`);
}
```

**Say:** Each `switch` binds the payload to `v` and adds it to a running `total`. The leaf contributes 3, the branch contributes 10, so we expect 13 at the end.

**Run it:**
```
kyte examples/14_enums.ky -o out && ./out
```

```
green code = 2
blue  code = 3
leaf(3)
branch(10)
total payload = 13
```

**Say:** Exactly what we predicted. Green is 2, Blue is 3, the two nodes describe themselves, and the payloads add up to 13.

## Segment: A note on coverage (7:45)

**Say:** One habit to build. A `switch` over an enum should cover every variant. In our methods we also added a trailing `return` after each switch, and the compiler is happy to see that fallback, since methods must return on every path. When you add a new variant to an enum later, the compiler helps you find the switches that need updating.

## Recap (8:15)

**Say:** Here is the shape to remember.

- An `enum` is a tagged union: a value that is exactly one of a fixed set of variants.
- Payload-less variants like `Color.Red` are plain values.
- Payload variants like `Node.Leaf(3)` are constructed like a call and carry data.
- `switch` matches a variant and, with `case Node.Leaf(v)`, binds the payload for you.
- An enum can declare methods after its variants that dispatch on `self`.

## Outro (8:45)

**Say:** Next we look at traits, Kyte's interfaces, which give you polymorphism through dynamic dispatch. If you are enjoying the series, a like and subscribe really helps. See you there.
