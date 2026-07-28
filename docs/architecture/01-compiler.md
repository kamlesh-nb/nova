# The Compiler

The Nova compiler is written in **Zig 0.16** and resides in `src/`. It is a classic multi pass compiler:
tokenise, parse, semantically analyse (in several passes), monomorphise, generate LLVM IR, and link. This
document walks through the pipeline in the very order in which source flows through it. Code generation is
large enough that it has been given [its own document](02-codegen.md).

`src/main.zig` (about 2500 lines) is the driver. It parses the CLI arguments, resolves the import graph,
runs every pass in sequence, and links the result. The two hot paths are `cmdTest` (for `nova test`) and
`compileProgram` (for `nova <file>` and `nova build`); both of them run the same pass sequence, which is
shown below.

## Pass Sequence (from `main.zig`)

```zig
loadProgram(...)                     // resolve and merge the import graph into one Program
sema_alpha.run(program)              // alpha-renaming
sema_ids.Assigner.run(program)       // NodeId and ModuleId assignment
type_checker.TypeChecker.check(...)  // diagnostics (arg count, visibility, colouring, and so forth)
sema_shadow.run(program, owned_sema) // build the authoritative typed IR (infer, subst, lower, symbols, ownership)
sema_mono.Worklist.compute(program)  // discover live generic instantiations
inst_disp.run(...)                   // instantiation dispatch
llvm_codegen.compile(...)            // AST and typed IR to LLVM IR to object file(s)
link                                 // in-process LLD (Mach-O, WASM) or clang++ / `zig c++` (cross)
```

## 1. Lexing, `src/lexer.zig` (about 680 lines)

This is a hand written scanner that turns source bytes into a `Token` stream. The Nova specific rules
worth noting are as follows.

- **There are two declaration keywords only,** namely `let` (mutable) and `const` (enforced immutable).
  `var` has been removed, and the lexer and parser reject it.
- **`spawn` is a soft keyword.** It is reserved in prefix position (`spawn f()`), yet it remains usable as
  a field or method name (`process.spawn(...)`).
- **Backtick template literals** such as `` `x=${expr}` ``, and decimal literals bearing an `m` suffix
  (`19.99m`), are lexed as first class tokens.
- **Contextual keywords** such as `in` are keywords only in the position that requires them.

## 2. Parsing and the AST, `src/parser.zig` (about 2560), `src/ast.zig` (about 510)

A recursive descent parser produces the AST that is defined in `ast.zig`. The key node families are
`FunctionDecl`, `StructDecl` (with `MethodDecl`), `TraitDecl` (with `TraitMethodDecl`), `EnumDecl`,
`UnionDecl`, `Expression` (a tagged union: `call`, `generic_call`, `field_access`, `await_expr`,
`go_expr`, `binary`, `struct_init`, `if_expr`, `template_expr`, and others), and `TypeRef` (`ident`,
`optional`, `generic {name, params}`, `func {params, ret}`).

Two behaviours of the parser are worth an understanding.

- **Target conditional blocks.** A `@wasm { ... }` or `@native { ... }` block includes or excludes
  declarations according to the build target (`Parser.is_wasm`). This is the "compiler flag" mechanism for
  code that cannot exist on a given target, for example sockets on WASM. The excluded block is brace
  counted and skipped.
- **Generated code is re-parsed.** The serde binders (`<Struct>__bind`) and the mediator dispatchers are
  emitted as Nova *source*, then parsed afresh with a new `Parser`, and folded into the declaration list
  (see `generateSerdeBinders` and `generateMediatorDispatch` in `main.zig`). This keeps generated code
  honest, since it passes through the same type checking and codegen as hand written code.

`main.zig:loadProgram` walks the `import` declarations depth first. It reads each module (from the local
`src/std/...`, or the installed `~/.nova/std/...`, or a fetched package under `~/.nova/cache/...`), dedups
by a **canonical path spelling** (so that a module read from two locations retains ONE identity), and
concatenates all declarations into a single `Program`. The import edges are preserved for the symbol
table.

## 3. The Semantic Passes, `src/type_checker.zig` and `src/sema/`

Nova divides semantic analysis into two parts: the **diagnostics** (the type checker) and the
**authoritative typed IR** (the `sema/` pipeline). The historical reason is the so called "F2-6"
migration. Codegen used to *guess* types from name strings; now `sema/` writes a complete typed IR, and
codegen ceases to guess.

### 3a. Alpha-renaming, `sema/alpha.zig` (about 260)

Same scope `let` shadowing is legal (in the Rust like manner). Alpha renaming rewrites the shadowed
bindings to unique names, so that every later lookup is unambiguous. (This was the root cause of an old
`string.replace` truncation bug, wherein a lookup did not scan most recent first.) One must **never add a
same scope redeclaration error**, since shadowing is a feature.

### 3b. ID Assignment, `sema/ids.zig` (about 260)

This assigns a stable `NodeId` to every AST node, and a `ModuleId` per module, so that the later passes
and the symbol table may reference nodes by identity rather than by reconstructing file paths.

### 3c. Type Checking, `type_checker.zig` (about 1520)

This pass emits **diagnostics**. It does not build the IR that codegen consumes. It resolves expression
types to the extent required to enforce the rules of the language.

- **Argument and parameter counts,** constructor arity, and ambiguous bare calls (a name shared by two
  imported modules is a hard error, and must be qualified).
- **Visibility,** that is, the `pub` rules for fields, methods, functions, types, and consts, applied
  uniformly across multi segment imports.
- **Pointer truncation and narrowing.** Storing a `ptr` (a raw address) into a 32 bit or smaller int, or
  an implicit narrowing or signedness change, is a located error (per F3, honest primitives).
