# Nova compiler: low-level design

This is the design document for the Nova compiler. It is written top down: first the whole architecture and
how the pipeline fits together, then each part of the pipeline in order, and inside each part its purpose, the
components it is built from, and what each component and its functions do. The goal is that a maintainer reads
this once and understands the shape and the reasoning, then uses the per-file reference sections
(`10-*` through `50-*` in this folder) as the function-by-function appendix.

The compiler is written in Zig 0.16. It turns Nova source into LLVM IR, then a native object, then a linked
binary. The runtime that binaries link against is a separate C++20 project in `src/runtime/` and is out of
scope here.

---

## Part 0. The whole architecture

### 0.1 What the compiler does

Nova is a statically typed, ES6/TypeScript-flavoured language. The compiler is a classic multi-stage
translator with one optional extra path (the optimiser). The stages, and the artefact that flows out of each,
are:

```
source text
  -> lexer            -> token stream
  -> parser           -> AST (untyped)
  -> type checker     -> AST (checked, obvious errors rejected)
  -> sema             -> typed IR (AST + a TypeId on every expression + ownership sets + monomorphised set)
  -> codegen          -> LLVM IR module
  -> LLVM + linker    -> native object -> executable

        (optional, off by default)
  sema's typed IR
  -> optimiser        -> HIR -> MIR -> LIR, run passes, then either emit LLVM directly (NOVA_OPT_EMIT)
                         or just report a shadow diff (NOVA_OPT). Per function, the emit path falls back
                         to codegen for anything it does not yet handle.
```

Everything above the optimiser line is the shipping path and is always on. The optimiser is a newer,
gated, in-progress second backend.

### 0.2 The five parts

The rest of this document is organised as five parts, matching the pipeline:

1. **Frontend: source to AST** (Part 1) - lexer, parser, AST. Turns text into a tree.
2. **Type checking and semantic analysis** (Part 2) - type checker plus the `sema/` cluster. Turns the tree
   into a *typed* tree with ownership and monomorphisation decided.
3. **Backend: codegen** (Part 3) - `codegen/`. Turns the typed tree into LLVM IR.
4. **The optimiser** (Part 4) - `optimiser/` plus `codegen/lir_emit.zig`. The optional second backend.
5. **The driver and CLI** (Part 5) - the top-level `src/*.zig`. Orchestrates which stages run, plus build,
   test, format, package, and scaffold commands.

### 0.3 The foundations that cross every part

Four ideas span the whole compiler. They are introduced here because you cannot read any single part without
them, and each is expanded where it is implemented.

- **The i64 value word.** Codegen represents every runtime value as a single 64-bit word (`val_type` =
  LLVM `i64`). What the word holds depends on the type: a small integer is the value; a float is the double's
  bit pattern; a string, heap struct, box, or trait object is a pointer; a value struct is the address of its
  inline stack bytes. This uniformity is why almost every function signature is "all i64" and why boxing and
  unboxing happen at type boundaries. Detailed in Part 3.
- **ARC (automatic reference counting).** Memory is not garbage collected. Every heap object has an 8-byte
  header (refcount at ptr-8, length at ptr-4). `nova_retain`/`nova_release(ptr, dtor)` adjust the count;
  destructors are synthesised per type. Ownership (who must retain, who must release) is decided in sema and
  emitted in codegen. Detailed in Parts 2 and 3.
- **TypeId threading.** Sema interns every type into a dense integer `TypeId` and threads it through the IR,
  so later stages decide behaviour from an id rather than by rendering and matching type names. The remaining
  name-based decisions in codegen are the known soundness debt. Detailed in Part 2.
- **Monomorphisation.** Generics are instantiated, not erased: `List<int>` becomes a concrete
  `List_int_*`. A worklist in sema drives instantiation. Detailed in Part 2.

### 0.4 Directory map

