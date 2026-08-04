# 4. Control flow

## `if` / `while`, and `if` as an expression

Conditions **must** be `bool`; Nova does not treat integers or pointers as truthy. `if` doubles as an
expression, so you can bind its result.

```nova
// examples/05_control_flow.nova
fn main(): void {
    let n = 7;
    if (n % 2 == 0) {
        console.log("even");
    } else {
        console.log("odd");
    }

    // if is also an expression
    let label = if (n > 5) "big" else "small";
    console.log(`label = ${label}`);

    // while
    let i = 0;
    let sum = 0;
    while (i < 5) {
        sum = sum + i;
        i = i + 1;
    }
    console.log(`sum 0..4 = ${sum}`);
}
```

Output:

```
odd
label = big
sum 0..4 = 10
```

## The four `for` forms

Nova has one keyword, `for`, with four shapes. The increment lives in its own block, so `continue`
runs it in every form.

```nova
// examples/06_for_loops.nova
import collections.list;

fn main(): void {
    // C-style
    for (let i: int = 0; i < 3; i = i + 1) {
        console.log(`c-style i=${i}`);
    }

    // range, exclusive (0,1,2) and inclusive (1..=3 -> 1,2,3)
    for (i in 0..3)  { console.log(`exclusive ${i}`); }
    for (i in 1..=3) { console.log(`inclusive ${i}`); }

    // over a collection
    let xs = list.List<string>();
    xs.push("a"); xs.push("b"); xs.push("c");
    for (x in xs) { console.log(`item ${x}`); }

    // break / continue
    let total = 0;
    for (i in 0..10) {
        if (i == 5) { break; }
        if (i % 2 == 0) { continue; }
        total = total + i;
    }
    console.log(`odd sum below 5 = ${total}`);   // 1 + 3 = 4
}
```

Output:

```
c-style i=0
c-style i=1
c-style i=2
exclusive 0
exclusive 1
exclusive 2
inclusive 1
inclusive 2
inclusive 3
item a
item b
item c
odd sum below 5 = 4
```

There is also a map form, `for ((k, v) in m) { ... }`, covered in [Collections](06-collections.md).

Range syntax: `a..b` is **exclusive** of `b`; `a..=b` is **inclusive**. Ranges are meaningful inside a
`for` header (they are not yet a first-class value you can store).

## `switch`

`switch` matches enum values and can **bind a variant's payload**:

```nova
// examples/07_switch.nova
enum Shape { Circle(int), Square(int), Point }

fn area(s: Shape): int {
    switch (s) {
        case Shape.Circle(r): { return 3 * r * r; }   // binds the payload r
        case Shape.Square(side): { return side * side; }
        case Shape.Point: { return 0; }
    }
    return -1;
}

fn main(): void {
    console.log(`circle(2)  area ~= ${area(Shape.Circle(2))}`);
    console.log(`square(3)  area  = ${area(Shape.Square(3))}`);
    console.log(`point      area  = ${area(Shape.Point)}`);
}
```

Output:

```
circle(2)  area ~= 12
square(3)  area  = 9
point      area  = 0
```

More on enums and payloads in [chapter 8](08-enums.md).

Next: [Functions & closures](05-functions-and-closures.md)
