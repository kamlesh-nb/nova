# Gap 2 -- Compiler crash surface (STABILITY): an empirical hunt

Date: 2026-08-15. Compiler under test: `/Users/kamlesh/.nova/bin/nova` (installed build).
All programs compiled and run with `NOVA_ASAN=1` so a latent memory bug surfaces as an
ASAN SEGV rather than passing silently.

This is the gap that decides alpha vs beta: **can you still hit compiler bugs (crashes /
miscompiles) building realistic programs?** The honest answer from this hunt is: **the common
paths are solid, and there is one genuine, reproducible crash class left on a feature
combination that a real app can hit** (generic struct + trait-object dispatch). It is a
known-open limitation, not a fresh regression, but it is a real SIGSEGV.

---

## 1. Method

I wrote 49 small but realistic Nova programs and, for each, recorded: does it compile? does it
run? does it crash (exit >= 132 / ASAN SEGV)? is the output correct?

Design of the corpus:

- **31 "everyday" programs** (`t00`–`t30`): feature combinations a normal app uses -- generics +
  closures (map/filter/reduce), traits + generics, nested optionals via generics
  (`List<int|undefined>`, `Map<K, int|undefined>`), error-unions + generics, `Map` of structs,
  async + generics, struct-of-struct, enums-with-payload + `switch`, closures capturing owned
  values, recursion (`fib`, recursive tree over `List<Node>`), string interpolation with mixed
  types, currying (closure returning closure), closure stored in a struct field, nested
  generics (`List<List<int>>`, `Map<string, List<int>>`), trait objects in a `List`, downcast
  with `as`, tuple destructuring.
- **10 "adversarial" programs** (`a01`–`a10`): the combinations that the project MEMORY notes
  flag as historically fragile -- value-optional call result passed directly as a nested arg;
  **generic-struct method dispatched through a trait vtable**; closure capturing an owned struct
  then invoked from a `List`; three-level nested generics; multi-payload enum; `try` inside a
  loop across a generic-ish boundary; async fn returning a struct; optional returned from a
  generic method of a generic struct; closure capturing the loop variable; enum payload holding
  a struct.
- **8 minimisation / control probes** (`a02b`, `a02c`, `b01`–`b05`, `t13b`): to isolate the one
  crash and prove what does *not* trigger it.

**Syntax was validated first** against passing sources so a parse error is never miscounted as
a bug: I read `docs/guide/examples/{05,08,09,10,11,13,14,15,16,17,21}.nova` and conformance
cases `278`, `299`, `306` before writing anything, and confirmed a baseline (`t00`) compiles and
runs. Import style follows the conformance corpus (`import list; List<int>()`).

---

## 2. Results -- the honest tally

**49 programs tried. 48 compiled. 47 ran correctly. 1 genuine crash. 1 clean type-error (my
syntax, not a bug).**

Breakdown of the two non-"ran-correctly" outcomes:

### (a) Genuine crash -- 1 (severity: CRASH / SIGSEGV, ASAN-confirmed)

**`a02_gen_via_trait` -- a generic struct method dispatched through a trait vtable, where the
method uses its `T`-typed field concretely (string interpolation), SEGVs.**

Minimal repro:

```nova
trait Render { fn render(self: Render): string; }
struct Cell<T> impl Render {
  pub v: T,
  init(v: T){ self.v = v; }
  pub fn render(self: Cell<T>): string { return `[${self.v}]`; }   // uses T concretely
}
fn show(r: Render): void { console.log(r.render()); }              // dispatch via vtable
fn main(): void { show(Cell<int>{ v: 42 }); }                       // T = int -> CRASH
```

ASAN output:

```
==ERROR: AddressSanitizer: SEGV on unknown address 0x000000000026
SUMMARY: AddressSanitizer: SEGV (…:arm64) in StringBuilder_append+0x1c
```

Blast-radius probes (what does and does not trigger it):

| Probe | Program | Result |
|-------|---------|--------|
| Same struct, **direct** call (no trait) | `a02b_direct` (`Cell<int>{}.render()`) | OK `[42]` -- matches conformance case 299 |
| Trait dispatch, method **ignores** `T` (returns a constant) | `a02c_trait_noT` | OK `const` |
| **Non-generic** struct via trait, with interpolation | `b02_nongen_trait_interp` | OK `[42]` |
| Trait dispatch, method returns a constant `int` | `b01_trait_retT` | OK `1` |
| Trait dispatch, **arithmetic** on `T`-field (`self.v + 100`, T=int) | `b05_trait_arithT` | OK `105` (correct!) |

