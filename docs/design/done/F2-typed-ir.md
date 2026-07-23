# F2 — Typed IR (the semantic middle)

**Depends on:** F1 (you cannot type what you cannot resolve).
**Blocks:** F3, F4, F5 — all of them.
**Status:** ✅ **SUBSTANTIALLY LANDED — this header said `Design` after the keystone shipped.**
Stages 1 → 4d are LANDED: `Type`/`TypeStore`, `TypeRef`→`TypeId` lowering, expression inference,
the `ExprId` re-key, codegen cut over as the default, and **the legacy resolver DELETED** (357
lines; 0 lossy fallbacks of 53,507). **Open: stage 5** (`.unresolved` is fatal; delete every
`orelse "i32"`) and **stage 6** (the checker writes `TypedIr` instead of discarding it).
**This is the keystone document. If you read one, read this.**
*(Corrected 2026-07-17 — see `../beta-readiness-plan.md` §1.)*

---

## 1. The claim

> Nova has no representation between the AST and LLVM. The type checker is a **linter whose results are
> freed before codegen starts**. Codegen re-derives types from scratch, as strings, at each use site —
> and when it fails, it returns `"i32"`, which is indistinguishable from success.

Two lines prove it.

**`main.zig:1310-1317`:**
```zig
var tc = type_checker.TypeChecker.init(allocator, &file_sources);
defer tc.deinit();                                   // <-- every inference freed
try tc.check(program);                               // takes ast.Program BY VALUE
try llvm_codegen.compile(allocator, program, ...);   // same untouched AST
```

`check` takes `program` **by value** (`type_checker.zig:100`). It is *structurally incapable* of
annotating anything. It computes real types (`resolveExprType`, `:498-659`) and even canonicalises them
(`canonicalizeTypeName`, `:778-794`) — then frees it all (`:40-52`).

**`arc.zig:11`:**
```zig
pub fn isRefCountedType(self: *LlvmCompiler, type_name: []const u8) bool
```

**Ownership — a semantic property — is decided from a string.** When the string is `"T"` the answer is
hardcoded `false` (`:13-15`). When it contains `"=>"`, hardcoded `false` (`:19-20`). Those are not
oversights. They are *the only possible answers* when the type is not known. **The function cannot be
fixed; its signature is the defect.**

And `src/types.zig` is **0 bytes** — an empty file where the `Type` should be.

---

## 2. Current state (measured, file:line)

### 2.1 The AST is the only IR, and it is untyped

`ast.zig:165`:
```zig
pub const TypeRef = union(enum) {
    ident: []const u8,  optional: *TypeRef,  fixed_array: ...,
    generic: struct { name: []const u8, params: []TypeRef },
    func: ...,  tuple: []TypeRef,
};
```

`TypeRef` carries **names only** — no `resolved`, no decl pointer, no symbol id. **No `Expression`
variant has a type field** (`ast.zig:277-304`); `BinaryExpr`, `CallExpr`, `FieldAccess` carry only
`span`. *There is nowhere to write an inferred type even if a pass wanted to.*

`StructInit.type_name` is `[]const u8` (`ast.zig:395`), **not a `TypeRef`** — a struct literal
structurally cannot carry type arguments. `parser.zig:1461-1470` parses `List<string>{...}`'s type args
and then **drops them on the floor**.

### 2.2 Types are strings, round-tripped through text

`typeRefToString` (`types.zig:125-174`) flattens the structured `TypeRef` to text —
`"List<string>"`, `"i32[4]"`, `"(i32,string)"` — and downstream code **re-parses it with string
surgery**: `indexOfScalar(t, '<')`, `indexOfScalar(t, '[')`, `splitSequence(", ")`.

The round-trip is not even self-consistent: `typeRefToString` emits `", "` for generics (`:148`) but
`","` for tuples (`:134`), while `substituteGenericType` splits on `", "` (`llvm_codegen.zig:2387`).

Type state, all `[]const u8`:
- `FunctionInfo.return_type` (`llvm_codegen.zig:55`)
- `current_local_types: ?*StringHashMap([]const u8)` (`:81`)
- `function_local_types: StringHashMap(StringHashMap([]const u8))` (`:87`)