| Part | Directory | Files |
|---|---|---|
| 1 Frontend | `src/frontend/` | `lexer.zig`, `parser.zig`, `ast.zig` |
| 2 Types + sema | `src/frontend/` + `src/frontend/sema/` | `type_checker.zig`, `types.zig`; `infer.zig`, `symbols.zig`, `mono.zig`, `ownership.zig`, `subst.zig`, `escape.zig`, `lower.zig`, `alpha.zig`, `builtins.zig`, `ids.zig`, `inst_disp.zig`, `shadow.zig`, `sema.zig` |
| 3 Codegen | `src/backend/codegen/` | `llvm_codegen.zig`, `expressions.zig`, `statements.zig`, `declarations.zig`, `arc.zig`, `types.zig`, `coverage.zig` |
| 4 Optimiser | `src/optimiser/` + `src/backend/codegen/` | `hir.zig`, `mir.zig`, `lir.zig`, `lower_ast_hir.zig`, `lower_hir_mir.zig`, `lower_mir_lir.zig`, `driver.zig`, `pass.zig`, `verify.zig`, `passes/*`; `lir_emit.zig` |
| 5 Driver | `src/` | `main.zig`, `cli.zig`, `pipeline.zig`, `builder.zig`, `tester.zig`, `format.zig`, `packages.zig`, `scaffold.zig`, `templates.zig`, `root.zig` |

The `formatter.zig` (`nova fmt`) sits beside the frontend and is a separate consumer of the AST; it is
covered with Part 1.

---

## Part 1. Frontend: source to AST

### 1.1 Purpose

The frontend turns a flat stream of source characters into a structured, but still untyped, abstract syntax
tree. It is responsible only for *shape*: is this valid Nova grammar, and what tree does it describe. It makes
no type decisions and resolves no names. Its output, the AST, is the contract every later stage reads.

### 1.2 Component: the lexer (`lexer.zig`)

**Purpose.** Convert characters into tokens: keywords, identifiers, literals (int, float, string, template
pieces), operators, and punctuation, each with a source span for error messages.

**How it works.** A single forward scan over the source with one character of lookahead. It recognises
multi-character operators greedily, distinguishes keywords from identifiers via a keyword table
(`tokenTypeFromKeyword`), and has dedicated sub-scanners for string and template literals (which can contain
interpolation) and for numeric literals (including radix forms like `0x...`, where the value is read as a
`u64` and bit-cast, so a high-bit hex literal keeps its full width).

**Its functions.** The `Lexer` struct holds the source and cursor. Its methods are the scanners: the main
`next`/`tokenize` loop, plus helpers for identifiers, numbers, strings, templates, and operator recognition,
each advancing the cursor and producing one token with its span. The reference appendix (`10-*`) lists all of
them.

### 1.3 Component: the parser (`parser.zig`)

**Purpose.** Consume the token stream and build the AST. This is the largest frontend file because it encodes
the entire grammar.

**Structure.** Recursive descent for statements and declarations, with precedence-climbing (Pratt-style) for
expressions. It is organised into four logical component groups:

- **Declaration parsing** - functions, structs and classes, traits and impls, enums, globals, imports. Each
  produces a top-level AST declaration.
- **Statement parsing** - `let`/`const`, assignment, `if`/`while`/`for`, `return`, `break`/`continue`,
  `defer`/`errdefer`, `try`, blocks. Block parsing also establishes the lexical nesting the checker relies on.
- **Expression parsing** - the precedence chain from assignment down through logical, comparison, additive,
  multiplicative, unary, and postfix (calls, member access, indexing), then primaries (literals, identifiers,
  grouping, struct/array/tuple/map construction, closures, template interpolation, NSX/JSX markup).
- **Type parsing** - `parseTypeRef` and `parseTypeRefAtom`, which read a type annotation: named and generic
  types, function types `(A) -> R`, tuple types `(A, B)`, arrays, optionals `T | undefined` and `T?`, and
  error unions `T | E`. A design point worth calling out: a single parenthesised type `(T)` is *grouping*, it
  returns `T` unwrapped; a tuple needs two or more elements; and a nested optional is collapsed because an
  optional is idempotent. Getting this wrong previously turned `(int|undefined)|undefined` into
  `Optional<Tuple<Optional<int>>>` and miscompiled.

**Its functions.** The `Parser` struct holds the token list, cursor, and error state. Each grammar production
is a method; expression precedence is a chain of methods calling the next-tighter level. The full list, in
source order with the precedence chain spelled out, is in the reference appendix (`10-*`).

### 1.4 Component: the AST (`ast.zig`)

**Purpose.** The data structure the whole pipeline reads. It is almost entirely type definitions, not code.

