# F1 — Name resolution, scopes & modules

**Depends on:** nothing. **This is the first piece.**
**Blocks:** F2 (you cannot type what you cannot resolve), and the type checker's arg-count check
(roadmap A2 says so explicitly).
**Status:** ⚠️ **PARTIALLY LANDED — this header said `Design` long after stages shipped.**
Stages 1, 2 and 3a (N2: ambiguity is an error) are LANDED. **Open: 3b** (cut codegen over to
`SymbolId`), **4** (real module scoping), **5** (lexical block scope — largely done via
`sema/alpha.zig` + `16_block_scope`), **6** (length-prefixed mangling), **7** (N3: failure is an
error). The stage table in §5 is the truth; done-criteria in §7 are 0/9 ticked.
*(Corrected 2026-07-17 — see `../beta-readiness-plan.md` §1.)*

---

## 1. The claim

> Nova has no symbol table. It has ~10 flat `StringHashMap`s keyed by mangled strings, and when an
> exact lookup misses it **linearly scans every function in the program looking for an underscore-
> delimited suffix match**. The first match in hash-iteration order wins.

The load-bearing defect, stated once:

> **`_` is simultaneously the module separator, the struct-method separator, the captured-global
> separator, and a legal identifier character.**

Because the separator is ambiguous with the payload, a mangled name cannot be *parsed* — only *guessed*.
Guessing is implemented as a scan. Every symptom below follows from that one sentence.

---

## 2. Current state (measured, file:line)

### 2.1 Modules do not exist past the loader

`main.zig:396-484` `loadProgram` is the entire module system:

```zig
for (program.declarations) |decl|
    if (decl != .import_decl) try declarations.append(decl);   // :476-480
merged.appendSlice(source);                                     // :482-483
```

Every declaration from every module is appended to **one flat `ArrayList`**. The `import_decl` is
**discarded**. Source text is concatenated into `merged.nova` (written at `main.zig:1226`).

**Nothing records which module a name came from.** There is no import table, no alias map, no
visibility, no export list. The only residue is `span.file` on each AST node.

### 2.2 Mangling is the file path, and it is not stable — ✅ **FIXED 2026-07-15**

> ✅ **Fixed.** `getModulePrefix` now strips whichever stdlib root the file was found under —
> including the absolute `$HOME/.nova/std/` fallback it used to miss — using `indexOf` rather than
> `startsWith`. The `.nova/std/` case now yields exactly what `src/std/` already yielded, so
> src-resolved builds are unchanged and HOME-resolved builds simply agree.
>
> **Measured:** path-dependent symbols **109 → 0**. And the actual claim, proven directly: the same
> source compiled with the stdlib resolved via `src/std/` versus via `~/.nova/std/` now produces a
> **byte-identical symbol set** (`nm | sort | md5` → `fd2c3518…` both ways). Before, one build carried
> `_Users_kamlesh_.nova_std_string_hash` and the other `string_hash`. **Builds are reproducible.**
>
> Cut over only after `NOVA_SEMA_SHADOW=1` predicted **0 new collisions** — which mattered:
> `declarations.zig:737-748` dedups functions by name, so a collision introduced by the rename would
> have *silently dropped one*. Corpus 26/26; YCSB and the driver repro clean end-to-end.
>
> The paragraph below records what it was.

`getModulePrefix` (`llvm_codegen.zig:1841-1861`) derives the prefix by taking `span.file`, stripping
`src/std/` or `src/lib/`, and replacing every `/` with `_`.

But the stdlib loader falls back to an **absolute** path — `"{HOME}/.nova/std/{sub}"` (`main.zig:422`) —
which starts with neither prefix. So:

| Same file, found via | Symbol |
|---|---|
| `src/std/string.nova` | `string_hash` |
| `~/.nova/std/string.nova` | `_Users_kamlesh_.nova_std_string_hash` |

