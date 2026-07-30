# The Nova Language — Specification & Reference

**Status:** authoritative language reference, reverse-engineered from the compiler's actual behavior and
the **conformance corpus** (`lang/conformance/cases/`, 55 executable cases as of this writing). Every
non-trivial claim is cited to the case that pins it, e.g. *(→ 53_for_loops)*. This document supersedes
`specs.md` (which is retained for history but deprecated).

> **Ground-truth rule.** If a statement here is not backed by a conformance case or directly observed
> compiler behavior, it is marked 🔎 (present but unverified) or ⏳ (planned/partial). Everything else is
> guaranteed by the gate suite (FUNC / `--arc` / `--asan` / `--shadow` / unit), run on every change.

---

## 1. Overview & toolchain

Nova is a statically-typed, natively-compiled language with **deterministic automatic reference counting
(ARC)** — no garbage collector, no manual `free`. Syntax is ES6/TypeScript-flavored; the compiler is
written in Zig and emits native code via LLVM; the runtime is C++20 (Boost.Asio for async).

**Commands:**
- `nova build --file app.nova` → a **native executable** (the default target; `cargo build`-style). WASM
  is opt-in via `--target wasm` *(→ fix 05ca77b; WASM build is currently unverified — see §15)*.
- `nova test [file.nova]` → compiles `@test` functions with a harness and runs them.
- `nova fmt`, `nova init`, `nova add`, `nova get` — formatting, scaffolding, dependencies.

A program's entry is `fn main(): void`. Command-line arguments are read via `env.args()` *(→ 54_process_args)*.

---

## 2. Lexical structure

- **Comments:** `// line comment`. (No block comments.)
- **Identifiers:** letter/`_` then letters/digits/`_`.
- **Keywords:** `let`, `const`, `fn`, `struct`, `enum`, `trait`, `union`, `impl`, `import`, `pub`,
  `if`, `else`, `while`, `for`, `switch`, `case`, `return`, `break`, `continue`, `defer`, `async`,
  `await`, `go`, `as`, `true`, `false`, `undefined`, `null`. `in` is a **contextual** keyword (only
  special inside a `for (… in …)` header) *(→ 53_for_loops)*. `var` was **removed** — use `let`/`const`.
- **Literals:**
  | Kind | Example | Type |
  |---|---|---|
  | integer | `42`, `-7`, `0xff`, `0b1010`, `0o17` | `int` (32-bit); a radix-prefixed literal (`0x` hex, `0b` binary, `0o` octal) is read at its base and fits `long` when it exceeds 32 bits |
  | float | `1.5`, `3.14` | `f64` (`double`) |
  | string | `"hello"` | `string` (UTF-8 bytes) |
  | bool | `true` `false` | `bool` |
  | decimal | `9.99m`, `0.1m`, `-3.14m` | `decimal` (128-bit BID) *(→ 50_decimal)* |
  | template | `` `n = ${x}` `` | `string` (runtime-assembled) *(→ 24_stringify, 48, 49)* |
  | array | `[1, 2, 3]` | `T[N]` |
  | tuple | `(a, b)` | tuple *(→ 28_tuple_return_heap)* |
  | null / undefined | `null`, `undefined` | absence (§3.5) |
- **Operators:** arithmetic `+ - * / %`; comparison `== != < > <= >=`; logical `&& ||`; bitwise `& ^ |`,
  shifts `<< >>`; range `..` (exclusive), `..=` (inclusive) *(→ 53_for_loops)*; assign `=`; nullish
  coalesce `??`; optional chaining `?.`; cast `as`; closure arrow `=>`; type union `|` (optionals /
  error unions).
  - Bitwise `^` is XOR (integers only), with C-family precedence: `&` binds tighter than `^`, which binds
    tighter than `|` — so `a & b ^ c | d` parses as `((a & b) ^ c) | d`. *(→ 88_bitwise_xor)*
  - Unary prefix operators: `-` (negate), `!` (logical not), `~` (bitwise NOT / one's complement, integers
    only — `~x == x ^ -1`). *(→ 88_bitwise_xor)*
  - Compound assignment: `+= -= *= /= %=` and the bitwise `&= |= ^= <<= >>=`. Each desugars to
    `a = a <op> b`. *(→ 88_bitwise_xor)*

