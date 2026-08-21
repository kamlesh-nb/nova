# Nova Language: Low-Level Design

Status snapshot: 2026-08-21.

This document is the authoritative, low-level design of the Nova **language** as it is actually implemented
(compiler in Zig 0.16 to LLVM to native, runtime in C++20, standard library in Nova). It is the companion to
`compiler-lld.md` (which explains how the compiler that accepts this language is *built*, stage by stage) and
to the friendly `docs/guide/` walkthrough. Where `compiler-lld.md` documents pipeline STAGES, this document
documents language FEATURES: what each one is, how it behaves, where it lives in code, and how to change it
without breaking the rest.

This catalogue is kept in one-to-one correspondence with **`docs/feature-inventory.md`** (its Stream 1,
"Language and runtime", is the authoritative register of what the language HAS and how sound each piece is).
Every Stream-1 feature has an entry here. When you land or change a language feature, update BOTH: the
inventory (its acceptance criteria and status) and this document (its design entry). If the two ever
disagree, the inventory's per-criterion `[x]`/`[ ]` marks are the ground truth for "is it done and sound",
and this document is the ground truth for "how it works and where it lives in code".

---

## How to read this document

Every feature below is written to the same seven-part template, the same one `compiler-lld.md` uses for
components, so you can skim to the part you need:

- **What it is**: a one-line identity, with the syntax.
- **Why it exists**: the problem it solves or the design reason, so you do not remove a constraint that is
  load-bearing.
- **What it does**: the actual semantics, step by step.
- **Where in code**: the file, and the function or type to open first. Paths are relative to `lang/`.
- **Data it produces**: what the feature lowers to (the runtime or IR representation the later stages and the
  running program see). For a purely static rule, this is "diagnostics only".
- **Gotchas**: the traps that have bitten us before.
- **How to change it safely**: the specific test or gate that proves you did not break it.

Confidence tags mark how sure a claim is: **[impl]** verified against the code, **[spec]** stated in the
language spec, **[open]** a known gap, **[design]** a settled decision.

Two rules override everything below:

1. **Run the corpus before and after every change.** From `lang/`: `conformance/run.sh -j` is the fast
   positive gate (about two minutes), `conformance/run.sh --asan` is the memory gate (needs a
   `NOVA_ASAN=1 zig build` first), and `gate.sh` runs the whole battery.
2. **Type and ownership decisions are made from TYPES in the semantic-analysis layer
   (`src/frontend/sema/`), never from the spelled name of a type.** Keying behaviour on a string like `"Str"`
   or `"List"` caused a whole class of corruption bugs. The rule is enforced by the shadow gate
   (`NOVA_SEMA_SHADOW=1` diffs the name and TypeId engines and fails on divergence).

### Contents

1. Program and lexical structure
2. Primitive types and literals
3. Bindings
4. Composite types
5. Generics, traits, and bounds
6. Control flow and pattern matching
7. Functions and closures
8. Error handling
9. Optionals and narrowing
10. Memory and ownership
11. Concurrency and the reactor
12. Serialization, FFI, and attributes
13. Type-system rules
14. Modules, packages, and visibility
15. Compiler and tooling (summary; full detail in `compiler-lld.md`)
16. Soundness checks the compiler enforces
17. Non-goals and known gaps

Inventory map (Stream 1 feature to section): Monomorphisation 5.1 - Traits/dispatch 5.2 - Generic bounds 5.3
- Enums/pattern matching 6.4 - Error handling 8 - Optionals/narrowing 9.1 - `x ?? d` present-0 9.2 - Closures
7.2 - Integers 2.1 - Atomic 11.7 - decimal128 2.4 - Type-checker fail-closed 16 - async/await 11.1 -
Combinators 11.2 - Channels/actors 11.3 - Reactor 11.6 - ARC 10.1 - OSSA verifier 10.4.

---

## 1. Program and lexical structure

### 1.1 Source files and program shape

**What it is.** A program is one or more source files; `.nova` holds logic, `.nsx` holds view/markup and is
the SAME language. `fn main(): void` is the entry point; a library has none. **[impl]**

**Why it exists.** Splitting markup into `.nsx` is a filing convention, not a second grammar, so the toolchain
and editors can treat view files specially without the compiler needing a second parser.

**What it does.** The resolver treats `<path>.nova` and `<path>.nsx` interchangeably (trying `.nova` first);
both are handed to the one parser, and markup enters through the JSX branch. `main` is found by name and
becomes the root of the reachability worklist.

**Where in code.** `src/pipeline.zig` (`resolveImportPath` and helpers) for resolution; `src/frontend/parser.zig`
(`parseJsxElement`) for markup; `src/frontend/sema/reach.zig` seeds from `main`.

**Data it produces.** One merged `ast.Program` (see `compiler-lld.md` 3.2); `main` is the single emission root.

**Gotchas.** Do not teach the parser about file extensions; a new source extension belongs in the resolver
only. Do not special-case `main` anywhere except reachability; treating it as "just the reachability root" is
what keeps libraries and apps on one code path.

**How to change it safely.** The whole corpus links every case; a resolution change is also covered by
`conformance/pkg-acceptance.sh`.

### 1.2 Comments, terminators, keywords

**What it is.** `//` line comments; statements end in `;` (no implicit last-expression return); a fixed
keyword set with `var` retired in favour of `let`/`const`. **[impl]**

**Why it exists.** Explicit `;` and no tail-expression return keep the missing-return analysis (section 16)
simple: a block's value is never silently a function's result.

**What it does.** The lexer drops `//` to end-of-line and holds the keyword table; the parser requires the
trailing `;`, so `fn f(): int { 5 }` is a parse error. Reserved words: `async await break case catch class
const continue default defer else enum errdefer export extern fn for if impl import let match pub return spawn
struct switch throw trait try union var while`.

**Where in code.** `src/frontend/lexer.zig` (keyword table, comment scan); `src/frontend/parser.zig`
(terminator rule).

**Data it produces.** A token stream, then AST nodes.

**Gotchas.** Adding a keyword is a breaking change: any program using that word as an identifier stops
compiling. Prefer a CONTEXTUAL keyword (recognised only where meaningful). `var` stays in the table only so an
old program gets a clear "use let/const" message instead of a confusing parse error.

**How to change it safely.** Update `docs/specs.md` first (spec-first rule), then run the whole corpus (a hard
keyword can break existing cases).

---

## 2. Primitive types and literals

### 2.1 Integers and overflow policy

**What it is.** `int` is 32-bit, `long` is 64-bit, with aliases (`byte`=i8, `short`=i16, and the `u*` names).
Default `+ - *` WRAP; `math.checked*` / `sat*` give opt-in overflow detection. **[impl]**

**Why it exists.** Honest widths avoid a heisenbug class: storing a heap address in an `int` emits an LLVM
`trunc i64->i32`, so it works until an address climbs past 4 GB and then SIGSEGVs on a value that looks fine.
The checked path exists for code that must not silently wrap (money, sizes, indices).

**What it does.** Aliases canonicalise to LLVM widths with signedness. `math.checkedAddInt`/`checkedSubInt`/
`checkedMulInt` return `int | undefined` (undefined on overflow, computed in 64-bit and range-checked);
`checkedAddLong`/etc. detect 64-bit overflow directly; `satAddInt`/etc. clamp. All compose with `??`.

**Where in code.** Alias-to-width in `src/frontend/sema/` (TypeId builtins) and `src/backend/codegen/types.zig`
(`cgPrim`, `CgRepr`, `reprBitWidth`); the checked/saturating functions are stdlib `math`.

**Data it produces.** i32/i64 LLVM values; the checked forms produce a value-optional (a boxed `int | undefined`,
see 9.1).

**Gotchas.** A heap ADDRESS must be `long`/`ptr`, never `int`. The default wrap is DELIBERATE and defined
behaviour (not UB); do not change it to trap. See the "int is 32-bit" gotcha in `lang/CLAUDE.md`.

**How to change it safely.** Case 394 (INT_MAX+1 / INT_MIN-1 / a 10^10 multiply / LONG_MAX+1 all yield
`undefined`; `sat*` clamps; in-range returns the value). A new checked form must keep the `int | undefined`
shape so it composes with `??`.

### 2.2 Floating point

**What it is.** `float` (f32) and `double` (f64). **[impl]**

**Why it exists.** Two honest float widths, no implicit widening surprise: coercion is governed by the one
assignability predicate (13.4), not by ad-hoc rules at each site.

**What it does.** Maps to LLVM `float`/`double`; numeric coercion is decided once in `assignable`.

**Where in code.** `src/backend/codegen/types.zig`; coercion in `src/frontend/type_checker.zig` (`assignable`).

**Data it produces.** LLVM `float`/`double` values.

**Gotchas.** If you add a numeric coercion, add it to `assignable` once, so calls, returns, and assignments
all agree.

