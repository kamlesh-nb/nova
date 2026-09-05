# F4 — Generics & monomorphization

**Depends on:** F2 (`.type_param` and `.struct_.args` must be types, not letters).
**Blocks:** F5 (ARC cannot release an element whose type is unknown at destruction).
**Absorbs:** roadmap **A2 increment 2**.
**Status:** 🔨 **PARTIALLY LANDED — this header said `Design` after 4b shipped as mandatory.**
Stage 2 (`.type_param` is a type) and stage 4 (per-instantiation destructors) are LANDED.
**Stage 4b (monomorphize method bodies) is LANDED AND MANDATORY — the flag was deleted the same
day** (an 'off' switch that selects memory corruption is a trap, not a fallback).
✅ **`Map` is NO LONGER excluded from mono, and `retainIfGenericStore` is DELETED.** §3's "Map is
excluded by name and that is the next task" is **stale** (verified 2026-07-17): `map.ky` now holds
`Storage<K>`/`Storage<V>` typed fields, the generated `__destruct_Storage_K` releases the slots, and
the two cases that failed when Map was included (`12_traits_dispatch`, `13_serde`) both pass, as does
`14_collections_map`. `retainIfGenericStore` survives only in historical comments. **This unblocks
F5 stage 5.** Still open: stages 1, 3, 5, 6.

> ⚠️ **A correction I had to make to my own correction.** The first pass of this header (2026-07-17)
> asserted "Map is still excluded — that is the next task", copied from a doc-derived summary rather
> than from the tree. It was false. **The doc-truth pass reintroduced exactly the class of stale claim
> it existed to remove** — which is the strongest possible argument for the rule in
> `../beta-readiness-plan.md` §0: *read the code, run the thing; a summary of a doc is still the doc.*

*(Corrected 2026-07-17 — see `../beta-readiness-plan.md` §1.)*

---

## 1. The claim

> `List<string>` and `List<int>` are **the same code, the same layout, and the same symbol**. They are
> indistinguishable after parse — and for struct literals, indistinguishable *at* parse. A generic type
> parameter is detected by testing whether a string is one uppercase letter.

Verified in the checked-in IR (`__kyte_test.ll`):

```llvm
define void @List_push(i64 %0, i64 %1)
define i64  @List_get(i64 %0, i64 %1)
define void @__destruct_List(i64 %0)
```

No `List_string_push`. No `__destruct_List_string`. One symbol per declaration.

---

## 2. Current state (measured, file:line)

### 2.1 Type erasure, precisely

1. **Uniform ABI.** `declarations.zig:752-755`: `@memset(params, compiler.val_type)` — *every* parameter
   of *every* function is one machine word. Return likewise (`:763`). **This is why one body can serve
   all instantiations** — nothing is typed at the boundary.
2. **Symbols carry no type args.** `llvm_codegen.zig:1896`:
   `allocPrint("{s}_{s}", .{ s.name, fn_decl.name })` — `s.name` is `"List"`; `type_params` is never
   consulted.
3. **Layout ignores type args.** `getFieldOffset` (`llvm_codegen.zig:738`) calls `getStructBaseName`
   then reads the *generic declaration's* fields. `getTypeSize` on a `T` field falls through to
   `if (is_wasm) 4 else 8` — a `T` is always one word.
4. **Elements are boxed.** `list.ky:4-9` `allocCopy<T>` writes a single pointer-sized word.

### 2.2 `getStructBaseName` is the erasure function

`types.zig:9-18`:
```zig
if (lastIndexOfScalar(base, '.')) |dot| base = base[dot+1..];  // strip qualifier
if (indexOfScalar(base, '<')) |pos| return base[0..pos];       // strip type args
```

`List<string>` → `List`. **Every table in codegen is keyed by that result** (24 call sites). This is
*why* there is no monomorphization: the base name is the lookup key everywhere, so an instantiation has
nowhere to exist.

### 2.3 `T` is a one-character string

`arc.zig:11-15` — the **only** structural test for "is this a generic param" in the entire codegen:
```zig
if (type_name.len == 1 and type_name[0] >= 'A' and type_name[0] <= 'Z') return false;
```

