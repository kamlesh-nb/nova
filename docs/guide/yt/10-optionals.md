# Video 10: Optionals

- Chapter: [10-optionals.md](../10-optionals.md)
- Estimated length: ~10 minutes
- You will need: the `nova` compiler on your PATH, and the guide example `examples/16_optionals.nova`

## Hook (0:00)

**Say:** Every language has to answer one awkward question: what do you do when a value simply is not there? A list index past the end, a map key that was never set. In a lot of languages the answer is null, and null is where the crashes live. In Nova the answer is an optional, and by the end of this video you will know all four ways to pull a value out of one safely, with the compiler watching your back the whole time.

## What we will cover (0:20)

- What an optional is: `T | undefined`, and why `undefined` means absence, not error
- Coalescing a default with `??`
- Narrowing with `if (x != undefined)`
- Returning absence yourself
- Optional chaining with `?.`
- Running the full example and reading the output

## Segment: What an optional is (0:45)

**Say:** An optional is written `T | undefined`. That vertical bar is a union: the value is either a real `T`, or it is the special value `undefined`, which means there is nothing here. Notice this is absence, not an error. Errors are their own topic, and they get their own chapter. Two standard-library workhorses hand you optionals all the time: `List.get(i)` and `Map.get(k)`, because the index or the key might just not be there.

**On screen:**
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
```

**Say:** We import the list and map collections, plus string. The `User` struct is here for the last segment, when we chain through an optional to read a field. Hold that thought.

## Segment: Coalesce with ?? (2:00)

**Say:** The quickest way to use an optional is to supply a fallback with the `??` operator. You read it as: if there is a value, give me the value, otherwise give me this default instead. Here we push two fruits into a list, then read index 0, which exists, and index 9, which does not.

**On screen:**
```nova
    // ---- List.get returns T | undefined; unwrap with ?? ----
    let fruits = list.List<string>();
    fruits.push("apple");
    fruits.push("banana");
    console.log(`fruits[0] = ${fruits.get(0) ?? "?"}`);
    console.log(`fruits[9] = ${fruits.get(9) ?? "?"}`);   // out of range -> undefined
```

**Say:** Index 0 gives back "apple". Index 9 is past the end, so `get` returns `undefined`, and the `?? "?"` steps in with a question mark. The same pattern works for maps. We look up "ada", which we set, and "babbage", which we never did, coalescing to minus one.

**On screen:**
```nova
    // ---- Map.get returns V | undefined ----
    let ages = map.Map<string, int>(16, string.hash);
    ages.set("ada", 36);
    console.log(`ada     = ${ages.get("ada") ?? -1}`);
    console.log(`babbage = ${ages.get("babbage") ?? -1}`);   // missing key -> undefined
```

## Segment: Narrowing with if (3:30)

**Say:** Sometimes a default is not what you want. You want to do real work only when the value is present. That is narrowing. You test `if (x != undefined)`, and inside that branch the compiler knows `x` is a plain `T`, no longer an optional. Here is a helper that scans a list for the name "root" and returns it, or returns absence if it never finds it.

**On screen:**
```nova
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
```

**Say:** Look at the return type: `string | undefined`. The function is honest about the fact that it might not find anything, and the last line, `return undefined`, is how you produce absence yourself from such a function. No admin found is not a failure, it is just absence.

**On screen:**
```nova
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
```

**Say:** The first call searches a list that contains "root", so we take the present branch and print the name. The second call searches the fruits list, which has no "root", so `findAdmin` returns `undefined` and we print "no admin". Inside that `if (admin != undefined)` branch, `admin` is a plain string, so interpolating it is fine.

## Segment: Optional chaining with ?. (6:00)

**Say:** The last tool is optional chaining, the `?.` operator. It lets you reach a field only if the thing on the left is present. If the left side is `undefined`, the whole expression short-circuits to `undefined`, and it never touches the field. That is what makes reaching through an absent value memory-safe rather than a null-dereference.

**On screen:**
```nova
    // ---- Optional chaining `?.`: reach a field only if present ----
    let users = map.Map<string, User>(16, string.hash);
    users.set("ada", User("Ada", 36));
    // present: `?.` reads the field; absent: the whole expression is undefined,
    // so `??` supplies the fallback.
    console.log(`ada  name = ${users.get("ada")?.name ?? "?"}`);
    console.log(`grace name = ${users.get("grace")?.name ?? "?"}`);
```

**Say:** For "ada", the map lookup succeeds, `?.name` reads the name field, and we print "Ada". For "grace", the lookup returns `undefined`, so `?.name` yields `undefined` without ever dereferencing anything, and the trailing `?? "?"` gives us the question mark. Chaining and coalescing pair up naturally: chain to reach in, coalesce to land on a default.

## Segment: Run it (7:45)

**Say:** Let us compile and run the whole thing and check every line.

**Run it:** `nova examples/16_optionals.nova -o out && ./out`

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

**Say:** Every line matches what we predicted. Present values pass through, absent ones fall to their defaults, the narrowed branches print the right message, and the chain reaches the name only when the user is there.

## Segment: get versus at (8:45)

**Say:** One more thing worth knowing. `.get(i)` returns an optional, because the index might be out of range. Its sibling `.at(i)` returns a present `T` directly, and you use that when you have already bounded the index yourself, for example inside a `while (i < size())` loop. And if you ever do read a field of an absent optional, Nova catches it: as a compile error where the checker can see it, otherwise as a located runtime abort. An optional never silently becomes a null-dereference.

## Recap (9:15)

**Say:** Quick recap:

- An optional is `T | undefined`, and `undefined` means absence, not an error.
- `x ?? default` gives the value if present, otherwise the default.
- `if (x != undefined)` narrows `x` to a plain `T` inside the branch.
- `return undefined` produces absence from a `T | undefined` function.
- `x?.field` reaches the field only when `x` is present, and chains safely otherwise.

## Outro (9:45)

**Say:** Absence is handled, so next we tackle the other side of the coin: actual failure. In the next video we look at error handling, where a function that can fail returns `T | E` and the error carries its reason. If this helped, a like and a subscribe keep these coming.