**The same source file produces a different linker symbol depending on which path it was found under**,
and the user's home directory is embedded in the symbol. `lastIndexOfScalar(path, '.')` also truncates
at the *last* dot, so `.nova` in a directory name survives as a literal `.` inside an LLVM symbol.

`isAlreadyNamespaced` (`llvm_codegen.zig:659-676`) is a **hardcoded 40-entry prefix allowlist**
(`"string"`, `"json"`, `"list"`, `"map"`, `"serde_json"`, …). A user function named `map_reduce` or
`set_value` starts with an allowlisted prefix followed by `_`, so it is silently treated as
already-namespaced and **never gets a module prefix**.

`getStructPrefix` (`llvm_codegen.zig:626-657`) decides a function is a method if **param[0] is literally
named `self`** and its type is a known struct. The receiver is identified by *spelling*.

### 2.3 Resolution is a scan

`resolveCalleeName` (`types.zig:487-529`):

```
1. hasFunction(name)                              -> name                (:488)
2. "{current_struct}_{name}"                      -> full_name           (:491-496)
3. "{current_module_prefix}_{name}"               -> full_name           (:498-503)
4. suffix-scan functions.items                    -> whole key           (:505-514)
5. suffix-scan func_map                           -> whole key           (:516-526)
6. return name unchanged  (SILENT FAILURE)                               (:528)
```

The scan: for each key, take the trailing `full_name.len + 1` bytes; accept if `suffix[0] == '_'` and
`suffix[1..] == full_name`. **First match wins** — scan 1 in `functions.items` insertion order, scan 2 in
`func_map` hash order. With two modules exporting the same name, *which one you call is decided by table
order*.

> ⚠️ **CORRECTION (stage 2, measured 2026-07-15).** An earlier draft of this section called that
> **"nondeterminism baked into the compiler"**. **That is wrong**, and it is exactly the kind of
> plausible-but-unmeasured claim this program exists to stop — including when it is mine.
>
> Zig's `StringHashMap` hashes with a **fixed seed**, so iteration order is deterministic for a given
> insertion sequence. Verified: compiling the same input three times produces a **byte-identical symbol
> set** (`nm | sort | md5` — same hash all three runs).
>
> The defect is real but it is **arbitrary and fragile**, not random: the pick is meaningless, and it
> **flips when unrelated code changes the insertion order or grows the map** — a wrong-function
> miscompile arriving from an edit nowhere near the call. That is bad differently, and it must be
> described accurately.

`hasFunction` (`llvm_codegen.zig:1863-1869`) is itself `func_map.contains` **plus** a linear scan, so
step 1 is already O(n) and steps 2-3 call it again. Steps 2-3 `allocPrint` and **never free on the miss
path** — leaked on every failed probe.

**Seven suffix-scan sites:** `types.zig:505`, `:516`, `:262`, `:396`; `llvm_codegen.zig:1206`, `:1219`
(retried with a **capitalized** object: `json` → `Json`); `expressions.zig:1675`.

**Four sites are weaker still** — `endsWith` with *no* `_` boundary check: `expressions.zig:819`
(`string_concat`), `:850` (`string_eql`), `:2385` (`serde_*_parse`), `:2412` `getFunc` — where
`getFunc("hash")` matches `..._rehash`. `expressions.zig:2413-2420` still contains a live
`std.debug.print` loop dumping `func_map` whenever the name is `List_init`.

### 2.4 There is no block scope and no shadowing

`Scope` (`llvm_codegen.zig:62-64`) holds **only `deferred_statements`**. It carries no names. The
`scopes` stack is exclusively a `defer` mechanism — **not a lexical environment**.

`locals` is a flat map cleared **once per function** (`declarations.zig:851`), never per block.
`collectLocalVarNames` hoists **every `let` in the entire body, including nested blocks**, into
entry-block allocas, with `if (compiler.locals.contains(name)) continue;` (`declarations.zig:896`).