**How to change it safely.** The nbody / spectral / mandelbrot bench sources plus the corpus exercise float
paths; a coercion change runs the whole corpus.

### 2.3 bool, string, char

**What it is.** `bool` (`true`/`false`), `string` (UTF-8, heap object under ARC), `char`. **[impl]**

**Why it exists.** `string` is a first-class heap object so it participates in ARC like any reference; the
borrowed `str.Str` VIEW (13-adjacent, and the debugger note in 15.4) is the zero-copy way to pass a substring.

**What it does.** A `string` carries the shared 8-byte heap header (refcount at ptr-8, length at ptr-4) and is
retained/released. `str.Str` is a `{ptr, len}` value view that borrows bytes it does not own.

**Where in code.** Runtime header shape in `src/runtime/` (`runtime_str.h`, `nova_abi.h`); `str.Str` in
`src/lib/std/str.nova`.

**Data it produces.** A heap pointer with the ARC header (`string`); an inline `{ptr, len}` value struct
(`str.Str`).

**Gotchas.** Do not invent a second string representation. A `str.Str` borrow requires its backing bytes to
outlive the view (manual, request-scoped lifetime, like Rust's `&str`, with no borrow checker); materialise
with `toOwned()` only at an escape boundary.

**How to change it safely.** Corpus plus `--asan` (a mishandled owned string leaks or double-frees; a dangling
`str.Str` reads freed memory, which only `--asan` catches). `str.Str` is gated by `conformance/cases/str_borrow.nova`.

### 2.4 decimal128

**What it is.** `decimal` / decimal128 exact base-10 arithmetic; no implicit int<->decimal coercion. **[impl]**

**Why it exists.** Silent int-to-decimal (or back) is where money bugs come from, so a conversion must be
spelled out.

**What it does.** Exact base-10 arithmetic, parse, and round-trip through JSON / YAML / BSON with fidelity;
a conversion to or from `int` must be explicit.

**Where in code.** `src/runtime/decimal.cpp`, surfaced through the stdlib.

**Data it produces.** A decimal128 value carried through the runtime engine.

**Gotchas.** Keep the no-implicit-coercion rule; if a caller finds it verbose, give them an explicit
constructor, not an implicit rule.

**How to change it safely.** The decimal128 conformance case (arithmetic + JSON/YAML/BSON round-trip with
fidelity).

### 2.5 Template literals

**What it is.** `` `text ${expr} more` `` string interpolation. **[impl]**

**Why it exists.** Ergonomic string building without a second concatenation syntax.

**What it does.** Lexed into a concatenation of literal chunks and `${...}` expressions, then lowered like a
normal string build.

**Where in code.** `src/frontend/lexer.zig` (template-string state machine) and `parser.zig`.

**Data it produces.** A string-build expression (the same lowering a manual concatenation produces).

**Gotchas.** The lexer's template-string state machine is the only place that needs to know the interpolation
syntax; keep interpolation parsing there.

**How to change it safely.** The corpus uses template literals pervasively (e.g. every `console.log(` \`...\` )`).

---

## 3. Bindings

### 3.1 let / const

**What it is.** `let name = expr;` (mutable) and `const name = expr;` (immutable), with an optional annotation
`let x: int = 1;`. **[impl]**

**Why it exists.** One mutable and one immutable binding form; the annotation pins numeric-literal typing.

**What it does.** The mutable/immutable flag rides the AST binding node and is checked by the type checker; an
annotation becomes the expected type for the initialiser. A `const` initialised by a function call is memoised
so re-evaluation does not leak.

**Where in code.** `src/frontend/parser.zig` (binding node), `src/frontend/type_checker.zig` (mutability +
expected-type), const memoisation in codegen.

**Data it produces.** A typed local slot (`slotTypeForLocal` in `types.zig`).

**Gotchas.** Keep the const memoisation (see the `const-reeval-leak` note); losing it re-evaluates and leaks.

**How to change it safely.** Corpus plus `--asan` for the const-memo path.

### 3.2 Destructuring

**What it is.** `let (a, b) = pair;` binds exactly as many names as the tuple has elements. **[impl]**

**Why it exists.** Ergonomic multiple-binding for tuples and multi-value returns.

**What it does.** Binds each name to the matching tuple element; an arity mismatch is a type error (a
section-16 gate).

**Where in code.** Arity check in `src/frontend/type_checker.zig`; ownership lowering in `src/frontend/sema/ossa/`.

**Data it produces.** One typed local per element.

**Gotchas.** The OSSA ownership verifier does NOT yet track per-binding ownership THROUGH a destructuring
pattern, so a leak that only happens via `let {a,b} = ...` is not caught (section 10.4, and an [open] gap in
section 17). If you extend destructuring, extend the OSSA lowering at the same time.

**How to change it safely.** The tuple-destructure-arity expect_fail case plus the corpus.

### 3.3 Shadowing

**What it is.** A later `let` may shadow an earlier binding in the same scope. **[impl]**

**Why it exists.** Convenient re-binding; made unambiguous once, up front, so nothing downstream juggles two
live bindings with one name.

**What it does.** Alpha-renaming rewrites the shadowing `let` to a fresh internal name before any type or
ownership reasoning runs.

**Where in code.** `src/frontend/sema/alpha.zig` (`run`).

**Data it produces.** An AST in which a name identifies exactly one binding.

**Gotchas.** If you add a construct that introduces bindings (a new loop form, a pattern), make sure
alpha-renaming visits it, or a later pass confuses the two.

**How to change it safely.** The shadowing corpus cases; add one for a new binding form.

---

## 4. Composite types

### 4.1 struct (value) and class (reference)

**What it is.** `struct` is a VALUE type (copy-on-assign, inline storage, nested value fields stored inline
Swift-style); `class` is a REFERENCE type (shared, ARC, identity). Both have fields, an `init(...)`, methods,
and `pub` per member. **[impl]**

**Why it exists.** A clear value/reference split with predictable copying; inline nested storage avoids a box
per nested value.

**What it does.** The fork is decided once from the declaration kind (`StructDecl.is_reference`) and flows
through layout and ARC: a value struct is an inline aggregate copied on assignment, with recursive destruction
of nested owned fields; a class is a shared heap pointer.

**Where in code.** `src/backend/codegen/types.zig` (inline layout), `src/backend/codegen/arc.zig`
(copy-on-assign, recursive destruction). Value semantics are the `struct-value-semantics-fix` note.

**Data it produces.** An inline LLVM aggregate (`struct`) or a heap pointer with an ARC header (`class`).

**Gotchas.** Keep the decision keyed on the TypeId, never the spelled name. The failure mode is aliasing
sneaking back in (`let b = a` sharing storage): it passes the plain corpus and only `--asan` catches the UAF.
Some escape-set structs (returned from a constructor, captured by a trait, serialised) may still be handled by
reference; that boundary is in the memory note.

**How to change it safely.** Corpus plus `--asan`; a struct change green on `run.sh -j` but red on `--asan`
almost always means reintroduced aliasing or a dropped nested destructor.

### 4.2 tuple, fixed array, union, function type

**What it is.** `(a, b, c)` tuples (`(T)` is grouping, not a one-tuple); `[value; count]` fixed arrays; `union`
(the general named sum type, plus the optional and error-union special forms); `(A, B) -> R` function types.
**[impl]**

**Why it exists.** The composite building blocks. Fixed arrays are the inline sequence; growable sequences are
the stdlib `List<T>` (generic over a `RawBuffer`), a different thing.

**What it does.** Tuples and fixed arrays lower to inline aggregates; a `union` is a tagged representation
(optionals and error unions are the two structural special-cases the compiler understands, section 9 and 8);
a function type is an `(env, code-ptr)` pair.

**Where in code.** `src/backend/codegen/types.zig` (aggregate layout, `valueOptionalName`), `parser.zig` (the
"one-tuple does not exist" rule), closures in `expressions.zig`.

**Data it produces.** Inline aggregates (tuple, fixed array), a tagged union, an environment+code-pointer pair
(function value).

**Gotchas.** `(T)` used to parse as a nested optional and SIGSEGV (fixed, guarded by conformance case 363).
Do not conflate a fixed array with `List<T>`.

**How to change it safely.** Corpus (case 363 for tuple grouping) plus `--asan`.

### 4.3 enum and pattern matching

**What it is.** `enum` with four variant shapes (payload-less, single-payload, tuple-form, struct-form),
methods, and dispatch via `switch`/`match` with case guards (`case v if cond`) and enforced exhaustiveness.
**[impl]** (Inventory: "Enums and pattern matching", SOUND.)

**Why it exists.** A typed sum with safe destructuring; enforced exhaustiveness stops a newly-added variant
being silently ignored at runtime.

**What it does.** Payload-carrying enums lower to tagged unions; a `switch` binds the payload(s) in each arm,
supports guards, and runs ARC destructors for refcounted payloads. A non-exhaustive switch on a typed enum is
a compile error, INCLUDING when the discriminant type cannot be resolved directly: for `switch (list[i])` (an
`.index` expression the resolver leaves untyped) `checkSwitch` recovers the enum from the case values
(`recoverEnumFromCases`) and runs a coverage-only check (`checkEnumCoverageOnly`) rather than skipping.

**Where in code.** Tag layout in `types.zig`; `switch`/`match` lowering in `statements.zig`/`expressions.zig`;
exhaustiveness in `src/frontend/type_checker.zig` (`checkSwitch`, `recoverEnumFromCases`,
`checkEnumCoverageOnly`).

**Data it produces.** A tagged union value; a branch table with a bound payload per arm; diagnostics for a
missing arm.

**Gotchas.** The untypeable-discriminant recovery is ADDITIVE (an integer/other switch on literal case values
never triggers it). A separate KNOWN codegen bug (a COMPLETE `switch (list[i])` on an enum can hit an
`LLVMVerificationError`) is tracked in the worklist and is not this type-check property.

**How to change it safely.** `expect_fail/untypeable_switch_nonexhaustive.nova` plus the corpus; verify a
refcounted-payload arm with `--asan`. If you add a variant shape, change the tag layout, the `switch`
payload-bind, and the exhaustiveness check together.

---

## 5. Generics, traits, and bounds

### 5.1 Monomorphisation

**What it is.** Generics are monomorphised: `List<int>` becomes a concrete `List_int_*`, each generic method
stamped per concrete instantiation; nothing is type-erased at runtime. **[impl]** (Inventory: Monomorphisation,
SOUND.)

**Why it exists.** Concrete codegen (no boxing, no erasure) is what gives Nova its native performance; it is
also the mechanism that gives module-scoped type identity and multi-version packaging for free (13.2, 14.3).

**What it does.** A worklist computes the needed instantiations and stamps them; field-type and return-type
recursion is instantiated. Nested generics beyond depth 2 are eagerly monomorphised for EXPLICITLY-USED types;
the depth-2 cap applies only to the SPECULATIVE method-return-type cascade (the thing that balloons
`chunk(): List<List<T>>` into dead deep nestings). An erased body exists only as an `internal`-linkage fallback
that LLVM's globalDCE deletes.

**Where in code.** `src/frontend/sema/mono.zig` (`Worklist`, the `noteImpl(t, speculative)` split),
`src/frontend/sema/inst_disp.zig`; reachability-pruned by `reach.zig` (`compiler-lld.md` 3.9/3.10).

**Data it produces.** The live (type x method) instantiation set consumed by codegen; distinct mangled symbol
names per instantiation.

**Gotchas.** Distinct instantiations get distinct PATH-derived mangled names; if you touch mangling, you touch
multi-version packaging (14.3).

**How to change it safely.** Case 390 (the value-optional `get()` path the erased layout mishandles) plus the
corpus (399/402 baseline); `--mem-stats` watches instantiation counts when changing the cap.

### 5.2 Traits and dynamic dispatch

**What it is.** `trait Name { fn m(self, ...): R; }` with `impl Name for Type`; dynamic dispatch via a fat
pointer `{struct_ptr, vtable}` where vtable slot 0 is the destructor. Trait default methods work cross-module;
generic trait dispatch is monomorphic (per-M vtables), not type-erased. **[impl]** (Inventory: Traits and
dynamic dispatch, SOUND.)

**Why it exists.** Interface polymorphism with a predictable ABI; slot 0 being the destructor lets ARC release
a trait object without knowing its concrete type.

**What it does.** Trait impls are matched in the checker/sema; method tables are built in codegen. A checked
downcast (`x as T`) traps on the wrong concrete type. A default method body is re-copied onto implementers on
the fully-merged decls (`pipeline.expandTraitDefaults`) so it works across modules. Each `impl Producer<M>`
names its vtable per-M (`_vtable_IntMaker_Producer_i32`, ...), derived from the struct's own impl `type_args`
in `getGlobalVTable`, so construction and the downcast check derive the SAME name; a plain non-generic trait
has no `type_args`, so its vtable name is byte-identical (no regression).

**Where in code.** `type_checker.zig`/`sema` (matching, downcast rejection), `declarations.zig` (`getGlobalVTable`,
method tables), `pipeline.zig` (`expandTraitDefaults`).

**Data it produces.** A fat pointer per trait value; a per-(impl, M) vtable global.

**Gotchas.** Do NOT reorder the vtable to put a method in slot 0 (that slot is the destructor); append new
slots. A generic ASYNC method is spawnable only from a CONCRETE instantiation, not an erased-`M` context (the
coroutine needs the real frame layout).

**How to change it safely.** Downcast (case 71), per-instantiation (299), generic-trait (55/56/57/120), and the
cross-module default (395) and per-M dispatch (391) cases; the DB `Connection`/`Driver` seam in `packages/nova-*`
is the realistic stress test.

### 5.3 Generic bounds (`where T: Bound`)

**What it is.** `fn f<T>(v: T): R where T: Bound` constrains a type parameter to types satisfying a trait.
**[impl]** (Inventory: Generic bounds, SOUND.)

**Why it exists.** To reject a wrong type argument at the call, with a clear error, rather than a deep
monomorphisation failure or (for an unused bound) no error at all.

**What it does.** Two enforcement paths. STRUCTURAL: a body that calls a bounded method fails to monomorphise
for a `T` lacking it (`totalArea<Sq>` compiles; a type without the method errors). NOMINAL, for an UNUSED
bound: the `where` clause is captured into the AST (`ast.WhereBound`, `parseWhereClause`) and `checkGenericBounds`
(via `structImplementsTrait`) rejects an explicit type argument that is a known struct not declaring a known
bound trait, even when the body never calls the method. Conservative: primitives, type-parameters, unknown
names, and unknown traits are not newly rejected.

**Where in code.** `src/frontend/parser.zig` (`parseWhereClause`), `src/frontend/ast.zig` (`WhereBound`),
`src/frontend/type_checker.zig` (`checkGenericBounds`, `structImplementsTrait`).

**Data it produces.** Diagnostics only (a static constraint).

**Gotchas.** The conservative bias is deliberate; do not widen it to reject primitives/type-parameters without
adding both a positive and an expect_fail case.

**How to change it safely.** Positive case 389 plus `expect_fail/unused_bound_violation.nova`, then the corpus.

---

## 6. Control flow and pattern matching

### 6.1 if / else (statement and expression)

**What it is.** `if`/`else`, and `if` as an EXPRESSION (`let x = if (c) 1 else 0;`). **[impl]**

**Why it exists.** One conditional that doubles as a value form, avoiding a separate ternary.

**What it does.** As a value, both arms must share a common type (a missing `else` is a type error, not a
silent `undefined`) and it lowers to a phi/select.

**Where in code.** `parser.zig`, `type_checker.zig` (arm-type unification), `expressions.zig` (value lowering).

**Data it produces.** A branch (statement) or a phi/select value (expression).

**Gotchas.** Using `if` where a value is expected without an `else` is a type error by design.

**How to change it safely.** The corpus covers both forms.

### 6.2 while

**What it is.** `while (cond) { ... }`. **[impl]**

**Why it exists.** The primitive unbounded loop.

**What it does.** Lowers to a condition block plus a body block. For the missing-return analysis (16.3) a
`while (true)` with no `break` is treated as never falling through.

**Where in code.** `src/backend/codegen/statements.zig`.

**Data it produces.** A loop CFG (condition + body blocks).

**Gotchas.** The missing-return rule errs towards "this returns", so it never false-accuses a valid function.

**How to change it safely.** The corpus; the `missing_return` expect_fail case must stay red.

### 6.3 for (four forms)

**What it is.** C-style `for (let i = 0; i < n; i = i + 1)`, exclusive range `for (i in 0..n)`, inclusive range
`for (i in 1..=n)`, and collection `for (x in xs)`. `continue` always runs the increment. **[impl]**

**Why it exists.** One keyword covering counted, range, and collection iteration. The range form matters for
performance: it lowers to a clean i64 induction variable that LLVM's scalar-evolution vectorises (the bench
`_for` variants rely on this).