---

## 3. Type system

### 3.1 Primitive & scalar types

| Type | Meaning | Notes |
|---|---|---|
| `int` | 32-bit signed integer | Arithmetic **wraps at 2³¹** — honestly 32-bit *(→ 19_int_overflow)* |
| `long` | 64-bit signed integer | |
| `uint`, `u64` | unsigned | unsigned relational/opcode selection *(→ 19)* |
| `float` / `f64` / `double` | IEEE-754 double | real `double` arithmetic *(→ 08_floats, 09_float_stdlib)* |
| `bool` | boolean | conditions **must** be `bool` (enforced) |
| `string` | UTF-8 byte buffer | ASCII-level ops + `text.utf8` codepoints *(→ 03_strings, 26_utf8)* |
| `decimal` | IEEE 754-2008 decimal128 (BID) | 16-byte ARC heap object; §3.6 |
| `ptr` | opaque machine word | first-class, **non-owned** address value *(→ 17_ptr)* |
| `void` | no value | |
| `any` | 🔎 present, not rejected | no type-system meaning; avoid |

### 3.2 Value vs reference

**Primitives are value types on the stack** (`int`/`long`/`float`/`bool`/`ptr`/enums). **`string`,
`decimal`, `List`, `Map`, `Set`, structs, tuples, closures** are **ARC-managed heap objects** — a
variable of such a type holds a pointer, and assignment/argument-passing manages refcounts automatically
(§5). There is no distinction in syntax; the type decides.

### 3.3 `string`

A UTF-8 byte buffer with a length prefix. Concatenation `+`, `.length`, indexing, and the `string`
stdlib are ASCII/byte-level; `text.utf8` provides real codepoint iteration *(→ 03_strings, 26_utf8)*.
Template strings are the canonical way to format values: `` `count = ${n}` `` — `${…}` stringifies
`int`/`long`/`float`/`bool`/`decimal`/`string` via runtime helpers *(→ 24_stringify, 18_float_interp)*.

### 3.4 Optionals — `T | undefined`

An optional is written `T | undefined`. `undefined` means **absence** (not an error). Member access
**through** an optional is memory-safe: it is guarded, not a null-deref *(→ 30_optional_member_access,
38_optional_deref_guard)*. Narrowing: `if (x != undefined) { use(x) }` narrows `x` to `T` in the branch.
`List<T>.get(i)` and `Map<K,V>.get(k)` return `T | undefined`.

### 3.5 Error unions — `T | E`

Nova's error model: a function that can fail returns `T | E` where `E` is a user error type (an enum or
struct). **Errors are values you return, not exceptions** *(→ 33_error_union, 32_error_payloads)*:

```nova
fn readConfig(path: string): string | ConfigError { … }
```

- `try readConfig(path)` — if it returned the error side, **return that error** from the enclosing
  function; otherwise yield the unwrapped ok value.
- `readConfig(p) catch h` — on the error side, evaluate the **expression** `h` (which may bind the error:
  `catch (e) reason(e)`); the ok value passes through unchanged.
- `errdefer cleanup()` — runs `cleanup()` ONLY when the enclosing function returns on the **error** path
  (an explicit error-side return, or a `try` that propagates). Plain `defer` runs at every scope exit;
  `errdefer` is its error-only twin, for unwinding a half-built resource when the operation fails. Multiple
  errdefers run LIFO *(→ 101_errdefer)*.
- The error **carries its reason** to the caller — the whole point of the model *(→ 32)*.

`T | E | undefined` composes the two: read as `(T | undefined) | E` (absence vs failure). There is **no
stack unwinding**: `try`/`catch` are branches on a value — nothing leaks, no UB under coroutines.
`try { … }` as a statement block is a **parse error** (Nova has no exceptions).

### 3.6 `decimal` — decimal128, complete

