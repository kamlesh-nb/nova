# Route Handling via Mediator — Generic Traits + Minimal-API Design

**Status:** Planned. Start date: 2026-07-17.
**Goal:** Give Kyte the developer experience of **.NET MediatR** (typed `IRequestHandler<TReq, TResp>`,
handlers auto-discovered, pipeline behaviors) fused with **.NET 7 Minimal API** (`app.MapGet<T>`,
automatic model-binding, automatic JSON serialization of the returned object).

This doc is the plan of record. It supersedes the string-keyed `app.get<T>` / `app.on<T>` design that
was prototyped and **rejected** (too much ceremony: `handle(req: any)` + manual `as` downcast + a
separate `on<T>` registration). See "Working-tree state" at the end for what to keep vs revert.

---

## 1. Target developer experience

```kyte
@serializable
struct GetUser { pub id: int }

@serializable
struct UserDto { pub id: int, pub name: string }

// IRequestHandler<GetUser, UserDto> — fully typed. No `any`, no downcast.
struct GetUserHandler impl Handler<GetUser, UserDto> {
    fn handle(self, req: GetUser): UserDto {
        return UserDto{ id: req.id, name: "Ada" };
    }
}

let app = App();
app.mapGet<GetUser>("/api/user/{id:int}");   // binds -> GetUser -> mediator -> handler -> UserDto -> JSON
app.mapPost<CreateUser>("/api/user");
app.run(8080);
```

The developer writes: the message, the DTO, and the typed handler. One line registers the endpoint.
No `any`, no `as` downcast, no manual JSON, no separate handler registration.

Behind `mapGet<GetUser>(route)` the compiler/framework:
1. finds the `Handler<GetUser, _>` impl (MediatR-style auto-discovery, resolved at compile time —
   missing/ambiguous handler is a **compile error**),
2. reifies the generated `GetUser__bind(src)` binder,
3. builds the request `ValueSource` (route params `@fromRoute` overlaid on body `@fromBody`),
4. dispatches through the **canonical mediator pipeline** (`web/mediator.ky`: behaviors, pre/post,
   exception handlers),
5. serializes the returned `UserDto` via the generated `UserDto__toJson`,
6. wraps it in a `Response`.

**Open ergonomics decision (settle when building the framework, NOT a compiler blocker):**
handler auto-discovered by its `Handler<GetUser, _>` impl (zero registration) vs passed once
(`app.mapGet<GetUser>(route, GetUserHandler())`). Recommendation: auto-discovery — it is the MediatR
feel and the compiler already has all the information.

---

## 1.5 Naming standard (traits & type parameters)

Adopted for the framework and any generic trait going forward. Mirrors .NET MediatR's clarity
(`IRequestHandler<TRequest, TResponse>`) without the C# `I`-prefix, which Kyte doesn't need — a trait
is already declared with `trait`/`impl`, so the kind is explicit at every use site.

**Type parameters**
- **Domain/role params: descriptive `T`-prefix, PascalCase** — `TRequest`, `TResponse`, `TMessage`,
  `TResult`, `THandler`. A reader sees the role, not a cryptic letter.
- **Bare single letters (`T`, `K`, `V`, `E`) are reserved for structural containers** where the param
  has no domain meaning: `List<T>`, `Map<K, V>`, `Storage<T>`.

**Framework traits** (MediatR-shaped)
| Kyte trait | .NET analogue | shape |
|---|---|---|
| `Request<TResponse>` | `IRequest<TResponse>` | marker on a message struct; declares its response type |
| `RequestHandler<TRequest, TResponse>` | `IRequestHandler<TRequest, TResponse>` | `fn handle(self, req: TRequest): TResponse` |
| `PipelineBehavior<TRequest, TResponse>` | `IPipelineBehavior<...>` | `fn handle(self, req: TRequest, next: () => TResponse): TResponse` |
| `PreProcessor<TRequest>` | `IRequestPreProcessor<TRequest>` | `fn process(self, req: TRequest): void` |
| `PostProcessor<TRequest, TResponse>` | `IRequestPostProcessor<...>` | `fn process(self, req: TRequest, res: TResponse): TResponse` |
| `ExceptionHandler<TRequest, TResponse>` | `IRequestExceptionHandler<...>` | `fn handle(self, req: TRequest, err: string): TResponse` |