Substitution hardcodes the letters — `llvm_codegen.zig:2345-2355`:
```zig
if (mem.eql(u8, type_to_sub, "T") and params.len >= 1) return params[0];
if (mem.eql(u8, type_to_sub, "K") and params.len >= 1) return params[0];
if (mem.eql(u8, type_to_sub, "V") and params.len >= 2) return params[1];
if (mem.eql(u8, type_to_sub, "U") and params.len >= 1) return params[0];
```

It **does not consult the declaration's `type_params`**. Consequences:
- `struct Foo<A, B>` gets **no substitution at all**.
- `Map<K,V>`'s `K` and `V` work only because the letters were chosen to match.
- Substitution is string surgery, splitting on `'<'`/`'>'`/`", "` (`:2357-2382`).

### 2.4 The parser throws type args away

`parser.zig:1461-1470`: for `List<string>{...}` the parser parses `type_args` (`:1433-1441`), then builds
`StructInit{ .type_name = type_name }` — the bare `.ident`. `type_args` is freed by its own `defer`
(`:1434`). `StructInit.type_name` is `[]const u8` (`ast.zig:395`), **not a `TypeRef`** — there is nowhere
to put them.

### 2.5 The leak is documented in-tree

`arc.zig:34-40`:

> *"Generic code treats T opaquely and never retains/releases it (isRefCountedType is false for "T")…
> Retaining here transfers ownership to the callee (container). Elements then leak on container drop
> **until reified-generic destructors exist**, which is acceptable versus a crash."*

That comment is accurate, and it names F4 as its own precondition. The measured cost (2026-07-15):
`List<string>`, 20 elems/round — 50k→66.7MB, 200k→249.8MB, 800k→**927.4MB**, linear and unbounded.

### 2.6 The machinery already exists — this is the good news

Three mechanisms already generate code per type, memoised by symbol name. **All are keyed by base
struct rather than by instantiation. That key is the only thing standing between them and
monomorphization.**

**(a) `getOrCreateDestructor` — `arc.zig:80-152`**
```zig
const base_struct = getStructBaseName(type_name);          // :81   <-- the erasure
const dest_name = allocPrint("__destruct_{s}", base_struct); // :86
if (core.LLVMGetNamedFunction(module, dest_name_z)) |existing| return existing;  // :91  <-- the memo
```
It saves/restores the builder insert point (`:101`, `:147-149`) — **it already emits a function
on demand, mid-way through another function's body**, and recurses into field destructors (`:139`).
This is exactly the shape monomorphization needs. Change `:81`'s key from base name to instantiation
and `__destruct_List<string>` becomes expressible.

**(b) `getGlobalVTable` — `llvm_codegen.zig:859-909`.** Keyed `_vtable_{struct}_{trait}` — a **pair of
types** — memoised via `LLVMGetNamedGlobal` (`:865`). Precedent that a multi-type key works.

**(c) `generateSerdeBinders` — `main.zig:273-394`.** The closest thing to monomorphization in the tree:
it emits **Kyte source text** per `@serializable` struct, special-cases `.generic` fields where
`g.name == "List"` (`:356`), switches on the **concrete element type** `g.params[0]` (`:358-370`), then
**re-parses** the generated source (`:386-391`) and appends the decls. It specialises per concrete type
argument today — just at the source level, by string emission, before the checker.

**(d) The call site already looks for specialised symbols** — `expressions.zig:1441-1463`:
```zig
const fn_val_opt = self.func_map.get(init_name)        // "List_string_init"
              orelse self.func_map.get(new_name)       // "List_string_new"
              orelse self.func_map.get(base_init_name) // "List_init"     <-- always taken
              orelse self.func_map.get(base_new_name);
```
**Nothing in the compiler ever generates `List_string_init`.** The lookup hook for monomorphization is
already written and has never once hit. F4 is what makes it fire.

---

## 3. Target design

### 3.1 Invariants

- **G1 — An instantiation is a type.** `List<string>` and `List<int>` are distinct `TypeId`s. `TypeId`
  equality is type equality (F2 interning).
- **G2 — `T` is a type, not a letter.** `.type_param{ owner, index }`. Substitution is **by index**, from
  the declaration's `type_params`. The `T`/`K`/`V`/`U` hardcode and the `len == 1` test are deleted.
