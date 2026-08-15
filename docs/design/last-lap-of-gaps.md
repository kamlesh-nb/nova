# Last lap of gaps

This is the final gap register for Nova before a go-or-scrap decision. It lists every gap behind the honest
percentage report, and for each one a design to close it. Each gap has a deep, code-grounded analysis in
`lastlap/gapN-*.md`; this file is the map, the summary, the dependency matrix, and the honest overall read.

## The honesty contract for this document

Because completion claims in this project were repeatedly inflated, every statement here is tagged by how much
it can be trusted:

- **PROVEN** - verified against the real code or by a command whose output I can show. The gap being real, and
  the root cause, are always in this category.
- **PLAN** - a design grounded in the real code, but a design is not a proof. It is only verified when built
  and gated. Every design carries a confidence level and its unknowns.
- **GUESS** - effort and risk numbers. Engineering estimates, not measurements. Labelled as guesses.

Nothing here is called "done." Done is what *you* verify after it exists, using the command in each gap's
"Verify" line.

## Scope decisions (recorded 2026-08-15)

- **DECISION: Road B chosen (full vision), WASM dropped, debugger IN.** Execution is incremental: one gap item closed to zero and verified at a time, no "done" until the verify command passes. Sequence by priority + the dependency matrix (crash fix, then soundness + stdlib in parallel, then debugger + tooling, then the optimiser rearchitecture, then ecosystem).

- **Debugger: IN SCOPE, via lldb, no bespoke debugger.** We will emit DWARF debug info from codegen (LLVM
  DIBuilder) so lldb works at source level. Honest caveat: the compiler emits NO debug info today, so lldb is
  assembly-level only until this lands. Scope of the item: line tables + subprograms + backtraces first (the
  "beta-adequate" cut = source-level stepping and stack traces in lldb), then local-variable locations as a
  follow-on (ARC and coroutine-split frames make the variable side genuinely hard). Effort GUESS: ~2-3 weeks
  for the first cut, more for variable inspection. It is independent of the other gaps, so it can run in
  parallel.
- **WASM: dropped, not a priority.** Removed from scope. Native + cross-compile (~90%, verified) stays; the
  WASM host-ABI work (weeks-plus) is out. Gap 7 therefore reduces to the days-scale Windows test-gate wiring,
  and even that is optional.

## What the verification changed about the percentage report

Six agents each built or read the real code to prove their gap. The result corrected my earlier percentage
guesses in both directions, which is the point of verifying instead of asserting:

- **Soundness (I guessed the correctness drag was the root cause): too pessimistic.** The corruption-class
  soundness gap is *not live*. The `NOVA_SEMA_SHADOW` gate shows 0 disagreements on the ownership guard cases.
  What remains is name-based dispatch/mangling cleanup whose failure mode is a loud link error, not silent
  corruption. (gap1)
- **Stability (I guessed ~50%, "you can hit bugs"): too pessimistic.** An empirical hunt of 49 realistic
  feature-combination programs found 47 ran correctly under ASAN and exactly 1 genuine crash, a single known
  class (generic struct method through a trait vtable). Everyday paths are solid. (gap2)
- **Optimiser (I guessed ~40%): confirmed, and if anything generous.** Real per-function emit coverage on
  ordinary Nova is ~10-12%; the perf goal is ~0% realised. (gap3)
- **Stdlib (~70%): confirmed** - deep on the spine, thin at the leaves, the real risk is test coverage. (gap8)
- **Cross-platform (~70%): native + cross is closer to ~90%, WASM is the real best-effort gap.** (gap7)
- **Tooling/ecosystem: confirmed rough** - a good LSP and formatter, a placeholder package manager, no
  debugger, and a broad-but-unhardened ecosystem. (gap56)

The corrected honest overall is not far from before, but the *shape* is different from what I claimed for
months: **the core (compiler correctness, stability, soundness) is more solid than reported; the drag is the
optimiser perf story, the debugger/package-manager, WASM, and stdlib depth.** The beta line is weeks away; the
full-vision line (perf-positive optimiser, mature ecosystem) is months.

## The gaps at a glance

Severity is "how much this blocks a usable, buildable-on beta," not how much work it is.

