# REPRO: `Map` SIGBUS on resize — ✅ FIXED 2026-07-15

> **RESOLVED.** Root cause was spec §10 #18 (bare fn value called as a closure box), not Map.
> Fix landed in `expressions.zig:buildBareFnBox` + the direct-field-call path in `llvm_codegen.zig`;
> see **The fix (as applied)** below. Regression-pinned by `conformance/cases/14_collections_map.ky`
> (verified to fail before the fix, at `test_map_resize_survives`). The repro below now prints
> `size=20`, exit 0. Kept as the record of the investigation.

**Map worked only until it grew.** This was spec §10 #16. Map is fundamental (web headers, serde objects,
sessions), and there were **zero Map conformance cases** — which is exactly why this survived.

## Reproduce

```kyte
import collections.map;
import string;
fn main(): void {
    let m = map.Map<string, i32>(16, string.hash);
    var i = 0;
    while (i < 20) { m.set("k" + __i32_to_string(i), i); i = i + 1; }
    console.log("size=" + __i32_to_string(m.size()));
}
```
```
kyte /tmp/mt.ky --native -o /tmp/mt && /tmp/mt     # -> exit 138 (SIGBUS), no output
```

## Measured behaviour — it is RESIZE, not volume

| cap | inserts | result |
|---|---|---|
| 16 | 20 | 💥 SIGBUS (20 > 16 → resize) |
| 256 | 20 | ✅ **ok, exit 0** (no resize) |
| 256 | 200 | 💥 SIGBUS (200 > ~0.75*256=192 → resize) |
| any | 1 (single set+get) | ✅ ok |

**Workaround for callers:** pre-size the Map above the expected maximum.

⚠️ **Corrects an older note** which claimed "crashes at ~60 inserts, NOT resize-specific". It **is**
resize — `cap=256`+20 inserts is clean.

## Hypotheses ELIMINATED — do not re-chase