**Contents.** The two central tagged unions are `Expression` (its `ExpressionKind` variant set covers every
expression form: literals, identifiers, binary/unary ops, calls, member and index access, construction of
structs/tuples/enums/arrays/maps, closures, optional chaining and nullish, template interpolation, casts, and
so on) and `Statement`. Alongside them are `TypeRef` (the syntactic form of a type annotation: `ident`,
`generic`, `func`, `tuple`, `optional`, `error_union`, `fixed_array`), and the declaration nodes. Every node
carries a source span. The full variant taxonomy is in the reference appendix (`11-*`).

### 1.5 Component: the formatter (`formatter.zig`)

**Purpose.** `nova fmt`. A second, independent consumer of the AST that walks the tree and re-emits canonical
source text. It shares the AST but nothing else with the rest of the pipeline; it is documented with the
frontend because that is the data it reads.

---

## Part 2. Type checking and semantic analysis

### 2.1 Purpose

This part turns the untyped AST into a *typed* one: every expression gets a `TypeId`, generics are
instantiated, ownership is decided, and semantic errors (type mismatches, unknown names, bad arities) are
raised. Its output is the typed IR that codegen consumes. It is split into a lightweight up-front checker and
a heavier `sema/` engine.

### 2.2 Component: the type checker (`type_checker.zig`) and the type store (`types.zig`)

**Purpose of the checker.** A first, structural checking pass over the AST that catches the obvious errors and
resolves the easy cases before the heavier engine runs. It rejects unimplemented type forms and does the
first-order consistency checks.

**Purpose of the type store (`types.zig`).** The interning table that turns a structural `TypeRef` into a
canonical `Type` with a dense `TypeId`. This is where type identity lives: two spellings of the same type
intern to the same id, and equality is an id comparison. It also answers the structural questions everyone
asks (is this optional, what is the inner type, is this owned).

**Their functions.** The checker's methods walk declarations and statements and call into the store to resolve
annotations. The store's methods are `intern`, the structural predicates, and the ownership queries. Full
lists in the reference appendix (`11-*`).

### 2.3 Component: inference (`sema/infer.zig`)

**Purpose.** The heart of sema. It walks the AST and assigns a concrete `TypeId` to every expression, applying
Nova's inference and coercion rules. It handles the hard cases: closures whose parameter types must be pinned
from how their result is later used, generic call resolution, narrowing of optionals, and unification across
branches.

**Its shape.** An `Inferer` struct carries the working state (the current scope's bindings, the narrowing
facts in force, the statement sequence for closure look-ahead). Inference is per-construct: each expression
and statement kind has its handling. A subtle design point is the closure two-pass: a closure like
`(a, b) => a + b` cannot be typed from its body alone, so inference looks ahead in the enclosing statement for
a call that pins the parameter types. The per-construct handling is in the reference appendix (`20-*`).

### 2.4 Component: symbols and ids (`sema/symbols.zig`, `sema/ids.zig`)

**Purpose.** `symbols.zig` is the symbol table: it assigns every declaration a positional `SymbolId` and
resolves names to symbols across modules (same-named symbols in different modules coexist via module-unique
mangling). `ids.zig` defines the small id newtypes (for example the `ExprId` assigner) that thread through the
IR. These are the naming and identity substrate the rest of sema stands on.

### 2.5 Component: monomorphisation and substitution (`sema/mono.zig`, `sema/subst.zig`)

**Purpose.** `mono.zig` drives generic instantiation. When a generic is used with concrete type arguments, it
builds an instantiation key (owner plus the interned argument TypeIds), dedups against a `seen` set, and adds
the concrete instance to a worklist, with a depth-fuel guard against runaway recursion. `subst.zig` performs
the actual type-parameter replacement inside a generic body, re-interning only when something changed so that
TypeId identity is preserved for unchanged types.

**Why it matters.** This is where a reachability bug bites: if a generic is reachable only transitively (for
example a `Map` reached only through a `Set`), its methods must still be added to the worklist, or codegen
emits a call to a function that was never generated.

### 2.6 Component: ownership and escape (`sema/ownership.zig`, `sema/escape.zig`)

