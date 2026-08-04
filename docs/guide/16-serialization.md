# 16. Serialization

Turning structs into JSON and back is a compile-time feature in Nova, not a runtime reflection trick.
Annotate a struct with **`@serializable`** and the compiler generates two free functions for it:

- **`<Struct>__bind(src: ValueSource): Struct`**: deserialize from a `ValueSource`. It recurses into
  nested `@serializable` structs and over `List<T>` fields automatically.
- **`<Struct>__toJson(value: Struct): string`**: serialize back to a JSON string, in
  field-declaration order. `__toJson` is symmetric with `__bind`, so a value round-trips.

A `ValueSource` is the abstract input the binder reads. `serde.source.fromJson(raw)` wraps a raw JSON
string as one. (The same abstraction is what lets a web handler bind a struct from a request whose fields
come partly from the route and partly from the body: same generated `__bind`, different source.)

One requirement: an `@serializable` struct must have a zero-argument `init()` that sets defaults for
every field. `__bind` starts from those defaults and overwrites whatever it finds in the source, so a
missing key keeps its default instead of crashing.

```nova
// examples/23_serde.nova
// Marking a struct `@serializable` makes the COMPILER generate binders for it at
// compile time: no reflection, no hand-written parsing:
//
//   * `<Struct>__bind(src: ValueSource)` : deserialize from a source (here JSON),
//     recursively over nested structs and List<T> fields.
//   * `<Struct>__toJson(value)`          : serialize back to a JSON string, in
//     field-declaration order (symmetric with __bind).
//
// `serde.source.fromJson(raw)` wraps a raw JSON string as a ValueSource that the
// generated binder reads. Every @serializable struct needs a zero-arg `init()`
// that sets defaults; __bind overwrites the fields it finds.
import serde.source;
import list;

@serializable
struct Address {
    pub street: string,
    pub city: string,
    init() { self.street = ""; self.city = ""; }
}

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

fn main(): void {
    let raw = "{\"id\":7,\"name\":\"Ada\",\"active\":true," +
              "\"address\":{\"street\":\"Main\",\"city\":\"Pune\"}," +
              "\"roles\":[\"admin\",\"dev\"]}";

    // Parse JSON into User via the compiler-generated binder.
    let u = User__bind(source.fromJson(raw));
    console.log(`id      = ${u.id}`);
    console.log(`name    = ${u.name}`);
    console.log(`active  = ${u.active}`);
    console.log(`city    = ${u.address.city}`);
    console.log(`#roles  = ${u.roles.size()}`);
    let i = 0;
    while (i < u.roles.size()) {
        console.log(`  role[${i}] = ${u.roles.at(i)}`);
        i = i + 1;
    }

    // Serialise User to JSON via the compiler-generated writer (round-trips).
    console.log(`json    = ${User__toJson(u)}`);
}
```

Output:

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

| Piece | Role |
|-------|------|
| `@serializable` | Ask the compiler to generate binders for this struct |
| `init()` (zero-arg) | Required; supplies field defaults `__bind` starts from |
| `<Struct>__bind(src)` | Deserialize from a `ValueSource` (recursive over structs + `List<T>`) |
| `serde.source.fromJson(raw)` | Wrap a raw JSON string as a `ValueSource` |
| `<Struct>__toJson(value)` | Serialize back to JSON, field-declaration order |

Because the binders are generated from the struct's declared fields, there is no runtime type
information and no schema to keep in sync by hand: change a field and the binder changes with it at the
next build. Note the round-trip in the output: the final `json` line is exactly the input re-emitted in
field order, which is what makes `__toJson` and `__bind` a matched pair.

Next: [Building a web service](17-web.md)
