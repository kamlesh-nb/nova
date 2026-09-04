# 13. Ownership & memory

Nova has **no garbage collector and no manual `free`**. Memory is managed by deterministic **ARC**
(automatic reference counting): every heap object carries a reference count, and it is freed the instant
its last owner goes away. Cleanup is predictable: it happens at a known point in the program, not
whenever a collector decides to run, and you never write a `free` call yourself.

The model in four rules:

- **Value types are copied, not tracked.** `int`, `long`, `float`, `bool`, a `struct`, and tuples are
  copied on assignment; there is no shared object to reference-count. A value type can still OWN heap data
  (a `struct` with a `List` field), and copying it copies that ownership.
- **Reference types are the heap objects ARC tracks:** `string`, `decimal`, `List`, `Map`, `Set`,
  closures, and any `class`. Each is freed **exactly once**, when its last owner is dropped.
- **Function arguments are borrowed.** The callee may read an argument freely; if it wants to *keep* one
  (store it in an aggregate, or return it), it retains its own reference. The caller still owns the value
  after the call returns.
- **Aggregates own their contents.** A `List<string>` owns its strings; a struct owns its fields. When the
  aggregate drops, everything it owns drops with it, recursively.

The example below builds a struct that owns a `List<string>`, returns it from a function (ownership
transfers to the caller), uses it, and lets it drop at the end of `main`, all memory-safe, with zero
manual management.

```nova
// examples/19_ownership.nova
// Nova manages memory with deterministic ARC (automatic reference counting):
// no garbage collector, no manual free. You never call `free`.
//
//   * Value types (int, long, float, bool, struct, tuple) are copied, not tracked.
//   * string / decimal / List / Map / Set / closures / class are reference types:
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

Output:

```
hello, Ada
still own name: Ada
Platform: Ada, Grace, Alan
size = 3
```

| Rule | Consequence |
|------|-------------|
| Value types (primitives, `struct`, tuples) | Copied on assignment; nothing shared to free |
| `string`/`decimal`/`List`/`Map`/`Set`/closures/`class` are reference types | Freed exactly once, when the last owner drops |
| Arguments are borrowed | Caller keeps ownership; callee retains only what it stores/returns |
| Aggregates own their contents | Dropping the aggregate drops everything inside it |
| No GC, no manual `free` | Cleanup is deterministic and automatic |

You wrote no `free`, no destructor, and no reference-count bookkeeping, yet every string and list here is
released exactly once, at a point you can predict from the code. That is the whole point of ARC: the
memory safety of a managed language with the determinism of manual management, and none of the ceremony of
either.

One honest limit to know: reference counting does not reclaim a **cycle** of strong references (A owns B
and B owns A), and Nova has no `weak` reference to break one for you, so such a cycle leaks. Keep
ownership a one-way tree and, where a child must refer back to its parent, hold it by an id or index
rather than a second strong reference. The mechanism, and why this is the one case ARC cannot handle, is
in [Chapter 21](21-architecture.md#reference-cycles).

Next: [Modules & visibility](14-modules.md)
