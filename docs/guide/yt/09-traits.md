# Video 09: Traits

- Chapter: [09-traits.md](../09-traits.md)
- Estimated length: ~11 minutes
- You will need: Nova installed and on your PATH, a terminal, and the files `examples/15_traits.nova` and `examples/geometry.nova` from the guide.

## Hook (0:00)

**Say:** In this video we get to polymorphism, the ability to write one piece of code that works over many concrete types. In Nova the tool for that is the trait. By the end you will be able to declare a trait, implement it on several structs, pass values around by their trait type with dynamic dispatch, return a trait from a factory, downcast back to a concrete type, and even write a generic trait. Let us get into it.

## What we will cover (0:20)

- What a trait is and how a struct implements one
- Dynamic dispatch through a trait-typed parameter
- A factory that returns a trait object
- Downcasting back to a concrete type with `as`
- Generic traits with two instantiations
- A quick look at running tests with a small geometry module

## Segment: Declaring and implementing a trait (0:50)

**Say:** A trait is an interface. It is a set of method signatures with no bodies, just the shapes. A struct opts in by writing `impl Trait` and supplying the actual methods. Here is a `Speaker` trait, and two structs that implement it.

**On screen:**
```nova
trait Speaker {
    fn speak(self: Speaker): string;
}

struct Dog impl Speaker {
    pub name: string,
    pub fn speak(self: Dog): string { return `${self.name} says woof`; }
}

struct Cat impl Speaker {
    pub name: string,
    pub fn speak(self: Cat): string { return `${self.name} says meow`; }
}
```

**Say:** The trait just says: anything that is a `Speaker` has a `speak` method that returns a string. Then `Dog` and `Cat` each declare `impl Speaker` and provide their own `speak`. A Dog says woof, a Cat says meow. Same signature, different behaviour.

## Segment: Dynamic dispatch (2:30)

**Say:** Now the interesting part. When you hold a value through its trait type, calling a method dispatches dynamically, through a vtable, to the concrete type's implementation. Here is a function that takes a `Speaker` and just calls `speak` on it.

**On screen:**
```nova
// Dispatch through a trait-typed parameter.
fn announce(s: Speaker): void {
    console.log(s.speak());
}
```

**Say:** `announce` never learns whether it is holding a Dog or a Cat. It just calls `speak`, and at runtime the right implementation runs. That is polymorphism: one call site, many concrete types.

## Segment: A factory that returns a trait (3:45)

**Say:** A factory function can return a trait type, which hides the concrete type from the caller. The caller asks for a Speaker and gets one, without knowing or caring which kind. Notice we build the structs here with the struct literal form, the one we mentioned back in the structs video.

**On screen:**
```nova
// A factory returning a trait object: the caller sees only `Speaker`.
fn make(kind: string): Speaker {
    if (kind == "dog") { return Dog{ name: "Rex" }; }
    return Cat{ name: "Milo" };
}
```

**Say:** So `make("dog")` gives back a Dog wearing the Speaker type, and anything else gives back a Cat. To the caller it is just a Speaker. Here `Dog{ name: "Rex" }` is a struct literal: we name the field directly rather than calling a constructor.

## Segment: Generic traits (5:00)

**Say:** Traits can also be generic, with type parameters that appear in the method signatures. Each `impl` fills in concrete type arguments. This `Handler` trait is generic over a request type `Q` and a response type `R`.

**On screen:**
```nova
// ---- Generic trait: type parameters appear in the method signature ----
trait Handler<Q, R> {
    fn handle(self, req: Q): R;
}

struct GetUser { pub id: int }
struct UserDto { pub id: int, pub name: string }

// One concrete instantiation: Handler<GetUser, UserDto>.
struct GetUserHandler impl Handler<GetUser, UserDto> {
    fn handle(self, req: GetUser): UserDto {
        return UserDto{ id: req.id, name: "Ada" };
    }
}

// A different instantiation of the SAME trait: Handler<int, int>.
struct Doubler impl Handler<int, int> {
    fn handle(self, n: int): int { return n + n; }
}
```

**Say:** Look at the two implementations of the same trait. `GetUserHandler` fills in `Handler<GetUser, UserDto>`, so its `handle` takes a `GetUser` and returns a `UserDto`. `Doubler` fills in `Handler<int, int>`, so its `handle` takes an int and returns an int. Same trait, two very different instantiations, each checked by substituting `Q` and `R` with the impl's arguments. This generic-trait pattern is actually the foundation for Nova's typed request and handler routing, the mediator.

## Segment: Putting it together in main (6:45)