**What it does.** All four desugar to a condition-body-step shape. `continue` jumps to the STEP block (not the
condition), so a C-style loop cannot livelock by skipping the increment. The collection form iterates by index
and READS each element (the `get`-versus-`at` element-fetch fix, task #170, lives here).

**Where in code.** `src/backend/codegen/statements.zig` (the `for` desugaring).

**Data it produces.** A loop CFG with an induction variable (i64 for the range form).

**Gotchas.** Preserve "`continue` runs the increment". For the collection form, ensure the element is READ, not
owned-then-dropped, or you leak/UAF per iteration.

**How to change it safely.** Corpus plus `--asan` for the collection form; the bench `_for` variants confirm the
range form still vectorises.

### 6.4 switch / match

**What it is.** `switch` (statement) and `match` over enum/union variants; `case`/`default`, case guards
(`case v if cond`), enforced exhaustiveness. **[impl]** (See 4.3 for the enum type; this is the pattern-matching
half of the same inventory feature.)

**Why it exists.** Safe destructuring dispatch with a compile-time guarantee that every variant is handled.

**What it does.** Checks arm tags, binds payloads, and rejects a non-exhaustive switch on a typed enum (see 4.3
for the untypeable-discriminant recovery). `break`/`continue` target the innermost loop; there is no labelled
break by choice.

**Where in code.** `statements.zig`/`expressions.zig` (lowering), `type_checker.zig` (`checkSwitch`).

**Data it produces.** A branch table with a bound payload per arm.

**Gotchas.** Keep exhaustiveness honest; silently accepting a missing arm is how a new variant gets ignored at
runtime.

**How to change it safely.** `expect_fail/untypeable_switch_nonexhaustive.nova` plus the corpus.

---

## 7. Functions and closures

### 7.1 Functions

**What it is.** `fn name(p: T, ...): R { ... }`; a non-void function must `return` on every path. Generic
functions are `fn f<T>(...)` with the type parameters scoped to the function's own `<...>`. **[impl]**

**Why it exists.** The basic abstraction; the must-return rule is a soundness gate; the type-parameter scope is
the whitelist that keeps a `T` from being flagged as an unknown type.

**What it does.** The checker proves every path returns (conservatively). A generic function is instantiated per
concrete call by the monomorphiser (5.1); its `<T>` params are passed to the unknown-type check
(`rejectUnimplementedType`) as the whitelist.

**Where in code.** `src/frontend/type_checker.zig` (`stmtDefinitelyReturns`/`blockDefinitelyReturns`,
`rejectUnimplementedType`), `src/frontend/sema/mono.zig` (instantiation).

**Data it produces.** An LLVM function per (function, concrete instantiation).

**Gotchas.** The must-return analysis is deliberately conservative (loops, `switch`, and any
expression-statement count as returning), so it can MISS an exotic missing return but never false-accuses.

**How to change it safely.** `expect_fail/missing_return.nova` stays red and the whole positive corpus stays
green.

### 7.2 Closures / lambdas

**What it is.** `(x: int) => x + 1`; closures capture BY VALUE; a stored multi-argument closure is callable.
**[impl]** (Inventory: Closures / lambdas, SOUND.)

**Why it exists.** First-class functions for higher-order stdlib APIs; capture-by-value is the contract callers
rely on.

**What it does.** A closure is an `(env, code-ptr)` pair with a per-instance heap environment (loop captures are
independent). Creating and dropping a closure reclaims its memory (empirically: 2,000,000 closures stay flat at
~1.2 to 1.4 MB). A call is ARITY-checked always and TYPE-checked for explicitly-typed params; an untyped param
still infers from the call site (so `list.map((x) => ...)` is not rejected). Signatures are tracked per local
(`closure_sigs`), and `let g = f` aliases the signature.

**Where in code.** `expressions.zig` (representation, capture), `type_checker.zig` (`closure_sigs`, arity/type
check).

**Data it produces.** An `(env, code-ptr)` value; the environment is an ARC heap object kept alive while the
closure is live.

**Gotchas.** Do not quietly switch to capture-by-reference (the `closure-capture-by-value` note). Requiring
types on every param would break ~50 legitimate infer-from-context closures, so untyped params inferring from
the call site is intended, not a gap.

**How to change it safely.** Case 393 (typed + aliased + untyped-infer) and `expect_fail/closure_arity_mismatch.nova`,
plus `--asan` for the environment reclaim; the closure-memory measurement (2M flat) is the leak guard.

---

## 8. Error handling (`T | E`, `try`, `catch`, `errdefer`)

**What it is.** Result-style errors: a function returns `T | E`, produced/consumed with `throw`, `try`, `catch`,
and `errdefer` (a deferred action that runs ONLY on the error path). `T | E | undefined` composes optional over
error. **[impl]** (Inventory: Error handling, SOUND.)

**Why it exists.** Value-based errors with no stack unwinding: predictable, cheap, and explicit in the type.

**What it does.** `try` propagates the error arm to the enclosing function; `catch` handles, both arms unifying
to one type; `errdefer` runs LIFO only when the scope exits via the error path (unlike `defer`, which always
runs). An error type carries a `message()`.

**Where in code.** The error-union is the same union machinery as optionals in `types.zig`; `throw`/`try`/`catch`/
`errdefer` lower in `statements.zig`. The model is the `e1-error-model` note.

**Data it produces.** A tagged union value (ok arm or error arm); `errdefer` produces error-path-only cleanup
code.

**Gotchas.** `errdefer` is the subtle one: a mis-lowered `errdefer` either leaks (never runs) or double-frees
(runs on the success path too).

**How to change it safely.** The error-handling conformance case; verify defer/errdefer release counts with
`--asan`.

---

## 9. Optionals and narrowing

### 9.1 Optionals (`T | undefined`) and narrowing

**What it is.** `T | undefined` (sugar `T?`); a present value is DISTINCT from `undefined` for every width,
including a stored `0`/`false`/`0.0` (value optionals are BOXED). Narrowing: `if (x != undefined) { /* x is T */ }`;
`?.` optional member access. **[impl]** (Inventory: Optionals and narrowing, SOUND.)

**Why it exists.** The single most bug-prone corner of the type system: a value optional cannot use a null
pointer for `undefined` because `0` is a legal present value, so "present 0" and "absent" must be physically
different.

**What it does.** A REFERENCE optional uses the null pointer for `undefined` cheaply; a VALUE optional
(`int | undefined`) is BOXED so present-0 never reads as absent. `if (x != undefined)` flow-types `x` to `T`
inside the guarded block; reassigning a narrowed variable invalidates the narrowing; nested optionals from
generics (`Map<K, int|undefined>`) are handled. Member access through an optional is guarded, not a null deref.

**Where in code.** `types.zig` (`valueOptionalName`, boxing); narrowing in the checker/sema; `statements.zig`
tracks the narrowing set.

**Data it produces.** A null-pointer optional (reference case) or a boxed value-optional (value case).

**Gotchas.** The narrowing only understands the direct `!= undefined` / `== undefined` shape; a narrowing hidden
behind a helper is not seen. Passing a value-optional call result DIRECTLY as a nested call argument can crash
(bind to a local first, per the memory note).

**How to change it safely.** `conformance/cases/127_value_optional_zero.nova` (`test_param_widths` covers the
value-optional PARAMETER ABI) under both `run.sh -j` and `--asan`.

### 9.2 `x ?? d` on a narrowed present 0

**What it is.** `??` null-coalescing that yields the STORED value even when it is a present `0`/`false`/`0.0`,
including after narrowing. **[impl]** (Inventory: `x ?? d` on a narrowed present 0, SOUND.)

**Why it exists.** The `??` presence test is `left != 0`; a RAW value-optional stores a present 0 identically to
the absent sentinel, so a present 0 used to read as absent and return the default.

**What it does.** Codegen tracks locals proven present by an enclosing `if (x != undefined)` (a scoped
`narrowed_present` set, populated per-branch in `statements.zig` and invalidated on reassignment); `??`
short-circuits a narrowed-present RAW PRIMITIVE left to its present value. Tightly scoped: the BOXED case
already tests the box pointer correctly, and a pointer-typed inner has null==0==absent with no valid present 0,
so only the raw-primitive case is touched (no ARC surface).

**Where in code.** `src/backend/codegen/statements.zig` (the `narrowed_present` set), the `??` lowering in
`expressions.zig`.

**Data it produces.** A select between the present value and the default, with the presence test corrected for
a narrowed-present raw primitive.

**Gotchas.** This replaced three earlier site-local guards that regressed serde/DI/try because they could not
tell a narrowed-present raw from a genuinely-optional raw; do not reintroduce a representational change at the
`??` site. If `x ?? d` ever returns `d` for a present zero, the narrowing tracker broke, not the operator.

**How to change it safely.** Case 392 (present-0 -> 0, genuine-absent -> default, reassign-to-absent -> default);
the serde/DI/try canaries that broke prior attempts must stay green; corpus 402/405 baseline.

---

## 10. Memory and ownership

### 10.1 Automatic Reference Counting (ARC)

**What it is.** ARC decided at COMPILE time (not a GC): every heap object carries an 8-byte header (refcount at
ptr-8, length at ptr-4); `nova_retain` / `nova_release(ptr, dtor)`. **[impl]** (Inventory: ARC memory
management, SOUND.)

**Why it exists.** Deterministic destruction (defined cleanup timing by scope) without a collector's pauses,
which is the right trade for a server-side language.

**What it does.** Codegen inserts retain/release using the ownership signals from the `TypedIr` (the same
information the OSSA verifier uses); destructors free owned objects at scope exit.

**Where in code.** `src/backend/codegen/arc.zig` (insertion, `acquisitionDisposition`, destructors); primitives
in `src/runtime/` (`nova_abi.h`, `runtime_str.h`).

**Data it produces.** `nova_retain`/`nova_release` calls and per-type destructor functions in the LLVM module.

**Gotchas.** The header offsets (refcount at -8, length at -4) are a hard contract shared by the compiler and
runtime; change them in lockstep or not at all. A leak or double-free is a codegen bug, not a tuning problem.

**How to change it safely.** Verify with `--asan`, NOT just the `--arc` audit (the audit misses use-after-frees
that ASAN catches, per the `arc-measurement-traps` note).

### 10.2 Value versus reference storage

**What it is.** Value structs stored inline (no box), copy by value; classes are shared references. **[impl]**

**Why it exists.** Predictable copying and no per-nested-value box (see 4.1).

**What it does.** Inline layout in `types.zig`, copy-on-assign and recursive nested destruction in `arc.zig`.

**Where in code.** `src/backend/codegen/types.zig`, `src/backend/codegen/arc.zig`.

**Data it produces.** Inline aggregates (value) versus heap pointers (reference).

**Gotchas.** Aliasing sneaking back in (`let b = a` sharing storage) passes the plain corpus and only `--asan`
catches the UAF.

**How to change it safely.** Corpus plus `--asan`.

### 10.3 Deterministic cleanup

**What it is.** Destructors run at scope exit; nested value-struct fields are destructed recursively. **[impl]**

**Why it exists.** Cleanup timing defined by scope (not a collector) so `defer`/`errdefer` and destructors
compose predictably.

**What it does.** Recursive destruction of nested owned fields at scope exit (the `nested-value-struct-dtor-leak`
fix).

**Where in code.** `src/backend/codegen/arc.zig`.

**Data it produces.** Destructor calls at each scope exit.

**Gotchas.** If you add a container or nested aggregate, make its destructor recurse into every owned field,
then prove the release count with `--asan`.

**How to change it safely.** Corpus plus `--asan`.

### 10.4 OSSA-lite ownership verifier

**What it is.** A static proof that ARC is balanced: every owned value is consumed exactly once on every path
(no leak, no double-free), default-on and fail-closed. **[impl]** (Inventory: OSSA static leak/double-free
verifier, SOUND.)

**Why it exists.** To move ARC soundness from ASAN-TESTED to compile-time VERIFIED across the whole corpus.

**What it does.** Lowers each function body into an ownership-only IR and checks the linear-ownership invariant,
reporting LEAK / DOUBLE-CONSUME / USE-AFTER-CONSUME / PATH-IMBALANCE. Coverage is 99-100% of functions; the
reassign deferral bucket is 0 (if/loop/switch/break/continue handled via phis). `NOVA_OSSA=hard` fails the
build on a proven imbalance.

**Where in code.** `src/frontend/sema/ossa/` (`ir.zig`, `lower.zig`, `verify.zig`; `forward.zig` is
measurement-only).

**Data it produces.** A per-path ownership verdict; a build failure under `hard` on a proven imbalance.

**Gotchas.** SOUND but INCOMPLETE: zero false positives, but it does not yet track ownership THROUGH a
destructuring pattern (3.2), so a leak that only happens via `let {a,b} = ...` slips past. This is a compiler
ARC-balance self-check, NOT a Rust-style borrow checker. When you extend ownership handling, extend the OSSA
lowering too or coverage silently narrows.

**How to change it safely.** `conformance/run.sh --ossa -j`; keep `NOVA_OSSA=hard` in `gate.sh`.

---

## 11. Concurrency and the reactor

### 11.1 async / await and spawn

**What it is.** `async`/`await`, and `spawn` (fork, returns a `future<T>`) with `await` (join), on LLVM
coroutines. **[impl]** (Inventory: async / await, SOUND.)

**Why it exists.** Structured asynchrony with real coroutines, backing the single-reactor web model.

**What it does.** An `async fn` compiles to an LLVM coroutine (presplit -> CoroSplit -> `.resume`/`.destroy`);
`spawn` forks and returns a future; `await` joins. Function colouring is enforced (`await`/`spawn` only inside
an `async fn`).

**Where in code.** Coroutine lowering in codegen (`emitCoroPrologue`/`emitCoroEpilogue`); the scheduler in
`src/runtime/concurrency.cpp`; `future<T>` handled by `sema/lower.zig`.

**Data it produces.** LLVM coroutine functions (`.resume`/`.destroy`) driven by the runtime scheduler.

**Gotchas.** A coroutine handle IS a frame address, and freed frames get recycled, so a stale resume can land on
a brand-new coroutine (the most expensive bug class here; read the "coroutine handle is a FRAME ADDRESS" section
of `lang/CLAUDE.md` before touching resume/detach). Use `NOVA_IO_WATCHDOG=1` to separate the failure modes.

**How to change it safely.** The async conformance cases; `NOVA_IO_WATCHDOG=1`/`NOVA_CRASH_TRACE=1` for the
runtime side.

### 11.2 Combinators

**What it is.** `when_all` and `selectAny` over a HOMOGENEOUS future list, plus `async_util.join2<A,B>` /
`join3<A,B,C>` for awaiting DIFFERENT-typed futures together into a typed tuple. **[impl]** (Inventory:
heterogeneous-type combinator, SOUND.)

**Why it exists.** `when_all`/`selectAny` take a list, so their futures must share a type; `join2`/`join3` cover
the heterogeneous case, each result keeping its own static type.

**What it does.** `let (a, b) = await join2<A,B>(spawn fa(), spawn fb())` returns a tuple. All are pure stdlib
(generic async + tuple return, no codegen change).

**Where in code.** `src/lib/std/` concurrency utilities (`async_util.join2`/`join3`).

**Data it produces.** A joined tuple (or a selected result) value.

**Gotchas.** Keep any new `joinN` a plain generic-async + tuple-return function so it needs no compiler support.

**How to change it safely.** Case 395 (`join2` of `(int, string)`, `join3` of `(int, string, int)`).

### 11.3 Channels and actors

**What it is.** A blocking buffered `Channel<T>`, a reactor-aware ASYNC channel, actor mailboxes with
`async receive`, a bounded `asyncchan.AsyncChannel<T>` (backpressure), `asyncchan.selectRecv<T>`, and actor
supervision (`ActorRegistry`, `Supervisor<M>` over a `SupervisedBehavior<M>`). **[impl]** (Inventory: Channels
and actors, SOUND.)

**Why it exists.** Message-passing concurrency for non-web workloads; backpressure and supervision make it a
real actor system ("let it crash", one-for-one restart).

**What it does.** The bounded channel parks a sender when full and a receiver when empty; `selectRecv(channels)`
parks on every channel and wakes on the first delivery, returning its index; `Supervisor<M>` restarts a faulted
behaviour (reset + count) up to `maxRestarts`, then stops it; the registry resolves an actor by name. All are
pure Nova over the single-reactor park/resume (like `AsyncLock`, 11.4).

**Where in code.** `src/lib/std/` (`asyncchan.AsyncChannel`/`selectRecv`, `actor.nova` `ActorRegistry`/
`Supervisor`/`SupervisedBehavior`).

**Data it produces.** Park/resume scheduling over the single reactor; a delivered message or a selected index.

**Gotchas.** The user-facing `channel<T>` is SEPARATE from the runtime's internal cross-reactor WAKE channel
(an eventfd / one-shot io_uring POLL_ADD); do not conflate them. Actors on the current single reactor are
half-baked for the mutex-lock case (the `118_actor` known-red case); the intended home is a future M:N
cooperative threadpool.

**How to change it safely.** Case 396 (capacity-2 backpressure), case 398 (`selectRecv` index), case 399
(restart-twice-then-stop + registry). Do not touch the runtime wake channel.

### 11.4 AsyncLock

**What it is.** The reactor-aware mutex; a blocking OS mutex inside async code is ~70x slower and must not be
used. **[impl]**

**Why it exists.** A plain OS mutex parks the whole reactor and everything it was driving (~70x measured).

**What it does.** Yields the coroutine instead of blocking the OS thread; already used to serialise the mongo
shared connection (`runCommand`).

**Where in code.** `src/lib/std/` (`AsyncLock`), used by the mongo driver.

**Data it produces.** A coroutine park/resume instead of an OS-thread block.

**Gotchas.** Inside `async` code, reach for `AsyncLock`, never a blocking mutex (`i1-proxy-and-socket-strand-limit`
note).

**How to change it safely.** The async/concurrency corpus; watch for reactor stalls with `NOVA_IO_WATCHDOG=1`.

### 11.5 The single-reactor web model

**What it is.** The web server is SINGLE-reactor per process; scale is horizontal (instances behind the proxy),
not in-process worker threads. **[impl] [design]**

**Why it exists.** A firm architectural decision (`web-single-reactor-only`): the in-process multi-core web path
was REMOVED; you scale by running more instances behind `proxyd`.

**What it does.** One reactor drives the web workload; actors/channels/`std::thread` remain for non-web
workloads.

**Where in code.** `src/runtime/concurrency.cpp`; the web framework in `src/lib/std/web/`.

**Data it produces.** One reactor loop per process.

**Gotchas.** Do not reintroduce in-process web worker threads; the horizontal model is what the orchestrator
(proxyd/orchd) assumes.

**How to change it safely.** The web/app conformance cases; the throughput method is in `lang/CLAUDE.md`.

### 11.6 Reactor backends

**What it is.** kqueue (macOS), epoll and io_uring (Linux), IOCP (Windows), selected per target; deadlines are
reactor-native on every backend. **[impl]** (Inventory: Reactor, PARTIAL — see 17 for the platform-blocked
criteria.)

**Why it exists.** One async model over the best mechanism per OS.

**What it does.** The backend is chosen per target by the target-conditional file rule, and on Linux by a
RUNTIME probe (`nova_reactor_backend()`), because a header being present does not mean the kernel enables
io_uring. Readiness on a proactor (IOCP, io_uring) is faked with a zero-byte receive.

**Where in code.** `src/runtime/concurrency.cpp` (`nova_reactor_backend`, the driver), `src/lib/std/net/ev/`
(`epoll`/`kqueue`/`iocp`/`uring`), selected via `targetVariantPath` (`compiler-lld.md` 3.2.2).

**Data it produces.** Reactor submissions/completions per backend.

**Gotchas.** On a PROACTOR the KERNEL owns the op record until the op completes or is cancelled, so "give up and
free it" corrupts the next op; `abandonOp` is the seam that answers who still owns the record. Required reading:
the reactor sections of `lang/CLAUDE.md`.

**How to change it safely.** The reactor conformance corpus, ONE backend at a time (a genuinely multi-threaded
case like `195` can phantom-fail under `-j`; re-check sequentially). IOCP readiness (192/194/195) and io_uring
multishot are PARTIAL and platform-blocked (section 17).

### 11.7 Atomic<T>

**What it is.** `Atomic<T>` for lock-free shared state: `load`/`store`/`compareAndSwap`/`add`/`sub`/`delete` on
`int` (i32) and `long` (i64); an invalid element type (`Atomic<string>`) is rejected at compile time. **[impl]**
(Inventory: `Atomic<T>`, SOUND.)

**Why it exists.** Lock-free primitives for shared counters/flags without a mutex.

**What it does.** The operations are a CODEGEN INTERCEPT (`compileAtomicCall`) lowering to the runtime
`nova_atomic_*_i32` / `nova_atomic_*_i64`, not the stub stdlib body; only i32 and i64 element types are legal.

**Where in code.** `src/backend/codegen/` (`compileAtomicCall`), `src/runtime/` (`nova_atomic_*`); the
compile-time element-type rejection in the checker.

**Data it produces.** Atomic LLVM/runtime operations on i32/i64.

**Gotchas.** An earlier "stub" mark came from reading the dead stdlib source; the real path is the intercept, so
trace `compileAtomicCall` and the runtime, not the `.nova` stub. If you widen the element set, add the runtime
primitive AND the element-type check together.

**How to change it safely.** Case 31_atomics (7/7), probed for int and long, ASAN-clean.

---

## 12. Serialization, FFI, and attributes

### 12.1 Serialization (`@serializable`)

**What it is.** `@serializable` on a struct generates bind/serialise code; JSON and BSON are supported, YAML
parsing exists; serde is SYNCHRONOUS. **[impl]**

**Why it exists.** Mechanical, error-prone boilerplate is generated as real AST so it is type-checked and owned
exactly like user code; the same path is the ORM bind.

**What it does.** `generateSerdeBinders` emits `__bind`/serialise functions before type checking. A
`@serializable` struct with `Str` fields binds ZERO-COPY from the DB wire.

**Where in code.** `src/pipeline.zig` (`generateSerdeBinders`, ~line 944).

**Data it produces.** Generated bind/serialise AST (type-checked like hand-written code).

**Gotchas.** Serde is synchronous by design; the DB drivers depend on the sync bind, so do NOT make it async.
There is a known YAML-parse leak tracked separately.

**How to change it safely.** The serde corpus cases plus `--asan` (a mis-generated binder leaks or double-frees);
the ORM zero-copy story is the `orm-str-and-index-hoist` note.

### 12.2 Foreign function interface (`extern`)

**What it is.** `extern` declarations bind named C symbols. **[impl]**

**Why it exists.** How the OS layer and some runtime shims are reached; C++ has no stable ABI, so everything is
reached through a thin `extern "C"` shim.

**What it does.** Binds C symbols BY NAME only (no C++ name mangling, no class ABI).

**Where in code.** The `extern` binding in the frontend; the runtime `.cpp` shims in `src/runtime/`.

**Data it produces.** A direct call to a named C symbol.

**Gotchas.** You cannot bind a mangled C++ symbol directly; write a small `extern "C"` wrapper and bind that
(the `ffi-landed` and `m14-max-ffi-reach` notes cover the reach).

**How to change it safely.** The FFI conformance cases; a new native dependency needs its `extern "C"` shim.

### 12.3 Attributes

**What it is.** `@test` marks a `nova test` function; `@serializable` drives serde; `@nova_*` are internal
compiler intrinsics (not user surface). **[impl]**

**Why it exists.** A small, explicit attribute surface for the two user-facing behaviours (testing, serde).

**What it does.** `@test` discovery collects the `@test` functions defined in the USER's files (filtered by
`fd.span.file`), not the stdlib's; `@serializable` is consumed by the generator (12.1).

