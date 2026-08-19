# Nova Language: Low-Level Design (LLD)

Status snapshot: 2026-08-19. This is the authoritative, low-level catalogue of the Nova **language** as it
is actually implemented (compiler in Zig 0.16 to LLVM to native, runtime in C++20, standard library in
Nova). It is written to be precise rather than tutorial: each feature lists its syntax, its semantics, and
its constraints or status.

### Where each thing is documented

This document is the LANGUAGE reference. Two companions carry the depth that used to be crammed in here:

- **How the compiler is built**, stage by stage, component by component: `compiler-lld.md`. That is where
  the pipeline, the type engine, monomorphisation, ownership verification, and codegen are explained in
  full. This document only summarises the compiler (section 6) and links across.
- **The friendly walkthrough** for users: `docs/guide/`. The per-feature rationale: the other
  `docs/design/` notes.

### How to read this document

Each feature lists its syntax and semantics, then a short **Maintainer's note** giving the three things you
need before touching it: **where** it lives in code, **why** it is built that way, and **how to change it
safely** (the test or gate that proves it). Confidence tags mark how sure a claim is: **[impl]** verified
against the code, **[spec]** stated in the language spec, **[open]** a known gap, **[design]** a settled
decision.

Two rules override everything below:

1. **Run the corpus before and after every change.** From `lang/`: `conformance/run.sh -j` (fast positive
   gate, about two minutes), `conformance/run.sh --asan` (memory gate, needs `NOVA_ASAN=1 zig build`
   first), and `gate.sh` (the whole battery).
2. **Ownership is decided from TYPES, never from the spelled name of a type.** Keying behaviour on a string
   like `"Str"` or `"List"` caused a class of corruption bugs. The authoritative engine is the TypeId engine
   in `src/frontend/sema/`; `NOVA_SEMA_SHADOW=1` proves the name and TypeId engines still agree.

### Contents

1. Language feature catalogue
2. Type system rules
3. Memory and ownership model
4. Concurrency model
5. Modules, packages, and visibility
6. Compiler and tooling (summary; full detail in `compiler-lld.md`)
7. Soundness checks the compiler enforces
8. Non-goals and known gaps

---

## 1. Language feature catalogue

### 1.1 Program structure
- A program is one or more source files. `.nova` holds logic; `.nsx` holds view/markup code and is the
  SAME language, just filed apart (imports resolve `.nova` and its `.nsx` sibling interchangeably). **[impl]**
  *Maintainer's note: import resolution and the `.nova`/`.nsx` interchange live in `src/pipeline.zig`
  (`resolveImportPath` and its helpers). They are the same grammar because both are handed to the one
  parser in `src/frontend/parser.zig`; `.nsx` just enters through the JSX branch. If you add a new source
  extension, do it in the resolver, not the parser: the parser should stay ignorant of file naming.*
- Entry point: `fn main(): void`. A library has no `main`. **[impl]**
  *Maintainer's note: `main` is found by name during code generation as the root of the reachability
  worklist (`src/frontend/sema/reach.zig` seeds from it, see stage 3.10 in `compiler-lld.md`). A library simply has no
  such root, so nothing is emitted as an entry point. Do not special-case `main` anywhere else; treating it
  as "just the reachability root" is what keeps libraries and apps on one code path.*
- Comments: `//` line comments. Statements are terminated by `;` (there is no implicit last-expression
  return; `fn f(): int { 5 }` is a parse error). **[impl]**
  *Maintainer's note: this is a lexer plus parser decision (`src/frontend/lexer.zig` drops `//` to
  end-of-line; the parser requires the trailing `;`). The "no implicit return" rule is deliberate: it keeps
  the missing-return check in section 7 simple, because a block's value is never a function's result.
  Changing it would mean re-teaching `stmtDefinitelyReturns` in `type_checker.zig` what a tail expression is.*
- Reserved words (lexer): `async await break case catch class const continue default defer else enum
  errdefer export extern fn for if impl import let match pub return spawn struct switch throw trait try
  union var while`. `var` is retired: use `let` (mutable binding) or `const`. **[impl]**
  *Maintainer's note: the keyword set is a table in `src/frontend/lexer.zig`. Adding a keyword is a breaking
  change: any existing program using that word as an identifier stops compiling, so prefer a contextual
  keyword (recognised only in the position where it is meaningful) unless you truly need a hard reservation.
  `var` is kept in the table only so an old program gets a clear "use let/const" message instead of a
  confusing parse error.*

### 1.2 Primitive types and literals
- Integers are HONEST about width: `int` is 32-bit, `long` is 64-bit. Aliases canonicalise (`int`->i32,
  `long`->i64, `byte`->i8, `short`->i16, and the `u*` names). A heap ADDRESS must be `long`/`ptr`, never
  `int` (an `int + offset` truncates to 32 bits). **[impl]**
  *Maintainer's note: the alias-to-LLVM-width mapping is in `src/frontend/sema/` (the TypeId builtins) and
  realised in `src/backend/codegen/types.zig`. The reason for honesty is a class of heisenbug we have paid
  for repeatedly: storing a pointer in an `int` emits an LLVM `trunc i64->i32`, so it works until an address
  climbs past 4 GB and then SIGSEGVs on a value that looks fine in the debugger. If you write runtime shims
  or FFI that hand back a pointer, its Nova type MUST be `long` or `ptr`. See the "int is 32-bit" gotcha in
  `lang/CLAUDE.md` for the concrete failure.*
- Floating point: `float` (f32) and `double` (f64). **[impl]**
  *Maintainer's note: also mapped in `types.zig`. There is deliberately no implicit float widening surprise:
  the assignability predicate in section 2 governs what coerces. If you add a numeric coercion, add it
  there, once, so calls, returns, and assignments all agree.*
- `bool` (`true`/`false`), `string` (UTF-8, heap object with an 8-byte ARC header), `char`. **[impl]**
  *Maintainer's note: `string` is a heap object under ARC, so it is retained and released like any other
  reference; the header layout (refcount at ptr-8, length at ptr-4) is shared by every heap object and is
  fixed by the runtime in `src/runtime/` (`runtime_str.h`, `nova_abi.h`). Do not invent a second string
  representation: the borrowed `str.Str` VIEW (section 2 and the debugger note) is the intended way to pass
  a substring without copying, and it is a `{ptr, len}` view, not an owned object.*
