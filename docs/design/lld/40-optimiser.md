# Low-Level Design: the Nova optimiser middle-end (`src/optimiser/` + the LIR emit path)

This chapter is a file-by-file, function-by-function reference for the Nova middle-end: the three-tier
HIR / MIR / LIR pipeline, the lowering chain that feeds it, the pass pipeline that optimises it, and the
one backend module that turns the optimised IR into LLVM directly. It is written for a maintainer who is
new to the code and wants to be productive without reverse-engineering the whole thing first. It documents
the code as it stands, not the aspirational design. For the design rationale and the rollout history, read
`docs/design/optimiser.md`; for the coverage backlog, read `docs/design/optimiser-pending.md`. This chapter
cites those where they carry an ABI fact you must not violate.

## Overview: what the middle-end is and how the pieces fit

The shipping compiler still walks the AST directly in `backend/codegen/llvm_codegen.zig`, guided by the sema
`TypedIr`, and emits LLVM in one pass. The middle-end is a parallel, staged path that sits between sema and
that backend. It exists for two reasons: to give the ARC traffic (retain / release) a representation the
compiler can reason about and cancel, and to give the classic scalar optimisations (fold, DCE, copy-prop,
mem2reg, CFG cleanup) somewhere to live. It runs in two distinct modes, and keeping them apart is the single
most important thing to understand before touching this code.

**The three tiers.** Each is a strict lowering of the one above it:

- **HIR** (`hir.zig`) is a typed, desugared tree stored in a flat node table. It is the AST with Nova sugar
  removed (`for`, `switch`, `?.`, `??`, string interpolation, ternary all lower to explicit `if` / `loop` /
  compare forms) and, as ownership threading matures, explicit `retain` / `release` nodes. It is still a tree
  because desugaring reads most naturally as a structural rewrite.
- **MIR** (`mir.zig`) is SSA over a control-flow graph of basic blocks. Each instruction defines at most one
  `Value` (a virtual register), each block ends in a terminator, and this is where every optimiser pass runs.
  Locals are lowered as memory (alloc + load / store), so a later `mem2reg` builds SSA and no phi construction
  is done during lowering.
- **LIR** (`lir.zig`) is a linear, near-LLVM op stream: MIR after the optimiser, with the CFG resolved into
  labels and jumps and every op mapping one-to-one onto an `LLVMBuild*` call.

**The lowering chain.** `lower_ast_hir.zig` builds HIR from the AST + `TypedIr` (and threads ARC nodes).
`lower_hir_mir.zig` builds the MIR CFG from HIR. `lower_mir_lir.zig` linearises optimised MIR into LIR. Each
lowering step is deliberately total: it handles every node kind and never crashes, falling to a structural
placeholder for anything not yet modelled, so the whole corpus flows through all four tiers.

**The pass pipeline.** `pass.zig` defines the `Pass` interface and a bounded fixpoint runner. `driver.zig`
holds the pipeline array, in dependency order: `mem2reg`, `constfold`, `copyprop`, `dce`, `arc_elision`,
`inline`, `simplifycfg`. `verify.zig` checks MIR well-formedness after every pass in debug builds.

**Two modes: the M0-M5 shadow versus the emit half.** These share the tiers and the passes but differ in
what they produce.

- The **shadow** (`driver.lowerProgramShadow`, gated by `NOVA_OPT` in the build path) lowers every function
  through all four tiers, runs the passes, and reports coverage. It does NOT emit anything: the AST backend
  still produces the program. Its job is to prove the machinery is correct and measure how much of the corpus
  it covers. This is milestones M0 (scaffold) through M5 (inline), all landed and firing behind `NOVA_OPT`.
- The **emit half** (`backend/codegen/lir_emit.zig`, gated by the SEPARATE `NOVA_OPT_EMIT`) actually emits an
  LLVM function body from the optimised MIR. This is milestone M6, in progress. It is a per-function FALLBACK:
  `tryEmit` returns false for anything outside a provable subset, and codegen then emits that function from
  the AST unchanged. So nothing regresses; only functions the emitter can prove it handles take the new path.

**The emit path's gating discipline.** This is the safety architecture, and it is layered on purpose. For each
candidate function `tryEmitInner` runs, in order:

1. Up-front signature rejects: `async fn` (coroutine), then per-param and per-return type-ref checks (optional,
   error-union, unmodelled scalar shapes).
2. `hirEmittable(hf)`: a whole-function allowlist over HIR node KINDS. This runs on HIR, not MIR, because MIR
   collapses `str` / `float` / `null` to `const_int 0` and the node kind would be lost.
3. Lower HIR to MIR, run the optimiser pipeline, then `verify.verify` the MIR (defence in depth, A3).
4. `mirEmittable(mf)`: a whole-function dry validation over every instruction and terminator. It builds NO
   IR. It MUST pass before `emitFunc` touches the builder, because a mid-stream reject would leave a
   half-filled LLVM block that the AST fallback would then double-fill. This is the "dry-validate-then-emit"
   rule, and it is delegated per instruction to `mirInstEmittable`.
5. Only then `emitFunc` walks the MIR and calls `emitInst` per instruction, which produces the exact LLVM the
   AST path would have.

Any reject at any layer returns false and the function falls back to the AST. The invariant is: an emitted
function is byte-identical to the AST-emitted one and ASAN-clean, or it is not emitted at all.

**The recurring footgun: adding a MIR op means updating N switches.** A new `Inst.Op` variant must be added
to, at minimum: `instOperands`, `rewriteInst`, `hasSideEffects` (all in `mir.zig`), `lower_mir_lir.lowerInst`,
`inline.remapOp`, and, if it is emittable, `mirInstEmittable` + `emitInst`. Several of these are exhaustive
switches with no `else`, so the compiler will catch the ones that are; `hasSideEffects` and the emit gates
have catch-alls, so those it will NOT catch. Miss one and you get a silent miscompile or a dropped operand.

**The ABI landmines** (each is stated at its site below, collected here as a checklist):

- A **value optional** (`int | undefined`) is a nullable pointer to an 8-byte ARC box; a present `0` is a
  NON-null box, absent is the null word. The emit path does not box, so any value-optional-typed value forces
  fallback. A **reference optional** (`string | undefined`) is NOT boxed (0 == absent) and does emit.
- A **tuple element** is a raw 64-bit word with no 32-bit wrap, so it must be word-typed, not `int`-typed, or
  arithmetic on it diverges from the AST on overflow.
- An **f32** is PROMOTED to double everywhere in scalar code, so its word carries the double's 64-bit pattern;
  it takes the identical `DoubleType` bitcast as f64, and using `LLVMFloatType` would reinterpret garbage.
- An **error-union** (`T | E`) is a tagged 16-byte heap box with a nested value-optional ok arm; not modelled.
- A **module-level const reference** is deliberately OPAQUE (`global_const`) so the folding passes never treat
  it as a known value; lowering it to `const_int 0` miscompiled every `& MASK32` in the crypto stdlib.

---

## `src/optimiser/hir.zig` (138 lines)

**Role in the pipeline.** Defines the HIR: a typed, desugared tree stored as a flat `Node` table addressed by
`HirId`. It is the target of `lower_ast_hir` and the source for `lower_hir_mir`. This file is data
definitions plus a small builder; it has no lowering logic of its own.

**Module-level state / constants.**

- **`pub const TypeId = types.TypeId`**, **`pub const SymbolId = types.SymbolId`** -- the middle-end reuses the
  frontend type system verbatim; it never invents a parallel one.
- **`pub const unset_ty: TypeId = @enumFromInt(0xFFFF_FFFF)`** -- the "no type threaded here yet" sentinel.
  Store TypeIds are dense indices from 0 and `int` is interned first, so TypeId 0 is a REAL type and cannot
  mean "unset". This out-of-range value never collides. Its absence caused the original whole-optimiser bug:
  using `@intFromEnum(ty)==0` for "untyped" made every `int` value read as untyped.
- **`pub const HirId = enum(u32) { none = 0xFFFF_FFFF, _ }`** -- a node index; `none` is the null reference.

**Key types & data structures.**

- **`pub const BinOp`** -- enum: `add, sub, mul, div, mod, and, or, eq, ne, lt, le, gt, ge, bit_and, bit_or,
  bit_xor, shl, shr, assign`. Note `assign` lives here (HIR keeps assignment as a binop until HIR->MIR splits
  it out).
- **`pub const UnOp`** -- enum: `neg, not, bit_not`.
- **`pub const Block`** -- an ordered `[]const HirId` of statement / expression node ids (a desugared block).
- **`pub const Arm`** -- `{ tag: ?SymbolId, body: Block }`, a match arm shape (defined, not yet heavily used).
- **`pub const Node`** -- `{ kind: Kind, ty: TypeId = unset_ty, span: ast.Span, expr_id: ast.ExprId }`. `ty` is
  filled by lowering from the `TypedIr`; `expr_id` links back to the source expression for ownership lookup
  and diagnostics.
- **`pub const Node.Kind`** -- the tagged union of node kinds. The full set:
  - Literals: `int: i64`, `float: f64`, `bool: bool`, `str: []const u8`, `null`, `undefined`.
  - References: `ident: []const u8`; `param: u32` (function parameter N, bound to its name by a synthesised
    `let` in `lowerFunc`); `field: {object, name}`; `index: {object, idx}`.
  - Operators: `binop: {op, lhs, rhs}`, `unop: {op, operand}`.
  - Calls: `call: {callee, args, sym: ?SymbolId}`, `generic_call: {callee, args, sym}`. `sym` is the resolved
    callee SymbolId from the `TypedIr` when known.
  - Aggregates: `struct_init: {type_name, fields, field_names}`, `enum_init: {name, variant, fields}`,
    `tuple: []const HirId`.
  - Value-producing desugar targets: `if_expr: {cond, then, else_}`, `nullish: {lhs, rhs}` (`a ?? b`),
    `optional_chain: {object, name}` (`a?.b`), `template: []const HirId`, `range: {start, end, inclusive}`,
    `cast: HirId` (target type carried in `.ty`), `closure: {body}` (opaque body ref, lifted by the backend),
    `try_: HirId`.
  - ARC: `retain: HirId`, `release: HirId`.
  - Statements / control: `let: {name, value: ?HirId}`, `assign: {target, value}`, `ret: ?HirId`, `brk`,
    `cont`, `if_: {cond, then: Block, else_: Block}`, `loop_: {cond: ?HirId, body: Block}` (cond null means
    infinite loop), `block: Block`.
  - Async: `await_: HirId`, `spawn_: HirId`.
  - `unsupported: []const u8` -- a form not yet lowered; carries the AST tag name for the coverage histogram, so
    lowering never crashes on real code.

- **`pub const Func`** -- a lowered function: `{ name, sym: ?SymbolId, inst: ?TypeId, nodes:
  ArrayListUnmanaged(Node), entry: Block, owned_strings: ArrayListUnmanaged([]u8) }`. `inst` is the
  monomorphisation instance. `owned_strings` holds heap-allocated names the lowering had to synthesise (e.g.
  a `string_<method>` callee name that is not a slice into the AST), owned here so they outlive lowering and
  emit and are freed once.