1. **`alloc_persistent` + `bytes.free` mismatch** (the long-standing theory: "allocZero uses the codegen
   bump allocator but resize frees it") — **NO.** In the C++ runtime `kyte_bytes_alloc_persistent` is
   plain `std::malloc(size + HEADER)` (`alloc.cpp:95`) and `kyte_bytes_free` does
   `std::free(ptr - HEADER)` after an arena check (`alloc.cpp:105`). malloc'd memory freed by free —
   correct. (The bump allocator is **wasm-only**; native declares these extern.)
2. **`allocZero` not zeroing** — **NO.** `map.ky:10-18` explicitly writes 0 over every byte
   (`malloc` doesn't zero, but allocZero does).
3. **`bytes.ptr_size()` wrong** — **NO.** Returns **8** natively; `write_ptr`/`read_ptr` round-trip
   64-bit values correctly at 0 and 8.
4. **`let i = 0` then `i = i + 1`** (map.ky:12/216 mutate a `let`, same wart as `string.slice`) —
   **NO.** Verified `let`-mutation compiles and increments correctly.

## ✅ ROOT CAUSE FOUND (ASAN, 2026-07-15) — a bare fn value is called as a closure box

```
==29653==ERROR: AddressSanitizer: BUS on unknown address (pc 0xf90017e0d100c3ff bp ... )
    #0 0xf90017e0d100c3ff  (<unknown module>)
 x[8] = 0xf90017e0d100c3ff
```

**The PC itself is garbage** — this is **not** a bad data read, it is a **jump through a corrupted
function pointer** (`blr x8` on ARM64, x8 == pc == garbage). And the garbage is diagnostic:
**`0xf9…` is the ARM64 load/store opcode prefix** — i.e. we **loaded instruction bytes and called them
as an address**.

**Therefore:** `hashFn` holds a **bare function** value (`string.hash` = a raw *code* pointer), but the
indirect call at `map.ky:223` uses the **closure-box** convention — box = `{fn_ptr, env}`, so it does
`fn_ptr = load [box+0]` / `env = load [box+8]` and calls `fn_ptr(env, …)`. Loading `[box+0]` off a
**code** address reads `string.hash`'s own first instruction (`0xf9…`) as the target → `blr` into
hyperspace → BUS.

**Confirmed from both sides:**
- bare fn (`string.hash`) → **exit 138** every time.
- lambda (`(s: string) => string.hash(s)`) — the boxed form that *would* work — **does not even parse**
  in an argument position (`Expect failed: expected=.right_paren, got=.colon`). So **every Map in the
  tree necessarily passes a bare fn**, i.e. the broken path is the only reachable one. *(This also
  corrects the old note "crashes with a lambda hashFn too" — that lambda can't have compiled.)*

**Why `set` works but `resize` doesn't:** `resize` copies the field into a local first
(`let oldHashFn = self.hashFn;` then `(oldHashFn)(key)`), whereas `set` calls the field directly. The
direct field-call path evidently keeps the bare-fn calling convention; the through-a-local path takes
the closure-box path. **That divergence is the bug.**

### The fix (as applied, 2026-07-15)

**Uniform representation — box bare function references when they are used as a value.** Lambdas already
box (A1), so this closes the gap rather than adding a second rule.

⚠️ **`{fn_ptr, env=0}` alone is NOT enough** — the plan as originally written would still have been
broken, just differently. A boxed call does `fn_ptr(env, args…)`: **env is a hidden leading argument**.
A lambda is compiled with that leading `__env` param (`llvm_codegen.zig:1602`), but a **bare fn is not** —
`string.hash` is `fn(s)`, not `fn(env, s)`. Boxing its raw pointer would shift every argument by one
(`env=0` lands in `s`, the real key lands in a param that doesn't exist). Trades a SIGBUS for silent
argument corruption.

**So the bare fn is wrapped in a thunk** that absorbs env and forwards the rest:

```llvm
define internal i64 @__fnbox_thunk_double(i64 %0, i64 %1) {   ; %0 = env, dropped
  %calltmp = call i64 @double(i64 %1)
  ret i64 %calltmp
}
@__fnbox_double = internal constant [2 x i64] [i64 ptrtoint (ptr @__fnbox_thunk_double to i64), i64 0]
```

Applied:
1. **`expressions.zig:buildBareFnBox`** — builds the thunk (arity read off the target's LLVM type;
   `buildCallWithCasts` adapts arg/return types and `void`→0) and a module-level **constant** box.
   Constant, not heap: a bare fn captures nothing, so there is no per-instance state — no alloc, and no
   contribution to the closure-env leak (§10 #15).
2. **Both fn-value sites now box** — `expressions.zig` `.ident` (`let f = double;`) and `.field_access`
   (`string.hash` as a value).
3. **`llvm_codegen.zig` direct-field-call** — was the *second* convention (called the field as a raw code
   pointer); now unpacks the box via `buildClosureCall` like every other call site. **This is what
   removes the divergence** — deleting one of the two conventions was the actual point.

**One box per target, cached** (`fn_box_globals`), which preserves fn-value **identity**: `string.hash`
evaluates to the same address everywhere, so `map.ky:50`'s `self.hashFn == string.hash` — which selects
string comparison in `keysEqual` — keeps working. A per-evaluation heap box would have silently broken it.

**Not affected:** `protocol.callDecoder`'s raw fn pointer (built directly at `expressions.zig:2142`, never
flows through the ident/field-access value paths) and trait vtables (raw ptrs, separate mechanism).

**Landed with:** `conformance/cases/14_collections_map.ky` — 15 tests: resize survival, all-keys-survive
across cap 4→256, delete/tombstone churn, keys/values, plus four pinning the #18 convention itself
(field-vs-local agreement, bare fn through a local, fn-value identity, multi-arg). Verified to **fail**
without the fix (`test_map_resize_survives`, abnormal termination) — a case that passes before and after
would guard nothing.

**Still open next to it:** typed lambda params don't parse in an argument position (§10 #19) — a parser
bug, no longer load-bearing now that bare fns are safe to pass.

## Superseded suspects (kept for the record)

1. **The indirect `(oldHashFn)(key)` call at `map.ky:223`.** `hashFn` is a *stored* function value.
   Closures are a heap box `{fn_ptr, env}` with a hidden leading `env` param, but `string.hash` is a
   **bare fn**. If the stored-bare-fn call convention differs from the closure-box one, resize calls it
   wrong → garbage → SIGBUS. **Note the old finding "crashes with a lambda hashFn too" — worth
   re-verifying now that A1 landed real closure envs.** The `set` path also calls `hashFn`, and `set`
   works — so if this is it, the difference must be *where/how* it is called in resize.
2. **The rehash probe loop (`map.ky:225-237`)** — `while (true)` with no bound. If no empty slot is
   ever seen it spins forever; that is a hang, not a SIGBUS, but a mis-sized buffer would give OOB
   writes → SIGBUS. Check `newCap * ps` sizing vs the `idx * ps` strides.
3. **`hash & (newCap - 1)` (`map.ky:224`)** with a negative hash from `string.hash`.
4. **`LOAD_FACTOR_MAX: f32 = 0.75`** — an **f32**, and spec §3.1 marks `f32` 🔎 unverified; every local
   is an i64 slot with floats bit-punned (§3.1). A wrong resize trigger wouldn't SIGBUS by itself, but
   the f32 compare is worth printing.

## Next step

Run it under the ASAN harness (recipe in `driver_alloc_churn_crash.ky`) — that named the string bug's
faulting frame in one shot and should do the same here:

```
KYTE_KEEP_OBJ=1 kyte /tmp/mt.ky --native -o /tmp/mt
clang++ -std=c++20 -g -O0 -fsanitize=address -pthread /tmp/mt.o \
  /tmp/asan/kyte_runtime_asan.o -L/opt/homebrew/lib deps/wolfssl/build/libwolfssl.a \
  -framework CoreFoundation -framework Security -o /tmp/mt_asan
ASAN_OPTIONS=detect_leaks=0 /tmp/mt_asan
```

**Land the fix WITH the first Map conformance case** (`conformance/cases/14_collections_map.ky`):
grow past resize, verify every key survives, plus delete/tombstone churn. No case ⇒ unverified by
construction (specs.md §13) — that is how this bug lived this long.