- `decimal` / decimal128: exact base-10 arithmetic; no implicit int<->decimal coercion. **[impl]**
  *Maintainer's note: the arithmetic lives in `src/runtime/decimal.cpp`, surfaced to Nova through the
  stdlib. The no-implicit-coercion rule is a correctness choice: silently turning an `int` into a `decimal`
  (or back) is where money bugs come from, so a conversion must be spelled out. Keep it that way; if a
  caller finds it verbose, give them an explicit constructor, not an implicit rule.*
- Template literals: `` `text ${expr} more` ``. **[impl]**
  *Maintainer's note: lexed and parsed in `src/frontend/lexer.zig` and `parser.zig` into a concatenation
  of the literal chunks and the `${...}` expressions, then lowered like a normal string build. If you change
  the interpolation syntax, the lexer's template-string state machine is the only place that needs to know.*

### 1.3 Bindings
- `let name = expr;` (mutable) and `const name = expr;` (immutable). Optional type annotation:
  `let x: int = 1;`. **[impl]**
  *Maintainer's note: parsed in `parser.zig`; the mutable/immutable distinction is carried on the AST binding
  node and checked by `type_checker.zig`. When a type annotation is present, the checker uses it as the
  expected type for the initialiser (this is how numeric-literal typing is pinned). A `const` that is
  initialised by a function call is memoised so re-evaluation does not leak (see the `const-reeval-leak`
  memory note); if you touch const lowering, keep that memoisation.*
- Destructuring: `let (a, b) = pair;` binds exactly as many names as the tuple has elements (an arity
  mismatch is a type error). **[impl]**
  *Maintainer's note: the arity check is in `type_checker.zig` and is one of the section-7 soundness gates.
  The known incompleteness is that the OSSA ownership verifier does NOT yet track per-binding ownership
  THROUGH a destructuring pattern (section 3), so a leak that only happens via `let {a,b} = ...` is not
  caught. If you extend destructuring, extend the ownership lowering in `sema/ossa/` at the same time or you
  widen that blind spot.*
- Shadowing: a later `let` may shadow an earlier binding in the same scope (alpha-renamed internally). **[impl]**
  *Maintainer's note: shadowing is made unambiguous by `src/frontend/sema/alpha.zig`, which renames the
  second `let` to a fresh internal name before any type or ownership reasoning runs. This is why nothing
  downstream needs to worry about two live bindings sharing a name. If you add a construct that introduces
  bindings (a new loop form, a pattern), make sure alpha-renaming visits it, or later passes will confuse
  the two.*

### 1.4 Composite types
- **struct**: a VALUE type (copy-on-assign, passed by value; nested value-struct fields are stored inline,
  Swift-style). Fields, an `init(...)` constructor, methods, `pub` visibility per member. **[impl]**
  *Maintainer's note: value semantics are realised in `src/backend/codegen/types.zig` (inline layout) and
  `arc.zig` (copy-on-assign and recursive destruction of nested value fields). This was hard-won: value
  structs were once gated off, and `let b = a` used to alias instead of copy. The regression guard is the
  corpus plus `--asan`; a struct change that is green on `run.sh -j` but red on `run.sh --asan` almost
  always means you reintroduced aliasing or dropped a nested destructor. Some escape-set structs (returned
  from a constructor, captured by a trait, serialised) may still be handled by reference; that boundary is
  documented in the `struct-value-semantics-fix` memory note.*
- **class**: a REFERENCE type (shared, pointer semantics). Same member surface as a struct. The
  struct=value / class=reference distinction is the default and is enforced in codegen. **[impl]**
  *Maintainer's note: the fork between value and reference is decided once, from the declaration kind, and
  flows through `types.zig`/`arc.zig`. Keep the decision keyed on the TypeId, never on the spelled type
  name: the `semantics-from-strings` memory note records that name-keyed ownership is exactly how corruption
  crept in before.*
- **enum**: payload-less variants and payload-carrying variants; methods and dispatch over variants. **[impl]**
  *Maintainer's note: payload-carrying enums are lowered as tagged unions in `types.zig`; multi-payload
  variants work (see the `multipayload-enums-work` note). Dispatch over variants is `match`/`switch`
  (section 1.6). If you add a variant shape, the tag layout and the `match` exhaustiveness both need to
  agree, so change them together.*
- **union**: a type union used for optionals and error unions (see below), and for named multi-payload
  sum types. **[impl]**
  *Maintainer's note: optionals (`T | undefined`) and error unions (`T | E`) are the two special unions the
  compiler understands structurally; a named union is the general form. The value-optional boxing rule
  (next bullet) is the subtle part, so read that before touching union lowering in `types.zig`.*
- **tuple**: `(a, b, c)`; `(T)` is a parenthesised grouping, NOT a one-tuple. **[impl]**
  *Maintainer's note: the "one-tuple does not exist" rule is in `parser.zig` and matters because a stray
  `(T)` used to be parsed as a nested optional and SIGSEGV (fixed, guarded by conformance case 363). If you
  rework tuple parsing, keep that case green.*
- **fixed array**: `[value; count]` fills `count` slots. **[impl]**
  *Maintainer's note: lowered to an inline aggregate in `types.zig`. This is the fixed-size array; growable
  sequences are the stdlib `List<T>` (a generic on a `RawBuffer`), which is a different thing. Do not
  conflate them.*
- **optional**: `T | undefined` (sugar: `T?`). A present value is DISTINCT from `undefined` for every
  width, including a stored `0`/`false`/`0.0` (value optionals are boxed so present-0 never reads as
  absent). **[impl]**
  *Maintainer's note: this is the single most bug-prone corner of the type system, so tread carefully. A
  REFERENCE optional uses the null pointer for `undefined` cheaply. A VALUE optional (`int | undefined`)
  cannot, because `0` is a legal present value, so it is BOXED so that "present 0" and "absent" are
  physically different. The regression guard is `conformance/cases/127_value_optional_zero.nova`
  (`test_param_widths` covers the value-optional PARAMETER ABI specifically). Two live traps recorded in the
  memory notes: passing a value-optional call result DIRECTLY as a nested call argument can crash (bind it to
  a local first), and value-optional zero has a long bug history. If you change optional lowering, run case
  127 under both `run.sh -j` and `run.sh --asan`.*
