# 9. Traits

A `trait` is an interface: a set of method signatures with no bodies. A struct opts in with
`impl Trait` and supplies the methods. A value referred to through its trait type is a **trait object**:
calling a method on it dispatches **dynamically** (through a vtable) to the concrete type's
implementation. This is how Kyte does polymorphism.

Three moves round out the picture:

- A **factory** function can return a trait type (`fn make(): Speaker`), hiding the concrete type from
  the caller.
- A trait object can be **downcast** back to a concrete type with `as` (`s as Dog`).
- Traits may be **generic** (`trait Handler<Q, R>`), with the type parameters appearing in the method
  signatures; each `impl` fills in concrete type arguments.

```kyte
// examples/15_traits.ky
// A trait is an interface: a set of method signatures. A struct declares
// `impl Trait` and provides the methods; calls through a trait-typed binding
// dispatch dynamically (via a vtable). A trait value can be downcast back to a
// concrete type with `as`. Traits may also be generic over type parameters.

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

// A factory returning a trait object: the caller sees only `Speaker`.
fn make(kind: string): Speaker {
    if (kind == "dog") { return Dog{ name: "Rex" }; }
    return Cat{ name: "Milo" };
}

// Dispatch through a trait-typed parameter.
fn announce(s: Speaker): void {
    console.log(s.speak());
}

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

fn main(): void {
    // Dynamic dispatch: same call site, different runtime type.
    announce(Dog{ name: "Rex" });
    announce(Cat{ name: "Milo" });

    // Factory returns a trait object.
    let s = make("dog");
    console.log(`factory: ${s.speak()}`);

    // Downcast a trait value back to its concrete type with `as`.
    let d = s as Dog;
    console.log(`downcast name = ${d.name}`);

    // Generic trait, two instantiations.
    let h = GetUserHandler{};
    let dto = h.handle(GetUser{ id: 7 });
    console.log(`handler -> id=${dto.id}, name=${dto.name}`);

    let dbl = Doubler{};
    console.log(`doubler(21) = ${dbl.handle(21)}`);
}
```

Output:

```
Rex says woof
Milo says meow
factory: Rex says woof
downcast name = Rex
handler -> id=7, name=Ada
doubler(21) = 42
```

| Concept | Form |
|---------|------|
| Declare a trait | `trait Speaker { fn speak(self: Speaker): string; }` |
| Implement it | `struct Dog impl Speaker { pub fn speak(self: Dog): string { ... } }` |
| Trait-typed binding / param | `let s: Speaker = Dog{...}` / `fn announce(s: Speaker)` |
| Factory returning a trait | `fn make(): Speaker { return Dog{...}; }` |
| Downcast to concrete | `let d = s as Dog;` |
| Generic trait | `trait Handler<Q, R> { fn handle(self, req: Q): R; }` |

Dispatch is by vtable, so `announce` never learns whether it holds a `Dog` or a `Cat`. Generic traits
are checked by substituting the trait's type parameters (`Q`, `R`) with the impl's arguments; a wrong
concrete type is a compile error, while dispatch itself is type-erased, so one vtable slot serves every
instantiation. The generic-trait pattern here is the foundation for Kyte's typed request/handler
(mediator) routing.

Next: [Optionals](10-optionals.md)