Therefore:
- Two `let x` in **disjoint blocks share one alloca** (first wins).
- An inner `let x` shadowing an outer one **aliases it**.
- Worse — `collectLocalVarTypes` (`llvm_codegen.zig:2241-2272`) does `map.put(name, type)` per `let`,
  **last writer wins**. So the *last textual* `let x` in a function decides `x`'s type **everywhere,
  including for earlier uses**.

That last one is a live miscompilation waiting to be discovered, and it has no conformance case.

### 2.5 Types are keyed by bare name

`structs`/`enums`/`unions`/`traits` (`llvm_codegen.zig:76-79`) are keyed by the **bare declared name** —
no module prefix, `put` with no collision check. **Two modules declaring `struct Config` silently
overwrite each other.**

### 2.6 `x.y` — two decision trees that disagree

**Value path** (`expressions.zig:1655-1765`) and **call path**
(`llvm_codegen.zig:1049-1290`) resolve `x.y` differently. Both consult `func_map` for a **bare field
name**.

The value path was guarded on 2026-07-15 (`expressions.zig:1667`, `obj_is_variable`) after `f.payload`
resolved to a user `fn payload` and the driver parsed a function address as a string — §10 #6, misfiled
for months as "string heap corruption".

**The call path's equivalent fallback — `func_map.get(fa.field)` at `llvm_codegen.zig:1236` — was also
guarded on 2026-07-15**, pinned by `expect_fail/method_shadowed_by_global_fn`. It is now a compile
error (`MethodOrFunctionNotFound`). What it used to do:

```nova
fn describe(a: int, b: int, c: int): string { ... }
struct Thing { pub v: int, ... }          // no `describe` method
let t = Thing(7);  t.describe()
```
```
LLVM Module Verification Failed: Incorrect number of arguments passed to called function!
  %calltmp2 = call i64 @describe()
```

This is precisely the failure spec §4.5 documents. It fails loudly only because LLVM's verifier happens
to catch the arity mismatch — **a same-arity collision would compile and silently call the wrong
function.**

### 2.7 Inference invents types on failure

`resolveExpressionTypeName` (`types.zig:176-485`) is the codegen's own inference, separate from the type
checker's. Notable:
- `.field_access` (`:220-243`) starts with `if (self.isStructType(fa.field)) return fa.field;` — **if a
  field's name collides with a type name, the expression's type becomes that type.**
- `.binary` (`:448-458`) falls back to `"i32"` when both sides are unknown — a wrong answer, not `null`.
- `.block_expr` / `.template_expr` (`:476-477`) → unconditionally `"string"`.
- `expressions.zig:1742` defaults an unresolved field's type to `i32` — **an unresolved field silently
  loads 8 bytes at a guessed offset.**

Return values are sometimes heap-allocated (`:207`, `:236`, `:358`) and mostly borrowed. **The caller
cannot tell which, and nothing frees them.**

---

## 2.8 Stage 1+2 results — measured, and they re-rank this document

Shadow mode (`NOVA_SEMA_SHADOW=1`, `src/sema/`) built the symbol table alongside legacy resolution and
instrumented the real `resolveCalleeName`. **Two of this document's claims did not survive contact with
the numbers.** Recording that is the point of a shadow stage.

### What is LIVE (fix it)

