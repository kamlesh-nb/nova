# LLD 22: Sema miscellany (escape, alpha, builtins, ids, inst_disp, sema)

This chapter documents six smaller support modules that live under `src/frontend/sema/`. They are not the heavy engines (that is infer.zig, mono.zig and ownership.zig), but a new maintainer meets all of them within the first day, so they are documented exhaustively here, function by function.

The six, in one line each:

- `escape.zig` is the P7 escape analysis. It classifies each owned allocation bound to a local as LOCAL or ESCAPES, computed as an interprocedural least fixpoint over the call graph. It is currently report-only (a gauge for the arena/value-struct promotion work), and defaults to ESCAPES so a wrong LOCAL cannot arise.
- `alpha.zig` is the alpha-renamer. It walks each function and gives shadowing `let` bindings fresh, unique names (`x`, `x$1`, `x$2`) so later passes never confuse two distinct variables that happen to share a source name.
- `builtins.zig` is the compile-time registry of builtin methods (`bytes.*`, `simd.*`, `console.*`), non-generic `mem` helpers, and bare-name runtime externs (`kyte_*`), together with their return types.
- `ids.zig` is the ExprId assigner. It stamps every AST expression node with a stable, copy-surviving `ExprId` so side tables can be keyed by node identity rather than by pointer address.
- `inst_disp.zig` is the instantiation-dispatch overlay. For each generic instance (struct, free fn, method) it records a TypeId overlay (`tp_resolve`, `expr_types_inst`, `owned_inst`) so ownership and type decisions inside generic bodies can be made from TypeIds instead of the old string engine.
- `sema.zig` is the small `Sema` container: it owns the TypeStore, SymbolTable and TypedIr for a compilation, plus a TypeId to display-name cache.

A note on the id newtypes these files thread around, since they are defined elsewhere but used throughout here:

- `ast.ExprId = enum(u32) { unassigned = 0, _ }` (in `src/frontend/ast.zig`). A `u32`-backed enum. The sentinel `0 = unassigned` means "no id yet"; every `ast.Expression` carries `id: ExprId = .unassigned`. ids.zig hands out `1, 2, 3, ...` and never `0`.
- `types.TypeId = enum(u32) { _ }` (in `src/frontend/types.zig`). A `u32`-backed opaque enum with no named members, one per interned type in the TypeStore.
- `symbols.SymbolId = enum(u32) { _ }` (in `src/frontend/sema/symbols.zig`), re-exported as `types.SymbolId`. A `u32`-backed opaque enum, one per declaration in the SymbolTable.

None of these carry semantic meaning in their integer value beyond the `unassigned = 0` sentinel on ExprId. They are handles: compare by equality, look them up in the relevant store.

---

## `src/frontend/sema/escape.zig` (431 lines)

**Role in the pipeline:** This is the P7 escape analysis described in `docs/design/p7-sound-arena.md`. Its job is to decide, for each owned heap allocation that is bound to a local variable, whether that allocation ESCAPES the function (is stored into a field, returned, passed to a callee whose parameter escapes, captured by a closure, and so on) or stays LOCAL. A LOCAL allocation is a candidate for arena or stack promotion; an escaping one must stay ARC-managed. The analysis runs in two stages: Stage 1 classifies each alloc site, Stage 2 replaces the crude rule "anything passed to any call escapes" with interprocedural summaries, so a call argument escapes only if the callee's matching parameter actually escapes.

The analysis is currently **report-only**: it prints a one-line summary when `report_enabled` (driven by `KYTE_ESCAPE_REPORT`) is set, and returns `Stats`. It does not yet drive codegen. Soundness is the whole point: the default classification is ESCAPES, a name becomes LOCAL only when no escape route touches it, and every unresolved callee (trait dispatch, closures, extern, unknown names) is treated conservatively. So a wrong LOCAL, the only dangerous direction, cannot arise from a missing route.

**Key types & data structures:**