**31 decision points** switch on a type-name string. The load-bearing ones:

| Site | Decides |
|---|---|
| `types.zig:40-48` | `toLLVMType` — 9 `mem.eql` chains → LLVM type |
| `types.zig:26-34` | `isPrimitiveTypeName` — 25 `mem.eql`s |
| `types.zig:74-79` | zext vs sext, by **spelling** of unsignedness |
| `llvm_codegen.zig:697-703` | `getTypeSize` — byte size by name |
| `expressions.zig:732-742` | `is_float_op` — `mem.eql(lt,"f32")\|\|"float"\|\|"f64"\|\|"double"` → **FAdd vs Add** |
| `expressions.zig:714-731` | `mem.eql(lt,"string")` → string concat vs integer add |
| `arc.zig:11-23` | **ownership** |
| `types.zig:9-18` | `getStructBaseName` — erases generic args by `indexOfScalar('<')` |

Choosing `FAdd` vs `Add` by string-comparing `"f64"` is the entire type system in one line.

### 2.3 Two inference engines, neither authoritative

| | `type_checker.zig:498` `resolveExprType` | `codegen/types.zig:176` `resolveExpressionTypeName` |
|---|---|---|
| Returns | `?ast.TypeRef` | `?[]const u8` |
| Has a canonicaliser | yes (`:778`) | **no** — hence the repeated 4-way `mem.eql` chains |
| Consumed by | nothing | codegen |
| Lifetime | freed at `deinit` | recomputed per use site |

They disagree, and the *worse* one wins. Codegen's version is called repeatedly for the same expression
and allocates: some returns are heap (`:207`, `:236`, `:358`), most are borrowed — **the caller cannot
tell which, and nothing frees them.**

### 2.4 The fallback is invisible — the most important fact in this document

`resolveExpressionTypeName` returns `"i32"` on failure:

| Site | Failure → |
|---|---|
| `types.zig:201` | integer literal → `"i32"` |
| `types.zig:206` | empty/unknown array element → `"i32"` |
| `types.zig:252` | any `bytes.*` → `"i32"` |
| `types.zig:334-339` | `nova_dir_*` / `nova_file_*` → `"i32"` |
| `types.zig:457` | binary with both sides unknown → `"i32"` |
| `types.zig:477` | `.block_expr` → `"string"`, unconditionally |
| `expressions.zig:1742` | unresolved **field** → `i32` → loads 8 bytes at a guessed offset |
| `declarations.zig:715,718`, `llvm_codegen.zig:2256` | unresolved → `"i32"` |

Because `i32` **is** the universal machine word (F3 §2.1), a failed inference produces a *valid-looking,
correctly-sized* value.

> **The compiler cannot distinguish "this is an int" from "I have no idea what this is."**

This is why Nova's defects are silent rather than loud, and why they are found in a debugger months
later instead of at compile time. Every bug fixed on 2026-07-15 was an instance.

### 2.5 The type checker treats `u64` and `i64` as the same type

`canonicalizeTypeName` (`type_checker.zig:790`) maps `u32`→`i32`, `uint`→`i32`, `double`→`f64`;
`typesAreEqual` (`:799`) compares canonicalised names. **Signedness is erased in the checker too**, so it
cannot catch a signed/unsigned error even in principle. It also never flags a pointer stashed in an
`i32` field, because `isTypeCompatible` (`:836`) sees a legal numeric.

---

## 3. Target design

### 3.1 Invariants

- **T1 — A type is a value, not a spelling.** `TypeId`, interned. `Type` is a real tagged union.
  `mem.eql` on a type name never decides semantics again.
- **T2 — Every expression has a type.** Not derivable on demand — *recorded*, once, by one pass.
- **T3 — One inference engine.** Codegen never infers. It reads.
- **T4 — Unknown is representable and fatal.** There is a `.unresolved` type. It is an **error at the
  end of sema**, never a silent `i32`. Reaching codegen is a compiler bug (assert).