**Purpose.** `ownership.zig` computes, for every local and every temporary, whether it owns a reference that
must be released, feeding the retain/release placement that codegen emits. It has two populations: locals,
found by a control-flow walk, and temporaries, recorded as the IR is built. `escape.zig` computes which value
structs escape their function (returned, stored into a heap field), which decides whether a struct stays an
inline value or is promoted to the heap.

### 2.7 Component: the shadow diff and lowering (`sema/shadow.zig`, `sema/lower.zig`, others)

**Purpose.** `shadow.zig`, despite its "report only" framing, is the file that actually raises the real
type-checking errors and the ownership foundation gate, and it holds the shared TypeId-to-name renderer.
`lower.zig` is sema-side lowering. The remaining small files (`alpha.zig` alpha-renaming, `builtins.zig` the
builtin registry, `inst_disp.zig` instantiation dispatch, `sema.zig` the orchestration entry) round out the
cluster. Details in reference appendices `21-*` and `22-*`.

---

## Part 3. Backend: codegen

### 3.1 Purpose

Codegen turns the typed IR into an LLVM IR module. It is the largest and most intricate part, because it is
where the abstract type model meets a concrete machine ABI. Its central design decision, the i64 value word,
shapes everything else.

### 3.2 The value ABI (read this before the components)

Every value is a single i64 word. The mapping:

| Nova type | i64 word holds |
|---|---|
| int/bool/enum tag | the integer, extended to 64 bits |
| long | the 64-bit integer |
| f32/f64 | the double's bit pattern (f32 is promoted to double) |
| string, heap struct, class | a pointer to an ARC-headed heap block |
| value struct | the address of inline stack bytes (no ARC header) |
| array | a pointer to the elements |
| reference optional (`string\|undefined`) | a nullable pointer: 0 is absent |
| value optional (`int\|undefined`) | a pointer to an 8-byte ARC box (0 absent; a non-null box is present, so present-0 is distinguishable) |
| error union (`T\|E`) | a pointer to a 16-byte box: tag at 0 (0 ok, 1 err), payload at 8; the ok arm is itself value-optional-boxed |
| trait object | a pointer to a 16-byte fat pointer: struct_ptr at 0, vtable at 8 (slot 0 is the destructor) |
| closure | a pointer to a 3-slot box: fn_ptr, env_ptr, cleanup; the env is a separate block of captured words |

Boxing (wrapping a bare value into one of these carriers) happens on the way *into* a slot; unboxing on the
way *out*. Putting a box or an unbox in the wrong place is the most common miscompile in this codebase, which
is why the components below are careful about exactly where those happen.

### 3.3 Component: the compiler core (`llvm_codegen.zig`)

**Purpose.** Defines `LlvmCompiler`, the object that owns all codegen state: the LLVM module and builder, the
function map, the struct and constant tables, the scope and owned-local stacks, and the typed IR handle. The
other codegen files are method mixins on this object (pulled in by `pub const X = mod.X;` re-exports), so in
prose they read as methods.

**What lives here.** The ABI helpers everything else calls: word packing and unpacking (`coerceToSlotType`
and friends), the ARC primitives (`compileRetain`/`compileRelease`), field layout and sizing
(`getFieldOffset`, `toLLVMType`), destructor resolution, string interning (immortal literals via a sentinel
refcount), and the box constructors (`buildValoptBox`/unbox, value-struct storage, `coerceToAny`, trait-object
construction). Also the monomorphisation pre-passes that collect and expand the functions to emit. Full list
in reference appendix `30-*`.

### 3.4 Component: expression emission (`expressions.zig`)

**Purpose.** The single largest file: it lowers every expression kind to IR. `compileExpression` is the entry
point every other file calls; internally `compileExpressionInner` is a switch over the AST expression tag with
one arm per kind.

**Its components (logical groups within the file).** Value-struct storage and copy helpers; the storage and
witness element ABI; trait widening and downcast; ident classification and first-class function boxing; the
per-kind emitters (calls, method and namespaced calls, construction of every aggregate, field and index
access, casts); the optional and nullish seam (where `buildValoptBox`/unbox are inserted); template
interpolation via a StringBuilder; error-union construction and `try`; and the async/await/spawn coroutine
plumbing. It also carries intrinsics that never call a real Nova function (SIMD, `mem.*`/`bytes.*` typed
memory access, decimal). The arm-by-arm detail is in reference appendix `31-*`.

