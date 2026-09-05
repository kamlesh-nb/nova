# Kyte Compiler: Low-Level Design

Status snapshot: 2026-08-19.

This document explains **how the Kyte compiler is built**, in enough depth that a developer who has never
seen the codebase can find their way, understand why each piece exists, and change it without breaking the
rest. It is the companion to `language-lld.md` (which describes the language the compiler accepts) and to
`pkg-manager.md`, `demand-driven-mono.md`, `ossa-lite-tasks.md`, and the other design notes (which go deep
on one topic each).

The compiler is one Zig 0.16 binary called `kyte`. It reads Kyte source, lowers it through a fixed pipeline
to LLVM IR, hands that to LLVM for optimisation and object emission, and links the objects against a C++20
runtime to make a native executable.

---

## How to read this document

Every stage and component below is written to the same template, so you can skim to the part you need:

- **What it is**: a one-line identity.
- **Why it exists**: the problem it solves, so you do not remove a constraint that is load-bearing.
- **What it does**: the actual behaviour, step by step.
- **Where in code**: the file, and the function or type to open first. Paths are relative to `lang/`.
- **Data it produces**: what the next stage receives.
- **Gotchas**: the traps that have bitten us before.
- **How to change it safely**: the specific test or gate that proves you did not break it.

Two rules override everything in this document:

1. **Run the corpus before and after every change.** From `lang/`: `conformance/run.sh -j` is the fast
   positive gate (about two minutes), `conformance/run.sh --asan` is the memory gate (needs a
   `KYTE_ASAN=1 zig build` first), and `gate.sh` runs the whole battery. Green before and red after tells
   you exactly what you broke.
2. **Type and ownership decisions are made in the semantic-analysis layer (`src/frontend/sema/`), never
   from the spelled name of a type in codegen.** Deciding ownership from a string like `"Str"` or `"List"`
   was the source of a whole class of corruption bugs. The rule is enforced by a shadow gate (see 4.1).

### Contents

1. Architecture at a glance
2. Source layout
3. The compile pipeline, stage by stage
4. Cross-cutting subsystems
5. Targets, cross-compilation, and linking
6. Diagnostics and debug switches
7. Test and gate infrastructure
8. Recipes: how to make common changes

---

## 1. Architecture at a glance

### 1.1 The languages involved

Kyte is implemented in three languages, each chosen for one reason:

- **The compiler is Zig 0.16.** Zig gives manual memory control with safety checks, a simple module system,
  and first-class LLVM bindings, without a runtime of its own.
- **The runtime is C++20** (`src/runtime/`). It is linked into every native binary and provides the async
  scheduler, the event-loop reactors, sockets, TLS plumbing, ARC primitives, and the decimal engine. C++20
  coroutines and mature libraries are why the runtime is C++ and not Kyte.
- **The standard library is Kyte itself** (`src/lib/std/`). Collections, strings, JSON/YAML/BSON, the HTTP
  and web framework, the DB seam, crypto, concurrency helpers, and regex are all ordinary Kyte code compiled
  from source on every build. Writing the stdlib in Kyte keeps the language honest: if a feature is awkward
  for the stdlib, it is awkward for users.

### 1.2 The one-binary, one-program model

Two design choices shape everything else:

- **One binary.** `kyte` is a single executable. There is no separate front end, optimiser process, or
  assembler. LLVM is linked in (statically in release builds), so `kyte` calls LLVM through its C API in
  process.
- **One merged program.** The first pipeline stage resolves every `import`, parses every reachable file,
  and **merges them all into a single `ast.Program`**. Every stage after that sees one flat list of
  declarations, not a module graph. Module identity survives only as a name-mangling prefix (see 4.3), so
  no later stage has to reason about which file a declaration came from. This is why cross-module bugs are
  almost always resolution or mangling bugs, not "later pass got confused about modules".

### 1.3 The two type engines