- **G3 — One body per instantiation.** `List<string>_push` and `List<int>_push` are distinct functions
  with distinct symbols.
- **G4 — Type args survive parse.** `StructInit` carries a `TypeRef`, not a name.
- **G5 — No type-erased generic reaches codegen.** Every `.type_param` is substituted before IR emission.
  A `.type_param` at codegen is a compiler bug (assert).

### 3.2 The pass

Monomorphization sits in sema, after typecheck, before codegen:

```
F1 resolve → F2 typecheck/annotate → [F4 monomorphize] → codegen
```

Standard worklist:

```
roots  := all non-generic functions (main, exported, @test)
queue  := roots
seen   := {}                                  // key: (SymbolId, []TypeId)

while queue not empty:
    fn := pop(queue)
    for each call/instantiation site in fn:
        key := (callee_symbol, concrete_type_args)      // from TypedIr — no strings
        if key ∉ seen:
            seen += key
            clone the decl, substituting .type_param{owner,index} -> args[index]
            queue += the clone
```

**Substitution is by `index`, over `TypeId`s.** No string surgery, no `'<'` splitting, no hardcoded
letters. `substitutePlaceholders`, `substituteGenericType`, `substituteGenericArgs`
(`llvm_codegen.zig:2344-2410`) are all deleted.

**Reuse the existing memo pattern** (§2.6a): the `seen` set *is* `getOrCreateDestructor`'s
`LLVMGetNamedFunction` check, generalised — key on `(SymbolId, args)` instead of base name.

### 3.3 Mangling instantiations

Extends F1 §3.4 (length-prefixed, parseable):

```
_NI<len><module>...<len><List>I<TypeId-mangling>E     e.g. _NI3std4list4ListI6stringE4push
```

`__destruct_List` becomes `__destruct_List<string>` (mangled) — **which is precisely what
`arc.zig:34-40` says must exist before elements can be released.** F5 depends on this and nothing else.

### 3.4 Representation: stay boxed, for now

Full monomorphization permits *unboxed* elements (`List<byte>` as a real byte array). **F4 deliberately
does not do that.**

- **In scope:** one body per instantiation; concrete element **types**; therefore working destructors.
- **Out of scope:** unboxed layouts, `size_of<T>`, non-word element storage.

Rationale: unboxing changes every `bytes.write_ptr`-based container in the stdlib and interacts with F3's
representation change. F4 is worth landing for **F5 alone** (ARC correctness) and should not be held
hostage to a performance change. Keeping the word-sized element representation means F4 changes *which
function is called*, not *what memory looks like* — a far smaller blast radius. Unboxing is a follow-on
(F4b) once F3 and F5 have landed.

### 3.5 Code growth

Monomorphization trades size for correctness. `List` has ~15 methods; if the stdlib instantiates it at 8
types, that is ~120 functions where 15 exist today. Mitigations, in order:
1. Only instantiate what is **reachable** (the worklist gives this free).
2. Identical-body dedup after substitution (`List<string>` and `List<Foo>` are byte-identical while
   elements stay boxed — see §3.4; both are one word with the same destructor *shape* but different
   destructor *targets*, so dedup must key on the substituted body, not the args).
3. Measure before optimising. Record the corpus's symbol count and `.o` size **before** stage 3.

### 3.6 Recursion guard

`struct Node<T> { next: Node<Node<T>> }` instantiates infinitely. The worklist must **bound
instantiation depth** and report a clear error. Today this is not a risk only because nothing is
instantiated. **Cannot ship without it** — an unbounded worklist is a compiler hang.

---

## 4. What this fixes

- **§10 #17** — `List`/`Map` element leaks. Not directly: F4 makes the *element type known at
  destruction*, which is the precondition F5 needs. F4 alone fixes nothing at runtime; that is expected.