**Trait name style:** PascalCase, no `I` prefix. (Open choice, flag if you want the literal `I`-prefix to
match .NET one-for-one — trivial to switch, purely stylistic.)

Example, fully spelled out:
```kyte
@serializable
struct GetUser impl Request<UserDto> { pub id: int }

struct GetUserHandler impl RequestHandler<GetUser, UserDto> {
    fn handle(self, req: GetUser): UserDto { return UserDto{ id: req.id, name: "Ada" }; }
}
```

## 2. Why the ideal design was blocked (the honest finding)

Probed against the real compiler (not assumed):
- **Generic traits are NOT supported.** `trait Handler<Q, R> { ... }` fails at the *parser*
  (`error.ExpectedToken`). `StructDecl.impls: [][]const u8` records trait names as **bare strings with
  no type args** — the compiler cannot even represent `impl Handler<GetUser, UserDto>`.
- `@serializable` **does** generate `<S>__toJson(obj): string` (`main.zig:332`) — auto-JSON is available.

So the literal `impl Handler<GetUser, UserDto>` syntax requires building **generic traits** first.

---

## 3. Generic traits: feasibility & scope (the enabling feature)

**Verdict: possible, and cheaper than a typical generic-traits feature — because trait dispatch in
Kyte is already fully type-erased.** Every value is one i64 handle (`val_type = i64`,
`llvm_codegen.zig:339`); the trait vtable call is built with all-i64 params + i64 return regardless of
declared types (`llvm_codegen.zig:1318-1323`), so `Handler<GetUser,UserDto>::handle` and
`Handler<Foo,Bar>::handle` compile to byte-identical call sites — **one vtable slot per method serves
every instantiation.** `StructDecl.impls` is **never read by codegen** (only sema, formatter, and a
Controller check read it). The type arguments `Q`/`R` are therefore a **compile-time-checking concern
only**.

**→ Codegen needs ZERO changes. No trait monomorphization.** This is the crux that makes it small.

### Stage-by-stage plan (all file:line anchors verified 2026-07-16)

**Parser** (~1 hr, very low risk — mirrors existing struct code)
- `parseTraitDecl` (`parser.zig:637-686`) dies at line 641 (`expect(.left_brace)` on a `<`). Insert the
  struct's 9-line type-param loop from `parser.zig:417-426` between reading the name and the `{`.
- `parseStructDecl` impl loop (`parser.zig:430-437`) reads a bare trait `identifier`; after each name,
  optionally parse `<...>` type args (reuse `parseTypeRef` at `parser.zig:758-767`).

**AST** (~2 hrs, low risk — mechanical ripple)
- Add `type_params: []const []const u8 = &.{}` to `TraitDecl` (`ast.zig:98-103`), identical to
  `StructDecl.type_params` (`ast.zig:56-58`).
- Widen `impls: [][]const u8` (`ast.zig:54`) to carry type args per impl, e.g.
  `[]struct { name: []const u8, args: []TypeRef }`. Fix the 4 readers: `parser.zig:502`,
  `formatter.zig:201-203`, `main.zig:109` (Controller check — name only), `type_checker.zig:348,911`.

**Sema** (~1 day, MODERATE risk — the only real logic)
- Trait registration (`symbols.zig:413-425`) already stores the whole `TraitDecl`, so `type_params`
  come along for free.