| Finding | Measure |
|---|---|
| ~~**Path-dependent symbols**~~ (§2.2) — ✅ **FIXED**, 109 → 0; identical symbol set from both resolution paths | Was: **109 of 204 symbols = 53%** on `ycsb.nova` embed `$HOME` in the **linker symbol**: `_Users_kamlesh_.nova_std_collections_list_allocCopy`. The build is **not reproducible across machines**, and the same file yields a different symbol depending on the path it was found under. |
| ~~**Unguarded call path**~~ (§2.6) | ✅ **FIXED 2026-07-15.** And the *silent* case was demonstrated first: a **zero-arg** global makes `t.describe()` lower to `call @describe()` with matching arity, so the LLVM verifier is blind — it printed `got=WRONG-global-fn`, **exit 0**. A clean compile, a wrong answer, no diagnostic. Now a compile error; pinned by `expect_fail/method_shadowed_by_global_fn` (verified to unexpectedly-compile without the guard). |
| **No block scope / last-`let`-wins types** (§2.4) | ✅ **FIXED 2026-07-15** (`src/sema/alpha.zig`, pinned by `16_block_scope`, verified to fail first). Was: **PROVEN** — `repro/block_scope_aliasing.nova`, specs §10 #23. `let x = 1; if (true) { let x = 2; } return x;` → **returns 2**. And a `let v = "…"` inside **`if (false)`** retypes a live `let v = 42` as `string`, so `${v}` reads a string header at `[42-4]` → **SIGSEGV**; deleting the dead branch makes the identical program print `42`. **Dead code segfaults live code.** This is the single worst live defect F1 fixes, and it is now the strongest argument for the scope tree. |

### What is LATENT (do not oversell it)

**The suffix scan is reached, but has never once been ambiguous in a real program.**

| Program | symbols | scan reached | **ambiguous** |
|---|---|---|---|
| `ycsb.nova` | 204 | **0** | **0** |
| `driver_alloc_churn_crash.nova` | 150 | **0** | **0** |
| `14_collections_map.nova` | 82 | 30 | **0** |
| `13_serde.nova` | — | 49 | **0** |

The static check predicted 6 ambiguous names on `ycsb` (`contains`, `hash`, `delete`, `set`). The real
resolver reached the scan **zero times** there: the exact-match paths (steps 1–3) always won. The static
check asked *"would this be ambiguous **if** the scan were reached"* — a hazard, not an occurrence.

**So the scan is a landmine that has not yet gone off in `resolveCalleeName`.** It still goes, because it
detonates the day someone adds a colliding name and the failure lands nowhere near the edit — but it is
**not currently miscompiling anything measurable**, and this document should not claim it is.

⚠️ **This does NOT exonerate the scans.** §10 #6 — months lost to "string heap corruption" — came from a
*different* scan: the `.field_access` value path (`expressions.zig:1675-1687`) and its bare
`func_map.get(fa.field)`. That one was live, did miscompile, and is fixed. Its sibling on the **call**
path (`llvm_codegen.zig:1236`) is still open. The danger is real and localised; the blanket claim was not.

### Re-ranking