**Where in code.** `src/tester.zig` (`collectTestFunctions`), `src/pipeline.zig` (serde).

**Data it produces.** The set of test functions to run; generated serde code.

**Gotchas.** `nova test` SKIPS `main()` (a measurement trap; use `NOVA_ARC_AUDIT=1` to see survivors). See 15.6.

**How to change it safely.** Keep the `@test` filter keyed on `span.file` matching the user's requested paths;
the corpus plus a manual `nova test` on a fixture.

---

## 13. Type-system rules

### 13.1 Static, nominal typing

**What it is.** Static, nominal typing; monomorphised generics, no runtime type erasure. **[impl]**

**Why it exists.** Identity by declaration (not shape) so two structs with the same fields are different types;
the authoritative engine is the TypeId engine, not codegen.

**What it does.** The engine infers a `TypeId` per expression and reasons over interned identities.

**Where in code.** `src/frontend/sema/` (`infer.zig`, `symbols.zig`, `subst.zig`, `builtins.zig`, `inst_disp.zig`).

**Data it produces.** The `TypedIr` (type + ownership per expression) — see `compiler-lld.md` 3.8.

**Gotchas.** Add a typing rule HERE, never in codegen.

**How to change it safely.** `NOVA_SEMA_SHADOW=1` across the corpus (any new name-vs-TypeId disagreement is a
regression).