### 3.5 Component: statement emission (`statements.zig`)

**Purpose.** Lowers statements, and crucially owns the ARC scope discipline. `compileStatement` switches over
the statement kind. Its most delicate responsibilities are scope-end releases (owned locals released in
reverse order at block exit), the `defer` and `errdefer` ordering (errdefers run innermost-first, reverse
within a scope, and only on the error path), return handling (retain a returned borrowed value; run all
defers), and loop-exit releases.

### 3.6 Component: declaration emission (`declarations.zig`)

**Purpose.** Emits top-level declarations and builds function signatures. It decides the calling convention
(the flat i64 ABI, arrays passed as pointers, no sret), lays out structs, vtables (slot 0 the destructor),
and enums, wires the native-async coroutine prologue and epilogue, and contains the hook that offers each
function to the optimiser emit path before falling back to AST emission.

### 3.7 Component: ARC and type layout (`arc.zig`, `types.zig`)

**Purpose.** `arc.zig` is the memory model made concrete: the 8-byte header, `nova_retain`/`nova_release`, and
the synthesis and caching of per-type destructors (`__destruct_*` for structs, `__clocleanup_*` for closures),
plus the exact layout of every box (error-union, enum tagged union, closure, trait fat pointer). `types.zig`
(the codegen one, distinct from the frontend `types.zig`) is the layout truth: the `cgPrim` table mapping each
primitive to a representation and signedness, the value-word storage convention, and the value-struct escape
machinery (`isValueStructName`, `computeValueEscapeSet`, heap promotion). These two files are the authoritative
ABI reference; details in appendix `33-*`.

---

## Part 4. The optimiser

### 4.1 Purpose

An optional second backend that lowers the typed IR through three of its own tiers and runs classic
optimisation passes, then either reports a diff against the AST backend (the shadow, `NOVA_OPT`) or emits LLVM
directly (the emit path, `NOVA_OPT_EMIT`). Both are off by default. The emit path is a strict per-function
fallback: anything it cannot prove it handles correctly is handed back to codegen. It is in-progress; the
current coverage and remaining work are tracked in `../optimiser-pending.md`.

### 4.2 Component: the three IR tiers (`hir.zig`, `mir.zig`, `lir.zig`)

**Purpose.** HIR is the highest tier, closest to the AST (keeps node kinds). MIR is the middle SSA-ish tier
where the passes run; its `Inst.Op` union is the real vocabulary (binops, load/store/alloc/gep, call and
indirect_call, retain/release, const_int/const_str/global_const, struct_new and tuple_new, field_get/set,
index_get, template). LIR is the lowest, closest to LLVM. A hard rule: adding an op means updating every
exhaustive switch over it (operand collection, rewriting, side-effect classification, the LIR lowering, and
the inline pass), or the build breaks; this is by design, so nothing silently forgets a new op.

### 4.3 Component: the lowering chain (`lower_ast_hir.zig`, `lower_hir_mir.zig`, `lower_mir_lir.zig`)

**Purpose.** Three sequential lowerings, AST to HIR to MIR to LIR. `lower_ast_hir` also threads the ARC ops
(retain/release) in from the ownership sets. `lower_hir_mir` builds the CFG and desugars (a switch becomes an
if-chain, a C-style for becomes a while). `lower_mir_lir` is the structural stand-in for the shadow.

### 4.4 Component: the passes (`passes/*`) and the pass runner (`pass.zig`, `driver.zig`)

**Purpose.** The classic set: constfold (width-honest, never folds a float binop), mem2reg (promotes memory
slots to SSA), copyprop, dce, simplifycfg, arc_elision (removes redundant retain/release pairs), and inline.
`driver.zig` runs the pipeline; `verify.zig` checks the invariants after each pass (every block terminated,
every value defined before use). arc_elision is wired and runs, but on the current emit subset it is a proven
no-op, so the perf win it represents is still latent.

### 4.5 Component: the emit path (`lir_emit.zig`)