- **T5 — Sema owns semantics; codegen owns instruction selection.** Codegen answers "which opcode for
  *this* `TypeId`", never "what does this name mean".

### 3.2 Shape

A new `src/sema/`, sitting where nothing sits today:

```
lexer → parser → [F1 resolve] → [F2 sema: typecheck + annotate] → codegen → LLVM
                      │                    │
                  SymbolTable          TypedIr  ─────────► consumed, not rebuilt
```

```zig
pub const TypeId = enum(u32) { _ };

pub const Type = union(enum) {
    prim:      PrimType,                                   // F3 owns this
    string,
    struct_:   struct { decl: SymbolId, args: []TypeId },  // args non-empty = instantiation (F4)
    enum_:     SymbolId,
    trait:     SymbolId,
    func:      struct { params: []TypeId, ret: TypeId },   // a real type, not "contains =>"
    optional:  TypeId,
    tuple:     []TypeId,
    array:     struct { elem: TypeId, len: usize },
    type_param: struct { owner: SymbolId, index: u32 },    // "T" is a TYPE, not a letter
    ptr,                                                   // F3
    unresolved,                                            // T4 — explicit, fatal
};

pub const TypeStore = struct {                             // interning: TypeId equality == type equality
    pub fn intern(self: *TypeStore, t: Type) TypeId { ... }
    pub fn get(self: *TypeStore, id: TypeId) Type { ... }
};
```

Note what becomes *expressible*:
- `.func` — a real type. `indexOf(name, "=>")` (`arc.zig:19`) becomes unrepresentable.
- `.type_param` — `T` is a type with an owner and an index. `type_name.len == 1 and 'A'..'Z'`
  (`arc.zig:13`) becomes unrepresentable, and `substitutePlaceholders`' hardcoded `T`/`K`/`V`/`U`
  (`llvm_codegen.zig:2345-2355`) becomes unnecessary — F4 substitutes by **index**.
- `.struct_.args` — `List<string>` ≠ `List<int>`. `getStructBaseName`'s erasure (`types.zig:9`) stops
  being the lookup key.

### 3.3 The typed IR

Minimum viable: **annotate, don't rebuild.** A side table keyed by AST node, not a new tree.

```zig
pub const TypedIr = struct {
    expr_types: std.AutoHashMapUnmanaged(ExprId, TypeId),  // T2
    expr_syms:  std.AutoHashMapUnmanaged(ExprId, SymbolId),// F1's answer, recorded
    types:      TypeStore,
    // + coercions/casts sema inserted, so codegen never re-derives one
};
```

This requires a stable `ExprId` — the one AST change F2 needs (`ast.zig` expressions gain an `id: ExprId`,
assigned by the parser). That is a smaller, more mechanical change than a parallel typed tree, and it
keeps the AST as the single structural representation.

`llvm_codegen.compile` takes `*const TypedIr`. `resolveExpressionTypeName` (`types.zig:176-485`, 309
lines) is **deleted**, along with codegen's duplicated tables.

> **Why not a full typed tree?** Because it can't land incrementally. A side table can be built and
> verified against today's behaviour while codegen still uses the old path (§5 stage 2). Given the
> resolution nondeterminism F1 exposes, "land it in one commit" is not available.

### 3.4 The checker becomes real

`type_checker.zig` stops being standalone. It:
- takes `*ast.Program` and a `*SymbolTable`, and **writes** `TypedIr`
- keeps its checks (arity `:315`, trait conformance `:681`, return types `:198`, bool conditions `:154`)
- drops `canonicalizeTypeName`'s signedness erasure (§2.5) — with `PrimType`, `u64` ≠ `i64` by construction
- loses `ambiguous_fns` (`:14-17`) — F1 makes ambiguity an error, so the arg-count check turns **on**

The checks currently blocked, per roadmap A2, unblock **because of F1+F2, not by patching the checker**:
arg-count (blocked on namespacing → F1), condition-is-bool (blocked on comparisons typed `i32` → F2),
return-type (blocked on permissive `isTypeCompatible` → F2 + F3).

---

## 4. What this fixes

Not a list of bugs — a list of *classes*:

