# Video 04: Control flow

- Chapter: [04-control-flow.md](../04-control-flow.md)
- Estimated length: ~9 minutes
- You will need: the `nova` compiler installed, a terminal, and the guide's `examples/` folder open

## Hook (0:00)

**Say:** In this video we will learn how Nova makes decisions and repeats work. By the end you will know how to write `if` both as a statement and as an expression, all four shapes of the `for` loop, and how `switch` can pull a value out of an enum in a single line. It is a small set of tools, but together they cover almost everything you will do day to day.

## What we will cover (0:20)

- `if` and `while`, and using `if` as an expression
- The four `for` forms in Nova
- `break` and `continue`
- `switch` and binding a variant's payload

## Segment: if and while (0:45)

**Say:** Let us start with the basics. One rule to remember up front: in Nova a condition must be a `bool`. Nova does not treat integers or pointers as truthy, so you always compare explicitly. Here is a small program that mixes an `if`, an `if` used as an expression, and a `while` loop.

**On screen:**
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

**Say:** The first `if` is an ordinary statement: `n % 2 == 0` is a `bool`, so if `n` is even we log "even", otherwise "odd". The interesting line is the next one. `if` doubles as an expression, so `if (n > 5) "big" else "small"` produces a value that we bind straight into `label`. No temporary variable, no early assignment. Finally the `while` loop runs while `i` is less than 5, adding each `i` into `sum`.

**Run it:**
```
nova examples/05_control_flow.nova -o out && ./out
```

```
odd
label = big
sum 0..4 = 10
```

**Say:** `n` is 7, so we get "odd", `label` is "big" because 7 is greater than 5, and the loop adds 0 through 4 to give 10.

## Segment: the four for forms (3:00)

**Say:** Nova has one loop keyword, `for`, but it comes in four shapes. The nice detail is that the increment lives in its own block, so `continue` still runs the increment in every form. Let us see all four.

**On screen:**
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

**Say:** The first form is the classic C-style loop with an initialiser, a condition, and an increment. The second and third are ranges. Note the difference: `0..3` is exclusive of the end, so you get 0, 1, 2, while `1..=3` with the equals sign is inclusive, so you get 1, 2, 3. The third form iterates over a collection, here a `List` of strings. And the last block shows `break` and `continue` together: we stop entirely when `i` hits 5, we skip even numbers with `continue`, and we sum the rest.

**Say:** One thing to know about ranges: they are meaningful inside a `for` header, but they are not yet a first-class value you can store in a variable. Use them where you see them here.

**Run it:**
```
nova examples/06_for_loops.nova -o out && ./out
```

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

**Say:** Walk through the last number with me. We loop from 0 up to 9. At `i` equals 5 we `break`, so we never reach anything above 4. Even numbers are skipped by `continue`, leaving just 1 and 3, which add up to 4. There is also a map form, `for ((k, v) in m)`, but that belongs with collections, so we will meet it in the next video.

## Segment: switch (6:30)

**Say:** Last tool for this video: `switch`. In Nova, `switch` matches enum values, and it can bind a variant's payload right in the case label. That last part is what makes it powerful. Here is an enum for shapes, where a circle and a square each carry an integer.

**On screen:**
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

**Say:** Look at each case. `case Shape.Circle(r)` does two things at once: it matches the Circle variant, and it binds that variant's payload into a fresh variable `r` that you can use inside the block. So for a circle we compute 3 times r times r. Same idea for the square with `side`. The `Point` variant has no payload, so we just return 0. This is much cleaner than checking a tag and then reaching in for the value separately.

**Run it:**
```
nova examples/07_switch.nova -o out && ./out
```

```
circle(2)  area ~= 12
square(3)  area  = 9
point      area  = 0
```

**Say:** Circle with radius 2 gives 3 times 2 times 2, which is 12. Square with side 3 gives 9. And the point is 0. There is a lot more to enums and payloads, and we cover that properly in the enums chapter.

## Recap (8:15)

**Say:** Quick recap of what we learned:

- Conditions in Nova must be `bool`, no truthy integers or pointers.
- `if` works as a statement and as an expression you can bind to a variable.
- `for` has four forms: C-style, exclusive range, inclusive range with `..=`, and over a collection, plus `break` and `continue`.
- `switch` matches enum variants and binds their payload in the case label.

## Outro (8:45)

**Say:** Next up we will look at functions and closures, where these tools start doing real work inside reusable pieces of code. If this helped, a like or subscribe keeps the series going. See you in the next one.
