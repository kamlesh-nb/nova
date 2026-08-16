# Gap 5 — per-request allocation reduction (ACTIVE, 2026-08-16)

Reopened after a premature "accept" close. The standing decision: beating Rust/Go per core is NOT a stop
condition — where there is safe, measured scope to cut allocations, take it. This is targeted, low-risk,
measure-first work (the opposite of the P7 blanket arena, which regressed 28% and stays scrapped, and of
Gap 3's ARC-forwarding, which measured 0 headroom).

## The measurement harness (built this cycle)
`src/runtime/alloc.cpp`: a cumulative `g_alloc_total` counts every `nova_bytes_alloc` (each object birth —
the churn that costs a header write + ARC retain/release traffic + cache pressure, even though Nova
bump-allocates small objects in a thread-local arena so the malloc cost is already low).
- `NOVA_ALLOC_COUNT=1 nova test <file>` prints total births at exit.
- `nova_alloc_total()` (extern C) reads the counter — call it before/after a loop to isolate a hot region.
- Method: run the same op at two loop counts N1 < N2; per-op allocations ≈ (births(N2) − births(N1)) / (N2−N1).

## Measured allocation profile (fresh, 2026-08-16)
| Path | allocations / op | verdict |
|---|---|---|
| `Map<int,int>.set` | ~0 (only occasional resize) | collections already allocation-lean for primitive keys |
| string `s = s + "x"` in a loop | ~1 | inherent to immutable strings; `string_builder` is the remedy |
| **JSON parse+bind (nested Order)** | **114 → 58 after fix below** | the real per-request hotspot |

Takeaway: Nova's collections do not allocate per element; the churn is in serde/JSON (node trees) and, to a
lesser degree, string building. The per-request hotspot is JSON, not the language primitives.

## Win #1 — lazy JsonValue arr/obj (114 → 58 allocs/parse, 49%)
`serde/json.nova`'s `JsonValue` init used to eagerly allocate BOTH a `List` and a `Map(8)` (+ its backing)
on EVERY node — including scalars (null/bool/number/string) that never use them, and array/object nodes
whose factories immediately overwrote them (double waste). Fix: make `arr`/`obj` optional, allocate them
only for kind-4 (array) and kind-5 (object) nodes; all accesses are already kind-guarded, routed through
`arrOf`/`objOf` narrow-check helpers (no fallback allocation on the hot path). Result on the nested Order
parse+bind: **114 → 58 allocations/op**. Correctness: all 6 serde/json corpus cases green
(13/160/159/176/162/170). Safety: ASAN clean, ARC audit clean.

## Method / discipline (for every further reduction)
1. Isolate the op with the harness (two loop counts) → a per-op allocation number.
2. Root-cause the allocations (read the hot code; look for eager/unused allocations, per-element boxing,
   intermediate containers).
3. Fix; RE-MEASURE the delta; verify correctness (relevant corpus cases) + ASAN + ARC audit. No claim
   without the before/after number.

## Candidate next reductions (measure before committing to any)
- **serde bind path** — after JSON builds the node tree, `<S>__bind` copies fields into the struct; check
  whether bind allocates intermediate boxes / value-optionals per field.
- **`?? JsonValue(0)` fallbacks** — pervasive in json.nova; if Nova evaluates `??` eagerly, each allocates a
  throwaway node. Measure; if eager, hoist a shared empty or restructure the guards.
- **Number nodes store `num` as a string** (`number(val)` does `i64ToString`) — a string allocation per
  numeric value; a numeric node could hold the parsed value directly.
- **Web/HTTP request path** — per-request temporaries in the parser + response building (needs a live
  request workload to attribute; the harness's `nova_alloc_total()` FFI can bracket a request).

## Standing rule
Same as Gap 3: no allocation rework lands without (1) a per-op measurement showing the waste and (2) a
measured delta after the fix, with correctness + ASAN green. Motion is not progress without the number.
