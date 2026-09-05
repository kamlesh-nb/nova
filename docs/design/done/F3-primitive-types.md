# F3 — Primitive types & value representation

**Depends on:** F2 (typed IR) for literal-range and narrowing enforcement.
**Supersedes/absorbs:** evolution plan **L1** (honest primitives) and **L3** (`ptr`). Those remain the
rationale; this is the implementable design.
**Status:** 🔨 **IN PROGRESS — this header said `Design` mid-implementation.**
Stages 1 (PrimType table), 2 (`ptr`), 3 (`${f64}`/`${i64}`), 4 (real float storage) and 4b
(stdlib `ptr` migration) are LANDED. **Stage 5 (int→32 + real unsigned) is IN PROGRESS**
(inc 1–5 landed; remaining: honest i32 local slots, debug-trap). **Stage 6** (stdlib annotation
sweep) in progress. **Open: 5a** (`decimal`), **7** (R6: unresolved is not `i32`).
⚠️ **Ordering is load-bearing: never pause inside stage 5** (§5).
*(Corrected 2026-07-17 — see `../beta-readiness-plan.md` §1.)*

---

## 1. The claim

> A declared type in Kyte does not describe storage. There is exactly **one** runtime type — a machine
> word — and declared type names are consulted only to pick an *instruction*, never a *representation*.

Everything below is measured.

---

## 2. Current state (measured, file:line)

### 2.1 One slot to rule them all

`llvm_codegen.zig:245`:
```zig
.val_type = if (is_wasm) core.LLVMInt32Type() else core.LLVMInt64Type(),
```

`types.zig:37-52` — `toLLVMType`, the entire declared-name → LLVM mapping:

| Kyte names | LLVM type | line |
|---|---|---|
| `i8 u8 byte ubyte` | `i8` | :40 |
| `i16 u16 short ushort` | `i16` | :41 |
| **`i32 u32 int uint`** | **`val_type`** (i64 native / i32 wasm) | **:42** |
| `i64 u64 long ulong` | `i64` | :43 |
| `i128 u128 decimal` | `i128` | :44 |
| `f32 float` | `float` | :45 |
| `f64 double` | `double` | :46 |
| `bool` | `i1` | :47 |
| everything else | `ptr` | :48,:50 |

So `i32` is **8 bytes on native, 4 on wasm**. `int` is an alias for it. `u*` is not unsigned — signedness
exists only as a zext-vs-sext choice at `types.zig:74-89`, and `castFromValType` (`:98-123`) **always
sexts on widening with no unsigned branch**, so the two directions are already asymmetric.

### 2.2 Locals and struct fields disagree with each other

This is the part that is not in the existing plan and matters for migration.

- **Locals/params:** *always* a `val_type` alloca, declared type never consulted.
  `declarations.zig:884` (params), `:911` (locals), `:752-754` (every param type), `:763` (every return).
- **Struct fields:** sized by declared type — `getTypeSize`, `llvm_codegen.zig:697-703`:
  `i8`→1, `i16`→2, **`i32`→8 native / 4 wasm** (:699), `i64`→8, `f32`→4, `f64`→8, `i128`→16.

**Therefore the same declared type has two different representations depending on where it lives.**
A `byte` local occupies 8 bytes; a `byte` field occupies 1. A `f64` local is an **integer** slot holding
a bit pattern; a `f64` field is a real `double`. Nothing enforces or documents this split.

Struct layout is hand-computed integer arithmetic — `getFieldOffset`, `llvm_codegen.zig:738-756` —
self-aligning (`align == the field's own size`), no struct-level alignment, no tail padding. Kyte structs
are **never** `LLVMStructType`; field access is `ptrtoint` + constant offset + `inttoptr`
(`expressions.zig:1759-1765`). The only real `LLVMStructType` is `exception_frame_type`
(`llvm_codegen.zig:248-252`).

### 2.3 Floats live in integer slots