| # | Gap | Beta severity | Verified state | Effort to close (GUESS) | Detail |
|---|---|---|---|---|---|
| 1 | Soundness name-layer cleanup | Low | Corruption closed (0 shadow disagreements); ~150 name-based mangling sites remain, fail loudly | 1-2 weeks | [gap1](lastlap/gap1-soundness.md) |
| 2 | Crash surface / stability | **High (but small)** | Track 1 (the 1 known crash) FIXED (5bcebd1, case 364, corpus 373/374); Track 2 dogfood harness DONE (b9b9299, 44 programs green, in gate.sh). Note: a standing net, not a proof of zero crashes | both tracks DONE | [gap2](lastlap/gap2-crashes.md) |
| 3 | Optimiser completion (perf) | Low for beta, High for the vision | ~40% of goal, ~10-12% real coverage, perf ~0% realised | months (rearchitecture) | [gap3](lastlap/gap3-optimiser.md) |
| 5 | Tooling (LSP/fmt/pkg/debugger) | Medium | LSP + fmt real; package manager a git-clone stub; no debugger | days (LSP/fmt) to large (debugger) | [gap56](lastlap/gap56-tooling-ecosystem.md) |
| 6 | Ecosystem (drivers/web/orch/DB) | Medium | Broad, single-request-proven, integration + robustness unhardened | weeks+ (separate repos) | [gap56](lastlap/gap56-tooling-ecosystem.md) |
| 7 | Cross-platform (Windows gates only; WASM DROPPED) | Low | Native+cross ~90% verified; WASM out of scope by decision | days (Windows test gates, optional) | [gap7](lastlap/gap7-crossplatform.md) |
| 8 | Stdlib depth (coverage/leaves) | Medium | PARTIAL. DONE: list/map/string convenience (b623fe9, 365/366/367); math leaves asin/acos/sinh/cosh/tanh/gcd/lcm (f2f0ec5, 368); crypto KATs md5+chacha20poly1305+hkdf+pbkdf2 (1bb7878, 369/370); url encode/decode already present. REMAINING: broad per-module @test coverage (~34/144 files carry @tests) — a long-tail sweep, not a bounded fix | leaves DONE; coverage-sweep is open-ended | [gap8](lastlap/gap8-stdlib.md) |

## The gaps in one paragraph each (design summary; full design in the detail files)

**Gap 1 - soundness name-layer cleanup.** PROVEN not a live corruption hole (0 shadow disagreements). The
residue is the vestigial "string engine": one string-only ownership-decision function confined to DCE-dropped
erased bodies, plus ~74 `resolveExpressionTypeName` and ~76 `typeRefToString` sites that are TypeId-first or
name-mangling-only. PLAN (confidence medium): migrate the remaining decision sites to TypeId predicates and
delete the string engine + shadow scaffolding; the hard part is threading the instantiation context through
the two divergence cases (292/341). Verify: `NOVA_SEMA_SHADOW` corpus-wide 0 disagreements + `--asan` green.

**Gap 2 - crash surface.** PROVEN small: 47/48 clean, one crash class. The crash is a generic struct's method
dispatched through a trait vtable using its `T`-typed field concretely, because `getGlobalVTable`/
`constructTraitObject` share one `T`-erased vtable per base struct (`llvm_codegen.zig`; known limitation in
case 299). PLAN: Track 1 fix that one class (confidence high on diagnosis, medium on effort - the unknown is
mono-body emission order); Track 2 add a standing dogfood harness of realistic programs to `gate.sh` under
ASAN, bar 100% green. Verify: the crash repro runs clean + the harness is green.

**Gap 3 - optimiser completion.** PROVEN ~40%. Two structural blockers, both proven from code: (A) no
whole-program MIR (the emit path lowers one function at a time), which gates closures and inlining and thus
the perf win; (B) no box-shaped MIR ops, which gates value-optionals, error-unions, try/errdefer, and async.
PLAN, ordered and honestly sized: enable inline (days), whole-program MIR + closures (weeks, rearchitecture),
value-optional box (weeks), error-union + try (weeks), async coroutines (multi-week, highest risk, cannot fall
back gracefully), then the default-on flip (days, gated on coverage). This is the single largest body of work
and it is months. Verify: emit corpus byte-identical to AST + ASAN, then the default-on corpus staying green.

**Gap 5 - tooling.** PROVEN: the LSP (`nls`, 13 handlers, real type-checker diagnostics) and formatter are
genuinely built; the package manager is a 179-line git-clone with no versioning or lockfile; there is no
debugger and no debug-info emission. PLAN: LSP workspace index for cross-file features (medium); formatter
idempotency + stress corpus (high confidence, low risk); a real package manager with versions + lockfile
(medium, real design work); a debugger via LLVM DIBuilder DWARF for line-level stepping + backtraces first,
variable inspection later (large, and ARC/coroutine frames make it hard). Verify: per-feature, the LSP request
returns correct spans on a multi-file project; `lldb` breaks and backtraces on a built binary.

**Gap 6 - ecosystem.** PROVEN broad but unhardened: real DB drivers (single-request-proven), a surprisingly
broad web framework in std, an orchestrator in active flux (Tier 1 rolling/readiness/drain/backpressure
against `acceptance/slice.sh`), and NovaDB (~60k Zig lines, a separate project whose integration is the soft
edge). PLAN is HIGH-LEVEL only here because these are separate repos with their own design docs (drivers,
`packages/nova-orchestrator`, `PLATFORM-PLAN.md`, `novadb/`); deep design needs a pass inside each. Verify:
`acceptance/slice.sh` 7/7 for the web-app-on-NovaDB slice; the driver multi-connection/pool robustness under
load.