- **Silent wrongness** (T4). The single highest-value change in the program.
- **Ownership by spelling** → F5 becomes possible at all.
- **`T` as a letter** → F4 becomes possible at all.
- **Width by spelling** → F3 becomes enforceable (literal ranges, narrowing).
- Two inference engines → one. ~309 lines of codegen inference deleted, plus the string round-trip.
- The `", "` vs `","` round-trip inconsistency (§2.2) — unrepresentable.
- Unfreed inference allocations (§2.3) — the store owns types.

**What F2 does NOT fix:** nothing about representation (F3), instantiation (F4), or ownership (F5). F2 is
the *substrate*. Landing it changes no runtime behaviour — that is the point, and it is what makes it
safe to land.

---

## 4b. The expression gap — where it went (2026-07-15)

Corpus-wide: **53,507 compared · 0 absent · gap 20 · disagree 1792**, 11 of 17 cases at gap 0.

The gap started at 124 on `14_collections_map` and was called "the generics gap". Clustering it by
(shape, legacy → F2) **with counts and a name** — not by reading examples — showed it was five
different things wearing one label:

| was | cause | not |
|---:|---|---|
| 30 | three missing rows in `builtins.zig` | codegen declared four test externs; the table listed one. It reported **its own omissions** as language gaps. |
| 49 | generics: the method join, per-scope params, generic functions | G1/G2 were already true — nothing performed the **join** |
| 21 | closure **calls** — `(self.hashFn)(key)`, plus generic field substitution | not generics |
| 13 | method calls on **trait** receivers — `src.getString(k)` | not closures, not generics |
| 9 | closure **params** — contextual typing | the only part that was actually "closure parameter typing" |

Two lessons worth more than the fixes:

1. **Gaps cascade, so the root is worth far more than its count.** `list.get(i)` unresolved ⇒ `s` ⇒
   `s.length` ⇒ `len_s`: one missing join, four clusters, 43 divergences.
2. **A cluster label is the shape of the expression, not its cause.** Every one of the five above
   presented as `call`/`ident → <unresolved>`. Naming them is what separated them.

### The remaining 20 — all documented limits, none a bug

| n | what | needs |
|---:|---|---|
| ~8 | `let f = (a, b) => a + b;` — no expected type, so params are unresolved (spec 6.3a) | inferring params from later **call sites** = constraint solving, not propagation |
| ~4 | `list.map((x) => x*2)` → `List<U>`: U comes from the **closure's return** | unifying actual `(int) -> int` against declared `(T) => U` = type-**argument** inference |
| ~2 | `await h` | ⚠️ **`go` yields an UNTYPED handle** — spec §7 stores them as `List<i64>`. Nothing links the handle to the async fn's return type, so `await` is untypeable **by construction**. Needs `Handle<T>`. Legacy's `int` here is the machine-word default, not reasoning. |
| ~6 | downstream of the above | — |