- **`pub const Stats = struct`** (module public). Counters returned from `analyze`: `fns`, `alloc_sites`, `local`, `escapes`, `iterations`, all `usize`, all default 0.
- **`const StrSet = std.StringHashMap(void)`**. A set of names (variable identifiers). Used for the escaping set and the alloc-site set.
- **`const Edge = struct { lhs: []const u8, rhs: []const u8 }`**. An alias edge meaning "if `lhs` escapes then `rhs` escapes". Created for `let b = a` and `a = b` where the RHS is a bare identifier.
- **`const FnEntry = struct { name, params, body }`**. A function made analysable by name: `name: []const u8`, `params: []ast.Param`, `body: *const ast.Block`. Free functions and struct/enum methods are all flattened into these.
- **`const Analysis = struct`**. The module-scoped, per-`analyze`-call state. Fields: `alloc: std.mem.Allocator`, `ir: *const TypedIr`, and `summaries: std.StringHashMap([]bool)`. The `summaries` map is the interprocedural summary: name to a bool vector where entry `i` is "does parameter `i` of any function with this name escape". Vectors are OR-merged across same-named functions and sized to the max arity seen. A call argument beyond the vector length is conservatively escaping. The map owns its value slices (freed in `analyze`'s defer). Method: **`fn summaryFor(self, name) ?[]bool`** returns the summary vector for a name, or null if the name is unknown (unresolved callee).
- **`const Ctx = struct`**. Per-function walk state. Fields: `an: *Analysis`, `escaping: *StrSet`, `allocs: ?*StrSet` (non-null only on the final classification pass), `edges: std.ArrayList(Edge)`. Method: **`fn markEscape(self, name)`** inserts a name into the escaping set (errors swallowed).

**Module-level state / constants:**

- **`pub var report_enabled: bool = false`**. When true, `analyze` prints the summary line. Set by the driver from the `KYTE_ESCAPE_REPORT` environment gate.
- The fixpoint round cap is the literal `24` in `analyze` (see below).

**Functions (source order):**

- **`pub fn analyze(allocator, store: *const TypeStore, ir: *const TypedIr, program: *const ast.Program) Stats`**. The entry point. `store` is currently unused (`_ = store`). Algorithm:
  1. Build the `Analysis` with an empty `summaries` map; a `defer` frees every value slice and deinits the map.
  2. Collect every analysable function into `fns` (free fns, plus every struct and enum method). Append failures are swallowed with `catch {}`.
  3. Pre-populate an all-false (optimistic BOTTOM) summary for every KNOWN function name, sized to the max arity across same-named functions. This is essential for a sound least fixpoint: a call to a known-but-not-yet-analysed function must start assuming its params do NOT escape and only gain escapes as justified. Only names ABSENT from the map (extern, trait-dispatch, indirect) stay conservative. Starting pessimistic would monotonically over-mark and never recover. When a later same-named function has more params, the vector is grown, preserving existing bits.
  4. Fixpoint loop, capped at 24 rounds: for each function, compute its escaping set with the current summaries, then `mergeSummary` it back; if any bit flipped on, iterate again. `st.iterations` counts rounds.
  5. Final classification pass with the converged summaries: for each function, recompute escaping AND the alloc-site set, then for each alloc site increment `escapes` or `local` depending on membership in escaping.
  6. If `report_enabled`, print `[escape] fns=... alloc_sites=... LOCAL=... ESCAPES=... (local N%, K iters)`. Guards divide-by-zero when `alloc_sites == 0`.
  - Allocates: the summary vectors and various temporary sets; all freed within the call. Returns `Stats` by value.
- **`fn mergeSummary(an, fe: FnEntry, escaping: *StrSet) bool`** (private). ORs the freshly computed per-param escape bits into the by-name summary vector, growing it if this same-named function has more params. Returns whether any bit flipped on (or a fresh summary was created), which drives fixpoint continuation. Allocates/frees summary slices via `an.alloc`. Footgun the code guards: a fresh summary always returns `true` so callers re-run.
- **`fn computeEscaping(an, params, body, escaping)`** (private). Thin wrapper: calls `computeEscapingAndAllocs` with `allocs = null` (the fixpoint passes do not need alloc sites).
- **`fn computeEscapingAndAllocs(an, params, body, escaping, allocs: ?*StrSet)`** (private). The per-function walk. `params` is unused (`_ = params`). Builds a `Ctx`, walks every statement with `walkStmt`, then runs the **alias fixpoint**: repeatedly, for each `Edge`, if `lhs` is in escaping and `rhs` is not, add `rhs` and mark changed, until stable. This is what propagates escape backwards through `let b = a` chains. `ctx.edges` is freed on return.
- **`fn isOwned(ctx, e) bool`** (private). Returns `ctx.an.ir.ownedOf(e) orelse false`: does the TypedIr say this expression produces an owned allocation. False when unknown (conservative for alloc-site detection, meaning fewer sites, never a wrong LOCAL).
- **`fn collectIdents(e, out: *ArrayList, a)`** (private). Recursively gathers every identifier name reachable from an expression into `out`. Covers binary, unary, call, generic_call, field_access (object only), index, struct_init, enum_init, cast, range, optional_chaining, nullish_coalesce, tuple, if_expr, template_expr, try_expr, catch_expr; other kinds contribute nothing. Append failures swallowed. This is how "the value flowing into an escape position" is reduced to the set of source variables it depends on.
- **`fn markIdentsEscape(ctx, e)`** (private). Collects idents from `e` (into a temporary list, freed) and marks each as escaping.
- **`fn calleeName(callee) ?struct { name, method: bool }`** (private). Extracts a callee's simple name: `.ident` gives `{name, method=false}`, `.field_access` gives `{fa.field, method=true}`, anything else gives null (indirect/computed callee).
- **`fn applyCall(ctx, callee, args)`** (private). The heart of Stage 2. Resolves the callee name; if null (indirect callee, e.g. a closure variable), every argument escapes. Otherwise looks up the callee's summary. For a method `recv.m(a0,a1)` the receiver is parameter slot 0 (self) and arg `i` maps to param `i+1`; for a free call arg `i` maps to param `i` (`base = is_method ? 1 : 0`). A pointer escapes only if the matching parameter escapes in the summary, or the position is out of range (more actuals than the summary knows, conservative). If there is no summary at all (unknown callee), receiver and all args escape. Important non-obvious behaviour the comment stresses: the receiver is NOT blanket-escaped, so a local builder you only mutate (`sb.append(x)`, self does not escape) stays LOCAL. Self escapes only if `esc[0]` is set, or the summary is too short (`esc.len == 0`).
- **`fn walkExpr(ctx, e)`** (private). Recurses through an expression applying calls and closure captures. For `.call`/`.generic_call` it runs `applyCall` then recurses into args. For `.closure` it marks every identifier in the closure body as escaping (a closure may outlive the frame, so anything it names escapes). Recurses structurally through binary, unary, field_access, index, struct_init, cast, nullish_coalesce, optional_chaining, if_expr, tuple, template_expr, try_expr, catch_expr; other kinds are leaves.
- **`fn markStmtIdentsEscape(ctx, s)`** (private). Used from closure-body walking: marks all idents in a statement as escaping. Handles expr_stmt, let_stmt (init), return_stmt (value), nested block, if_stmt, while_stmt, for_stmt (body). Every value touched inside a closure body is treated as escaping.
- **`fn identName(e) ?[]const u8`** (private). Returns the name if `e` is a bare `.ident`, else null. Used to detect alias edges.
- **`fn walkStmt(ctx, s)`** (private). The statement walker, the primary escape-route classifier:
  - `.let_stmt`: for a single-name let (`ls.names == null`), if the init is owned, record `ls.name` as an alloc site (only when `ctx.allocs` is non-null, i.e. the final pass). If the init is a bare ident, record an alias edge `{ls.name, rhs}`. Then walk the init expression.
  - `.expr_stmt` with a top-level `.assign` binary: this is the key escape route. If the LHS is a field_access or index (`obj.f = rhs` or `a[i] = rhs`), the RHS escapes (stored into a heap-reachable location). If the LHS is a bare ident, record an alias edge and walk the RHS. Otherwise just walk the RHS.
  - `.return_stmt`: the returned value's idents escape (returning hands ownership out), then walk it.
  - Control flow (if, while, for, switch, defer, block) recurses into conditions and bodies.
  - Footgun the design encodes: field/index assignment escapes conservatively because the analysis does not track whether the container itself is local.

**Cross-references:** consumes `infer.TypedIr.ownedOf` (whether an expression is an owned allocation). Complements the arena/value-struct promotion work in codegen/arc.zig and codegen/types.zig, which is where a future non-report consumer would live. Does not currently feed mono.zig.

---

## `src/frontend/sema/alpha.zig` (265 lines)

**Role in the pipeline:** This is the alpha-renamer. Kyte allows `let` shadowing (a legal, deliberately supported feature, see the memory note kyte-shadowing-alpha-lookup), so within one function body the same source name can denote two different variables. Later passes that key state by name would confuse them. The renamer walks each function, and whenever a `let` binding reuses a name already seen anywhere in the function, it rewrites that binding (and all references resolving to it) to a fresh unique name of the form `name$N`. Names that do not collide are left exactly as written.

The renamer is scope-aware: it maintains a stack of scopes, each holding `src -> renamed` bindings, and `lookup` searches inner-to-outer. Function parameters, closure parameters, `for` loop bindings and `catch` error names are bound "plain" (registered as seen, never renamed themselves), while `let` bindings go through the renaming path. It mutates the AST in place: `ident` expressions are rewritten to the resolved name, and `let` statement name fields are overwritten.

**Key types & data structures:**

- **`const Binding = struct { src: []const u8, renamed: []const u8 }`**. One entry in a scope: original source name and its resolved (possibly identical) name.
- **`pub const Renamer = struct`** (module public). Fields:
  - `allocator: std.mem.Allocator`.
  - `scopes: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Binding)) = .empty`. The scope stack; each scope is a list of bindings. Inner-to-outer lookup, most-recent binding within a scope wins.
  - `owned: std.ArrayListUnmanaged([]const u8) = .empty`. Every freshly allocated `name$N` string, owned here and freed in `deinit`.
  - `seen: std.StringHashMapUnmanaged(void) = .empty`. Every name ever bound in this function (both source names and generated names). A name in `seen` triggers renaming on the next collision.
  - `counter: usize = 0`. Monotonic suffix source for `name$N`.

**Module-level state / constants:**

- **`pub var renames: usize = 0`** and **`pub var shadowed_names: usize = 0`**. Process-global counters for diagnostics. `renames` is incremented each time a fresh name is minted. (`shadowed_names` is declared but not incremented in this file.)

**Functions:**

- **`pub fn init(allocator) Renamer`** (method). Returns a Renamer with the given allocator and all lists empty.
- **`pub fn deinit(self)`** (method). Frees each scope list, the scope stack, the `seen` map, and the `owned` list. Note: it deinits the `owned` list container but relies on `run` creating a fresh Renamer per function, so the generated strings themselves are freed at process teardown via the arena/allocator, not individually here. (Each `owned` entry is an `allocPrint` result; deinit frees the backing array of pointers, and the strings persist in the AST that references them.)
- **`fn push(self) !void`** (private). Pushes a new empty scope.
- **`fn pop(self) void`** (private). Pops and deinits the top scope. Asserts non-empty via `.pop().?`.
- **`fn lookup(self, name) ?[]const u8`** (private). Searches scopes inner-to-outer, and within a scope most-recent-first, returning the `renamed` of the first `src` match, or null. Most-recent-first within a scope is what makes a later shadow win over an earlier binding in the same scope.
- **`fn bind(self, name) ![]const u8`** (private). The renaming binder. If `name` is already in `seen`, it is a collision: increment `counter`, allocPrint `name$counter`, record it in `owned`, use it as the output, and increment `renames`. Register both the source name and (if different) the generated name in `seen`. Ensure a scope exists (push one if the stack is empty), then append `{src = name, renamed = out}` to the top scope. Returns the resolved name. Allocates the fresh string (owned by `self.owned`).
- **`fn bindPlain(self, name) !void`** (private). Registers `name` in `seen` and appends `{src = name, renamed = name}` to the top scope without ever renaming. Used for params, closure params, loop bindings and catch names, i.e. bindings that are not `let` and are never themselves shadow-rewritten. Pushes a scope if none exists.
- **`pub fn walkExpr(self, e: *ast.Expression) anyerror!void`** (method). Recurses through an expression. The load-bearing case is `.ident`: it looks the name up and, if the resolved name differs, rewrites `e.kind` to `.{ .ident = r }`. `.catch_expr` pushes a scope, binds `ce.err_name` plain, and walks the handler. `.closure` pushes a scope, binds each closure param plain, and walks the body (expr or block). All other cases recurse structurally (range, binary, unary, call, generic_call, field_access, index, struct_init, enum_init, cast, optional_chaining, nullish_coalesce, tuple, if_expr, try_expr, block_expr, template_expr, await_expr/go_expr operand). `.jsx_element` and `.literal` are no-ops. Note `.closure`'s block body is `@constCast` to walk it mutably.
- **`pub fn walkBlock(self, b: *ast.Block) anyerror!void`** (method). Pushes a scope, walks every statement, pops on return (via defer). Every block introduces a lexical scope.
- **`pub fn walkStmt(self, s: *ast.Statement) anyerror!void`** (method). The statement walker. Key case is `.let_stmt`: first walk the init (references resolve against the OUTER scope, which is correct: the RHS cannot see the name being bound), then bind. If `ls.names` is a destructuring list, bind each name and write back any renamed slot into `names[idx]`. Otherwise bind the single `ls.name` and overwrite it. `.for_stmt` pushes a scope, walks the initializer, and for the iterator binds the `.item` name or the `.destructure` key/value plain, then walks condition, increment and body. `.switch_stmt` walks the discriminant and each case's values, guard and body. Other cases (if, while, return, defer, expr_stmt, block) recurse. `break_stmt`/`continue_stmt` are no-ops.
- **`pub fn walkFunction(self, f: *ast.FunctionDecl) !void`** (method). Pushes a scope, binds every parameter plain, then walks each body statement. Note it does not call `walkBlock` on the body (which would push a redundant second scope), it iterates `f.body.statements` directly under the param scope.
- **`pub fn run(allocator, program: ast.Program) !void`** (module public, not a method). The driver: for each declaration, create a FRESH `Renamer` per function (free fns, struct methods, enum methods) and `walkFunction` it, deiniting after each. A fresh renamer per function is deliberate: renaming is function-local, so `seen`/`counter` reset at each function boundary.

**Cross-references:** runs before infer.zig so that the typed-IR pass sees already-disambiguated names. ids.zig (the ExprId assigner) and alpha.zig both walk the AST but are independent passes. The ids.zig tests explicitly note "array literal elements (alpha.zig skips these)": alpha.zig's `walkExpr` does not descend into `.literal`, whereas ids.zig does.

---

## `src/frontend/sema/builtins.zig` (268 lines)

**Role in the pipeline:** This is the compile-time registry of everything the compiler treats as a builtin rather than as ordinary Kyte source: receiver-qualified builtin methods (`bytes.alloc`, `simd.add4`, `console.log`), a couple of non-generic `mem` helpers, and the bare-name runtime externs (`kyte_test_fail`, `kyte_reactor_resume`, and so on). Each entry carries the return type as a small `Ret` enum, which `retType` maps to a real `TypeId` on demand. infer.zig consults `find`/`isReceiver`/`findExtern` to type these calls, and codegen lowers them (SIMD entries in particular lower directly to LLVM vector intrinsics).

The registry is a plain flat array searched linearly. That is fine because it is small and consulted at compile time only. Anything not in these tables is treated as ordinary user code.

**Key types & data structures:**

- **`pub const Ret = enum { void_, int, long, ptr, string, bool_, decimal, double, vec4, vec_u8x16, vec_u32x4, vec_u64x2 }`**. The closed set of builtin return kinds. `void_` and `bool_` are spelled with trailing underscores to avoid Zig keyword clashes. The `vec*` members correspond to LLVM vector types (`vec4` is f64x4, then u8x16, u32x4, u64x2).
- **`pub const Builtin = struct { receiver: []const u8, name: []const u8, ret: Ret }`**. One registry row. `receiver` is the qualifier (`"bytes"`, `"simd"`, `"console"`, `"mem"`, or `""` for a bare extern). `name` is the method or function name. `ret` is the return kind.

**Module-level state / constants:**

- **`pub const table = [_]Builtin{...}`**. The receiver-qualified builtin methods. Groups:
  - `bytes.*`: raw buffer primitives. `alloc`/`alloc_persistent`/`new`/`new_persistent`/`new_with_allocator`/`read_ptr` all return `.ptr` (a POINTER, not an int, which a dedicated test pins). `free`/`write_*` return `.void_`, `read_byte`/`read_i32`/`ptr_size`/`length`/`len` return `.int`, `read_string` returns `.string`, `read_decimal`/`write_decimal` handle `.decimal`.
  - `decimal.*`: `fromInt`/`fromString` return `.decimal`, `toInt` returns `.int`.
  - `simd.*`: the explicit SIMD surface. f64x4 (`splat4`/`make4`/`load4`/`add4`/`sub4`/`mul4`/`div4`/`fma4` return `.vec4`, `sum4` returns `.double`, `store4` returns `.void_`). Integer vectors (FR-simd-L1): u8x16, u32x4, u64x2 families with splat/load/store/arith/logic/shift; `movemaskU8x16` collapses sign bits to an `.int`. `clmulU64x2` (FR-simd-L2) is the carryless multiply / GHASH accelerator returning `.vec_u64x2`; it is named with the `U64x2` suffix so codegen routes it through `compileIntSimd`. Codegen lowers each SIMD entry to native LLVM vector ops in `compileSimdCall`.
  - `mem.xorBytes`: the one non-generic `mem` builtin (returns `.void_`). The comment notes the generic `mem` builtins (load/store/rotl/rotr/ctz/clz/bswap) are typed by a special case in infer.zig, not this table, because they are generic.
  - `console.*`: `log`/`info`/`err`/`debug`, all `.void_`.
- **`pub const externs = [_]Builtin{...}`**. Bare-name runtime functions (`receiver = ""`). Test harness hooks (`kyte_test_*`, `kyte_arc_audit_report`), process/args (`kyte_exit`, `kyte_arg_count`, `kyte_arg_at`), float/bit helpers (`kyte_f64_bits`, `kyte_pg_be_f64`, `kyte_pg_be_i64`, `kyte_html_find_meta`), `kyte_f64_sqrt` (lowered to the `llvm.sqrt.f64` intrinsic in codegen, not a runtime symbol, so `math.fsqrt` gets one hardware instruction), mutex/spinlock primitives, thread ids, and the whole reactor/coroutine surface (`currentCoro`, `coroSuspend`, `coroStart`, `kyte_reactor_*`, `kyte_mono_ms`, `kyte_evfilt_user`, and so on), plus process spawn helpers. A comment records that the wolfSSL TLS externs were removed in M13 (TLS is pure Kyte now).

**Functions:**

- **`pub fn findExtern(name) ?Builtin`**. Linear scan of `externs` for an exact name match. Returns the row or null.
- **`pub fn isReceiver(name) bool`**. True if any row in `table` has this receiver. Used to decide whether `foo.bar(...)` names a builtin receiver rather than a user value. Note: `"string"` is deliberately NOT a receiver (a test pins this), and unknowns return false.
- **`pub fn find(receiver, name) ?Builtin`**. Linear scan of `table` for an exact `(receiver, name)` pair. Returns the row or null.
- **`pub fn retType(store: *types.TypeStore, r: Ret) !types.TypeId`**. Maps a `Ret` to a real interned `TypeId` by calling the matching store constructor (`voidT`, `intT`, `longT`, `ptrT`, `stringT`, `boolT`, `decimalT`, `doubleT`, `vecF64x4T`, `vecU8x16T`, `vecU32x4T`, `vecU64x2T`). This is the only function that touches the TypeStore; the tables themselves are pure data. Can error if the store's intern fails.

The file also contains several `test` blocks (not part of the shipped surface) that pin the invariants above: `bytes.alloc` returns a pointer distinct from int and not owned, the address-yielding methods all agree, reads yield values and writes yield void, console is all void, the whole test harness is declared, retired externs (`kyte_file_open`, `__i32_to_string`) do not resolve, and receiver recognition rejects unknowns.

**Gotchas / invariants:** the tables are the single source of truth for builtin return types; adding a builtin means adding a row here (and, for SIMD, a codegen lowering). Generic `mem` builtins are the exception and live in infer.zig. Lookups are exact-match and linear, so receiver and name spelling must match exactly.

**Cross-references:** infer.zig calls `find`/`isReceiver`/`findExtern`/`retType` to type builtin calls (and separately special-cases the generic `mem.*` builtins). codegen (`compileSimdCall`/`compileIntSimd`) lowers the SIMD entries; `kyte_f64_sqrt` is lowered to an LLVM intrinsic rather than emitted as a call.

---

## `src/frontend/sema/ids.zig` (268 lines)

**Role in the pipeline:** This pass stamps every AST expression with a stable `ExprId`. The problem it solves: side tables (types, ownership dispositions, per-instance overlays) want to key on "this specific expression node", but a node's pointer address is not stable (an `ast.Expression` is a value type, so copying it, moving a slice, or storing it in a container changes its address). An `ExprId` survives a copy, an address does not, which is exactly what one of the tests asserts. So before infer.zig and inst_disp.zig record anything keyed by node, `Assigner.run` gives every expression a unique non-zero id.

The assigner walks the whole program deterministically in source order and assigns `1, 2, 3, ...`. Zero is never handed out because `ExprId`'s zero value is the `unassigned` sentinel.

**Key types & data structures:**

- **`pub const Assigner = struct`** (module public). Fields:
  - `next: u32 = 1`. The next id to hand out. Starts at 1 so 0 stays reserved for `unassigned`.
  - `assigned: usize = 0`. Count of ids handed out (diagnostic / test hook).

**Module-level state / constants:** none beyond the struct fields. The `ExprId` type itself lives in ast.zig (`enum(u32) { unassigned = 0, _ }`).

**Functions:**

- **`pub fn init() Assigner`** (method). Returns a default `Assigner` (`next = 1`, `assigned = 0`).
- **`fn fresh(self) ast.ExprId`** (private, method). Returns `@enumFromInt(self.next)`, then increments `next` and `assigned`. The single point that mints ids.
- **`pub fn run(self, program: ast.Program) anyerror!void`** (method). Walks every declaration. Entry point for the whole program.
- **`pub fn walkDecl(self, d: *ast.Declaration) anyerror!void`** (method). Dispatches: `fn_decl` and struct/enum methods go through `walkFn`; `const_decl` walks its value (const initialisers contain expressions that need ids too); `union_decl`/`import_decl`/`export_decl`/`trait_decl` are no-ops.
- **`fn walkFn(self, f: *ast.FunctionDecl) anyerror!void`** (private, method). Walks the function body block.
- **`pub fn walkBlock(self, b: *ast.Block) anyerror!void`** (method). Walks each statement. Unlike alpha.zig this does not push scopes, ids do not care about scoping.
- **`pub fn walkStmt(self, s: *ast.Statement) anyerror!void`** (method). Recurses through every statement kind, walking each contained expression: let init, expr_stmt, if (condition + branches), while, for (initializer, condition, increment, iterator iterable, body), switch (discriminant, case values, case guards, case bodies, default), return value, defer expr. `break_stmt`/`continue_stmt` are no-ops.
- **`pub fn walkExpr(self, e: *ast.Expression) anyerror!void`** (method). The core. First line assigns `e.id = self.fresh()`, so EVERY visited expression gets an id, then recurses into children. Covers range, literal (descending into `.array` items, `.array_repeat` value, `.object` field values, while scalar literals are leaves), ident (leaf), binary, unary, call, generic_call, field_access, index, struct_init, enum_init, cast, optional_chaining, nullish_coalesce, tuple, if_expr, try_expr, catch_expr, block_expr, template_expr, await_expr/go_expr operand, closure (body expr or block), and jsx_element (via `walkJsx`). Note it descends into array-literal elements, which alpha.zig skips, a difference the tests call out explicitly.
- **`fn walkJsx(self, j: *ast.JsxElement) anyerror!void`** (private, method). Walks JSX attribute expression values and children (nested elements recurse, expression children walk, statement children go through `walkStmt`, text is a leaf).

The file's `test` blocks pin the contract: id 0 is never handed out (0 means unassigned), distinct expressions get distinct ids, an id survives a value copy while an address does not (the stated whole point), array literal elements are reached, and nested structure is fully covered with no duplicates.

**Gotchas / invariants:** the walk order must match every other AST walker's coverage, or some node will never get an id and its side-table lookups will collide on `unassigned`. The traversal here is intentionally the most complete of the sema walkers (it descends into literals and JSX). `assigned` equals the number of expressions in the program after `run`.

**Cross-references:** ids must be assigned before infer.zig records `expr_types`/`owned` and before inst_disp.zig records `expr_types_inst`/`owned_inst`, all of which are keyed by `e.id`. Consumed indirectly everywhere the TypedIr is queried by node.

---

## `src/frontend/sema/inst_disp.zig` (263 lines)

**Role in the pipeline:** This is the instantiation-dispatch overlay, part of the string-engine-removal work. Kyte monomorphizes generics, but ownership and type decisions inside a generic body were historically made by reconstructing type names as strings. This pass instead records, per concrete instance, a TypeId overlay so those decisions can be made from TypeIds. For each instance it does two things: record `tp_resolve[{type_param, inst_key}] = concrete_arg` (so a type parameter resolves to its concrete TypeId under a given instantiation), and walk the generic body recording `expr_types_inst` (the concrete type of each expression under this instance) and `owned_inst` (its ownership disposition). With these in place, `typeOfExprConcrete` and `isOwnedTypeId` become total inside generic bodies keyed by `current_instantiation_id`, so codegen no longer needs the string engine there.

There are three entry points, one per kind of generic thing: struct instances (`run`), free generic function instances (`runFreeFns` / `recordFreeFnInst`), and generic method instances (`runMethods`). Struct T-params come from the receiver struct's args; method U-params come from the method owner's args; a method combines both under one key.

**Key types & data structures:**

- **`const Ctx = struct`**. The per-instance walk context. Fields:
  - `allocator`, `store: *TypeStore`, `ir: *TypedIr`.
  - `decl: types.SymbolId` and `args: []const TypeId`: the PRIMARY substitution owner and its concrete type args (the struct, or the free fn, or, for a method, the struct).
  - `inst: TypeId`: the instantiation key under which overlay entries are recorded.
  - `decl2: ?types.SymbolId = null` and `args2: []const TypeId = &.{}`: an optional SECOND substitution applied after the first. For a generic METHOD body the first is the struct's `(decl, T-args)` and the second the method's `(mid, U-args)`, so both `T` and `U` resolve. Null for struct/free-fn bodies.
  - Methods: **`fn concreteOf(self, t) TypeId`** applies `subst.substitute` with the primary owner/args, then, if present, the secondary owner/args, returning the fully concretised TypeId (falling back to the input on error). **`fn visit(self, e)`** records the overlay for one expression: if the IR knows `typeOf(e)`, compute its concrete type, record `owned_inst[e.id, inst] = disposition(...)`, and if the concrete type differs from the generic one record `type_inst[e.id, inst] = concrete`. Then recurse via `children`. **`fn children(self, e)`** recurses into every sub-expression (call/generic_call callee+args, binary, unary, field_access, index, cast, optional_chaining, nullish_coalesce, template_expr parts, tuple, struct_init/enum_init field values, if_expr, block_expr statements, try_expr, catch_expr, await/go operand, closure body). **`fn stmt(self, s)`** recurses through statements (let init, expr_stmt, return, if, while, for condition/increment/iterator/body, switch, defer, block).

**Module-level state / constants:** none. Everything is passed in. The two `@import("mono.zig")` calls inside `runFreeFns`/`runMethods` reach mono's discovered-instance lists.

**Functions:**

- **`pub fn run(allocator, store, tab: *const SymbolTable, ir, insts: []const TypeId)`**. Struct instances. For each `inst` that is a `.struct_` with type args: for each arg, intern the corresponding `type_param{owner = st.decl, index = i}` and record `tp_resolve[tp, inst] = arg`. Then look up the struct decl's symbol; if it is a struct, build a `Ctx` (single owner) and walk every method body's statements. Records overlay for the whole struct including all its methods under the one struct instance key.
- **`pub fn runFreeFns(allocator, store, ir, program: ast.Program)`**. Free generic functions. Reads `mono.free_fn_insts` and calls `recordFreeFnInst` for each discovered instance. The comment notes only directly-discovered instances are handled here; the transitive path (`noteFreeFnInstStr`) has no `inst_key` yet (B1) and is handled later from codegen.
- **`pub fn recordFreeFnInst(allocator, store, ir, program, fn_name, owner_opt: ?SymbolId, args_opt: ?[]const TypeId, key_opt: ?TypeId)`**. Records the overlay for ONE free-fn instance. No-op unless owner, args and key are all present (each `orelse return`). For each arg, record `tp_resolve[type_param{owner, i}, key] = arg`. Find the generic free fn by name, build a single-owner `Ctx`, and walk its body. Callable both from sema (`runFreeFns`) and from codegen's transitive fixpoint as new TypeId-native instances are discovered (B1), which is why it takes optionals and fails soft.
- **`fn findFreeFn(program, name) ?*const ast.FunctionDecl`** (private). Linear scan of declarations for a `fn_decl` whose name matches AND that has type params (`type_params.len > 0`), i.e. an actually-generic free fn. Returns null otherwise.
- **`pub fn runMethods(allocator, store, tab: *const SymbolTable, ir)`**. Generic method instances (`List<T>.map<U>`, B2). Reads `mono.method_insts`. For each with an `inst_key`, `recv`, `method_owner` and `args_tids`: verify `recv` is a `.struct_`. Record `tp_resolve` for BOTH the struct T-params (from `si.args` under `si.decl`) AND the method U-params (from `margs` under `mowner`), all under the combined `key`. Look up the method owner symbol; if it is a function, build a TWO-owner `Ctx` (`decl/args` = struct, `decl2/args2` = method) and walk the body. This is what makes both `T` and `U` resolve via TypeIds inside the method body.
- **`fn disposition(kind: ast.ExprKind, t: TypeId, store: *const TypeStore) bool`** (private). Computes the ownership disposition recorded in `owned_inst`. Certain syntactic forms are never owning regardless of type: `.ident`, `.field_access`, `.index` (these borrow), `.binary` with `.assign` op, `.literal`, and `.try_expr`/`.cast`/`.await_expr`/`.go_expr`/`.optional_chaining`. For everything else, the disposition is `store.isOwnedSafe(t)`. This mirrors the "is this expression producing a fresh owned value" question the ARC pass asks, but decided from the concrete instance type.

**Gotchas / invariants:** every overlay is keyed by `(e.id, inst)`, so ids.zig must have run first. Struct instances use one owner; method instances use two (struct then method) and the order matters (`concreteOf` applies primary before secondary). The pass is a no-op for non-generic instances and fails soft (`catch continue`, `orelse return`) rather than erroring, because it is an overlay: a missing entry falls back to the non-instance decision, it does not corrupt anything. The B1 transitive free-fn path is intentionally not covered here.

**Cross-references:** built directly on infer.zig's TypedIr (`recordTpResolve`, `recordOwnedInst`, `recordTypeInst`, `typeOf`), `subst.substitute`, and mono.zig's instance lists (`free_fn_insts`, `method_insts`). It is the seam described in the memory notes kyte-string-engine-removal / kyte-optimiser-emit-path: it lets codegen/types.zig and codegen ownership decisions read TypeIds inside generic bodies (`current_instantiation_id`) instead of parsing type-name strings.

---

## `src/frontend/sema/sema.zig` (101 lines)

**Role in the pipeline:** This is the small container that holds the whole semantic-analysis state for a compilation and its lifetime. It is not the analysis itself (that is infer/mono/ownership/lower), it is the box those passes read and write: the TypeStore (interned types), the SymbolTable (declarations), the TypedIr (per-node types and ownership), plus a cache mapping each TypeId to its display name string. It is heap-allocated as a single `*Sema` and torn down in one `destroy`.

The name cache exists because display names (`List<int>`, and so on) are computed lazily and are expensive to rebuild; interning them per TypeId means the same bytes are handed back on repeat lookups (a test pins that two interns of the same name return the identical pointer, not merely an equal string).

**Key types & data structures:**

- **`pub const TypeId = types.TypeId`** (re-export for convenience).
- **`pub const Sema = struct`** (module public). Fields:
  - `allocator: std.mem.Allocator`.
  - `store: types.TypeStore`. Owns all interned types.
  - `tab: symbols.SymbolTable`. Owns all declaration symbols.
  - `ir: infer.TypedIr = .{}`. The typed IR side tables (types, ownership, instance overlays).
  - `names: std.AutoHashMapUnmanaged(TypeId, []const u8) = .empty`. TypeId to display name. The map OWNS each name string (freed in `destroy`); the invariant is exactly one entry per TypeId and one owned allocation per entry.

**Module-level state / constants:** none beyond the struct.

**Functions:**

- **`pub fn create(allocator) !*Sema`** (method). Allocates a `Sema`, initialises `store` and `tab` from the allocator, leaves `ir` and `names` empty. Returns the heap pointer. The caller owns it and must `destroy`.
- **`pub fn destroy(self)`** (method). Frees every cached name string, deinits `names`, `ir`, `tab`, `store` (in that order), then destroys the `Sema` allocation itself. Order matters: the name strings are freed before the map that holds them. This is the single teardown path; a test asserts create/destroy leaks nothing.
- **`pub fn internName(self, id: TypeId, name: []const u8) ![]const u8`** (method). Caches a display name for a TypeId. If an entry already exists, it FREES the passed-in `name` (the caller handed ownership over, and the cache already has a copy) and returns the cached bytes. Otherwise it stores `name` (taking ownership) and returns it. So the caller must pass an owned/duped string and must not use it afterwards; the returned slice is the canonical one. This is what guarantees pointer-identity for repeated names.
- **`pub fn cachedName(self, id: TypeId) ?[]const u8`** (method, const self). Returns the cached name for a TypeId, or null if none has been interned. A pure lookup, no allocation.

The `test` blocks pin the ownership contract: create/destroy leaks nothing, a re-interned name returns the SAME bytes (pointer equality) with the second copy freed, distinct types get distinct names and an un-interned type returns null, and the store's own interned slices are freed too.

**Gotchas / invariants:** `internName` takes ownership of its argument, so passing a non-owned or reused slice is a use-after-free or double-free waiting to happen; callers dupe first (the tests use `testing.allocator.dupe`). The name cache is purely a display convenience; it is not consulted for type identity (that is the TypeStore's job via interning). The whole `Sema` is one allocation with one owner and one `destroy`.

**Cross-references:** wraps `types.TypeStore`, `symbols.SymbolTable`, `infer.TypedIr`, and (through its fields) is the object the other sema passes documented above operate on: escape.zig reads `ir`, inst_disp.zig reads/writes `store`/`ir`/`tab`, builtins.zig's `retType` takes the `store`. codegen/types.zig consumes the same TypeStore and the TypedIr overlays inst_disp.zig populates.
