# Nova Language: Low-Level Design (LLD)

Status snapshot: 2026-08-18. This is the authoritative, low-level catalogue of the Nova language as it is
actually implemented (compiler in Zig 0.16 to LLVM to native, runtime in C++20, standard library in Nova).
It is written to be precise rather than tutorial: each feature lists its syntax, its semantics, and its
constraints or status. The friendly walkthrough lives in `docs/guide/`; the per-feature rationale lives in
the other `docs/design/` files. Where a claim is subtle it is tagged so a reader knows how sure to be:
**[impl]** verified against the code, **[spec]** stated in the language spec, **[open]** a known gap.

Contents:
1. Language feature catalogue
2. Type system rules
3. Memory and ownership model
4. Concurrency model
5. Modules, packages, and visibility
6. Compiler features
7. Full pipeline (stage by stage)
8. Tooling surface
9. Soundness checks the compiler enforces
10. Non-goals and known gaps

---

## 1. Language feature catalogue

### 1.1 Program structure
- A program is one or more source files. `.nova` holds logic; `.nsx` holds view/markup code and is the
  SAME language, just filed apart (imports resolve `.nova` and its `.nsx` sibling interchangeably). **[impl]**
- Entry point: `fn main(): void`. A library has no `main`. **[impl]**
- Comments: `//` line comments. Statements are terminated by `;` (there is no implicit last-expression
  return; `fn f(): int { 5 }` is a parse error). **[impl]**
- Reserved words (lexer): `async await break case catch class const continue default defer else enum
  errdefer export extern fn for if impl import let match pub return spawn struct switch throw trait try
  union var while`. `var` is retired: use `let` (mutable binding) or `const`. **[impl]**

### 1.2 Primitive types and literals
- Integers are HONEST about width: `int` is 32-bit, `long` is 64-bit. Aliases canonicalise (`int`->i32,
  `long`->i64, `byte`->i8, `short`->i16, and the `u*` names). A heap ADDRESS must be `long`/`ptr`, never
  `int` (an `int + offset` truncates to 32 bits). **[impl]**
- Floating point: `float` (f32) and `double` (f64). **[impl]**
- `bool` (`true`/`false`), `string` (UTF-8, heap object with an 8-byte ARC header), `char`. **[impl]**
- `decimal` / decimal128: exact base-10 arithmetic; no implicit int<->decimal coercion. **[impl]**
- Template literals: `` `text ${expr} more` ``. **[impl]**

### 1.3 Bindings
- `let name = expr;` (mutable) and `const name = expr;` (immutable). Optional type annotation:
  `let x: int = 1;`. **[impl]**
- Destructuring: `let (a, b) = pair;` binds exactly as many names as the tuple has elements (an arity
  mismatch is a type error). **[impl]**
- Shadowing: a later `let` may shadow an earlier binding in the same scope (alpha-renamed internally). **[impl]**

### 1.4 Composite types
- **struct**: a VALUE type (copy-on-assign, passed by value; nested value-struct fields are stored inline,
  Swift-style). Fields, an `init(...)` constructor, methods, `pub` visibility per member. **[impl]**
- **class**: a REFERENCE type (shared, pointer semantics). Same member surface as a struct. The
  struct=value / class=reference distinction is the default and is enforced in codegen. **[impl]**
- **enum**: payload-less variants and payload-carrying variants; methods and dispatch over variants. **[impl]**
- **union**: a type union used for optionals and error unions (see below), and for named multi-payload
  sum types. **[impl]**
- **tuple**: `(a, b, c)`; `(T)` is a parenthesised grouping, NOT a one-tuple. **[impl]**
- **fixed array**: `[value; count]` fills `count` slots. **[impl]**
- **optional**: `T | undefined` (sugar: `T?`). A present value is DISTINCT from `undefined` for every
  width, including a stored `0`/`false`/`0.0` (value optionals are boxed so present-0 never reads as
  absent). **[impl]**
- **error union**: `T | E`: the ok type or an error type. **[impl]**
- **function type**: `(A, B) -> R` for closures/higher-order values. **[impl]**
- **generics**: `List<T>`, `fn ident<T>(v: T): T`. Monomorphised (each instantiation is a concrete type,
  `List<int>` -> `List_int_*`), never type-erased at runtime; an erased body is a link-time fallback that
  globalDCE drops. **[impl]**

### 1.5 Operators and casts
- Arithmetic, comparison, logical, and the null-coalescing `??`. No `^` power operator (use a function).
- Explicit cast: `expr as Type` (also the trait->concrete downcast, see 1.9). **[impl]**