- **error union**: `T | E`: the ok type or an error type. **[impl]**
  *Maintainer's note: the same union machinery as optionals, with the error arm carrying a `message()`. The
  surface for producing and consuming them is `throw`/`try`/`catch`/`errdefer` (section 1.9).*
- **function type**: `(A, B) -> R` for closures/higher-order values. **[impl]**
  *Maintainer's note: closures capture BY VALUE (`closure-capture-by-value` note), and are represented as an
  environment plus a code pointer. A stored multi-arg closure is callable (this once SIGSEGV'd; fixed via
  type-inference lookahead). If you change the closure representation, the capture-by-value contract is the
  thing callers rely on, so do not quietly switch to capture-by-reference.*
- **generics**: `List<T>`, `fn ident<T>(v: T): T`. Monomorphised (each instantiation is a concrete type,
  `List<int>` -> `List_int_*`), never type-erased at runtime; an erased body is a link-time fallback that
  globalDCE drops. **[impl]**
  *Maintainer's note: monomorphisation is `src/frontend/sema/mono.zig`, reachability-pruned via `reach.zig`
  (`compiler-lld.md` stage 3.9). Mono is MANDATORY: the type-erased body exists only as an `internal`-linkage fallback
  that LLVM's globalDCE deletes, so do not rely on it at runtime. The reason instantiations get distinct
  symbol names (`List_int_*`) is that the mangle prefix is PATH-derived, which is also what makes two package
  versions coexist for free (section 5). If you touch mangling, you touch multi-version packaging.*

### 1.5 Operators and casts
- Arithmetic, comparison, logical, and the null-coalescing `??`. No `^` power operator (use a function).
  *Maintainer's note: operators are parsed with a precedence table in `parser.zig` and lowered in
  `src/backend/codegen/expressions.zig`. `^` is intentionally not exponentiation (it reads as xor to most
  programmers and we have neither); the `crypto-x2` note records this. If you add an operator, add it to the
  precedence table and the expression lowering together, and prefer not to reuse a symbol with a common other
  meaning.*
- Explicit cast: `expr as Type` (also the trait->concrete downcast, see 1.9). **[impl]**
  *Maintainer's note: `as` covers both a numeric cast and the trait-to-concrete narrowing. The narrowing case
  is required precisely because implicit trait-to-concrete is REJECTED (section 1.8): a trait value can hold
  any implementation, so making the caller write `as Concrete` is the point where they take responsibility.
  The check is in `type_checker.zig`; the codegen for the downcast is in `expressions.zig`.*

### 1.6 Control flow
- `if`/`else`; `if` is also an EXPRESSION (`let x = if (c) 1 else 0;`). **[impl]**
  *Maintainer's note: parsed in `parser.zig`; as an expression it must have both arms with a common type,
  checked in `type_checker.zig` and lowered as a value in `expressions.zig` (a phi/select). If you use `if`
  where a value is expected, the missing-`else` case is a type error, not a silent `undefined`.*
- `while (cond) { ... }`. **[impl]**
  *Maintainer's note: lowered in `src/backend/codegen/statements.zig` to a condition block plus a body block.
  For the missing-return analysis (section 7), a `while (true)` with no `break` is treated as never falling
  through; the conservative rule there errs towards "this returns" so it never false-accuses.*