`decimal` is IEEE 754-2008 decimal128 in **BID** encoding — a 16-byte ARC heap object, wire-identical to
BSON's decimal128. It exists for exactness (`0.1m` is exact) and for the MongoDB driver.
- **Literals:** `m`/`M` suffix — `10.5m`, `-3.14m`, up to 34 significant digits *(→ 50_decimal)*.
- **Arithmetic + compare:** `+ - * / %` and all six relations, base-10 with round-half-even to 34
  digits; `0.1m + 0.2m` is exactly `0.3` *(→ 52_decimal_arith)*. **No implicit int↔decimal** conversion
  — a mixed operand is a compile error (`2m`, not `2`). Div-by-zero yields `0` (a stub).
- **BSON:** `bytes.write_decimal`/`read_decimal` (the 16 BID bytes are the wire format); `serde.bson`
  encodes a `decimal` field as element type `0x13` *(→ 51_bson_decimal)*.

### 3.7 Containers & generics

Generics are real, carried through as type parameters and **monomorphized** per instantiation (with
per-instantiation destructors and ARC) *(→ 07_generics, 02_generics_destructor)*.

- `List<T>` — `push`, `get(i): T | undefined`, `set`, `size`, `map`/`filter`/`reduce` (closures)
  *(→ 01_collections_list, 04_closures)*.
- `Map<K,V>` — constructed `Map<K,V>(capacity, hashFn)`; `set`, `get(k): V | undefined`, `has`,
  `delete_key`, `size`, `keys(): List<K>`, `values(): List<V>`, `forEach((K,V) => void)`
  *(→ 14_collections_map)*.
- `Set<T>` — membership.
- `Storage<T>` — the low-level owned buffer backing `List`/`Map`; ARC releases each slot via a generated
  `__destruct_Storage_T`.
- `Atomic<T>` — `load`/`store`/`add`/`sub`/`compareAndSwap` over int/long/bool *(→ 31_atomics)*.
- `Future<T>` — the result handle of a `go`-launched async call (§11).
- **Tuples** — `(a, b)`; ARC-correct even when holding heap elements *(→ 28_tuple_return_heap)*.

### 3.8 Structs, enums, traits

```nova
struct Point { pub x: int, pub y: int
    init(x: int, y: int) { self.x = x; self.y = y }
    pub fn sum(self: Point): int { return self.x + self.y }
}
```
- **Structs** have `pub`/private fields, an `init` constructor, and methods (`self: T` first param).
  Field/method visibility is enforced within a struct *(→ 12, 39_declared_type_ownership)*.
- **Enums** are tagged; variants may be payload-less or carry a payload:
  ```nova
  enum Color { Red, Green, Blue }          // Color.Red
  enum Tagged { N(int), S(string) }        // Tagged.N(3)
  ```
  A payload-less variant `E.A` is a value; methods dispatch on it (`E.A.code()`) *(→ 36_enum_method_dispatch)*.
- **Traits** are interfaces with dynamic dispatch (vtables):
  ```nova
  trait Speaker { fn speak(self: Speaker): int; }
  struct Dog impl Speaker { pub fn speak(self: Dog): int { return 5; } }
  fn make(): Speaker { return Dog(); }     // factory returning a trait object
  ```
  Trait-typed bindings, downcasts (`x as T`), and factory returns all work *(→ 12_traits_dispatch,
  44_downcast_and_struct_literal_args)*.
- **Generic traits** — a trait may take type parameters that appear in its method
  signatures, and an impl supplies concrete type arguments:
  ```nova
  trait Handler<Q, R> { fn handle(self, req: Q): R; }
  struct GetUserHandler impl Handler<GetUser, UserDto> {
      fn handle(self, req: GetUser): UserDto { return UserDto{ id: req.id, name: "Ada" }; }
  }
  ```
  Impl-conformance substitutes the trait's type params (`Q`, `R`) with the impl's type
  arguments before checking method signatures — a wrong concrete type is a compile
  error. Dispatch is type-erased (one vtable slot per method serves every
  instantiation), so codegen is unchanged. *(→ 55_generic_traits)*. Foundation for the
  typed-mediator routing framework (`docs/design/done/route-handling-via-mediator.md`).
- **Unions** — `union_decl` exists 🔎 (not corpus-verified as a user feature).

---

## 4. Ownership & memory model