### 13.2 Module-scoped type identity

**What it is.** Same-named structs in different modules coexist as distinct types (module-unique mangled names).
**[impl]**

**Why it exists.** Prevents cross-module symbol collisions and is exactly what makes two package versions
coexist (14.3).

**What it does.** The mangle prefix comes from the source file path (`getModulePrefix`), so `a/store.nova`'s
`Row` and `b/store.nova`'s `Row` mangle apart automatically.

**Where in code.** `getModulePrefix` in the codegen mangling path.

**Data it produces.** Distinct mangled symbols per module.

**Gotchas.** A same-name-across-modules dispatch bug was fixed once (`async-owned-struct-uaf`); if you change
mangling, that class of bug is what to re-test.

**How to change it safely.** The corpus plus `--asan`; multi-version resolution is covered by
`conformance/pkg-acceptance.sh`.

### 13.3 Honest integer widths in the ABI

**What it is.** `int` is 32-bit and `long` is 64-bit everywhere, INCLUDING the ABI. **[impl]**

**Why it exists.** A runtime shim that returns a 64-bit handle must be typed `long` on the Nova side or the
value is truncated at the boundary.

**What it does.** Widths are honoured end-to-end in `types.zig` and the runtime ABI headers.

**Where in code.** `src/backend/codegen/types.zig`, `src/runtime/nova_abi.h`.