- Four `for` forms: C-style `for (let i = 0; i < n; i = i + 1)`, exclusive range `for (i in 0..n)`,
  inclusive range `for (i in 1..=n)`, and collection `for (x in xs)`. `continue` always runs the increment.
  **[impl]**
  *Maintainer's note: all four are desugared in `statements.zig` down to a condition-body-step shape. The
  "`continue` runs the increment" rule is the one to preserve: it means `continue` jumps to the STEP block,
  not the condition, so a C-style loop cannot livelock by skipping `i = i + 1`. The collection form iterates
  by index and reads each element; the `get`-versus-`at` element-fetch fix (task #170) lives here, so if you
  change collection iteration, check that the element is read, not owned-then-dropped.*
- `switch` (statement) and `match` over enum/union variants; `case`/`default`. **[impl]**
  *Maintainer's note: `match` over an enum/union checks the arm tags; lowering is in `statements.zig` and
  `expressions.zig`. If you add a variant to an enum, an existing `match` without a `default` should force
  the author to handle it. Keep exhaustiveness honest: silently accepting a missing arm is how a new variant
  gets ignored at runtime.*
- `break` / `continue`. **[impl]**
  *Maintainer's note: these target the innermost loop; they are lowered as branches to the loop's exit/step
  blocks in `statements.zig`. There is no labelled break, by choice.*

### 1.7 Functions and closures
- `fn name(p: T, ...): R { ... }`. A non-void function must `return` on every path (or end in a
  loop/return); falling off the end is a compile error (see 9). **[impl]**
  *Maintainer's note: the "must return on every path" rule is `stmtDefinitelyReturns` /
  `blockDefinitelyReturns` in `type_checker.zig`. It is deliberately CONSERVATIVE: loops, `switch`, and any
  expression-statement are treated as returning, so it never rejects a valid function (zero false positives
  on first corpus run). That means it can MISS a genuinely-missing return in an exotic shape; widening it is
  safe only if you re-run the whole corpus and the `missing_return` expect_fail case stays red. Erring
  towards acceptance is intentional: a false accusation blocks a correct program, a miss is caught later.*
- Closures: `(x: int) => x + 1`. They capture BY VALUE. A stored multi-arg closure is callable. **[impl]**
  *Maintainer's note: capture-by-value is the contract (see 1.4 function type). The multi-arg-stored-closure
  crash was fixed with type-inference lookahead; the guard is in the corpus. If you change capture, update
  the `closure-capture-by-value` memory note and the guard case together.*
- Higher-order functions: closures and function values pass and return like any value. **[impl]**
  *Maintainer's note: a function value is just its `(env, code-ptr)` pair, so passing/returning it is
  ordinary value flow through `expressions.zig`. Nothing special is needed beyond keeping the environment
  alive under ARC while the closure is live.*
- Generic functions: `fn f<T>(...)`; the type-parameter scope is the function's own `<...>`. **[impl]**
  *Maintainer's note: the type parameters are scoped to the function and are the whitelist used by the
  unknown-type check (section 7), so a `T` inside the signature is not flagged as an unknown type. This is
  why `rejectUnimplementedType` is passed the function's `tparams`. Monomorphisation instantiates the body
  per concrete call from `mono.zig`.*

### 1.8 Traits
- `trait Name { fn method(self, ...): R; }` with `impl Name for Type { ... }`. **[impl]**
  *Maintainer's note: trait declarations and impls are matched in `type_checker.zig`/`sema`, and the method
  tables are built during codegen (`declarations.zig`). Async trait methods and dynamic dispatch through a
  trait-typed FIELD are supported and gated (used by the DB `Connection`/`Driver` seam). If you add a trait
  feature, the DB drivers in `packages/nova-*` are the realistic stress test.*
- Dynamic dispatch via a fat pointer `{struct_ptr, vtable}`; vtable slot 0 is the destructor. **[impl]**
  *Maintainer's note: the fat-pointer layout and "slot 0 is the destructor" convention are fixed in codegen.
  Slot 0 being the destructor is what lets ARC release a trait object without knowing its concrete type, so
  do NOT reorder the vtable to put a method in slot 0. If you add vtable slots, append them.*
- Generic trait objects (`Beh<M>`) erase the type arg for dispatch onto a shared base-name vtable. **[impl]**
  *Maintainer's note: `Beh<M>` shares one base-name vtable (`_vtable_S_Trait`) across its `M` instantiations
  for dispatch. The important consequence, recorded in `lang/CLAUDE.md`: a generic ASYNC method is only
  spawnable from a CONCRETE instantiation, not from an erased-`M` context, because the coroutine needs the
  real frame layout. If a `spawn` on a generic method fails to compile, this is usually why.*
- Implicit trait->concrete NARROWING at a call argument is rejected (a trait value may hold any
  implementation); make it explicit with `<expr> as Concrete`. Concrete->trait widening is allowed. **[impl]**
  *Maintainer's note: the rejection is in `type_checker.zig` and is one of the section-7 gates. Widening
  (concrete to trait) is always safe and allowed; narrowing (trait to concrete) is the unsafe direction, so
  it must be spelled `as Concrete`. Do not "help" callers by making narrowing implicit; it would let a value
  of the wrong implementation through with no diagnostic.*

### 1.9 Error handling
- Result-style: a function returns `T | E`. **[impl]**
  *Maintainer's note: this is the error-union special-case of section 1.4, so it rides the same union
  lowering in `types.zig`. The model is documented in the `e1-error-model` memory note.*
- `throw`, `try`, `catch`, and `errdefer` (a deferred action that runs only on the error path). **[impl]**
  *Maintainer's note: lowered in `statements.zig`. `errdefer` is the subtle one: it runs ONLY when the scope
  exits via the error path, unlike `defer` which always runs. It exists so you can release a
  half-constructed resource on failure without a manual flag. If you change defer/errdefer lowering, verify
  the release count with `--asan`, because a mis-lowered errdefer either leaks (never runs) or double-frees
  (runs on the success path too).*
- An error type carries a `message()`. **[spec]**
  *Maintainer's note: this is spec-level surface, realised by the error types in the stdlib. If you add a
  new error type, giving it a `message()` keeps `catch` blocks uniform.*

### 1.10 Optionals in use
- Narrowing: `if (x != undefined) { /* x is T here */ }`. **[impl]**
  *Maintainer's note: the narrowing (flow-typing `x` to `T` inside the guarded block) is done in the type
  checker/sema. It only understands the direct `!= undefined` / `== undefined` shape; a narrowing hidden
  behind a helper function is not seen. Keep the recognised shapes explicit and small.*
- `?.` optional member access and `??` null-coalescing (`x ?? default`, yielding the stored value even when
  it is `0`). **[impl]**
  *Maintainer's note: `??` must yield the STORED value when it is a present `0`/`false`/`0.0`, which is only
  correct because value optionals are boxed (section 1.4). This is the same invariant as case 127; if `x ??
  d` ever returns `d` for a present zero, the boxing broke, not the operator.*

### 1.11 Serialization
- `@serializable` on a struct generates bind/serialize code; JSON and BSON are supported, YAML parsing
  exists. Serde is synchronous. **[impl]**
  *Maintainer's note: the code is GENERATED, in `pipeline.zig` `generateSerdeBinders` (around line 944),
  before type checking, so the generated `__bind`/serialize functions are type-checked like hand-written
  code. This is also the ORM bind path: a `@serializable` struct with `Str` fields binds ZERO-COPY from the
  DB wire (the `orm-str-and-index-hoist` note is the authority on why that is throughput-neutral). Serde is
  synchronous by design; do not make it async, the drivers depend on the sync bind. If you change the struct
  layout the generator assumes, regenerate and run the serde corpus cases plus `--asan` (there is a known
  YAML-parse leak tracked separately).*

### 1.12 Foreign function interface
- `extern` declarations bind named C symbols (the FFI is how the OS layer and some runtime shims are
  reached). **[impl]**
  *Maintainer's note: `extern` binds C symbols BY NAME only, no C++ name mangling and no class ABI. This is
  why every native dependency is reached through a thin `extern "C"` shim (the runtime `.cpp` files in
  `src/runtime/`, and the pattern the Skia/UI direction would follow, see the pause note). If you need a C++
  library, write a small `extern "C"` wrapper and bind that; you cannot bind a mangled C++ symbol directly.
  The `ffi-landed` and `m14-max-ffi-reach` notes cover the reach.*

### 1.13 Attributes
- `@test` marks a test function run by `nova test`. `@serializable` drives serde codegen. (The `@nova_*`
  attributes are internal compiler intrinsics, not user surface.) **[impl]**
  *Maintainer's note: `@test` discovery is `collectTestFunctions` in `src/tester.zig`. It runs ONLY the
  `@test` functions defined in the files the user asked to test (a given file, or the scanned project), NOT
  the `@test`s that live in the stdlib or in imported packages. Those get merged into the program like any
  import, but the collector filters by `fd.span.file` (set by the parser to the source path) against the
  user's file set, because the stdlib's own tests are already covered by the conformance corpus and re-running
  them on every `nova test` is noise. `nova test` also SKIPS `main()`, a measurement trap worth remembering
  (use `NOVA_ARC_AUDIT=1` to see survivors, per the `arc-measurement-traps` note). If you change how files
  are loaded, keep the filter keyed on `span.file` matching the user's requested paths. `@serializable` is
  consumed by the generator in `pipeline.zig`. The `@nova_*` intrinsics are compiler-internal.*

---

## 2. Type system rules

The authoritative type engine lives in `src/frontend/sema/`. Codegen CONSUMES its decisions; it never makes
them. Full detail on the engine and where these rules run in the pipeline: `compiler-lld.md` section 3.8.

### 2.1 Static, nominal typing
Static, nominal typing. Monomorphised generics; no runtime type erasure. **[impl]**

*Maintainer's note: the engine is the TypeId engine under `src/frontend/sema/` (`infer.zig`, `symbols.zig`,
`subst.zig`, `builtins.zig`, `inst_disp.zig`). "Nominal" means identity is by declaration, not shape, so two
structs with the same fields are different types. When you add a typing rule, add it here and NOT in codegen.*