**Gap 7 - cross-platform.** PROVEN: all four emit paths (macOS Mach-O ran, Windows PE32+, static Linux ELF,
valid WASM) verified here; native + cross is ~90% solid. WASM is genuinely best-effort: 68% of the corpus is
outside its baseline, no coroutine runtime, no I/O host ABI. Windows `--asan`/`--arc` are unwired and the
referenced baseline file is absent. PLAN: ship the Windows baseline + wire Windows sanitizers (days), a real
WASM host path via WASI imports (days-weeks) with async-on-wasm being a separate weeks+ effort. Verify: the
corpus green on each host; `run.sh --wasm` if/when a WASM host exists. Note: two CLAUDE.md "still open" notes
were found stale (Linux epoll driver and IOCP readiness are done).

**Gap 8 - stdlib depth.** PROVEN: 144 files, only 13 TODO/stub markers (none a missing core feature), deep on
the load-bearing spine (string/list/json/crypto->TLS/web, all dogfooded), thin at the leaves. The real risk is
test coverage: 34/144 files have their own `@test`, and crypto primitives have no known-answer vectors. PLAN:
add the missing convenience methods with tests (list `flatMap/zip/chunk`, map `clear/entries`, string
`padStart/repeat`, days), crypto KAT vectors (days, plus unknown remediation if a primitive is wrong), and a
`@test` on every public module (1-1.5 weeks). Verify: every public module has API-exercising `@test`; 0
TODO/unimplemented in core; crypto KATs pass.

## Dependency matrix

The single most useful honest finding: **the gaps are mostly independent.** The only hard dependency chain is
*inside* the optimiser (gap 3). Everything else can be picked in any order, so sequencing is a priority
decision, not a blocking one.

Reading: a row DEPENDS ON a column (row cannot sensibly start until the column is done). `-` none, `soft`
better-after, `HARD` cannot start before.

| Depends on -> | G1 sound | G2 crash | G3 opt | G5 tool | G6 eco | G7 xplat | G8 std |
|---|---|---|---|---|---|---|---|
| **G1 soundness** | - | - | - | - | - | - | - |
| **G2 crash-fix** | - | - | - | - | - | - | - |
| **G3 optimiser default-on** | soft | - | (internal chain) | - | - | - | - |
| **G5 tooling** | - | - | - | - | - | - | - |
| **G6 ecosystem** | - | soft | - | - | - | - | soft |
| **G7 cross-platform** | - | - | - | - | - | - | - |
| **G8 stdlib** | - | - | - | - | - | - | - |

The only non-`-` cells:

- **G3 default-on flip depends softly on G1** - you want the type-decision layer clean before you trust the
  optimiser enough to make it the default backend. Not a hard block; the emit path is safe-fallback regardless.
- **G6 depends softly on G2 and G8** - a robust ecosystem wants the crash class fixed and the stdlib it uses
  hardened, but it can proceed in parallel.

The chain that IS hard, entirely inside gap 3:

```
enable-inline (days) ----\
whole-program MIR (weeks) --> closures + inline ---> arc-elision perf win
box-op MIR (weeks) --> value-optional --> error-union --> try/errdefer
                                             \--> async coroutines (needs box-ops + coroutine lowering)
all of the above (high coverage) ---> default-on flip
```

## Two roads, so the go-or-scrap is a real choice

The gap list splits cleanly into two scopes, and they cost very differently. This is the decision.

**Road A - honest beta (buildable-on, stable, tested). Roughly 5-8 weeks.**
Close gap 2 (fix the one crash + stand up the dogfood harness, days), gap 8 (stdlib coverage + convenience,
~3 weeks), gap 1 (soundness cleanup, ~1-2 weeks), and the days-scale slice of gaps 5 and 7 (formatter
hardening, Windows test gates). This gets you a language you can build real programs on without hitting
compiler bugs, with a tested stdlib and a clean type layer. It does NOT include the perf optimiser, a
debugger, WASM, or a mature ecosystem. Those become post-beta iterations. The scope is bounded and every item
has a verify command you run yourself.

**Road B - the full vision. Months.**
Everything in Road A, plus the optimiser rearchitecture (gap 3, the big one), source-level debugging via
emitted DWARF for lldb (gap 5, no bespoke debugger), and ecosystem hardening (gap 6, across separate repos).
WASM is dropped. This is where the real perf story and the polished platform live, and it is a genuine
multi-month effort with the optimiser and the async-coroutine emit as the highest-risk pieces.

**The honest recommendation, stated as opinion not fact:** if the goal is "a real language people can use,"
Road A is the finishable target and it is close, and the discipline that makes it real is exactly what was
missing before - close one gap, you verify it, then the next, no "done" until you have run the command. If the
goal is "the whole platform vision including the perf backend and the ecosystem," that is Road B and it is
months, and it should only start after Road A proves the base is trustworthy. Trying to do Road B first is how
the last five plans failed: building the vision on a base that was never finished.

Go, or scrap, is your call. What this document gives you that the earlier plans did not is a bounded scope with
a verify command on every line, so you never again have to take "done" on faith.