### 1.6 Control flow
- `if`/`else`; `if` is also an EXPRESSION (`let x = if (c) 1 else 0;`). **[impl]**
- `while (cond) { ... }`. **[impl]**
- Four `for` forms: C-style `for (let i = 0; i < n; i = i + 1)`, exclusive range `for (i in 0..n)`,
  inclusive range `for (i in 1..=n)`, and collection `for (x in xs)`. `continue` always runs the increment.
  **[impl]**
- `switch` (statement) and `match` over enum/union variants; `case`/`default`. **[impl]**
- `break` / `continue`. **[impl]**

### 1.7 Functions and closures
- `fn name(p: T, ...): R { ... }`. A non-void function must `return` on every path (or end in a
  loop/return); falling off the end is a compile error (see 9). **[impl]**
- Closures: `(x: int) => x + 1`. They capture BY VALUE. A stored multi-arg closure is callable. **[impl]**
- Higher-order functions: closures and function values pass and return like any value. **[impl]**
- Generic functions: `fn f<T>(...)`; the type-parameter scope is the function's own `<...>`. **[impl]**

### 1.8 Traits
- `trait Name { fn method(self, ...): R; }` with `impl Name for Type { ... }`. **[impl]**
- Dynamic dispatch via a fat pointer `{struct_ptr, vtable}`; vtable slot 0 is the destructor. **[impl]**
- Generic trait objects (`Beh<M>`) erase the type arg for dispatch onto a shared base-name vtable. **[impl]**
- Implicit trait->concrete NARROWING at a call argument is rejected (a trait value may hold any
  implementation); make it explicit with `<expr> as Concrete`. Concrete->trait widening is allowed. **[impl]**

### 1.9 Error handling
- Result-style: a function returns `T | E`. **[impl]**
- `throw`, `try`, `catch`, and `errdefer` (a deferred action that runs only on the error path). **[impl]**
- An error type carries a `message()`. **[spec]**

### 1.10 Optionals in use
- Narrowing: `if (x != undefined) { /* x is T here */ }`. **[impl]**
- `?.` optional member access and `??` null-coalescing (`x ?? default`, yielding the stored value even when
  it is `0`). **[impl]**

### 1.11 Serialization
- `@serializable` on a struct generates bind/serialize code; JSON and BSON are supported, YAML parsing
  exists. Serde is synchronous. **[impl]**

### 1.12 Foreign function interface
- `extern` declarations bind named C symbols (the FFI is how the OS layer and some runtime shims are
  reached). **[impl]**

### 1.13 Attributes
- `@test` marks a test function run by `nova test`. `@serializable` drives serde codegen. (The `@nova_*`
  attributes are internal compiler intrinsics, not user surface.) **[impl]**

---

## 2. Type system rules
- Static, nominal typing. Monomorphised generics; no runtime type erasure. **[impl]**
- Module-scoped type identity: same-named structs in different modules coexist as distinct types
  (module-unique mangled names). **[impl]**
- `int` is 32-bit and `long` is 64-bit everywhere, including the ABI. **[impl]**
- Assignability is governed by one predicate (`assignable`): equal/compatible types, allowed
  numeric widening, struct->trait widening; it REJECTS int narrowing and signedness mismatch. Call
  arguments and returns use the same rule. **[impl]**

---

## 3. Memory and ownership model
- Automatic Reference Counting (ARC), decided in codegen/sema, NOT a garbage collector. Every heap object
  has an 8-byte header: refcount at ptr-8, length at ptr-4. `nova_retain` / `nova_release(ptr, dtor)`. **[impl]**
- Value structs are stored inline (no box) and copy by value; classes are shared references. **[impl]**
- Deterministic cleanup: destructors run at scope exit; nested value-struct fields are destructed
  recursively. **[impl]**
- An OSSA-lite ownership verifier proves release-balance (no leak, no double-free) over 100% of functions;
  it is enforced corpus-wide under `NOVA_OSSA=hard`. Verify memory changes with `--asan`, not only the ARC
  audit. **[impl]**

---

## 4. Concurrency model
- `async`/`await`, and `spawn` (fork, returns a `future<T>`) with `await` (join). Built on LLVM coroutines
  (presplit -> CoroSplit -> `.resume`/`.destroy`). **[impl]**
- Combinators: `when_all`, `selectAny`. **[impl]**
- Channels (`channel<T>`) and an actor model built on channels + coroutines. A generic async method is
  spawnable only from a CONCRETE instantiation. **[impl]**