**The cutover gate is no longer the gap.** It is the **1792 disagreements**, which are overwhelmingly
cases where **F2 is right and legacy is wrong** (`bytes.write_ptr(...)` IS void; `val < 0` IS bool;
legacy's `int` is the machine-word lie F3 exists to kill). Cutting over *fixes* those — but each one
changes emitted code, so 4b is a reviewed diff, not a flag flip.

## 5. Staging

| # | Stage | Content | Guard |
|---|---|---|---|
| 1 | ✅ **`Type` + `TypeStore`** (landed 2026-07-15) | `src/types.zig` was **0 bytes**; it now holds `Type`, `TypeId`, `PrimType` and an interning `TypeStore`. Imported by nothing — wired in at stage 2 under a shadow diff. | ✅ **12 invariant tests**, registered in `src/root.zig`'s `test` block (the house convention) so `zig build test` reaches them |
| **2a** | ✅ **`TypeRef` → `TypeId` lowering** (landed 2026-07-15) | `src/sema/lower.zig` — the bridge from syntax to the type system. Reports the declared-type surface under `NOVA_SEMA_SHADOW=1`; consumed by nothing. **Measured on `ycsb.nova`: 563 declared types, 480 lowered (85%), 83 unresolved (15%) — and all 16 distinct unresolved names are STRUCT types** (`Stats`, `TcpStream`, `PCursor`, `Rand`, `Allocator`…). Primitives, `string`, `func`, `optional`, `tuple`, `array` all lower cleanly; the only gap is **named types**, i.e. the F1↔F2 join. | ✅ corpus 28/28; 8 unit tests; shadow silent when the env var is unset |
| **2b** | ✅ **Symbol table wired in** (landed 2026-07-15) | `.ident "Stats"` → `.struct_{decl}`; `List<string>` → `.struct_{decl, args}`. The join F1 was built for. **`ycsb.nova`: 83 unresolved → 0. 563/563 of the declared surface types.** Also 0 unresolved on the driver repro (384), `13_serde` (463), `12_traits_dispatch` (291), `16_block_scope` (199). | ✅ corpus 28/28; 30 unit tests |
| **2c** | ✅ **Expression inference** (landed 2026-07-15) | `src/sema/infer.zig` — a third engine, deliberately, because the two that exist are both wrong (one is freed at `deinit`, the other falls back to `"i32"`). **`ycsb.nova`: 5097 expressions, 4294 typed (84%), 803 unresolved.** Failing shapes are *named*: `ident` 291, `call` 290, `field_access` 102, `index` 62, rest 58. | ✅ corpus 28/28; 34 unit tests |
| **2d** | ✅ **Module-qualified calls** (landed 2026-07-15) | `string.hash(x)` — the object is a MODULE, not a struct receiver. Guarded by *"is the object a variable"*, the same rule F1 put into codegen. **803 → 664 unresolved; 84% → 86%.** `ident` 291→225, `call` 290→224. | ✅ corpus 28/28; 35 unit tests |
| **2e–2h** | ✅ **Undeclared surfaces + the rest** (landed 2026-07-15) | Builtins (`console`/`bytes` have **no `.nova` file**), runtime externs (`nova_test_fail` ×34, bare-named), constants, implicit `self` in constructors, module-segment ambiguity, generic calls, array literals, string properties, indexing. **803 → 71 unresolved; 84% → 98%.** Across the tree: driver repro 99%, `13_serde` 98%, `12_traits_dispatch` 98%, `16_block_scope` 99%, `10_async_go` 98%. | ✅ corpus 28/28; 41 unit tests |
| **2i** | ⚠️ **`TypedIr` persisted — but keyed WRONG** (2026-07-15) | Keyed by the expression's **address**. Types 98% of the surface, but see stage 4: **address-keying cannot work for the cutover**, and §6 Q1's original `ExprId` recommendation was right. | corpus 28/28; 44 unit tests |
| **3** | ✅ **Diff against the legacy resolver** (landed 2026-07-15) | Both engines answer every real resolution codegen performs; the answers are compared. **ycsb: 6596 compared — 4880 agree · 177 F2-better · 129 disagree · 114 legacy-answered-F2-didn't · 1296 not in the IR.** Dominant disagreement: `binary: 'i32' -> 'bool'`, exactly as §2.4 predicted from reading the code. | ✅ corpus 28/28 |
| **4a** | ✅ **Re-keyed the IR on `ExprId`** (landed 2026-07-15) | Address-keying could not reach zero: `compileStatement(stmt: ast.Statement)` / `compileExpression(expr: ast.Expression)` take AST nodes **BY VALUE**, so pointers derived inside them (`&es.expr`, `&ls.init.?`) are **stack addresses**; only pointer *fields* (`bin.left`) and slice elements (`&call.args[0]`) survive a copy. That is why stage 3 went 1296 → 1113 and then **flat** — structural, not a bug list. Took option **(a)** (`ExprId` on the AST, per §6 Q1) over **(b)** (by-reference codegen, ~115 sites): fewer edits, and (b) fails *silently* while (a) fails at compile time. `Expression` is now `{id, kind}`; `sema/ids.zig` stamps every node, one `Assigner` per program. **Measured, same program & harness: 4444 compared · 1121 absent → 0 absent; agree 2949 → 3624.** | ✅ absences **1121 → 0**; corpus 28/28; IR byte-identical on all 17 positive cases |
| **4b** | 🟡 **Cut codegen over** — *works, byte-identical, gated* (2026-07-15) | `NOVA_F2_TYPES=1`: codegen READS the IR. **52,088 answered (97.3%) · 1,419 fell back · emitted IR BYTE-IDENTICAL on all 17 cases · corpus 28/28 · +6.3% compile time, +0.1 MB RSS.** The 1792 disagreements were 21 clusters, then **9** once the `<fn>` printer was fixed; **7 of 9 are F2 right and legacy wrong** (comparisons ARE bool; `bytes.write_ptr` IS void; legacy conflates a closure's param with the closure). The other 2 are `K`/`V` — F2 says the type parameter, legacy says the erased word; both describe today's boxed representation, so F4's monomorphization is what makes it a real difference. **And serving F2 at every disagreeing site changes NO emitted code — the disagreements are real but INERT** (codegen asks and does not use them to select instructions). Byte-identity verified against a `f2_served` counter, because "identical IR" is otherwise indistinguishable from "the cutover never ran". | ✅ IR diff reviewed, not assumed |
| **4c** | ✅ **Sema runs on every compile; the cutover is the default** (2026-07-15) | `sema/sema.zig` owns store + table + IR + interned names; main creates and destroys it (at FUNCTION scope — a block-scoped `defer` frees the IR before codegen reads it, and freed memory still reads fine, so the corpus would hide it). **IR byte-identical on all 17 · 28/28 · 97.3% served · +0.9% time · +0.2 MB · silent by default.** Escape hatch `NOVA_NO_F2_TYPES=1` until legacy is deleted. | ✅ owned (tests under `testing.allocator`); corpus green; IR byte-identical |
| **4d** | ✅ **Legacy resolver DELETED** (2026-07-15) | **357 lines gone**, emitted IR byte-identical, corpus 28/28. Codegen ASKS sema. `null` now means "no type", not `int`. Gated on **0 lossy fallbacks of 53,507** — every resolution legacy answered, sema answers — which took `future<T>` for `await`, closure-param inference from use, contextual typing in return position, and type-**argument** inference (`solveParams`). | ✅ 0 fallbacks that legacy could answer; IR byte-identical |

> **What "1,419 fallbacks" actually meant.** 4d looked blocked on 1,419 of 53,507 resolutions. Only
> **20 were LOSSY** — legacy had an answer and sema did not; the other 1,399 are cases where legacy
> returns null too, so deleting it costs nothing there. Measuring that split is what turned 4d from
> enormous into five increments: 20 → 11 (`await`) → 5 (param-from-use) → 3 (return position) → 1
> (type-arg inference) → **0**.
>
> **Three bugs sat between "implemented" and "working" on the last one**, and none was visible in the
> code — each was found because *the number did not move*: `U` was never a `.type_param` at all (only
> the struct's scope was installed, so it lowered to `.unresolved` and the solver had nothing to
> match); the closure reported its **expected** type as its actual one, so solving `U` against `U`
> learned nothing; and `reduce`'s `U` is solved from argument 0 *after* the closure was already
> inferred — fixed by recognising that an expectation of `unresolved` is **no expectation**, so the
> body-use rule applies anyway.


> **What actually unblocked 4c — and the correction that got there.** I claimed leaks were the blocker
> (31277b3). **Wrong**: main allocates from an `ArenaAllocator` with `defer arena.deinit()`, so the
> "leaks" were bounded and reclaimed at exit, and an individual `free()` into an arena is a no-op. The
> measurement I already had said so (+0.1 MB). The real blocker was **+6.3% compile time**, and the fix
> was **interning type names**: the cutover renders a name on every resolution (9,222 on one case), and
> a TypeId is interned so its name is a pure function of it. Render once → **296 allocations → 11**, and
> the overhead fell to noise.
>
> The second thing keeping sema off was that **building it and reporting on it were the same switch**. A
> compiler that narrates its own type inference on every build is unusable — so the narration was gating
> the feature. Separating them is what let sema become unconditional.

| 3 | **Triage divergences** | Each is a real bug (fix + case) or intended. Expect the `.block_expr → "string"` and `binary → "i32"` sites to light up. | new cases |
| 4 | **Cut codegen over** | Codegen reads `TypedIr`. Delete `resolveExpressionTypeName` + duplicated tables. `isRefCountedType` takes `TypeId`. | corpus green |
| 5 | **T4: unresolved is fatal** | Delete every `orelse "i32"`. `.unresolved` at end of sema = error; at codegen = assert. | expect_fail cases |
| 6 | **Checker writes, not discards** | Merge `type_checker.zig` into sema. Turn on arg-count, bool-condition, return-type. | expect_fail per check; zero stdlib false positives |

Stage 2 is the risk strategy, and it is the same one F1 uses: **build the truth alongside the lie and
diff them** before anything depends on it.

---

## 6. Open questions

1. **`ExprId` on AST nodes vs a parallel typed tree.** ⚠️ **I got this wrong twice — the ORIGINAL recommendation stands.**
   Stage 2i replaced `ExprId` with address-keying and called the design over-cautious. Stage 3 then
   measured the consequence: codegen takes AST nodes **by value**, so a pointer taken inside it is a
   stack address and the IR can never be read there. The caveat I wrote at 2i — *"an ExprId survives an
   AST copy; an address does neither"* — was the whole argument, and I shipped the address anyway
   because it was cheaper. **Use `ExprId`.** The paragraph below records what 2i claimed.
   ~~**RESOLVED 2026-07-15 — neither was needed.** The side table keys on the expression's **address**:
   expressions live in parser-allocated memory that is never copied, so identity was already available
   and `ast.zig`/`parser.zig` are untouched.~~
   **WRONG, and reverted in 4a (2026-07-15).** The premise — "never copied" — was false: codegen's whole
   walk takes AST nodes **by value**, so the address key missed on every derived pointer. The caveat
   below was written *in the same commit that shipped the address anyway*, which is the actual lesson:
   the argument against was already known and lost to it being cheaper.
   ⚠️ (as written then) an `ExprId` survives an AST copy and prints in a debugger; an address does
   neither, and if the AST is ever copied or reallocated after sema the lookup **misses silently**.
   It did — 1121 silent misses on one corpus case, invisible until stage 3 counted them.
   Forcing pointer identity also forced the whole walk to be by-reference — `inferStmt` taking
   `ast.Statement` **by value** meant switch captures pointed into a stack copy, so every recorded
   address would have dangled. That was found by the compiler, not by a test; it would not have been
   found by reading.
2. **Where do coercions live?** Sema should *insert* explicit cast nodes rather than leave codegen to
   infer them (`castToValType` currently guesses from the LLVM kind). Confirm sema owns this.
3. **How much does sema desugar?** Template strings, `?.`, `??`, `for`, JSX. Desugaring in sema shrinks
   codegen a lot. *Recommendation:* out of scope for F2; revisit after F5.
4. **Error recovery.** Continue after the first type error to report many (needs `.unresolved` to
   propagate without cascading), or fail fast? *Recommendation:* propagate, report all, never codegen.

---

## 7. Done criteria

- [x] ✅ `src/types.zig` contains a `Type` and a `TypeStore` (was 0 bytes) — landed 2026-07-15, 12 tests
- [ ] Every expression has a recorded `TypeId`; codegen infers nothing
- [ ] `isRefCountedType(TypeId)` — no `[]const u8` in any semantic signature
- [ ] Zero `mem.eql` on type names in codegen (31 sites → 0); no type is ever a string
- [ ] `resolveExpressionTypeName` deleted
- [ ] `.unresolved` exists, is an error at end of sema, and asserts in codegen; zero `orelse "i32"`
- [ ] The checker writes `TypedIr`; `tc.deinit()` no longer discards the compiler's knowledge
- [ ] `ambiguous_fns` deleted; arg-count check on, zero stdlib false positives
- [ ] specs grades table: *Type checker = Advisory only* → **Enforcing**