Historically the compiler decided types by manipulating **type-name strings**. That was replaced by a
proper **TypeId engine** (interned type identities in `src/frontend/sema/`). During the migration both
engines run and a **shadow gate** (`KYTE_SEMA_SHADOW`) fails the build on any disagreement, so a name-based
decision cannot creep back in. The name layer is being deleted incrementally (tasks #171/#172/#191); until
it is gone, "the two engines must agree" is an invariant you will meet in several places. See 4.1.

### 1.4 The pipeline in one picture

```
                    kyte build <file>
                          |
  ┌───────────────────────┴───────────────────────────────────────────┐
  │ FRONTEND                                                            │
  │  load + resolve imports + merge   →  one ast.Program               │
  │  synthetic code generation        →  serde/mediator/route decls    │
  │  alpha-rename                      →  unique binding names          │
  │  assign expression ids            →  stable ExprId per expression   │
  │  type check                       →  diagnostics (user-facing gate) │
  │  semantic analysis (TypeId)       →  TypedIr: type + ownership      │
  │  monomorphise + reachability      →  the live (type x method) set   │
  │  ownership verify (OSSA-lite)     →  proven release-balance         │
  └───────────────────────┬───────────────────────────────────────────┘
                          |  ast.Program + TypedIr + live-set
  ┌───────────────────────┴───────────────────────────────────────────┐
  │ BACKEND                                                            │
  │  code generation (llvm_codegen)   →  one LLVM module               │
  │  LLVM passes (O0 debug / O3 rel)  →  optimised module              │
  │  object emission                  →  .o file(s)                    │
  │  link (LLD / clang++ / zig c++)   →  native executable             │
  └────────────────────────────────────────────────────────────────────┘
```

The exact call order lives in `src/builder.zig` `compileProgram`. Read that function alongside section 3;
it is the ground truth and this document tracks it.

---

## 2. Source layout

| Path | Responsibility |
|---|---|
| `src/main.zig` | Process entry point. Calls `cli.run`, prints a friendly hint on a user error. |
| `src/cli.zig` | Argument parsing, subcommand dispatch, `userErrorHint` (maps internal errors to one-liners). |
| `src/builder.zig` | `kyte build` / `kyte <file>`: orchestrates the whole compile+link pipeline (`compileProgram`, `cmdBuild`). |
| `src/pipeline.zig` | The reusable pipeline pieces: import resolution, file merge, the four synthetic generators, target derivation, link-command assembly, build-cache stamp. |
| `src/packages.zig` | The package manager: fetch, lock, resolve, and the `get`/`restore`/`update`/`publish` commands. |
| `src/tester.zig` | `kyte test`: collects the `@test` functions defined in the USER's file(s) (not the stdlib's, filtered by source path), builds a harness, compiles, and runs. See `language-lld.md` 15.6. |
| `src/scaffold.zig`, `src/templates.zig` | `kyte init`: project scaffolding and the file templates. |
| `src/format.zig`, `src/frontend/formatter.zig` | `kyte fmt`: the source formatter. |
| `src/frontend/lexer.zig` | Tokeniser. |
| `src/frontend/parser.zig` | Recursive-descent parser, produces the AST. |
| `src/frontend/ast.zig` | The AST node definitions (the data every stage passes around). |
| `src/frontend/type_checker.zig` | The user-facing type checker and most soundness gates. |
| `src/frontend/types.zig` | Frontend type helpers (distinct from the codegen `types.zig`). |
| `src/frontend/sema/` | The semantic-analysis layer: the authoritative TypeId engine, monomorphisation, reachability, ownership. |
| `src/frontend/sema/ossa/` | The OSSA-lite ownership IR, its lowering, and the release-balance verifier. |
| `src/backend/codegen/` | LLVM code generation: `llvm_codegen.zig`, `declarations.zig`, `expressions.zig`, `statements.zig`, `arc.zig`, `types.zig`, `coverage.zig`. |
| `src/runtime/` | The C++20 runtime (`concurrency.cpp` scheduler + reactor, `io.cpp` TLS, `core.cpp`, `alloc.cpp`, `decimal.cpp`, `kyte_abi.h`, `runtime_str.h`). |
| `src/lib/std/` | The Kyte standard library. |
| `conformance/` | The test corpus (`cases/` positive, `expect_fail/` must-reject) and `run.sh` (the harness). |
| `docs/design/` | This document and the per-topic design notes. |
| `packages/kyte-*` | The concrete DB drivers (postgres/mysql/mssql/novadb/mongodb), in-repo for development. |

---

## 3. The compile pipeline, stage by stage

The order below is the real order in `builder.zig` `compileProgram`. Optional stages (escape, ownership
verify, OSSA) are gated by environment variables and do not run in a normal build; they are described where
they sit in the sequence.

### 3.1 Driver and CLI

**What it is.** The entry path: `main.zig` to `cli.run` to `builder.cmdBuild` to `compileProgram`.

**Why it exists.** To turn a command line into a concrete build request (input file, target, profile,
flags) and to make a user's mistake read as a clean message rather than a Zig stack trace.

**What it does.**
- `cli.zig` parses the subcommand (`build`, `test`, `init`, `get`/`restore`/`update`/`publish`, `fmt`) and
  dispatches to the right module.
- `builder.cmdBuild` parses build arguments: `--target`, `-o`, `--release`/`--debug`, `--watch`, and the
  build-tuning flags (`--asan`, `--keep-obj`, `--dump-merged`, `--split-objects`, `--prune`, `--emit-llvm`,
  `--mem-stats`). User-facing knobs are FLAGS; `KYTE_*` environment variables are for compiler-internal
  debugging only.
- It also computes the output path and, in project mode, the `build/<profile>/{obj,bin}` layout and the
  `.build-hash` path.
- Before compiling, it calls `packages.ensureDependencies` so a freshly cloned app fetches its dependencies
  automatically.

**Where in code.** `src/cli.zig` (`run`, `userErrorHint` around line 108); `src/builder.zig` (`cmdBuild`,
`compileProgram`).

**Gotchas.**
- A user error (bad type, missing file) must go through `userErrorHint` so it prints one line. A genuine
  compiler bug may still crash loudly; do not swallow those.
- Environment variables are read with `init.environ_map.get("VAR")`, not `std.posix.getenv` (which does not
  work in this Zig).

**How to change it safely.** Add user options as flags, route the subcommand through the right module
rather than growing `cli.zig`, and if the option changes the OUTPUT, fold it into the build stamp (3.3).

### 3.2 Stage 1: Load, resolve imports, merge

**What it is.** The front door that turns a root file plus its import graph into one `ast.Program`.

**Why it exists.** Every later stage is simpler if it sees one flat program. Resolution, parsing, and
merging are concentrated here so nothing downstream has to know about files or modules.

**What it does.**
1. Preloads `string_builder.ky` from the stdlib (it is needed pervasively), then loads the app's root
   file.
2. For each `import`, resolves the name to a source path, parses the file, and appends its declarations to
   the merged program.
3. Tracks visited files in a set so a cycle (A imports B imports A) terminates.
4. Accumulates a `merged.ky` text used for diagnostics and dumpable with `--dump-merged` /
   `KYTE_DUMP_MERGED`.

**Where in code.** `src/pipeline.zig` (`loadProgram`, `resolveImportPath`, and the helpers below). Called
from `builder.compileProgram`.

#### 3.2.1 The resolver order