F1's strongest justification is **not** "resolution is a nondeterministic scan". It is:
1. ~~**53% of symbols are path-dependent**~~ — ✅ **FIXED 2026-07-15** (109 → 0; builds reproducible).
2. ~~**The call-path `func_map.get(fa.field)` fallback**~~ — ✅ **FIXED 2026-07-15**.
3. **No block scope; last-`let`-wins types** — live, **proven** (§10 #23): shadowing aliases, and a `let`
   in a never-taken branch **segfaults** a live one. Arguably #1, not #3.
4. *Then* the scan, as a latent trap — ✅ **defused 2026-07-15 by N2** (ambiguity is now an error), so
   what remains of stage 3 is cleanliness (deleting the scan sites), not safety.

The work is unchanged; the argument for it is now honest.

---

## 3. Target design

### 3.1 Invariants

- **N1 — Every name resolves through a symbol table.** Zero suffix scans, zero `endsWith`, zero
  capitalize/lowercase retries. Deleting all 11 sites is a completion criterion.
- **N2 — Resolution is deterministic.** Never dependent on table order. Ambiguity is a **compile error
  naming both candidates**, never a silent pick. ✅ **LANDED 2026-07-15** (stage 3a), ahead of the
  cutover: stage 2 measured 0 ambiguous scans across four programs, so it rejects nothing that compiled
  before (corpus green) while permanently closing the class. Pinned by `expect_fail/ambiguous_bare_call`
  (`contains` → `string_contains` vs `assert_contains`), verified to unexpectedly-compile without it.
- **N3 — Resolution failure is an error.** No "return the name unchanged" (`types.zig:528`), no
  `orelse "i32"`.
- **N4 — Lexical scope is a tree.** Block scope and shadowing work. An inner `let x` is a *distinct*
  binding.
- **N5 — A symbol carries its module.** A name knows where it came from; imports control visibility.
- **N6 — Mangling is unambiguous and stable.** The mangled name is *parseable*, not guessable, and does
  not depend on the filesystem path the file was found under, nor on `$HOME`.

### 3.2 The symbol table

```zig
pub const SymbolId = enum(u32) { _ };
pub const ModuleId = enum(u32) { _ };

pub const Symbol = struct {
    name:     []const u8,      // source spelling, unmangled
    module:   ModuleId,
    kind:     union(enum) { function: *ast.FunctionDecl, type_: TypeDeclRef,
                            local: LocalId, constant: *ast.ConstDecl, param: LocalId },
    visibility: enum { public, private },
    span:     ast.Span,
};

pub const Scope = struct {
    parent:   ?*Scope,
    kind:     enum { module, function, block, lambda },
    names:    std.StringHashMapUnmanaged(SymbolId),   // this level only
    // `defer` list moves here too — it is a scope property (llvm_codegen.zig:62)
};
```

Resolution is `Scope.lookup(name)`: walk `parent` to the root. **That is the whole algorithm.** It is
O(depth), deterministic, and it makes shadowing (N4) fall out for free.

### 3.3 Modules

- The loader stops discarding `import_decl` (`main.zig:476-480`). Each module gets a `ModuleId` and its
  own module-level `Scope`.
- `import x.y;` binds `y` in the importing scope to module `x.y`'s scope. Only `pub` symbols are
  visible (`pub` already exists in the AST).
- **Module identity is the logical import path** (`std.string`), **not the filesystem path.** This is
  what kills §2.2: the same module has one identity whether found in `src/std/` or `~/.nova/std/`.
- Two modules may both define `Config`. Resolving bare `Config` where both are imported is an **error
  naming both** (N2).
- `merged.nova` remains as a debug artifact only. **Nothing may depend on text concatenation.**

### 3.4 Mangling

The current scheme is unfixable because its separator is a legal identifier character. Replace it:

```
_N<len><module_segment>...<len><name>          e.g. _N3std6string4hash
_NM<len><module>...<len><Struct><len><method>  e.g. _NM3std4list4List4push
```

Length-prefixed (Itanium-style). **Parseable, unambiguous, stable, `$HOME`-free.** `isAlreadyNamespaced`'s
40-entry allowlist (`llvm_codegen.zig:659`) and the capitalize/lowercase retries are deleted — nothing
needs to guess whether a name is already mangled, because mangling happens exactly once, from a
`SymbolId`.

The mangled name stops being the resolution key. **`SymbolId` is the key**; the mangled string is only
what gets emitted to the linker.

### 3.5 What F1 does NOT do

- It does not introduce types (F2). `resolveExpressionTypeName` stays, string-based, for now — F1 makes
  it *resolvable*, F2 makes it *typed*.
- It does not fix generics (F4) or ARC (F5).
- It does not change codegen's IR emission. F1 is deliberately a **front-end-only** change so it can
  land under the existing corpus.

---

## 4. What this fixes

- §10 #7 flat namespace — the root, not the symptom
- §10 #6's sibling: the unguarded call path (§2.6) — structurally, not with another guard
- Nondeterministic resolution (§2.3)
- Missing block scope / shadowing, and the last-`let`-wins type bug (§2.4)
- Silent cross-module type collisions (§2.5)
- `$HOME` in linker symbols; path-dependent symbols (§2.2)
- **Unblocks the type checker's arg-count check** — the roadmap names this as the blocker
- Deletes: 11 scan sites, a 40-entry allowlist, 2 case-retry hacks, the `allocPrint` leaks at
  `types.zig:491-503`, and the live debug `print` at `expressions.zig:2413`

---

## 5. Staging

| # | Stage | Content | Guard |
|---|---|---|---|
| 1 | **Symbol table, shadowing the old one** | Build `Scope`/`Symbol` in a new `src/sema/` during a resolve pass. **Do not consume it yet.** Assert it agrees with the existing resolution on the whole corpus + stdlib; log divergence. | corpus green (no behaviour change) |
| 2 | **Diverge-report → fix** | Every divergence from stage 1 is either a real bug (fix, add a case) or an intended difference (document). This is where the wrong-fn collisions surface. | new cases per divergence |
| **3a** | ✅ **N2: ambiguity is an error** (landed 2026-07-15) | The *safety* half of stage 3, taken first because stage 2 measured it free: 0 ambiguous across 4 programs. The scan still guesses, but it can no longer guess **silently**. | ✅ corpus 28/28; `expect_fail/ambiguous_bare_call` |
| 3b | **Cut over resolution** | Codegen resolves via `SymbolId`. Delete the 7 scan sites + 4 `endsWith` sites + allowlist + retries. **Now cleanliness, not safety** — N2 holds the line meanwhile, so this can wait behind F2 on evidence. | corpus green; case: two modules, same fn name, both callable |
| 4 | **Real module scoping** | Loader keeps `import_decl`; module scopes; visibility. | cases: `pub` vs private; ambiguous import is an error |
| 5 | **Lexical block scope** | Scope tree drives allocas; shadowing works; per-block `let`. | cases: shadowing, disjoint-block `let x` of different types (**fails today**) |
| 6 | **New mangling** | Length-prefixed. | corpus green; symbols contain no `$HOME` |
| 7 | **N3: failure is an error** | Delete `types.zig:528` fallthrough and the `i32` field default (`expressions.zig:1742`). | expect_fail cases |

Stage 1's shadow-mode is the whole risk strategy: it makes the blast radius **observable before it is
taken**. Given that today's resolution is nondeterministic, expect stage 2 to find real miscompilations.

---

## 6. Open questions

1. **Ambiguity policy.** Two imported modules export `parse`. Error always, or last-import-wins, or
   require qualification? *Recommendation:* **error**, require `json.parse`. Nova is already written
   this way by convention.
2. **Does `import x.y` bind `y` or `x.y`?** Today's code says `json.parse`, i.e. the last segment.
   Confirm, and decide aliasing (`import a.b as c`).
3. **Private by default or public by default?** `pub` exists, so presumably private-by-default — but
   §2.1 means it is currently unenforced. Enforcing it **will break stdlib code** that reaches across
   modules. Size that in stage 4.
4. **Method receivers.** Keep "param[0] named `self`" (§2.2) or introduce real method syntax? F1 can
   keep the convention; it just resolves it via the table instead of by spelling.

---

## 7. Done criteria

- [ ] Zero suffix-scan / `endsWith` resolution sites (all 11 deleted)
- [ ] `isAlreadyNamespaced` allowlist and both case-retries deleted
- [ ] Resolution never depends on hash order; ambiguity is an error naming both candidates
- [ ] `Scope` is a tree; shadowing and block scope have cases that **fail before this lands**
- [ ] `structs`/`enums`/`traits` keyed by `SymbolId`; cross-module `Config` collision is an error
- [ ] Mangled symbols are length-prefixed, path-independent, `$HOME`-free
- [ ] `t.describe()` (§2.6) is a **compile error**, not an LLVM verifier failure
- [ ] The arg-count check the roadmap deferred is **on**, with no stdlib false positives
- [ ] specs §4.5's "one flat namespace" warning and "Prefix your helpers" workaround are **deleted**