**Functions (all methods on `Func`).**

- **`pub fn deinit(self, allocator)`** -- frees every `owned_strings` entry, then the two ArrayLists. Owns and
  frees its own storage.
- **`pub fn internName(self, allocator, name: []u8) ![]const u8`** -- takes ownership of a heap name, appends it
  to `owned_strings`, returns a stable slice. Freed in `deinit`. Callers that fail to intern must free the
  name themselves (see `stringMethodName`).
- **`pub fn add(self, allocator, node) !HirId`** -- appends a node, returns its id (the pre-append length).
- **`pub fn get(self, id) Node`** -- returns the node by index (returns a copy).
- **`pub fn unsupportedCount(self) usize`** -- counts `.unsupported` nodes; a coverage metric for the shadow.

---

## `src/optimiser/mir.zig` (346 lines)

**Role in the pipeline.** Defines the MIR (SSA over a CFG), the builder, and the shared operand-walking
helpers that every pass and the verifier use. This is the busiest definition file: the `Inst.Op` union is the
contract between the lowering, the passes, and the emitter, and the free helpers (`instOperands`,
`rewriteInst`, `hasSideEffects`) are the exhaustive switches that MUST stay in sync with it.

**Module-level state / constants.**

- **`pub const unset_ty: TypeId = @enumFromInt(0xFFFF_FFFF)`** -- mirrors `hir.unset_ty`; same rationale.
- **`pub var type_store: ?*const types.TypeStore = null`** -- the sema `TypeStore`, set by the driver and by the
  emit path so passes (constfold) can resolve a TypeId's integer width and stay width-honest. Null when unset,
  which makes width-dependent folding conservatively skip (never wrong).
- **`pub var emit_mode: bool = false`** -- set true by the LIR emit path around its own HIR->MIR lowering, false
  for the shadow. It gates lowerings that produce a DEDICATED emit-path op (currently `.template`): the shadow
  keeps its structural placeholder so op counts stay byte-identical, while the emit path gets a real op. Always
  reset via `defer` by the setter so it never leaks into a later shadow lowering.
- **`pub const IntWidth = struct { width: u16, signed: bool }`**.

**Key types & data structures.**

- **`pub const Value = enum(u32) { invalid = 0xFFFF_FFFF, _ }`** -- an SSA virtual register; `.invalid` marks a
  value-less instruction (store, release).
- **`pub const Block = enum(u32) { _ }`**.
- **`pub const BinOp`** -- enum: `add, sub, mul, div, mod, eq, ne, lt, le, gt, ge, bit_and, bit_or, bit_xor,
  shl, shr`. Note: NO `assign` and NO `and`/`or` (HIR->MIR maps logical `and`/`or` onto `bit_and`/`bit_or` and
  handles `assign` before `mapBin`).
- **`pub const Inst = struct { result: Value, ty: TypeId, op: Op }`**.
- **`pub const Inst.Op`** -- the full union. Every variant, with what it means:
  - **`binop: {op: BinOp, lhs: Value, rhs: Value}`** -- a two-operand arithmetic / comparison / bitwise / shift.
  - **`load: {addr}`** / **`store: {addr, val}`** -- memory access on a slot (a local, pre-mem2reg).
  - **`alloc: {ty: TypeId}`** -- a stack slot for a local.
  - **`gep: {base, offset: u32}`** -- a field / element address computation (defined, structural).
  - **`call: {callee: SymbolId, args, takes_ownership: []const bool, name: ?[]const u8}`** -- a direct call.
    `name` is the source callee name the emit path resolves by (the optimiser has no symbol table at emit
    time); `takes_ownership` is the per-argument +1 flag for ARC reasoning.
  - **`indirect_call: {receiver: Value, slot: u32, args, name: ?[]const u8}`** -- dynamic dispatch through a
    trait fat pointer. `receiver` is the trait-object word (a pointer to a `{struct_ptr, vtable}` pair); `name`
    is the trait method's source name. `slot` stays a placeholder because the optimiser has no trait table; the
    backend resolves the real slot from the receiver's TypeId at emit time. `args` EXCLUDES the receiver (the
    backend prepends `struct_ptr` as self, matching the AST calling convention).
  - **`cast: {val}`** -- an int<->int cast; the target type is `Inst.ty`.
  - **`retain: {val}`** / **`release: {val}`** -- first-class ARC, so the elision pass can see and cancel pairs.
  - **`await_: {fut}`** / **`spawn_: {callee: SymbolId, args}`** -- async (structural; emit rejects them).
  - **`const_int: i64`** -- a constant materialised by const-folding or a literal. A float literal is carried
    here as the double's BIT PATTERN, with a float `Inst.ty` to keep constfold from folding it as an integer.
  - **`const_str: []const u8`** -- a string literal (raw source bytes). The emit path materialises it via an
    IMMORTAL interned global (retain / release are no-ops on it), so it needs no ARC. The shadow lowers it to a
    structural `const_int 0` for op counts.
  - **`global_const: []const u8`** -- a reference to a module-level `const` BY NAME. Deliberately OPAQUE: its
    value is unknown to the optimiser (a const can be a runtime-computed expression), so the folding passes
    must NOT treat it as any particular constant. Lowering it to `const_int 0` let constfold turn `x & MASK32`
    into 0. The emit path resolves it at emit time via `compiler.constants` + `compileConstRef`; `mirEmittable`
    only accepts it when the named const is a scalar int / bool. The shadow lowers it to `const_int 0`.
  - **`param: u32`** -- function parameter N; its value is the Nth LLVM function argument.
  - **`struct_new: {type_name, field_names, args}`** -- an atomic struct construction carrying the names a
    backend needs to resolve layout (offsets / widths) via the type store; allocates + initialises.
  - **`field_get: {base, field}`** / **`field_set: {base, field, val}`** -- read / write one field at its real
    width.
  - **`index_get: {object, idx}`** -- element read `object[idx]`. Carries no element type: the backend resolves
    layout from the object's threaded TypeId (a string indexes a byte with zext; an array GEPs the i64-word
    element). Float-element arrays are rejected downstream.
  - **`tuple_new: {args}`** -- tuple construction `(a, b, ...)`: a positional heap aggregate, N i64 words
    (`nova_bytes_alloc`), element k at offset `k*8`, each arg stored as the raw i64 word. Distinct from
    `struct_new` because a tuple has no named struct / field names; the layout is purely positional. The emit
    path gates it to all-scalar element tuples (owned-element tuples need element ARC + a tuple destructor).
  - **`template: {parts}`** -- string interpolation. Carries the ORDERED part values; every part is a `string`
    (an interpolated var OR a literal-text run materialised as a `const_str`). The emit path reproduces the
    AST's StringBuilder lowering. Produced ONLY under `emit_mode`; `mirEmittable` admits it only when every
    part is a string.
- **`pub const Terminator`** -- union: `br: {dest, args}`, `condbr: {cond, then, else_}`, `switch_: {scrutinee,
  cases: []const Case, default}`, `ret: ?Value`, `unreachable_`. **`Terminator.Case = {val: i64, dest}`**.
- **`pub const BasicBlock = struct { params: []const Value, insts: ArrayListUnmanaged(Inst), term: Terminator
  = .unreachable_ }`**. `params` are block arguments (our phi spelling); the memory-based lowering produces
  none, so they stay empty in practice. A fresh block defaults to `.unreachable_`, which is how
  `mirTerminated` and the verifier detect an un-terminated block.
- **`pub const Func = struct { sym, inst, blocks, value_types, entry }`**. `value_types` maps each `Value`
  (by `@intFromEnum`) to its TypeId.

**Functions.**

- **`pub fn intWidthOf(tid) ?IntWidth`** -- resolves `tid` to its integer machine width / signedness via
  `type_store`, or null if not an int prim / no store. Returns null on out-of-range or `unset_ty`.
- **`pub fn isFloatTy(tid) bool`** -- true if `tid` is a float primitive. Used to keep constfold from folding a
  float binop as an integer op (a float const_int holds the double's bit pattern, so `l +% r` would add bit
  patterns, producing garbage).
- **`pub fn wrapToWidth(v: i64, width: u16, signed: bool) i64`** -- wraps `v` into `width` bits: truncate, then
  sign- or zero-extend back to i64. This is the i64-domain twin of codegen's `canonicalizeInt`, so a folded
  constant equals the runtime result. Width 0 or >=64 is a passthrough. Signed uses a shift-left-then-
  arithmetic-shift-right; unsigned masks.
- **`pub fn instOperands(op: Inst.Op, buf: *[8]Value) []Value`** -- collects the Value operands an instruction
  READS into `buf`, returns the used slice. An inner `push` helper skips `.invalid` and bounds-checks the
  fixed 8-slot buffer (long arg lists are truncated; analysis stays conservative). EXHAUSTIVE SWITCH -- a new op
  with operands must be added here or the passes and the verifier will silently ignore its operands. Definers
  (`alloc`, `const_int`, `const_str`, `global_const`, `param`) push nothing.
- **`pub fn termOperands(term, buf: *[2]Value) []Value`** -- collects a terminator's read operands (`condbr`
  cond, `switch_` scrutinee, `ret` value); `br` and `unreachable_` read none.
- **`pub fn replaceUses(func, from, to)`** -- rewrites every operand equal to `from` to `to`, across every
  instruction and terminator. Used by copy propagation and load-forwarding. Definitions (results) are NOT
  touched. Delegates to `rewriteInst` / `rewriteTerm`.
- **`fn sw(v: *Value, from, to)`** (private) -- the single-operand rewrite primitive (`if v.* == from`).
- **`fn rewriteInst(op: *Inst.Op, from, to)`** (private) -- the per-op operand rewrite. EXHAUSTIVE SWITCH; must
  mirror `instOperands` exactly (same operands, in place). Miss an op and copy-prop / mem2reg silently fail to
  rewrite through it.
- **`fn rewriteTerm(term: *Terminator, from, to)`** (private) -- the terminator twin.
- **`pub fn hasSideEffects(op: Inst.Op) bool`** -- true if the instruction has an observable effect and must not
  be removed by DCE even when its result is unused. True for: `store`, `call`, `indirect_call`, `retain`,
  `release`, `await_`, `spawn_`, `struct_new`, `tuple_new`, `field_set`, `template` (each allocates and / or
  writes memory or calls out). False for the pure value producers. NOTE this has a catch-all-style explicit
  false arm, so a NEW op defaults to whatever you write; get it wrong and DCE either drops a side-effecting op
  or keeps dead code.