**Data it produces.** i32/i64 values that match across the FFI boundary.

**Gotchas.** "Even in the ABI" is the part people forget (see 2.1).

**How to change it safely.** The FFI cases plus any runtime-shim change built and run.

### 13.4 One assignability predicate

**What it is.** One predicate (`assignable`) governs assignment, call arguments, and returns: equal/compatible
types, allowed numeric widening, struct->trait widening; it REJECTS int narrowing and signedness mismatch.
**[impl]**

**Why it exists.** So assignment, arguments, and returns can never disagree about what coerces.

**What it does.** A single function decides coercion for every position.

**Where in code.** `src/frontend/type_checker.zig` (`assignable`).

**Data it produces.** Accept/reject decisions (diagnostics).

**Gotchas.** If you need a new coercion, change this ONE function; a special case at the call site creates a
rule that holds for arguments but not assignments.

**How to change it safely.** The corpus; int-narrowing and signedness-mismatch expect_fail cases stay red.

---

## 14. Modules, packages, and visibility

### 14.1 Imports and visibility

**What it is.** `import name;` resolves by the dependency's DECLARED name; `pub` controls cross-module
visibility. **[impl]**

**Why it exists.** Cargo-style naming: the import name comes from the dependency's OWN `project.json` `name`,
not the folder.