- `AsyncLock` is the reactor-aware mutex (a blocking mutex inside async code is ~70x slower and must not be
  used). **[impl]**
- The web server is SINGLE-reactor per process; scale is horizontal (instances behind the proxy), not
  in-process worker threads. Actors/channels/`std::thread` still exist for non-web workloads. **[impl]**
- Reactor backends: kqueue (macOS), epoll and io_uring (Linux), IOCP (Windows), selected per target. **[impl]**

---

## 5. Modules, packages, and visibility
- `import name;` resolves by the dependency's DECLARED name; `pub` controls cross-module visibility. **[impl]**
- Standard library is written in Nova and imported by short names (`string`, `list`, `map`, `json`, ...). **[impl]**
- Package manager (see `pkg-manager.md`): `project.json` dependencies are `url[#ref]` strings; a flat
  `project.lock.json` records the declared name and the resolved git SHA per dep; the version-keyed cache is
  `~/.nova/cache/<name>-<sha8>`; resolution is transitive and cache-deduped; `nova build`/`nova test` honour
  the lock and never move a pin; imports are resolved PER OWNING PACKAGE so two versions of a dependency
  coexist. Commands: `get`, `restore`, `update`, `publish`. **[impl]**

---

## 6. Compiler features
The compiler (`nova`) is a single Zig 0.16 binary that lowers Nova to LLVM IR to a native object to a
linked executable. Feature surface, all **[impl]** unless noted:

- **Targets**: native macOS/Linux/Windows on x86_64 and arm64 (primary); WebAssembly via `wasm-ld`
  (secondary, best-effort). Cross-compilation from one host to any target (`--target windows-x86_64` etc.)
  via the bundled `zig c++` toolchain; a Windows `.exe` is a real PE32+.
- **Diagnostics**: type errors carry `file:line:col` and a source line with a caret; a user error is a
  clean one-liner, not a Zig stack trace (`userErrorHint` maps the internal error set).
- **Incremental build cache**: `nova build` hashes the sources + profile + link libs + the COMPILER BINARY
  mtime, so an unchanged project short-circuits, and any toolchain change forces a rebuild.
- **Demand-driven monomorphisation**: only the generic methods reachable from `main()` are emitted (the
  reachability worklist), instead of the whole method surface of every instantiation then globalDCE.
- **Object emission**: one combined `<app>.o` by default; `--split-objects` for per-file objects with a
  content-hash cache. `--emit-llvm` writes the `.ll`.
- **Debug info**: DWARF line tables + DITypes in debug builds (O0); driven in-editor by `lldb-dap`.
- **Sanitiser / verifier gates**: `--asan` (AddressSanitizer link), `--tsan` (ThreadSanitizer),
  `--arc` (ARC leak audit, baseline-gated), and `NOVA_OSSA=hard` (ownership release-balance verifier,
  corpus-wide). Coverage instrumentation is available via `codegen/coverage.zig`.
- **Formatter**: `nova fmt` (frontend/formatter.zig). **LSP**: `nls` reuses the frontend for
  completion/hover/definition/symbols/rename/refs/code-actions/semantic-tokens.
- **Self-contained delivery**: `zig build -Dstatic-llvm` links LLVM's component archives into a
  ~132 MB self-contained `nova`; release archives bundle `nova` + `nls` + stdlib + a checksum.

## 7. Full pipeline (stage by stage)
`nova build <file>` runs these stages in order (`src/builder.zig` orchestrates; `src/pipeline.zig` does
loading/merge/codegen entry):

1. **Load + resolve imports + merge** (`pipeline.loadProgram`): recursively resolve each `import` to a
   source path (stdlib short-names, importer-relative, local `packages/`, then the version-aware package
   cache when a lockfile exists: §5), parse each file to an AST, and MERGE all reachable files into one
   program (declarations + a `merged.nova` text for diagnostics). Cycles terminate via a visited set.
2. **Generate synthetic code**: `generateSerdeBinders` emits bind/serialize functions for `@serializable`
   types; `generateMediatorDispatch` emits the web mediator/router dispatch (`<mediator-generated>` /
   `<rmediator-generated>` synthetic sources). A synthetic `platform` module supplies target constants.
3. **Alpha-rename** (`sema/alpha.zig`): make `let`-shadowing unambiguous by renaming.
4. **Assign expression ids** (`sema/ids.zig`): every AST expression gets a stable id for the typed-IR
   overlay.
5. **Type check** (`type_checker.zig`): arg count + cross-category arg types, unknown-type rejection,
   missing-return, trait->concrete narrowing, tuple-destructure arity, return-type mismatch, ambiguous
   cross-module calls, duplicate type params. Diagnostics collected with spans.