- **`Func` methods:** **`deinit`** (frees each block's insts, then the block list + value_types),
  **`typeOf(v) TypeId`**, **`newValue(allocator, ty) !Value`** (appends to `value_types`, returns the new id),
  **`newBlock(allocator) !Block`**, **`block(b) *BasicBlock`**, **`emit(allocator, b, ty, op) !Value`**
  (appends a value-producing instruction, returns its result), **`emitVoid(allocator, b, op) !void`** (appends
  a value-less instruction with `result = .invalid`, `ty = unset_ty`), **`setTerm(b, term)`**.

---

## `src/optimiser/lir.zig` (59 lines)

**Role in the pipeline.** Defines the LIR: a linear, near-LLVM op stream that a `lir_to_llvm` emitter would
consume with no decisions left to make. In the current codebase LIR is produced by `lower_mir_lir` for the
SHADOW's op-count metric only; the emit path drives LLVM directly from MIR and never materialises LIR (see the
notes in `lower_mir_lir`). So LIR is real and complete but, on the emit path, dormant.

**Module-level state / constants.** `TypeId`, `SymbolId` re-exports; **`pub const Reg = enum(u32) { _ }`** and
**`pub const Label = enum(u32) { _ }`**.

**Key types & data structures.**

- **`pub const BinOp`** -- same 15-variant set as `mir.BinOp` (no assign / and / or).
- **`pub const Op`** -- the linear op union, intentionally close to the LLVM builder surface:
  - Arithmetic / memory: `binop: {result, op, lhs, rhs}`, `load: {result, addr}`, `store: {addr, val}`,
    `alloc: {result, ty}`, `gep: {result, base, offset}`, `cast: {result, val, to: TypeId}`, `const_int:
    {result, val}`, `param: {result, index}`.
  - Calls: `call: {result: ?Reg, callee, args}`, `indirect_call: {result: ?Reg, receiver, slot, args}`.
  - ARC runtime calls (emitted, not decided): `retain: {val}`, `release: {val, dtor: ?SymbolId}`.
  - Async (LLVM coroutine intrinsics): `await_: {result: ?Reg, fut}`, `spawn_: {result, callee, args}`.
  - Control: `label: Label`, `jmp: Label`, `condjmp: {cond, then, else_}`, `ret: ?Reg`.
- **`pub const Func = struct { sym, inst, ops: ArrayListUnmanaged(Op), reg_types: ArrayListUnmanaged(TypeId)
  }`** with a **`deinit`** that frees both lists.

Note LIR carries an explicit `dtor` on `release` (MIR's `release` does not; the destructor is resolved at
lowering / emit time), and its control ops are flat labels + jumps rather than a per-block terminator.

---

## `src/optimiser/pass.zig` (29 lines)

**Role in the pipeline.** The `Pass` interface and the bounded fixpoint runner. Every optimiser pass is a
`Pass`, and the driver sweeps the array to a fixpoint.

**Key types.** **`pub const Pass = struct { name: []const u8, run: *const fn (allocator, func: *mir.Func)
anyerror!bool }`** -- `run` returns true if it modified the function, so the pipeline can iterate the classic
fold -> DCE -> simplify cycle.

**Functions.**

- **`pub fn runToFixpoint(allocator, func, passes: []const Pass, max_iters) !usize`** -- sweeps all passes
  repeatedly; a sweep that makes no change stops the loop; `max_iters` is a runaway backstop. Returns the
  number of sweeps performed. A pass that errors propagates the error (the driver catches it).

---

## `src/optimiser/driver.zig` (244 lines)

**Role in the pipeline.** The middle-end entry point. It owns the pass pipeline array, the per-function
`optimise` routine, and the whole-program SHADOW (`lowerProgramShadow`) that `builder.zig` calls under
`NOVA_OPT`. The emit path calls `optimise` directly on its one function; it does not use `lowerProgramShadow`.

**Module-level state / constants.**

- **`pub const pipeline = [_]pass.Pass{ mem2reg, constfold, copyprop, dce, arc_elision, inline, simplifycfg }`**
  -- the passes in dependency order. `arc_elision` and `inline` are in the array but are no-ops on the current
  emit subset (arc_elision finds no cancellable pairs; inline's pipeline entry always returns false because
  there is no callee map at pass level).
- **`pub const enabled: bool = false`** -- a compile-time gate constant (the shadow is env-gated at the call
  site in `builder.zig`, so this stays false).
