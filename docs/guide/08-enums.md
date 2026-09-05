# 8. Enums

An `enum` is a **tagged union**: a value that is exactly one of a fixed set of variants. Variants come in
two flavours:

- **Payload-less**: `enum Color { Red, Green, Blue }`. Each variant is a plain value referenced as
  `Color.Red`.
- **With a payload**: `enum Node { Leaf(int), Branch(int) }`. A payload variant is constructed like a
  call: `Node.Leaf(3)`.

You inspect an enum with `switch`, which matches a variant and, for payload variants, **binds** the
payload in the `case`. An enum may also declare methods (after its variants) that dispatch on `self`:
the same per-variant `switch` shape, packaged as a method.

```kyte
// examples/14_enums.ky
// Enums are tagged unions. Variants may be payload-less (`Color.Red`) or
// carry a payload (`Node.Leaf(3)`). `switch` matches a variant and binds its
// payload; a method on the enum dispatches per variant over `self`.

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

fn main(): void {
    // Payload-less variants are plain values: `Color.Green`.
    let c = Color.Green;
    console.log(`green code = ${c.code()}`);
    console.log(`blue  code = ${Color.Blue.code()}`);   // method on a literal

    // Payload variants are constructed like a call: `Node.Leaf(3)`.
    let leaf = Node.Leaf(3);
    let branch = Node.Branch(10);
    console.log(leaf.describe());
    console.log(branch.describe());

    // Match and bind the payload directly at the case site.
    let total = 0;
    switch (leaf)   { case Node.Leaf(v): { total = total + v; } case Node.Branch(v): { total = total + v; } }
    switch (branch) { case Node.Leaf(v): { total = total + v; } case Node.Branch(v): { total = total + v; } }
    console.log(`total payload = ${total}`);
}
```

Output:

```
green code = 2
blue  code = 3
leaf(3)
branch(10)
total payload = 13
```

| Concept | Form |
|---------|------|
| Payload-less variant | `enum Color { Red, Green, Blue }`, used as `Color.Red` |
| Payload variant | `enum Node { Leaf(int) }`, constructed `Node.Leaf(3)` |
| Match + bind payload | `case Node.Leaf(v): { ... v ... }` |
| Method on an enum | declared after the variants; dispatches with `switch (self)` |
| Call a method | `Color.Blue.code()` or `let c = Color.Blue; c.code()` |

A `switch` over an enum should cover every variant. The trailing `return 0;` / `return "?";` after each
`switch` above is a fallback the compiler is happy to see; methods must return on every path.

Next: [Traits](09-traits.md)
