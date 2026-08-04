# 10. Optionals

An **optional** is written `T | undefined`. The value `undefined` means **absence**: there is no value
here, *not* an error (errors are Chapter 11). Two standard-library staples return optionals:
`List<T>.get(i)` and `Map<K,V>.get(k)` both return `T | undefined`, because the index or key might not be
there.

You get at the value four ways:

- **Coalesce** with `??`: `xs.get(i) ?? default` yields the value if present, otherwise the default.
- **Narrow** with `if (x != undefined) { ... }`: inside the branch, `x` is a plain `T`.
- **Chain** with `?.`: `user?.name` reads `.name` only if `user` is present; if it is `undefined`, the
  whole expression is `undefined`.
- **Return absence** yourself with `return undefined` from a function typed `T | undefined`.

Member access *through* an optional is memory-safe: it is guarded at runtime, never a silent null-deref.

```nova
// examples/16_optionals.nova
// An optional is `T | undefined`, where `undefined` means ABSENCE (not an
// error). `List<T>.get(i)` and `Map<K,V>.get(k)` return `T | undefined`.
// Narrow with `if (x != undefined) { use(x) }`; coalesce a default with `??`;
// reach through a possibly-absent value with `?.`.
import collections.list;
import collections.map;
import string;

struct User {
    pub name: string,
    pub age: int,
    init(n: string, a: int) { self.name = n; self.age = a; }
}

// A function whose result may be absent: the return type says so.
fn findAdmin(names: List<string>): string | undefined {
    let i = 0;
    while (i < names.size()) {
        let n = names.get(i) ?? "";
        if (n == "root") { return n; }
        i = i + 1;
    }
    return undefined;   // no admin found: absence, not failure
}

fn main(): void {
    // ---- List.get returns T | undefined; unwrap with ?? ----
    let fruits = list.List<string>();
    fruits.push("apple");
    fruits.push("banana");
    console.log(`fruits[0] = ${fruits.get(0) ?? "?"}`);
    console.log(`fruits[9] = ${fruits.get(9) ?? "?"}`);   // out of range -> undefined

    // ---- Map.get returns V | undefined ----
    let ages = map.Map<string, int>(16, string.hash);
    ages.set("ada", 36);
    console.log(`ada     = ${ages.get("ada") ?? -1}`);
    console.log(`babbage = ${ages.get("babbage") ?? -1}`);   // missing key -> undefined

    // ---- Narrowing: inside the guard the value is a plain T ----
    let names = list.List<string>();
    names.push("guest");
    names.push("root");
    let admin = findAdmin(names);
    if (admin != undefined) {
        console.log(`admin found: ${admin}`);
    } else {
        console.log("no admin");
    }

    let noAdmin = findAdmin(fruits);
    if (noAdmin != undefined) {
        console.log(`admin found: ${noAdmin}`);
    } else {
        console.log("no admin");
    }

    // ---- Optional chaining `?.`: reach a field only if present ----
    let users = map.Map<string, User>(16, string.hash);
    users.set("ada", User("Ada", 36));
    // present: `?.` reads the field; absent: the whole expression is undefined,
    // so `??` supplies the fallback.
    console.log(`ada  name = ${users.get("ada")?.name ?? "?"}`);
    console.log(`grace name = ${users.get("grace")?.name ?? "?"}`);
}
```

Output:

```
fruits[0] = apple
fruits[9] = ?
ada     = 36
babbage = -1
admin found: root
no admin
ada  name = Ada
grace name = ?
```

| Form | Meaning |
|------|---------|
| `T \| undefined` | An optional: a `T` or the absence value `undefined` |
| `xs.get(i)` / `m.get(k)` | Returns `T \| undefined` (out of range / missing key gives `undefined`) |
| `x ?? default` | The value if present, else `default` |
| `if (x != undefined) { ... }` | Narrows `x` to `T` inside the branch |
| `x?.field` | `field` if `x` is present, else `undefined` (chains) |
| `return undefined` | Produce absence from a `T \| undefined` function |

`.get(i)` returns an optional; its sibling `.at(i)` returns a present `T` (used when you have already
bounded the index). Reading a field of an *absent* optional is caught: as a compile error where the
checker can see it, and otherwise as a located runtime abort, so an optional never becomes a silent
null-dereference.

Next: [Error handling](11-error-handling.md)