### 2.2 Module-scoped type identity
Same-named structs in different modules coexist as distinct types (module-unique mangled names). **[impl]**

*Maintainer's note: the mangle prefix comes from the source file path (`getModulePrefix`), so `a/store.nova`'s
`Row` and `b/store.nova`'s `Row` mangle apart automatically. This is load-bearing for two features: it
prevents cross-module symbol collisions, and it is exactly what makes two package versions coexist (section
5). A same-name-across-modules dispatch bug was fixed once (`async-owned-struct-uaf` note); if you change
mangling, that class of bug is what to re-test.*

### 2.3 Honest integer widths
`int` is 32-bit and `long` is 64-bit everywhere, including the ABI. **[impl]**

*Maintainer's note: honoured end-to-end in `types.zig` and the runtime ABI headers (`nova_abi.h`). "Even in
the ABI" is the part people forget: a runtime shim that returns a 64-bit handle must be typed `long` on the
Nova side or the value is truncated at the boundary. See 1.2.*

### 2.4 One assignability predicate
Assignability is governed by one predicate (`assignable`): equal/compatible types, allowed numeric widening,
struct->trait widening; it REJECTS int narrowing and signedness mismatch. Call arguments and returns use the
same rule. **[impl]**

*Maintainer's note: there is deliberately ONE predicate (`assignable` in `type_checker.zig`) so that
assignment, call arguments, and returns can never disagree about what coerces. If you need a new coercion,
change this one function; do not add a special case at the call site, or you create a rule that holds for
arguments but not assignments (or vice versa) and that inconsistency becomes a bug report. It rejects int
narrowing and signedness mismatch on purpose: both silently corrupt values.*

---

## 3. Memory and ownership model

Full detail on where ARC is inserted, how ownership is verified, and the runtime primitives:
`compiler-lld.md` sections 4.2 (ARC) and 3.12 (ownership verification).

### 3.1 Automatic Reference Counting (ARC)
ARC is decided in codegen/sema, NOT a garbage collector. Every heap object has an 8-byte header: refcount at
ptr-8, length at ptr-4. `nova_retain` / `nova_release(ptr, dtor)`. **[impl]**

*Maintainer's note: the retain/release insertion is `src/backend/codegen/arc.zig`; the primitives live in the
runtime (`src/runtime/`, header shape in `nova_abi.h`/`runtime_str.h`). ARC is decided at COMPILE time, so a
leak or double-free is a codegen bug, not a tuning problem. The header offsets (refcount at -8, length at -4)
are a hard contract shared by the compiler and the runtime; changing them means changing both in lockstep.
Golden rule for any ARC change: verify with `--asan`, NOT just the `--arc` audit, because the ARC audit
misses use-after-frees that ASAN catches (`arc-measurement-traps` note).*

### 3.2 Value versus reference storage
Value structs are stored inline (no box) and copy by value; classes are shared references. **[impl]**

*Maintainer's note: inline layout in `types.zig`, copy-on-assign in `arc.zig` (see 1.4). The failure mode to
watch for is aliasing sneaking back in (`let b = a` sharing storage): it passes the plain corpus and only
`--asan` catches the resulting UAF.*

### 3.3 Deterministic cleanup
Destructors run at scope exit; nested value-struct fields are destructed recursively. **[impl]**

*Maintainer's note: recursive destruction of nested value-struct fields is in `arc.zig` (the
`nested-value-struct-dtor-leak` note records the fix). "Deterministic" means cleanup timing is defined by
scope, not by a collector, so `defer`/`errdefer` and destructors compose predictably. If you add a container
or a nested aggregate, make sure its destructor recurses into every owned field, then prove the release count
with `--asan`.*

### 3.4 The OSSA-lite ownership verifier
An OSSA-lite ownership verifier proves release-balance (no leak, no double-free) over 100% of functions;
enforced corpus-wide under `NOVA_OSSA=hard`. Verify memory changes with `--asan`, not only the ARC audit.
**[impl]**

*Maintainer's note: the verifier is `src/frontend/sema/ossa/` (lowering into an ownership IR, then a per-path
release-balance check). It is SOUND but INCOMPLETE: it never false-accuses (0 false positives across the
corpus), but it does not yet track ownership through destructuring patterns (section 1.3), so a leak that only
happens via `let {a,b} = ...` slips past. Run it with `conformance/run.sh --ossa -j`; the hard gate
`NOVA_OSSA=hard` fails the build on a PROVEN imbalance. When you extend ownership handling, extend the OSSA
lowering too, or the verifier's coverage silently narrows.*

