# Adding a Feature

This is the contributor playbook: where each kind of change resides, and the gate discipline that keeps the
language sound. Kindly read [the overview](README.md) and [the compiler](01-compiler.md) first.

## The Golden Rules

1. **Spec first.** Check and update [`../language-specification.md`](../language-specification.md) *before*
   adding a language feature. The spec is the contract, and drift from it is a bug.
2. **The conformance corpus is the gate.** `conformance/run.sh` must be green both before and after. The
   positive cases run via `nova test`; the negatives reside under `expect_fail/`, and must be *rejected for
   the declared reason* (a segfault is not a rejection). A gate is to be added for every behaviour that you
   add.
3. **Verify memory with ASAN, and not merely with ARC.** Run `NOVA_ASAN=1 zig build`, and thereafter
   `conformance/run.sh --asan`. The ARC audit does miss use after free cases that ASAN catches. This is the
   authority for any change that touches allocation or ownership.
4. **`int` is 32 bit; heap addresses are `long` or `ptr`.** The most common bug is address truncation. In
   case you compute or store a pointer, kindly keep it 64 bit.
5. **Never `git reset`** (a git stash is fine); `build.zig` recovers the build runner from cache. Commit
   only when asked.

## Where a Change Goes

### A new operator or expression form
- **Lexer** (`src/lexer.zig`), for the token, in case the syntax is new.
- **Parser and AST** (`src/parser.zig` and `src/ast.zig`), for the node.
- **Type checker** (`src/type_checker.zig`), for its diagnostics (the argument and type rules).
- **Typed IR** (`src/sema/infer.zig` and its companions), for its type resolution.
- **Codegen** (`src/codegen/expressions.zig`), for its LLVM lowering.
- **Gate.** A `conformance/cases/NN_<name>.nova` proving the behaviour, along with an `expect_fail/` case
  for whatever it must reject.

### A new keyword or statement
The same as the above, in addition to `src/codegen/statements.zig` for the lowering, and kindly consider
`formatter.zig` as well, so that `nova fmt` handles it.

### A new type or trait mechanic
`sema/infer.zig` (inference), `sema/subst.zig` (substitution, in case it is generic), `sema/mono.zig` (in
case it introduces instantiations), `codegen/types.zig` (the LLVM layout), `codegen/arc.zig` (its
destructor, in case it owns heap), and `codegen/llvm_codegen.zig` (the vtable and dispatch, in case it is a
trait).

### A new runtime primitive (native)
1. Implement `extern "C" ...` in the appropriate `src/runtime/*.cpp`, and declare it in
   `src/runtime/nova_abi.h`.
2. Register the extern's LLVM signature in `src/codegen/declarations.zig`, and, in case it is user
   callable, in `src/sema/builtins.zig` as well.
3. In case it must also work on WASM, provide a host import in `conformance/wasm-run.mjs`. In case it
   *cannot* (as with sockets, threads, or native crypto), it is native only; the checker and codegen
   already reject it on WASM with a clean error, and callers guard it with `@native { ... }`.

### A new standard library module (in Nova)
1. Write `src/std/<area>/<mod>.nova`.
2. Register it in the `std_modules` list in `main.zig`, so that `import <area>.<mod>` resolves.
3. Add a conformance case. Kindly note that **uncovered standard library modules rot silently**; a module
   that no one imports can cease to compile unnoticed. Compile check it with `nova <file-that-imports-it> -o
   out` (and not merely with `nova test`), and grep for `.nova:L:C:` errors.

## The Typed IR Discipline (F2-6)

Codegen must **not** re-derive types from name strings; that was the root cause of a whole class of
corruption bugs. The semantic passes write a *complete* typed IR, and a leftover `unresolved` at the end of
sema is fatal by design. In case codegen requires the type of something, obtain it from the typed IR, and
not by string matching a type name. When in doubt, run `NOVA_SEMA_SHADOW=1` to diff the two type engines.

## The WASM Target (Secondary, Best Effort)

WASM is not primary, and it does not gate Beta; nevertheless, kindly keep it from regressing when you touch
codegen.

- Guard the native only code paths behind `if (self.is_wasm)` in codegen, and behind the `@wasm` and
  `@native` blocks in Nova source.
- Bear in mind the WASM pointer model: `ptr_type` is i32; use `ptrElemSize()` for the pointer array
  strides; and the host imports mask to 32 bits. The value handle remains i64.
- `conformance/run.sh --wasm` gates compilation; `--wasm-run` executes under Node; and `wasm-run.mjs
  --guard` is the ASAN equivalent, for catching out of bounds writes into static data.

## The Loop

```sh
# 1. Make the change (spec first, in case it is language surface).
zig build                      # rebuild the compiler and runtime
conformance/run.sh             # the native corpus, green both before AND after
NOVA_ASAN=1 zig build && conformance/run.sh --asan   # the memory gate, for allocation and ownership changes
# 2. Add the gate(s): conformance/cases/NN_*.nova (along with expect_fail/*.nova for rejections).
# 3. Update docs/language-specification.md, in case the surface changed.
```

A change is done when its Definition of Done is met **and** the full suite is green; never on account of
"it compiles" or "the happy path works".

## Where to Look When Something Breaks

| Symptom | The first suspect |
|---------|-------------------|
| A SIGSEGV that is address dependent (a heisenbug) | Pointer truncation, that is, an `int` typed heap address (please see golden rule 4). |
| A use after free found only under ASAN | An ownership pass drop, or an `arc.zig` retain and release imbalance. |
| "Function 'X' not found" at codegen | An unresolved call, or a missing monomorphisation instantiation, or a native symbol on WASM. |
| A trait method that "silently never runs", or a garbage vtable | A fat pointer or trait widening bug (a fresh trait temp freed too early). |
| A WASM `call_indirect` "null function" | The pointer width stride (`ptrElemSize`), or an out of bounds write (use `--guard`). |
| A standard library module that stopped compiling | Uncovered module rot; add and retain a conformance import of it. |