An `import X` is resolved by trying, in order: stdlib short-names (`string`, `list`, `json`, ...), a path
relative to the importing file, the local `packages/` directory, and finally the version-aware package cache
`~/.kyte/cache/<name>-<sha8>` when a `project.lock.json` exists (see 4.3 and `pkg-manager.md`). The first hit
wins. If an import "cannot be found", trace this order first: the file was either not reached or resolved to
the wrong copy.

#### 3.2.2 Platform-axis variant selection

Some stdlib modules have a per-OS implementation. `targetVariantPath` (`pipeline.zig` around line 431) takes
a resolved `dir/name.ky` and prefers, in order: `dir/<os>/<arch>/name.ky`, `dir/<os>/name.ky`, then
(for POSIX targets) `dir/posix/<arch>/name.ky` and `dir/posix/name.ky`, and finally the legacy
`dir/name_<os>.ky` suffix. There is a special case for `net/eventloop`, which maps to
`net/ev/<mechanism>.ky` (epoll/kqueue/iocp/uring). This is how the same import gives a Linux program the
epoll unit and a macOS program the kqueue unit without the caller knowing.

#### 3.2.3 The `.ky` / `.nsx` interchange

A resolved import may be either `<path>.ky` or its `<path>.nsx` sibling. `.nsx` is the SAME language, just
the file that holds view/markup code. The resolver tries `.ky` first (so it wins on a tie) and falls back
to `.nsx`. The parser does not care which extension it came from; markup is parsed by the JSX branch either
way (`parseJsxElement` in `parser.zig`), so `.nsx` is a filing convention, not a second grammar.

#### 3.2.4 Merge, cycle termination, and `merged.ky`

Declarations from every reachable file are concatenated into one list. The visited-set makes the graph walk
terminate. The merged text is what `--dump-merged` writes; when a bug looks like "a symbol the code
obviously defines is missing", dump the merged program and check whether the defining file was actually
reached and merged.

**Gotchas.** Do not add per-file special-casing downstream. If resolution picks the wrong file, fix it here.

**How to change it safely.** The package-manager acceptance harness `conformance/pkg-acceptance.sh` (six
items, local `file://` repos, no network) exercises resolution and multi-version coexistence; run it after
any resolver change. It is wired into `gate.sh`.

### 3.3 Build-cache short-circuit

**What it is.** An early check that skips the entire compile when nothing that affects the output has
changed.

**Why it exists.** Rebuilds are common; recompiling an unchanged project is wasted time. Equally important,
the cache must NOT survive a change that would produce a different binary, or a user sees a stale result and
concludes their fix did nothing (this actually happened during the debugger work).

**What it does.** In project (`build`) mode it computes `sourcesHash(files, is_release, asan,
linkLibsStamp)` and compares it to the stored `.build-hash`. If the hash matches AND the output binary
exists, it prints "up to date" and returns without compiling. `linkLibsStamp` folds in the link libraries
and the `~/.kyte/bin/kyte` compiler-binary mtime, so upgrading the compiler forces a rebuild.

**Where in code.** `src/pipeline.zig` (`sourcesHash`, `linkLibsStamp` around line 1947); the compare is in
`builder.compileProgram`.

**Gotchas.** Any new input that can change the output (a new flag, a new codegen mode, a new env var that
alters emission) MUST be folded into the stamp. If you add such an input and forget the stamp, `kyte build`
will hand back a stale binary and the resulting "my fix does nothing" bug is maddening to trace.

**How to change it safely.** After adding a stamp input, verify: build, change only that input, build again,
and confirm it rebuilds rather than short-circuits.

### 3.4 Stage 2: Synthetic code generation

**What it is.** Four generators that emit real Kyte AST for boilerplate the user should not hand-write.

**Why it exists.** Serialisation binders, the web mediator/router dispatch, controller routes, and the
runtime mediator are mechanical and error-prone by hand. Generating them as ordinary AST means they are
type-checked and owned exactly like user code, with no separate trust path.

**What it does.** Runs, in order: `generateControllerRoutes`, `generateSerdeBinders` (bind/serialise for
`@serializable` structs, the ORM bind path too), `generateMediatorDispatch` (the compile-time mediator/
router), and `generateRuntimeMediator`. Their sources carry synthetic file names in angle brackets
(`<mediator-generated>`, `<rmediator-generated>`).

**Where in code.** `src/pipeline.zig`: `generateControllerRoutes` (~776), `generateSerdeBinders` (~944),
`generateMediatorDispatch` (~1392), `generateRuntimeMediator` (~1565). Called from `compileProgram` right
after loading.

**Gotchas.** These run BEFORE type checking, on purpose. Several later checks skip `<...>` sources because
generated code legitimately names types the user never spelled (this is why the unknown-type check exempts
synthetic files, see 3.7). Serde is synchronous by design; the DB drivers depend on the sync bind, so do not
make it async.

**How to change it safely.** A generator change is validated by the serde corpus cases plus `--asan` (a
mis-generated binder leaks or double-frees). If you add a generator, follow the pattern: emit real AST, name
the source `<...>`, and let the normal passes validate it.

### 3.5 Stage 3: Alpha-renaming

**What it is.** A rewrite that makes shadowed bindings unambiguous.

**Why it exists.** Kyte allows a later `let` to shadow an earlier binding in the same scope. If two live
bindings shared a name, every later pass would have to disambiguate them. Renaming once, up front, means
nothing downstream worries about it.

**What it does.** Walks the program and renames shadowing `let`s to fresh internal names, so after this
stage a name identifies exactly one binding.

**Where in code.** `src/frontend/sema/alpha.zig` (`run`).

**Gotchas.** If you add a construct that introduces bindings (a new loop form, a pattern), alpha-renaming
must visit it, or a later pass will confuse the two bindings.

**How to change it safely.** The shadowing corpus cases cover this; add one if you add a binding form.