**Purpose.** Turns the optimised MIR into LLVM directly, reusing codegen's helpers so the optimiser's work
actually reaches the binary. Its discipline is a set of gates: `tryEmitInner` checks the signature,
`hirEmittable` and `mirEmittable`/`mirInstEmittable` dry-validate the whole function before any IR is built,
and only then does `emitInst` emit. Anything outside the subset is rejected and the function falls back to
AST codegen, so the emit path can never regress a build. The gates are where the value-optional, trait, and
error-union guards live (the guards that stop a scalar-signature caller from passing a raw word into a
boxed-parameter callee, for instance). Detail in appendix `40-*`.

---

## Part 5. The driver and CLI

### 5.1 Purpose

The top level: parse the command line, decide which stages run, and drive them, plus the build/test/format/
package/scaffold commands and the `~/.nova` install layout that produced binaries depend on.

### 5.2 Components

- **`main.zig`** - the entry point; hands off to `cli.zig`.
- **`cli.zig`** - argument parsing and command dispatch.
- **`pipeline.zig`** - the compile pipeline: a cycle-guarded import walk (`loadProgram`) that merges the whole
  program, target-conditional file selection, the codegen-prelude generators (routes/serde/mediator, which
  emit Nova source and re-parse it), the LLVM object emission, and the link step (in-process LLD, `clang++`,
  or cross via bundled `zig c++`), plus cross-compilation and the `~/.nova` layout.
- **`builder.zig`** and **`tester.zig`** - `nova build` (project.json, profiles, a content-hashed `.o` cache)
  and `nova test` (@test discovery and run). Both set the optimiser emit flags identically.
- **`format.zig`**, **`packages.zig`**, **`scaffold.zig`**, **`templates.zig`** - `nova fmt`, dependency
  fetch into `~/.nova/cache`, and `nova init` app/web scaffolding.
- **`root.zig`** - the module root.

Function-level detail for all of these is in reference appendix `50-*`.

---

## Part 6. Cross-cutting invariants and gotchas

These are the rules that span parts and that a maintainer must not break.

- **The i64-word truncation trap.** A heap address computed as `intAddr + offset` truncates to 32 bits and
  produces a garbage pointer. Heap addresses must be `long`/`ptr`. Address-dependent, so it looks like a
  heisenbug.
- **ARC balance.** Every retain needs a matching release. Over-retain leaks; under-retain is a
  use-after-free. Verify memory changes with `--asan`, not just the `--arc` audit, because the audit misses
  use-after-frees that ASAN catches.
- **Box/unbox pairing.** A value optional, error union, `any`, closure, and trait object are boxes. A value
  that meets a boxed slot must be boxed; a value read out of one must be unboxed. A raw word passed where a box
  is expected is dereferenced as a pointer and crashes.
- **TypeId identity.** Substitution must preserve TypeId identity for unchanged types, or downstream id-keyed
  tables (destructors, monomorphisation dedup) break.
- **The optimiser switch-sync rule.** Adding a MIR op means updating every exhaustive switch over
  `Inst.Op`.
- **Env vars via `init.environ_map.get`**, never `std.posix.getenv`.

## Part 7. Build, test, debug

```
zig build                  # build nova, install to ~/.nova
NOVA_ASAN=1 zig build      # also build the sanitized runtime for the --asan gate
nova <file> -o out         # compile one file
nova test <file>           # run @test (skips main())
conformance/run.sh -j      # the corpus, parallel
conformance/run.sh --asan  # AddressSanitizer gate
conformance/run.sh --arc   # ARC leak gate
```

Debug: `NOVA_DUMP_MERGED=1` dumps merged IR; `NOVA_SEMA_SHADOW=1` diffs the type engines;
`NOVA_OPT_EMIT_VERBOSE=1` logs which functions the emit path took or rejected.

---

## Appendix: per-file function reference

For the exhaustive, function-by-function detail (every public and private function, its signature, side
effects, and gotchas), see the reference sections in this folder: `10-frontend-lexer-parser`,
`11-frontend-ast-types-typecheck-format`, `20-sema-infer`, `21-sema-shadow-symbols-ownership-mono`,
`22-sema-misc`, `30-codegen-core`, `31-codegen-expressions`, `32-codegen-declarations-statements`,
`33-codegen-arc-types`, `40-optimiser`, `50-cli-pipeline-drivers`. This design document is the map; those are
the territory.
