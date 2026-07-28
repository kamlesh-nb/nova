# Adding a Feature

This is the contributor playbook: where each kind of change lives, and the gate discipline that keeps the
language sound. Read [the overview](README.md) and [the compiler](01-compiler.md) first.

## The golden rules

1. **Spec first.** Check and update [`../language-specification.md`](../language-specification.md) *before*
   adding a language feature. The spec is the contract; drift is a bug.
2. **The conformance corpus is the gate.** `conformance/run.sh` must be green before and after. Positive
   cases run via `nova test`; negatives live in `expect_fail/` and must be *rejected for the declared
   reason* (a segfault is not a rejection). Add a gate for every behavior you add.
3. **Verify memory with ASAN, not just ARC.** `NOVA_ASAN=1 zig build` then `conformance/run.sh --asan`.
   The ARC audit misses use-after-frees that ASAN catches. This is the authority for any allocation- or
   ownership-touching change.
4. **`int` is 32-bit; heap addresses are `long`/`ptr`.** The most common bug is address truncation. If you
   compute or store a pointer, keep it 64-bit.
5. **Never `git reset`** (git stash is fine); `build.zig` recovers the build-runner from cache. Commit only
   when asked.

## Where a change goes

### A new operator or expression form
- **Lexer** (`src/lexer.zig`) — the token, if new syntax.
- **Parser + AST** (`src/parser.zig`, `src/ast.zig`) — the node.
- **Type checker** (`src/type_checker.zig`) — its diagnostics (arg/type rules).
- **Typed IR** (`src/sema/infer.zig` + friends) — its type resolution.
- **Codegen** (`src/codegen/expressions.zig`) — its LLVM lowering.
- **Gate** — a `conformance/cases/NN_<name>.nova` proving the behavior + an `expect_fail/` case for what it
  must reject.

### A new keyword / statement
Same as above, plus `src/codegen/statements.zig` for lowering, and consider the `formatter.zig` so
`nova fmt` handles it.

### A new type or trait mechanic
- `sema/infer.zig` (inference), `sema/subst.zig` (substitution if generic), `sema/mono.zig` (if it
  introduces instantiations), `codegen/types.zig` (LLVM layout), `codegen/arc.zig` (its destructor if it
  owns heap), `codegen/llvm_codegen.zig` (vtable/dispatch if it's a trait).

### A new runtime primitive (native)
1. Implement `extern "C" …` in the right `src/runtime/*.cpp` and declare it in `src/runtime/nova_abi.h`.
2. Register the extern's LLVM signature in `src/codegen/declarations.zig` and, if user-callable, in
   `src/sema/builtins.zig`.
3. If it must also work on WASM, provide a host import in `conformance/wasm-run.mjs`; if it *can't*
   (sockets/threads/native crypto), it is native-only — the checker/codegen already reject it on WASM with
   a clean error, and callers guard it with `@native { … }`.

### A new stdlib module (in Nova)
1. Write `src/std/<area>/<mod>.nova`.
2. Register it in `main.zig`'s `std_modules` so `import <area>.<mod>` resolves.
3. Add a conformance case. **Uncovered stdlib modules rot silently** — a module no one imports can stop
   compiling unnoticed. Compile-check it with `nova <file-that-imports-it> -o out` (not just `nova test`)
   and grep for `.nova:L:C:` errors.

## The typed-IR discipline (F2-6)

Codegen must **not** re-derive types from name strings — that was the root cause of a whole class of
corruption bugs. The semantic passes write a *complete* typed IR; a leftover `unresolved` at the end of
sema is fatal by design. If codegen needs to know a type, get it from the typed IR, not by string-matching
a type name. When in doubt, run `NOVA_SEMA_SHADOW=1` to diff the two type engines.

## The WASM target (secondary / best-effort)

WASM is not primary and does not gate Beta, but keep it from regressing when you touch codegen:

- Guard native-only code paths behind `if (self.is_wasm)` in codegen and the `@wasm`/`@native` blocks in
  Nova source.
- Remember the WASM pointer model: `ptr_type` is i32; use `ptrElemSize()` for pointer-array strides; host
  imports mask to 32 bits. The value handle stays i64.
- `conformance/run.sh --wasm` gates compilation; `--wasm-run` executes under Node; `wasm-run.mjs --guard`
  is the ASAN-equivalent for catching out-of-bounds writes into static data.

## The loop

```sh
# 1. make the change (spec first if it's language surface)
zig build                      # rebuild compiler + runtime
conformance/run.sh             # native corpus — green before AND after
NOVA_ASAN=1 zig build && conformance/run.sh --asan   # memory gate for allocation/ownership changes
# 2. add the gate(s): conformance/cases/NN_*.nova (+ expect_fail/*.nova for rejections)
# 3. update docs/language-specification.md if the surface changed
```

A change is done when the DoD is met **and** the full suite is green — never on "it compiles" or "the
happy path works."

## Where to look when something breaks

| Symptom | First suspect |
|---------|---------------|
| SIGSEGV, address-dependent (heisenbug) | pointer truncation — an `int`-typed heap address (§golden rule 4) |
| Use-after-free found only under ASAN | an ownership-pass drop / `arc.zig` retain-release imbalance |
| "Function 'X' not found" at codegen | an unresolved call / missing mono instantiation / a native symbol on WASM |
| Trait method "silently never runs" / garbage vtable | a fat-pointer / trait-widening bug (a fresh trait temp freed too early) |
| WASM `call_indirect` "null function" | pointer-width stride (`ptrElemSize`) or an out-of-bounds write (`--guard`) |
| A stdlib module stopped compiling | uncovered module rot — add/keep a conformance import of it |