So the trigger is precise: **generic struct + `impl Trait` + trait-object dispatch + the method
reads the `T`-typed field where `T`'s concrete identity changes the operation** -- specifically
string interpolation of a non-`string` `T`. Arithmetic on a `T=int` field happens to work
because the erased body defaults the field to an integer slot; interpolation is where the
erased body picks the *string-append* path and derefs the raw integer value as a `char*`.

First-look root cause (backend codegen, high confidence -- I read the code):

- `getGlobalVTable` in `lang/src/backend/codegen/llvm_codegen.zig` (~line 1595) builds **one
  vtable per (base-struct-name, trait)** and fills each slot with the method looked up as
  `"{struct_name}_{tm.name}"` = `Cell_render` -- the **T-erased** shared body.
- `constructTraitObject` (same file, ~line 1671) then stores that vtable using
  `getGlobalVTable(getStructBaseName(struct_name), …)`, i.e. it deliberately strips `<int>` /
  `<string>` before the lookup. The in-code comment even states the intent: *"Generic trait
  objects share ONE vtable per (base struct, trait) -- the type arg is erased for dispatch."*
- That is correct only when the method body is genuinely `T`-agnostic. When the body uses `T`
  concretely, the erased body is wrong: for `Cell<int>` the inline `int` field is fed to the
  string path in `StringBuilder_append` and dereferenced as a pointer → SEGV.

This is **a known-open limitation, not a new regression**: conformance case 299
(`299_generic_struct_typed_field_value.nova`) explicitly documents it -- *"Still open (tracked
separately): dispatch of such a method through a TRAIT OBJECT vtable, where the vtable points to
the erased shared method body rather than the per-instantiation monomorphisation."* This hunt
confirms it empirically and pins the crashing site.

### (b) Clean compile-error -- 1 (NOT a bug; my syntax)

`t13_opt_chain_nested` used `m.get("a")?.addr.city` -- a `?.` on the first hop then a plain `.`
on a still-optional value. The type checker **correctly rejected it** with a clear, actionable
message (*"field access on a possibly-`undefined` value … narrow with `if (x != undefined)`"*)
and did **not** crash. The correct form `m.get("a")?.addr?.city` (`t13b_opt_chain_fixed`)
compiles and runs (`Pune`). Counted as an anti-inflation item: this is the type system doing its
job, not a defect.

### Everything else -- 47 ran correctly under ASAN

Every other combination in the corpus was green, including the historically-fragile ones the
MEMORY notes call out: value-optional passed as a nested arg (`a01`), closures capturing owned
structs from a `List` (`a03`), three-level nested generics (`a04`), multi-payload enums (`a05`),
`try` in a loop (`a06`), async returning a struct (`a07`), optional from a generic method
(`a08`), closure capturing the loop var (`a09`), enum payloads holding structs (`a10`),
`Map<string, int|undefined>` present-null vs absent (`t30`). Two realistic mini-apps
(word-count `b03`, a bank ledger `b04`) were also clean.

One thing worth a footnote (not a crash, not counted as a bug): in `t30`, a key stored with an
explicit `undefined` value reports `!= undefined` as **true** (present), which is the intended
present-vs-absent double-box semantics from the `nova-a-nested-double-box-arc` note. It ran
cleanly; flagging only so a future reviewer does not mistake it for a miscompute.

---

## 3. Assessment

**The crash surface is "a handful of edge cases", not "core paths are fragile."** Grounded in
the tally: 47 of 48 compiled programs ran correctly under ASAN across a deliberately broad
spread of feature *combinations*, including the ones prior sessions marked risky. The single
genuine crash is **not** on a hot everyday path -- it needs the specific stack of *generic
struct + trait-object dispatch + concrete use of the `T` field*. A great many real programs
never hit it (direct method calls on generic structs are fine; trait objects over non-generic
structs are fine).

But it is a **real, memorable crash a real app can reach**: "put my generic wrapper behind an
interface and print it" is an ordinary thing to do, and it SIGSEGVs with no diagnostic. For a
*beta* stability claim, an un-diagnosed SEGV on a plausible pattern is a genuine blocker, even
if narrow. The honest read: **Nova's compiler is close to beta-stable on stability grounds  -- 
one well-understood defect stands between this corpus and 100% green.** That matches the
`nova-final-beta-readiness` note's framing (alpha, not beta), and this hunt narrows *why* on the
stability axis to essentially one class.

Caveat on scope: 49 hand-written programs is a spot-check, not a proof of absence. It samples
the combinations a human judged likely; it does not exhaust generic-depth, ownership-churn, or
async-colouring interactions. "Few bugs found" here is real and good news, but it bounds the
*known* surface, not the *true* one.

---

## 4. Design to close (PLAN)