- `traitMethodReturn` (`infer.zig:1091-1102`) must substitute `Q`/`R`. It explicitly punts today
  (`infer.zig:1089-1090`: "Traits are not generic today ... nothing to substitute"). Reuse the
  generic-struct machinery: `subst.substitute` (`subst.zig:40`), `ParamScope`/`typeParamRef`
  (`lower.zig:165`), and the `lowerInStructScope` pattern (`infer.zig:734-745`). Decide: add `args` to
  the store's `trait_` type (`types.zig:94`, mirroring `StructType`) OR resolve args from the receiver
  struct's impl entry. **Prefer adding `args` to `trait_`** — symmetric with structs, and the impl
  entry already carries them after the AST change.
- Impl-conformance check (`type_checker.zig:910-930`, `structImplementsTrait` at `344-352`) must
  substitute trait params before comparing method signatures (else it compares `Q` vs `A`).

**Codegen** — **nothing.** Dispatch (`llvm_codegen.zig:1288-1345`), vtable (`getGlobalVTable`,
`1005-1062`), the 16-byte fat pointer (`arc.zig:294-296`), `constructTraitObject`, and
`__destruct_trait` (`arc.zig:297-320`) are all unchanged.

**Tests** (~half day) — conformance cases: generic trait 1 param, 2 params, dispatch through a trait
object, impl-conformance error when a method signature mismatches after substitution.

**Estimate: ~2–3 focused days for the language feature.** Risk concentrated entirely in the sema
substitution; codegen (the historically risky part) is untouched.

---

## 4. Framework layer (on top of generic traits)

After generic traits land, build the minimal-API/mediator framework:

1. **`Handler<Q, R>` trait** in `web/mediator.ky`: `fn handle(self, req: Q): R;`. Replaces the
   `any`-based `RequestHandler`. Pipeline traits (`PipelineBehavior`, pre/post, exception) stay.
2. **Handler discovery**: at compile time, scan structs impl-ing `Handler<Q, _>` to build a
   request-type → (handler, `handle` fn-ptr, response type) map. Ambiguous/missing = compile error.
3. **`app.mapGet<T>` / `mapPost<T>` / `mapPut` / `mapDelete` / `mapPatch`**: codegen lowering (same
   pattern as the prototyped `get<T>`, and as `json.parse<T>`) — reify `T` into the `T__bind` binder +
   the discovered handler's `handle` fn-ptr + the `R__toJson` serializer, register the route.
4. **Dispatch**: match route → build `ValueSource` (GET: `ParamSource(route+query)`; POST/PUT/PATCH:
   `CompositeSource(route, body)` — `@fromRoute` over `@fromBody`) → `T__bind(src)` → mediator pipeline
   → `handle(req)` → `R__toJson` → `Response`. All typed; no `any`, no downcast.
5. **Auto-JSON**: response type `R` inferred from the handler's `handle` return; serialize with
   `R__toJson`.

Much of this plumbing was prototyped this session and is reusable: `serde.callBinder`, `CompositeSource`
(both in `serde/source.ky`), the async server framing in `app.ky` (Content-Length, 100-continue,
keep-header-read), and the codegen reify pattern for `<T>__bind` fn-pointers.

---

## 5. Foundational fixes already landed / in-tree this session

These are **keepers regardless of the framework design** — general compiler bug fixes surfaced while
prototyping (web/request.ky and app.ky had never actually compiled):

- **Tuple-return ARC** (COMMITTED `4464c04`): returning a tuple of computed heap values corrupted them;
  now retains refcounted elements at the return boundary. Gate `28_tuple_return_heap`.