### 3.6 Stage 4: Expression id assignment

**What it is.** A pass that stamps every AST expression with a stable `ExprId`.

**Why it exists.** The TypeId engine needs to attach a type to each expression WITHOUT mutating the AST. An
id is that attachment key: an overlay maps `ExprId` to type, so the AST stays a pure syntax tree.

**What it does.** Walks the program and assigns each `ast.Expression` a unique `ExprId` (the field defaults
to `.unassigned`; see `ast.zig`).

**Where in code.** `src/frontend/sema/ids.zig` (`Assigner.run`).

**Gotchas.** Ids must be STABLE for the rest of the run. If you rewrite the AST AFTER this pass, you
invalidate the overlay. Rewrite before ids, or re-run ids.

**How to change it safely.** Any AST-producing stage that runs after ids (there are none today by design)
would need to re-number; keep new rewrites before this pass.

### 3.7 Stage 5: Type checking

**What it is.** The user-facing gatekeeper: the pass that produces the errors a programmer sees.

**Why it exists.** To reject ill-typed and unsound programs with a clear `file:line:col` message before any
lowering happens, and to be the home of the compiler's soundness checks.

**What it does.** Runs a battery of checks, each collecting diagnostics with spans:
- **Argument count** per call, and a **cross-category scalar argument** check (`checkArgTypes` with
  `primCategory`): a `string` passed where an `int` is expected is rejected rather than miscompiled. It
  fires only when both sides are KNOWN primitives of DIFFERENT categories, so it never guesses.
- **Unknown type names** in a function signature or struct field (`rejectUnimplementedType` with
  `isKnownTypeName`): `unknown type 'Frob'`. Builtin generics (`future`/`channel`) are whitelisted and
  synthetic `<...>` sources are skipped. The function's own type parameters are passed in as the whitelist.
- **Missing return** (`stmtDefinitelyReturns` / `blockDefinitelyReturns`): a non-void function that can fall
  off the end is rejected. The analysis is deliberately conservative (loops, `switch`, and any
  expression-statement count as returning), so it has zero false positives at the cost of possibly missing
  an exotic case.
- **Trait-to-concrete narrowing** at a call argument, **tuple-destructure arity**, **return-type mismatch**,
  **ambiguous cross-module calls**, and **duplicate type parameters**.

**Where in code.** `src/frontend/type_checker.zig` (`TypeChecker.check` and the named helpers).

**Data it produces.** Diagnostics. It does not lower; it accepts or rejects.

**Gotchas.** Every check here is corpus-GATED: it must reject its matching `conformance/expect_fail/*.ky`
case AND leave every positive case green. The design bias is fail-closed for soundness but zero false
positive for ergonomics: rejecting valid code is worse than missing an exotic bug (which a later pass or
`--asan` still catches).

**How to change it safely.** When you add a check, add its `expect_fail` case in the same change, then run
the whole corpus. See the recipe in 8.4.

### 3.8 Stage 6: Semantic analysis (the TypeId engine)

**What it is.** The authoritative type-and-ownership analysis. It builds the `TypedIr`: for each expression,
its interned `TypeId`, and whether the value is owned.

**Why it exists.** This is where the real type decisions live. Codegen and the ownership verifier both
consume it. It replaced the old string-based type reasoning.

**What it does.**
- Builds a `SymbolTable` (modules, declarations, imports) in `symbols.zig`.
- Infers a `TypeId` per expression in `infer.zig` (the `Inferer`, `inferExpr`; the results are read back
  through `TypedIr.typeOf` / `typeOf2` / `typeOfInst`).
- Interns and substitutes types through `subst.zig`, with builtin type knowledge in `builtins.zig` and
  `TypeRef`-to-`TypeId` lowering in `lower.zig`.
- Runs both the name engine and the TypeId engine and, when `KYTE_SEMA_SHADOW` is set, diffs them and fails
  on any divergence (`shadow.zig`). A `KYTE_TID_CENSUS` mode counts the coverage gaps that still block
  deleting the string fallback.

**Where in code.** Driven by `sema_shadow.run` from `builder.compileProgram` into an owned `Sema`
(`sema/sema.zig` `Sema.create`). Engine files: `infer.zig`, `symbols.zig`, `subst.zig`, `builtins.zig`,
`lower.zig`, `shadow.zig`.

**Data it produces.** The `TypedIr` (type + ownership per expression), consumed by monomorphisation,
ownership verification, and codegen.

**Gotchas.** Add type rules HERE, not in codegen, and keep the shadow gate green. The two-engine agreement
is a temporary invariant; do not add a NEW name-based decision even though the name layer still exists.

**How to change it safely.** Run with `KYTE_SEMA_SHADOW=1` across the corpus; any new disagreement is a
regression. See 4.1.

### 3.9 Stage 7: Monomorphisation and instantiation dispatch

**What it is.** The pass that turns generic code into concrete code: `List<int>` becomes a concrete type
`List_int_*`, and each generic method is stamped per concrete instantiation.

**Why it exists.** Kyte generics are NOT type-erased at runtime; monomorphisation is mandatory. An erased
body exists only as an `internal`-linkage fallback that LLVM's globalDCE deletes.

**What it does.**
- A `Worklist` (`mono.zig`) computes which instantiations are needed and stamps them.
- `inst_disp.zig` dispatches instantiations across the type store, free functions, and methods
  (`run`/`runFreeFns`/`runMethods`).
- A container-nesting cap (currently 2, see the comment at the top of `mono.zig`) stops pathological deep
  nestings like `List<List<List<...>>>` that no real code uses; refused-deeper types are dead anyway because
  reachability (3.10) never emits their bodies.

**Where in code.** `src/frontend/sema/mono.zig` (`Worklist`), `src/frontend/sema/inst_disp.zig`.