Nova uses **RAII + ARC**. The compiler inserts retain/release so every heap object is freed exactly once
when its last owner goes away — deterministically, at scope exit, with no GC pauses.

- **Disposition.** Every expression is *owned* (a fresh `+1` the statement must consume) or *borrowed*
  (names an existing owner). A literal is borrowed; a producer (call, template, arithmetic making a
  string/decimal, struct/tuple literal) is owned.
- **Uniform borrow-ABI.** Function arguments are **borrowed** — the callee retains (dups) what it keeps,
  the caller drops its temporary. There are no consuming parameters.
- **Aggregates take ownership.** Storing a value into a struct/list/tuple field either moves a fresh
  temporary in or retains a borrowed one, so the aggregate's destructor balances it *(→ 41, 42, 46)*.
- **Static balance check.** A sema pass proves, per function, that every owned local and temporary has
  exactly one consume path (move or drop) — a build error otherwise. This is enforced under `--shadow`
  and is what makes ARC *provable*, not merely *green*. It caught real defects even in this spec's own
  for-loop work.
- **`--asan` is a required gate** — the leak audit is blind to use-after-free; ASAN is not optional.

Owned types: `string`, `decimal`, `List`/`Map`/`Set`/`Storage`, structs, tuples, closures, error-union
payloads. Not owned: `int`/`long`/`float`/`bool`/`ptr`/enums.

---

## 5. Declarations

### 5.1 Functions & methods
```nova
fn add(a: int, b: int): int { return a + b }
fn id<T>(x: T): T { return x }            // generic
```
Methods take `self: T` as the first parameter; static/associated methods are called `Struct.method()`
*(→ 22_static_methods)*. A module-qualified constructor/static call is `module.Struct()` /
`module.Struct.method()` *(→ 23_module_qualified_calls)*.

### 5.2 `let` / `const`
Two binding keywords only *(`var` removed)*:
- `let x = …` — **mutable**.
- `const x = …` — **enforced-immutable**; reassigning it is a hard error.

Type annotations are optional when inferable: `let x: int = 0` or `let x = 0`. Destructuring:
`let (a, b) = pair`.

---

## 6. Statements

### 6.1 `if` / `while`
`if (cond) { … } else { … }` and `while (cond) { … }`. **The condition must be `bool`** (enforced —
`non_bool_condition`). `if` is also an expression (§7).

### 6.2 `for` — all four forms
The increment lives in its own block, so `continue` runs it for every form *(→ 53_for_loops)*:
```nova
for (let i: int = 0; i < n; i = i + 1) { … }   // C-style
for (i in 0..n)   { … }                         // range, exclusive
for (i in 1..=n)  { … }                         // range, inclusive
for (x in xs)     { … }                         // collection (List) — over .size()/.get(i)
for ((k, v) in m) { … }                         // map — over keys()/get()
```
`break` and `continue` work in all forms.

### 6.3 `switch`
```nova
switch (self) {
    case Color.Red:   { return 1; }
    case Tagged.N(v): { return v; }             // binds the payload
}
```
`match` is reserved-unimplemented; `switch` is the real construct.

### 6.4 `return`, `break`, `continue`, `defer`
`defer expr` runs `expr` at scope exit 🔎 (present; lightly covered).

---

## 7. Expressions

- **Template strings** `` `…${x}…` `` — the canonical formatter (§3.3).
- **Closures** — `(x) => x + 1` or `(x, y) => { … }`. Real per-instance heap environments capture
  variables; parameters are **untyped** (inferred from the call site / expected type)
  *(→ 04_closures, 05_closures_capture, 06_closures_advanced, 49_closure_interpolation)*.
- **Casts** — `x as T` for numeric/bit-level conversions and trait downcasts *(→ 44)*.
- **`?.` / `??`** — optional chaining and nullish-coalescing (§3.4).
- **Ranges** — `a..b` / `a..=b`, meaningful in a for-in iterable (not yet a first-class value).
- **`if` / block as expression** — `let x = if (c) a else b`; owned if-expressions balance per edge
  *(→ 47_ifexpr_owned)*.
