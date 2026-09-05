# 7. Structs

A `struct` groups named fields under a type. Fields marked `pub` are readable from outside the struct;
an un-annotated field is **private**: only the struct's own methods can touch it. A struct declares a
constructor with `init` (no `fn`), instance methods that take `self: T` as their first parameter, and
static (associated) methods that omit `self` and are called as `Struct.method()`.

Fields are separated by commas or newlines. `init` assigns every field through `self`. Kyte is ARC-
managed, so a struct and everything it owns is freed deterministically when its last owner goes away:
no `free`, no GC.

```kyte
// examples/13_structs.ky
// A struct groups named fields, a constructor (`init`), instance methods
// (first parameter `self: T`), and static/associated methods (no `self`,
// called as `Struct.method()`).

struct Account {
    pub owner: string,        // pub fields are readable from outside
    balance: int,             // no `pub` -> private to the struct's methods

    init(owner: string, opening: int) {
        self.owner = owner;
        self.balance = opening;
    }

    // Static factory: no `self`, called as `Account.newAccount(...)`.
    pub fn newAccount(owner: string): Account {
        return Account(owner, 0);
    }

    // Instance methods take `self: Account` first.
    pub fn deposit(self: Account, amount: int): void {
        self.balance = self.balance + amount;
    }

    pub fn withdraw(self: Account, amount: int): bool {
        if (amount > self.balance) { return false; }   // reads a private field
        self.balance = self.balance - amount;
        return true;
    }

    pub fn statement(self: Account): string {
        return `${self.owner}: ${self.balance}`;
    }
}

fn main(): void {
    // Construct via the init constructor.
    let a = Account("Ada", 100);
    console.log(a.statement());

    a.deposit(50);
    console.log(`after deposit: ${a.statement()}`);

    let ok = a.withdraw(30);
    console.log(`withdraw 30 ok=${ok}, ${a.statement()}`);

    let tooMuch = a.withdraw(1000);   // exceeds balance -> refused
    console.log(`withdraw 1000 ok=${tooMuch}, ${a.statement()}`);

    // Static factory -> a fresh account with a zero opening balance.
    let b = Account.newAccount("Bob");
    console.log(b.statement());

    // pub field is directly readable.
    console.log(`owner of b = ${b.owner}`);
}
```

Output:

```
Ada: 100
after deposit: Ada: 150
withdraw 30 ok=true, Ada: 120
withdraw 1000 ok=false, Ada: 120
Bob: 0
owner of b = Bob
```

| Piece | Form | Notes |
|-------|------|-------|
| Field | `pub x: int` / `x: int` | `pub` = readable outside; bare = private |
| Constructor | `init(...) { self.x = ... }` | no `fn`; assigns every field |
| Instance method | `pub fn m(self: T, ...): R` | `self: T` is the first parameter |
| Static method | `pub fn f(...): R` (no `self`) | called `T.f(...)`, e.g. a factory |
| Construct | `T(args)` | runs `init`; also a struct literal `T{ x: 1 }` |

There are two ways to build a struct value: calling the constructor `Account("Ada", 100)` (runs `init`),
or a **struct literal** `UserDto{ id: 7, name: "Ada" }` that names each field directly; you will see the
literal form in the enum and trait chapters.

## `struct` is a value type; `class` is a reference type

A `struct` has **value semantics**: assigning it, or passing it to a function, makes an independent copy.
Change the copy and the original is untouched. This is like `int` or a tuple, just with named fields.

```kyte
let a = Account("Ada", 100);
let b = a;            // b is a COPY of a
b.deposit(50);        // changes b only
// a is still 100, b is 150
```

When you want the opposite, a single object that several holders SHARE, declare a `class` instead of a
`struct`. A `class` has **reference semantics**: assigning it hands out another handle to the same
object, so a change through one handle is visible through all of them. Both are managed by ARC, and both
are freed automatically; the only difference is copy versus share.

```kyte
class Counter {
    pub n: int,
    init() { self.n = 0; }
    pub fn bump(self: Counter): void { self.n = self.n + 1; }
}

let x = Counter();
let y = x;      // y refers to the SAME Counter as x
y.bump();       // x.n is now 1 as well
```

Reach for a `struct` by default: value semantics are easier to reason about, because nothing changes
under you through an alias. Use a `class` when you deliberately want shared, mutable state, for example a
cache or a connection pool that the whole app talks to through one instance.

Next: [Enums](08-enums.md)