- **Namespace-receiver capture** (module functions COMMITTED `4464c04`; module-TYPE extension still
  UNCOMMITTED in `llvm_codegen.zig`): a module/type receiver used inside a closure was captured as a
  phantom free variable (`url.decode`, then `response.Response(...)` inside `mediator.send`'s closures).
  `isNamespaceReceiver` now also recognizes module-qualified types (member is a struct/enum). This makes
  `mediator.ky` compile. **Held uncommitted for the framework work** — it only benefits the framework,
  and it cannot be gated standalone yet (see the new bug below). Commit it tomorrow WITH a gate once the
  module-qualified-type-in-closure codegen bug is addressed.
- **Optional see-through for member access** (COMMITTED — the keeper commit): `list.get(i).field` /
  `map.get(k).method()` now resolve — `fieldType`/`methodReturn` see through a leading `.optional`
  (`T | undefined`). Previously only the `?? default` form worked. Gate `30_optional_member_access`.

### New bug found while gating (record for tomorrow)
Constructing or calling a method on a MODULE-QUALIFIED TYPE **inside a closure in the main program**
fails in codegen — `response.Response(...)` → `StructTypeNotFound` (`llvm_codegen.zig:868`
`getFieldOffset`, via `expressions.zig:2173`); `Status.Ok.toCode()` → `MethodOrFunctionNotFound`. The
lifted closure function loses the struct/enum resolution for the qualified name. `mediator.ky` works
only because it is compiled IN its own module context. The framework's user code (handlers returning
`app.json(...)`) likely avoids this, but it blocks a clean standalone conformance gate for the
namespace-type capture fix, and should be fixed so module-qualified types work uniformly in closures.

---

## 6. Working-tree state (reconcile before starting)

Uncommitted changes implement the **rejected** string-keyed design mixed with keeper fixes. Tomorrow:

- **KEEP:** optional see-through (`infer.zig` `fieldType`/`methodReturn`), `isNamespaceReceiver`
  module-qualified-type extension (`llvm_codegen.zig`), `serde.callBinder` + `CompositeSource`
  (`serde/source.ky`), the `app.ky` async-server + `HttpRequest`/parser + response helpers +
  form/multipart sources.
- **REPLACE:** the `app.get<T>`/`on<T>` codegen lowering (`expressions.zig` App-routing block) and the
  App-void sema branch (`infer.zig` generic_call) → become `mapGet<T>` with generic-trait handlers.
  The `App.addRoute`/`registerFor` string-keyed helpers and the `RequestHandler(any)` wiring in
  `app.ky` → replaced by `Handler<Q,R>` + discovery.
- **DELETE eventually:** the rejected `app.on<T>` path once `mapGet<T>` + discovery is in.

Suggested first commit tomorrow: split out the keeper fixes (optional see-through, namespace-type
capture) as their own commit with conformance gates, so the framework rewrite starts from a clean base.

---

## 7. Execution order (tomorrow)

1. Commit the keeper foundational fixes with gates (optional see-through; namespace-type capture).
2. Generic traits: parser → AST → sema, a conformance case green at each step. (~2–3 days)
3. `Handler<Q,R>` trait + compile-time handler discovery.
4. `mapGet<T>`/`mapPost<T>`/... lowering + typed dispatch + auto-JSON.
5. End-to-end conformance: typed handler, route+query bind, `@fromRoute`+`@fromBody`, 404/405, auto-JSON.
6. Update `kyte-readiness-roadmap.md`; refresh the `kyte init app` template to the new API.

See also: `kyte-app-generic-mediator` memory, `kyte-serde-codegen`, `kyte-f4b-monomorphization`,
`kyte-trait-dispatch-foundation`, `docs/design/F4-generics.md`.

---

## 8. Pending activities backlog (inventory — 2026-07-17, UNPRIORITISED)

Everything below was **measured**, not assumed — each item names the evidence or the `file:line` that
proves it. This is a raw inventory; §7 above is still the mediator execution order. Prioritisation is a
separate pass (see §9 once written).

Origin: an error-handling design question ("throw vs Rust/Go/Zig") that turned into an audit of the
three mechanisms an error design would have to rest on — tuples, enum payloads, and optionals. All three
have gaps. The audit method that produced these: run the case, then run a **negative control** to prove
the test can fail. Several earlier "it works" beliefs did not survive that.

### 8.A — Conformance harness integrity (blocks *verifying* everything else)

The harness cannot currently distinguish "rejected by the compiler" from "crashed". Until this is fixed,
every negative result below is unfalsifiable and any check can regress silently.

