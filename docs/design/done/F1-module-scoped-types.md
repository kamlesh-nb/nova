# F1 keystone — module-scoped struct/type resolution

**Status (2026-07-21): DONE — the co-existence capability is IMPLEMENTED.** Two modules may define the
same struct name and each resolves to its OWN. The diagnostic that enforced uniqueness is retired.
Verified: gate 77 (two modules, each a different `Widget`) + all 3 SQL drivers + web.app + web.mediator
+ web.routing together + a user struct colliding with a stdlib name — all ASAN+ARC clean; FUNC/SHADOW/ARC
99/99. What landed (matches the plan below):
- sema: `findTypeInModule(name, ctx)` resolves a bare name to the LOCAL definition first; the lowerer and
  the ~10 infer `findType` sites pass `current_module`; method `self_ty` in shadow.zig resolves
  module-scoped (was the bare-global bug that bound `self` to the wrong same-named struct).
- symbol table: `colliding_types` set + per-symbol precomputed `scoped_name`
  (`<legacyModulePrefix(file)>_<name>`); `scopedNameFor(name, file)` const lookup.
- codegen: `scopedStructName`/`isCollidingStruct` helpers; struct table keyed by scoped name; method
  mangling (`getStructPrefix`, `methodSymbol` owners) and construction sites (`Widget()` via the typed
  result) all route colliding structs through the scoped name. KEY GOTCHA: a constructor name must be
  built via `methodSymbol` (→ `mangleTypeName`, which escapes `-`→`_da` etc.), NOT raw — a raw
  `{name}_init` missed a scoped struct's init whose module path contained a hyphen (`nova-lang`).
- The whole change is a NO-OP when no struct name collides (gated on `colliding_types`), which kept the
  98→99 suite green at every stage.

--- ORIGINAL PLAN (as executed) ---

## Why it's a keystone (the load-bearing obstacle)

Codegen resolves structs by **bare name string**, deliberately:

- `LlvmCompiler.structs : StringHashMap(StructDecl)` keyed by `decl.name` (llvm_codegen.zig:2453),
  ~38 `structs.get`/`contains` lookup sites.
- Struct methods mangle as `<StructBaseName>_<method>` (`getStructPrefix` → `getStructBaseName`), so two
  `Mediator`s both emit `Mediator_send` into `func_map` — a method-name collision, not just a table one.
- `getStructBaseName` **collapses a module-qualified reference back to the bare name** (strips at the last
  `.`): `mod.Struct` → `Struct`. The bare-name assumption is an invariant the resolver relies on, not an
  accident — that's why this can't be band-aided.
- Sema is ALREADY module-aware: a struct `TypeId` carries `st.decl` (a module-unique `SymbolId`); two
  same-named structs are distinct TypeIds. The info is lost only when a type is **rendered to a bare
  string** for codegen (`sema/shadow.zig renderLegacy` `.struct_` arm → `sym.name`).

So the fix = make the codegen-facing NAME module-unique for colliding structs, consistently, at every
point that name is produced or consumed.

## Safety property that makes this tractable

The stdlib is now collision-free, so a **"module-qualify ONLY names that collide across modules"** rule is
a *no-op for all existing code* — the 98-case FUNC/SHADOW/ARC suite is guaranteed unchanged, and the new
path activates only on a real collision. Repro to develop against (currently blocked by the diagnostic):

```
a/wa.nova:  pub struct Widget { pub n: int  init(){self.n=1} pub fn val(self:Widget):int{return self.n} }
            pub fn mkA(): int { let w = Widget(); return w.val(); }
b/wb.nova:  pub struct Widget { pub s: string init(){self.s="x"} pub fn len(self:Widget):int{return self.s.length} }
            pub fn mkB(): int { let w = Widget(); return w.len(); }
main.nova:  import a.wa; import b.wb;  wa.mkA() + wb.mkB()   // never names Widget directly
```

## The one shared primitive

`scopedStructName(bareName, definingFile) -> []const u8`:
- if `bareName` ∈ **collision set** → `<legacyModulePrefix(definingFile)>_<bareName>` (underscore form —
  `getStructBaseName` does NOT strip `_`, so uniqueness survives normalization);
- else → `bareName` (unchanged).

Collision set = struct names declared in >1 distinct file. Compute ONCE in sema (the symbol table has every
struct symbol + its module); expose it so BOTH `renderLegacy` (sema) and codegen read the identical set.
`legacyModulePrefix` (symbols.zig) already mirrors codegen's `getModulePrefix`, so sema and codegen derive
the SAME string.

## Staged plan (each stage keeps 98/98 by the no-op property; add a collision gate at the end)

1. **Collision set** — sema computes `colliding_struct_names` while building the symbol table; expose via
   `live_sema`. Codegen reads the same set (or recomputes from `self.program.declarations` — must match).
   No behavior change yet.
2. **Rendering** — `renderLegacy` `.struct_` arm: `if name ∈ set → scopedStructName(name, moduleFile(sym))`.
   Now `resolveExpressionTypeName` returns the unique name for colliding structs everywhere it's used.
3. **Struct table + type sizes** — register `self.structs` and the size/offset tables under
   `scopedStructName(s.name, s.span.file)`. All `structs.get` sites already receive their key from
   `resolveExpressionTypeName` (stage 2) → they match. Audit the FEW sites that pass a raw `si.type_name`.
4. **Method mangling** — `getStructPrefix` returns `scopedStructName(base, fn_decl.span.file)` (the method
   is defined in its struct's module, so `span.file` is correct). Method DEFINITION and CALL now agree:
   the call resolves the receiver via stage 2 → unique name → `func_map.get(unique_method)`.
5. **Construction sites** — struct literal `T{}` and constructor call `T()`: resolve `T` to its unique name
   via the typed IR (`resolveExpressionTypeName(&the_expr)`), NOT the raw `si.type_name` / callee ident.
   These paths use the bare name pervasively (findEnumByVariant, getTypeSize, getFieldOffset) — compute the
   resolved name ONCE at the top of each arm and thread it.
6. **Vtables / trait objects** — `_vtable_<Struct>_<Trait>` and `constructTraitObject` use the struct name;
   route them through `scopedStructName` too, or a colliding struct's vtable collides.
7. **Retire the diagnostic** — with co-existence working, the "defined in two modules" error is removed
   (or downgraded to fire only on a genuine SAME-FILE duplicate). Add a conformance gate = the repro above
   (mkA + mkB, distinct field/method shapes, ASAN + ARC clean).

## Risks / watch-items
- Any hardcoded struct-name string compare would break — but those are for BUILTINS (`string`, `i32`), not
  user structs, so they're safe (verified: user names are never hardcoded).
- `getStructBaseName` MUST NOT strip the underscore prefix (it strips `.` and `<` only — confirmed).
- Enum/union share the same bare-name keying; the same treatment applies if they ever collide (out of scope
  now — no enum/union name collides in the stdlib).
- The prefix must be byte-identical between sema (`legacyModulePrefix`) and codegen (`getModulePrefix`) or
  definition/reference names diverge — pin BOTH to `legacyModulePrefix` in the shared primitive.

## Interim contract (in force today)
A struct name must be unique across all loaded modules; the type checker enforces it with a located error.
This is sound (no silent miscompiles) and is what the renames + diagnostic delivered. This doc is the plan
to lift that restriction.
