# Nova Language — Specification & Reference

> ⚠️ **DEPRECATED — do not trust this file.** The authoritative language reference is now
> **[`language-specification.md`](language-specification.md)**, reverse-engineered from the compiler's
> actual behavior and the conformance corpus (2026-07-20). This file is retained for history only; its
> status markers predate for-loops, decimal128 arithmetic/BSON, cross-module visibility, `env.args()`,
> and the native-default `nova build`. Consult it for nothing.

**Revision 2026-07-15.** This is a **complete rewrite**. The previous document (v0.6.0, dated
2025-07-05, *"Status: Planning"*) was discarded: it was a **plan written in the present tense**, so it
read as authoritative while being wrong. Examples of what it asserted:

- primitives are `i32, i64, f32, f64, bool, string, datetime` — missing `int`/`byte`/`short`/`long`/
  `float`/`double`/`void`/`any`, and **`datetime` is not a type at all**;
- "the type checker rejects [user-facing `any`]" — **it does not**;
- "There is no tuple type in v1" — `tuple` **is** in the AST;
- **zero mentions** of template strings or `go` — both of which ship.

**This document has one job: describe what is true.** It is the **inventory, reference manual, and
spec** in one. Anything not built lives in §12 (Planned), clearly separated, never present-tense.

---

## 0. How to read this

| Mark | Meaning |
|---|---|
| ✅ | Implemented **and pinned by a conformance case** — rely on it |
| ⚠️ | Implemented, but with a caveat you must know |
| 💥 | Implemented but **broken** — compiles, then misbehaves/crashes at runtime |
| 🔎 | Present in parser/AST but **not corpus-verified** — at your own risk |
| ❌ | **Not implemented.** If you need it, it goes in the plan (§12) |

**Rules of engagement — why this document exists.** *Do not invent a feature on the spot.* Check here
first: ✅ use it; ⚠️/💥/🔎 know what you're stepping on; ❌ it goes in the plan, **not** into an ad-hoc
helper next to the thing that already exists. §11 names the **one canonical way** per task. Skipping
that step is precisely how the tree ended up with `fiber.spawn` beside `go`, `StopWatch` beside
`nowNs`, and `__i32_to_string` beside template strings.

**Verification.** The surface below is extracted from `src/lexer.zig` (keywords), `src/ast.zig` (nodes),
`src/codegen/types.zig` (types), and `conformance/cases/` (what is pinned). **Where this document and
the code disagree, the code is right and this document is a bug.**

---

## 1. Overview & toolchain

Nova is a statically-typed, compiled, ES6/TypeScript-flavoured language for **server-side services,
hypermedia apps, and WASM**. Compiler in Zig → LLVM IR; runtime in C++20 (Boost.Asio); **ARC, no GC**.

**Targets — ⚠️ the CLI defaults to `--wasm`:**

```
nova app.nova --native -o app        # native — what you almost always want today
nova app.nova --wasm   -o app.wasm   # wasm  — ⚠️ on hold (§12)
```

Compiling without `--native` and getting `Function 'nova_test_fail' not found` means you built for wasm.

| Fact | |
|---|---|
| `zig build` (in `lang/`) | builds the compiler **and installs the stdlib into `~/.nova/std`** |
| Import resolution | `src/std/…` relative to CWD, **falling back to `~/.nova/std`** |
| ⚠️ **Consequence** | after editing `lang/src/std/*.nova` you **must** `zig build`, or anything compiled outside `lang/` silently uses the **old** stdlib |
| `NOVA_THREADS=n` | runtime worker-pool size (default: hardware concurrency) |
| `NOVA_KEEP_OBJ=1` | keep the intermediate `.o` (e.g. to relink under a sanitizer) |
| Corpus | `conformance/run.sh` — **23/23 green** |

---

## 2. Lexical structure

**Keywords** (`lexer.zig`):

```
async await break case catch const continue default defer else enum export false fn for go if
impl import let match pub return std struct switch throw trait true try union var while
```

⚠️ **Four of these are RESERVED but not usable** — using one is a compile error, not an identifier:
- **`match`** — reserved-unimplemented; `switch` is the real construct (§5.4).
- **`throw` / `try` / `catch`** — **REMOVED** (§5.5). Nova has no exceptions; they never worked.
  Reserved rather than deleted so old code gets an explanation instead of "undefined identifier".
  ⚠️ `try`/`catch` may RETURN with different (non-exception) meanings — see §3.4b's open decision.

⚠️ `and` / `or` are **not** keywords (they are ordinary identifiers). Use `&&` / `||`.

**Operators**

| Class | Ops | Notes |
|---|---|---|
| Arithmetic | `+ - * / %` | `+` also concatenates strings |
| Comparison | `== != < <= > >=` | resolve to `bool` |
| Logical | `&&` `\|\|` `!` | ✅ the only logical ops |
| Bitwise | `&` `\|` `^` `<<` `>>` | ⚠️ resolve to `int`, not `bool` |
| Optional | `?.` `??` | §6.5 |
| Cast | `as` | §6.4 — numeric/bit-level **only**, never formatting |

**Comments** `//`, `/* */`, `///` doc. **Literals** ints (`42`, `5_000_000_000`), floats (`3.14`),
strings `"…"`, template strings `` `…${x}…` ``, `true`/`false`.

---

## 3. Type system

### 3.1 Primitives — ⚠️ the widths do not mean what they say

Recognised names (`types.zig:isPrimitiveTypeName`):

```
i8 u8 byte ubyte    i16 u16 short ushort    i32 u32 int uint    i64 u64 long ulong
i128 u128    f32 float    f64 double    decimal    bool    void    any
```

> ### 💥 The single most important fact in this document
>
> `types.zig:42` maps **`i32`, `u32`, `int`, `uint` all to one `val_type`**, and
> `llvm_codegen.zig:240` sets **`val_type` = `i64` on native / `i32` on wasm**. Therefore:
>
> ```nova
> let a: i32 = 5000000000;   // prints 5000000000 on NATIVE — i32 is not 32 bits
>                            // the same line TRUNCATES on wasm
> ```
>
> - **`i32` is not 32-bit.** `int` is merely an alias for it.
> - **`u*` / `uint` are not unsigned.**
> - **The same source has different arithmetic on native vs wasm.**
> - Every local/param is allocated as a uniform **i64 stack slot regardless of declared type**
>   (`declarations.zig:884`) — a `byte` occupies 8 bytes, and an **`f64` lives in an integer slot,
>   reinterpreted as bits**.
>
> Until **L1** (§12): prefer **`int`** for ordinary integers, use **`long`/`i64`** when you genuinely
> need 64 bits, and never trust a declared width to bound a value.

`f32` — 🔎 named, not corpus-verified. **`datetime` is not a type** (the old spec said it was); there is
a `datetime` *module* (§9).