- **A1. `expect_fail` judges by exit code only.** `conformance/run.sh` treats any non-zero exit as
  "rejected as expected". A **segfault also exits non-zero**, so a case that compiles and crashes is
  reported as a passing negative test. Must assert the *reason* (typechecker diagnostic) not just exit≠0.
- **A2. `return_type_mismatch` has silently REGRESSED.** `conformance/expect_fail/return_type_mismatch.ky`
  (`fn f(): string { return 42; }`) **compiles and segfaults** today. `expect_fail/PENDING.md` documents
  this check as DONE and enabled (`checkReturnType` wired into `.return_stmt`). The harness reports it
  PASS because of A1. Measured: 10/16 negative cases genuinely reject; this one does not.
- **A3. 4 negative cases "pass" via compiler crash, not diagnostic.** `undefined_variable`,
  `undefined_function`, `method_shadowed_by_global_fn`, `ambiguous_bare_call` exit non-zero by throwing
  an unhandled Zig error with a stack trace (`error: IdentifierNotFound` etc.), not a user-facing
  diagnostic. Sound but terrible UX; they should become real diagnostics.
- **A4. The corpus runs with leak checking OFF.** `conformance/run.sh` never sets `KYTE_ARC_AUDIT`, so
  no case has ever gated on leaks. Turning it on is how 8.D3 stayed invisible. (Note: the audit env var
  is `KYTE_ARC_AUDIT`; `KYTE_ARC_DUMP` alone reports nothing — `alloc.cpp:59`.)
- **A5. No enum conformance case exists at all.** `grep` over `conformance/cases/` finds none, which is
  why 8.E1 was never caught.

### 8.B — Optionals (`T | undefined`): a live segfault, and a design conflict

Runtime half works: `??`, `?.`, `!= undefined` narrowing, and `list.get()` returning undefined all
produce correct values (verified). The **static half does not exist**.

- **B1. No narrowing enforcement anywhere.** `type_checker.zig` has no narrowing machinery — every hit
  for "narrow" is integer-width conversion (F3 §6). There is no `.optional` arm in the field-access path
  (`type_checker.zig:761-793`, `else => {}` → `resolveExprType` returns null), so all downstream checks
  silently skip.
- **B2. Unnarrowed access on an absent value SEGFAULTS.** `let s = l.get(5); let n = s.length;` compiles
  and crashes — the exact null dereference spec §3.4 says "the type system exists to prevent". Live in
  the current stdlib: `list.get`/`map.get` return optionals everywhere.
- **B3. Every unsound direction compiles with no diagnostic:** assigning `string | undefined` to a
  `string`, passing it to `fn takes(s: string)`, returning it from `fn(): string`, and member access.
  Not a resolver blind spot around `l.get()` — explicitly annotated
  `let s: string | undefined = "hi"; let x: string = s;` is equally unchecked.
- **B4. ⚠️ DESIGN CONFLICT with the §5 keeper commit `950495c`.** "Optional see-through for member
  access" *deliberately* made `list.get(i).field` / `map.get(k).method()` resolve without narrowing
  (`infer.zig` `fieldType`/`methodReturn` see through a leading `.optional`), gated by
  `30_optional_member_access`. That ergonomic win is **exactly the hole in B2**. These two cannot both
  stand as-is: either see-through is restricted to `?.`/`??` forms, or §3.4 is rewritten to admit
  optionals are unchecked. **Must be reconciled before either is called done.**
- **B5. Early-exit narrowing limit** (already recorded in spec §3.4a): `if (s == undefined) { return; }`
  does not narrow the code after it — needs reachability, not just scoping. This bites error handling
  hard, since early-return *is* the idiom. `try` sugar (8.C4) sidesteps it by generating the narrowing.
- **B6. Measure stdlib blast radius BEFORE enforcing.** Precedent: `isTypeCompatible`'s numeric
  permissiveness is commented as "LOAD-BEARING ... Tightening it breaks all stdlib compilation"
  (`type_checker.zig:1090-1095`). Count the stdlib sites relying on unnarrowed optional access first —
  this is a grep-and-count job, not a guess.