**Say:** Now `main` exercises all of it. First, dynamic dispatch: same `announce` call, two different runtime types.

**On screen:**
```nova
fn main(): void {
    // Dynamic dispatch: same call site, different runtime type.
    announce(Dog{ name: "Rex" });
    announce(Cat{ name: "Milo" });

    // Factory returns a trait object.
    let s = make("dog");
    console.log(`factory: ${s.speak()}`);
```

**Say:** We announce a Dog and a Cat, then ask the factory for a dog and let it speak. Next comes the downcast. A trait object can be brought back to its concrete type with `as`.

**On screen:**
```nova
    // Downcast a trait value back to its concrete type with `as`.
    let d = s as Dog;
    console.log(`downcast name = ${d.name}`);
```

**Say:** `s` is a Speaker, but we know it is really a Dog, so `s as Dog` gives us a concrete Dog and now we can read `d.name` directly. Finally the two generic handlers.

**On screen:**
```nova
    // Generic trait, two instantiations.
    let h = GetUserHandler{};
    let dto = h.handle(GetUser{ id: 7 });
    console.log(`handler -> id=${dto.id}, name=${dto.name}`);

    let dbl = Doubler{};
    console.log(`doubler(21) = ${dbl.handle(21)}`);
}
```

**Say:** We make a `GetUserHandler`, hand it a `GetUser` with id 7, and get back a `UserDto`. Then a `Doubler`, and `handle(21)` doubles it. Let us run the whole thing.

**Run it:**
```
nova examples/15_traits.nova -o out && ./out
```

```
Rex says woof
Milo says meow
factory: Rex says woof
downcast name = Rex
handler -> id=7, name=Ada
doubler(21) = 42
```

**Say:** All six lines. Rex woofs, Milo meows, the factory's dog woofs, the downcast lets us read Rex's name, the user handler returns id 7 with name Ada, and the doubler turns 21 into 42.

## Segment: How dispatch works, briefly (9:15)

**Say:** A couple of things worth knowing. Dispatch is by vtable, so `announce` genuinely never knows if it holds a Dog or a Cat. For generic traits, the checker substitutes the type parameters `Q` and `R` with the impl's arguments, and a wrong concrete type is a compile error. But dispatch itself is type-erased, so one vtable slot serves every instantiation. You get strong checking at compile time and a lean runtime.

## Segment: A small module and running tests (9:50)

**Say:** To round off, here is a tiny module called `geometry`, which pairs nicely with traits and structs. It shows a `pub struct Point` and some free functions, and it carries a `@test` so we can run it directly. Only `pub` declarations are visible to other modules.

**On screen:**
```nova
pub struct Point {
    pub x: int,
    pub y: int,
    init(x: int, y: int) {
        self.x = x;
        self.y = y;
    }
}

// Manhattan (taxicab) distance between two points.
pub fn manhattan(a: Point, b: Point): int {
    let dx = if (a.x > b.x) a.x - b.x else b.x - a.x;
    let dy = if (a.y > b.y) a.y - b.y else b.y - a.y;
    return dx + dy;
}
```

**Say:** `Point` is a public struct with public x and y and an `init`. `manhattan` computes the taxicab distance using an `if` expression to pick the positive difference on each axis. There is also a non-pub helper and a `pub perimeter`, and at the bottom a `@test` that checks the maths.

**On screen:**
```nova
@test
fn t_geometry(): void {
    let a = Point(0, 0);
    let b = Point(3, 4);
    assert.equalInt(manhattan(a, b), 7);
    assert.equalInt(perimeter(a, b), 14);
}
```

**Say:** This file has no `main`, it has a `@test`, so we run it with `nova test`, which finds and runs the test functions rather than a main program.

**Run it:**
```
nova test examples/geometry.nova
```

**Say:** If the assertions hold, the test passes cleanly. That is the everyday loop: write a small module, add a `@test`, and run `nova test` to check it.

## Recap (10:45)

**Say:** Let us wrap up.

- A `trait` is an interface, and a struct implements it with `impl Trait` plus the method bodies.
- Calling a method through a trait-typed binding dispatches dynamically via a vtable.
- A factory can return a trait type to hide the concrete type from callers.
- You can downcast a trait value back to its concrete type with `as`.
- Traits can be generic, checked by substituting the type parameters, and this is the base of Nova's mediator routing.

## Outro (11:00)

**Say:** That closes out the object-style chapters. Next in the series we look at optionals, Nova's safe way to handle a value that might be missing. If this was useful, a like and subscribe keeps the series going. See you in the next video.