- **Tuples** — `(a, b)`; construction and returning tuples of heap elements is ARC-correct *(→ 28)*.
- **JSX/NSX** — `jsx_element` exists 🔎 for hypermedia views; not corpus-covered.

---

## 8. Modules & visibility

- **Import:** `import assert;`, `import collections.map;` — dotted paths address nested stdlib modules.
  Names are used qualified by the last segment: `map.Map<K,V>()`, `bson.BsonDocument{…}`.
  - A path segment is normally an identifier, but a **version directory** may be a bare integer:
    `import crypto.tls.13.tls;` addresses `crypto/tls/13/tls.nova`, qualified as `tls.*`. The integer
    may not be the first segment.
- **Compiler-provided `platform` module** *(→ this session)* — `import platform;` resolves to a module the
  compiler **synthesizes** from the compilation target (it is not a file on disk; its values always match
  the actual `--target`, or the host for `--native`). It exports compile-time constants describing the
  target:
  - `platform.os: string` — one of `"darwin"`, `"linux"`, `"windows"`, `"wasm"`.
  - `platform.arch: string` — one of `"aarch64"`, `"x86_64"`, `"wasm32"`.
  - `platform.pointerSize: int` — 8 (or 4 on wasm32).
  - `platform.isDarwin`, `platform.isLinux`, `platform.isWindows`, `platform.isWasm`, `platform.isPosix: bool`
    — convenience predicates (`isPosix` = darwin or linux).

  Use it for **fine-grained**, cross-compilable target choices (a byte offset, an errno value, a
  constant). Because it is compile-time-known, a future release may prune `if (platform.isX) {…}` branches
  whose condition is comptime-false before codegen; **until then, do not place a platform-only `extern`
  behind a `platform` `if`** — the symbol would still be emitted and fail to link on the other OS. For
  divergent-extern code, use target-conditional files (next bullet) instead.