- **B7. Not in `PENDING.md`.** Unlike the private-field and arg-count gaps, this soundness hole is
  undocumented. Add it.

### 8.C — Error handling model (the original question)

Current `throw`/`catch` is **not** exceptions in any usable sense; recommendation is to remove it rather
than invest in it. Evidence:

- **C1. `throw` is an integer longjmp.** `kyte_throw(long long)` (`runtime/core.cpp:162`) does
  `std::longjmp`; the catch binding is `zext(setjmp_res)` — an **i32** (`statements.zig:587`). You cannot
  throw a string/struct/enum; the value is truncated to 32 bits, and `throw 0` silently becomes `1`.
- **C2. No unwinding ⇒ guaranteed ARC leaks.** The catch path only releases locals collected lexically
  from the *catching* frame's try block (`collectLocalVarNames(&try_locals, tc.try_block)`,
  `statements.zig:559-580`). Every frame between `throw` and `catch` leaks everything it owned — and a
  throw across a call boundary is the only interesting kind. `drainTemporaries` never runs.
- **C3. `longjmp` out of a fiber is UB, and out of a C++20 coroutine is UB.** Directly collides with
  `runtime-cpp20-plan.md`. Making it real needs LLVM `invoke`/`landingpad` + a personality function +
  cleanup pads emitting ARC releases at every frame — then re-solving it for coroutines.
- **C4. DECISION (recommended, not yet ratified): Zig-shaped `T | Error`.** `!T`-style union +
  `try` (propagate) + `catch` as an expression (the error-side twin of `??`) + `errdefer` (pairs with
  existing `defer`). Error side = ordinary tagged enum **with payloads**, consumed by existing `switch`
  — Zig's control flow with Rust's expressiveness. Rejected: **Rust** `Result<T,E>` (needs `From`-based
  conversion traits for `?`, plus boxed errors = ARC traffic per failure); **Go** tuples (see 8.D — and
  its defining property is that ignoring the error is the default).
- **C5. Spec §5.5 must be rewritten.** It currently says "`try`/`catch`/`throw` — ✅ exceptions exist",
  which overstates C1–C3. Per the spec-first rule, the `T | Error` section lands in `specs.md` **before**
  implementation.
- **C6. Representation decision — the real work.** `T | undefined` uses a sentinel; `T | Error` cannot
  (the error is a value). Low-bit pointer tagging **breaks on `int | Error`** (odd ints read as errors).
  Heap-boxing `{tag,payload}` costs an allocation on **every success** — that's the tuple design and is
  wrong for the hot path. Principled answer: return `{i64 tag, i64 payload}` **in two registers**
  (x86-64 SysV / AArch64 AAPCS both return 16-byte aggregates in registers, zero memory traffic). Codegen
  returns a single i64 today. **This same capability is what fixes tuples properly (8.D6)** — one
  foundation, two payoffs.
- **C7. Stack traces: none exist today.** `kyte_get_stacktrace()` is a stub — `return kyte_bytes_alloc(0)`
  (`core.cpp:172`); `exception.getStackTrace()` returns a zero-length string (verified). So `throw`
  provides **no** trace and there is nothing to lose by dropping it.
- **C8. Stack traces are compatible with `T | Error`.** Capture at error *construction* (same site a
  throw would capture) via `backtrace()`/`backtrace_symbols()` from `execinfo.h` — the runtime is C++,
  so this works natively on macOS/Linux; host import for WASM. Gate behind a debug flag (µs cost).
  `try`-propagation loses nothing: the trace was already captured at the failure site.
- **C9. Error context chains (`%w`-style wrapping) matter MORE than traces here.** Under a fiber /
  coroutine scheduler a stack trace shows the scheduler, not the logical caller. Design the wrapping
  story alongside C4.