Two tracks: fix the found defect, and stand up a process so the surface trends to zero.

### Track 1 -- fix the one crash (confidence: HIGH on diagnosis, MEDIUM on effort)

Per-instantiation vtables for generic structs that `impl` a trait. Concretely:

1. Key the vtable by the **monomorphised** struct name, not the base: emit
   `_vtable_Cell_int_Render` whose method slot points at the mono body `Cell_render__int`
   (which already exists and works -- `a02b` proves the mono body is correct), and
   `_vtable_Cell_string_Render` pointing at `Cell_render__string`.
2. In `constructTraitObject`, select the vtable using the **concrete** `struct_name` (it still
   carries `<int>` at that call site -- the code currently throws it away via
   `getStructBaseName`). Fall back to the erased vtable only for a genuinely erased value.
3. Guard: keep the shared/erased vtable for the T-agnostic case so we do not regress binary size
   where the method truly does not touch `T`.

Unknown / risk: whether the mono method bodies are always emitted before the trait object is
constructed (emission ordering). If not, this needs the monomorphisation worklist to note
"struct instantiated into a trait object" as a root, similar to the field-type fix in case 306.
That is the medium-effort part.

Files: `lang/src/backend/codegen/llvm_codegen.zig` (`getGlobalVTable`, `constructTraitObject`);
possibly the mono worklist in `lang/src/backend/codegen/declarations.zig`.

Then pin it with a new conformance case (the `a02` repro), asserting `[42]` and `[hi]`.

### Track 2 -- a standing dogfood/fuzz harness (confidence: HIGH it helps; "zero" is asymptotic)

There is already `tests/fuzz.sh`, `tests/codegen_fuzz.{py,sh}`, and `tests/emit-differential.sh`.
The gap is a **realistic-combination dogfood corpus run under ASAN in CI**, distinct from the
type-directed codegen fuzzer:

1. Land this 49-program corpus (trimmed to the ~40 signal programs) as
   `tests/dogfood/*.nova`, each a self-checking program (assert or known stdout), run under
   `NOVA_ASAN=1` by `gate.sh`. Bar: **100% green** (after Track 1).
2. Prioritise categories by observed and historical risk, in order:
   (a) generic struct × {trait dispatch, field-of-generic, method-returns-`T`} -- the live class;
   (b) optional/error-union boxing across generic and async boundaries (double-box, value-opt as
   nested arg) -- historically the richest bug seam;
   (c) closures capturing owned/struct values stored in containers;
   (d) enum payloads holding structs / other enums, matched via `switch`.
3. Add a small **generative** layer: a script that combines a fixed set of "shapes" (generic
   struct, trait, optional, enum-payload, closure) up to depth 2–3, compiles each under ASAN,
   and reports any non-zero exit. This is where new, unforeseen combinations get caught. The
   existing `codegen_fuzz.py` is a starting skeleton but is type/arithmetic-oriented; this needs
   feature-combination templates.

Honest note: "zero crashes" is asymptotic. A generative harness lowers the *probability* of an
un-caught combination; it never certifies zero. The realistic goal is: the curated dogfood set
is 100% green and stays green, and the generative layer runs N thousand random combinations per
CI run with zero SEGVs over a sustained window.

---

## 5. Verify -- the measurable beta bar

Stability is "done enough for beta" when all of the following hold:

1. **The `a02` repro is fixed** and landed as a conformance case that asserts correct output
   (not just "does not crash").
2. **A curated dogfood corpus of ~40 realistic feature-combination programs is 100% green under
   `NOVA_ASAN=1`** and is wired into `gate.sh` so a regression fails CI. (This hunt's corpus is
   the seed; it is 47/48 today, one fix from 48/48.)
3. **A generative feature-combination fuzzer runs >= N (e.g. 5,000) random depth<=3 programs per
   CI run with zero compiler crashes and zero ASAN SEGVs** over at least one sustained green
   window (e.g. a week of nightly runs).

Bars 1 and 2 are days of work and directly closeable. Bar 3 is the process guarantee that keeps
the surface at zero rather than proving it once; it is the part that is genuinely ongoing.

---

### Appendix -- reproduction

Programs live in `…/scratchpad/lastlap/progs/*.nova`; the runner is
`…/scratchpad/lastlap/run.sh` (compiles + runs each under ASAN, classifies
`OK` / `COMPILE_FAIL` / `COMPILE_CRASH` / `RUN_CRASH`). The one crash reproduces with:

```
NOVA_ASAN=1 /Users/kamlesh/.nova/bin/nova progs/a02_gen_via_trait.nova -o /tmp/a02 && /tmp/a02
```