6. **Semantic analysis / typed IR** (`sema/sema.zig` + `shadow.zig`): the authoritative TypeId engine
   (infer / symbols / subst / builtins / inst_disp). `NOVA_SEMA_SHADOW` diffs the name engine vs the
   TypeId engine; the shadow gate fails on any divergence (ownership must never be decided by name).
7. **Monomorphise, reachability-pruned** (`sema/mono.zig` + `reach.zig`): a worklist instantiates generic
   types/methods reachable from `main()` roots only. `lower.zig` handles builtin generics (`future<T>`).
8. **Ownership analysis** (`sema/ownership.zig`, `escape.zig`, `ossa/lower.zig`): escape analysis (report),
   and the OSSA-lite lowering + release-balance verifier (leak / double-consume / imbalance), enforced
   under `NOVA_OSSA=hard`.
9. **Code generation** (`backend/codegen/`): `llvm_codegen.zig` walks the typed program; `declarations.zig`
   emits functions/types and drives object emission; `expressions.zig` / `statements.zig` lower bodies;
   `arc.zig` inserts retain/release and destructors; `types.zig` maps Nova types to LLVM (value-struct
   inline layout, honest-int widths); DWARF DITypes/line tables in debug builds. Output: one LLVM module
   -> optimisation passes (O0 debug / O3 release) -> native object(s).
10. **Link**: in-process LLD or `clang++` links the object(s) with the C++20 runtime (`libnovacore.a`, the
    Boost.Asio-free reactor runtime, TLS, channels, actors) into the final binary; WASM via `wasm-ld`;
    cross-targets via bundled `zig c++` (adds the per-OS link libs). ASAN/TSAN link against the sanitised
    runtime when requested.

Debug hooks: `NOVA_DUMP_MERGED=1` writes the merged IR; `NOVA_SEMA_SHADOW=1` diffs the type engines;
`NOVA_IO_WATCHDOG` / `NOVA_CRASH_TRACE` diagnose the async runtime.

---

## 8. Tooling surface
- CLI: `nova <file>`, `nova build [--release]`, `nova test`, `nova init <console|web|desktop>`,
  `nova get|restore|update|publish`, `nova fmt`, `nova add feature`. User-facing build options are CLI
  flags (`--asan`, `--split-objects`, `--prune`, `--keep-obj`, `--emit-llvm`, `--dump-merged`,
  `--mem-stats`), not environment variables. **[impl]**
- In-editor debugger: DWARF line tables + DITypes emitted in debug builds, driven by `lldb-dap` from the
  scaffolded VS Code launch config; optional Python data-formatters give C#-quality value display (strings,
  `List`/`Map`/`Set` element expansion, struct fields, borrowed `str.Str` text). **[impl]**
- Language server (`nls`, pure-Zig, bundled in the release archives) and a VS Code extension for syntax and
  NSX. **[impl]**

---

## 9. Soundness checks the compiler enforces
- Argument COUNT per call; a cross-CATEGORY scalar argument (a `string` where an `int` is expected) is
  rejected rather than miscompiled to garbage. **[impl]**
- Unknown TYPE names in a function signature or a struct field are rejected (`unknown type 'Frob'`), scoped
  to where the type-parameter context is exact; compiler-generated sources are exempt. **[impl]**
- A non-void function that can finish without returning a value is rejected (conservative all-paths
  analysis: loops, `switch`, and any expr-statement are treated as returning, so nothing valid is flagged).
  **[impl]**
- Trait->concrete narrowing at a call argument; tuple destructure arity; return-type mismatch; ambiguous
  cross-module calls; the OSSA ownership verifier. **[impl]**

---

## 10. Non-goals and known gaps
- **WASM is a secondary, best-effort target**; native is primary. **[impl]**
- **Actors on the single-threaded web reactor are deliberately not the model**: actors are for M:N
  threadpool workloads, not the single-reactor web server. **[design]**
- **Package supply-chain trust**: the recursive fetch trusts each package's declared dep list; `nova
  vendor` is the recorded first future step. **[open]**
- **Missing-return and unknown-type checks are scoped**: missing-return covers functions (methods and
  `let`-annotation unknown-types are a later pass). **[open]**
- **Three corpus runtime cases remain** (an actor `mutex lock`, `189_epoll` off-Linux by design, a nested
  value-optional aggregate); the actor one is low-priority given the concurrency model above. **[open]**
- No registry, no module proxy, no semver range solving (exact git-ref pins only). **[design]**
