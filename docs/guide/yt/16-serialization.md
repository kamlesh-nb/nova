# Video 16: Serialization

- Chapter: [16-serialization.md](../16-serialization.md)
- Estimated length: ~11 minutes
- You will need: Nova installed, a terminal, and the guide's `examples/` folder handy.

## Hook (0:00)

**Say:** Almost every real service has to turn data into JSON and read JSON back into data. In a lot of languages that means reflection at runtime, or hand-written parsing that drifts out of sync with your types. Nova does neither. In this video you will mark one struct as `@serializable`, and watch the compiler generate the parser and the writer for you, at compile time, with no reflection at all. By the end you will be able to deserialize JSON into a struct, walk its nested fields and lists, and serialize it straight back.

## What we will cover (0:25)

- What `@serializable` actually does
- The zero-argument `init()` rule and why it matters
- Deserializing JSON with the generated `__bind`
- Nested structs and lists, handled automatically
- Serializing back with `__toJson`, and the round-trip

## Segment: What @serializable does (0:50)

**Say:** Here is the idea in one line. You put `@serializable` on a struct, and the compiler generates two free functions for that struct. The first is `<Struct>__bind`, which takes a `ValueSource` and gives you back a fully populated struct. It reads from a source, and here our source is JSON. The second is `<Struct>__toJson`, which takes a value of that struct and returns a JSON string, in field-declaration order. These two are a matched pair, so a value goes out to JSON and comes back the same.

**Say:** A `ValueSource` is just the abstract input the binder reads. For JSON you wrap a raw string with `serde.source.fromJson`. The same abstraction is what later lets a web handler bind a struct from a request, where some fields come from the route and some from the body. Same generated `__bind`, different source.

## Segment: The struct and the init() rule (2:00)

**Say:** Let us look at the example. We will build a `User` that has a nested `Address` and a list of roles. First the imports and the nested struct.

**On screen:**
```nova
// examples/23_serde.nova
import serde.source;
import list;

@serializable
struct Address {
    pub street: string,
    pub city: string,
    init() { self.street = ""; self.city = ""; }
}
```

**Say:** Notice the `init()` with no arguments. That is a hard requirement for a serializable struct. It has to set a default for every field. The reason is simple: `__bind` starts from those defaults and then overwrites whatever it finds in the source. So if a key is missing in the JSON, that field just keeps its default instead of crashing. Here `Address` defaults both strings to empty.

**Say:** Now the `User` struct, which pulls in that nested `Address` and a list.

**On screen:**
```nova
@serializable
struct User {
    pub id: long,
    pub name: string,
    pub active: bool,
    pub address: Address,      // nested @serializable struct
    pub roles: List<string>,   // List of primitives
    init() {
        self.id = 0;
        self.name = "";
        self.active = false;
        self.address = Address();
        self.roles = List<string>();
    }
}
```

**Say:** Two things to point out. `address` is itself a `@serializable` struct, and `roles` is a `List<string>`. The generated binder recurses into that nested struct and iterates over the list for you. You do not write any of that walking code yourself. And again, `init()` sets a sensible default for every single field, including a fresh `Address` and an empty list.

## Segment: Deserializing with __bind (4:15)

**Say:** Now to `main`. We start with a raw JSON string. It is written with escaped quotes because it is a normal Nova string, and it is split across a few lines with `+`.

**On screen:**
```nova
fn main(): void {
    let raw = "{\"id\":7,\"name\":\"Ada\",\"active\":true," +
              "\"address\":{\"street\":\"Main\",\"city\":\"Pune\"}," +
              "\"roles\":[\"admin\",\"dev\"]}";
```

**Say:** That JSON has an id, a name, a boolean, a nested address object, and an array of roles. Now we parse it into a `User` in a single call.

**On screen:**
```nova
    // Parse JSON into User via the compiler-generated binder.
    let u = User__bind(source.fromJson(raw));
    console.log(`id      = ${u.id}`);
    console.log(`name    = ${u.name}`);
    console.log(`active  = ${u.active}`);
    console.log(`city    = ${u.address.city}`);
    console.log(`#roles  = ${u.roles.size()}`);
```

**Say:** Read that middle line carefully. `source.fromJson(raw)` wraps the raw string as a `ValueSource`, and `User__bind` reads from it and returns a `User`. After that, `u` is an ordinary struct. We reach into the nested address with `u.address.city`, and we ask the list its size with `u.roles.size()`. No parsing code anywhere, just field access.

## Segment: Walking the list (6:15)

**Say:** The roles came in as a proper `List<string>`, so we can loop over it the normal way.

**On screen:**
```nova
    let i = 0;
    while (i < u.roles.size()) {
        console.log(`  role[${i}] = ${u.roles.at(i)}`);
        i = i + 1;
    }
```

**Say:** Nothing special here, this is the list handling you already know. `size()` gives the count, `at(i)` gives the element. The point is that the JSON array became a real Nova list through the generated binder, so you work with it exactly like any other list.

## Segment: Serializing back with __toJson (7:15)

**Say:** Now the other direction. We take our `User` value and turn it back into a JSON string with the generated writer.

**On screen:**
```nova
    // Serialise User to JSON via the compiler-generated writer (round-trips).
    console.log(`json    = ${User__toJson(u)}`);
}
```

**Say:** `User__toJson` walks the struct in field-declaration order and produces JSON. Because it is symmetric with `__bind`, this round-trips. The value we parsed in should come back out as the same JSON.

**Run it:** `nova docs/guide/examples/23_serde.nova -o /tmp/serde && /tmp/serde`

```
id      = 7
name    = Ada
active  = true
city    = Pune
#roles  = 2
  role[0] = admin
  role[1] = dev
json    = {"id":7,"name":"Ada","active":true,"address":{"street":"Main","city":"Pune"},"roles":["admin","dev"]}
```

**Say:** Look at that last line. It is exactly the JSON we fed in, re-emitted in field order. The nested address is there, the roles array is there, everything matched. That is what makes `__bind` and `__toJson` a matched pair.

## Segment: Why this design is nice (9:15)

**Say:** Let me put the pieces together.

**On screen:**
```
@serializable                  Ask the compiler to generate binders for this struct
init() (zero-arg)              Required; supplies field defaults __bind starts from
<Struct>__bind(src)            Deserialize from a ValueSource (recursive over structs + List<T>)
serde.source.fromJson(raw)     Wrap a raw JSON string as a ValueSource
<Struct>__toJson(value)        Serialize back to JSON, field-declaration order
```

**Say:** The big win is that the binders are generated from the struct's declared fields. There is no runtime type information and no separate schema to keep in sync by hand. If you add a field, or rename one, the binder changes with it at the next build. You cannot get a mismatch between your type and your parser, because the parser is your type.

## Recap (10:15)

**Say:** Quick recap.

- `@serializable` makes the compiler generate `__bind` and `__toJson` for a struct, at compile time, no reflection.
- Every serializable struct needs a zero-argument `init()` that sets a default for every field.
- `<Struct>__bind` reads from a `ValueSource`, and `serde.source.fromJson` wraps raw JSON as one.
- Nested serializable structs and `List<T>` fields are handled automatically.
- `<Struct>__toJson` writes JSON back in field order, and it round-trips with `__bind`.

## Outro (10:50)

**Say:** Now that you can move data in and out of JSON, you are ready for the capstone. In the next video we put this to work in a real web service, where the very same generated binders bind request structs from an incoming HTTP request. See you there.