### 8.D — Tuples: silent corruption (independent of the error decision)

> ## ✅ THE ARC HALF IS FIXED (2026-07-17) — D3, D5, D6, D7 closed. D1/D2/D4 remain.
> **Measured: `28_tuple_return_heap` 68 → 3 (the floor), `29_http_request_parse` 46 → 6.
> Corpus above-floor ~118 → ~6.** Corpus 48/48, stable ×5; unit tests 107/107.
>
> The fix was NOT the one this backlog predicted. D7 said rendering `"<tuple>"` as `(a,b)` would
> "light up the retain/release paths that are already written" — **it changed the leak by exactly
> zero**, twice. The IR showed both halves already firing and cancelling. What was actually wrong:
> 1. **The box owned nothing.** Construction stored each element's word RAW; a retain at the RETURN
>    boundary patched it, guarded *syntactically* on `v.kind == .tuple` — so it fired only for a
>    tuple LITERAL in return position. Now construction retains and `__destruct_tuple_*` releases:
>    **ownership is a property of the box, not of the syntax at one use site.** That is what fixes
>    `return t` (D5) for the same reason it fixes the literal.
> 2. **Nothing ever released the box.** `consumeTemporary` unregistered it on the "a local now owns
>    it" rule — true for `let x = e`, false for `let (a,b) = e`, where no local owns the box. Now
>    left registered so the statement's drain releases it *through the destructor*.
> 3. **Destructured locals were never block-owned.** `owned_locals` registration was gated on
>    `ls.names == null`. Invisible at function scope; a linear leak in a LOOP — 20 iterations
>    released only the last pair (`x19 "A"`, `x19 "B"` survivors).
> 4. **⚠️ Sema never bound destructured names** (`infer.zig` bound only `ls.name`, which is `""` for
>    a destructuring `let`). So `let (a,b) = f(); let t = (b,a);` rendered `t` as
>    `(unresolved,unresolved)` — and its destructor released two elements construction had never
>    retained. **An over-release, i.e. a use-after-free, caused by a missing bind.** Found only
>    because a new conformance case exercised it; it is now `test_tuple_rebuilt_from_destructured`.
>
> **Still open — the TYPE-CHECKER half (D1, D2, D4).** `type_checker.zig` is a separate engine from
> sema's `infer.zig` and still never reads `ls.names`, so `v + e` (int + string) still compiles and
> arity is still unchecked in both directions. Verified after the fix. See `PENDING.md`.



Tuples are **not** a candidate for the error model, but they are live in `web/request.ky`,
`datetime.ky` (a 6-element destructure) and `yaml.ky`, so these are real bugs today. What works:
tuple types parse in every position; `let (v, e) = f()` destructures; heap elements survive the
happy path.

- **D1. The type checker is blind to tuples.** No `.tuple` case in `resolveExprType` (`type_checker.zig:698-880`,
  `else => return null` at `:879`), and **`ls.names` — the destructuring field — is never read anywhere in
  `type_checker.zig`**. Destructured bindings are never registered, so they have no type.
- **D2. Consequence: element types are unchecked.** `let (v, e) = divide(10,2)` where `e: string`, then
  `v + e` compiles and yields `4304536869` — a **raw string pointer added to 5**, no diagnostic.
- **D3. Every tuple leaks — and the leak is LOAD-BEARING.** Measured over 100 iterations with
  `KYTE_ARC_AUDIT=1`: single-`string` return → 3 survivors (flat baseline); `struct` return → 3 (flat);
  `(string,string)` return → **303** (box + both elements, every call). The unbalanced retain is the only
  thing preventing use-after-free.
- **D4. Arity unchecked in both directions.** Destructuring 3 names from a 2-tuple compiles (reads out of
  bounds); returning a 3-tuple from a `(int,string)` signature compiles.
