# The Compiler

The Nova compiler is written in **Zig 0.16** and lives in `src/`. It is a classic multi-pass compiler:
tokenize → parse → semantically analyze (several passes) → monomorphize → generate LLVM IR → link.
This document walks the pipeline in the order source flows through it. Code generation is large enough
to get [its own document](02-codegen.md).

`src/main.zig` (~2500 lines) is the driver: it parses CLI args, resolves the import graph, runs every
pass in sequence, and links the result. The two hot paths are `cmdTest` (`nova test`) and
`compileProgram` (`nova <file>` / `nova build`); both run the same pass sequence, shown below.

## Pass sequence (from `main.zig`)

```zig
loadProgram(...)                     // resolve + merge the import graph into one Program
sema_alpha.run(program)              // α-renaming
sema_ids.Assigner.run(program)       // NodeId / ModuleId assignment
type_checker.TypeChecker.check(...)  // diagnostics (arg count, visibility, coloring, ...)
sema_shadow.run(program, owned_sema) // build the authoritative typed IR (infer/subst/lower/symbols/ownership)
sema_mono.Worklist.compute(program)  // discover live generic instantiations
inst_disp.run(...)                   // instantiation dispatch
llvm_codegen.compile(...)            // AST + typed IR → LLVM IR → object file(s)
link                                 // in-process LLD (Mach-O/WASM) or clang++/`zig c++` (cross)
```

## 1. Lexing — `src/lexer.zig` (~680 lines)

A hand-written scanner turning source bytes into a `Token` stream. Notable Nova-specific rules:

- **Two declaration keywords only:** `let` (mutable) and `const` (enforced-immutable). `var` is removed;
  the lexer/parser reject it.
- **`spawn` is a soft keyword** — reserved in prefix position (`spawn f()`) but usable as a field/method
  name (`process.spawn(...)`).
- **Backtick template literals** `` `x=${expr}` `` and decimal literals with an `m` suffix (`19.99m`)
  are lexed as first-class tokens.
- **Contextual keywords** like `in` are only keywords in the position that needs them.

## 2. Parsing & the AST — `src/parser.zig` (~2560), `src/ast.zig` (~510)

A recursive-descent parser produces the AST defined in `ast.zig`. Key node families: `FunctionDecl`,
`StructDecl` (+ `MethodDecl`), `TraitDecl` (+ `TraitMethodDecl`), `EnumDecl`, `UnionDecl`, `Expression`
(a tagged union: `call`, `generic_call`, `field_access`, `await_expr`, `go_expr`, `binary`,
`struct_init`, `if_expr`, `template_expr`, …), and `TypeRef` (`ident`, `optional`, `generic {name, params}`,
`func {params, ret}`).

Two parser behaviors worth knowing:

- **Target-conditional blocks.** `@wasm { … }` / `@native { … }` include or exclude declarations by the
  build target (`Parser.is_wasm`). This is the "compiler flag" mechanism for code that cannot exist on a
  given target (e.g. sockets on WASM). The excluded block is brace-counted and skipped.
- **Generated code is re-parsed.** Serde binders (`<Struct>__bind`) and mediator dispatchers are emitted
  as Nova *source*, then parsed with a fresh `Parser` and folded into the declaration list
  (`generateSerdeBinders` / `generateMediatorDispatch` in `main.zig`). This keeps generated code honest —
  it goes through the same type-checking and codegen as hand-written code.

`main.zig:loadProgram` walks `import` declarations depth-first, reads each module (from local
`src/std/…`, the installed `~/.nova/std/…`, or a fetched package under `~/.nova/cache/…`), dedups by a
**canonical path spelling** (so a module read from two locations keeps ONE identity), and concatenates all
declarations into a single `Program`. Import edges are preserved for the symbol table.

## 3. The semantic passes — `src/type_checker.zig`, `src/sema/`

Nova splits semantic analysis into **diagnostics** (the type checker) and **the authoritative typed IR**
(the `sema/` pipeline). The historical reason is the "F2-6" migration: codegen used to *guess* types from
name strings; now `sema/` writes a complete typed IR and codegen stops guessing.

### 3a. α-renaming — `sema/alpha.zig` (~260)

