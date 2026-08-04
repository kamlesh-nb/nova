# Video 07: Structs

- Chapter: [07-structs.md](../07-structs.md)
- Estimated length: ~10 minutes
- You will need: Nova installed and on your PATH, a terminal, and the file `examples/13_structs.nova` from the guide.

## Hook (0:00)

**Say:** So far we have worked with plain values: numbers, strings, lists, and maps. In this video we group related data under one type and give it behaviour. By the end you will be able to write a Nova `struct` with private and public fields, a constructor, instance methods, and a static factory, and you will understand how Nova frees all of it for you automatically. We will build a small bank account type and watch it run.

## What we will cover (0:20)

- What a `struct` is and what `pub` means on a field
- The `init` constructor
- Instance methods that take `self`
- Static (associated) methods, used as a factory
- Two ways to build a struct value
- Automatic memory management with ARC

## Segment: What a struct is (0:45)

**Say:** A `struct` groups named fields under a single type. Some fields you want the outside world to read, and some you want to keep to yourself. In Nova you mark a field `pub` to make it readable from outside the struct. A field with no annotation is private, which means only the struct's own methods can touch it. Let us look at the header of our account type.

**On screen:**
```nova
struct Account {
    pub owner: string,        // pub fields are readable from outside
    balance: int,             // no `pub` -> private to the struct's methods
```

**Say:** So `owner` is public, anyone holding an `Account` can read it. But `balance` has no `pub`, so it is private. Only the methods we write inside `Account` are allowed to read or change it. That is how we protect the balance from being poked at directly. Notice fields are separated by commas here, you can also separate them with newlines.

## Segment: The init constructor (2:00)

**Say:** Next we need a way to build an account. In Nova the constructor is written with `init`, and notice there is no `fn` keyword in front of it. The job of `init` is to assign every field through `self`.

**On screen:**
```nova
    init(owner: string, opening: int) {
        self.owner = owner;
        self.balance = opening;
    }
```

**Say:** So `init` takes an owner name and an opening amount, and it stores both onto `self`. After `init` runs, both fields have a value. Every field should be assigned here.

## Segment: A static factory method (3:00)

**Say:** Sometimes you want a named way to build a common case. A static method, also called an associated method, has no `self` parameter, and you call it on the type itself as `Account.something`. Here is a factory that makes a fresh account with a zero opening balance.

**On screen:**
```nova
    // Static factory: no `self`, called as `Account.newAccount(...)`.
    pub fn newAccount(owner: string): Account {
        return Account(owner, 0);
    }
```

**Say:** Because there is no `self`, this belongs to the type, not to any one account. Inside it we just call the constructor with a zero opening balance and hand back the result. We will call this as `Account.newAccount("Bob")` later.

## Segment: Instance methods (4:15)

**Say:** Now the real behaviour. Instance methods take `self: Account` as their first parameter. That `self` is the particular account you are calling the method on. Here are deposit and withdraw.

**On screen:**
```nova
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
```

**Say:** `deposit` adds to the private balance. `withdraw` first checks whether you are asking for more than you have, and if so it refuses by returning `false`, otherwise it subtracts and returns `true`. Both of these read and write `balance`, the private field, and that is fine because they are methods on `Account`. `statement` builds a small summary string using a template literal with `${...}`. And that closing brace ends the struct.

## Segment: Building and using an account (5:45)

**Say:** Let us put it to work in `main`. There are two ways to construct a struct. The first is to call the constructor directly, which runs `init`.

**On screen:**
```nova
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
```

**Say:** We create Ada's account with an opening balance of 100, deposit 50, then withdraw 30, which succeeds. Then we try to withdraw 1000, which is more than she has, so `withdraw` returns `false` and the balance is left untouched. Watch how the `ok` flag flips between those two withdrawals.

**Say:** Now the second half of `main` shows the static factory and reading a public field directly.

**On screen:**
```nova
    // Static factory -> a fresh account with a zero opening balance.
    let b = Account.newAccount("Bob");
    console.log(b.statement());

    // pub field is directly readable.
    console.log(`owner of b = ${b.owner}`);
}
```

**Say:** We call `Account.newAccount("Bob")` on the type, and get back an account with a zero balance. Then we read `b.owner` straight off the value, which is allowed because `owner` is `pub`. If we tried to read `b.balance` here from outside, the compiler would stop us, because that field is private.

**Run it:**
```
nova examples/13_structs.nova -o out && ./out
```

```
Ada: 100
after deposit: Ada: 150
withdraw 30 ok=true, Ada: 120
withdraw 1000 ok=false, Ada: 120
Bob: 0
owner of b = Bob
```

**Say:** There it is. Ada starts at 100, goes to 150 after the deposit, drops to 120 after the successful withdrawal, stays at 120 when the big withdrawal is refused, Bob starts at 0, and we can read his name directly.

## Segment: Memory, the easy part (8:30)

**Say:** One thing worth calling out. Nova is ARC managed, which stands for automatic reference counting. A struct and everything it owns is freed for you, deterministically, when its last owner goes away. There is no `free` to call and there is no garbage collector pausing your program. You write the logic, Nova cleans up.

## Segment: The two ways to build, recapped (9:00)

**Say:** Quick note before we finish. We used the constructor form `Account("Ada", 100)`, which runs `init`. There is a second form called a struct literal, written like `UserDto{ id: 7, name: "Ada" }`, where you name each field directly. We will see that literal form in the enum and trait videos coming up, so keep it in mind.

## Recap (9:30)

**Say:** Let us sum up.

- A `struct` groups named fields, and `pub` makes a field readable from outside while a bare field stays private to the struct's methods.
- The constructor is `init`, no `fn`, and it assigns every field through `self`.
- Instance methods take `self: T` as their first parameter and can touch private fields.
- Static methods drop `self` and are called on the type, which is handy for factories.
- You build a value either with the constructor `T(args)` or a struct literal `T{ x: 1 }`, and ARC frees it all automatically.

## Outro (10:00)

**Say:** Next up we look at enums, Nova's tagged unions, where a value is exactly one of a fixed set of variants and can even carry a payload. If this helped, a like and subscribe keeps these coming. See you in the next one.