- **D5. `return t` via a local is a USE-AFTER-FREE.** The retain guard is *syntactic* — `v.kind == .tuple`
  (`statements.zig:362`) — so it only fires on a tuple **literal** in return position. Taking conformance
  case `28_tuple_return_heap`'s `splitOnColon` and changing only `return (key, val)` to
  `let t = (key, val); return t;` yields garbage (`Expected "Host", got "\xef..."`). Same for
  `return cond ? (a,b) : (c,d)`, tuple stored in a struct field, or tuple captured by a closure.
  **Case 28 gates the one shape that works.**
- **D6. No tuple destructor exists.** `getOrCreateDestructor` returns null for any tuple
  (`arc.zig:407-409` — not in `self.structs`), while `isRefCountedType` is a catch-all returning true
  (`arc.zig:12-31`). Net: the box is freed via `kyte_release(box, null)` and **every element leaks**.
- **D7. Root cause of D6, and the cheapest high-leverage fix: `shadow.zig:588` renders every tuple type
  as the literal string `"<tuple>"`.** That doesn't start with `(`, so `getTupleElementType`
  (`llvm_codegen.zig:419-434`) returns `"i32"` for **every element of every destructuring, always**
  (`llvm_codegen.zig:2583-2590`). So `isRefCountedType("i32")` is false ⇒ the destructuring retain never
  fires, and `releaseLocalVariables` never releases them. **The retain/release paths are already written
  and are simply unreachable.** Fixing the rendering lights them up.
- **D8. `getTupleElementType` splits on `","` naively** — `(Map<string,int>, int)` would yield
  `"Map<string"`. Needs depth-awareness over `<>`. (`lower.zig:8-9` already calls out this exact
  round-trip fragility.)
- **D9. Mono worklist drops tuples.** `mono.zig:150` `note()` bails with `if (ty != .struct_) return;`
  before recursing, so `(List<int>, string)` never notes `List<int>` — that instantiation may go
  un-emitted unless mentioned elsewhere.
- **D10. Principled fix** = a real tuple destructor keyed off `TypeId` rather than re-parsing rendered
  text — which converges with **8.C6** (two-register returns). Interim = D7.

### 8.E — Enum payloads (the `T | Error` prerequisite)

- **E1. Payload binding silently depends on the discriminant.** Works when switching on a **parameter**
  or a **call result**; **fails when switching on a local** — `let e = E.BadDigit(7); switch (e) { case
  E.BadDigit(pos): ... }` → `Identifier 'pos' not found`. Root cause: the payload-binding block is gated
  on `is_tagged_union`, computed from `resolveExpressionTypeName(&ss.discriminant)`
  (`statements.zig:629`); `let e = E.BadDigit(7)` doesn't infer to `E`, so the gate is false and the
  binding never happens. **Workaround: annotate — `let e: E = E.BadDigit(7)` passes** (verified,
  including a string payload under ARC audit).
- **E2. This is on the `T | Error` critical path.** `let r = parse(s); switch (r)` — switching on a local
  — is precisely the idiomatic shape. `yaml.ky` never hit it because every switch there is on a
  parameter.
- **E3. Fails loudly (compile error), unlike 8.D which fails silently at runtime.** Narrow and fixable;
  it is local type inference for enum-constructor initialisers, not a design flaw.

### 8.F — Carried over from §5 (unchanged, still open)

- **F1. Module-qualified type inside a closure fails in codegen** — `response.Response(...)` →
  `StructTypeNotFound` (`llvm_codegen.zig:868` via `expressions.zig:2173`); `Status.Ok.toCode()` →
  `MethodOrFunctionNotFound`. Blocks a clean standalone gate for the namespace-type capture fix. See §5.

### 8.G — Cross-cutting notes

- **G1. The `let` convention gap is the same shape as B1.** Spec §5.1 admits `let` is not
  enforced-immutable; optionals are now a second "working convention with no static guarantee". Worth
  deciding whether Kyte claims enforcement or documents convention — consistently.
- **G2. Deferred items already tracked in the `kyte-deferred-backlog` memory are not duplicated here.**