- `struct Foo<A, B>` — silently unsubstituted today (§2.3)
- `List<string>` vs `List<int>` indistinguishable — G1
- `Hash`/`Eq` on type params (roadmap A2's blocked item) — becomes possible once `T` is a real type
- Deletes: `substitutePlaceholders`/`substituteGenericType`/`substituteGenericArgs`, the `T`/`K`/`V`/`U`
  hardcode, the `len == 1` test, and `getStructBaseName`'s role as a lookup key
- Makes the dead hook at `expressions.zig:1441-1463` live for the first time

**Does NOT fix:** boxing/performance (§3.4), ARC itself (F5), variance/bounds (§6 Q2).

---

## 5. Staging

> **Landed 2026-07-15 (stage 2, ahead of stage 1).** Substitution — `sema/subst.zig` plus the join in
> `infer.zig` — took **generics to ZERO of F2's expression gap** (124 → 31, and none of the 31 is
> generics). Worth recording *why it came first*: F2's cutover was blocked on typing generic
> expressions, which needs only **G1 + G2 + substitution** — all in sema. It never needed G4, the
> worklist, or emission. The staging below is ordered for *codegen* monomorphization; the measurement
> said sema's half was both cheaper and the actual blocker.
>
> What the gap really was, once clustered by NAME rather than shape:
>
> | | | |
> |---:|---|---|
> | 30 | three missing rows in `builtins.zig` | not generics — the table was a SUBSET of what codegen declares, so it reported its own omissions as language gaps |
> | 43 | generics **+ cascade** | `list.get(i)` unresolved ⇒ `s` ⇒ `s.length` ⇒ `len_s`. One join, four clusters. Types flow, so gaps flow — which is why the *root* is worth far more than its own count |
> | 6 | a method's own `U` | one owner cannot describe two declarations (`param_scopes`) |
> | 9 | generic **functions** | `generic_call` only handled constructors |
> | 21 | closure calls through a field | **not generics** — `(self.hashFn)(key)`. The next increment |
>
> G1 and G2 were **already true** before this work: `lower.zig` already interned `List<string>` and
> `List<int>` as distinct TypeIds, and `T` already lowered to `.type_param{owner,index}`. Nothing put
> them together. The bug was never a missing capability; it was a missing *join*.
>
> Two traps found on the way, both from a valid-looking default rather than a wrong algorithm:
> `Lowerer.owner` defaulted to `@enumFromInt(0)` and **no caller ever set it**, so every generic's `T`
> collapsed onto ONE TypeId — presenting as a cosmetic mis-render (`'K' -> 'T'`). And a method's params
> were *merged* with its struct's under one owner, making `U` into `{List, 1}` — an index List does not
> have. Both are now unrepresentable (`param_scopes`), not merely guarded.


| # | Stage | Content | Guard |
|---|---|---|---|
| 1 | **G4: type args survive parse** | `StructInit.type_name: []const u8` → `type_ref: ast.TypeRef`. Stop dropping `type_args` (`parser.zig:1461`). Nothing consumes them yet. | corpus green |
| 2 | ✅ **G2: `.type_param` is a type** (landed 2026-07-15, out of order — see above) | F2's `.type_param{owner,index}`. Substitution by index — but still string-free *inside sema only*; codegen untouched. | corpus green |
| 3 | **Worklist, shadow mode** | Compute the instantiation set. **Emit nothing.** Log the set + projected symbol/size growth (§3.5). Recursion guard here. | corpus green; growth numbers recorded |
| **4** | ✅ **G3 — per-instantiation DESTRUCTORS** (landed 2026-07-15, **narrowed**) | **NOT** full monomorphization. §3.5 item 2 already said why: the bodies are byte-identical while elements stay boxed — **only the destructor targets differ**. So the destructor is the whole of what F5 needs, and cloning 12 method bodies per instantiation is cost without a customer. `getStructBaseName` stripped `<...>` from the destructor's name AND its memo key, so one `__destruct_List` served every element type; it can neither release elements (List<string>) nor not (List<int>), so it does neither, and List<string> leaks ~138 B/iter (`repros/list_string_leak.md`). Now `__destruct_List_i32` / `__destruct_List_string`. **1,396 → 1,460 functions (+4.6%)**, vs 1.29x for the full version. | ✅ corpus 28/28; symbol-level (two destructors where there was one) — see the note |
| **4b** | **Monomorphize method BODIES** — *now the blocker, with a customer* (scoped 2026-07-15) | No longer "if ever needed". **F5 cannot finish without it**, proven by trying: ARC inside a generic method body is undecidable, because the body sees `Storage<K>` and `isRefCountedType("K")` is FALSE — `K` is a type parameter. So `Map<K,V>.set` never retains its key, the key is freed, and the lookup returns garbage (`Expected 100, got 4339729744`, consistently). **`retainIfGenericStore` is not a bug — it is the WORKAROUND for exactly this**: it checks the argument's actual type at the CALL SITE, where `m.set("hello", 1)` really is a `string`, precisely because inside the body `K` is erased. Deleting it without monomorphizing is what produced three separate memory bugs. **Scope: 36 sites build `<Struct>_<method>` symbols**, all of which must become `List_string_push`; plus N-copy emission at declarations.zig:655 and :840; plus a TypeRef-substituting clone of each FunctionDecl. ⚠️ **The clone is WRONG — see the correction below (2026-07-16).** | corpus green + STABLE across repeated runs (the bugs it replaces were intermittent) |