A float literal is `LLVMConstReal(double)` then **bitcast** to `val_type` (`expressions.zig:562-564`).
Every float op is a bitcast sandwich: operands bitcast out to `double`, `FAdd`/`FSub`/…, result bitcast
back (`expressions.zig:747-770`). On wasm, `val_type` is **i32** — a 64-bit double bitcast into a 32-bit
slot. This is the mechanism behind `${f64}` SIGSEGV (§10 #2) and why `f32` is 🔎 unverified.

### 2.4 `data: i32` — why the lie is invisible

`list.ky:12` declares `pub data: i32` and stores a 64-bit heap pointer in it. It does not truncate
because **`i32` is not i32**:

1. `toLLVMType("i32")` → `val_type` → **i64** (`types.zig:42`)
2. `getTypeSize("i32", is_field=true)` → **8** (`llvm_codegen.zig:699`)
3. The field is stored/loaded through an `i64*` — a full 64-bit store (`expressions.zig:680-681`,
   `:1762-1765`)
4. `castToValType` i64→i64 is a no-op (`types.zig:94-95`); the truncation branch (`:91-92`) is never
   reached because `val_width == target_width`

Known pointer-in-`i32` sites (9 structs, 53 `bytes.alloc` call sites):

| File:line | Field |
|---|---|
| `std/collections/list.ky:12` | `pub data: i32` |
| `std/collections/string_builder.ky:6` | `pub buf: i32` |
| `std/collections/array.ky:33` | `ptr: i32` |
| `std/concurrency/atomic.ky:7` | `pub ptr: i32` |
| `std/data/btree/client.ky:50` | `pub buf: i32` |
| `std/data/btree/protocol.ky:98` | `pub buffer: i32` |
| `std/fs.ky:12`, `std/io/file.ky:20`, `std/io/dir.ky:23` | `pub handle: i32` |

**This works on wasm only by coincidence** — there, pointers genuinely are 32-bit.

### 2.5 The surface

| Fact | Count |
|---|---|
| `: i32` annotations in stdlib | **329** |
| `: int` / `: long` / `: double` in stdlib | **0** |
| `"i32"` string literals in the compiler | 48 |
| `bytes.alloc` sites | 53 |

**The canonical names from L1's own target table are used nowhere.** The stdlib is written entirely in
the names that lie.

### 2.6 "Unknown" and "i32" are the same value

`resolveExpressionTypeName` (`types.zig:176-485`) returns `?[]const u8` and falls back to `"i32"` on
failure: integer literal → `"i32"` (:201), unknown array element → `"i32"` (:206), binary →
`left orelse right orelse "i32"` (:457), `bytes.*` → `"i32"` (:252), `kyte_dir_*`/`kyte_file_*` → `"i32"`
(:334-339). Also `declarations.zig:715,718` and `llvm_codegen.zig:2256`.

Because `i32` **is** the universal slot, a failed inference is indistinguishable from a correct one.
**The compiler cannot currently tell "this is an int" from "I have no idea what this is."** That is why
these defects are silent rather than loud, and it is the single most important thing F3 changes.

---

## 3. Target model

### 3.1 The type table (from L1, unchanged — it was right)

| Kyte | Width | Signed | Notes |
|---|---|---|---|
| `bool` | 1 | — | |
| `byte` / `sbyte` | 8 | u / s | |
| `short` / `ushort` | 16 | s / u | |
| **`int`** / `uint` | **32** | s / u | **the default integer** |
| `long` / `ulong` | 64 | s / u | timestamps, counters, sizes |
| `float` / `double` | 32 / 64 | — | IEEE-754 **binary**, in real float storage |
| `decimal` | 128 | — | IEEE 754-2008 **decimal128** — base-10. See §3.2a |
| `ptr` | word | — | **opaque**; `bytes`/FFI only |
| `string`, `void` | — | — | heap+ARC / unit |

`i8 i16 i32 i64 u8 u16 u32 u64 f32 f64` remain **explicit fixed-width aliases** — but only once they
honestly carry those widths. `int` = **32-bit on every target**; the per-target split is the actual bug.

**`i128` / `u128` are removed** (decision 2026-07-15). Zero stdlib uses, zero conformance cases, no
consumer. Every retained name is another `mem.eql` link in the chains this document deletes. Honest
fixed-width 128-bit aliases can be added later if a real user appears; .NET added `Int128` only in .NET 7
and they remain niche. **`f128` is not added** — nothing asks for binary128.

### 3.2a `decimal` — IEEE decimal128, kept for BSON

**Decision (2026-07-15): `decimal` is IEEE 754-2008 decimal128, base-10, 34 significant digits.**
Driver: **BSON**. BSON's `decimal128` (type `0x13`) *is* IEEE decimal128, so this choice makes Kyte's
`decimal` **wire-identical to BSON — zero conversion, zero loss.**

**It is explicitly NOT .NET's `System.Decimal`**, and that distinction is the whole decision:

| | .NET `System.Decimal` | **IEEE decimal128 (chosen)** |
|---|---|---|
| Significand | 96-bit int + scale 0–28 | **34 decimal digits** |
| Range | ±7.9e28 | ±1e6145 |
| Standard | bespoke | IEEE 754-2008 |

**.NET's format cannot round-trip BSON decimal128** — fewer digits, smaller range. This is not
theoretical: the MongoDB C# driver ships its own `MongoDB.Bson.Decimal128` struct rather than use
`System.Decimal`, and converting between them can throw. Choosing .NET's format would make every BSON
decimal round-trip lossy **by construction**.

Equally, `decimal` must **not** be aliased to binary128/`fp128`. Binary128 is still *binary*: `0.1`
remains inexact, just inexact with 113 mantissa bits. A base-2 type named `decimal` would be the same
defect as `i32` not being 32 bits — the defect this document exists to remove.

**Constraints, all real:**

1. **Software implementation.** No hardware on ARM64/x86; no LLVM type. Options: Intel libbid, IBM
   libdecnumber (GCC's choice), or an own subset. Runtime dependency, decided before stage 5a.
2. **16 bytes does not fit today's slot.** Every local is one 8-byte `val_type` alloca (§2.2), so
   `decimal` as a **value type depends on F3 stage 4** (honest slots) and cannot exist before it.
   Making it a heap/ARC reference type instead would give a *number* reference semantics and allocate
   per operation — rejected.
3. **Kyte has no operator overloading**, so `a + b` on `decimal` is **lowered by the compiler to a
   runtime call**. Deliberate, recorded here rather than discovered later.

**Interim, until implemented:** `decimal` is a **hard compile error** ("not yet implemented"), never a
silent `i128`. Today it maps to `LLVMInt128Type()` (`types.zig:44`) — an *integer* — so
`let p: decimal = 10.5` cannot hold a fraction at all, and because locals are `val_type` the slot is
actually an **i64 holding bitcast double bits**. That is a live trap with no case guarding it, and it is
removed in stage 1. Consistent with roadmap A3: *"turn 'not supported in LLVM yet' printfs into hard
compile errors."*

### 3.2 `ptr` is not optional

Narrowing `int` to 32 bits **breaks every `data: i32`** the moment a pointer no longer fits. `ptr` is the
honest replacement and **must land before or with the width change** (§5 staging). L1 already said this;
it is restated because it is the one ordering constraint that, if missed, turns this migration into
silent heap corruption on native.

`ptr` semantics:
- Opaque, word-sized (64-bit native / 32-bit wasm). **Not** an integer: no arithmetic, no implicit
  conversion to/from any numeric type.
- Only `bytes.*`, FFI declarations, and runtime intrinsics produce or consume it.
- **Not ARC-managed** (F5 defines what is; a `ptr` is explicitly unowned).
- Printing a `ptr` requires an explicit `ptr.addr(): long`.

### 3.2b Ergonomics — `__i32_to_string` must never appear in user code

**Kyte targets web developers.** `__i32_to_string(n)` is compiler plumbing wearing a fixed-width type
name, and it has leaked into **24 call sites** across the stdlib and conformance corpus. It is not a
style wart; it is a **symptom with a measurable cause**, and F3 is what removes the cause.

**The cause.** Template strings already exist and are already the canonical style (§11) — `lexer.zig:40-41`,
`ast.zig:296`. Measured 2026-07-15:

| `` `${x}` `` where x is | Result |
|---|---|
| `int`, `bool`, `string` | ✅ works |
| **`long` / `i64`** | 💥 **SIGSEGV** (compiles clean) — exit 139 |
| **`double` / `f64`** | 💥 **SIGSEGV** (compiles clean) |

Only `__i32_to_string` / `__bool_to_string` exist — there is **no `__i64_to_string`, no
`__f64_to_string`**. So printing a `long` or a `double` was *impossible*, and `__i32_to_string` became
the workaround people reached for even where `${n}` already worked. **The ugly name spread because the
pretty one crashed.**

Root cause is this document: an `f64` bit-punned into an integer slot (§2.3) cannot be formatted, and an
`i32` that is secretly 64-bit is exactly why `__i32_to_string` can print 64-bit values at all. **F3 stage
3 (real float storage) + stage 5 (honest widths) are what make `${double}` and `${long}` implementable.**

**The target, per L2 — already designed, do not reinvent it:**

```kyte
// ---- never again ----
console.log("count = " + __i32_to_string(n));   // plumbing in user code
console.log("ratio = " + ???);                  // impossible: no __f64_to_string

// ---- the two layers, and only two ----
console.log(`count = ${n}, ratio = ${ratio}, when = ${ts}`);   // int, double, long — all work
console.log("count = " + n.toString());                         // ToString trait, explicit
```

**Rules this sets:**
- **E1 — `__*_to_string` is compiler-internal.** It may exist as a lowering target; it must be
  **unspellable in user code**. Zero uses in stdlib or corpus.
- **E2 — `${x}` works for every primitive**, or it is a bug. No type may be un-printable.
- **E3 — `as` never stringifies.** `n as string` is a **compile error** directing you to `${n}` /
  `.toString()`. Overloading `as` for rendering conflates *representation* with *presentation* — a
  permanent wart.
- **E4 — One way.** No `text.format`. Template strings cover it; a rival formatting API is exactly the
  "different different things" divergence (§11). Width/precision, if ever wanted, goes **inside** the
  interpolation grammar (`${ratio:0.00}`), not into a second API.

**Sequencing.** L2 (finish `${}`, `ToString`, delete `__*_to_string`) is the **immediate follow-on that
F3 unblocks**, and it is the first thing a web developer will feel. F3 is not "done" in any user-visible
sense until L2 lands on top of it — but it is L2's precondition, not its rival. Deleting the 24 call
sites is L2's work, tracked there.

### 3.3 Representation invariants

The rules F3 establishes. Each is stated so a violation is mechanically detectable:

- **R1 — A declared type determines storage, everywhere.** A local, a param, a return and a struct field
  of type `T` all use `llvmTypeOf(T)`. No universal slot. `val_type` survives **only** as the
  representation of `ptr`, renamed `word_type`.
- **R2 — Same width on every target.** `int` is 32 bits on native and wasm. Only `ptr` is
  target-dependent, and that is its definition.
- **R3 — Floats live in float storage.** An `f64` local is `alloca double`. No bitcast sandwich. The
  bitcast paths at `expressions.zig:562-564,747-770` are deleted, not adjusted.
- **R4 — Signedness is carried, not spelled.** `PrimType` has an explicit `signed: bool`; every compare,
  divide, remainder, and shift-right selects its opcode from that field. `castFromValType`'s
  always-sext (`types.zig:118`) is a bug this makes unrepresentable.
- **R5 — A pointer has type `ptr`.** No pointer is ever stored in a numeric-typed field. Enforced by
  the checker; the 9 sites in §2.4 migrate.
- **R6 — Unknown is not a type.** Inference returns an explicit "unresolved", never `"i32"`. Unresolved
  reaching codegen is a **compiler bug** (assert), not a silent word.

### 3.4 The representation, in code

Replacing 48 `"i32"` literals and 31 `mem.eql` type decisions with one table:

```zig
pub const PrimKind = enum { bool, int, float, ptr, void };

pub const PrimType = struct {
    kind:   PrimKind,
    bits:   u16,      // 1,8,16,32,64,128 — for .ptr: target word size
    signed: bool,     // meaningful for .int

    pub fn llvmType(self: PrimType, c: *Ctx) LLVMTypeRef { ... }
    pub fn sizeBytes(self: PrimType) u32 { ... }   // one definition, used by BOTH locals and fields
};
```

Canonical name → `PrimType` is resolved **once** in F2's name/type resolution, not re-derived at each
use site. After F3, `types.zig` contains a `Type`, not a family of string functions.

**One sizing function.** Today `getTypeSize` (`llvm_codegen.zig:678`) is the only sizer and it is used
for fields only, because locals bypass it. R1 makes it the sizer for both — which is what removes the
locals-vs-fields split in §2.2.

### 3.5 Struct layout becomes explicit

With honest widths, hand-rolled self-aligning offsets (`llvm_codegen.zig:738-756`) become wrong: `int`
(4) followed by `long` (8) needs 4 bytes of padding that the current formula produces only by accident
of every type being 8. Two options:

- **(a) Use `LLVMStructType` + `LLVMOffsetOfElement`** — LLVM computes layout and ABI alignment. Removes
  the hand-rolled arithmetic and the duplicated formula at `:689`/`:712`.
- **(b) Keep hand-rolled, add explicit `align` per `PrimType` and struct-level alignment/tail padding.**

**Recommendation: (a).** It deletes code rather than adding it, and it is the only option that is
correct by construction for `#[repr]`-style control later. Cost: struct field access moves from
`ptrtoint`+offset to `LLVMBuildStructGEP2`, touching `expressions.zig:1759-1765` and the field-store path.
This is the largest single mechanical change in F3 and is staged separately (§5, stage 4).

---

## 4. What this fixes, and what it does not

**Fixes (each currently in specs §10):**
- #2 `${i64}`/`${f64}` SIGSEGV — ✅ **fixed (stage 3, 2026-07-16)** via runtime `kyte_f64_to_string`/`kyte_i64_to_string`; the interpolation path no longer treats a number as a string pointer
- Primitive types **Unsound** → sound: `i32` is 32 bits; `uint` is unsigned (R2, R4)
- native/wasm arithmetic divergence (R2)
- `data: i32` and the 8 pointer-stashing structs (R5 + `ptr`)
- `f32` 🔎 unverified → verified
- **Silent inference failure** (R6) — arguably the highest-value item, because it converts an entire
  class of invisible wrongness into compile errors

**Does NOT fix (stated so nobody assumes it):**
- ARC (F5), generics (F4), name resolution (F1)
- `decimal` and `i128` remain 🔎 unverified — F3 gives them honest storage, not a verified implementation
- Overflow *semantics* (wrap vs trap) — F3 makes width honest; the wrap/trap policy is a separate
  decision that F3 makes **possible** and must be made before `int` narrows (see §6 Q1)

---

## 5. Staging

Each stage lands independently, corpus green, with cases that are **shown to fail beforehand**.

| # | Stage | Content | Guard |
|---|---|---|---|
| 1 | ✅ **`PrimType` table** + retire the 128-bit lies (landed 2026-07-16) | `cgPrim` in `codegen/types.zig` is the codegen source of truth (name → `CgRepr` + signedness); `toLLVMType`/`isPrimitiveTypeName`/`getTypeSize`/`castToValType` consult it. Reproduces today's mapping — **IR byte-identical on all 17 cases** — including `i32`→word (`.word` = `val_type`; sema/lower.zig already carries the honest `int`=32, codegen catches up at stage 5). `i128`/`u128` dropped from the table; `decimal` is a hard type-checker error (`rejectUnimplementedType`), never a silent `i128`. Byte's latent signedness (it sext'd; now honest unsigned) fixed as a side effect, corpus-invisible. | ✅ corpus 29/29 (IR byte-identical); expect_fail `decimal_unimplemented.ky` rejected with a clear message |
| 2 | ✅ **`ptr` type** (landed 2026-07-16); ✅ **stdlib migration DONE** (2026-07-16, see stage 4b) | **Foundation done:** `ptr` is a first-class codegen primitive — `cgPrim` entry `.word`/unsigned, so `isPrimitiveTypeName("ptr")`=true → `isRefCountedType("ptr")`=**false** (a `ptr` local/field is a VALUE, never ARC-released). `renderLegacy .ptr → "ptr"`. Word-sized, additive: **IR byte-identical on all 17 existing cases**. **Stdlib half LANDED as stage 4b** — turned out to be ~40 sites across 25 files (not 9), done compiler-guided (see the stage-4b row) rather than by hand. | ✅ `17_ptr.ky`; corpus 30/30 → 32/32 after 4b |
| 4b | ✅ **stdlib `ptr` migration — compiler-guided** (landed 2026-07-16) | The survey found the "9 sites" were really **~40 address-holding `int`s across 25 files**, and hand-editing would be unverifiable. Instead **enforced ptr-distinctness in the type checker** (int stays 64-bit, so the interim is safe) and fixed the flush: `bytes.alloc`/`new*`/`read_ptr` resolve to `ptr` (from `builtins.zig`); `ptr → i8/i16/i32` is rejected at let/return/**assignment** (incl. constructor `self.field = …`, which needed `self` registered up front) while `int→ptr` (size/offset/null) and `ptr→i64` stay legal; **pointer arithmetic `ptr ± int → ptr`** keeps addresses honest. Fixed sites: `string_builder.buf`, `map.tombstones`+`allocZero`, `array.ptr`, `Allocator.ctx`/`allocFn`/`freeFn`, `Arena.start`/`current`/`end`, `bson` (dual-purpose `int_val→long`, doc/serialize/deserialize pointers), `protocol.buffer`, `Reader.buf`, `atomic.ptr`, and the runtime-handle fields whose externs return real pointers (`file.handle`←`FILE*`, `dir.handle`←`DIR*`, `tls.ctx`←`TlsContext*`, `process.ctx`←`ProcessContext*`, `fs.handle`←`WatcherContext*`); genuine fds (`socket.fd` ← `kyte_socket_connect` returns `int`) correctly LEFT as `int`. **Self-verifying:** a per-module type-check sweep across the whole stdlib is now flush-clean. | ✅ corpus 32/32; new `expect_fail/ptr_truncation.ky` (a `ptr` into an `int` field is rejected — regression guard for the enforcement); full-stdlib flush scan clean |
| 3 | ✅ **`${f64}`/`${i64}` fix** (landed 2026-07-16); ⏳ `alloca double` folded into stage 4 | **Split on investigation:** float _arithmetic_ already works (A4), so the only observable float defect was `${f64}`/`${long}` (§10 #2 SIGSEGV). Fixed with two C runtime helpers `kyte_f64_to_string` (shortest round-trip: 3.0→"3", 2.5→"2.5") / `kyte_i64_to_string`, declared as externs (return `val_type`, the string-as-i64 ABI) and wired into `compileAppendToStringBuilder` (float branch bitcasts the i64 slot bits → double; the temp is released after append, leak-clean). **The pure `alloca double` representation change is coupled with stage 4** — every float load/store/op site shares the honest-slot load/store machinery — and has _no observable benefit alone_ (arith already round-trips through the bitcast sandwich), so it moves to stage 4. ⚠️ Discovered latent bug: `kyte_from_cstr` (used by `kyte_getenv`/`sha256`/`md5`) returns `payload+4`, sliding the refcount onto the size field — ARC-`release` of such a string corrupts size instead of freeing. Not float-related; fix in the runtime pass. | ✅ new case `18_float_interp.ky` (`${double}` whole/fraction/negative, `${double}` from arith, `${float}`, `${long}` > 2³¹); corpus 31/31; ARC-audit clean for the 6 temporaries (only the pre-existing harness self-test survivors remain) |
| 4 | ✅ **`alloca double` — float bitcast sandwich deleted** (landed 2026-07-16); ⏳ narrow-int honest slots folded into stage 5 | **Investigation reshaped this stage.** Struct layout is ALREADY honest — a struct with adjacent `byte`/`byte`/`short`/`int` fields round-trips with no clobbering (packed `getFieldOffset` + honest-width field access via `toLLVMType`/`castFromValType`); converting the byte-buffer structs to `LLVMStructType` is cosmetic (zero observable change), so it is dropped. Narrow-int honest slots (`byte`→`i8`) have NO observable effect while `int` is still 64-bit, so they move to stage 5 where "wraps at N bits" is the real guard. **What landed:** float locals/params get a real `alloca double`; float literals/arith/negation produce and consume real `double`; loads read the honest slot type (`LLVMGetAllocatedType`); `double`↔i64 is reinterpreted ONLY at the uniform i64-ABI edges — param-in, return, call-arg (`buildCallWithCasts`), collection/struct slot (`castFromValType`), phi merges (`if`-expr, `??`). The load/bitcast/op/bitcast/store sandwich is gone: `half(x)` is now `alloca double` → coerce-in → `fdiv double` → coerce-out (2 edge bitcasts, 0 sandwich). Helpers: `slotTypeForLocal`, `coerceToSlotType` (types.zig). | ✅ corpus 31/31; `08_floats` extended (if-expr phi merge, straight-line arith chain); `half()` IR shows `fdiv double` with no bitcast around the op; bitcasts on the case dropped ~20+→8 |
| 5 | 🔨 **Narrow `int` to 32 + real unsigned (R2, R4)** — IN PROGRESS | §6 decided: overflow **wrap** (release; debug-trap later), `int`=32 all targets, widening value-preserving. **Increment 1 LANDED (2026-07-16): honest 32-bit arithmetic.** `.i32` repr split off `.word` (ptr keeps `.word`; `.i32` still lowers to `val_type` so slots/layout are unchanged — behaviour-preserving) + `reprBitWidth`. Integer arithmetic now **canonicalises to its honest width**: add/sub/mul/shl `trunc`→iW→`sext`/`zext` back, so `int` wraps at 2³¹ (and byte@8, short@16) identically on native and wasm; `long` (64) is a no-op. **Real unsigned:** `uint`/`ulong` use `udiv`/`urem`/`lshr` and unsigned compare predicates (operands reduced to zero-extended canonical form first). **Increment 2 LANDED (2026-07-16): literal-range check.** An integer literal (accounting for a leading unary `-`) that does not fit its declared fixed-width int type is a hard error, not a silent wrap — `let n: int = 5000000000` says "use 'long'". `intTypeRange`/`intLiteralValue` in the checker; flush-clean across the stdlib (nothing had out-of-range literals). **Increment 4 LANDED (2026-07-16): honest `int` struct fields (4-byte `i32`).** `llvmForRepr(.i32)`→`i32_type` and `getTypeSize(.i32)`→4 on every target (was `val_type`/8 native — the §7 native-vs-wasm layout divergence, now GONE). Struct/element machinery reads/writes int fields at 32 bits and sext/truncs at the i64 value boundary via `castToValType`/`castFromValType`, exactly as byte/short already did — so it worked with **zero** field-access changes. IR confirms real `i32` field load/store + trunc/sext (verified on `17_ptr`). Note: this is FIELDS/elements only; int LOCAL slots stay i64 (canonical 32-bit values) — the honest-slot pipeline change is a later, orthogonal, pure-cleanliness increment. ⚠️ Diagnosed a PRE-EXISTING crash in `collections.array` (segfaults on mere import — a codegen bug in one of its complex generic fns; crashes identically on the pre-5.4 compiler, so NOT caused by this change; array is never gated by the corpus). | ✅ corpus 35/35; IR shows i32 fields |
**Increment 3 LANDED (2026-07-16): narrowing-cast enforcement.** A narrowing integer conversion (wider→narrower, e.g. `long`→`int`) now needs an explicit `as`; widening (`int`→`long`) stays implicit. `intWidthOf`/`isNarrowingInt` in the checker, wired into `assignable` (let/return) and the assignment path. **Gauge result: ZERO flush** across the whole corpus AND stdlib — `long` usage is well-isolated, nothing implicitly narrows, so this was free. **Increment 5 LANDED (2026-07-16): cross-signedness rule.** A same-width signedness change (`int`↔`uint`, `long`↔`ulong`, …) reinterprets the bits, so it needs an explicit `as` (`isSignednessMismatch` reads the pre-canonical names, since `canonicalizeTypeName` collapses int/uint to `i32`). **Integer LITERALS are exempt** from both narrowing and signedness (they are polymorphic — `let u: uint = 4000000000` is fine, gated only by the range check); wired through let/return/assignment. **Remaining:** honest i32 LOCAL slots (fields already done in inc 4; locals are pure §7 cleanliness, no observable change); debug-trap. | ✅ `19_int_overflow.ky` + `expect_fail/{int_literal_overflow,narrowing_int,signedness_mismatch}.ky`; corpus 37/37 |
| 5a | **`decimal` for real** (optional; gated on BSON) | IEEE decimal128 as a 16-byte value type; runtime lib chosen (§3.2a.1); `+`/`-`/`*`/`/`/compare lowered to runtime calls; literal syntax + parse/format. **Requires stage 4.** | new cases: `0.1 + 0.2 == 0.3` **exactly**; 34-digit round-trip; BSON `0x13` byte-for-byte round-trip |
| 6 | 🔨 **Stdlib annotation sweep — IN PROGRESS** | Widen `int`→`long` where a value genuinely needs 64 bits (semantic, not compiler-flushed). **Batch 1 landed (2026-07-16):** `stopwatch` (was SECONDS in int — 1s resolution, overflowed ×1000 after ~25 days; now nanoseconds in `long` via `nowNs()`); `io/file.seek`(offset)/`tell` → `long` + the codegen decls for `kyte_file_seek`/`kyte_file_tell` (were i32, truncating >2GB offsets — C is `long`); btree `protocol.readU64`/`writeStructU64` now read/write the **full 64-bit word** (`read_ptr`/`write_ptr`) instead of truncating the high 32 bits, and `session_id`/`payload_len`/`rows_affected` fields → `long`. **Remaining:** datetime seconds params (Y2038, fits until then); web session/rate-limit/request counters + timestamps; Content-Length >2GB. Two pre-existing codegen bugs surfaced (both unrelated to §6, in never-gated modules): `io.file` `FieldAccessObjectNotStruct`, `driver`/`client` `MethodOrFunctionNotFound`; and `fiber.sleep` corrupts execution in a @test context. | corpus 37/37; `stopwatch` test green (ns resolution via busy-loop, `long` return); protocol compiles clean |
| 7 | **R6: unresolved is not `i32`** | Remove every `orelse "i32"`; unresolved becomes an error/assert. | expect_fail cases |

**Ordering is load-bearing:** stage 2 (`ptr`) **must** precede stage 5 (`int`→32). Reversed, every
pointer in the stdlib silently truncates on native and the failure mode is heap corruption — the exact
class of bug this program exists to end.

Stages 1–4 are behaviour-preserving; stage 5 is the breaking change; stage 6 is fallout. If the program
is ever paused, **pause between 4 and 5**, never inside 5.

---

## 6. Open questions — decide before stage 5

**DECIDED 2026-07-16 (user):**
1. ✅ **Overflow policy = trap in debug, wrap in release**, with explicit `+%`/`-%`/`*%` wrapping ops.
   *Implementation staging:* land **wrap semantics first** (arithmetic in i32 — the release behaviour, and
   what a 32-bit `int` observably IS); the debug-trap needs a debug/release build distinction Kyte does not
   have yet, so it is a follow-up on top of wrap, NOT a blocker for the narrowing. Wrapping operators are
   deferred to when a real use needs them.
2. ✅ **`int` = 32 on every target** (native AND wasm — fixes the current divergence where `.word` is i64
   native / i32 wasm). Confirmed by the user 2026-07-16; matches C#/Java/TS.
3. ✅ **Implicit widening = value-preserving only.** `int`→`long`, `byte`→`int` etc. are implicit; any
   NARROWING (`long`→`int`, or a literal that does not fit) needs an explicit `as`. **Never implicit across
   signedness** (`int`↔`uint` needs a cast). Enforced in the type checker alongside the ptr-truncation rule.
4. ~~**`decimal` / `i128`.**~~ **DECIDED 2026-07-15** (§3.2a): `i128`/`u128` removed; `decimal` kept as
   **IEEE 754-2008 decimal128** because BSON's `decimal128` is that format — not .NET's `System.Decimal`,
   which cannot round-trip it. Hard compile error until stage 5a implements it. Remaining sub-question:
   **which runtime library** (libbid vs libdecnumber vs own subset) — decide before 5a, not now.
5. **wasm `ptr`.** 32-bit `ptr` on wasm vs 64-bit native means `ptr.addr()` returns `long` on both — a
   `ptr` must never be assumed to fit an `int`.

---

## 7. Done criteria

- [ ] No `val_type` outside `ptr`'s representation (`word_type`). The 48 `"i32"` literals are gone.
- [ ] `PrimType` is the single source of width/signedness/size; one sizing function for locals *and* fields.
- [ ] `int` is 32-bit and **identical on native and wasm**, pinned by a parity case.
- [ ] `uint`/`ulong` use unsigned opcodes, pinned by a case that fails under sext.
- [x] `${f64}` / `${long}` case green (closes §10 #2) — `18_float_interp.ky`, 2026-07-16.
- [ ] `f64`/`f32` in real float storage (`alloca double`) — folded into stage 4.
- [ ] Zero pointers in numeric fields; all 9 sites on `ptr`; enforced by the checker.
- [ ] Zero `orelse "i32"` fallbacks; unresolved is an error.
- [ ] `i128`/`u128` removed. `decimal` is either a hard compile error or a real IEEE decimal128 —
      **never an `i128`**.
- [ ] If stage 5a landed: `0.1 + 0.2 == 0.3` is **true**; 34 significant digits round-trip; a BSON
      `decimal128` (`0x13`) round-trips **byte-for-byte** with no conversion.
- [ ] Stdlib migrated: `: i32` count → 0 except deliberate fixed-width FFI use.
- [ ] specs §3.1 rewritten: the 💥 "widths do not mean what they say" box is **deleted**, and the grades
      table's *Primitive types = Unsound* becomes Sound.