---

## 4. Concurrency model

The scheduler and the reactor backends are in the C++20 runtime (`src/runtime/concurrency.cpp`). Full detail:
`compiler-lld.md` section 4.6.

### 4.1 async/await and spawn
`async`/`await`, and `spawn` (fork, returns a `future<T>`) with `await` (join). Built on LLVM coroutines
(presplit -> CoroSplit -> `.resume`/`.destroy`). **[impl]**

*Maintainer's note: the coroutine lowering is in codegen (LLVM's presplitcoroutine then CoroSplit produce
`.resume`/`.destroy`); the scheduler that drives them is `src/runtime/concurrency.cpp`. A `future<T>` is a
builtin generic handled by `sema/lower.zig`. The single most expensive bug class in this area is documented at
length in `lang/CLAUDE.md`: a coroutine handle IS a frame address, and freed frames get recycled, so a stale
resume can land on a brand-new coroutine. If you touch resume/detach logic, read the "coroutine handle is a
FRAME ADDRESS" section there first, and use `NOVA_IO_WATCHDOG=1` to separate the three failure modes that look
identical from outside.*

### 4.2 Combinators
`when_all`, `selectAny`. **[impl]**

*Maintainer's note: stdlib concurrency utilities layered on `spawn`/`await`. Treat them as ordinary Nova code
that happens to await; there is no special compiler support beyond coroutines.*

### 4.3 Channels and actors
Channels (`channel<T>`) and an actor model built on channels + coroutines. A generic async method is spawnable
only from a CONCRETE instantiation. **[impl]**

*Maintainer's note: two DIFFERENT things share the word "channel", and confusing them has cost time. The
user-facing `channel<T>` is the stdlib actor/message primitive. The runtime's internal cross-reactor WAKE
channel (an eventfd watched by epoll or a one-shot io_uring POLL_ADD) is SEPARATE and load-bearing for the
reactor; it is not `channel<T>`. Before anyone removes user-facing channels/actors (the pause note weighs
this), verify nothing in the web stack imports `concurrency/channel` AND do not touch the runtime wake
channel. Actors on the current single reactor are half-baked (that is what the `118_actor` corpus crash
shows); the intended home for them is a future M:N cooperative threadpool.*

### 4.4 AsyncLock
`AsyncLock` is the reactor-aware mutex (a blocking mutex inside async code is ~70x slower and must not be
used). **[impl]**

*Maintainer's note: `AsyncLock` yields the coroutine instead of blocking the OS thread; a plain OS mutex parks
the whole reactor and everything else it was driving (the `i1-proxy-and-socket-strand-limit` note measured
~70x). It is already used to serialise the mongo shared connection (`runCommand`). Rule: inside `async` code,
reach for `AsyncLock`, never a blocking mutex.*

### 4.5 The single-reactor web model
The web server is SINGLE-reactor per process; scale is horizontal (instances behind the proxy), not in-process
worker threads. Actors/channels/`std::thread` still exist for non-web workloads. **[impl]**

*Maintainer's note: this is a firm architectural decision (`web-single-reactor-only` note): the in-process
multi-core web path was REMOVED, and you scale by running more instances behind `proxyd`. Do not reintroduce
in-process web worker threads; the horizontal model is what the orchestrator (proxyd/orchd) assumes. Non-web
workloads may still use `std::thread`, actors, and channels.*

### 4.6 Reactor backends
kqueue (macOS), epoll and io_uring (Linux), IOCP (Windows), selected per target. **[impl]**

*Maintainer's note: the backend is chosen per target by the target-conditional file rule, and on Linux by a
RUNTIME probe (`nova_reactor_backend()` in `concurrency.cpp`), because a header being present does not mean the
running kernel enables io_uring. The proactor backends (IOCP, io_uring) have a rule that has bitten us
repeatedly and is spelled out in `lang/CLAUDE.md`: on a proactor the KERNEL owns the op record until the op
completes or is cancelled, so "give up and free it" corrupts the next op. `abandonOp` is the seam that answers
who still owns the record. Readiness on a proactor is faked with a zero-byte receive. If you add or change a
backend, that file's reactor section is required reading.*

---

## 5. Modules, packages, and visibility

Import resolution and the package manager live in `src/pipeline.zig` and `src/packages.zig`. Full detail:
`compiler-lld.md` sections 3.2 (resolution) and 4.3 (multi-version coexistence via path-derived mangling).

### 5.1 Imports and visibility
`import name;` resolves by the dependency's DECLARED name; `pub` controls cross-module visibility. **[impl]**

*Maintainer's note: resolution is `resolveImportPath` in `src/pipeline.zig`; `pub` is enforced during type
checking. "By declared name" is the Cargo-style rule: the import name comes from the dependency's OWN
`project.json` `name`, not the repo or folder name, so the resolver reads the dependency's manifest to learn
what `import X` means. Anything not `pub` is module-private. If an import fails to resolve, the order of
attempts (stdlib, importer-relative, local `packages/`, then the version-keyed cache) is the thing to trace.*

### 5.2 The standard library
Written in Nova and imported by short names (`string`, `list`, `map`, `json`, ...). **[impl]**

*Maintainer's note: the stdlib source is `src/lib/std/` and is compiled from source on each build (the import
graph gates which modules are pulled in). Short names are resolved first by the same resolver. To ADD a stdlib
module you add the `.nova` file AND register it where the resolver maps short names to `src/lib/std/` paths
(the `stdlib-restructure-and-tprod` note records the `os/<os>` layout; the `async-lock-primitive` note points
at the registration site). Because stdlib is real Nova, a stdlib change is validated by the same corpus and
`--asan` gates as user code. Note that `nova test` does NOT re-run the stdlib's own `@test`s (see 6.6).*

### 5.3 The package manager
See `pkg-manager.md`: `project.json` dependencies are `url[#ref]` strings; a flat `project.lock.json` records
the declared name and the resolved git SHA per dep; the version-keyed cache is `~/.nova/cache/<name>-<sha8>`;
resolution is transitive and cache-deduped; `nova build`/`nova test` honour the lock and never move a pin;
imports are resolved PER OWNING PACKAGE so two versions of a dependency coexist. Commands: `get`, `restore`,
`update`, `publish`. **[impl]**