> ### 4b's method is a RENDER-BOUNDARY substitution, not an AST clone (corrected 2026-07-16)
>
> The row above says 4b needs "a TypeRef-substituting clone of each FunctionDecl". **That cannot work,
> and the reason is one line:** `TypedIr.expr_types` is keyed by `ast.ExprId` (`infer.zig:83`;
> `typeOf(e) => expr_types.get(e.id)`). Cloning an AST does not re-run sema, so a cloned body lands in
> one of two ditches:
>
> - **the clone copies the ExprIds** → `typeOf` returns the type sema inferred for the ERASED body, i.e.
>   `T`. The clone bought nothing; you still need substitution at the render boundary.
> - **the clone gets fresh ExprIds** → `typeOf` returns `null`, and codegen loses *every* expression type
>   in the body. Strictly worse than today.
>
> **The erasure lives in sema, not in the AST**, so cloning the AST cannot remove it. Re-running
> inference per instantiation would — that is the honest long-term answer — but it is a far larger
> change (sema re-entry, symbol-table churn, compile-time cost) than 4b's customer needs.
>
> **A type parameter becomes a STRING in exactly two places, and every consumer downstream
> (`isRefCountedType`, `local_types`, the destructor lookup) reads those strings:**
>
> | Site | Path | Renders `T` for |
> |---|---|---|
> | `codegen/types.zig:128` | `typeRefToString` → `.ident => name` | DECLARED types — params, fields, lets |
> | `sema/shadow.zig:595` | `renderLegacy` → `.type_param => typeParamName(tp)` | INFERRED expression types |
>
> So 4b is: a `current_instantiation` context set around each emitted body, consulted at those two
> sites. `isRefCountedType("string")` is then TRUE inside `List_string_push`, which is the whole of what
> F5 is blocked on. **The substituter already exists and is proven** — G3's `substituteFieldType`
> (`arc.zig:155`) already does whole-token replacement BY INDEX from the declaration's own `type_params`
> (`substituteFieldType("List<string>", "Storage<T>")` → `Storage<string>` today). 4b generalizes its
> *caller*, not its logic.
>
> **This does not make "36 sites" wrong** — those sites build `<Struct>_<method>` symbols and still must
> become `List_string_push`. It makes the *body* half of 4b two sites instead of a tree-walking clone.
> The N-copy emission at `declarations.zig:655`/`:840` is unchanged.
>
> ### ✅ 4b LANDED 2026-07-16 — and monomorphization is now MANDATORY (no flag)
>
> It shipped behind `KYTE_F4_MONO=1`, then **the flag was deleted the same day**. It stopped being
> optional the moment `Map` moved onto `Storage<K>` (F5 §3.4b): an ERASED `Storage<K>` has inert ARC, so
> nothing retains the key while the call-site retain still fires. The two do not compose, and the result
> is an intermittent **use-after-free — 4 of 6 corpus runs** failed on 12_traits_dispatch. An "off"
> switch that selects memory corruption is a trap, not a fallback, so there is no switch. Cost: **112 →
> 150 functions (1.34x)**, against stage 3's 1.29x projection.
>
> **The erasure is broken, and here is the measurement that says so** — one program, three bodies:
>
> | body | `kyte_retain` | `kyte_release` | |
> |---|---|---|---|
> | `List_push` (erased) | 0 | 0 | undecidable: `isRefCountedType("T")` is false, so it does nothing |
> | `List_i32_push` | 0 | 0 | correct — `i32` is not refcounted |
> | `List_string_push` | **1** | **1** | correct — retains the value, releases the slot's old occupant |
>
> `isRefCountedType` is now DECIDABLE inside a generic body. That is the whole of what F5 was blocked on.
>
> **Guards met.** Mono OFF: corpus 28/28 and IR **byte-identical** on all 17 compiled cases — the flag is
> the only thing that changes behaviour. Mono ON: corpus 28/28, **stable across 3 runs** (the guard this
> row asked for, because the bugs 4b replaces were intermittent). Growth measured at **1.33x**, against
> stage 3's projection of 1.29x.
>
> **What it actually took** (none of it was the clone):
> - `current_instantiation` on the compiler, consulted at the two render boundaries above.
> - N-copy expansion of `compiler.functions` — the list every phase already walks — so `local_types`,
>   prototypes and bodies all emit N times without being taught anything new.
> - `qualifySelfType`: sema types `self` as a BARE `List`, not `List<T>` (measured: `in=List<string>`,
>   `obj_type=List`). With no `T` to substitute, `self.grow()` bound to the erased `List_grow` while
>   `List_string_grow` sat emitted and uncalled — **a monomorphized body re-entering the erasure one call
>   deep**, which the symbol dump showed and no test would have.
> - `getFunctionParamType` matched only `Map_set`, so it returned `null` for every mono callee — which
>   skipped the ARC retain *and the trait-object construction beside it*, because both live under the same
>   `if`. That is why `12_traits_dispatch` failed.
> - The call-site retain (`retainIfGenericStore`) now **stands down for a monomorphized callee**: that
>   retain is the workaround for a body that cannot decide, and this body can.
> - `substituteFieldType`'s arg parser underflowed `depth` on `->` (`List<(int) -> string>`) — a compiler
>   PANIC, latent in G3 since it only ever saw field types. Fixed; fn-typed instantiations are skipped
>   rather than mangled, because folding `(int) -> string` and `int, string` to one symbol is a collision.
>
> **`retainIfGenericStore` is STILL NOT DELETABLE** — for the opposite reason to before. It is now dead
> for monomorphized callees and load-bearing for `Map`, which is excluded (below).
>
> **`Map` is excluded from mono, by name, and that is the next task.** Measured: `Map_string_i32_set` has
> `retain=0` and 14 raw `write_ptr`s — Map stores keys through `bytes.write_ptr` into `allocZero` memory,
> which carries **no ARC even when K is concrete**. The only thing that ever retained a Map key was the
> call-site retain that mono correctly withdraws, so the key is freed: `Expected 100, got 4367861072`
> (12_traits_dispatch) and `Expected 7, got 0` (13_serde), consistently. **Proven by exclusion:** with
> `Map` skipped, mono is 28/28 stable; with it included, exactly those two fail. Migrating `Map` to
> `Storage<T>` is F5 §3.4b's next link — and 4b was its blocker, so it is now unblocked.