- **Target-conditional files (build constraints)** *(→ this session)* — when resolving module `M`, if a
  file `M_<os>.nova` exists next to `M.nova` (where `<os>` is the target's `platform.os` value), the
  suffixed file is compiled **instead of** the base file. So `import os.backend;` compiles
  `os/backend_darwin.nova` on macOS, `os/backend_linux.nova` on Linux, `os/backend_windows.nova` on
  Windows. This is how whole modules with platform-divergent syscalls (e.g. the reactor's kqueue / epoll
  / IOCP backends) are selected — the non-target files are never parsed, so their externs never reach the
  linker. The base `M.nova` (if present) is the fallback when no suffixed file matches the target.
- **`pub`** marks a declaration exported from its module. **Cross-module visibility is enforced**: a
  non-`pub` **function**, **type** (struct/enum), or **const** referenced from another module is a hard
  error — "not public" *(→ this session, commit 7d7a76d; the stdlib is `pub` where it must be)*.
  - Caveat: function-visibility enforcement has a known hole for **multi-segment imports** (they resolve
    via a fallback that skips the check); type/const enforcement is robust. See §15.

---

## 9. Concurrency

`async` / `await` / `go` over a Boost.Asio coroutine runtime *(→ 10_async_go, 11_channels)*:
```nova
async fn fetch(): int { … }
let f = go fetch();      // launch concurrently → Future
let v = await f;         // suspend until it completes
```
- `async fn` compiles to a native LLVM coroutine.
- `go`/`spawn <async-call>` launches it as a concurrent task, yielding a `Future`.
- `await <future>` suspends the caller until the result is ready.
- **Function coloring.** `await` and `spawn`/`go` are legal **only inside an `async fn`**. Inside an
  `async fn`, an async call **must** be `await`ed or `spawn`ed — a *bare* async call is a compile error
  *(→ expect_fail/bare_async_call_in_async)*. A bare async call block-drives the callee to completion,
  and doing that from within a running coroutine re-enters the event loop → deadlock; the checker
  rejects the shape and the runtime aborts loudly if one is ever reached at runtime.
  - `coroStart(<async-call>)` is a third **detached spawn** form (fire-and-forget; the reactor drives the
    coroutine, no `Future` is returned). Like `spawn`, it consumes the async call rather than block-driving
    it, so it is allowed inside an `async fn` *(→ this session; the reactor accept loop uses it)*.
- **Sync → async at the top.** A **synchronous** `main`/`@test`/top-level caller *may* call an `async fn`
  directly: it is driven to completion (block-drive). This is the one sanctioned bridge from sync into
  async and is safe only at a true top level (not already inside the loop) *(→ 111_async_trait_methods)*.
- **Channels** carry values between tasks *(→ 11_channels)*; **`Atomic<T>`** provides lock-free
  primitives *(→ 31_atomics)*. The runtime is multi-threaded with per-socket strands.

---

## 10. Serialization

`@serializable` structs get **compiler-generated binders** — `<Struct>__bind(ValueSource)` deserializers
built at compile time (no reflection), recursive, from JSON/form/BSON sources *(→ 13_serde,
37_serde_composite_source)*. `serde.json`, `serde.yaml`, `serde.bson` are the codecs; `decimal` round-trips
through BSON as type `0x13` (§3.6).

---

## 11. Program entry & arguments

Entry is `fn main(): void`. The runtime `main(argc, argv)` stashes the args; `env.args(): List<string>`
returns them (`argv[0]` first) — the idiomatic accessor, like Rust's `env::args()` *(→ 54_process_args)*.
A bare `fn main()` cannot receive them directly.

---

## 12. Standard library (index)

`assert` · `string` · `text.utf8` · `collections.{list,map,set,string_builder}` · `math` · `datetime` ·
`env` (get/set/**args**) · `process` · `io.{file,dir}` · `mem.{allocator,arena,memory}` · `crypto`
(SHA-256/512 via wolfCrypt — *(→ 25_crypto)*) · `serde.{json,yaml,bson,source}` · `net.{tcp,tls,asyncio}`
· `concurrency.{channel,asyncchan,atomic,fiber}` · `web.*` (request/response/router/mediator/server —
ASP.NET-style; *(→ 29_http_request_parse)*).

---

## 13. Canonical style — one way per task

- Formatting → template strings `` `${x}` `` (not manual concatenation).
- Iteration → `for (x in xs)` / `for (i in 0..n)` (the `while`-idiom is no longer necessary).
- Fallible functions → return `T | E`; propagate with `try`, handle with `catch`. Never simulate
  exceptions.
- Absence → `T | undefined`; test with `!= undefined`.
- Immutability → `const`; mutability → `let`.

---

## 14. Conformance corpus — what is guaranteed

The 55 cases in `lang/conformance/cases/` are the executable specification; each pins a behavior this
document describes. Highlights: `00`–`09` fundamentals (arithmetic, lists, strings, closures, generics,
floats), `10`–`11` concurrency, `12` traits, `13`/`37` serde, `14` maps, `15`–`16` scoping, `17`–`19`
honest primitives, `28` tuple ARC, `30`/`38` optionals, `31` atomics, `32`/`33` errors, `36` enum
methods, `41`–`49` ownership/ARC edge cases, `50`–`52` decimal128, `53` for-loops, `54` args. A change
that breaks any case fails the gate.

---

## 15. Known gaps (honest)

- **WASM build** ⏳ — `nova build --target wasm` is unverified and currently fails even for trivial
  programs (the WASM codegen branch lacks the test-harness externs and has no `--wasm` conformance run).
  Native is the working default. CLAUDE.md still lists WASM as a strategic target.
- **Function cross-module visibility** — has a multi-segment-import hole (a non-`pub` function reachable
  via `import a.b` is not rejected). Types/consts are enforced robustly (§8).
- **Diagnostics** — an undefined identifier / unresolved call is *rejected*, but sometimes late (at
  codegen) with a terser message rather than a located sema error (F1-7/F2-5 are diagnostics-quality
  work, not correctness).
- **Int local slots** are 64-bit wide (a perf detail); int *arithmetic* is honestly 32-bit *(→ 19)*.
- **`defer`, unions, JSX, tuples-in-general** are present but lightly/not corpus-covered (🔎 above).

These are polish/verification items, not correctness holes in the covered core — see
`foundation-pending.md` for the audited status and `feature-roadmap.md` for what's next.