Same-scope `let` shadowing is legal (Rust-like). Alpha-renaming rewrites shadowed bindings to unique
names so every later lookup is unambiguous. (This was the root cause of an old `string.replace`
truncation bug — a lookup that didn't scan most-recent-first.) **Never add a same-scope-redeclaration
error**; shadowing is a feature.

### 3b. ID assignment — `sema/ids.zig` (~260)

Assigns a stable `NodeId` to every AST node and a `ModuleId` per module, so later passes and the symbol
table can reference nodes by identity rather than by reconstructing file paths.

### 3c. Type checking — `type_checker.zig` (~1520)

This pass emits **diagnostics** — it does not build the IR codegen consumes. It resolves expression types
well enough to enforce the language's rules:

- **Arg/param counts**, constructor arity, ambiguous bare calls (a name shared by two imported modules is
  a hard error — qualify it).
- **Visibility** — `pub` rules for fields, methods, functions, types, consts, uniformly across
  multi-segment imports.
- **Pointer-truncation & narrowing** — storing a `ptr` (raw address) into a ≤32-bit int, or an
  implicit narrowing/signedness change, is a located error (F3 honest-primitives).
- **Optionals soundness (H2)** — an unguarded value use of an optional is a compile error; `??` strips the
  optional; `at()` traps.
- **Function coloring (A2)** — `await`/`spawn` are legal only inside an `async fn`; a *bare* (non-awaited,
  non-spawned) call to an `async fn` from inside another `async fn` is an error (it would block-drive the
  event loop and deadlock); a struct method must match its trait method's async-ness. On the WASM target,
  `async`/`await`/`spawn` and native-only runtime symbols are rejected with clean located errors instead
  of crashing codegen. See `callTargetsAsync` and the `in_async`/`in_awaited`/`is_wasm` flags.

### 3d. The typed IR — `sema/` (`shadow.zig` orchestrates)

`sema_shadow.run` builds `owned_sema`, the typed intermediate representation. The sub-passes:

| File | Role |
|------|------|
| `infer.zig` (~2640) | Type inference — the largest sema file. Resolves every expression to a `TypeId` in a `TypeStore`; unknown stays `unresolved` (never silently `i32`). |
| `subst.zig` (~350) | Generic substitution — replace type params with concrete args. |
| `lower.zig` (~510) | Lower the checked AST into the typed IR the ownership pass and codegen read. |
| `symbols.zig` (~690) | The symbol table + module resolution as a lookup (import edges → `findModuleBySegment` / `findFunctionBySegment`). |
| `ownership.zig` (~520) | The ARC ownership model: decides per-edge which values are owned/borrowed/dropped, so codegen emits balanced retains/releases. |
| `subst`/`ids`/`alpha`/`inst_disp` | supporting machinery. |
| `shadow.zig` (~1040) | Orchestrates the above and (under `NOVA_SEMA_SHADOW`) diffs the two type engines to catch divergence. |

The guiding principle (F2-6): **the checker writes a COMPLETE typed IR; codegen does not re-derive
types.** A leftover `unresolved` at the end of sema is fatal, by design — a guess would be a silent wrong
answer.

## 4. Monomorphization — `sema/mono.zig` (~420), `inst_disp.zig`

Generics are **not** type-erased at runtime. A `Worklist` starts from the program roots and discovers
every concrete instantiation actually reached — `List<int>`, `Map<string, MessageHandler>`,
`Storage<K>` — including instantiations discovered through method-return types. Each becomes a real
specialized function/type (`List_int_push`, …). `inst_disp.run` wires the discovered instantiation IDs
back into the typed IR.

An *erased* generic body is emitted only as a link-time fallback with `internal` linkage; LLVM's
`globalDCE` drops it because nothing reachable calls it. If you ever see an erased body survive into the
output, an instantiation wasn't discovered — that's a mono bug, not an intended path.

## 5. Code generation — `src/codegen/` (~11500)

Covered in depth in **[02-codegen.md](02-codegen.md)**. In one paragraph: `declarations.zig` declares
every function, global, vtable, and the emitted allocator; `expressions.zig` + `statements.zig` lower
expression/statement IR to LLVM instructions; `arc.zig` emits the retain/release/destructor machinery
`ownership.zig` planned; `types.zig` maps Nova types to LLVM types. The module is verified, run through
`CoroSplit` (async → real coroutines) and `globalDCE`, and written to an object file.

## 6. Linking & the driver — `main.zig`

`main.zig` finishes the job by linking the object(s) into an executable:

- **Native macOS** — in-process `ld64.lld` via `nova_lld_link_macho` (from `src/linker/`, linked against
  LLVM's `liblld*`), reconstructing the args the clang driver would pass. No shell-out.
- **Native (general) / runtime link** — `clang++` links the object against the prebuilt C++ runtime
  (`~/.nova/lib/libnova_runtime.a`) + Boost + `-lz` + wolfSSL.
- **Cross-compilation (T1)** — from macOS, `zig c++` produces Linux x86_64/arm64 (static musl ELF) and
  Windows x86_64 (PE32+). The runtime is compiled for the target once and cached at
  `~/.nova/lib/nova_runtime_<triple>.o`.
- **WASM** — in-process `wasm-ld` (`nova_lld_link_wasm`), freestanding (`--no-entry`, host imports).

### Incremental builds (T6)

`nova build` writes to `build/<profile>/{obj,bin}` and keeps a **content-hash cache**: `sourcesHash`
digests every input file's (path + content), the profile, a `CACHE_VERSION`, and — crucially — the
**linked runtime libs' mtimes** (`linkLibsStamp`), so editing `src/runtime/` forces a relink instead of
serving a stale binary. T6 also splits emission per source file into separate `.o` objects with their own
hash cache, so a one-file edit rebuilds one object.

## Debugging the compiler

- `NOVA_DUMP_MERGED=1` — write the merged pre-codegen IR to `merged.nova`.
- `NOVA_SEMA_SHADOW=1` — diff the two type engines; reports divergence and resolution traces.
- `NOVA_ARC_AUDIT=1 nova test f` — per-run ARC audit ("ARC audit: clean" or survivors).
- `NOVA_KEEP_OBJ=1` — keep the intermediate `.o` (e.g. to hand-relink against the ASAN runtime).
- `build.zig` recovers from the Zig build-runner cache; **never `git reset`** in this repo (git stash is
  fine).