**What it does.** The resolver reads the dependency's manifest to learn what `import X` means; anything not `pub`
is module-private.

**Where in code.** `src/pipeline.zig` (`resolveImportPath`); `pub` enforced in type checking.

**Data it produces.** A resolved source path per import.

**Gotchas.** If an import fails to resolve, trace the attempt order (stdlib, importer-relative, local `packages/`,
then the version-keyed cache).

**How to change it safely.** `conformance/pkg-acceptance.sh` plus the corpus.

### 14.2 The standard library

**What it is.** Written in Nova, imported by short names (`string`, `list`, `map`, `json`, ...). **[impl]**

**Why it exists.** Writing the stdlib in Nova keeps the language honest: if a feature is awkward for the stdlib,
it is awkward for users.

**What it does.** Compiled from source on each build (the import graph gates which modules are pulled in); short
names resolve first.

**Where in code.** `src/lib/std/`; short-name registration in `src/pipeline.zig`.

**Data it produces.** Ordinary Nova declarations merged into the program.

**Gotchas.** To ADD a module, add the `.nova` file AND register its short name; a platform-specific module uses
the `targetVariantPath` layout. `nova test` does NOT re-run the stdlib's own `@test`s (15.6).

**How to change it safely.** A `@test` in the module plus the corpus and `--asan`.

### 14.3 The package manager

**What it is.** `project.json` deps are `url[#ref]` strings; a flat `project.lock.json` records the declared
name and resolved git SHA per dep; the cache is `~/.nova/cache/<name>-<sha8>`; two versions coexist. Commands:
`get`, `restore`, `update`, `publish`. **[impl]**

**Why it exists.** Two facts explain the whole design: git SHAs ARE the version lock and integrity check
(content-addressed), and the mangle prefix is path-derived (13.2), so two versions at different cache paths
mangle apart and coexist with no codegen change.

**What it does.** Resolution is transitive and cache-deduped; `nova build`/`nova test` HONOUR the lock and never
move a pin (only `get`/`update` move a SHA); imports resolve PER OWNING PACKAGE. An optional Cargo-style registry
+ semver range resolution exists (`src/registry.zig`, `src/semver.zig`): a name+range dep is rewritten to a
concrete `url#ref`, additive so git-URL deps are untouched.

**Where in code.** `src/packages.zig` (fetch/lock/resolve, the commands), `src/pipeline.zig`
(`findOwningManifestDir`, `resolveVersioned`), `src/registry.zig`, `src/semver.zig`. Locked contract:
`docs/design/pkg-manager.md`.

**Data it produces.** A resolved, locked dependency tree in the cache.

**Gotchas.** Do NOT add scope (a registry, semver, MVS) without re-opening `pkg-manager.md`. The recorded
out-of-scope limitation is supply-chain trust (the recursive fetch trusts each package's declared dep list);
`nova vendor` is the first future step.

**How to change it safely.** `conformance/pkg-acceptance.sh` (6 items, local `file://` repos, no network) plus
`zig test src/semver.zig`/`src/registry.zig`; wired into `gate.sh`.

---

## 15. Compiler and tooling (summary)

This section is a SUMMARY; the full stage-by-stage account is `compiler-lld.md`. Read that to change the
compiler; read this to know what the toolchain offers.

### 15.1 The compiler in one paragraph

`nova` is a single Zig 0.16 binary. It resolves every `import` and merges all reachable files into one program,
generates synthetic boilerplate (serde binders, the web mediator, routes), alpha-renames, assigns expression
ids, type-checks, runs the authoritative TypeId semantic analysis, monomorphises only what is reachable from
`main`, optionally verifies ARC ownership balance, then generates one LLVM module, optimises it (O0 debug, O3
release), emits object files, and links against the C++20 runtime. Exact order: `builder.zig` `compileProgram`;
stages in `compiler-lld.md` section 3.

### 15.2 What the toolchain offers

- **Targets.** Native macOS, Linux, Windows on x86_64 and arm64 (primary); WebAssembly via `wasm-ld`
  (secondary). Cross-compilation from any host via the bundled `zig c++`; `--target windows-x86_64` makes a
  real PE32+ `.exe`. **[impl]**
- **Diagnostics.** `file:line:col` with a source line and caret; a user mistake reads as one line, not a Zig
  stack trace (`userErrorHint`). **[impl]**
- **Incremental build cache.** `nova build` hashes sources, profile, link libraries, and the compiler mtime, so
  an unchanged project short-circuits and a toolchain change forces a rebuild. **[impl]**
- **Demand-driven monomorphisation.** Only generic methods reachable from `main` are emitted (`sema/reach.zig`),
  the main build-speed lever. **[impl]**
- **Object emission.** One combined `<app>.o` by default; `--split-objects` gives per-file objects with a
  content-hash cache; `--emit-llvm` writes the `.ll`. **[impl]**
- **Sanitiser/verifier gates.** `--asan`, `--tsan`, `--arc`, and `NOVA_OSSA=hard`. Verify memory changes with
  `--asan`, not just `--arc`. **[impl]**
- **Self-contained delivery.** Release builds static-link LLVM; six bundles each carry `nova` + `nls` + the
  stdlib + a checksum. **[impl]**

### 15.3 CLI surface

`nova <file>`, `nova build [--release]`, `nova test`, `nova init <console|web|desktop>`,
`nova get|restore|update|publish`, `nova fmt`, `nova add feature`. User-facing build options are CLI flags;
`NOVA_*` environment variables are compiler-internal debug switches (`compiler-lld.md` section 6). **[impl]**

*Dispatch is in `src/cli.zig`, delegating to `builder.zig`/`tester.zig`/`scaffold.zig`/`packages.zig`/`format.zig`.
Add a user option as a flag; if it changes the OUTPUT, fold it into the build stamp.*

### 15.4 In-editor debugger

**What it is.** Debug builds emit DWARF line tables and DITypes, driven in VS Code by `lldb-dap`, with optional
Python data-formatters for C#-quality value display. **[impl]** (Inventory Stream 4: Debugger, PARTIAL —
non-macOS wiring + full formatter coverage remain.)

**Why it exists.** So a Nova program can be stepped and inspected in a standard editor with readable values,
rather than raw pointers, using the platform debugger rather than a bespoke one.

**What it does.** Release builds are O3 and carry no DWARF; debug builds emit line tables from statement spans
and DITypes for the value display. The optional formatters expand `List`/`Map`/`Set` elements, struct fields,
and borrowed `str.Str` text.

**Where in code.** DITypes in `backend/codegen/llvm_codegen.zig`, line tables in statement lowering; formatters
at `~/.nova/std/debug/nova_formatters.py` (source in `src/lib/std/debug/`). Full detail: `compiler-lld.md` 4.5.

**Data it produces.** DWARF line tables and DITypes in the debug object; on macOS the DWARF stays in the `.o`
with OSO stubs (so `dwarfdump` on the executable shows "zero DWARF"; `dsymutil` collects it).

**Gotchas.** `lldb-dap` renders a pointer as its raw address and an aggregate as a summary, so strings and
containers are single-member aggregate DWARF types; the formatters MUST degrade gracefully when Python is
absent. VS Code uses the Homebrew `lldb-dap` on PATH, not Apple's.

**How to change it safely.** Build a debug binary, set a breakpoint (including in a `.nsx` view line), and
confirm values render; the formatters must still work with Python absent.

### 15.5 Language server and editor extension

**What it is.** `nls` (pure Zig, bundled) reuses this repo's frontend, so completion/hover/definition/symbols/
semantic-tokens see the same types the compiler does; a VS Code extension adds highlighting and NSX. **[impl]**
(Inventory Stream 4: LSP, PARTIAL — semantic cross-file rename/references and cross-file diagnostics remain.)

**Why it exists.** Reusing the compiler frontend (rather than a second, approximate parser) is what keeps the
editor's type view in agreement with the compiler.

**What it does.** Serves completion, hover, definition, symbols, semantic tokens, and (single-file) rename,
references, and code-actions over the shared frontend; the extension provides syntax highlighting and `.nsx`
support.

