# P7 — Sound per-request arena via compiler escape analysis

## Why

A `sample` of the pizza web app under load (byte-matched 194 KB `/products`, fused Level-B binder,
2026-08-12) shows the request is dominated by allocation churn, NOT decode or bind:

| bucket | ~samples |
|---|---|
| `nova_release` + `nova_retain` (ARC) | ~1044 |
| malloc / free / memmove / memset | ~1500 |
| socket write (190 KB body) + read + kevent | ~850 |
| HTML escape of the 190 KB body | ~226 |
| driver decode (`decodeDataRow`) | 167 |
| DbValue array (dbLazy + push + destruct) | ~110 |
| `ProductView__bindAll` (the bind itself) | 20 |

The bind is free; the DbValue array is small. The lever is the ARC + malloc buckets (~2500 samples), i.e.
**per-request allocation churn**. A per-request bump arena that reclaims in O(1) at request end removes it.

## What was already tried and why it failed (do NOT repeat)

The BLANKET async arena (`NOVA_REQUEST_ARENA`, region live across the whole request, hand-guarded escapes)
was fully attempted and ROLLED BACK (see [[nova-p7-request-arena-infra]]): it became correct but ~28%
SLOWER (range-check keeps every chunk mapped → 6-10x working set, cache thrash) and leaked RSS to
3.5-8.3 GB. Root cause is structural: **ARC follows pointers across the region boundary**, so freeing the
arena decrements persistent strings the arena borrowed (UAF), and hand-guarding every crossing does not
converge. The runtime region primitives survive (`nova_region_new/set/free/gen`, `region_alloc`,
`nova_web_region_enter/exit`, the gen-validated per-coro region swap in `concurrency.cpp`); what was removed
is the stdlib wiring and the escape pass.

## The sound approach

Region-allocate (and ARC-elide) ONLY objects the compiler PROVES are request-local; leave every possibly
-escaping object on the ARC heap. Then freeing the region at request end can never dangle a live pointer,
because nothing live points into it. Soundness rule: **default = ESCAPES**; an allocation is `LOCAL` only
when proven so. A wrong `LOCAL` is a UAF, so the analysis must be conservative and ASAN is the authority.

### Escape definition (per allocation site)

An owned heap allocation ESCAPES its enclosing function when its pointer can be reached after the function
returns. Sources:
1. It is the return value (or reachable from it).
2. It is stored into a field of a non-local object (`obj.f = a` where `obj` escapes / is `self` / global).
3. It is passed as an argument to a call whose summary lets that parameter escape (interprocedural).
4. It is captured by a closure that escapes.
5. It flows into another escaping local (`b = a; <b escapes>`).

Request-local = does not escape the handler's dynamic extent. Because the handler is the request root, an
allocation that does not escape ANY frame up to the handler is request-local. Interprocedural summaries
(`param i escapes` / `return aliases param i` / `return is fresh-local`) let callee allocations be judged at
the call site.

## Staged plan (each stage independently verifiable; ASAN is the gate)

- **Stage 1 — escape gauge (REPORT-ONLY, no behaviour change). ← this change.**
  New `src/sema/escape.zig`: for every owned allocation site (an expr with `ir.expr_owned == true` bound to
  a local, plus struct/list/map/set/string-concat), classify `LOCAL` vs `ESCAPES` intraprocedurally with a
  simple fixpoint over local dataflow (return / field-store / call-arg / closure-capture / alias). Print
  per-program counts behind `NOVA_ESCAPE_REPORT`. Corpus stays green (nothing generated differs). Validates
  the classifier and quantifies the opportunity (how many alloc sites on the pizza request path are LOCAL).

- **Stage 2 — interprocedural summaries.** Compute per-function `{param escapes?, return fresh?}` summaries
  to a fixpoint over the call graph; refine call-arg escape from `ESCAPES` (conservative) to the summary.
  Still report-only. Re-validate counts.

- **Stage 3 — ARC-elision of proven-LOCAL.** For a `LOCAL` allocation with a strictly-nested lifetime, drop
  its `retain`/`release` pair (they net to a scope-end free). Strictly safe subset first (single-owner, no
  container insertion). Gate `NOVA_ESCAPE_ELIDE`; validate under `--asan` on the pizza app at c=50 AND full
  corpus; measure. This alone captures part of the `nova_release` bucket with NO region (no free-time UAF
  class).

- **Stage 4 — region-alloc proven-LOCAL + barrier.** Route proven-LOCAL allocations to the per-request
  region (`nova_web_region_enter/exit` in the serve loop) and add a barrier: a store of a region pointer into
  a persistent object is a compile error (the analysis proves it cannot happen, so the barrier only guards
  bugs). `inRoot(body)` for the few persistent per-query allocs (pg read-buffer growth, stmt cache). Free the
  region strictly AFTER the response is written. Validate `--asan` c=50 + corpus; measure RSS + rps.

- **Stage 5 — measure end-to-end.** Target: recover the ARC+malloc buckets → ~3200+ rps consistently on this
  box (the profile's headroom), RSS flat (~37 MB), byte 194739, 100% success, corpus + ASAN green.

## Gauges

- `NOVA_ESCAPE_REPORT` — Stage 1/2 per-program classification counts (report-only).
- `NOVA_ESCAPE_ELIDE` — Stage 3 opt-in ARC-elision.
- `NOVA_REQUEST_ARENA` — Stage 4 opt-in region routing (replaces the old blanket flag; now analysis-driven).
- `--asan` on the real app under load is the soundness authority throughout.