*Maintainer's note: the implementation is `src/packages.zig` (fetch/lock/resolve, the four commands) plus the
version-aware import resolution in `src/pipeline.zig` (`findOwningManifestDir`, `resolveVersioned`). The design
is a locked contract in `docs/design/pkg-manager.md`; do NOT add scope (a registry, semver ranges, MVS, a
checksum DB) without re-opening that document. Two facts explain the whole design: (1) git SHAs ARE the
version lock and the integrity check, because git is content-addressed, so there is no separate hash scheme;
(2) the mangle prefix is path-derived (section 2), so two versions living at different cache paths mangle to
distinct symbols and coexist with no codegen change. The critical invariant is that `nova build`/`nova test`
HONOUR the lock and never move a pin; only `get` and `update` move a SHA. The recorded out-of-scope limitation
is supply-chain trust (the recursive fetch trusts each package's declared dep list); `nova vendor` is the
first future step. The acceptance harness is `conformance/pkg-acceptance.sh` (6 items, local `file://` repos,
no network); run it after any packaging change, it is wired into `gate.sh`.*

---

## 6. Compiler and tooling

This section is a SUMMARY. The full, stage-by-stage account of how the compiler is built, with a section
per pipeline stage and per component, lives in **`compiler-lld.md`**. Read that document when you need to
change the compiler; read this section when you only need to know what the toolchain offers.

### 6.1 The compiler in one paragraph

`nova` is a single Zig 0.16 binary. It resolves every `import` and merges all reachable files into one
program, generates synthetic boilerplate (serde binders, the web mediator, routes), alpha-renames, assigns
expression ids, type-checks, runs the authoritative TypeId semantic analysis, monomorphises only what is
reachable from `main`, optionally verifies ARC ownership balance, then generates one LLVM module, optimises
it (O0 debug, O3 release), emits object files, and links them against the C++20 runtime into a native
binary. The exact order is `builder.zig` `compileProgram`; the stages are documented in `compiler-lld.md`
section 3.

### 6.2 What the toolchain offers

- **Targets.** Native macOS, Linux, and Windows on x86_64 and arm64 (primary); WebAssembly via `wasm-ld`
  (secondary, best-effort). Cross-compilation from any host to any target via the bundled `zig c++`
  toolchain; `nova app.nova --target windows-x86_64` produces a real PE32+ `.exe`. **[impl]**
- **Diagnostics.** Type errors carry `file:line:col` and a source line with a caret. A user mistake reads as
  a one-line message, not a Zig stack trace (`userErrorHint` in `cli.zig`). **[impl]**
- **Incremental build cache.** `nova build` hashes the sources, profile, link libraries, and the compiler
  binary's mtime, so an unchanged project short-circuits and any toolchain change forces a rebuild
  (`pipeline.zig` `linkLibsStamp`). **[impl]**
- **Demand-driven monomorphisation.** Only the generic methods reachable from `main` are emitted, instead
  of the whole method surface of every instantiation (`sema/reach.zig`). This is the main build-speed lever.
  **[impl]**
- **Object emission.** One combined `<app>.o` by default; `--split-objects` gives per-file objects with a
  content-hash cache; `--emit-llvm` writes the `.ll`. **[impl]**
- **Sanitiser and verifier gates.** `--asan` (AddressSanitizer), `--tsan` (ThreadSanitizer), `--arc` (ARC
  leak audit), and `NOVA_OSSA=hard` (the ownership release-balance verifier over the whole corpus). Verify
  memory changes with `--asan`, not just `--arc`. **[impl]**
- **Self-contained delivery.** Release builds static-link LLVM; `release.yml` publishes six bundles, each
  carrying `nova` + `nls` + the stdlib + a checksum, so end users install nothing. **[impl]**

### 6.3 CLI surface

`nova <file>`, `nova build [--release]`, `nova test`, `nova init <console|web|desktop>`,
`nova get|restore|update|publish`, `nova fmt`, `nova add feature`. User-facing build options are CLI flags
(`--asan`, `--split-objects`, `--prune`, `--keep-obj`, `--emit-llvm`, `--dump-merged`, `--mem-stats`); the
`NOVA_*` environment variables are compiler-internal debug switches (see `compiler-lld.md` section 6), not
user surface. **[impl]**

*Maintainer's note: dispatch is in `src/cli.zig`, delegating to `builder.zig` (build), `tester.zig` (test),
`scaffold.zig` (init), `packages.zig` (packaging), `format.zig` (fmt). Add a user option as a flag, route it
through the right module rather than growing `cli.zig`, and if it changes the OUTPUT fold it into the build
stamp.*

### 6.4 In-editor debugger

Debug builds emit DWARF line tables and DITypes, driven in VS Code by `lldb-dap`. Optional Python
data-formatters give C#-quality value display: clean strings, `List`/`Map`/`Set` element expansion, struct
fields, and borrowed `str.Str` text. **[impl]**

*Maintainer's note: DWARF is emitted in `backend/codegen/llvm_codegen.zig` (DITypes) and statement lowering
(line tables); the formatters are Python at `~/.nova/std/debug/nova_formatters.py`. VS Code uses the
Homebrew `lldb-dap` on PATH, not Apple's. `lldb-dap` renders a pointer as its raw address and an aggregate
as a summary, which is why strings and containers are single-member aggregate DWARF types (they show
`"text"`, not `0x...`). The formatters MUST degrade gracefully when Python is absent. Full detail:
`compiler-lld.md` section 4.5.*

### 6.5 Language server and editor extension

`nls` (pure Zig, bundled in the release archives) reuses this repo's frontend, so completion, hover,
definition, symbols, rename, references, code-actions, and semantic tokens see the same types the compiler
does. A VS Code extension provides syntax highlighting and NSX support. **[impl]**

*Maintainer's note: `nls` is a separate repo version-locked to lang (`scripts/check-version-sync.sh`); the
extension is the sibling `extension/` project. If `nls` drifts from the compiler frontend, the editor's type
view disagrees with the compiler.*

### 6.6 The `nova test` runner

`nova test [file]` runs the `@test` functions defined in the file you name, or across the current project
when no file is given. It runs ONLY YOUR `@test`s, not the standard library's: the stdlib is compiled into
the program like any import, but its own `@test`s are already covered by the conformance corpus, so re-running
them on every `nova test` would be noise. A file with no `@test` of its own is still COMPILED (so a mistake is
still caught), and reports "0 passed, 0 failed". **[impl]**

*Maintainer's note: the runner is `src/tester.zig`. `collectTestFunctions` filters `@test`s by
`fd.span.file` (the parser stamps each function's span with its source path) against the files the user asked
to test (`file_paths.items`). Two coupled rules a maintainer must keep: (1) the filter keyed on `span.file`
matching the user's requested paths is what excludes stdlib and package tests; (2) when zero user tests are
found, the runner must NOT return before type checking. It falls through to build a trivial 0-test harness so
the file is still compiled. Skipping the compile here would silently un-check an expect_fail case that has no
`@test` of its own, and would make a no-test fixture look like a failure. Full detail: `compiler-lld.md`
section 2 (source layout) and section 3.7 (soundness). Also remember `nova test` SKIPS `main()`; use
`NOVA_ARC_AUDIT=1` to see ARC survivors (`arc-measurement-traps` note).*

---

## 7. Soundness checks the compiler enforces

Each check has the same shape: it lives in `src/frontend/type_checker.zig`, it is proven by a
`conformance/expect_fail/*.nova` case that MUST stay rejected, and it must not reject any positive corpus
case. That pairing (one expect_fail case per check, plus the whole positive corpus) is how you change a
check without regressing it. Full context: `compiler-lld.md` section 3.7.

### 7.1 Argument checks
Argument COUNT per call, and a cross-CATEGORY scalar argument (a `string` where an `int` is expected) is
rejected rather than miscompiled to garbage. **[impl]**

*Maintainer's note: `checkArgTypes` with `primCategory`/`PrimCat`. It fires only when both sides are KNOWN
primitives of DIFFERENT categories (numeric/boolean/text/other), so it never guesses. It is category-based,
not exact-type, to reject the dangerous confusions without blocking legal numeric widening. Guard:
`expect_fail/arg_type_category_mismatch.nova`.*

### 7.2 Unknown type names
An unknown type name in a function signature or a struct field is rejected (`unknown type 'Frob'`), scoped
to where the type-parameter context is exact; compiler-generated sources are exempt. **[impl]**

*Maintainer's note: `rejectUnimplementedType` with `isKnownTypeName`. Two exemptions are load-bearing:
builtin generics (`future`/`channel`) are whitelisted, and synthetic `<...>` sources are skipped (they name
types the user never wrote). The check is passed the function's own type parameters as the whitelist. Guard:
`expect_fail/unknown_type_annotation.nova`. A false positive here is almost always a missing whitelist
entry, not a reason to remove the check.*

### 7.3 Missing return
A non-void function that can finish without returning a value is rejected. The analysis is conservative:
loops, `switch`, and any expression-statement count as returning, so nothing valid is flagged. **[impl]**

*Maintainer's note: `stmtDefinitelyReturns`/`blockDefinitelyReturns`. Conservative by design (zero false
positives at the cost of possibly missing an exotic case): a false accusation blocks a valid program, a miss
is caught later. Guard: `expect_fail/missing_return.nova`.*

### 7.4 The rest
Trait-to-concrete narrowing at a call argument, tuple-destructure arity, return-type mismatch, ambiguous
cross-module calls, and the OSSA ownership verifier. **[impl]**

*Maintainer's note: the first four are in `type_checker.zig` with matching expect_fail cases; the OSSA
verifier is the separate ownership pass (`sema/ossa/`, gated by `NOVA_OSSA=hard` and `run.sh --ossa`).
"Ambiguous cross-module call" exists because same-named types coexist across modules: when a call could bind
to more than one, the compiler refuses rather than pick. All are wired into `gate.sh`.*

---

## 8. Non-goals and known gaps

The honest boundary: what Nova deliberately does NOT do, and what is known-incomplete. A maintainer reads it
to avoid two mistakes: "fixing" a settled non-goal, and assuming a gap is covered when it is not.

### 8.1 Settled non-goals (do not "fix")
- **WASM is secondary, best-effort**; native is primary (decision of 2026-07-28). Do not block a native
  feature on WASM parity. **[impl]**
- **Actors are not the web concurrency model.** The web server is single-reactor plus horizontal scale.
  Actors and `channel<T>` are KEPT but off the beta path; their intended future home is a Swift-style M:N
  cooperative threadpool (a multi-week roadmap item, aimed at Skia UI apps). Before deleting them, re-read
  the runtime-wake-channel note in section 4. **[design]**
- **No registry, no module proxy, no semver range solving** (exact git-ref pins only). Git SHAs are the
  version lock and the integrity mechanism; different pins coexist, so there is nothing to unify. This is a
  locked decision in `pkg-manager.md` section 9. **[design]**

### 8.2 Known-incomplete (real gaps)
- **Package supply-chain trust.** The recursive fetch trusts each package's declared dependency list; a
  malicious package could pull arbitrary repos. This is documented in `pkg-manager.md` sections 5 and 9;
  `nova vendor` is the recorded first mitigation. **[open]**
- **The soundness checks are scoped.** Missing-return covers function bodies; unknown-type covers signatures
  and struct fields but not a `let x: Frob` local annotation (a later pass). If you extend either, add the
  expect_fail case and re-run the whole corpus. **[open]**
- **Three known-red corpus cases**, each understood, so do not treat them as regressions: `118_actor` (a
  half-baked actor mutex lock, low priority under the single-reactor model), `189_epoll` (asserts epoll
  struct layout, inapplicable off Linux by design, with a kqueue twin `188` inapplicable off macOS), and
  `42_nested` (a nested value-optional aggregate). A FOURTH red case is a regression. **[open]**