- **Optionals soundness (H2).** An unguarded value use of an optional is a compile error; `??` strips the
  optional; and `at()` traps.
- **Function colouring (A2).** `await` and `spawn` are legal only inside an `async fn`. A *bare* (that is,
  neither awaited nor spawned) call to an `async fn` from inside another `async fn` is an error, since it
  would block drive the event loop and thereby deadlock. Furthermore, a struct method must match its trait
  method's async-ness. On the WASM target, `async`, `await`, `spawn`, and the native only runtime symbols
  are rejected with clean located errors, instead of crashing codegen. Kindly see `callTargetsAsync` and
  the `in_async`, `in_awaited`, and `is_wasm` flags.

### 3d. The Typed IR, `sema/` (orchestrated by `shadow.zig`)

`sema_shadow.run` builds `owned_sema`, which is the typed intermediate representation. The sub passes are
as follows.

| File | Role |
|------|------|
| `infer.zig` (about 2640) | Type inference; this is the largest sema file. It resolves every expression to a `TypeId` in a `TypeStore`; anything unknown remains `unresolved`, and is never silently made `i32`. |
| `subst.zig` (about 350) | Generic substitution, that is, replacing type parameters with concrete arguments. |
| `lower.zig` (about 510) | Lowering the checked AST into the typed IR that the ownership pass and codegen read. |
| `symbols.zig` (about 690) | The symbol table and module resolution as a lookup (import edges via `findModuleBySegment` and `findFunctionBySegment`). |
| `ownership.zig` (about 520) | The ARC ownership model. It decides, per edge, which values are owned, borrowed, or dropped, so that codegen may emit balanced retains and releases. |
| `subst`, `ids`, `alpha`, `inst_disp` | The supporting machinery. |
| `shadow.zig` (about 1040) | Orchestrates the above and, under `NOVA_SEMA_SHADOW`, diffs the two type engines so as to catch any divergence. |

The guiding principle (per F2-6) is this: **the checker writes a COMPLETE typed IR, and codegen does not
re-derive types.** A leftover `unresolved` at the end of sema is fatal, by design, since a guess would be
a silent wrong answer.

## 4. Monomorphisation, `sema/mono.zig` (about 420), `inst_disp.zig`

Generics are **not** type erased at runtime. A `Worklist` begins at the program roots and discovers every
concrete instantiation that is actually reached, for example `List<int>`, `Map<string, MessageHandler>`,
and `Storage<K>`, including the instantiations discovered through method return types. Each of these
becomes a real specialised function or type (`List_int_push`, and so on). `inst_disp.run` then wires the
discovered instantiation IDs back into the typed IR.

An *erased* generic body is emitted only as a link time fallback with `internal` linkage; LLVM's
`globalDCE` drops it, because nothing reachable calls it. In case you ever observe an erased body surviving
into the output, it means an instantiation was not discovered; that is a monomorphisation bug, and not an
intended path.

## 5. Code Generation, `src/codegen/` (about 11500)

This is covered in depth in **[02-codegen.md](02-codegen.md)**. In one paragraph: `declarations.zig`
declares every function, global, vtable, and the emitted allocator; `expressions.zig` and `statements.zig`
lower the expression and statement IR to LLVM instructions; `arc.zig` emits the retain, release, and
destructor machinery that `ownership.zig` planned; and `types.zig` maps Nova types to LLVM types. The
module is then verified, run through `CoroSplit` (which turns async into real coroutines) and `globalDCE`,
and written to an object file.

## 6. Linking and the Driver, `main.zig`

`main.zig` finishes the job by linking the object or objects into an executable.

- **Native macOS.** In-process `ld64.lld` via `nova_lld_link_macho` (from `src/linker/`, linked against
  LLVM's `liblld*`), reconstructing the very arguments that the clang driver would pass. There is no shell
  out.
- **Native (general), the runtime link.** `clang++` links the object against the prebuilt C++ runtime
  (`~/.nova/lib/libnova_runtime.a`), along with Boost, `-lz`, and wolfSSL.
- **Cross compilation (T1).** From macOS, `zig c++` produces Linux x86_64 and arm64 (a static musl ELF),
  and Windows x86_64 (a PE32+). The runtime is compiled for the target once and cached at
  `~/.nova/lib/nova_runtime_<triple>.o`.
- **WASM.** In-process `wasm-ld` (`nova_lld_link_wasm`), freestanding (`--no-entry`, with host imports).

### Incremental Builds (T6)

`nova build` writes to `build/<profile>/{obj,bin}` and maintains a **content hash cache**. `sourcesHash`
digests every input file's path and content, the profile, a `CACHE_VERSION`, and, most importantly, the
**mtimes of the linked runtime libraries** (`linkLibsStamp`), so that editing `src/runtime/` forces a
relink instead of serving a stale binary. T6 additionally splits emission per source file into separate
`.o` objects, each with its own hash cache, so that a one file edit rebuilds one object.

## Debugging the Compiler

- `NOVA_DUMP_MERGED=1` writes the merged pre-codegen IR to `merged.nova`.
- `NOVA_SEMA_SHADOW=1` diffs the two type engines; it reports divergence and resolution traces.
- `NOVA_ARC_AUDIT=1 nova test f` performs a per-run ARC audit (reporting either "ARC audit: clean" or the
  survivors).
- `NOVA_KEEP_OBJ=1` keeps the intermediate `.o` (useful, for instance, to hand relink against the ASAN
  runtime).
- `build.zig` recovers from the Zig build runner cache. Kindly **never `git reset`** in this repo (a git
  stash is perfectly fine).