**Data it produces.** The set of live instantiations (`sema_mono.live_instantiations`), read by codegen.

**Gotchas.** Distinct instantiations get distinct MANGLED symbol names, and the mangle prefix is
path-derived, which is exactly what makes two package versions coexist (4.3). If you touch mangling, you
touch multi-version packaging.

**How to change it safely.** `--mem-stats` prints instantiation counts; watch them when changing the cap or
the worklist. The whole corpus plus `--asan` is the regression gate.

### 3.10 Stage 8: Reachability pruning (demand-driven monomorphisation)

**What it is.** A reachability analysis that keeps only the functions and methods reachable from the
program's roots, so codegen emits "only what the app uses".

**Why it exists.** The old approach emitted the entire method surface of every generic instantiation (List
alone had 17417 functions, RawBuffer 9330) and let globalDCE delete the roughly 93 percent that were dead
AFTER codegen had already paid to build them. That was the dominant build-speed and peak-memory cost.

**What it does.** From the roots (`main`, plus vtable/serde/closure roots) it walks the call graph and marks
reachable DECLs. Reachability is context-insensitive on type arguments (if `List.push` is reached anywhere,
it is kept for every `List<T>`), which is over-approximate and therefore sound. The same walk drops
unreachable subsystems, so a plaintext app never emits the crypto stack. Default ON for builds;
`KYTE_REACH_OFF` disables it, `KYTE_REACH_SHADOW` prints the report without gating.

**Where in code.** `src/frontend/sema/reach.zig` (`compute`, `publish`, `report`). Wired in
`builder.compileProgram` right after monomorphisation; it sets `reach.gate_on` so codegen consults it.

**Data it produces.** The live (instantiation x method) set that codegen emission is gated on.

**Gotchas.** If a method is reachable only through a path the worklist does not model (a new kind of vtable
slot, a reflected call), it will not be emitted and you get a link error for a method that "obviously"
exists. When you add a new way to REACH a function, teach `reach.zig` about it.

**How to change it safely.** Run with `KYTE_REACH_SHADOW=1` to audit the drop list before trusting a change;
a full corpus run confirms nothing live was dropped.

### 3.11 Stage 9: Escape analysis (report-only)

**What it is.** A may-escape analysis that classifies each owned allocation bound to a local as LOCAL or
ESCAPES.

**Why it exists.** It was built to measure whether a request-scoped arena would pay off. The blanket arena
was scrapped (28 percent slower; ARC follows pointers across the region), so this analysis is currently
REPORT-ONLY and has no codegen effect.

**What it does.** Interprocedural least-fixpoint propagation: a call argument escapes only if the callee's
matching parameter escapes. Default is ESCAPES; a name is LOCAL only when no escape route touches it, so a
wrong LOCAL cannot arise from a missed route. Opt in with `KYTE_ESCAPE_REPORT`.

**Where in code.** `src/frontend/sema/escape.zig` (`analyze`). See `docs/design/p7-sound-arena.md`.

**Gotchas.** Do not wire this into codegen without a measured win; the header comment and the design note
record why the arena was rolled back.

### 3.12 Stage 10: Ownership verification (OSSA-lite)

**What it is.** A static proof that ARC is balanced: every owned value is consumed exactly once on every
path, so there is no leak and no double-free.

**Why it exists.** Before this, ARC soundness was ASAN-TESTED, not compile-time VERIFIED. OSSA-lite gives a
verifier that proves release-balance over the whole corpus.

**What it does.**
- Lowers each function body into a minimal, ownership-aware IR (`ossa/ir.zig`, `ossa/lower.zig`). The IR
  models ONLY ownership events (copy, move, destroy, borrow, return-owned), not arithmetic or control flow
  computation.
- The verifier (`ossa/verify.zig`) checks the linear-ownership invariant and reports LEAK, DOUBLE-CONSUME,
  USE-AFTER-CONSUME, and PATH-IMBALANCE (one predecessor consumed a value, another did not).
- `ossa/forward.zig` is a separate, measurement-only analysis for a future ownership-forwarding optimisation
  (it counts redundant copies; no transform is built, per the "measure before you optimise" rule).

**Where in code.** `src/frontend/sema/ossa/` (`ir.zig`, `lower.zig`, `verify.zig`, `forward.zig`). Also a
sema-level owned-local report in `ownership.zig` (`runVerify`) and a codegen-level ARC balance verifier
toggled by `arc.balance_verify`. Driven by `KYTE_OSSA` (`1` = report, `hard` = fail the build) and
`KYTE_OWN_VERIFY`.

**Gotchas.** The verifier is SOUND but INCOMPLETE: it never false-accuses (zero false positives on the
corpus) but it does not yet track ownership THROUGH a destructuring pattern (`let {a,b} = ...`), so a leak
that only happens that way is not caught. When you extend ownership handling, extend the OSSA lowering too,
or coverage silently narrows.

**How to change it safely.** `conformance/run.sh --ossa -j` runs the verifier over the corpus;
`KYTE_OSSA=hard` fails the build on a proven imbalance. Keep the hard gate in `gate.sh`.

### 3.13 Stage 11: Code generation

**What it is.** The backend: it walks the typed program and builds one LLVM module, then runs LLVM's passes
and emits native object(s).

**Why it exists.** To turn the verified, monomorphised program into machine code, inserting ARC
retain/release and destructors, laying out value types inline, and honouring the honest integer widths.

**What it does.** This is the largest subsystem, so its parts are described separately.

#### 3.13.1 The code generator and its inputs

`declarations.compile` (`declarations.zig` line 72) is the backend entry. It creates the `LlvmCompiler`
(the walk state in `llvm_codegen.zig`), emits the function and type surface, lowers bodies, runs passes, and
emits objects. It consumes the `ast.Program`, the `TypedIr`, and the reachability set.