- **`pub const Coverage`** -- the shadow's metrics struct: `funcs, nodes, unsupported, mir_blocks, mir_insts,
  verify_errors, insts_removed, lir_ops, arc_ops, arc_removed, typed_values, total_values, calls_total,
  calls_resolved, calls_inlined`. These drive the `[opt]` summary lines.

**Functions.**

- **`pub fn optimise(allocator, func: *mir.Func) !usize`** -- runs the pipeline to a bounded fixpoint (16
  iters), then, in Debug builds ONLY, runs `verify.verify` and asserts zero violations. Returns the sweep
  count. This is what the emit path calls (it also independently re-verifies afterwards, since asserts are
  compiled out in release).
- **`pub fn lowerProgramShadow(allocator, program, ir: ?*const TypedIr, tab: ?*const SymbolTable, verbose)
  !Coverage`** -- the whole-program shadow. Two-pass by design:
  - Pass 1: lower EVERY function (free functions and struct methods) AST -> HIR -> MIR via `lowerToMir`,
    storing each MIR `Func` (kept alive so a call graph exists) alongside its own SymbolId.
  - Between passes: assign each func's `sym`, then build the inline candidate list -- single-block,
    `countInsts <= 16`, symbol-resolved functions become `inline_pass.Callee` entries.
  - Pass 2: for each func, inline small callees (measuring `calls_inlined`), run `optimise` (measuring
    `insts_removed` and `arc_removed`), then lower to LIR (measuring `lir_ops`). Never fatal: a failed inline
    or optimise is swallowed (`catch`), a failed LIR lowering `continue`s.
  - Prints the `[opt]` coverage summary, the type-threading + call-resolution percentages, the inline count,
    and (verbose) the unsupported-tag histogram.
  Owns and frees all the `mir.Func`s it accumulates and the histogram map.
- **`fn lowerToMir(allocator, fd, ir, own_sym, cov, hist, funcs, own_syms) !void`** (private) -- pass-1 worker.
  Skips extern functions (no body). Lowers AST -> HIR (counting nodes and `.unsupported` tags into the
  histogram), then HIR -> MIR (counting blocks, insts, typed values, and resolved-vs-unresolved call callees),
  verifies the MIR (counting violations), and appends the kept MIR + its SymbolId to the two lists.
- **`fn countCalls(mf) usize`**, **`fn countInsts(mf) usize`**, **`fn countArc(mf) usize`** (private) -- metric
  helpers (calls / all instructions / retain+release counts).
- **`pub fn run() void`** -- a reference-only stub that touches `lower_hir_mir.lowerFunc`,
  `lower_mir_lir.lowerFunc`, `hir.HirId.none`, `mir.Value.invalid`, `lir.Reg` so the exe build compiles the
  whole chain even before it emits. No behaviour.

---

## `src/optimiser/lower_ast_hir.zig` (565 lines)

**Role in the pipeline.** Builds HIR from a function's AST body, and (when a `TypedIr` is supplied) threads
ARC nodes with scope-accurate placement. It also does the source-level desugaring: C-style `for` -> `while`,
`switch` -> if-chain, string-method calls -> named calls, and it stamps every node with its sema TypeId. It is
the single most semantically dense file in the middle-end, because ownership placement lives here.

**The ARC placement contract (from the file header).** A `let` whose initialiser sema marks OWNED declares an
owned local in the current lexical scope; binding an owned local FROM another owned local (a copy) emits a
`retain`. Releases are placed as HIR nodes: at the end of the declaring block; before a `return` (all
enclosing owned locals except one moved out by `return x`); before a `break` / `continue` (the owned locals of
the scopes the jump exits). Placing the release BEFORE the exit node is what makes HIR->MIR lower it (a release
after a terminator would be dropped). This gives `arc_elision` balanced pairs to cancel.

**Key types.**

- **`const Scope = std.ArrayListUnmanaged([]const u8)`** -- one lexical scope's owned local names.
- **`const Ctx`** -- the walk state: `allocator, func: *hir.Func, ir: ?*const TypedIr, scopes: [Scope]` (the
  lexical stack), `owned: StringHashMap(TypeId)` (in-scope owned local name -> TypeId, so the emit path can
  gate ARC ops by type; `unset_ty` when sema could not type it), `loop_depths: [usize]` (scope-stack depth at
  each enclosing loop, so break / continue know which scopes to release), `tmp_ctr` (fresh-name counter).

**Functions, in source order.**

- **`fn hasEnclosingContinue(stmt) bool`** (private) -- true if `stmt` contains a `continue` targeting the
  ENCLOSING loop (recurses through blocks, if / else, and switch CASES, but stops at a nested `for`/`while`,
  which owns its own continues). Used by `lowerFor` to decide whether the naive while desugaring is safe.
- **`fn lowerFor(ctx, ids, fs: ast.ForStmt) !void`** (private) -- desugars a C-style `for (init; cond; incr)
  body` to `{ init; while (cond) { body; incr } }`. Falls to `.unsupported` (AST fallback) for the iterator
  form `for x in ...` OR when the body has an enclosing `continue` (a naive while would skip the increment on
  continue). Pushes a loop depth, lowers the body + increment into a fresh scope, pops scope releases,
  produces a `.loop_` node.
- **`fn isStringTid(tid) bool`** (private) -- true if `tid` is the `string` primitive in `mir.type_store`
  (null-store-safe). Used by the return-acquisition retain.
- **`fn isStructTid(tid) bool`** (private) -- true if `tid` is a `.struct_` (user struct / class OR a
  monomorphised generic like `List<int>`). Deliberately BROAD: the real emit decision is made downstream by
  `lir_emit.emittableHeapStructTid`, so an over-broad match here cannot miscompile (it just leaves an unused
  retain node when the function falls back).
- **`fn stringMethodName(ctx, fa: ast.FieldAccess) ?[]const u8`** (private) -- if the field access is a method
  on a STRING receiver, returns the mangled callee `string_<method>` (interned in `func`), else null. Requires
  `mir.type_store` and the `TypedIr`. If interning fails it frees the name and returns null. This is the C0
  string-method-naming that makes an otherwise-nameless field-access callee resolvable by the emit path.
- **`Ctx` methods:** **`deinit`**; **`ownedExpr(e) bool`** (`ir.ownedOf(e)`); **`pushScope`**;
  **`declareOwned(name, ty)`** (records the name in the top scope + the owned map); **`popScopeReleases(ids)`**
  (emits release nodes for the top scope's owned locals, then pops); **`releaseScopesDownTo(ids, from_depth,
  skip)`** (emits releases for scopes `[from_depth..top]` skipping one moved-out local, WITHOUT popping -- used
  by return / break / continue); **`appendRelease(ids, name)`** (loads the ident stamped with the owned local's
  TypeId, wraps it in a `.release`, appends).
- **`pub fn lowerFunc(allocator, fn_decl, ir) !hir.Func`** -- the shadow entry: delegates to `lowerFuncTyped`
  with null param types.
- **`pub fn lowerFuncTyped(allocator, fn_decl, ir, param_types: ?[]const TypeId) !hir.Func`** -- the emit-path
  entry. Binds each parameter to its name with a synthesised `let name = param(i)` at function entry (stamped
  with its resolved TypeId when `param_types` is supplied -- this MATTERS because mem2reg forwards the param
  store->load, making the param value itself an arithmetic operand whose width the emit gate must be able to
  prove). Lowers the body, prepends the param bindings, sets `func.entry`. Owns / frees the intermediate
  slices on the error path via `errdefer`.
- **`fn lowerBlock(ctx, block) !hir.Block`** (private) -- pushes a scope, lowers each statement, and stops early
  at a control exit (return / break / continue) since later statements are dead and the exit already emitted
  its scope releases. If terminated, pops the scope WITHOUT block-end releases (they were already emitted);
  else `popScopeReleases`. Dupes the id list into a stable slice.
- **`fn isExitStmt(stmt) bool`** (private) -- return / break / continue.
- **`fn lowerStmt(ctx, ids, stmt) !void`** (private) -- the statement dispatcher. Handles: `block`; `let_stmt`
  (lowers the initialiser, detects a copy of an owned local and emits the copy-retain, declares the owned local
  with its inherited / sema TypeId); `expr_stmt`; `return_stmt` (see below); `if_stmt`; `while_stmt` (records
  a loop depth); `break_stmt` / `continue_stmt` (release the exited scopes down to the loop depth, then emit
  the jump); `switch_stmt` -> `lowerSwitch`; `for_stmt` -> `lowerFor`; everything else -> `.unsupported`.
  - The `return_stmt` arm is the subtle one. It binds the return value to a synthesised `__retN` temp FIRST,
    so the return expression (which may READ a local that the scope releases would free) is evaluated BEFORE
    those releases; without this, `return s.len()` would release `s` before the call (a use-after-free). It
    detects a moved-out owned local (`return x` where `x` is owned) and skips its release. Then it threads the
    return-ACQUISITION retain (D4): for a returned BORROWED owned value that is neither moved nor a fresh owned
    temporary, if the type is a string OR a struct it stamps the temp and emits a `retain` (the caller gets a
    new owner). `lir_emit.emittableHeapStructTid` is the precise arbiter downstream.
- **`fn lowerStmtAsBlock(ctx, stmt) !hir.Block`** (private) -- lowers a single statement into its own scope
  (used for if / while branch bodies), handling the terminated-scope case like `lowerBlock`.
- **`fn lowerSwitch(ctx, ids, ss) !void`** (private) -- desugars a `switch` to an if-chain. Any GUARDED case
  (`case v if cond`) makes the whole switch `.unsupported` (the guard's fall-to-default semantics are not
  modelled). Binds the discriminant once to a `__swN` temp (it may have side effects), threading its TypeId
  onto every reference so the `disc == v` compares prove an integer kind. Builds the chain from the LAST case
  to the FIRST, nesting each into the running else-block; each case's condition is an OR (`bit_or`) of
  side-effect-free `disc == vK` eq compares (exact and needing no short-circuit), stamped with the discriminant
  type so the emit path's bit_or / branch gates accept the 0/1 results.
- **`fn lowerExpr(ctx, expr) !HirId`** (private) -- the expression dispatcher, returning the node id. Handles
  every AST expression kind: literals; `ident`; `binary` (assignment split out as `.assign`, else `.binop` via
  `mapBinOp`); `unary` (`.unop` via `mapUnOp`); `call` (with the string-method fast path -- a `field_access`
  callee on a string receiver becomes a NAMED `string_<method>(recv, args...)` call with the receiver as the
  first arg, matching the AST self convention); `field_access`; `index`; `block_expr`; `await_expr` /
  `go_expr` (spawn); `cast`; `if_expr`; `nullish_coalesce`; `optional_chaining`; `generic_call`; `struct_init`
  (capturing field names); `enum_init`; `tuple`; `template_expr`; `range`; `try_expr`; `closure` (opaque body
  `HirId.none`); everything else -> `.unsupported`. At the end it stamps `expr_id` and threads the concrete
  post-inference TypeId from `ir.typeOf2(eid)`, leaving the placeholder where sema could not type the expr.
- **`fn lowerExprSlice(ctx, exprs) ![]const HirId`** / **`fn lowerFieldSlice(ctx, fields) ![]const HirId`**
  (private) -- lower a list of expressions / object-field initialisers, returning a duped slice.
- **`fn zeroSpan() ast.Span`** (private) -- a zero span for synthesised nodes.
- **`fn mapBinOp(op: ast.BinaryOp) hir.BinOp`** / **`fn mapUnOp(op: ast.UnaryOp) hir.UnOp`** (private) -- the
  AST-to-HIR operator maps.

---

## `src/optimiser/lower_hir_mir.zig` (514 lines)

**Role in the pipeline.** Builds the MIR control-flow graph from the desugared HIR tree. Locals become memory
(alloc + load / store), value-producing conditionals (`if_expr`, `nullish`) lower through a result slot, and
terminators wire the blocks. It is total (handles every HIR kind, never crashes) so it runs over the whole
corpus. This is where the emit-path-specific ops (`tuple_new`, `template`, the unop-as-binop lowering, the
`global_const` opaque-name lowering) are produced.

**Key types / constants.** **`const placeholder_ty = mir.unset_ty`**. **`const Ctx`** -- `{ allocator, hf:
*const hir.Func, mf: *mir.Func, cur: Block, slots: StringHashMap(Value)` (local name -> alloc address),
`loop_header: ?Block, loop_exit: ?Block }`. **`pub const unresolved_callee: mir.SymbolId =
@enumFromInt(0xFFFF_FFFF)`** -- marks a call whose callee sema could not name.

**Functions.**

- **`pub fn lowerFunc(allocator, func: hir.Func) !mir.Func`** -- creates the entry block, walks `func.entry`,
  and adds an implicit `ret void` if the last block is un-terminated. Scope-end releases are already HIR nodes,
  so nothing ARC is added here.
- **`fn lowerBlock(ctx, block) !void`** (private) -- lowers each node; stops at the first node that terminates
  the current block (anything after is dead in this structured form).
- **`fn mirTerminated(ctx) bool`** (private) -- the current block's terminator is not `.unreachable_`.
- **`fn lowerNode(ctx, id) !Value`** (private) -- the big per-node lowering. Returns a Value for value-producing
  nodes, `.invalid` for statements. Uses the node's threaded TypeId where sema resolved it, else the
  placeholder. The notable arms:
  - Literals: `int` / `bool` -> `const_int`; `param` -> `param`; `str` -> `const_str`; `float` -> `const_int`
    carrying `@bitCast(fv)` (the double's bits) with a float type; `null` / `undefined` -> `const_int 0` (exact
    for a reference optional, WRONG for a value optional -- the emit gates keep value optionals out).
  - `ident`: a local slot -> `load`; otherwise (module const / bare function ref / capture) -> the OPAQUE
    `global_const` carrying the name. Lowering it to `const_int 0` instead miscompiled every `& MASK32`.
  - `binop`: lowers both operands, then RECOVERS an unresolved same-type result via `inferSameTypeResult`
    (needed because tuple-element access leaves its result type unthreaded), then emits `binop`.
  - `unop`: NOT a cast-through (that silently dropped the operator -- the real INT_MIN bug). Each unop lowers to
    its exact binop identity: `neg` -> `0 - x` (sub), `bit_not` -> `x ^ -1`, `not` -> `x == 0`. constfold then
    folds the constant forms.
  - `cast` -> `cast`.
  - `call` / `generic_call` -> `lowerCall`.
  - `field` -> `field_get`.
  - `optional_chain`: `a?.b` lowered as a reference-optional present-check branch (`a != 0 ? a.b : 0`) through
    a result slot. Correct only when the whole result is a reference optional; the emit gates reject a
    value-optional-typed result and non-scalar fields, so it is safe (fallback) for the rest.
  - `index`: lowers to `index_get`, and RECOVERS a tuple element's type. A tuple `t.k` desugars (in the parser)
    to `t[k]` and arrives unresolved; it recovers the element TypeId from the tuple type + the CONSTANT index,
    and types it as the raw 64-bit WORD (via `wordTid`), NOT its declared 32-bit `int` -- because the AST reads
    a tuple element as an i64 word with no width canonicalisation, so typing it `int` would make the emit
    binop wrap at 32 bits and diverge on overflow.
  - `struct_init` -> `struct_new` (lowering each field arg).
  - `enum_init` -> `lowerAggregate`.
  - `tuple` -> `tuple_new` (lowering each element; `lowerAggregate` would drop them).
  - `template`: under `emit_mode` -> a real `template` op; else `lowerAggregate` (the shadow keeps its
    structural placeholder so op counts are unchanged).
  - `range` -> lowers both ends for side effects, yields `const_int 0`. `closure` -> `const_int 0`.
  - `await_` -> `await_`; `spawn_` -> a structural `spawn_` (callee 0, no args); `try_` -> passes through.
  - `retain` -> emits a void `retain`, returns the operand value; `release` -> emits a void `release`, returns
    `.invalid`.
  - `let` -> an `alloc` slot recorded in `ctx.slots`, then a `store` of the initialiser.
  - `assign` -> a `store` into the target's slot (ident), a `field_set` for `obj.field = v` (NOT a `field_get`,
    which would read instead of taking the address), else a `store` into a computed address.
  - `ret` -> sets the block terminator. `brk` / `cont` -> `br` to `loop_exit` / `loop_header`.
  - `block` -> recurse. `if_` -> `lowerIf`. `if_expr` -> a result slot + `lowerIfExpr` + a final load.
  - `nullish`: `a ?? b` as a present-check branch on the word (`a != 0 ? a : b`) through a result slot, with
    `b` evaluated only on the absent path (matching the AST short-circuit). Safe for value optionals because
    the present-check compare is a reference-word eq that the emit `isRefWordEq` gate only admits for a
    reference word.
  - `loop_` -> `lowerLoop`. `unsupported` -> `const_int 0`.
- **`fn lowerCall(ctx, callee, call_args, sym, result_ty) !Value`** (private) -- a `field`-access callee (a
  non-string method, since string methods were already renamed) lowers to an `indirect_call` carrying the
  receiver + method name (the backend resolves the vtable slot only for a genuine trait object; a static struct
  method is rejected downstream and falls back). A bare-ident callee keeps its source name so the emit path can
  resolve it without a symbol table; anything else stays nameless. `takes_ownership` is initialised all-false.
  The target SymbolId is `sym` when known, else `unresolved_callee`.
- **`fn wordTid(st) ?mir.TypeId`** (private) -- finds the interned 64-bit signed int (`long`) TypeId by
  scanning the store (the store is const here, so it cannot intern). Used to word-type tuple elements.
- **`fn tyUnresolved(st, tid) bool`** (private) -- out of range, `unset`, or a store `.unresolved`.
- **`fn inferSameTypeResult(ctx, op, nty, lhs) mir.TypeId`** (private) -- for a same-type-result binop
  (arithmetic / bitwise / shift, NOT comparison), recovers an unresolved result type from the lhs operand's
  resolved type. Returns `nty` unchanged when already resolved or unrecoverable, so nothing sema typed is
  disturbed.
- **`fn lowerAggregate(ctx, fields) !Value`** (private) -- lowers each field for side effects, yields a
  placeholder `alloc` (the structural stand-in for enum_init / shadow templates).
- **`fn lowerIf(ctx, cond_id, then_b, else_b, merge_opt) !void`** (private) -- the standard condbr -> then / else
  / merge lowering, wiring un-terminated arms to the merge with a `br`.
- **`fn lowerIfExpr(ctx, cond_id, then_v, else_v, slot) !void`** (private) -- the value-producing form; each arm
  is a single value node that stores into `slot`.
- **`fn lowerLoop(ctx, cond_id, body) !void`** (private) -- header / body / exit blocks; a null cond is an
  infinite loop (`br` to body). Saves / restores `loop_header` + `loop_exit` around the body so nested loops
  nest correctly.
- **`fn mapBin(op: hir.BinOp) mir.BinOp`** (private) -- maps HIR binops to MIR; logical `and` / `or` map onto
  `bit_and` / `bit_or` (short-circuit was already desugared), and `assign` maps to `.add` as a dead default
  (assign is handled before `mapBin` is ever reached).

---

## `src/optimiser/lower_mir_lir.zig` (97 lines)

**Role in the pipeline.** Linearises optimised MIR into the LIR op stream, one label per block followed by its
instructions and its terminator as explicit jumps. MIR Values map 1:1 to LIR Regs (the memory-based lowering
produces no block-argument phis, so there is nothing to resolve beyond the block->label map). On the emit path
this is unused (the emitter drives LLVM from MIR); it exists for the shadow's `lir_ops` metric, so several arms
are deliberately structural stand-ins.

**Functions.**

- **`fn reg(v) lir.Reg`** / **`fn label(b) lir.Label`** (private) -- the identity index re-tags.
- **`pub fn lowerFunc(allocator, func: mir.Func) !lir.Func`** -- copies `value_types` into `reg_types` 1:1,
  then for each block appends a `label`, lowers each instruction, and lowers the terminator.
- **`fn lowerInst(allocator, lf, inst) !void`** (private) -- the per-op lowering. Faithful for the scalar /
  memory / call / ARC ops. Structural stand-ins (for the shadow op count only, since the emit path never uses
  LIR): `global_const` and `const_str` -> `const_int 0`; `struct_new` / `tuple_new` / `template` -> `alloc`;
  `field_get` / `index_get` -> a `load` off the base / object register; `field_set` -> a `store`. `release`
  lowers with a null `dtor` (the shadow does not resolve destructors). This is an EXHAUSTIVE SWITCH; a new MIR
  op must be added here.
- **`fn lowerTerm(allocator, lf, term) !void`** (private) -- `br` -> `jmp`, `condbr` -> `condjmp`, `ret` ->
  `ret`, `switch_` -> a `jmp` to default (structural; the emitter would build a condjmp chain), `unreachable_`
  -> `ret null`.
- **`fn regs(allocator, vals) ![]const lir.Reg`** (private) -- maps a Value slice to a fresh Reg slice.
- **`fn mapBin(op: mir.BinOp) lir.BinOp`** (private) -- the MIR-to-LIR binop map.

---

## `src/optimiser/verify.zig` (97 lines)

**Role in the pipeline.** The MIR verifier (M2). Runs after lowering and after every pass (in the driver's
debug assert, and again unconditionally on the emit path). It catches the invariant breaks that would
otherwise reach LLVM as a mysterious miscompile. The ARC-balance check is declared but dormant (no ARC-balance
computation yet).

**Key types.** **`pub const Error = struct { kind: Kind, block: u32, detail: []const u8 }`** with **`Kind`**:
`not_terminated`, `bad_block_target`, `use_out_of_range`, `result_out_of_range`, `use_before_def`,
`arc_imbalance` (dormant).

**Functions.**

- **`pub fn verify(allocator, func: *const mir.Func) ![]Error`** -- returns an owned error slice (the CALLER
  frees it). It:
  1. Computes each value's program-order definition position (block-major, then instruction index) into
     `def_pos`, `undefined_pos` for never-defined. The emit path's MIR flows values forward only (cross-block
     values live in memory via alloc / load / store, no back-edge SSA), so a valid def always precedes its use
     in this order. This is the `use_before_def` check, and it is exactly what would have caught the M6-C
     dangling load (a load promoted away while a use survived).
  2. Flags any operand used at a position `>=` its definition position as `use_before_def`.
  3. Per block: flags out-of-range operands (`use_out_of_range`) and results (`result_out_of_range`); flags an
     un-terminated block (`.unreachable_` -> `not_terminated`); validates every terminator's block targets
     (`bad_block_target`) including switch cases; and flags out-of-range terminator operands.

---

## `src/optimiser/passes/constfold.zig` (81 lines)

**Role.** Folds a binop whose operands are both `const_int` into a single `const_int`, in place, and records
the mapping so downstream uses see the constant. dce then removes the now-dead feeders.

**Functions.**

- **`fn run(allocator, func) !bool`** (the `pass.run`) -- allocates a `konst` map (Value -> known constant),
  then does a single forward sweep. On a `const_int` it records the value; on a `binop` with both operands
  known AND not a float (checked on the result type AND both operand types via `mir.isFloatTy`), it folds via
  `fold`, then WRAPS the result to the result type's width via `mir.wrapToWidth` (width-honesty: Nova's `int`
  is 32-bit; folding at i64 would miscompile a chained overflow like `(2e9 + 2e9) >> 20`). If the width is
  unknown (no store / not an int prim, e.g. a bool compare result) it leaves the raw fold (already 0/1).
  Rewrites the instruction op to `const_int`.
  - **Safety condition:** never fold a float binop (the const_int holds the double's bit pattern; integer
    folding would add bit patterns). Division / modulo by zero is left unfolded so the runtime trap semantics
    are unchanged.
- **`fn fold(op, l, r) ?i64`** (private) -- the i64 fold table: `+%` / `-%` / `*%` (wrapping), `@divTrunc` /
  `@rem` (null on zero divisor), the six comparisons (0/1), the three bitwise ops, and shl / shr (null when the
  shift is negative or `>= 64`).

---

## `src/optimiser/passes/copyprop.zig` (81 lines)

**Role.** Copy propagation + algebraic identity simplification. Forwards a value through an op that provably
produces it unchanged, so the identity op becomes dead (dce removes it). Runs after constfold, so one operand
is often a known constant.

**Functions.**

- **`fn run(allocator, func) !bool`** -- collects the `const_int` map, then for each `binop`: if the RIGHT
  operand is an identity constant (`isRightIdentity`), `replaceUses(result, lhs)`; if `x * 0`, forward to the
  zero operand; symmetrically for the LEFT operand but only for COMMUTATIVE ops (`isCommutative`).
  - **Safety condition:** only identities that provably do not change the result. `x - 0 -> x` is a right
    identity but subtraction is not commutative, so `0 - x` is correctly NOT simplified.
- **`fn isRightIdentity(op, c) bool`** (private) -- `add/sub/bit_or/bit_xor/shl/shr` with `c == 0`; `mul/div`
  with `c == 1`.
- **`fn isCommutative(op) bool`** (private) -- `add, mul, bit_or, bit_xor, bit_and, eq, ne`.

---

## `src/optimiser/passes/dce.zig` (50 lines)

**Role.** Dead-code elimination. Removes instructions whose result is never used AND which have no side effect.
Value ids are never renumbered, so a removed instruction simply leaves its result unused; no fix-up needed.

**Functions.**

- **`fn run(allocator, func) !bool`** -- marks every used Value (across all instruction operands via
  `instOperands` and all terminator operands via `termOperands`), then compacts each block's instruction list,
  dropping any instruction whose result is defined, unused, and `!hasSideEffects`.
  - **Safety condition:** `hasSideEffects` is the guard. A `retain` whose only use was elided by arc_elision
    becomes dead here, which is the intended interaction.

---

## `src/optimiser/passes/mem2reg.zig` (136 lines)

**Role.** Promote memory slots to SSA values by intra-block load-forwarding, plus a full promotion of
non-escaping single-block slots. The enabler for the other passes (without it most values are opaque
loads / stores).

**Functions.**

- **`fn run(allocator, func) !bool`** -- four phases:
  1. **Escape + slot analysis.** Mark each `alloc` result as a slot; mark a slot ESCAPED if its address appears
     anywhere other than as a `load.addr` / `store.addr` (crucially, a slot address used as a stored VALUE
     escapes). An escaped slot is never forwarded.
  2. **Single-block detection.** Record `block_of[slot]` = the one block it is used in, or a `many` sentinel.
  3. **Intra-block load-forwarding.** Sweep each block tracking `last[slot]` = the most recently stored value.
     A `load` of a non-escaped slot with a known `last` is forwarded (`replaceUses`). A load with no prior
     store this block marks the slot `live_load` (the load INSTRUCTION survives). An opaque `call` /
     `indirect_call` conservatively forgets all `last` values (an aliased pointer could have written).
  4. **Full promotion.** Drop the alloc + stores of a non-escaping, single-block slot with NO surviving load.
  - **Safety condition + the M6-C bug it fixed.** The `live_load` tracking is the fix for the crash the emit
    path surfaced: full promotion USED to remove a single-block slot's alloc + store even when an opaque call
    between store and load blocked that load's forwarding, leaving a load of freed memory. A slot with a
    surviving load is now left entirely intact. Stores and allocs are otherwise left in place (a later
    cross-block promotion would remove them); nothing removed here changes behaviour.

---

## `src/optimiser/passes/simplifycfg.zig` (133 lines)

**Role.** Control-flow graph simplification: fold constant / duplicate-target branches, and remove unreachable
blocks with a proper renumber (terminators reference blocks by index).

**Functions.**

- **`fn run(allocator, func) !bool`** -- collects the `const_int` map, then:
  1. **condbr simplification.** A condbr whose two targets are the same block -> `br`. A condbr with a constant
     condition -> `br` to the taken side.
  2. **Dead-block elimination.** SKIPPED entirely if any `switch_` is present (its cases are an immutable slice
     that cannot be remapped in place; the lowering never emits `switch_`, so this stays sound). Otherwise:
     mark reachable-from-entry via a DFS over `successors`, and if any block is unreachable, build an old->new
     remap, compact the block list in place (freeing dropped blocks' inst storage), fix `func.entry`, and
     rewrite every terminator's block references through the remap.
  - **Safety condition:** run last as a clean-up and interleaved as other passes create dead edges; the
    switch_ guard and the const-condition check are the two correctness gates.
- **`fn successors(term) [3]mir.Block`** (private) -- the up-to-two successors padded to a fixed array (a
  maxInt sentinel for `ret` / `unreachable_`).
- **`fn remapTerm(term, remap) void`** (private) -- rewrites a terminator's block indices through the remap.

---

## `src/optimiser/passes/arc_elision.zig` (208 lines)

**Role.** The headline pass: cancel balanced `retain` / `release` pairs. Conservative by construction -- any
uncertainty keeps the pair (a wrongly-removed retain is a use-after-free ASAN catches; a kept redundant one is
merely slow). On the current emit subset it is a proven no-op (a retained string is always subsequently used;
a return-acquisition retain's matching release lives in the CALLER), but it is wired, active, and cannot
imbalance ARC.

**Functions.**

- **`fn run(allocator, func) !bool`** -- delegates to `cancelOverTraces`.
- **`const Pos = struct { b: usize, i: usize }`** -- a (block, instruction) position.
- **`fn cancelOverTraces(allocator, func) !bool`** (private) -- cross-block cancellation over straight-line
  TRACES. A trace is a maximal chain `b0 -> b1 -> ...` where each block ends in an unconditional `br` to the
  next and the next block has exactly ONE predecessor (no branching or merge between them). Concatenating a
  trace's instructions and applying within-block matching is sound because with no branch on the path, a
  retain / release pair with no interleaved observer is balanced. Branching regions fall back to per-block
  cancellation (each block is its own length-1 trace).
- **`fn predCounts(allocator, func) ![]u32`** (private) -- predecessor counts per block (via `bump`), used to
  find single-predecessor successors.
- **`fn bump(preds, b) void`** (private) -- increments a block's predecessor count, bounds-checked.
- **`fn cancelInTrace(allocator, func, blocks) !bool`** (private) -- flattens the trace's instructions into a
  position list, then for each `retain v` scans forward for a matching `release v`, marking both dead -- UNLESS
  an intervening `observesRef` is hit first (the pair stays). Then compacts each block, dropping the dead
  positions.
  - **Safety condition:** the scan stops at the first `observesRef(other, v)`, so a pair straddling any use of
    the extra reference is never cancelled.
- **`fn observesRef(op, v) bool`** (private) -- true if `op` could rely on the extra reference to `v`: a `store`
  of v, another `retain` / `release` of v, a `call` / `spawn_` passing v, or an `indirect_call` receiving /
  passing v. EXHAUSTIVE-ish switch with an `else => false`; a new op that captures a value must be added.
- **`fn containsV(args, v) bool`** (private) -- membership test.
- Two unit tests: cancels an adjacent retain / release of the same value; keeps a pair straddling a `store` of
  the value (the escape case).

---

## `src/optimiser/passes/inline.zig` (180 lines)

**Role.** Bounded inlining of small single-block callees: splice the callee's instructions into the caller
(fresh caller Values, operands remapped), then replace the call's result with the callee's returned value.
DORMANT on real code via the pipeline (there is no MIR call graph at pass level); activation is driver-level
(`lowerProgramShadow` builds the callee map and calls `inlineSmallCallees` directly). Implemented + unit-tested
so it is ready.

**Functions.**

- **`fn run(allocator, func) !bool`** (the `pass.run`) -- a no-op (returns false): no callee graph at pass
  level.
- **`pub const Callee = struct { sym: mir.SymbolId, func: *const mir.Func }`**.
- **`pub fn inlineSmallCallees(allocator, caller, callees, max_insts) !bool`** -- for each `call` whose callee
  is found in `callees`, is not the caller itself, is single-block, and is within `max_insts`, splice it in and
  drop the call. Rebuilds each block's instruction list (so spliced instructions are never re-examined  -- 
  single-level inlining per invocation; nested inlining comes from re-running).
- **`fn findCallee(callees, sym) ?*const mir.Func`** (private) -- linear lookup by SymbolId.
- **`fn spliceInto(allocator, caller, out, call_result, callee) !void`** (private) -- allocates a fresh caller
  Value for each callee Value (`vmap`), copies each callee instruction with its result and operands remapped,
  and replaces uses of the call result with the callee's returned value. It DUPLICATES any args slice before
  remapping (`call` / `indirect_call` / `spawn_`), because `ni = cinst` shares the callee's const slice and
  `remapOp` mutates operands in place -- without the copy it would corrupt the callee body. This is a real
  footgun the comment calls out.
- **`fn remapOp(op, vmap) void`** (private) -- rewrites every operand of a spliced instruction through `vmap`.
  EXHAUSTIVE SWITCH, must mirror `instOperands` / `rewriteInst`; a new op with operands must be added or
  inlining silently leaves a callee-space Value in the caller.
- One unit test: inlines a single-block callee returning a constant and asserts the call is gone and the
  const spliced in.

---

## `src/backend/codegen/lir_emit.zig` (1494 lines)

**Role in the pipeline.** The LIR->LLVM emitter, i.e. the emit half (M6). For a candidate function it lowers
AST -> HIR -> MIR, runs the optimiser, and emits LLVM DIRECTLY from the optimised MIR, so the ARC-elision /
fold / inline actually reach the binary. It is gated behind `NOVA_OPT_EMIT` (separate from the `NOVA_OPT`
shadow) and is a strict per-function FALLBACK: `tryEmit` returns false for anything outside the emittable
subset and codegen emits that function from the AST. Nothing regresses; only provably-correct functions take
the new path. This one file holds the entire admission policy (the gates) and the entire emission (the LLVM
per op).

**Module-level state / constants.**

- **`pub var emit_enabled: bool = false`** -- set from `NOVA_OPT_EMIT` in `builder.zig` (and, since the
  vacuous-gate fix, `tester.zig`). Off by default, so default builds are byte-identical.
- **`pub var emit_verbose: bool = false`** -- set from `NOVA_OPT_EMIT_VERBOSE`; logs each function taken (and
  each reject reason) for proof-of-fire.
- **`const Callee = struct { fn_val, fn_type }`**, **`const IntKind = struct { width: u32, signed: bool,
  is_bool: bool }`**, **`const IndexKind = enum { string, array_word }`**, **`const StructDropKind = enum {
  heap, value }`** -- small local helper types described at their use sites below.

### The entry + the three gate layers

- **`pub fn tryEmit(compiler, fn_val, func: anytype) bool`** -- the public entry codegen calls per function.
  Wraps `tryEmitInner` in `catch false` (any error -> fall back).
- **`fn reject(comptime why) bool`** (private) -- logs (verbose) and returns false. Every gate returns
  `reject("...")`.
- **`fn tryEmitInner(compiler, fn_val, func) !bool`** (private) -- the orchestrator. In order:
  1. Reject `func.is_async` up front (an async fn is an LLVM coroutine; emitting a plain body and skipping the
     coro prologue makes a malformed coroutine that CoroSplit turns into a crash, even for a trivial body).
  2. **Parameter gate.** `func.params.len != func.param_count` -> reject (a method's implicit `self` shifts the
     LLVM arg indices, and `params` is populated only for free functions). Cap 32. For each param: reject an
     `optional` type-ref unless it is a REFERENCE optional (`isRefOptionalTypeRef`); reject an `error_union`
     type-ref; resolve the param TypeId (for a reference optional, thread the INNER reference tid, not the
     stripped optional tid, which would land in a different slot); then admit it only if it is a signed
     int / bool scalar, an emittable heap struct, a string, a non-float array word, an f32 / f64 word, a
     read-only value-struct param, a reference optional, or a trait param. Anything else -> reject.
  3. **Return gate.** Reject an `optional` return unless reference-optional; reject an `error_union` return
     (the tagged 16-byte heap box with a nested value-optional ok arm is not modelled -- see B7). `void` is
     fine; otherwise admit a signed int / bool scalar, an emittable heap struct (the fresh-construction case,
     further restricted in `mirEmittable`'s `.ret`), an f32 / f64 word, a string, or a reference optional.
  4. Build a synthetic `ast.FunctionDecl`, set `mir.type_store`, lower AST -> HIR via `lowerFuncTyped`
     (threading the resolved param types).
  5. `rewriteEnumValueNodes` (fold payloadless enum values to their int discriminant BEFORE the HIR gate).
  6. `hirEmittable(&hfunc)` -> reject on any non-emittable HIR node kind.
  7. Set `mir.type_store` again + `mir.emit_mode = true` (with a `defer` reset), lower HIR -> MIR, run
     `opt_driver.optimise`.
  8. `verify.verify` the MIR -> reject on any violation (A3, defence in depth).
  9. `mirEmittable(&mfunc)` -> reject if any instruction / terminator is outside the subset. This is the dry
     validation; NO IR is built yet.
  10. `emitFunc` -- walk the MIR and build the LLVM body.

### The gate helpers (admission policy)

- **`fn hirEmittable(hf) bool`** (private) -- the whole-function HIR node-kind ALLOWLIST. Admits: `int, bool,
  param, ident, binop, unop, let, assign, ret, block, if_, loop_, if_expr, brk, cont, nullish, call,
  generic_call, struct_init, field, tuple, retain, release, index, cast, str, template, float`. Everything else
  falls back. **`undefined` / `null` are DELIBERATELY NOT admitted** -- they lower to `const_int 0`, exact for a
  reference optional but WRONG for a value optional (which boxes them to a non-zero sentinel), and the
  whole-function HIR gate cannot tell the two apart per node. Admitting `.undefined` was verified to miscompile
  `f(undefined)` for a value-optional param. Runs on HIR (not MIR) because MIR collapses str / float / null to
  `const_int 0`, losing the kind.
- **`fn payloadlessEnumDeclForTid(compiler, tid) ?*const ast.EnumDecl`** (private) -- the AST EnumDecl a TypeId
  names, but ONLY if the enum is PAYLOADLESS (no variant has a `type_name` or `fields`). A payloadless enum
  value is a plain integer discriminant word, so the emit path treats it as a signed 64-bit int. A tagged enum
  is a heap box with a different ABI -> null. Resolves via the live sema symbol table (`sema_shadow.live_sema`).
- **`fn hirBindsLocal(hf, name) bool`** (private) -- true if the HIR binds a local / param called `name` (params
  are `let name = param(i)`). Distinguishes a real field read on a same-named variable from a payloadless
  enum-value access `Color.Red`.
- **`fn rewriteEnumValueNodes(compiler, hf) void`** (private) -- rewrites a payloadless enum VALUE (`Color.Red`,
  a `.field` on a type-name ident) into an `.int` discriminant constant, exactly what the AST materialises
  (`LLVMConstInt(val_type, v.value orelse idx)`). Skips a same-named local (a real field read) and tagged enums
  (heap box, different ABI). The node KEEPS its enum TypeId, so `disc == Color.Red` still compares as a plain
  i64, byte-identical to the AST. The orphaned type-name ident node is never emitted (only block-reachable
  nodes are lowered).
- **`fn intKindForTid(compiler, tid) ?IntKind`** (private) -- an integer primitive's machine kind, or null for
  "not a signed integer or bool primitive". Returns null on `unset_ty`. A payloadless enum is classified as a
  signed 64-bit int. Otherwise resolves via `compiler.symbolName` + `types_mod.cgPrim`; maps `i1` -> bool,
  `i8/i16/i32/i64/word` -> the width + signedness, `f32/f64` -> null. Unsigned integers are deliberately
  excluded (they need unsigned canonicalisation the AST applies conditionally). Note `symbolName`'s result is a
  transient compile-time string NOT owned by the caller, so it is NOT freed (a real bug was a double-free here).
- **`fn isF64Tid` / `fn isF32Tid` / `fn isFloatWordTid`** (private) -- float classification. `isF64Tid` is a
  clean 8-byte double. `isF32Tid`: in THIS backend an f32 is PROMOTED to double everywhere in scalar code -- its
  slot is `double`, its word carries the DOUBLE's 64-bit pattern (`castToValType` FPExts f32->double then
  bitcasts), and the binop path bitcasts the word straight to `DoubleType`. So an f32 value is bit-for-bit a
  double in the word, and the emit path uses the SAME DoubleType bitcast as f64; using `LLVMFloatType` (32-bit)
  would reinterpret garbage. `isFloatWordTid` = f32 OR f64 (both take the DoubleType path). f32 struct FIELDS
  and f32 ARRAYS keep real 32-bit storage and still fall back.
- **`fn resolveCallee(compiler, name, nargs) ?Callee`** (private) -- resolves a direct call by source name to an
  LLVM function, but ONLY if its signature is ALL-WORD: `nargs` word (i64) params and a word or void return.
  Nova passes every non-array param as the i64 word, so such a call needs no coercion. Anything else (array=ptr
  params, wider / narrower ABI, varargs, arg-count mismatch) -> null (fall back).
- **`fn isStringTid` / `fn isArrayWordTid` / `fn isScalarTupleTid`** (private) -- type classifiers. `isStringTid`
  = the `string` primitive (an ARC heap pointer whose release needs no destructor, so the one owned type
  D1 / D2 emits). `isArrayWordTid` = a non-float array (flows as a clean `ptr`, round-trips the i64 slot).
  `isScalarTupleTid` = a tuple whose EVERY element is a scalar int / bool (no owned / float element to retain or
  bit-read).
- **`fn indexKind(compiler, otid) ?IndexKind`** (private) -- how to emit `object[idx]`: `.string` (byte index),
  `.array_word` (i64-word element GEP, including a scalar tuple, which indexes like a word array); null for
  float-element arrays (need a float load type) and lists / maps (method-call access).
- **`fn storeAddrIsAlloc(mf, addr) bool`** (private) -- true if `addr` is defined by an `alloc` (a real stack
  slot). Any other store target -- e.g. the `index_get` result an unmodelled `a[i] = v` lvalue lowers to -- is
  not a pointer, and emitting `store i64 %v, i64 %addr` fails LLVM verification, so those functions fall back.
- **`fn structBaseNameOf(compiler, mf, v) ?[]const u8`** (private) -- the declared base name of the struct /
  class a value holds (via its TypeId), or null. Resolves field layout for field_get / field_set.
- **`fn fieldTypeRef(compiler, struct_name, field_name) ?ast.TypeRef`** (private) -- the declared TypeRef of a
  named field.
- **`fn isScalarFieldTypeRef(tr) bool`** (private) -- a field this slice can store at its real width: a bare
  int / bool primitive (not f32 / f64). Floats, strings, nested structs, optionals, arrays need the float-store
  path or ARC and stay on the AST.
- **`fn emittableValueStructParamTid` / `fn emittableHeapStructTid` / `fn emittableTraitParamTid`** (private)  -- 
  struct / trait param classifiers. A value-struct param is admitted READ-ONLY (all-scalar fields; it flows as
  the address of its inline bytes; construction / mutation / copy / return of a value struct need the by-value
  ABI and stay on the AST). A heap struct is a known struct that is NOT a value struct. A trait param is a
  known trait (a borrowed fat-pointer word; no ARC threaded, matching the AST borrow contract).
- **`fn traitDispatchSlot(compiler, mf, x) ?u32`** (private) -- resolves a MIR `indirect_call` to a concrete
  trait vtable slot. The receiver's TypeId must name a known trait and the method name must be one of its
  methods; returns the method's index in the trait decl (the emitter adds 1 because slot 0 is the destructor).
  Rejects an ASYNC trait method (a coroutine, not modelled).
- **`fn valueIsParam(mf, v) bool`** (private) -- true if `v` is defined by a `.param`.
- **`fn receiverIsParamBacked(mf, v) bool`** (private) -- true if a trait dispatch receiver is a caller-built
  fat pointer: a param directly, OR a load from a slot stored ONLY param values (a repeated `sh.method()` that
  mem2reg left as a load). EXCLUDES a trait LOCAL that could hold a struct implicitly WIDENED to the trait (a
  conversion the emit path does not model). A trait object passed in as a param is always well-formed, so
  dispatching on it is safe.
- **`fn calleeHasTraitParam(compiler, name, nargs) bool`** (private) -- true if the callee declares a
  trait-typed parameter among its first `nargs`. Passing an arg to a trait param may need implicit
  struct->trait WIDENING at the call site (the AST builds the fat pointer via `constructTraitObject`); the emit
  path passes raw words with no coercion, so it cannot widen -> fall back. Also closes a pre-existing miscompile
  (a function that constructed a trait object and passed it to a trait-param free function emitted the raw
  struct pointer, crashing the callee's first vtable load).
- **`fn isStringFieldTypeRef(tr) bool`** (private) -- the bare `string` type-ref: the one OWNED field the emit
  path can construct + release (via the struct's real `__destruct_<Struct>`, which releases each string field
  with a null dtor).
- **`fn stringFieldStructDropKind(compiler, tid) ?StructDropKind`** (private, D3) -- classifies a struct whose
  owned fields are ALL bare strings (every field scalar or `string`). Returns `.heap` (a class / escaping
  struct: `nova_release(ptr, __destruct_*)`) or `.value` (a value struct: `dropValueStruct` calls
  `__destruct_*` directly on the inline storage, no free), or null (any other owned field kind -> fall back).
  KEY finding: a plain `struct` is a VALUE struct in this build, so a string-field struct is usually dropped
  via `dropValueStruct`, not `nova_release`.
- **`fn isConstStrResult(mf, v) bool`** (private) -- true if `v` is a `const_str` (an immortal interned
  literal). A literal moved into a struct's string field needs NO retain, so construction with const_str string
  fields is admitted; a non-literal (named) string field would need a retain and falls back.
- **`fn isRefWordTid(compiler, tid) bool`** (private) -- true if `tid` is a REFERENCE (pointer) word: a string,
  a reference optional, a heap struct, or the raw `word`-repr `ptr` prim (which a reference-optional
  param / local is often typed as). An eq / ne between two such words -- or one and the null word -- is a plain
  `icmp eq/ne i64`.
- **`fn isRefOptionalTypeRef(compiler, tr) bool`** (private) -- an OPTIONAL type-ref whose present arm is a
  reference type (string or heap / class struct), so it strips to a nullable pointer word. A value optional
  returns false (must stay on the AST).
- **`fn isRefWordEq(compiler, mf, x) bool`** (private) -- true if the two operands of an eq / ne are a
  reference-word comparison (at least one side a reference word, the other a reference word OR an integer, the
  null literal being `const_int 0`). Pure int / bool eq / ne does NOT match here (handled by the signed-word
  arm).
- **`fn refOptionalInner(compiler, tid) ?mir.TypeId`** (private) -- if `tid` is a store `.optional` whose inner
  is a REFERENCE type (string or non-value struct / class), returns that inner tid, else null. Store-
  authoritative: it sees the `.optional` even when the rendered NAME drops the `| undefined` (e.g. `string |
  undefined` renders as `string`), which is exactly why B6's string-optional params were not emitting. A value
  optional returns null.
- **`fn isValueOptionalTid(compiler, tid) bool`** (private) -- true if `tid` is a store `.optional` that is NOT
  a reference optional, i.e. a BOXED value optional. The AST boxes it (`nova_valopt_box`) so a present 0 is
  distinguishable from absent; the emit path has no boxing and would flow the raw word (a miscompile). Gating
  on the TYPE here catches a value optional arriving via a typed local or a call result, which the whole-
  function HIR `.undefined` guard misses.
- **`fn emittableRefOptionalTid(compiler, tid) bool`** (private) -- the store-authoritative-first reference-
  optional test (a `.optional` with a reference inner), falling through to a name heuristic (`<arm> |
  undefined`, present arm a string or non-value struct) for the cases the store cannot see. Rejects a boxed
  value optional (`valueOptionalName`) and multi-arm unions.
- **`fn isStringRefOptionalTid(compiler, tid) bool`** (private) -- `string | undefined` SPECIFICALLY: its ARC
  contract is a plain string's (single allocation, null destructor, releasing the null word is a no-op), so
  retain / release on it emit exactly like a bare string. A class-payload optional needs the struct destructor
  and is excluded.
- **`fn tidIsValueOptional(compiler, tid) bool`** (private) -- the name-based value-optional test
  (`types_mod.valueOptionalName`), used inside `mirInstEmittable` to reject a value optional materialised or
  bound inside an otherwise-scalar function.
- **`fn callTargetsValueOptionalParam(compiler, name, nargs) bool`** (private) -- true if a direct call delivers
  ANY argument into a value-optional PARAMETER. The AST boxes such an arg at the call site
  (`buildValoptBox`); the emit path passes the raw word, so the callee reads a present value as absent (present
  0 == the null word) or dereferences a raw scalar on unbox. `resolveCallee` accepts the callee (a boxed value
  optional IS an i64 word in the signature), which is exactly why the plain all-word check is not enough; this
  recovers the callee's declared param TypeRefs by name and rejects.

### The dry validation (`mirEmittable` / `mirInstEmittable`)

- **`fn mirEmittable(compiler, mf) bool`** (private) -- the whole-function dry validation. For every instruction:
  reject if its result type is a value optional (`isValueOptionalTid`), then delegate to `mirInstEmittable`.
  For every terminator: a `ret` of a heap struct must transfer a balanced +1 to the caller, so it is admitted
  ONLY when the returned value is a FRESH `struct_new` (`isStructNewResult`, rc=1, moved out -- also covers a
  returned owned local whose slot forwards to its struct_new) OR a BORROWED value the return path RETAINED
  (`isRetainedResult`, D4); an un-retained borrow would under-retain (double-free) and is rejected. A
  `switch_` terminator is rejected outright. `br` / `condbr` / `unreachable_` are fine. Builds NO IR -- this MUST
  pass before `emitFunc`.
- **`fn mirInstEmittable(compiler, mf, inst) bool`** (private) -- the per-instruction gate. First rejects a
  value-optional result type (`tidIsValueOptional`). Then per op:
  - **`binop`** -- FLOAT (f64 / f32) binop: both operands float-word; arithmetic (add / sub / mul / div) needs a
    float result, comparisons yield bool; no mod / shift / bitwise on float. Reference-word eq / ne
    (`isRefWordEq`) -> admitted. Otherwise both operands must be `intKindForTid`: arithmetic + shifts
    (add / sub / mul / shl / div / mod / shr) need SIGNED non-bool operands and a non-bool int result; bitwise
    needs signed-or-bool operands; comparisons split ordering (signed non-bool) from eq / ne (signed-or-bool).
  - **`cast`** -- int<->int only: both operand AND result must be integer kinds (the emitter canonicalises to the
    result width, which is exact for int<->int but wrong for float<->int / pointer casts).
  - **`call`** -- the callee must resolve all-word (`resolveCallee`), must NOT have a trait-typed param
    (`calleeHasTraitParam`, cannot widen), and must NOT target a value-optional param
    (`callTargetsValueOptionalParam`, cannot box).
  - **`struct_new`** -- the struct must be known and FULLY initialised (every declared field supplied, so
    zero-init is never relied on); every field must be scalar, OR a bare `string` field whose arg is a
    `const_str` literal (moved in, no retain). Holds for both a heap struct (released via `nova_release` + real
    `__destruct_`) and a value struct (inline stack bytes, `dropValueStruct`).
  - **`tuple_new`** -- the result must be a scalar tuple and every element a scalar int / bool.
  - **`field_get` / `field_set`** -- the base must be a known struct and the field scalar (reads / writes work
    for both heap and value structs; field offsets are payload-relative in both).
  - **`global_const`** -- the name must BE a const (`compiler.constants`, not a bare function ref / capture) and
    its result type a scalar int / bool.
  - **`retain`** -- a plain refcount bump, admitted on a string, a string-optional, or a heap-struct pointer
    word (D4).
  - **`release`** -- admitted on a string / string-optional (null dtor), a string-field struct
    (`stringFieldStructDropKind`, D3), or a scalar tuple (freed via its no-op-body tuple destructor).
  - **`index_get`** -- the object must be a string or a non-float array (`indexKind`).
  - **`template`** -- EVERY part must be a string, and the four StringBuilder helpers must be resolvable in
    `func_map`.
  - **`const_str`** -- always emittable (immortal interned global, no ARC).
  - **`store`** -- the target must be an `alloc` (`storeAddrIsAlloc`); an unmodelled `a[i] = v` lvalue lowers to
    a computed-i64 address and would fail LLVM verification.
  - **`const_int` / `alloc` / `load` / `param`** -- always fine.
  - **`indirect_call`** -- the receiver must resolve to a trait vtable slot (`traitDispatchSlot`, sync only), be
    a caller-built fat pointer (`receiverIsParamBacked`), take NO extra args (self only), and return a scalar
    int / bool.
  - everything else (`gep` / `await` / `spawn`) -> reject.
- **`fn isStructNewResult(mf, v) bool` / `fn isRetainedResult(mf, v) bool`** (private) -- the two heap-struct-
  return admission helpers used by `mirEmittable`'s `.ret` gate.

### The emission (`emitInst` / `emitFunc` / `emitBinop`)

- **`fn emitInst(compiler, fn_val, inst, mf, vals) !?types.LLVMValueRef`** (private) -- emits one MIR
  instruction into the builder's current block; `vals` maps MIR Value -> LLVM value across the whole function
  (SSA is globally numbered). Per op, the EXACT LLVM produced:
  - **`const_int`** -- `LLVMConstInt(val_type, v, signed)`, then `canonicalizeInt` to the result type's int
    width (so a constfold result that overflows `int` wraps as the AST would). Bool is not canonicalised.
  - **`const_str`** -- `getOrCreateStringLiteral` (the SAME immortal interned global the AST uses).
  - **`global_const`** -- `compileConstRef(name, init_expr)` (the SAME lazy-init per-module `__const_<name>_val`
    load the AST uses). The word is used VERBATIM -- NOT re-canonicalised: the threaded MIR type can be narrower
    than the const's real type (a `long` mask read as `int`), and a width-32 sign-extend would turn `0xffffffff`
    into -1, unmasking `x & MASK32`.
  - **`param`** -- `LLVMGetParam(fn_val, i)`.
  - **`binop`** -- delegates to `emitBinop`.
  - **`alloc`** -- `LLVMBuildAlloca(val_type)`. **`load`** -- `LLVMBuildLoad2(val_type, addr)`. **`store`**  -- 
    `LLVMBuildStore(val, addr)`.
  - **`cast`** -- `canonicalizeInt(src, width, signed)` to the RESULT width (an int<-long cast truncates).
  - **`struct_new`** -- `getTypeSize`, then a value struct uses `buildValueStructStorage` and a heap struct
    `compileAlloc(nova_bytes_alloc)`; each field is stored at `base + getFieldOffset`, inttoptr to the field's
    real LLVM type, `castFromValType` the word, store. Reuses the SAME layout + cast helpers as the AST.
  - **`tuple_new`** -- `compileAlloc(N*8)`, each element word stored at `base + k*8` via inttoptr to `ptr_type`.
  - **`field_get`** -- `base + getFieldOffset`, inttoptr to the field type, `LLVMBuildLoad2`, then
    `castToValType` back to the word.
  - **`index_get`** -- string: `obj + idx` -> inttoptr -> load i8 -> zext to the word. Array: `arrayBasePtr` +
    an inbounds i64 GEP + load. No bounds check (the AST emits none here either).
  - **`retain`** -- `compileRetain(val)`. **`release`** -- a string / string-optional -> `compileRelease(v,
    null)`; a scalar tuple -> `compileRelease(v, getOrCreateDestructorByTypeId)`; else the string-field struct
    path: `.heap` -> `compileRelease(v, getOrCreateDestructorPreferId(sname, tid))`, `.value` ->
    `dropValueStruct(v, sname, tid)` (no free -- stack storage).
  - **`field_set`** -- `base + offset`, inttoptr to the field type, `castFromValType`, store.
  - **`call`** -- `resolveCallee`, pass the arg words straight through (no coercion), `LLVMBuildCall2`.
  - **`indirect_call`** -- reproduces the AST's `buildTraitVtableCall` EXACTLY: load `struct_ptr = *(recv)`,
    `vtable = *(recv + ptr_size)`, `fn_ptr = *(vtable + (slot+1)*ptr_size)` (slot 0 is the destructor), then an
    indirect `LLVMBuildCall2` of a 1-word-param / word-return function type passing `struct_ptr` as self.
  - **`template`** -- reproduces the AST StringBuilder lowering: `compileAlloc(sizeof StringBuilder)`,
    `StringBuilder_init`, one `StringBuilder_append(sb, part)` per part (append copies + borrows, no per-part
    ARC), `StringBuilder_toString` (the owned result), `StringBuilder_delete`, then `compileRelease(sb, null)`.
  - everything else -> `error.Unemittable` (filtered by `mirEmittable`, but safe).
- **`fn emitFunc(compiler, fn_val, mf, entry_bb) !void`** (private) -- emits the whole function. Block 0 is the
  already-positioned `entry_bb`; every other MIR block gets a fresh LLVM block. Instructions are emitted in
  block-index order (which satisfies SSA define-before-use for these structured CFGs -- locals are memory, so the
  only cross-block values are entry-dominating allocas, and loop back-edges carry control only, no phis). The
  `vals` map is filled as it goes. Terminators: `ret` (a value or void; a null value defaults to `const 0`),
  `br`, `condbr` (branch on `cond != 0`, exactly as the AST does), `unreachable_`; `switch_` -> `error.Unemittable`
  (rejected by `mirEmittable`).
- **`fn emitBinop(compiler, inst, op, mf, l, r) !types.LLVMValueRef`** (private) -- the airtight binop emitter,
  reproducing the AST's integer semantics EXACTLY. Three arms:
  - FLOAT (f64 / f32): both operands must be float-word; bitcast to `DoubleType`, do the FP op
    (`FAdd`/`FSub`/`FMul`/`FDiv`), bitcast the result back to the word; comparisons use the ordered predicates
    (`OEQ`/`ONE`/`OLT`/`OLE`/`OGT`/`OGE`) then zext. f32 takes the identical DoubleType path (its word already
    carries the double pattern). No mod / shift / bitwise on float.
  - Reference-word eq / ne (`isRefWordEq`): a bare `icmp eq/ne i64` then zext, mirroring how the AST compiles a
    nullable-pointer `== undefined` / `== null`.
  - Integer: both operands `intKindForTid`. Arithmetic + left shift emit at the i64 word then
    `canonicalizeInt` to the RESULT width (the 32-bit-honest wrap). Bitwise are representation-preserving (no
    canonicalise, matching the AST). Comparisons use the signed predicates then zext (ordering needs signed
    non-bool operands; eq / ne allow bool). div / mod emit the AST path's exact div-by-zero (+ i64 MIN / -1)
    guard via `emitIntDivGuard` then `SDiv` / `SRem` (NOT canonicalised: width<64 sign-extended operands cannot
    overflow, width==64 is caught by the guard). shr is an arithmetic `AShr` of the sign-extended word.
    Unsigned div / mod / shr fall back to the AST.

---

## Cross-references

- **`backend/codegen/llvm_codegen.zig`** -- the shipping AST->LLVM backend and the fallback for every function
  the emit path rejects. `tryEmit` is invoked from the function-emission path there; the emitter reuses this
  file's `LlvmCompiler` for every LLVM helper (`compileAlloc`, `getFieldOffset`, `toLLVMType`,
  `castFrom/ToValType`, `getOrCreateStringLiteral`, `compileConstRef`, `resolveCalleeName`, `func_map`,
  `structs`, `enums`, `traits`, `constants`, `symbolName`, `scopedTypeName`, `canonicalizeInt`,
  `emitIntDivGuard`, `getOrCreateDestructorByTypeId` / `getOrCreateDestructorPreferId`). The invariant is that
  an emitted function is byte-identical to what this backend would have produced.
- **`backend/codegen/arc.zig`** -- the ARC primitives the emit path reuses for `retain` / `release`:
  `compileRetain`, `compileRelease(ptr, dtor)`, `dropValueStruct`, plus the destructor resolution the release
  gate leans on. The whole point of `arc_elision` is to remove pairs before they reach these calls.
- **`backend/codegen/types.zig`** (`types_mod`) -- the type-name / layout helpers the gates use: `cgPrim`,
  `reprBitWidth`, `getStructBaseName`, `valueOptionalName`. The middle-end resolves everything through TypeIds
  and these helpers, never through raw type spellings (the lesson of the string-engine removal).
- **`frontend/sema`** -- the source of truth the middle-end consumes but does not modify:
  `infer.TypedIr` (`typeOf`, `typeOf2`, `ownedOf`, `symOf`), `symbols.SymbolTable`, `frontend/types.zig`
  (`TypeId`, `TypeStore`, `SymbolId`), and `sema/shadow.live_sema` (the live symbol table the enum classifier
  reads). The IR is built AFTER monomorphisation, so all generics are concrete.