> **F5's three O4 rules are ONE system, and they only balance together** (learned the hard way, 2026-07-15):
>
> ```
> return | transfer    ->  Storage<T>.get RETAINS          <- ⚠️ NOT IN FORCE (see below)
> store  | retain new  ->  Storage<T>.set RETAINS (+ release old)
> pass   | borrow      ->  nothing at the call site
> ```
>
> ⚠️ **Corrected 2026-07-16: rule 1 was never actually enabled.** `Storage<T>.get` does NOT retain
> (measured: `List_string_get` has `retain=0`). `a53827f`, the commit that claims to have enabled it,
> landed in a **dead** second copy of Storage (`compileStorageCall`, zero corpus hits, now deleted). So
> the paragraph below — and anything reasoning from "every call returns owned" — rests on a premise the
> compiler does not implement. See F5 §3.3's "O4 rule 'return | transfer' is NOT IN FORCE".
>
> Enabling them piecemeal produced a memory bug **every time**: `get` alone left `Map.resize` storing a
> value whose local then died (use-after-free); `set` alone double-retained with the call-site retain
> (leak); deleting the call-site retain alone made `push(concat(..))` leak the temporary. Applying all
> three together finally gave a *consistent* failure instead of an intermittent one — which is what
> located the real cause. **An intermittent failure means the model is wrong somewhere else; a
> consistent one means you have found it.**
>
> **The borrow-return audit (2026-07-15).** Of 123 `return <call>` sites in the stdlib returning a
> ref-counted type, all but nine are constructors returning a fresh +1. **Level 0 is exactly one:**
> `map.ky:125`, `return bytes.read_ptr(self.valsPtr, ...)`. **Level 1 is eight** that inherit it —
> `request.getHeader`/`getCookie`, `response.getHeader`, `app.param`, `source.getString`,
> `findHeaderVal`, `set.has`, `yaml.at`. Fixing `Map.get` fixes all nine, and the fix is the Storage
> migration — which needs 4b.