#### 3.13.2 Type mapping (`types.zig`)

`types.zig` is the single source of truth for how a Kyte type becomes LLVM. It holds:
- The honest-int table (`cgPrim`, `CgRepr`): `int`/`i32` to i32, `long`/`i64` to i64, and the `u*` names,
  with signedness. `reprBitWidth` gives the width.
- Value-struct inline layout: a value struct is laid out as an inline aggregate (no box), so nested value
  fields sit inside their parent. `getStructBaseName`, `isStructType`, and `instantiationsOf` support the
  mangled generic names.
- `valueOptionalName` marks the boxed value-optional types (see `language-lld.md` 9.1 for why value
  optionals are boxed).
- `toLLVMType` / `slotTypeForLocal` map a `TypeRef` to the LLVM type and to a local's stack slot type.

Touch `types.zig` and you touch layout everywhere; a mistake here is an ABI mismatch, not a local bug.

#### 3.13.3 Expression and statement lowering

`expressions.zig` (the largest file) lowers every `ExprKind`; `statements.zig` lowers control flow (the
`for` desugaring, `while`, `if`, `switch`/`match`, `defer`/`errdefer`, `break`/`continue`). JSX/markup
lowering also lives in `expressions.zig`, including `jsxSetLoc` which sets a debug location per markup line
so `.nsx` breakpoints land on the right source line.

#### 3.13.4 ARC insertion (`arc.zig`)

`arc.zig` owns retain/release/destructor insertion. Key entry points:
- `compileRetain` / `compileRelease(ptr, dtor)` emit calls to the runtime `kyte_retain` / `kyte_release`.
- `acquisitionDisposition` / `namesExistingOwner` decide whether an expression yields a new owner or borrows
  an existing one (this is the borrow-vs-own decision that drives whether a retain is needed).
- `getOrCreateDestructor*` build the per-type destructor; a trait object's destructor is vtable slot 0
  (`getOrCreateTraitDestructor`).
- Value-optional boxes and tuple/optional shapes have their own release paths.
- `elide_enabled` (default on) turns on borrowed-field ARC elision; `balance_verify` turns on the
  codegen-level release-balance check; `asan_codegen_enabled` instruments Kyte-generated code with ASAN for
  provenance.

Any change in `arc.zig` risks a leak or use-after-free, so the rule is verify with `--asan`, not just the
`--arc` audit.

#### 3.13.5 DWARF debug info

In debug builds only, `llvm_codegen.zig` emits DWARF: line tables (from statement spans) and DITypes
(`diStringType`, `diStrType`, `diContainerType`, `diStructType`). The rendering details are hard-won: strings
and containers are emitted as single-member aggregate DWARF types so `lldb-dap` shows a summary (`"text"`)
rather than a raw pointer address; the borrowed `str.Str` is a pointer-to-`{ptr, len}` struct so its field
decode reads through the pointer. Release builds are O3 and carry no DWARF.

#### 3.13.6 LLVM passes and object emission

`emitModule` (`declarations.zig` around line 1500) runs the pass pipeline: `default<O3>,globaldce` in
release, `default<O0>,globaldce` in debug (loop and SLP vectorisation and unrolling are explicitly enabled
in release, because the C PassBuilder API defaults them off). `--asan` adds the `asan` pass. Emission is
either one combined `<app>.o` or, with `--split-objects`, per-file objects with a content-hash cache; the
split path clones the module, internalises only the DEAD functions, and globalDCE's them so an unchanged
file can be skipped entirely on the next build. Coroutines get a prologue/epilogue pair
(`emitCoroPrologue`/`emitCoroEpilogue`) so LLVM's CoroSplit produces the `.resume`/`.destroy` functions.

**How to change codegen safely.** The cardinal rule: codegen CONSUMES type and ownership decisions, it does
not make them. If you find yourself deciding a type from a name in codegen, push the decision up to the sema
engine (3.8). Every codegen change goes through the corpus AND `--asan`; a memory change that is green on
`run.sh -j` but red on `run.sh --asan` almost always means aliasing or a dropped destructor.

### 3.14 Stage 12: Linking

**What it is.** The step that turns object files into a runnable binary.

**Why it exists.** The emitted objects need the C++20 runtime, TLS, and per-OS system libraries linked in.

**What it does.** Depending on target and platform:
- **Native macOS, in-process:** an in-process LLD Mach-O link (`linkNativeInProcessMacho`), the fast default
  when not cross-compiling and not using ASAN.
- **Native, general:** assembles a `clang++ -std=c++20` command with the dead-strip flag, PIE flags,
  profile flags (`-O3 -DNDEBUG` release, `-g -O0` debug), optional `-fsanitize=address`, the runtime archive
  (`kytecore` or `kytecore_asan`), the TLS link, and any FFI libraries the program declared
  (`collectFfiLibs`).
- **Cross-compilation:** `crossLinkViaZig` uses the bundled `zig c++` toolchain, which supplies the per-OS
  link libraries (for Windows, `-lws2_32 -lmswsock -lbcrypt`, and MSVC `link.exe` flag translation described
  in `lang/CLAUDE.md`). Target switches map to triples in `cmdBuild` (`windows-x86_64` to
  `x86_64-pc-windows-gnu`, etc.); a Windows `.exe` is a real PE32+.
- **WASM:** `wasm-ld` (in-process or via `clang -target wasm32`).

**Where in code.** `src/builder.zig` (the link branches in `compileProgram`), `src/pipeline.zig`
(`crossLinkViaZig`, `linkNativeInProcessMacho`, `appendRuntimeLink`, `collectFfiLibs`, `dead_strip_flag`,
`pie_flags`).