**Where in code.** `nls` is a separate repo version-locked to lang (`scripts/check-version-sync.sh`); the
extension is `extension/`.

**Data it produces.** LSP responses (completions, hovers, symbols, tokens) computed from the same types the
compiler infers.

**Gotchas.** If `nls` drifts from the compiler frontend, the editor's type view disagrees with the compiler.
Cross-file (import-resolved) rename/references and diagnostics are PARTIAL (currently text-based/single-file,
section 17).

**How to change it safely.** The `nls` repo's own tests plus a manual editor session; keep the version-sync
check green so `nls` and the compiler frontend stay locked.

### 15.6 The `nova test` runner

**What it is.** `nova test [file]` runs the `@test` functions in the file you name (or across the project),
ONLY yours, not the stdlib's; a file with no `@test` is still COMPILED and reports "0 passed, 0 failed".
**[impl]** (Inventory Stream 4: test runner, PARTIAL — coverage/benchmarks/name-filters/fixtures remain.)

**Why it exists.** Re-running the stdlib's own `@test`s on every `nova test` would be noise (they are already
covered by the conformance corpus), so the runner scopes to the user's tests; still compiling a no-test file
keeps a mistake catchable.

**What it does.** `collectTestFunctions` collects `@test`s whose `fd.span.file` (stamped by the parser) matches
the files the user asked to test, builds a harness, compiles, and runs with a pass/fail tally.

**Where in code.** `src/tester.zig` (`collectTestFunctions` filters by `fd.span.file`).

**Data it produces.** A compiled test harness binary and a pass/fail tally.

**Gotchas.** Two coupled rules: (1) the `span.file` filter excludes stdlib/package tests; (2) when zero user
tests are found, the runner must NOT return before type checking (it falls through to a trivial 0-test harness
so the file is still compiled — skipping this would silently un-check an expect_fail case with no `@test`).
`nova test` SKIPS `main()`; use `NOVA_ARC_AUDIT=1` for survivors.

**How to change it safely.** Keep the filter keyed on `span.file`; the corpus runs every case via `nova test`.

---

## 16. Soundness checks the compiler enforces

Each check lives in `src/frontend/type_checker.zig`, is proven by a `conformance/expect_fail/*.nova` case that
MUST stay rejected, and must not reject any positive corpus case. Full context: `compiler-lld.md` 3.7.

### 16.1 Argument checks

**What it is.** Argument COUNT per call, plus a cross-CATEGORY scalar argument check (a `string` where an `int`
is expected). **[impl]**

**Why it exists.** To reject the dangerous confusions without blocking legal numeric widening.

**What it does.** `checkArgTypes` with `primCategory` fires only when both sides are KNOWN primitives of
DIFFERENT categories (numeric/boolean/text/other), so it never guesses.

**Where in code.** `src/frontend/type_checker.zig` (`checkArgTypes`, `primCategory`).

**Data it produces.** Diagnostics.

**Gotchas.** Category-based, not exact-type, on purpose.

**How to change it safely.** `expect_fail/arg_type_category_mismatch.nova` plus the corpus.

### 16.2 Unknown type names

**What it is.** An unknown type in a signature or struct field is rejected (`unknown type 'Frob'`).
**[impl]**

**Why it exists.** To catch typos/missing types before lowering.

**What it does.** `rejectUnimplementedType` with `isKnownTypeName`; builtin generics (`future`/`channel`) are
whitelisted and synthetic `<...>` sources are skipped; the function's own type parameters are the whitelist.

**Where in code.** `src/frontend/type_checker.zig` (`rejectUnimplementedType`, `isKnownTypeName`).

**Data it produces.** Diagnostics.

**Gotchas.** A false positive here is almost always a missing whitelist entry, not a reason to remove the check;
it covers signatures and struct fields but not a `let x: Frob` local (a later pass — section 17).

**How to change it safely.** `expect_fail/unknown_type_annotation.nova` plus the corpus.

### 16.3 Missing return

**What it is.** A non-void function that can finish without returning is rejected. **[impl]**

**Why it exists.** To reject a real bug class while never blocking a valid program.

**What it does.** `stmtDefinitelyReturns`/`blockDefinitelyReturns`, conservative (loops, `switch`, any
expression-statement count as returning), so zero false positives at the cost of possibly missing an exotic
case.

**Where in code.** `src/frontend/type_checker.zig`.

**Data it produces.** Diagnostics.

**Gotchas.** Erring towards acceptance is intentional: a false accusation blocks a correct program, a miss is
caught later.

**How to change it safely.** `expect_fail/missing_return.nova` plus the whole positive corpus.

### 16.4 The rest, and type-checker fail-closed

**What it is.** Trait-to-concrete narrowing at a call argument, tuple-destructure arity, return-type mismatch,
ambiguous cross-module calls, and the OSSA verifier. Fail-closed is not yet TOTAL. **[impl]** (Inventory:
Type-checker fail-closed, PARTIAL.)

**Why it exists.** Narrowing (trait to concrete) is the unsafe direction and must be spelled `as Concrete`;
widening (concrete to trait) is always safe. "Ambiguous cross-module call" exists because same-named types
coexist across modules.

**What it does.** The high-value positions fail closed (arity, non-bool condition, optional/error where a plain
value is required, return-type mismatch). A handful of genuinely-untypeable expressions still fall through the
remaining `resolveExprType(...) orelse return` sites — defence-in-depth, not a live bug, BLOCKED on resolver
completeness (task #174).

**Where in code.** `src/frontend/type_checker.zig` (the first four checks); the OSSA verifier is `sema/ossa/`
(gated by `NOVA_OSSA=hard` and `run.sh --ossa`).

**Data it produces.** Diagnostics (and a build failure under the OSSA hard gate).

**Gotchas.** Flipping the condition site to fail-closed today regresses because a few STDLIB method-call
conditions have a return type the resolver cannot yet determine; the path forward is `.call`/method
return-type resolution (#174).

**How to change it safely.** The matching expect_fail cases plus the corpus; all wired into `gate.sh`.

---

## 17. Non-goals and known gaps

The honest boundary: what Nova deliberately does NOT do, and what is known-incomplete. A maintainer reads it to
avoid two mistakes: "fixing" a settled non-goal, and assuming a gap is covered when it is not.

### 17.1 Settled non-goals (do not "fix")

- **WASM is secondary, best-effort**; native is primary (decision 2026-07-28). Do not block a native feature on
  WASM parity. **[design]**
- **Actors are not the web concurrency model.** The web server is single-reactor plus horizontal scale (11.5).
  Actors and `channel<T>` are KEPT but off the beta path; their intended future home is a Swift-style M:N
  cooperative threadpool. Before deleting them, re-read the runtime-wake-channel note in 11.3. **[design]**
- **No registry proxy, no MVS.** Git SHAs are the version lock and integrity mechanism; different pins coexist,
  so there is nothing to unify. Locked in `pkg-manager.md`. (An OPTIONAL Cargo-style name+semver registry layer
  exists additively, 14.3, but the git-pin model remains the default.) **[design]**
- **ARC, not a GC, and not a borrow checker.** OSSA-lite is a compiler ARC-balance self-check, not a Rust-style
  borrow checker (10.4). **[design]**

### 17.2 Known-incomplete (real gaps)

- **Ownership through destructuring.** The OSSA verifier does not yet track per-binding ownership through
  `let {a,b} = ...` (3.2, 10.4). **[open]**
- **The soundness checks are scoped.** Missing-return covers function bodies; unknown-type covers signatures and
  struct fields but not a `let x: Frob` local (16.2). **[open]**
- **Type-checker fail-closed is not total.** A handful of genuinely-untypeable expressions still fall through;
  blocked on resolver completeness (task #174, 16.4). **[open]**
- **Reactor on non-host backends.** IOCP readiness (cases 192/194/195) and io_uring multishot-recv / SQPOLL are
  PARTIAL and PLATFORM-BLOCKED (IOCP is Windows-only, io_uring is Linux-only), so neither is falsifiable on a
  macOS checkout (11.6). **[open]**
- **Three known-red corpus cases**, each understood, so do not treat them as regressions: `118_actor` (a
  half-baked actor mutex lock under the single-reactor model), `189_epoll` (asserts epoll struct layout,
  inapplicable off Linux, with a kqueue twin `188` inapplicable off macOS), and `42_nested` (a nested
  value-optional aggregate). A FOURTH red case is a regression. **[open]**

---

*This document tracks the language surface implemented by `src/frontend/`, `src/backend/codegen/`, the C++20
runtime in `src/runtime/`, and the Nova stdlib in `src/lib/std/`. It is kept in correspondence with Stream 1 of
`docs/feature-inventory.md`: when you land or change a language feature, update both, and update the matching
seven-part entry here so the next maintainer inherits the truth, not the history.*