> **The letter-hardcode was already dead.** §2.3 documents `substitutePlaceholders` (T/K/V/U) as the
> root of the erasure and G3 as what deletes it. All three substituters were **unreachable** —
> `substituteGenericArgs` had 0 references, `substituteGenericType`'s only reference was a comment, and
> `substitutePlaceholders` was called by exactly those two plus itself. Deleted in 2467743: 62 lines,
> IR byte-identical. Both cases written to demonstrate the hardcode — `struct Pair<A, B>` (letters
> outside T/K/V/U) and `struct Swap<V, U>` (letters in swapped positions) — **pass**, because uniform
> boxing makes substitution unobservable. The erasure is real; the hardcode had not been its mechanism
> for some time.
>
> **There is no failing runtime test for G3, and there cannot be** — §4 says "F4 alone fixes nothing at
> runtime; that is expected". The verification is symbol-level plus corpus-green. The conformance case
> passes before and after: it is a regression guard, not a demonstration, and saying otherwise would be
> theatre.

| 5 | **G5: erased generics are fatal** | `.type_param` at codegen asserts. Delete the erasure path. | corpus green |
| 6 | **`generateSerdeBinders` folds in** | The source-emit-and-reparse hack (§2.6c) becomes a normal instantiation. | serde case green |

Stage 3's shadow mode matters: **monomorphization's cost is unknown until the instantiation set is
counted**, and the count is cheap to get without emitting anything.

---

## 6. Open questions

1. **Instantiation depth limit.** What number, and what does the error say? (§3.6 — blocking.)
2. **Bounds / constraints.** `T: Hash` needed for `Map<K,V>` (roadmap A2 names Hash/Eq). Does F4 include
   trait bounds, or is unbounded `T` enough for now? *Recommendation:* **unbounded in F4**; bounds are
   F4c, since Map today takes an explicit `hashFn` and works.
3. **Do methods on `List<T>` become methods on the instantiation?** Affects F1's mangling. Presumably
   yes, per §3.3.
4. **Separate compilation.** Monomorphization needs the generic's body at every use site. Kyte merges
   everything into one flat list today (F1 §2.1), so this is free *now* — but it forecloses separate
   compilation later. Accept and record.
5. **Dedup key.** §3.5 item 2 needs care: two instantiations with identical substituted bodies but
   different destructor targets are **not** interchangeable. Get this wrong and F5 leaks again.

---

## 7. Done criteria

- [ ] `List<string>` and `List<int>` are distinct `TypeId`s and distinct symbols
- [ ] `__destruct_List<string>` exists — the thing `arc.zig:34-40` says must exist
- [ ] `substitutePlaceholders` + the `T`/`K`/`V`/`U` hardcode deleted; substitution is by index
- [ ] The `len == 1 and 'A'..'Z'` test (`arc.zig:13`) deleted
- [ ] `struct Foo<A, B>` substitutes correctly — with a case (**fails today**)
- [ ] `StructInit` carries a `TypeRef`; `parser.zig:1461` no longer drops type args
- [ ] `.type_param` at codegen asserts; `getStructBaseName` is not a lookup key
- [ ] Recursion guard, with a case
- [ ] Symbol count and `.o` size growth measured and recorded (before vs after)
- [ ] specs grades: *Type checker — "generics erased at parse time"* removed