**Gotchas.** A missing symbol at link time is usually a reachability miss (3.10) or an unbuilt runtime shim,
not a linker misconfiguration. On Windows the runtime is linked as a COFF object (link.exe cannot read
llvm-ar's GNU archive).

**How to change it safely.** After a link change, build a real app on each target you touched and run it; the
corpus links every case, so a broad `run.sh` catches most link regressions.

---

## 4. Cross-cutting subsystems

These span several stages, so they are collected here rather than repeated.

### 4.1 The two type engines and the shadow gate

The old compiler resolved types by manipulating type-name strings (`resolveExpressionTypeName`). The new
engine interns type identities as `TypeId`s and reasons over them (`sema/`). During the migration both run,
and `shadow.zig` diffs them: with `KYTE_SEMA_SHADOW=1` any disagreement fails, so a name-based ownership
decision cannot slip back in. `KYTE_TID_CENSUS` counts the expressions where the TypeId engine still returns
null but the string engine resolved a concrete name; those are the coverage gaps that block deleting the
string layer (tasks #171/#172/#191). The rule for a maintainer: add new decisions to the TypeId engine, keep
the shadow gate green, and never add a new string-based decision.

### 4.2 ARC: how retain and release are decided

ARC is decided at COMPILE time (it is not a garbage collector). Every heap object carries an 8-byte header:
refcount at ptr-8, length at ptr-4. The primitives are `kyte_retain` and `kyte_release(ptr, dtor)` in the
runtime. Codegen (`arc.zig`) inserts them, using the ownership signals from the `TypedIr` (the same
information the OSSA verifier uses). The header offsets are a hard contract shared by the compiler and the
runtime (`kyte_abi.h`, `runtime_str.h`); change them in lockstep or not at all. Verify every ARC change with
`--asan`; the `--arc` audit is weaker and misses use-after-frees.

### 4.3 Monomorphisation, mangling, and multi-version packages

Two features fall out of one mechanism. Symbol mangling is PATH-derived (`getModulePrefix`), so:
- same-named types in different modules mangle apart and coexist as distinct types (module-scoped identity);
- two versions of a package that live at different cache paths (`X-<sha1>/` vs `X-<sha2>/`) mangle to
  distinct symbols automatically, so multi-version coexistence needs no codegen change.

This is why the package manager can be small (see `pkg-manager.md`): git SHAs are the version lock and the
integrity check, and path-derived mangling gives version coexistence for free.

### 4.4 Value versus reference semantics in codegen

`struct` is a value type (copy-on-assign, inline storage); `class` is a reference type (shared, ARC,
identity). The decision is carried on `StructDecl.is_reference` and realised in `types.zig` (layout) and
`arc.zig` (copy and recursive destruction of nested value fields). This was hard-won: value structs were once
gated off and `let b = a` aliased instead of copying. The regression guard is the corpus plus `--asan`. Some
escape-set structs may still be handled by reference; that boundary is in the `struct-value-semantics-fix`
memory note.

### 4.5 DWARF debug info and the in-editor debugger

Debug builds emit DWARF; VS Code drives it through `lldb-dap` (the Homebrew one on PATH, not Apple's).
`lldb-dap` renders a pointer type as its raw address and an aggregate as a summary, which is why strings and
containers are emitted as single-member aggregate DWARF types. Optional Python formatters at
`~/.kyte/std/debug/kyte_formatters.py` (source in `src/lib/std/debug/`) give richer display (List/Map/Set
element expansion, struct fields, `str.Str` text) and MUST degrade gracefully when Python is absent. On
macOS the DWARF stays in the `.o` files with OSO stubs in the executable, so `dwarfdump` on the executable
shows "zero DWARF" even when it is present; `dsymutil` collects it.

### 4.6 The C++ runtime and the reactor

The runtime (`src/runtime/`) provides the scheduler and the event-loop reactors that back `async`/`await`
and `spawn`. There are four reactor backends selected per target (kqueue on macOS, epoll and io_uring on
Linux, IOCP on Windows), and on Linux the choice is made by a RUNTIME probe (`kyte_reactor_backend()` in
`concurrency.cpp`), because a header being present does not mean the running kernel enables io_uring. The
proactor backends (IOCP, io_uring) have a rule that has cost real debugging and is spelled out in
`lang/CLAUDE.md`: on a proactor the KERNEL owns the op record until the operation completes or is cancelled,
so "give up and free it" corrupts the next op. The user-facing `channel<T>` (the actor primitive) is
SEPARATE from the runtime's internal cross-reactor WAKE channel; do not conflate them. If you touch the
reactor, read the reactor sections of `lang/CLAUDE.md` first.

---

## 5. Targets, cross-compilation, and linking

- **Primary targets:** native macOS, Linux, and Windows on x86_64 and arm64. **Secondary:** WebAssembly via
  `wasm-ld`, best-effort (dropped as the primary target in 2026-07-28).
- **Cross-compilation** works from any host to any target via the bundled `zig c++` toolchain. Adding a
  target means providing: a reactor backend (4.6), the per-OS link libraries, and any target-conditional
  stdlib module (via `targetVariantPath`, 3.2.2).
- **Delivery:** contributor DEV builds use dynamic system LLVM (fast); RELEASE builds static-link LLVM
  (`zig build -Dstatic-llvm`) so end users install nothing. `release.yml` publishes six bundles
  (macOS/Linux arm64+x86_64 static, Windows dynamic with a bundled `LLVM-C.dll`), each containing `kyte` +
  `nls` + the stdlib + a checksum. A release that ships `kyte` alone is broken for anyone without the stdlib
  on disk.
- **Windows** has its own trap list (WSAStartup, IOCP timers and association, ConnectEx, MSVC link.exe flag
  translation); it is documented in `lang/CLAUDE.md` and must be read before touching the Windows path.

---

## 6. Diagnostics and debug switches

Match the switch to the stage where a bug lives:

| Switch | What it does | Use when |
|---|---|---|
| `--dump-merged` / `KYTE_DUMP_MERGED=1` | Writes the merged program to `merged.ky`. | A symbol the code defines seems missing (stage 1). |
| `KYTE_SEMA_SHADOW=1` | Diffs the name engine and the TypeId engine, fails on divergence. | A type decision is suspect (stage 6). |
| `KYTE_TID_CENSUS=1` | Counts TypeId-engine coverage gaps. | Auditing the string-engine deletion. |
| `KYTE_REACH_SHADOW=1` / `KYTE_REACH_OFF` | Reports / disables the reachability gate. | A method fails to link, or auditing what got dropped (stage 8). |
| `KYTE_OSSA=1` / `KYTE_OSSA=hard` | Runs the ownership verifier, optionally failing the build. | Verifying ARC balance (stage 10). |
| `KYTE_OWN_VERIFY=1` / `hard` | The sema owned-local report plus the codegen balance verifier. | Cross-checking ownership (stage 10). |
| `KYTE_ESCAPE_REPORT=1` | The report-only escape gauge. | Escape-analysis work (stage 9). |
| `--emit-llvm` | Writes the `.ll`. | Codegen looks wrong; read the IR before theorising (stage 11). |
| `--mem-stats` | Prints declaration and instantiation counts. | Build-speed or memory work (stages 7 to 8). |
| `KYTE_IO_WATCHDOG=1` / `KYTE_CRASH_TRACE=1` | Runtime reactor diagnostics. | A connection hangs with the server idle, or a silent async SIGSEGV (runtime). |

The discipline everywhere in this codebase: measure before theorising. Each switch above has ruled out an
entire class of bug in one run.

---

## 7. Test and gate infrastructure

- **The corpus** (`conformance/cases/*.ky`) is the positive gate: `conformance/run.sh` runs each case via
  `kyte test`; `-j` parallelises it (about two minutes). Run it BEFORE and AFTER every change.
- **`expect_fail/`** holds programs that MUST be rejected; each soundness check (3.7) owns one.
- **`--asan`** is the memory gate (needs a `KYTE_ASAN=1 zig build` first); it catches the use-after-frees the
  `--arc` audit misses.
- **`--ossa`** runs the ownership verifier over the corpus.
- **`conformance/pkg-acceptance.sh`** proves the package manager (six items, local `file://` repos, no
  network).
- **`gate.sh`** runs the whole battery and is the real definition of "did not regress".

Three positive corpus cases are known-red and understood, so do not treat them as regressions: `118_actor`
(a half-baked actor mutex lock, low priority under the single-reactor web model), `189_epoll` (asserts epoll
struct layout, inapplicable off Linux by design, with a kqueue twin `188` inapplicable off macOS), and
`42_nested` (a nested value-optional aggregate). A FOURTH red case is a regression.

---

## 8. Recipes: how to make common changes

Each recipe names the files to touch and the gate that proves it.

### 8.1 Add a keyword
Add the token to the keyword set in `lexer.zig`, handle it in `parser.zig`, and extend the AST in `ast.zig`
if it introduces a new node. Prefer a CONTEXTUAL keyword (recognised only where it is meaningful) over a hard
reservation, because a hard keyword breaks any program using that word as an identifier. Update
`docs/specs.md` first (spec-first rule). Gate: the whole corpus (a hard keyword can break existing cases).

### 8.2 Add an operator
Add the token in `lexer.zig`, place it in the precedence ladder in `parser.zig` (the `parseBitwiseOr` to
`parseShift` chain), add the `BinaryOp`/`UnaryOp` in `ast.zig`, and lower it in `expressions.zig`. Gate:
corpus. Avoid reusing a symbol with a common other meaning (this is why there is no `^` power operator).

### 8.3 Add a builtin type
Register it in the TypeId builtins (`sema/builtins.zig`) and map it to LLVM in codegen `types.zig` (`cgPrim`
if it is a scalar). If it is a heap object, decide its ARC story in `arc.zig`. Gate: corpus plus `--asan`.

### 8.4 Add a soundness check
Add the check to `type_checker.zig`, add a `conformance/expect_fail/<name>.ky` that it must reject, and run
the whole positive corpus to confirm zero false positives. Bias conservative: missing an exotic bug is better
than rejecting valid code. Wire it into `gate.sh` if it needs its own mode.

### 8.5 Add a stdlib module
Add the `.ky` file under `src/lib/std/` and register its short name where the resolver maps names to paths
(`pipeline.zig`). If it is platform-specific, use the `targetVariantPath` layout (3.2.2). Gate: a `@test` in
the module plus the corpus.

### 8.6 Add a target
Provide a reactor backend in the runtime (4.6), the per-OS link libraries in the link step (3.14), the target
triple mapping in `cmdBuild`, and any target-conditional stdlib module. Gate: build and RUN a real app on the
new target; then the corpus.

### 8.7 Add a codegen lowering
Lower it in `expressions.zig` or `statements.zig`, using types from `types.zig` and ARC from `arc.zig`. Do
NOT make a type decision from a name here; if you need one, add it to the sema engine (3.8) and read it back
from the `TypedIr`. Gate: corpus, `--asan`, and `KYTE_OSSA=hard`.

---

*This document tracks `builder.zig` `compileProgram` and the `src/frontend/` and `src/backend/codegen/`
trees. When you change the pipeline order or a stage's responsibility, update the matching section here so the
next maintainer inherits the truth, not the history.*
