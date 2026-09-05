# 6. Collections

Kyte ships three generic collections in the standard library: `List<T>`, `Map<K, V>`, and `Set<T>`.
They are monomorphized like any other generic: a `List<int>` and a `List<string>` are distinct
types. Import each from its module under `collections`.

A recurring theme below: **element/value accessors return an optional**, `T | undefined`. Optionals
get their own chapter ([chapter 10](10-optionals.md)); until then we unwrap them with the
nullish-coalescing operator `?? default`, which yields the value if present and `default` if it is
`undefined`.

## `List<T>`

A `List<T>` is a growable, indexed vector. `get(i)` returns `T | undefined` (so an out-of-range index
is safe), while `map` / `filter` / `reduce` take the closures from [chapter 5](05-functions-and-closures.md).

```kyte
// examples/10_collections.ky
import collections.list;

fn main(): void {
    // A growable, typed vector.
    let fruits = list.List<string>();
    fruits.push("apple");
    fruits.push("banana");
    fruits.push("cherry");
    console.log(`size = ${fruits.size()}`);

    // get(i) returns an OPTIONAL (T | undefined). Unwrap with ?? (chapter 10).
    console.log(`fruits[1] = ${fruits.get(1) ?? "?"}`);
    console.log(`fruits[9] = ${fruits.get(9) ?? "?"}`);   // out of range -> undefined

    // set(i, v) overwrites in place.
    fruits.set(0, "avocado");
    console.log(`fruits[0] = ${fruits.get(0) ?? "?"}`);

    // Iterate with for-in.
    for (f in fruits) { console.log(`fruit: ${f}`); }

    // Transform pipelines with map / filter / reduce.
    let nums = list.List<int>();
    for (i in 1..=5) { nums.push(i); }

    let squares = nums.map((n) => n * n);
    let big = squares.filter((n) => n > 4);
    let total = big.reduce(0, (acc, n) => acc + n);
    console.log(`squares>4 count = ${big.size()}, total = ${total}`);
}
```

Output:

```
size = 3
fruits[1] = banana
fruits[9] = ?
fruits[0] = avocado
fruit: avocado
fruit: banana
fruit: cherry
squares>4 count = 3, total = 50
```

| Method | Result |
|--------|--------|
| `push(v)` | append an element |
| `size()` | element count |
| `get(i)` | element at `i` as `T \| undefined` |
| `set(i, v)` | overwrite element at `i` |
| `map(fn)` / `filter(pred)` / `reduce(acc, fn)` | transform / select / fold |

## `Map<K, V>`

A `Map<K, V>` is a hash map. Its constructor takes an initial capacity **and a hash function for the
key type** (`Map<string, int>(16, string.hash)`). `get(k)` returns `V | undefined`; `has` tests
membership; `delete_key` removes; and `for ((k, v) in m)` iterates entries.

```kyte
// examples/11_maps.ky
import collections.map;
import string;

fn main(): void {
    // A Map needs a capacity hint and a hash function for its key type.
    // For string keys, use string.hash.
    let ages = map.Map<string, int>(16, string.hash);
    ages.set("alice", 30);
    ages.set("bob", 25);
    ages.set("carol", 41);
    console.log(`size = ${ages.size()}`);

    // get(k) returns an OPTIONAL (V | undefined). Unwrap with ?? (chapter 10).
    console.log(`alice = ${ages.get("alice") ?? -1}`);
    console.log(`dave  = ${ages.get("dave") ?? -1}`);   // absent -> undefined

    // has / delete_key.
    console.log(`has bob = ${ages.has("bob")}`);
    ages.delete_key("bob");
    console.log(`has bob = ${ages.has("bob")} (after delete)`);

    // Iterate entries as (key, value) pairs.
    let sum = 0;
    for ((name, age) in ages) { sum = sum + age; }
    console.log(`total of remaining ages = ${sum}`);

    // keys() and values() return Lists.
    console.log(`key count = ${ages.keys().size()}`);
}
```

Output:

```
size = 3
alice = 30
dave  = -1
has bob = true
has bob = false (after delete)
total of remaining ages = 71
key count = 2
```

| Method | Result |
|--------|--------|
| `Map<K, V>(cap, hashFn)` | construct, e.g. `Map<string,int>(16, string.hash)` |
| `set(k, v)` | insert or overwrite |
| `get(k)` | value as `V \| undefined` |
| `has(k)` | membership test |
| `delete_key(k)` | remove a key |
| `size()` | entry count |
| `keys()` / `values()` | a `List<K>` / `List<V>` |
| `for ((k, v) in m)` | iterate entries (order is unspecified) |

The hash function is per key type: `string.hash` for `string` keys (import `string`), and for `int`
keys the `set` module exports `i32Hash`.

## `Set<T>`

A `Set<T>` stores **unique** elements; adding a value that is already present is a no-op. Like `Map`
it takes a capacity hint and a hash function (`Set<T>` is a thin wrapper over `Map<T, bool>`).

```kyte
// examples/12_sets.ky
import collections.set;
import collections.map;
import string;

// A Set<T> stores unique elements. Internally it is a thin wrapper over
// Map<T, bool>, so it takes the same (capacity, hashFn) pair.
//
// Beta note: because Set is built on Map<T, bool>, a standalone program must
// also reference that Map<T, bool> directly so the compiler instantiates it;
// the two `prime*` calls below exist only for that. This is a dead-code
// elimination gap being tracked; normal Map usage needs no such priming.
fn primeString(): void { let m = map.Map<string, bool>(1, string.hash); m.set("_", true); }
fn primeInt(): void { let m = map.Map<int, bool>(1, set.i32Hash); m.set(0, true); }

fn main(): void {
    primeString();
    primeInt();

    // A Set of strings. For string keys, use string.hash.
    let methods = set.Set<string>(16, string.hash);
    methods.add("get");
    methods.add("post");
    methods.add("get");          // duplicate -> ignored
    console.log(`size = ${methods.size()}`);

    // Membership test.
    console.log(`has post = ${methods.has("post")}`);
    console.log(`has put  = ${methods.has("put")}`);

    // Remove an element.
    methods.remove("post");
    console.log(`has post = ${methods.has("post")} (after remove)`);

    // A Set of ints. For int keys, use set.i32Hash.
    let ids = set.Set<int>(16, set.i32Hash);
    ids.add(1); ids.add(2); ids.add(2); ids.add(3);
    console.log(`unique ids = ${ids.size()}`);
}
```

Output:

```
size = 2
has post = true
has put  = false
has post = false (after remove)
unique ids = 3
```

| Method | Result |
|--------|--------|
| `Set<T>(cap, hashFn)` | construct: `string.hash` for strings, `set.i32Hash` for ints |
| `add(v)` | insert (duplicates ignored) |
| `has(v)` | membership test |
| `remove(v)` | delete an element |
| `size()` | element count |

Next: [Structs](07-structs.md)
