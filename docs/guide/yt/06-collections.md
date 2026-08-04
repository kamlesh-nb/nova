# Video 06: Collections

- Chapter: [06-collections.md](../06-collections.md)
- Estimated length: ~11 minutes
- You will need: the `nova` compiler installed, a terminal, and the guide's `examples/` folder open

## Hook (0:00)

**Say:** Nova ships three generic collections in its standard library: `List`, `Map`, and `Set`. In this video we will use all three. You will learn how to grow a list and run pipelines over it, how a map stores key-value pairs with a hash function, and how a set keeps only unique elements. There is one recurring theme to watch for: accessors hand you an optional, and we will unwrap it as we go.

## What we will cover (0:30)

- `List<T>`: push, size, get, set, iterate, and map/filter/reduce
- The optional return theme and the `??` operator
- `Map<K, V>`: construction with a hash function, get, has, delete, iterate
- `Set<T>`: unique elements, add, has, remove

## Segment: the optional theme (1:00)

**Say:** Before the code, one idea that runs through this whole chapter. Element and value accessors return an optional, written `T` or `undefined`. That makes an out-of-range or missing lookup safe instead of a crash. Optionals get their own chapter later, but until then we unwrap them with the nullish-coalescing operator, `?? default`. It yields the value if it is present, and the default if it is `undefined`. Keep an eye out for that double question mark.

## Segment: List (1:45)

**Say:** A `List<T>` is a growable, indexed vector. You import it from its module under `collections`. Let us build one of strings, poke at it, and then run a transform pipeline.

**On screen:**
```nova
// examples/10_collections.nova
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

**Say:** We create the list, push three fruits, and check the size. Then `get(1)` gives us "banana", but watch `get(9)`: index 9 is out of range, so it returns `undefined`, and our `?? "?"` turns that into a question mark instead of blowing up. `set` overwrites in place, turning the first fruit into "avocado". We iterate with `for-in`. Then the pipeline: fill a list with 1 to 5, `map` each to its square, `filter` to keep squares above 4, and `reduce` to total them.

**Run it:**
```
nova examples/10_collections.nova -o out && ./out
```

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

**Say:** The squares of 1 to 5 are 1, 4, 9, 16, 25. Filtering for greater than 4 keeps 9, 16, and 25, so that is three elements totalling 50. Notice `fruits[9]` printed a question mark, exactly the safe-lookup behaviour we talked about.

## Segment: Map (5:00)

**Say:** A `Map<K, V>` is a hash map. Its constructor is a little different from what you may expect: it takes an initial capacity and a hash function for the key type. For string keys, that hash function is `string.hash`, so you import `string` too. Let us store some ages.

**On screen:**
```nova
// examples/11_maps.nova
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

**Say:** We build the map with capacity 16 and `string.hash`, then set three names to ages. `get("alice")` returns 30, but `get("dave")` returns `undefined` because Dave is absent, and our `?? -1` gives us minus 1 as the sentinel. `has` tests membership, and `delete_key` removes an entry, so after deleting bob, `has bob` becomes false. Then look at the iteration: `for ((name, age) in ages)` walks entries as key-value pairs, and this is the map form of the loop I promised in the control-flow video. Finally, `keys()` and `values()` return Lists.

**Run it:**
```
nova examples/11_maps.nova -o out && ./out
```

```
size = 3
alice = 30
dave  = -1
has bob = true
has bob = false (after delete)
total of remaining ages = 71
key count = 2
```

**Say:** After we delete bob, the remaining ages are alice at 30 and carol at 41, which sum to 71, and the key count is 2. One thing worth knowing: the hash function is per key type. Use `string.hash` for string keys, and for `int` keys the `set` module exports `i32Hash`, which we will use in a moment.

## Segment: Set (8:30)

**Say:** Last one: `Set<T>` stores unique elements. Adding a value that is already present is simply a no-op. Under the hood a set is a thin wrapper over a `Map` of `T` to `bool`, so it takes the same capacity and hash-function pair. There is one Beta quirk in this standalone example, and I will point it out.

**On screen:**
```nova
// examples/12_sets.nova
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

**Say:** The two `prime` functions at the top look odd, so let me explain them. Because a set is built on `Map<T, bool>`, a standalone program has to reference that map type directly so the compiler instantiates it. That is what the prime calls do, and they exist only for that reason. It is a dead-code elimination gap that is being tracked, and normal Map usage needs no such priming. Now the real content: we add "get", "post", and "get" again to a set of strings. The second "get" is a duplicate, so it is ignored, and the size is 2. We test membership, remove "post", and then build a set of ints using `set.i32Hash` for the integer keys.

**Run it:**
```
nova examples/12_sets.nova -o out && ./out
```

```
size = 2
has post = true
has put  = false
has post = false (after remove)
unique ids = 3
```

**Say:** The string set has size 2 because the duplicate "get" was ignored. And for the ints we added 1, 2, 2, 3, but the two is only kept once, so we have three unique ids. That is exactly what a set is for.

## Recap (10:15)

**Say:** Let us recap the three collections:

- `List<T>` is a growable vector: `push`, `size`, `get`, `set`, `for-in`, and the map/filter/reduce pipeline.
- Accessors return an optional `T | undefined`, which you unwrap with `?? default`.
- `Map<K, V>` takes a capacity and a hash function, and supports `get`, `has`, `delete_key`, and `for ((k, v) in m)`.
- `Set<T>` keeps unique elements, built on `Map<T, bool>`, with the same construction pattern.
- Pick the right hash function per key type: `string.hash` for strings, `set.i32Hash` for ints.

## Outro (10:50)

**Say:** Next we move on to structs, where you design your own types instead of just using the built-in ones. If this video helped, a like or subscribe keeps the guide going. See you in the next one.