> ### ✅ `decimal` is IEEE 754-2008 decimal128 (BID) — Stage 1 implemented
>
> `decimal` is base-10, 34 significant digits, encoded as **BID** (Binary Integer Decimal) — the EXACT
> encoding MongoDB's BSON decimal128 uses, so Nova's `decimal` is wire-identical to BSON with no
> conversion (the point: it is for the MongoDB driver). Deliberately **not** .NET's `System.Decimal`
> (which cannot round-trip BSON) and **not** binary128 (`0.1m` must be exact, and a base-2 type named
> `decimal` would be the same lie as an `i32` that is not 32 bits). `i128`/`u128` were removed.
>
> - **Representation:** a 16-byte **ARC-managed heap object** (like `string`) — a `decimal` value in a
>   slot is a pointer. (16 bytes cannot fit Nova's 8-byte slots.)
> - **Literals:** the `m`/`M` suffix — `10.5m`, `100m`, `-3.14m`, `0.1m`. The digit text is handed
>   verbatim to the runtime's BID parser, so `0.1m` is EXACT (no f64 round-trip).
> - **`toString` / `${d}`:** ✅ formats the BID value back to a decimal string.
> - **BSON encode/decode:** ✅ Stage 3 — the 16 BID bytes ARE decimal128's wire format, so it is a
>   straight memcpy: `bytes.write_decimal(dst, off, d)` / `bytes.read_decimal(src, off)` (the MongoDB
>   driver hook), and `serde.bson` encodes a `decimal` field as element type `0x13`.
> - **Arithmetic (`+ - * / %`) + compare:** ✅ Stage 2 — base-10 on the decoded (sign, coefficient,
>   exponent) triple with **round-half-even** to 34 significant digits. `0.1m + 0.2m` is exactly `0.3`;
>   exact results get their IEEE 754 preferred exponent (`1m / 4m` → `0.25`, `1.5m * 2m` → `3.0`); a
>   repeating quotient (`10m / 3m`) rounds to 34 digits. Each op yields a fresh ARC heap decimal.
>   There is **no implicit int↔decimal conversion**: a mixed `decimal <op> non-decimal` is a compile
>   error (write `2m`, not `2`). Runtime BID ops live in `src/runtime/decimal.cpp`
>   (`nova_decimal_add/sub/mul/div/mod/cmp`). Div-by-zero currently yields `0` (a Stage-2 stub).

### 3.2 Value vs reference — ✅ the model is correct

- **Every primitive is a value type on the stack.** `arc.zig:isRefCountedType` returns **false** for
  primitives (also enums, closures); locals/params are `alloca` slots.
- **`string` is a heap object with ARC** (variable length) — as are **lists, maps, structs**.
- Consequence: a struct parameter **already passes by reference** — mutating its field is visible to the
  caller. Primitives pass **by value**, and there are ❌ no out-params (see L3, §12).

**Heap object layout** — load-bearing for anything touching `bytes`:

```
[ptr-8] refcount (i64)   [ptr-4] length (i32)   [ptr..] data
```

`bytes.alloc(n)` writes that header and returns `base+8`, so **`bytes.alloc(n) as string` is the
documented idiom** for building a string from raw bytes (`string.nova:allocString` does exactly this).

### 3.3 `string` — ⚠️ ASCII / bytes only

✅ heap + ARC. ⚠️ **No UTF-8 codepoint handling**: `length` counts bytes, `toUpperCase` is ASCII-only,
`slice` indexes bytes. (L5, §12.)

### 3.4 Optionals — ✅ `T | undefined`

```nova
let found: string | undefined = map.get(key);
if (found != undefined) { use(found); }   // `found` is `string` INSIDE the branch
let name = maybeName ?? "anonymous";      // nullish coalesce
let n = user?.profile?.name;              // optional chaining
```

⚠️ `List.get(i)` returns `T | undefined`.

#### 3.4a Narrowing — comparing against `undefined` narrows the binding

Testing a binding against `undefined` narrows its type in the branch where the test holds:

```nova
let s = list.get(i);              // string | undefined
// s.length                       // ERROR here: s may be undefined
if (s != undefined) {
    total = total + s.length;     // OK: s is `string` in this branch
}
if (s == undefined) { return ""; }
// (no narrowing after the branch — see the limit below)
```

Rules:

- The test must be `x != undefined` / `x == undefined` where **`x` is a plain binding**. A field
  (`a.b != undefined`) or a call does not narrow: nothing stops the value changing between the test
  and the use.
- `!=` narrows the **then** branch; `==` narrows the **else** branch. Both directions hold.
- Narrowing is scoped to the branch and does not leak past it.
- **Limit (today):** narrowing is *branch*-scoped only. An early-exit guard
  (`if (s == undefined) { return; }`) does **not** narrow the code after it, even though it is
  equivalent. Recorded because the stdlib will want it; it needs reachability, not just scoping.

**Accessing a member of an optional without narrowing — ⚠️ CHECKED AT RUNTIME, not compile time (P2-14).**

> ⚠️ **This section claimed enforcement that does not exist.** Corrected 2026-07-17 by running it:
> ```nova
> let l = List<string>(); l.push("hi");
> let s = l.get(5);        // undefined — out of bounds
> let n = s.length;        // compiles. SEGFAULTS.
> ```
> Every direction is unchecked — assigning `string | undefined` to a `string`, passing it to
> `fn takes(s: string)`, returning it from `fn(): string`, and member access. Not a resolver blind
> spot around `l.get()` either: an explicitly annotated `let s: string | undefined = "hi";
> let x: string = s;` is equally unchecked. `type_checker.zig` has no narrowing machinery at all
> (every "narrow" in it is integer-width conversion), and there is no `.optional` arm in the
> field-access path, so `resolveExprType` returns null and every downstream check silently skips.
>
> ✅ **RESOLVED (P2-14, 2026-07-17): keep the see-through, guard it at runtime.**
> Commit `950495c` deliberately made `list.get(i).field` resolve without narrowing (the ergonomic
> win that unblocked the router), and that is what made the absent case a null deref. Rather than
> restrict the see-through (which breaks the router + 3 bson sites) or leave it unsound, codegen
> now inserts a guard before a member deref whose object is optional-typed: if the value is
> `undefined` (handle 0), it ABORTS with
>     `abort: member access on an absent optional at <file>:<line>`
> instead of a SEGV. UB became an honest, located crash — the same transformation applied to
> `throw` (§5.5) and to errors (§3.4b). Present values are unaffected; the guard costs one
> compare+branch and is a no-op unless the object's type is `T | undefined`. Gated by
> `38_optional_deref_guard.nova` (present-value paths) and the whole corpus being ASAN-clean.
>
> **Not yet: COMPILE-TIME enforcement.** Rejecting unnarrowed access statically (spec's original
> intent) is the soundness endgame, but it needs flow-narrowing better than today's branch-scoped
> rule (§3.4a: an early-exit `if (x==undefined) return;` does not narrow after it), or optionals
> become painful. The runtime guard is memory-safe now; enforcement retires it later.

The rule as *intended*: it is not auto-unwrapped. This is the one rule that makes optionals worth
having — `List.get(i)` returns `T | undefined` precisely so that an absent element cannot be read as
if it were present. `s.length` on a `string | undefined` loads a length header through whatever
`undefined` is: a null dereference the type system exists to prevent, and today does not.

### 3.4b Errors — `T | Error` — ⚠️ **IMPLEMENTED** (`try` / `catch`; no `is` yet)

> **Status:** LANDED 2026-07-17 — gated by `conformance/cases/33_error_union.nova` (ASAN-clean).
> `throw`/`try`/`catch`-as-exceptions were removed first (§5.5); `try`/`catch` return here as VALUE
> operators. Representation: a box `[header][tag][payload]` (tag 0 = ok, 1 = err) that OWNS its
> payload and releases it in `__destruct_ErrUnion_*`, branching on the tag.
>
> **Not built:** `is` narrowing (`if (r is E)`) — it needs flow-sensitive narrowing, since every
> later use of `r` would have to know whether it is still a box. `try`/`catch` need no flow
> analysis and cover the cases; `catch (e)` gives you the error as a plain enum to `switch` on.
> Also unbuilt: the zero-alloc two-register return (see Open Decision 2), and async (Decision 3).

#### The rule: ABSENCE is not FAILURE

This is the whole design in one line, and the reason `T | Error` is not just "optionals again":

| | Meaning | Type | Fallback |
|---|---|---|---|
| **Absence** | not finding something is a NORMAL outcome | `T \| undefined` | `??` |
| **Failure** | something went wrong, and there is a REASON | `T \| Error` | `catch` |

`map.get(k)` is absence. `parseInt(s)`, a DB round-trip, a socket read are failures. **Nova has no
`null`** — it never has, and it never will; the `null`/`undefined` split is the worst thing JS/TS
inherited and Nova is free of it. Keep it that way.

#### Declaring and returning

The error side is an **ordinary tagged enum with payloads**, consumed by the `switch` that already
exists. No new pattern machinery, and — unlike Zig's payload-free error sets — the reason survives:

```nova
enum ConfigError {
    NotFound(string),
    BadSyntax(string),
    OutOfRange(int),
}

fn readConfig(path: string): string | ConfigError {
    if (!fs.exists(path)) { return ConfigError.NotFound(path); }
    return fs.read(path);
}
```

#### Consuming — ⚠️ `is` is NOT IMPLEMENTED (planned; use `catch (e)` today)

```nova
let r = readConfig("app.toml");
if (r is ConfigError) {
    switch (r) {                      // r : ConfigError in this branch
        case ConfigError.NotFound(p): { log.warn(`missing ${p}`); }
        case ConfigError.BadSyntax(m): { log.error(m); }
        case ConfigError.OutOfRange(n): { log.error(`bad: ${n}`); }
    }
    return;
}
// r : string here
```

#### Propagating (`try`) and defaulting (`catch`)

```nova
fn loadPort(): int | ConfigError {
    let raw = try readConfig("app.toml");   // error -> return it; else raw : string
    return try parsePort(raw);
}

let port = loadPort() catch 8080;           // reads exactly like `??` does for undefined
```

`try` is **not** sugar. §3.4a records that narrowing is *branch-scoped only* — an early-exit guard
does not narrow the code after it. Error handling is written as early-return, so that limit would bite
every function. `try` sidesteps it because the compiler generates the narrowing instead of relying on
flow analysis. **`catch` is the failure-side twin of `??`**, which is why the pair reads consistently.

`errdefer` pairs with the existing `defer`: run on the error path only.

#### ✅ DECIDED — the `try`/`catch` keywords (2026-07-17)

Reused, with value semantics. `try` is valid ONLY as a prefix on an expression; `try { … }` remains
a parse error whose message explains the difference, which is what keeps the two readings apart.
`catch` pairs with `??`: absence vs failure, same shape. Rejected: `!int` / `?int` sigils — Nova
already spells unions with `|`, so `T | E` borrows nothing and reads like `T | undefined`.

#### (was) OPEN DECISION 1 — the `try`/`catch` keywords

These are Zig's spellings, and §5.5 has just told every user that `try`/`catch` mean *"exceptions do
not exist"*. Reusing them within one release has a real cost for an audience coming from ES6/TS/.NET,
who read `try` and think exceptions.

- **Recommendation: use them anyway**, with `try` valid ONLY as a prefix on an expression — never a
  block. `try { … }` stays a parse error with a message pointing here, which disambiguates at the one
  place confusion would occur. `catch` earns its keep by pairing with `??`: absence vs failure,
  same shape.
- **Alternative:** `f()!` / `f()?` to propagate (Rust/Swift-ish). Cheaper to explain to a .NET
  audience, but `?` collides visually with `?.`/`??`, which Nova already uses for absence.

#### ⚠️ OPEN DECISION 2 — representation (the actual engineering)

`T | undefined` uses a **sentinel** (0). `T | Error` cannot: the error is itself a value.

- ❌ **Low-bit pointer tagging breaks immediately** on `int | Error` — odd integers would read as
  errors.
- ❌ **Heap-boxing `{tag, payload}`** costs an allocation on **every success**. That is the tuple
  design (§6.6), and it is wrong for the hot path.
- ✅ **Recommendation: return `{i64 tag, i64 payload}` in TWO REGISTERS.** x86-64 SysV and AArch64
  AAPCS both return 16-byte aggregates in registers with zero memory traffic. Codegen returns a single
  i64 today, so this is real work — **but it is the same capability tuples need for a real destructor
  (§6.6), so one foundation pays for both.**

#### ⚠️ OPEN DECISION 3 — async has no failure story at all

**No document states how an async task reports failure.** `go` yields an **untyped** handle (§7 stores
them as `List<i64>`), so `await` is untypeable *by construction* — F2 says it needs `Handle<T>`; the
runtime plan defers `Future<T>`; neither has a design. An async error channel lives exactly there.
**`T | Error` is incomplete for `async fn` until that is resolved.**

#### What this does NOT do

- **No stack traces.** `nova_get_stacktrace()` returns an empty buffer and always has, so `throw`
  never provided one either (§5.5). Traces are *compatible* with this design — capture at error
  CONSTRUCTION (the same site a throw would capture) via `backtrace()`/`backtrace_symbols()`; the
  runtime is C++, so it works natively. `try`-propagation loses nothing, because the trace was already
  taken at the failure site. Gate it behind a debug flag.
- **No implicit conversion between error types.** Rust's `?` is ergonomic only because of `From`; that
  is trait machinery Nova does not have. Convert explicitly, or use one error enum per layer.
- **Context chains (`%w`-style wrapping) are not designed yet** — and under a coroutine scheduler they
  matter *more* than traces, because a stack trace shows the scheduler, not the logical caller.

#### Why not Rust or Go

- **Rust `Result<T, E>`** — a generic payload enum plus `From`-based conversion for `?`. The trait
  machinery is the blocker, and boxed errors mean ARC traffic on every failure.
- **Go `(T, error)`** — REJECTED, and measured (§6.6 and `route-handling-via-mediator.md` §8.D):
  tuples are invisible to the type checker (`v + e` where `e` is a string compiled to pointer
  arithmetic), arity is unchecked in both directions, and **nothing forces you to look at the error**.
  Go's model works because Go's checker types multi-returns and Go has a GC; Nova has neither.

### 3.5 `any` — ⚠️ exists, and is **not** rejected

`any` is a recognised primitive. The old spec claimed the checker rejects user-facing `any`; **it does
not**. Use only at serde boundaries; narrow with `as`.

### 3.6 Generics — ⚠️ real, but by **erasure**

```nova
struct Pair<A, B> { pub first: A, pub second: B, init(a: A, b: B) { … } }
fn identity<T>(x: T): T { return x; }
let l = List<int>();
```

✅ Multi-param generics on fns/structs; checked for arity mismatch, type-args on non-generics, and
duplicate type params. ⚠️ **No monomorphization** — one uniform boxed (i64) body per generic. No
`size_of<T>`; a `List<byte>` is not byte-packed.

### 3.7 Traits — ✅

```nova
trait Shape { fn area(self: Shape): double; }
impl Shape for Circle { fn area(self: Circle): double { … } }
```

✅ Pinned by `12_traits_dispatch`. ❌ No `Hash`/`Eq` traits (Map uses a `hashFn` heuristic).

---

### 3.8 `Storage<T>` — 🔎 **planned**, the owned buffer (F5 §3.3a)

> **Status: specified, not implemented.** Written before the code, per the spec-first rule. Nothing
> below is true yet.

`Storage<T>` owns **N contiguous slots of `T`**. It is the one container primitive the compiler
understands, and it exists so that ARC can see *through* a collection to its elements.

```nova
struct List<T> {
    data: Storage<T>,     // owns `cap` slots of T
    len:  int,
    cap:  int,
}
```

- **It is a heap object like any other** (§3.2's layout): `[ptr-8] refcount`, `[ptr-4] length`,
  `[ptr..] slots`. `length / 8` **is** the slot count — no separate capacity field is needed inside it.
- **It is ARC-visible.** `data` is a *typed field*, so releasing a `List` releases its `Storage<T>` by
  the mechanism that already works. When the `Storage<T>` refcount hits zero its destructor **releases
  every slot** whose `T` is ref-counted, then the buffer is freed. Nothing is special-cased per
  collection, and **a user writing their own container gets ARC for free**.
- **A slot holds `T` directly — no box.** `List` currently heap-allocates a one-word box per element
  (`allocCopy<T>`), and nothing frees the boxes: measured at exactly **one leaked object per `push`**.
  `Storage<T>` stores the word in the slot, so the boxes — and `allocCopy` — cease to exist.
- **Releasing a slot needs `T` to be concrete**, which is F4 (`__destruct_Storage_string` is a distinct
  symbol from `__destruct_Storage_int`). This is *why* F4 came first.

Surface:

| | |
|---|---|
| `Storage<T>(n)` | allocate `n` zeroed slots; refcount 1 |
| `s.get(i)` | the slot's value as `T` |
| `s.set(i, v)` | store `v`; **retains** `v` if `T` is ref-counted, releases the old |
| `s.cap` | slot count (`length / 8`) |

⚠️ **Bounds are NOT checked** (consistent with `bytes`). `Storage<T>` is the primitive collections are
built *from*; `List.get` returns `T | undefined` and does the checking.

**Why not `Heap<T>`/`Arc<T>`/`Buffer<T>`/`Memory<T>`** — decided 2026-07-15, see F5 §3.3a for the
rejection table. In Nova *heap-allocated* and *reference-counted* are true of every `string`, `List`,
`Map` and struct, so a name built on either property distinguishes nothing. The name says what the thing
**is**: it owns N slots of `T`. Precedent: Swift's `ManagedBuffer`.

**Consequence — `delete()` goes.** Collections currently expose `pub fn delete(self)`, which is both the
ARC deinit hook *and* hand-called in 17 places; it survives only because each is idempotent. With
`Storage<T>` the generated destructor frees the buffer, so there is nothing left for `delete()` to do,
and the `<Struct>_delete`-as-finalizer special case in `arc.zig:146` is deleted with it. `App.delete(path, handler)`
(an HTTP verb) and `Map.delete_key(key)` are ordinary methods and stay.

## 4. Declarations

AST: `fn_decl struct_decl union_decl enum_decl const_decl import_decl export_decl trait_decl`

### 4.1 Functions — ✅

```nova
fn add(a: int, b: int): int { return a + b; }
pub fn exported(x: string): void { … }
async fn fetch(url: string): string { … }        // §7
```

⚠️ Every parameter needs a type; every function needs a return type (`: void` if none).
❌ No default parameter values, no overloading, no varargs.

### 4.2 Structs — ✅

```nova
pub struct Point {
    pub x: int,
    pub y: int,
    tag: string,                                  // no `pub` => private
    init(x: int, y: int) { self.x = x; self.y = y; self.tag = "p"; }
    pub fn dist(self: Point): double { … }        // `self` is EXPLICIT and typed
}
let p = Point(3, 4);                              // no `new`
```

⚠️ **`self` is an explicit, typed first parameter** — not implicit. `init` is the constructor; its arg
count is checked.

**Where methods live — the convention (2026-07-19):** a method is any `fn m(self: T, …)`. It may be
written INSIDE the type's body (`struct Point { pub fn dist(self: Point) … }`) OR as a free function
with an explicit `self` and called UFCS-style (`fn hash(self: string) …` → `s.hash()`), which the
stdlib uses pervasively (`string`, `datetime`, `net/tcp`, `web/*`). ONE restriction: a **GENERIC**
type's methods must be defined INSIDE the struct body (as `List`/`Map`/`Set` do) — free-function UFCS
methods on a generic receiver (`fn push<T>(self: Container<T>, …)`) are NOT typed by the checker (the
`self: Container<T>` param's `T` is not solved at the call site), so `x.m()` on such a receiver would
not resolve. The former `Array<T>` container was the lone violator of this and was removed
(redundant with `List<T>` anyway).

### 4.3 Enums — ✅ tagged

```nova
enum Result { Ok(int), Err(string) }
let r = Result.Ok(42);
switch (r) { case Result.Ok(v): … case Result.Err(e): … }
```

### 4.4 Unions — 🔎 `union_decl` exists; not corpus-verified.

### 4.5 Imports / exports — ⚠️ **one flat namespace**

```nova
import string;
import collections.list;
import data.btree.client;
```

> ⚠️ **The merged stdlib shares a single flat namespace.** A local `fn parseInt(s: string)` silently
> collides with `datetime`'s `parseInt(s, start, end)` → LLVM verification fails with *"Incorrect number
> of arguments passed to called function"*. **Prefix your helpers.** (It is also why the arg-count
> checker skips ambiguous names.)

❌ **There is no top-level `let`** — use `const` or a function.

---

## 5. Statements

`block let_stmt expr_stmt if_stmt while_stmt for_stmt switch_stmt return_stmt break_stmt
continue_stmt defer_stmt`  
(`try_catch_stmt`/`throw_stmt` REMOVED — §5.5)

### 5.1 `let` / `const` — ✅ two keywords, `const` enforced-immutable

```nova
let x = 5;      // MUTABLE variable — reassignable
x = 6;          // ✅ ok

const y = 10;   // IMMUTABLE constant
y = 11;         // ❌ error: cannot assign to 'y' — it is a `const`
```

Nova has exactly **two** binding keywords (ES6-style): `let` for a mutable variable, `const` for an
immutable constant. There is **no `var`** — it was removed (a third keyword meaning the same as `let`
was only confusing). ✅ **`const` immutability IS enforced** (2026-07-19): reassigning a `const`
binding is a hard sema error (`infer.zig` records it, `shadow.zig` rejects with a located diagnostic),
gated by `expect_fail/const_reassign.nova`. `let` is reassignable (`let i = 0; i = i + 1;`).

Mutating **through** a `const` reference is allowed — `const` freezes the BINDING, not the pointee:
```nova
const xs = List<int>();   // xs may not be rebound…
xs.push(1);               // …but the list it names may be mutated ✅
```

### 5.2 `if` / `while` — ✅ the condition **must be `bool`** (enforced: `non_bool_condition`).
### 5.3 `for` — 🔎 present; the stdlib uses `while` — do likewise for anything load-bearing.
### 5.4 `switch` — ✅ the real construct (`match` is reserved-unimplemented).
### 5.5 `try` / `catch` / `throw` — ❌ **REMOVED. Nova has no exceptions.**

Reserved words (like `match`), so using one is a compile error that explains itself rather than
`undefined identifier 'throw'`. Gated by `expect_fail/throw_removed.nova` and
`expect_fail/try_catch_removed.nova`.

> This section previously read "✅ exceptions exist". They existed in the sense that the syntax
> parsed. **They never worked.** Removed 2026-07-17 for three measured reasons:
>
> 1. **The thrown value could not survive.** `nova_throw` took a `long long`; codegen's catch bound
>    `zext(setjmp_res)` — an **i32**. The stdlib's only user, `web/di.nova`, did
>    `throw "DI Error: Service not registered: " + key`; `web/recovery.nova` caught it and logged
>    **`[RECOVERY] Caught exception: 8472`** — the string pointer truncated to 32 bits and
>    re-stringified as a number. `web/mediator.nova` had already stopped reading `err` and passed a
>    hardcoded string to its exception handlers. The one thing an exception is for — carrying an
>    error — never once worked.
> 2. **No unwinding, so every throw leaked.** ARC released only the *catching* frame's try-block
>    locals; every frame between the throw and the catch leaked everything it owned. (F5 §3.4e found
>    that `break`/`continue` — "the exits that JUMP" — released nothing. A `throw` was a third such
>    exit, covered by no rule at all.)
> 3. **UB exactly where it was used.** setjmp/longjmp out of a C++20 coroutine is undefined
>    behaviour, and `async fn` compiles to precisely that. The sole stdlib consumer was a pipeline
>    behavior inside an async HTTP handler.
>
> Also gone: `nova_throw`, `nova_push_exception_frame`, `nova_pop_exception_frame`, the
> `ExceptionFrame` stack, and the `_setjmp` declaration that existed only to serve them.
> **There are no stack traces either** — `nova_get_stacktrace()` returns an empty buffer and always
> has, so `throw` never provided one.
>
> **The replacement is `T | Error` — designed in §3.4b** (errors as VALUES, checked by the type
> system, message intact, nothing to unwind, no UB under coroutines). **Not yet built:** until it
> lands, return `T | undefined` and check it — which conveys exactly as much as `throw` did, since
> `throw` destroyed its message too.
>
> ⚠️ §3.4b proposes bringing `try` and `catch` BACK with Zig semantics — `try f()` propagates, `f()
> catch d` defaults — which is **not** what they meant here. That keyword reuse is an open decision
> recorded in §3.4b; if it is taken, this section's error message must change from "was removed" to
> "means something different now".
### 5.6 `defer` — 🔎 present; not corpus-verified.

---

## 6. Expressions

`literal ident binary unary call generic_call field_access index struct_init enum_init cast
optional_chaining nullish_coalesce jsx_element closure tuple if_expr block_expr template_expr
await_expr go_expr`

### 6.1 Template strings — ✅ the canonical way to format… ⚠️ but 💥 on 64-bit types

```nova
let s = `hello ${name}, n=${count}`;            // ✅ int, bool, string
writeFsFile(`dir/changed_${count}.txt`, "…");   // real stdlib usage (fs.nova:50)
```

> 💥 **`${x}` SEGFAULTS at runtime for `i64`/`long` and `f64`/`double`** — and it **compiles clean**.
>
> | `${x}` where x is | |
> |---|---|
> | `int`, `bool`, `string` | ✅ |
> | `i64` / `long`, `f64` / `double` | 💥 **SIGSEGV** |
>
> Same root as §6.2 (and §3.1's i64-slot punning). Until L2 (§12): scale a float to `int` before
> interpolating.

### 6.2 Stringification — ⚠️ only two builtins exist

`__i32_to_string(x)` and `__bool_to_string(x)` are compiler-injected. **There is no `__i64_to_string`
and no `__f64_to_string`.** ⚠️ Because `int` is secretly 64-bit (§3.1), `__i32_to_string` *does* print
full 64-bit values. Deprecated — see §11.

### 6.3 Closures — ✅ real, but parameters are **untyped**

```nova
let add = (a, b) => a + b;                    // parameters carry NO type annotation
list.forEach((k, v) => console.log(k));      // their types come from CONTEXT (§6.3a)
```

⚠️ **`(a: int, b: int) => a + b` does NOT parse.** This section claimed it did, and it never has:
`parser.zig:1815` reads a bare identifier per parameter and then expects `,` or `)`, so the `:` is a
syntax error (`expected=.right_paren, got=.colon`). `ast.Closure.params` is `[][]const u8` — names
only, with nowhere to put a type. Corrected 2026-07-15 after the spec's own example was run.

Deferred, not rejected: typed parameters would need `Closure.params` to become `[]Param` plus a parser
change. Nothing needs them yet, because every parameter's type is recoverable from context — and where
it is not, the closure is unusable anyway.

✅ Real per-instance heap environments (box `{fn_ptr, env}`); returned closures and loop captures are
independent. ⚠️ Environments are not ARC'd yet (they leak).

#### 6.3a Contextual typing — a closure's parameters come from the expected type

Because a parameter has no annotation, its type is whatever the position it is passed to expects:

```nova
// map.nova:  pub fn forEach(self: Map<K,V>, fn: (K, V) -> void): void
m.forEach((k, v) => { ... });   // m: Map<string,int>  =>  k: string, v: int
```

Rules:

- The expected type is the **declared parameter type** of the function being called, after the
  receiver's type arguments are substituted (§3.6). `Map<string,int>.forEach` expects
  `(string, int) -> void`, not `(K, V) -> void`.
- Arity must match. A closure with the wrong number of parameters is a type error, not a partial
  binding.
- With **no** expected type, a parameter is inferred from **its use in the body**, where the use pins it:

  ```nova
  let f = (x) => x + 1;        // x: int   — `x + 1` against an int forces it
  let g = (a, b) => a + b;     // a, b: unresolved — nothing pins either side
  ```

  The rule is deliberately narrow: a parameter used as one side of a binary operator whose *other* side
  has a known type takes that type. That covers the common shape and nothing more.

- **Limit (today):** `(a, b) => a + b` genuinely cannot be concluded — both sides are unknown, and
  `a + b` says only "these are addable", which needs type variables and a solver, not propagation.
  Inferring from later **call sites** (`f(5)` ⇒ `x: int`) needs the same. Both stay `unresolved`, which
  is honest; guessing `int` would be the machine-word lie in a new place.

### 6.4 Casts (`as`) — ✅ numeric / bit-level **only**

```nova
let i = (d as int);                  // double -> int
let s = bytes.alloc(n) as string;    // documented raw-bytes -> string idiom (§3.2)
```

⚠️ `as` does **not** format: `n as string` on a number is not a stringify.

### 6.5 `?.` / `??` — ✅ (§3.4)
### 6.6 Tuples — 🔎 `tuple` is in the AST (the old spec wrongly denied it); unverified. The stdlib
returns structs for multi-value.
### 6.7 `if_expr` / `block_expr` — 🔎 present; `string.nova` uses `if`-as-expression.
### 6.8 JSX / NSX — 🔎 `jsx_element` exists (hypermedia views); not corpus-covered.

---

## 7. Concurrency — ✅ `go` + `async` / `await`

```nova
async fn work(id: int): int { … }

async fn runAll(): int {
    let h1 = go work(1);              // launch concurrently -> joinable handle
    let h2 = go work(2);
    return await h1 + await h2;       // join
}

fn main(): void {
    let total = runAll();             // calling an async fn from sync code BLOCK-DRIVES the scheduler
}
```

✅ Pinned by `10_async_go` / `11_channels`. Real **Boost.Asio** scheduler: each coroutine gets a strand;
`run()` executes on a **`NOVA_THREADS`-sized pool** → genuine multi-core. ⚠️ `go` handles can be stored
(`List<i64>`) and awaited in a loop, so dynamic worker counts work.

#### 7.1 The types of `go` and `await`

```nova
async fn square(n: int): int { … }

let v  = await square(3);   // int          — await on a CALL yields the fn's return
let h  = go square(3);      // future<int>  — go yields a FUTURE of the return
let v2 = await h;           // int          — await on a future unwraps it
```

- **`go E`** where `E` is a call returning `T` yields **`future<T>`**.
- **`await E`** yields `T` if `E` is `future<T>`, and otherwise the type of `E` — so `await` on a direct
  async call is the call's return type.
- `future<T>` is **not** written by users today; there is no syntax for it. It exists so `await` has
  something to unwrap, which is what makes `let v = await h` typeable at all.

⚠️ **A handle is represented as a bare `i64`** and the spec above stores them in `List<i64>`. So
`future<T>` is a *type-level* fact only: nothing stops `h + 1` from compiling, because the checker does
not yet reject arithmetic on a future. Recorded rather than claimed away — the alternative was typing a
handle AS its eventual value (what the old resolver did), which makes `h + 1` not merely unchecked but
*correct*, and that is the machine-word lie F3 exists to kill.

> ### ⚠️ `fiber.spawn` is DEPRECATED — it is **not** concurrent
> `concurrency/fiber.nova`'s `spawn` runs the closure **inline on the calling thread**
> (`concurrency.cpp:30`, "synchronous v0 shim"). It looks like concurrency and isn't. **Use `go`.**

**Channels:** `concurrency/channel` ⚠️ blocking queue (blocks the OS thread — don't call from a
coroutine that must yield); `concurrency/asyncchan` ✅ `await chanRecv` parks correctly.
**Atomics:** `concurrency/atomic` — `Atomic<T>` load/store/CAS/add/sub.

---

## 8. Memory model

ARC, no GC. Primitives = stack values (§3.2); strings/lists/maps/structs = refcounted heap pointers
(retain on store, release on scope exit). Enums and closures are not refcounted.

✅ **The "string heap corruption" is FIXED (2026-07-15) — and it was never heap corruption.** The wild
**read** in `string_slice` was a *symptom*: `x.field` resolved to a global **function** of the same name
(§10 #6/#7), so the btree driver put a code address in a `string` field. `.length` then read the
function's instruction bytes as a length, and `string_slice` read wild from there. Every heap hypothesis
was correctly eliminated because the premise was wrong — the heap was fine. Fixed in `expressions.zig`
(`.field_access` no longer resolves a **variable**'s field against the function table); pinned by
`15_name_resolution`. Record: `lang/repro/driver_alloc_churn_crash.nova`.

---

## 9. Standard library index

Canonical import names (`main.zig:std_modules`). Status = fitness for use, not existence.

| Module | Status |
|---|---|
| `string` | ⚠️ ASCII-only; ❌ no `toInt`; has `slice/split/join/trim/replace/indexOf/eql/parseFloat` |
| `collections/list` | ⚠️ `.size()` (**not** `.length()`); `get()` → `T \| undefined` |
| `collections/map` | 💥 **CRASHES ON RESIZE** (see §10 #16) — usable only below the load factor; ❌ no `Hash`/`Eq` (uses a `hashFn` heuristic) |
| `collections/set`, `collections/string_builder` | ⚠️ alpha |
| `collections/array` | ❌ dead/unused — do not use |
| `math` | ✅ int + float suite (`fabs/ffloor/fceil/fround/fsqrt/fpow`, `fln/fexp/fpowf`); ❌ **no RNG** |
| `datetime` | ⚠️ `now()` = **seconds**; ✅ `nowNs()` = **nanoseconds — use this for timing** |
| `stopwatch` | ⚠️ **1-second resolution** (`elapsedMs()` = `(end-start)*1000`) — useless for latency |
| `env` | ✅ `get` returns `""` when unset (this previously **segfaulted**) |
| `crypto` | ❌ **STUB — `sha256`/`md5` return `""`**, while their own test asserts a real digest |
| `serde/json`, `serde/yaml`, `serde/bson` | ⚠️ prototype (escape/float gaps) |
| `io/file`, `io/dir`, `fs`, `process` | ⚠️ alpha |
| `net/tcp/*`, `net/tls`, `net/asyncio` | ⚠️ alpha; TLS verify gaps |
| `web/*` (~30 modules) | ⚠️ prototype — middleware largely not in-path; sessions/CSRF insecure (no CSPRNG) |
| `data/btree/client` | ✅ verified against BTreeDB (binary protocol); ⚠️ see §8 |
| `concurrency/fiber` | ⚠️ **deprecated** (§7) |
| `concurrency/channel`, `asyncchan`, `atomic` | ⚠️/✅ see §7 |
| `mem/allocator`, `mem/arena_allocator`, `traits`, `assert`, `exception` | ⚠️ alpha |

---

## 10. Known-broken / gotcha index

The highest-value section here. **A green-looking API that crashes costs more than a missing one.**

| # | Thing | Reality |
|---|---|---|
| 1 | `i32` / `int` widths | 💥 **i64 native, i32 wasm** — not 32-bit; unsigned isn't unsigned (§3.1) |
| 2 | `${i64}` / `${f64}` | 💥 **SIGSEGV** at runtime; compiles clean (§6.1) |
| 3 | `crypto.sha256` / `md5` | ❌ **return `""`** (§9) |
| 4 | `fiber.spawn` | ⚠️ **runs inline** — no concurrency (§7) |
| 23 | ✅ **Block scope — FIXED** (2026-07-15) | Was: 💥 **no block scope at all**. `let x = 1; if (true) { let x = 2; } return x;` → **returned 2**; and a `let v` inside **`if (false)`** retyped a live `let v = 42` as `string` (last-writer-wins in `collectLocalVarTypes`), so `${v}` read a string header at `[42-4]` → **SIGSEGV** — *dead code segfaulting live code*. **Fix:** `src/sema/alpha.zig` — an alpha-renaming pass gives every colliding binding a distinct name (`x$1`) before the checker and codegen, which makes their flat-per-function `locals` map correct by construction rather than teaching three sites about scopes. Codegen untouched; non-shadowing code byte-identical. Renames on **any collision in the function**, not just shadowing — disjoint blocks shadow nothing yet still collided. Pinned by `16_block_scope` (12 tests, verified to fail first). ⚠️ Slots are still function-lifetime (a block `let` lives for the whole fn) — a lifetime/ARC question (F5), not correctness. Real `Scope{names,parent}`: `design/F1` §3.2 |
| 22 | ⚠️ **async scheduler: a rare residual race** | **Four scheduler bugs fixed 2026-07-15** (the `10_async_go` flake, ~20% → 0/50): a **lost wakeup** (re-scheduling while `running` was still set → the request was swallowed into `pending_resume` and never re-checked → `await` returned a stale pointer); `delete state` **under its own `lock_guard`** (unlocking a freed mutex); **`nova_run()` returns on an *idle* io_context but the caller read the root's promise unconditionally** — idle ≠ done, now `nova_run_root()` drives until genuinely complete and **aborts** on a lost wakeup rather than returning garbage; and a **stale waiter** — the early-done path skipped `take_waiter()`, leaking a registration in `g_waiters`, which is keyed by a **reused heap address**, so a later coroutine inherited it and the scheduler resumed a destroyed frame. Frames are now freed via `nova_coro_release()`, serialised against the scheduler, not a bare `llvm.coro.destroy`. **Residual: 1 bad `await` in ~18,000 drives — real, not noise, and not one of the four.** Repro + method (ASAN is useless here; `NOVA_THREADS=1` is the control; lldb finds it): `lang/repro/async_scheduler_race.nova`. **Do not treat the scheduler as sound.** |
| 5 | `StopWatch` | ⚠️ 1-second resolution (§9) |
| 6 | ~~string heap bug~~ | ✅ **FIXED** (2026-07-15) — never a heap bug. `x.field` on a **variable** resolved to a same-named global **fn**, so a code address landed in a `string` field → `.length` read instruction bytes → wild read in `string_slice`. **This was the ⛔ blocker on YCSB/the driver**; YCSB LOAD+RUN now complete clean (also under ASAN). Pinned by `15_name_resolution` (§8) |
| 7 | Flat namespace | ⚠️ helper names silently collide with the stdlib (§4.5). ✅ **Symbols are no longer path-dependent** (2026-07-15): `getModulePrefix` now strips the absolute `$HOME/.nova/std/` root it used to miss, so a symbol no longer embeds the developer's home directory and the same file yields the same symbol however it was resolved — **109 of 204 symbols (53%) on ycsb → 0**, and a src-resolved vs HOME-resolved build now produce a byte-identical symbol set. Builds are reproducible. **No longer corrupts member access** (#6 fixed: a variable's field/method always wins over a global fn). Still live for **top-level** names: your `fn hash` and the stdlib's `hash` share one table, and resolution is by **string suffix scan** over `func_map` — the structural fix is a real symbol table |
| 8 | Default target | ⚠️ `--wasm`; pass `--native` (§1) |
| 9 | Stale stdlib | ⚠️ edited `src/std`? **`zig build`** or you're using the old copy (§1) |
| 10 | `let` | ⚠️ reassignable — not enforced-immutable (§5.1) |
| 11 | `List.length()` | ❌ it is `.size()` (§9) |
| 12 | Top-level `let` | ❌ not allowed (§4.5) |
| 13 | `string` ops | ⚠️ ASCII/bytes only (§3.3) |
| 14 | `match` | ❌ reserved, unimplemented — use `switch` |
| 15 | Closure envs | ⚠️ **leak** (not ARC'd) (§6.3) — **MEASURED 2026-07-15: linear and unbounded, ~46 B per closure.** 1M→51.9MB, 4M→189.5MB, 16M→740.4MB (`/usr/bin/time -l` peak RSS; baseline 5.9MB). 4× work → 4× memory, so a long-running server dies eventually. Box+env are `alloc_persistent`'d and nothing ever releases them |
| 16 | **`Map` resize** | ✅ **FIXED** (2026-07-15) — was 💥 SIGBUS the moment the Map grew past its load factor. Root cause was #18, not Map; fixing the fn-value representation fixed this. Pinned by `14_collections_map` (grow past resize, all keys survive, tombstone churn) — the case that never existed is why it survived (§13) |
| 18 | ✅ **A bare `fn` value called through a local is called as a closure box** — **FIXED** (2026-07-15) | Was: a **bare function** (e.g. `string.hash`) is a raw **code** pointer, but the indirect-call path unpacked it as a **closure box** `{fn_ptr, env}`, loading the function's own first instruction as the call target → SIGBUS. Two conventions existed, so a fn value silently changed meaning depending on how it was called: `(self.hashFn)(k)` (direct field) worked, `let f = self.hashFn; (f)(k)` crashed. **Fix:** one uniform representation — every fn value is a box `{fn_ptr, env}` whose `fn_ptr` takes `env` as a hidden leading param. A bare fn has no env param, so boxing the raw pointer alone would shift every argument by one; it is wrapped in a compiler-generated thunk `__fnbox_thunk_<name>(env, args…)` that drops `env` and forwards the rest, boxed as a module-level **constant** `{thunk, 0}` (no captures ⇒ nothing to alloc, nothing to leak, and stable identity so `self.hashFn == string.hash` still holds). `expressions.zig:buildBareFnBox`; the direct-field-call path now unpacks the box like every other call site. Pinned by `14_collections_map`. Detail: `lang/repro/map_resize_crash.md` |
| 19 | ❌ **Typed lambda params don't parse in an argument position** | `f(16, (s: string) => g(s))` → `Expect failed: expected=.right_paren, got=.colon`. Still open — a **parser** bug, independent of #18. No longer load-bearing now that #18 is fixed (bare fns are safe to pass), but it still blocks passing a *typed* lambda inline; drop the annotation (`(s) => g(s)`) or bind it to a local first |
| 17 | `List`/`Map` element leaks | ⚠️ elements are not released (roadmap C1) — **MEASURED 2026-07-15: it is exactly the *refcounted elements*, and it is linear/unbounded.** `List<string>` (20 elems/round): 50k→66.7MB, 200k→249.8MB, 800k→927.4MB (4× work → 3.7× memory). **`List<i32>` is BOUNDED** (3.2M rounds → 618MB plateau, vs 495MB at 200k) — so the allocator and buffer reuse are fine; `List.delete()` frees the backing buffer correctly. The bug is only that nothing releases refcounted elements. Shares a root with #15: **ARC doesn't release what it owns** |
| 20 | ⚠️ **`allocator.globalAllocator()` allocates a fresh `Allocator` on every call** | It returns a *struct literal*, so each call heap-allocates (verified 2026-07-15: two calls compare unequal) **plus** a retain/release, since `Allocator` is a struct. **11 call sites**, including hot paths: `io/file.nova:111` is `allocator.globalAllocator().alloc(size + 1)` — *an allocation in order to allocate*; `io/dir.nova:48,117` likewise. Must be a singleton. **Deeper:** the abstraction has **one** implementation — `new_with_allocator<T>` is called 3×, always with `globalAllocator()`, and `ArenaAllocator` (with an adapter at `mem/arena_allocator.nova:40`) is **unused** — while `List`/`Map`/`StringBuilder` bypass it entirely for raw `bytes.alloc_persistent`. **Two allocation models, neither used consistently** (§11's "different different things"). Decision: `design/F5` §3.3b + §6 Q6 |
| 21 | ⚠️ **A static bare-fn box is read-only — do not make fn values ARC'd until it is fixed** | `buildBareFnBox` emits `LLVMSetGlobalConstant(box_g, 1)` (`expressions.zig:97`) → `__DATA_CONST` → **read-only at runtime**. Harmless today *only* because `isRefCountedType` returns `false` for any name containing `->`. The moment fn values become owned (`design/F5` §3.2 `.func => true`), `nova_retain` writes `[box-8]` → **BUS**. Live instance in waiting: `mem/allocator.nova`'s `allocFn: (i32,i32) -> i32` holds the bare fn `cAllocFn`. Not hypothetical — this exact fault was traced on 2026-07-15 (`___fnbox_payload` in `__DATA_CONST`, `nova_retain`, `alloc.cpp:123`). **Fix:** copy the string-literal precedent (`llvm_codegen.zig:351-357`) — writable global + 8-byte header + refcount sentinel `100000000` — so retain/release are uniform and harmless. Detail: `design/F5` §3.4a |

---

## 11. Canonical style — one way per task

The antidote to "different different things". Where two mechanisms exist, **this** is the one:

| Task | ✅ Use | ❌ Don't |
|---|---|---|
| Format / stringify | template strings `` `x = ${x}` `` | `__i32_to_string`; a bespoke `format()` |
| Concurrency | `go f(x)` + `async`/`await` | `fiber.spawn` |
| Timing / latency | `datetime.nowNs()` | `StopWatch`, `datetime.now()` |
| Logical ops | `&&` `\|\|` | `and`/`or` (not keywords); `&`/`\|` (bitwise) |
| Branching | `switch` | `match` (reserved) |
| Loops | `while` | `for` (🔎 unverified) |
| Ordinary integers | `int` | `i32` (lies about its width) |
| Multi-value return | a struct | `tuple` (🔎 unverified) |
| Raw bytes → string | `bytes.alloc(n) as string` | hand-rolled headers |
| Optionals | `T \| undefined` + `?.` / `??` | sentinel values |
| Storing a callback | store the **fn value** and call it either way — `(self.f)(x)` and `let f = self.f; (f)(x)` are now the same thing (§10 #18). Bare fns and lambdas share one representation | passing a **typed** lambda inline — still unparseable (§10 #19); use `(s) => …` |

---

## 12. Planned — **not implemented; do not write code against this**

> ### 🏗️ The foundation program comes first — `docs/design/` (2026-07-15)
>
> **Nothing in this section starts until F1–F5 land.** Every item below is a *type-directed* feature
> sitting on a compiler that has no types at the point of decision: ownership is chosen by
> `isRefCountedType(type_name: []const u8)`, `T` is detected as "a string of length 1 that is
> uppercase", and names are resolved by scanning for an `_`-delimited suffix. The four bugs fixed on
> 2026-07-15 (§10 #6, #16, #17, #18) were four symptoms of that one fact.
>
> | # | Piece | Kills |
> |---|---|---|
> | **F1** | Name resolution, scopes & modules — a real symbol table | §10 #6, #7; unblocks the arg-count check |
> | **F2** | **Typed IR** — a type is a value, not a spelling. *The keystone.* | silent wrongness; unblocks F3/F4/F5 |
> | **F3** | Primitive types & representation (absorbs **L1**+**L3**) | §10 #2; *Primitive types = Unsound* |
> | **F4** | Generics & monomorphization (absorbs roadmap **A2** inc. 2) | erased generics; precondition for F5 |
> | **F5** | **ARC ownership model** (absorbs **A1** remaining, **C1**) | §10 #15, #17 |
>
> Read `docs/design/README.md` first; it carries the evidence and the dependency order. **The plan was
> never missing — it was skipped.** L1 already predicted the `data: i32` breakage; roadmap A2 already
> named un-namespaced resolution as the blocker that later cost months as "string heap corruption"; A1
> already flagged the closure-env leak on delivery. This program exists so that a design is agreed
> *before* code, and so no feature is built on a foundation piece still marked `Designed`.

Detail: **`nova-language-evolution-plan.md`** (L0–L6). Sequencing: **`nova-readiness-roadmap.md`** §M2.5.
Runtime detail: `runtime-cpp20-plan.md`.

| ID | What | Fixes |
|---|---|---|
| **L0** | **This document** + a generator + a CI check | the entire "invented a shipped feature" class |
| **L1** | Honest primitives: `int`=32 on every target, `long`=64, real unsigned, per-type stack slots — **now `design/F3`** | §10 #1 |
| **L2** | Finish `${}` for all primitives; `ToString`; delete `__*_to_string` | §10 #2 |
| **L3** | `ref` params + an opaque `ptr` (**no raw pointers**) — `ptr` **now `design/F3`** | out-params; the address-in-an-int idiom |
| **L4** | `crypto` over wolfCrypt (already vendored+linked) + CSPRNG/PRNG split | §10 #3; unblocks web security |
| **L5** | UTF-8; `text` namespace; regex — **via Boost.Regex** (already installed) | §10 #13 |
| **L6** | i18n/l10n — **via Boost.Locale** (already installed): negotiation, plurals, number/currency/date, `dir` | web-first gap |

⚠️ **L5/L6 dependency note.** Boost **1.90.0** is installed with **Boost.Regex and Boost.Locale
prebuilt** (`libboost_regex`, `libboost_locale`) — the runtime already uses Boost.Asio, so these are the
same dependency family. Two facts shape the design: (1) the runtime links **no** Boost lib today (Asio is
header-only), and both of these are **compiled** libs — so they change every user-program link and are
**hostile to the WASM target**; (2) the installed `libboost_locale` **does not link ICU**, so plurals
degrade to gettext `Plural-Forms` and Unicode regex (`boost::u32regex`) is unavailable. **The ICU
yes/no decision is open** and gates how much L5/L6 deliver — see the evolution plan.

Also planned (roadmap): monomorphization, `Hash`/`Eq`, serde correctness, web/TCP rewrite, the string
ARC fix (§8). **WASM is ⚠️ on hold.**

---

## 13. Conformance corpus — what is actually guaranteed

`conformance/run.sh` — **28/28 green**. **A feature with no case here is unverified by construction**
(`${f64}` had none; it segfaults).

> ✅ **`10_async_go` was FLAKY; fixed 2026-07-15.** ~20% → **0 failures in 50 runs**, corpus 25/25 across
> 3 consecutive full runs. Four real scheduler bugs, not one (§10 #22). The gate is usable again.
> ⚠️ But a **residual race remains** — 1 bad `await` in ~18,000 drives (§10 #22). It cannot realistically
> flake a 2-drive case, so it does not compromise the corpus gate, but the scheduler is **not** sound.
> Method note, because it cost hours: **ASAN is useless on this race** (its slowdown closed every window
> — 1800 drives clean while the same binary crashed 3/20 natively); `NOVA_THREADS=1` is the control; a
> PC *equal to* the faulting address means a jump through a garbage fn pointer, i.e. a freed frame.

**Positive (17):** `00_smoke` `01_collections_list` `02_generics_destructor` `03_strings` `04_closures`
`05_closures_capture` `06_closures_advanced` `07_generics` `08_floats` `09_float_stdlib` `10_async_go`
`11_channels` `12_traits_dispatch` `13_serde` `14_collections_map` `15_name_resolution` `16_block_scope`

**Negative — must fail to compile (11):** `constructor_arg_count` `duplicate_type_param`
`generic_arity_mismatch` `non_bool_condition` `return_type_mismatch` `type_args_on_non_generic`
`undefined_function` `undefined_variable` `wrong_arg_count` `method_shadowed_by_global_fn` `ambiguous_bare_call`

**Rule:** a fix for anything in §10 lands **with** a case here, or it regresses silently.
