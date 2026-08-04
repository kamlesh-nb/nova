# Video 13: Ownership & memory

- Chapter: [13-ownership.md](../13-ownership.md)
- Estimated length: ~10 minutes
- You will need: the `nova` compiler installed, a terminal, and the guide's `examples/` folder open

## Hook (0:00)

**Say:** In this video we will look at how Nova manages memory. The headline is simple: there is no garbage collector, and you never write a `free` call yourself. By the end you will understand the four rules that govern who owns what, and you will watch a program build a struct that owns a list of strings, hand it back from a function, use it, and clean itself up, all with zero manual management.

## What we will cover (0:25)

- Why Nova uses deterministic ARC instead of a garbage collector
- The four ownership rules: primitives, heap objects, borrowed arguments, and aggregates
- A worked example that owns, transfers, and drops heap data
- Why the cleanup is predictable and safe

## Segment: what ARC gives you (0:50)

**Say:** Nova has no garbage collector and no manual `free`. Memory is managed by deterministic ARC, which stands for automatic reference counting. Every heap object carries a reference count, and it is freed the instant its last owner goes away. The important word there is deterministic. Cleanup happens at a known point in the program, not whenever a collector decides to run, and you never write the free yourself. So you get the memory safety of a managed language with the determinism of manual management, and none of the ceremony of either.

## Segment: the four rules (2:00)

**Say:** The whole model comes down to four rules, so let us go through them one at a time.

**Say:** Rule one: primitives are value types. `int`, `long`, `float`, and `bool` are copied, never owned. There is no heap object to track, so there is nothing to free.

**Say:** Rule two: everything else is a heap object. That means `string`, `decimal`, `List`, `Map`, `Set`, structs, tuples, and closures. Each is freed exactly once, when its last owner is dropped.

**Say:** Rule three: function arguments are borrowed. The callee may read an argument freely. If it wants to keep one, by storing it in an aggregate or returning it, it retains its own reference. The caller still owns the value after the call returns.

**Say:** Rule four: aggregates own their contents. A `List<string>` owns its strings, and a struct owns its fields. When the aggregate drops, everything it owns drops with it, recursively.

## Segment: a struct that owns heap data (3:30)

**Say:** Let us make this concrete. Here is a `Team` struct. It owns two heap things: a `string` name, and a `List<string>` of members. Watch how ownership is set up in the constructor and the `add` method.

**On screen:**
```nova
// examples/19_ownership.nova
// Nova manages memory with deterministic ARC (automatic reference counting):
// no garbage collector, no manual free. You never call `free`.
//
//   * Primitives (int, long, float, bool) are VALUE types: copied, never owned.
//   * string / decimal / List / Map / Set / structs / tuples / closures are
//     heap objects. Each is freed EXACTLY ONCE, when its last owner goes away.
//   * Function arguments are BORROWED: the callee may read them and, if it keeps
//     one (stores it, returns it), it retains its own reference.
//   * Aggregates OWN what you put in them: a List<string> owns its strings; a
//     struct owns its fields. Drop the aggregate and everything it owns is freed.
import collections.list;

// A struct that owns heap data: a string and a List<string>.
struct Team {
    pub name: string,
    pub members: List<string>,
    init(n: string) {
        self.name = n;
        self.members = list.List<string>();   // the Team now owns this List
    }
    pub fn add(self: Team, who: string): void {
        self.members.push(who);   // the List takes ownership of the pushed string
    }
    pub fn roster(self: Team): string {
        let out = self.name + ": ";
        let i = 0;
        while (i < self.members.size()) {
            out = out + self.members.at(i);
            if (i < self.members.size() - 1) { out = out + ", "; }
            i = i + 1;
        }
        return out;   // a fresh heap string; ownership moves to the caller
    }
}
```

**Say:** In the constructor, `self.members = list.List<string>()` creates a fresh list, and from that moment the `Team` owns it. In `add`, when we push a string into the list, the list takes ownership of that string. And `roster` builds a brand new heap string and returns it, so ownership of that string moves out to whoever called `roster`. Notice there is no bookkeeping in this code, no reference counts, no destructors. It just reads like normal code.

## Segment: borrowing and transferring (5:30)

**Say:** Now the two free functions. `greet` shows borrowing, and `buildTeam` shows ownership transfer.

**On screen:**
```nova
// `who` is BORROWED: this function reads it and returns a NEW string built from
// it. It never frees `who`; the caller still owns it after the call.
fn greet(who: string): string {
    return `hello, ${who}`;
}

// Build and return a heap object. Ownership of the Team transfers to the caller.
fn buildTeam(): Team {
    let t = Team("Platform");
    t.add("Ada");
    t.add("Grace");
    t.add("Alan");
    return t;
}
```

**Say:** In `greet`, the argument `who` is borrowed. The function reads it to build a new string and returns that, but it never frees `who`. The caller still owns `who` afterwards. In `buildTeam`, we create a `Team`, add three members, and return it. The `Team`, together with the list and strings it owns, transfers out to the caller. The function does not clean it up on the way out, because it is handing ownership over.

## Segment: putting it together in main (7:00)

**Say:** Finally, `main` ties the two ideas together. It borrows a name, then takes ownership of a team, and at the end everything drops on its own.

**On screen:**
```nova
fn main(): void {
    // `name` is a heap string owned by this scope.
    let name = "Ada";
    // Borrowed by greet; still valid here afterwards.
    console.log(greet(name));
    console.log(`still own name: ${name}`);

    // The Team (and the List + strings it owns) is created in buildTeam and
    // handed back. `team` is now the single owner.
    let team = buildTeam();
    console.log(team.roster());
    console.log(`size = ${team.members.size()}`);

    // No free() anywhere. When main returns, `team` drops: its List drops, every
    // string in it drops, and the name string drops, each exactly once.
}
```

**Say:** We create `name`, a heap string owned by this scope. We pass it to `greet`, which borrows it, and the very next line proves we still own it. Then `team` becomes the single owner of the `Team` that `buildTeam` handed back. We print the roster and the size. And that is it. There is no `free` anywhere. When `main` returns, `team` drops, which drops its list, which drops every string inside it, and the name string drops too, each exactly once.

**Run it:**
```
nova examples/19_ownership.nova -o out && ./out
```

```
hello, Ada
still own name: Ada
Platform: Ada, Grace, Alan
size = 3
```

**Say:** Exactly what we predicted from reading the code. The greeting borrows the name, we still own it, the roster lists all three members, and the size is 3.

## Recap (9:00)

**Say:** Quick recap of the four rules:

- Primitives are value types: copied, never owned, nothing to free.
- `string`, `List`, `Map`, `Set`, structs, tuples, and closures are heap objects, each freed exactly once when the last owner drops.
- Arguments are borrowed: the caller keeps ownership, and the callee retains only what it stores or returns.
- Aggregates own their contents, so dropping the aggregate drops everything inside it.
- No GC and no manual `free`: cleanup is deterministic and automatic.

## Outro (9:40)

**Say:** So you wrote no `free`, no destructor, and no reference-count bookkeeping, yet every string and list was released exactly once, at a point you can predict from the code. Next up we will look at modules and visibility, how Nova organises code across files. If this helped, a like or subscribe keeps the series going.
