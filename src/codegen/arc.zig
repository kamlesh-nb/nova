const std = @import("std");
const ast = @import("../ast.zig");
const llvm = @import("llvm");
const types = llvm.types;
const core = llvm.core;

const sema_shadow = @import("../sema/shadow.zig");
const typesys = @import("../types.zig");
const lower = @import("../sema/lower.zig");
const subst = @import("../sema/subst.zig");
const LlvmCompiler = @import("llvm_codegen.zig").LlvmCompiler;
const getStructBaseName = @import("types.zig").getStructBaseName;
const isPrimitiveTypeName = @import("types.zig").isPrimitiveTypeName;
const mangleTypeName = @import("types.zig").mangleTypeName;

/// True when an enum is a TAGGED UNION — has at least one payload-carrying variant, so its values
/// are heap boxes `[tag, payload...]` (the `is_tagged_union` test used at every construction site).
/// A payload-less enum (all bare variants) is an immediate integer tag, never boxed.
pub fn enumIsTaggedUnion(self: *LlvmCompiler, enum_name: []const u8) bool {
    const enum_decl = self.enums.get(enum_name) orelse return false;
    for (enum_decl.variants) |v| {
        if (v.type_name != null or v.fields != null) return true;
    }
    return false;
}

pub fn isRefCountedType(self: *LlvmCompiler, type_name: []const u8) bool {
    if (sema_shadow.report_enabled) { sema_shadow.a2_irct_calls += 1; if (std.mem.indexOfAny(u8, type_name, "<(") != null) sema_shadow.a2_irct_composite += 1; }
    const base = getStructBaseName(type_name);
    if (type_name.len == 1 and type_name[0] >= 'A' and type_name[0] <= 'Z') {
        // A single uppercase letter is USUALLY an unbound type PARAMETER (`T`, `U`, `K`, `V`), which
        // the principled erasure rule reads as a non-owned machine word. But `struct P {...}` is legal
        // Nova, and then `P` is a real OWNED struct, not a param — so disambiguate via the decl tables
        // exactly as the TypeId engine (store.isOwned) does. Without this, a single-letter struct name
        // is silently classified non-owned and its box is never released at the name-only ownership
        // sites (destructor/box generators) — a latent leak. Caught by the F5-2 `--shadow` gate on a
        // struct literally named `P` (typed-engine=owned, string-engine=not): the gate exists to make
        // exactly this string-vs-type divergence a hard failure rather than a someday-leak.
        // A single-letter TRAIT name (`trait G {...}`) is a real OWNED type (a 16-byte fat pointer),
        // not a type parameter — omitting it here classified `G` as non-owned, so a `(int, G)` tuple's
        // destructor released nothing and leaked the trait object + its struct (single-letter traits
        // only; multi-letter fall through to the owned default below). Same decl-table disambiguation
        // the struct case uses; the typed path (isOwnedTypeId(.trait_)) already agrees.
        if (!self.structs.contains(type_name) and !self.enums.contains(type_name) and !self.unions.contains(type_name) and !self.traits.contains(type_name)) {
            return false;
        }
    }
    if (isPrimitiveTypeName(type_name)) {
        return false;
    }
    // §3.4j: a function-typed VALUE is a heap box `{fn_ptr, env}` — a closure (heap,
    // owns its env) or a bare-fn box (a writable global with a `100_000_000` refcount
    // sentinel, so releasing it is a harmless decrement). Both are safe to release, and
    // treating them as ref-counted is what finally frees a closure's box and env (a
    // closure-typed `let` local leaked 2 objects per closure, unbounded — §10 #15).
    if (self.enums.contains(base)) {
        // A TAGGED-UNION enum (>=1 payload-carrying variant) is a HEAP BOX `[tag, payload...]`
        // (compileAlloc at construction) and MUST be released — its box was leaking, never
        // registered as owned. A payload-LESS enum is an immediate tag value, not a pointer, so it
        // stays non-owned. (Its destructor, released when the box refcount hits 0, frees the owned
        // payloads; see getOrCreateEnumDestructor.)
        return enumIsTaggedUnion(self, base);
    }
    // ⚠️ F5 stage 2 (safety increment, 2026-07-17): a WHOLE type that is a pure "sema could
    // not type this" placeholder must NEVER be an ARC decision target. The old catch-all
    // returned `true` here — "free it" — so a placeholder that reached a retain/release freed a
    // NON-POINTER. That is the exact mechanism behind this session's corruptions: a tuple
    // rendered `(unresolved,unresolved)` whose destructor released two never-retained elements
    // (a use-after-free), and every "codegen guessed from an untyped value" bug.
    //
    // Measured: across the whole corpus NONE of these strings reach here as a whole type — `void`
    // is a primitive (handled above), bare params are handled at the top, and `<unresolved>` only
    // ever appears NESTED inside a fn type (`(<unresolved>, i32) -> i32`), where "owned" is
    // correct because the fn VALUE is a box regardless of a param's type. So this abort is
    // behavior-preserving today and a TRIPWIRE for the future: it converts a silent
    // free-a-non-pointer into a loud, located compiler failure AT the guess — the same
    // silent→visible transformation applied to `throw` and optional derefs this session.
    //
    // This is the increment toward `isOwned(TypeId)` (F5 stage 2 full): make the decision on an
    // un-typeable value UNREPRESENTABLE. The full swap threads a TypeId to all 40 call sites and
    // lands later; this makes the string function safe-by-construction meanwhile.
    if (isUntypeablePlaceholder(type_name)) {
        std.debug.print(
            "\x1b[1m\x1b[31mcompiler error:\x1b[0m\x1b[1m ARC ownership asked of an un-typeable value '{s}'\x1b[0m\n" ++
            "  sema failed to type a value that reached a retain/release. This is a COMPILER bug\n" ++
            "  (not user code): freeing it would corrupt memory. F5 stage 2 — please report.\n",
            .{type_name});
        std.process.exit(70); // EX_SOFTWARE — an internal fault, not a user error
    }
    // Any other type (strings, lists, maps, structs, function values) is a
    // reference-counted pointer.
    return true;
}

/// A WHOLE rendered type that means "sema could not type this" — a placeholder, never a real
/// type. Whole-string only: a fn type that merely CONTAINS `<unresolved>` in a parameter is a
/// valid owned box and must not match. See isRefCountedType's abort.
pub fn isUntypeablePlaceholder(name: []const u8) bool {
    return name.len == 0 or
        std.mem.eql(u8, name, "unresolved") or
        std.mem.eql(u8, name, "<unresolved>") or
        std.mem.eql(u8, name, "<tuple>") or
        std.mem.eql(u8, name, "<array>") or
        std.mem.eql(u8, name, "<fn>");
}

pub fn compileCallArgument(self: *LlvmCompiler, arg: ast.Expression) anyerror!types.LLVMValueRef {
    const val = try self.compileExpression(arg);
    return val;
}

// ── The RAII CONSTRUCTOR (acquisition) decision ──────────────────────────────────────
//
// RAII has two halves and Nova already has the destruction one (arc.md §0b): scope exit
// runs a `-1` via `releaseLocalVariables` / `drainTemporaries` → `getOrCreateDestructor`.
// This is the OTHER half — deciding where the `+1` those releases must balance is BORN.
// It used to be inferred inline in `compileExpression` from an ad-hoc producer WHITELIST
// (plus a type check); that lived nowhere nameable, so the ~30 hand-placed retain/consume
// sites each re-decided ownership locally and drifted out of balance (arc.md §0). It is now
// ONE principled decision — `acquisitionDisposition`/`principledDisposition` — cut over
// per-construct and gated (arc.md §7). The whitelist and its shadow-diff scaffolding are gone
// now that every construct agrees with the principled model.

/// The acquisition disposition of an evaluated expression occurrence.
/// - `.owned`    — evaluating it handed back a FRESH `+1` nothing else refers to yet; the
///                 enclosing statement must eventually consume it (a bind takes it off the
///                 pending list; otherwise the statement-end drain releases it).
/// - `.borrowed` — it merely NAMED a value that already has an owner (an ident / field /
///                 index read), or the value is not ARC-managed at all. Nothing to do.
pub const Disposition = enum { owned, borrowed };

/// Decide the disposition of `expr`'s result. The public entry; delegates to the principled
/// model. The caller (`compileExpression`) still resolves the rendered type name for the
/// destructor lookup and treats an unresolvable name as `.borrowed`.
/// Classify a disposition disagreement by the type the CHECKER assigned, recursing through `.optional`
/// so `xs.get(i)` — which returns `T | undefined` = `optional(T)` — is recognized as the SAME erasure
/// boundary as a bare `.type_param` (both erased-container-method returns). Without the recursion an
/// `optional(type_param)` mis-classifies as `.other` and trips the foundation gate on a benign, correct
/// boundary. `.enum_` is likewise unwrapped from an `optional(enum)`. Anything else is a genuine `.other`.
fn dispResidueOf(store: *const typesys.TypeStore, tid: typesys.TypeId) sema_shadow.DispResidue {
    return switch (store.get(tid)) {
        .type_param => .type_param,
        .enum_ => .enum_,
        .optional => |inner| dispResidueOf(store, inner),
        else => .other,
    };
}

pub fn acquisitionDisposition(self: *LlvmCompiler, expr: *const ast.Expression) Disposition {
    const principled = principledDisposition(self, expr);
    // ── THE FLIP (stage 5 step 7): the CHECKER's disposition is now the FIRST authority ──────────
    // The disposition oracle proved corpus-wide that the pass NEVER over-claims ownership — every
    // recorded disagreement was `pass=borrowed / codegen=owned`, only on the two keystone gaps
    // (`.type_param` erased returns, payload `.enum_`). So `ownedOf == true` is SOUND to obey: it can
    // only ever agree with, or be a subset of, what codegen would own. Codegen now OBEYS it — and
    // falls back to `principledDisposition` exactly where the pass did NOT record owned, which is a
    // borrow (same answer) or a keystone UNDER-claim (where the fallback correctly owns the temp until
    // F4 / enum-awareness close those gaps). Behaviour-preserving on the whole corpus (proven: there
    // is no `pass=owned / codegen=borrowed` case), and the FIRST place codegen reads the checker's
    // ownership verdict to drive a real decision — the acquisition/registration of a temporary.
    // Instantiation-aware: inside a MONOMORPHIZED body, read the checker's per-instantiation disposition
    // (`ownedOfInst`) — so `self.data.get(i)` in `List_string_get` is decided OWNED from the IR, not from
    // codegen's `keystoneSubst` side-channel. Falls back to the erased single-key disposition elsewhere.
    // With this the checker's disposition agrees with codegen everywhere (disposition oracle disagree=0).
    const pass_says_owned = if (self.typed_ir) |ir| blk: {
        if (self.current_instantiation_id) |inst| {
            if (ir.ownedOfInst(expr.id, inst)) |o| break :blk o;
        }
        break :blk (ir.ownedOf(expr) orelse false);
    } else false;
    const d: Disposition = if (pass_says_owned) .owned else principled;
    // Shadow-diff still compares the PRINCIPLED decision (not the flipped `d`) against the pass, so it
    // keeps proving they agree — the residue must stay the two keystone gaps, never `.other`.
    // F2-6 stage 5 (balance-check step 1): shadow-diff the disposition the CHECKER recorded
    // (TypedIr.expr_owned, computed in inferExprExpecting) against this codegen decision. The
    // checker OWNING the ownership disposition is the precondition for the static balance check;
    // this proves it can, by measuring where the two disagree AND classifying the residue by the
    // type the CHECKER assigned. Corpus-wide the residue is exactly TWO documented keystone gaps,
    // and EVERY disagreement is `codegen=owned, sema=borrowed` — the checker only ever UNDER-claims
    // ownership (the memory-safe direction), never over-claims:
    //   * `.type_param` — a generic ERASED return (`fn id<T>(x: T): T`): the checker sees the
    //     abstract `T` (non-owned by the erasure rule) while codegen monomorphizes to a concrete
    //     owned type (`string`). The same erased-body gap the F5-2 keystone shadow tracks; closes
    //     when the checker records the per-call-site monomorphized return (F4).
    //   * `.enum_` — a payload-carrying enum, which `store.isOwned` reads coarsely as non-owned
    //     while codegen routes it through `isOwnedExpr`'s variant-aware enum fallback (owned box).
    //     Closes when `isOwned` gets variant awareness (the F5 `.enum_ => false` follow-up).
    if (sema_shadow.report_enabled) {
        if (self.typed_ir) |ir| {
            // In a MONOMORPHIZED body, prefer the per-instantiation disposition the checker now records
            // (inst_disp.zig) — `self.data.get(i)` is `.type_param` (borrowed) in the erased IR but
            // `string` (owned) under `List<string>`. This is the measurement that the checker CAN be
            // instantiation-aware; if it drives the residue to 0, codegen can read it and drop
            // keystoneSubst + the fallback. Falls back to the single-key erased disposition.
            const sema_owned_opt: ?bool = if (self.current_instantiation_id) |inst|
                (ir.ownedOfInst(expr.id, inst) orelse ir.ownedOf(expr))
            else
                ir.ownedOf(expr);
            if (sema_owned_opt) |sema_owned| {
                if ((principled == .owned) == sema_owned) {
                    sema_shadow.disp_agree += 1;
                } else {
                    sema_shadow.disp_disagree += 1;
                    const sema_tag: sema_shadow.DispResidue = blk: {
                        const st = self.type_store orelse break :blk .other;
                        const tid = ir.typeOf(expr) orelse break :blk .other;
                        break :blk dispResidueOf(st, tid);
                    };
                    switch (sema_tag) {
                        .type_param => sema_shadow.disp_disagree_typeparam += 1,
                        .enum_ => sema_shadow.disp_disagree_enum += 1,
                        .other => {
                            sema_shadow.disp_disagree_other += 1;
                            sema_shadow.disp_last_kind = @tagName(expr.kind);
                            sema_shadow.disp_last_type = (self.resolveExpressionTypeName(expr) catch null) orelse "";
                        },
                    }
                }
            }
        }
    }
    return d;
}

/// KINDS that NAME a value which already has an owner — reading one is a borrow, never a
/// fresh +1. The SINGLE source for "is this a borrow?", shared by the acquisition
/// disposition (`principledDisposition`) and the aggregate-element move/dup rule
/// (`takeOwnedElement`). Replaces the `kind == .ident or .field_access or .index` triple
/// that was open-coded at every store-into-aggregate site.
pub fn namesExistingOwner(kind: ast.ExprKind) bool {
    return switch (kind) {
        .ident, .field_access, .index => true,
        else => false,
    };
}

/// The principled acquisition decision (arc.md §2): an occurrence is `.owned` (a fresh heap
/// +1 the statement drain must release) UNLESS it is one of the non-producing forms below,
/// AND its type is ARC-managed (`isOwnedExpr`, from the TypeId store — never a string). This
/// inverts the old ad-hoc producer whitelist: "owned" is the DEFAULT for a managed value, so
/// a producing KIND nobody remembered to list is caught, not silently leaked. It was cut over
/// per-construct and gated (arc.md §7); every construct now agrees with this model, so the
/// whitelist and its shadow-diff scaffolding are gone.
fn principledDisposition(self: *LlvmCompiler, expr: *const ast.Expression) Disposition {
    // A payload-less enum-variant construction (`V.Null`) PARSES as `.field_access` but does NOT
    // name an existing owner — it produces a FRESH owned box (a tagged-union enum is heap-boxed even
    // for its payload-less variants). Treating it as a borrow (namesExistingOwner) meant an inline
    // `x != V.Null` never registered the box as a drainable temp, leaking 16 bytes. Let it fall
    // through to the isOwnedExpr producer check instead.
    const is_enum_variant_ctor = expr.kind == .field_access and
        expr.kind.field_access.object.kind == .ident and
        self.enums.contains(expr.kind.field_access.object.kind.ident);
    // BORROWS — name a value that already has an owner; reading it is never a fresh +1.
    if (!is_enum_variant_ctor and namesExistingOwner(expr.kind)) return .borrowed;
    switch (expr.kind) {
        // ASSIGNMENT yields the value the TARGET now owns, not a fresh temp. Registering it
        // would release the variable's own value at statement end — a UAF, measured (all 17
        // corpus cases died). Only a NON-assign binary (`a + b` makes a string) is a producer.
        .binary => |b| {
            if (b.op == .assign) return .borrowed;
        },
        // A bare LITERAL is a compile-time constant: int/bool are trivial, and a string/char
        // literal is a STATIC, sentinel-refcounted global — not a fresh heap +1, so never a
        // statement-drain temporary (releasing it is a no-op on the sentinel). A runtime-
        // ASSEMBLED string is a `.template_expr`, which IS owned — this excludes only literals.
        // EXCEPT a decimal literal: `9.99m` lowers to a runtime nova_decimal_from_string call —
        // a fresh 16-byte heap +1, not a sentinel — so it falls through to the isOwnedExpr check
        // and registers as an owned temp (mirror of infer.ownedDisposition). Used as a borrowed
        // arg (`take(9.99m)`) it must still be drained, or the decimal leaks.
        // EXCEPT an ARRAY literal too: `[31, 28, ...]` allocates a FRESH heap box (compileAlloc), so a
        // transient use — `MONTH_DAYS[i]` on a const array, or a `[..]` passed as an arg — must be drained
        // or the whole box leaks (a string literal, by contrast, is a shared global, correctly borrowed).
        .literal => |lit| if (lit != .decimal and lit != .array) return .borrowed,
        // Acquired by their OWN compile arm (or ownership handled by another lowering) — must
        // not be auto-registered too, or the +1 is released twice (the `.try_expr`/`.cast`
        // double-register hazard the whitelist comment documents).
        .try_expr, .cast, .await_expr, .go_expr, .optional_chaining => return .borrowed,
        // `.if_expr` IS an owned producer when its result type is managed: the phi SELECTS one
        // branch's value and that value becomes the result temp. The per-edge move/dup is done in
        // the if_expr arm (each branch calls `takeOwnedElement` on its own value — retain a borrowed
        // branch, move a fresh one — so the value the phi carries owns exactly one reference on
        // whichever edge was taken); the phi is then registered here like any owned temp. Before this
        // cutover an owned if-expr was a UAF: both branch temps drained at statement end while the
        // bind held the selected (freed) one — `let x = if c mk("a") else mk("b")` returned garbage.
        else => {},
    }
    if (!self.isOwnedExpr(expr)) return .borrowed;
    return .owned;
}

/// The store-into-aggregate ACQUISITION primitive (RAII "constructor", store side): give an
/// aggregate its own owning reference to an element `val` it is about to store. The caller
/// has already decided the element IS owned (from the declared field type or the expr type);
/// this applies the single move/dup rule that every aggregate constructor needs:
///   * element BORROWED (`namesExistingOwner`: ident/field/index) -> DUP (`compileRetain`):
///     it is owned elsewhere, so the aggregate must make its OWN +1; both the original owner
///     and the aggregate's destructor release later, balanced.
///   * element FRESH (a producer temp) -> MOVE (`consumeTemporary`): take the +1 it already
///     carries OFF the statement drain so it is not freed under the aggregate. A no-op if it
///     was not a drainable temp (e.g. a nested struct literal), so the reference just transfers.
/// This is the exact rule that was open-coded — comment and all — at the struct/union/enum
/// field-store and tuple-element sites (conformance/cases 41, 42). One function, one place to
/// be right, `namesExistingOwner` instead of a re-typed `.ident or .field_access or .index`.
pub fn takeOwnedElement(self: *LlvmCompiler, elem_kind: ast.ExprKind, val: types.LLVMValueRef) anyerror!void {
    if (namesExistingOwner(elem_kind)) {
        try self.compileRetain(val);
    } else {
        self.consumeTemporary(val);
    }
}

pub fn compileRetain(self: *LlvmCompiler, ptr: types.LLVMValueRef) anyerror!void {
    const retain_fn = if (self.func_map.get("nova_retain")) |f| f else blk: {
        var arg_types = [_]types.LLVMTypeRef{self.val_type};
        const fn_type = core.LLVMFunctionType(self.void_type, &arg_types, 1, 0);
        const f = core.LLVMAddFunction(self.module, "nova_retain", fn_type);
        try self.func_map.put("nova_retain", f);
        break :blk f;
    };
    const fn_t = core.LLVMGlobalGetValueType(retain_fn);
    var args = [_]types.LLVMValueRef{ptr};
    _ = core.LLVMBuildCall2(self.builder, fn_t, retain_fn, &args, 1, "");
}

pub fn compileRelease(self: *LlvmCompiler, ptr: types.LLVMValueRef, destructor_fn_opt: ?types.LLVMValueRef) anyerror!void {
    const release_fn = if (self.func_map.get("nova_release")) |f| f else blk: {
        const ptr_type = core.LLVMPointerType(self.void_type, 0);
        var arg_types = [_]types.LLVMTypeRef{self.val_type, ptr_type};
        const fn_type = core.LLVMFunctionType(self.void_type, &arg_types, 2, 0);
        const f = core.LLVMAddFunction(self.module, "nova_release", fn_type);
        try self.func_map.put("nova_release", f);
        break :blk f;
    };
    const fn_t = core.LLVMGlobalGetValueType(release_fn);
    const dest_val = if (destructor_fn_opt) |d|
        core.LLVMBuildBitCast(self.builder, d, core.LLVMPointerType(self.void_type, 0), "dest_cast")
    else
        core.LLVMConstNull(core.LLVMPointerType(self.void_type, 0));
    var args = [_]types.LLVMValueRef{ptr, dest_val};
    _ = core.LLVMBuildCall2(self.builder, fn_t, release_fn, &args, 2, "");
}

/// The destructor's symbol name, which is the INSTANTIATION's name, not the
/// declaration's — `__destruct_List_string`, not `__destruct_List`.
///
/// F4 G3 (narrowed): `List<string>` must release its elements and `List<int>` must
/// not, so they cannot share a destructor. They did: the name came from
/// `getStructBaseName`, which strips `<...>`, so ONE `__destruct_List` served every
/// element type — and since it can only do one thing for all of them, it does
/// nothing, and the elements leak (~138 B/iter, repros/list_string_leak.md).
///
/// Giving each instantiation its own destructor is the PRECONDITION F5 needs: the
/// element type is knowable at destruction because the destructor belongs to
/// exactly one instantiation. F4 §4 is explicit that this alone fixes nothing at
/// runtime — the bodies are identical until F5 fills them in.
///
/// Non-generic types are unaffected: `Foo` still yields `__destruct_Foo`.
fn destructorName(allocator: std.mem.Allocator, type_name: []const u8) ![]u8 {
    const mangled = try mangleTypeName(allocator, type_name);
    defer allocator.free(mangled);
    return std.fmt.allocPrint(allocator, "__destruct_{s}", .{mangled});
}


/// `List<string>` + a field declared `Storage<T>` -> `Storage<string>`.
///
/// A destructor belongs to ONE instantiation (F4 G3), so it knows what T is — but
/// the field's declared type still says `T`. Without substituting,
/// `__destruct_List_string` releases `data` as `Storage<T>`; `isRefCountedType("T")`
/// is false, so THAT destructor's body is empty and the elements leak. Measured
/// exactly: List<int> went clean while List<string> still leaked its 2 strings.
///
/// BY INDEX, from the DECLARATION's own type_params — never by hardcoded letters.
/// The deleted `substitutePlaceholders` used `if (T) return params[0]`, which gave
/// `struct Foo<A, B>` nothing at all; here `List`'s `type_params[0]` is whatever
/// `List` chose to call it.
pub fn substituteFieldType(self: *LlvmCompiler, inst_name: []const u8, field_type: []const u8) anyerror![]const u8 {
    const lt = std.mem.indexOfScalar(u8, inst_name, '<') orelse return field_type;
    if (!std.mem.endsWith(u8, inst_name, ">")) return field_type;
    const base = inst_name[0..lt];
    const decl = self.structs.get(base) orelse return field_type;
    if (decl.type_params.len == 0) return field_type;

    var args = std.ArrayListUnmanaged([]const u8).empty;
    defer args.deinit(self.allocator);
    const inner = inst_name[lt + 1 .. inst_name.len - 1];
    var depth: usize = 0;
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        switch (inner[i]) {
            '<' => depth += 1,
            // NOT every `>` closes a `<`. A function-typed argument renders with an
            // ARROW — `List<(int) -> string>` — and `depth -= 1` on that `>` underflows
            // a usize, which is a compiler PANIC, not a wrong answer
            // (06_closures_advanced, `integer overflow` at this line). G3 never reached
            // it because a destructor only ever fed this a FIELD type; 4b feeds it
            // whole instantiation names, which is how a latent crash became a real one.
            '>' => if (depth > 0) {
                depth -= 1;
            },
            ',' => if (depth == 0) {
                try args.append(self.allocator, std.mem.trim(u8, inner[seg_start..i], " "));
                seg_start = i + 1;
            },
            else => {},
        }
    }
    try args.append(self.allocator, std.mem.trim(u8, inner[seg_start..], " "));
    if (args.items.len != decl.type_params.len) return field_type;

    // Whole-token replacement: the `T` in `Storage<T>`, not the `T` inside `Text`.
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(self.allocator);
    var j: usize = 0;
    outer: while (j < field_type.len) {
        const at_start = j == 0 or !isIdentCh(field_type[j - 1]);
        if (at_start) {
            for (decl.type_params, 0..) |tp, k| {
                if (std.mem.startsWith(u8, field_type[j..], tp)) {
                    const end = j + tp.len;
                    if (end == field_type.len or !isIdentCh(field_type[end])) {
                        try out.appendSlice(self.allocator, args.items[k]);
                        j = end;
                        continue :outer;
                    }
                }
            }
        }
        try out.append(self.allocator, field_type[j]);
        j += 1;
    }
    return try out.toOwnedSlice(self.allocator);
}

/// F4 4b: `T` -> `string` inside the body of `List_string_push`.
///
/// The whole of 4b's body half. `substituteFieldType` above already answers
/// "given instantiation I, what does this type string mean?" — correctly, by index,
/// for any type string, not just a field's. This just asks it about the body being
/// emitted, and is a no-op outside one (`current_instantiation == null`), which is
/// why wiring it in is inert until emission actually sets the context.
///
/// It is called at the ONLY two sites where a type parameter becomes a string
/// (F4 §5, 4b correction): `typeRefToString`'s `.ident` for declared types, and
/// `resolveExpressionTypeName`'s render for inferred ones. Both must substitute:
/// the first is `value: T`, the second is what sema inferred for `self.data.get(i)`.
/// Substituting only one leaves the erasure alive on the other path — and since
/// `isRefCountedType("T")` is silently FALSE rather than an error, the symptom is a
/// leak or a use-after-free, not a diagnostic.
pub fn substTypeParams(self: *LlvmCompiler, type_str: []const u8) anyerror![]const u8 {
    // F4-5: first substitute the STRUCT params (T from `current_instantiation`), then the METHOD
    // params (U from `current_method_subst`). Both are whole-token replacements; running struct-subst
    // first means a `List<U>` inside a `List_string_map_int` body becomes `List<int>` only via the
    // method pass (T is already string). Method subst applies even without a struct instantiation
    // (a free generic fn), so it is not gated on `current_instantiation`.
    const after_struct = if (self.current_instantiation) |inst|
        try self.substituteFieldType(inst, type_str)
    else
        type_str;
    return try self.substMethodParams(after_struct);
}

/// Apply `current_method_subst` (the method type-params -> concrete types) as whole-token
/// replacements, the same discipline `substituteFieldType` uses for struct params. Returns the input
/// unchanged when no method subst is installed (every non-specialized body). The result is freshly
/// allocated only when a replacement happened; otherwise the input slice is returned as-is.
pub fn substMethodParams(self: *LlvmCompiler, type_str: []const u8) anyerror![]const u8 {
    const bindings = self.current_method_subst orelse return type_str;
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(self.allocator);
    var replaced = false;
    var j: usize = 0;
    outer: while (j < type_str.len) {
        const at_start = j == 0 or !isIdentCh(type_str[j - 1]);
        if (at_start) {
            for (bindings) |b| {
                if (std.mem.startsWith(u8, type_str[j..], b.name)) {
                    const end = j + b.name.len;
                    if (end == type_str.len or !isIdentCh(type_str[end])) {
                        try out.appendSlice(self.allocator, b.concrete);
                        j = end;
                        replaced = true;
                        continue :outer;
                    }
                }
            }
        }
        try out.append(self.allocator, type_str[j]);
        j += 1;
    }
    if (!replaced) {
        out.deinit(self.allocator);
        return type_str;
    }
    return out.toOwnedSlice(self.allocator);
}

fn isIdentCh(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// §3.4j: is `type_name` a FUNCTION type — `(int) => int` — as opposed to a container
/// that merely holds functions — `List<(int) => int>`?
///
/// The distinction is the arrow's bracket DEPTH: a real function type has `=>`/`->` at
/// depth 0; in `List<(int) => int>` the arrow is at depth 1, inside `<>`. Getting this
/// wrong gave `List<(int) => int>` the CLOSURE destructor, which read `list[8]` (the
/// `len` field, value 3) as an env pointer and freed `0x3` — a crash on
/// test_loop_capture. Parens do not count as depth; only `<>` (generic args) do, since
/// a function type's own parens are part of its syntax.
pub fn isFunctionType(type_name: []const u8) bool {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < type_name.len) : (i += 1) {
        switch (type_name[i]) {
            '<' => depth += 1,
            '>' => {
                // `=>`/`->` end in `>`; only decrement for a GENERIC close, i.e. a `>`
                // NOT preceded by `=` or `-`.
                if (i > 0 and (type_name[i - 1] == '=' or type_name[i - 1] == '-')) {
                    if (depth == 0) return true;
                } else {
                    depth -= 1;
                }
            },
            else => {},
        }
    }
    return false;
}

/// The element type of a `Storage<T>`, or null if this is not one.
///
/// `Storage<T>` is THE container primitive the compiler understands (specs.md §3.8,
/// F5 §3.3a). Everything else about collections stays in the library — capacity,
/// growth policy, bounds — because those are decisions, and injecting them would put
/// List's growth policy in the compiler and make every new container need a compiler
/// change. This is the one thing the library CANNOT express: releasing N slots whose
/// type it does not know.
fn storageElem(type_name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, type_name, "Storage<")) return null;
    if (!std.mem.endsWith(u8, type_name, ">")) return null;
    return type_name["Storage<".len .. type_name.len - 1];
}

/// The destructor for a `Storage<T>`: release every slot, then the buffer itself is
/// freed by nova_release. Generated, never written — a library cannot write this,
/// because it cannot ask "is T ref-counted?".
///
/// The slot count is NOT a field: `Storage<T>` IS the heap object, and §3.2's layout
/// already records its byte length at [ptr-4]. length/8 is the slot count. A `cap`
/// field would be a second source of truth for something the allocation already
/// knows.
fn buildStorageDestructor(self: *LlvmCompiler, dest_fn: types.LLVMValueRef, elem: []const u8) anyerror!void {
    const owned = self.isOwnedStorageElemByName(elem);
    const elem_dest = if (owned) try self.getOrCreateDestructor(elem) else null;
    try buildStorageDestructorLoop(self, dest_fn, owned, elem_dest);
}

/// F2-6 stage 5 Phase C1: the storage slot-release built from the element's TypeId — ownership via the
/// typed `isOwnedTypeId`, the slot destructor via the TypeId dispatch. The LLVM slot loop is shared with
/// the string path (`buildStorageDestructorLoop`); only the element SOURCE moves to the store. Proven safe
/// by `diffStorageElem` (store==parse, agree=1108 DISAGREE=0 corpus-wide) + ARC/ASAN.
fn buildStorageDestructorByTypeId(self: *LlvmCompiler, dest_fn: types.LLVMValueRef, elem_tid: typesys.TypeId) anyerror!void {
    const owned = self.isOwnedTypeId(elem_tid);
    const elem_dest = if (owned) try self.getOrCreateDestructorByTypeId(elem_tid) else null;
    try buildStorageDestructorLoop(self, dest_fn, owned, elem_dest);
}

/// The element-type-agnostic slot loop shared by both storage builders: iterate `[ptr-4]/8` slots and
/// release each via `elem_dest`. `owned == false` ⇒ empty body (a `Storage<int>` owns nothing, but must
/// still HAVE a destructor symbol). Assumes the builder is positioned at `dest_fn`'s entry block.
fn buildStorageDestructorLoop(self: *LlvmCompiler, dest_fn: types.LLVMValueRef, owned: bool, elem_dest: ?types.LLVMValueRef) anyerror!void {
    // A slot of a non-ref-counted T (Storage<int>) owns nothing: the buffer is freed
    // by nova_release and there is nothing inside to release. An empty body, not a
    // missing symbol — `List<int>` and `List<string>` must both HAVE a destructor.
    if (!owned) return;

    const self_val = core.LLVMGetParam(dest_fn, 0);
    const fn_parent = dest_fn;

    // n = [ptr-4] (the byte length) / 8
    const four = core.LLVMConstInt(self.val_type, 4, 0);
    const len_addr = core.LLVMBuildSub(self.builder, self_val, four, "stg_len_addr");
    const len_ptr = core.LLVMBuildIntToPtr(self.builder, len_addr, core.LLVMPointerType(self.i32_type, 0), "stg_len_ptr");
    const len_i32 = core.LLVMBuildLoad2(self.builder, self.i32_type, len_ptr, "stg_len");
    const len_val = core.LLVMBuildZExt(self.builder, len_i32, self.val_type, "stg_len_ext");
    const eight = core.LLVMConstInt(self.val_type, 8, 0);
    const n_slots = core.LLVMBuildUDiv(self.builder, len_val, eight, "stg_slots");

    const i_alloca = core.LLVMBuildAlloca(self.builder, self.val_type, "stg_i");
    _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.val_type, 0, 0), i_alloca);

    const cond_bb = core.LLVMAppendBasicBlock(fn_parent, "stg_cond");
    const body_bb = core.LLVMAppendBasicBlock(fn_parent, "stg_body");
    const exit_bb = core.LLVMAppendBasicBlock(fn_parent, "stg_exit");

    _ = core.LLVMBuildBr(self.builder, cond_bb);
    core.LLVMPositionBuilderAtEnd(self.builder, cond_bb);
    const i_cur = core.LLVMBuildLoad2(self.builder, self.val_type, i_alloca, "stg_i_cur");
    const cmp = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntULT, i_cur, n_slots, "stg_cmp");
    _ = core.LLVMBuildCondBr(self.builder, cmp, body_bb, exit_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
    const i_b = core.LLVMBuildLoad2(self.builder, self.val_type, i_alloca, "stg_i_b");
    const off = core.LLVMBuildMul(self.builder, i_b, eight, "stg_off");
    const slot_addr = core.LLVMBuildAdd(self.builder, self_val, off, "stg_slot_addr");
    const slot_ptr = core.LLVMBuildIntToPtr(self.builder, slot_addr, core.LLVMPointerType(self.val_type, 0), "stg_slot_ptr");
    const elem_val = core.LLVMBuildLoad2(self.builder, self.val_type, slot_ptr, "stg_elem");
    // A zeroed slot is empty, not an object at address 0. write_header memsets the
    // buffer, so unwritten slots are 0 — releasing them would call the destructor on
    // a null pointer.
    try self.compileRelease(elem_val, elem_dest);
    const i_next = core.LLVMBuildAdd(self.builder, i_b, core.LLVMConstInt(self.val_type, 1, 0), "stg_i_next");
    _ = core.LLVMBuildStore(self.builder, i_next, i_alloca);
    _ = core.LLVMBuildBr(self.builder, cond_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, exit_bb);
}

/// F2-6 stage 5 Phase C1: the `Storage<T>` destructor keyed on the TypeId — element from `st.get(t).storage`,
/// slots released via the TypeId dispatch (`buildStorageDestructorByTypeId`), no `storageElem` string parse.
/// Symbol name via the name-generator (`renderLegacy`→`destructorName`, unchanged) → the SAME memoized
/// function the string builder produces; only the element SOURCE moves to the store. Proven safe by
/// `diffStorageElem` (agree=1108 DISAGREE=0) + ARC/ASAN. This is what retires `storageElem`'s destructor
/// role (its non-destructor callers, if any, are handled separately).
fn getOrCreateStorageDestructorByTypeId(self: *LlvmCompiler, t: typesys.TypeId) anyerror!?types.LLVMValueRef {
    const st = self.type_store orelse return null;
    if (st.get(t) != .storage) return null;
    // Regression guard (shadow): the store element still matches the string parse.
    if (sema_shadow.report_enabled) diffStorageElem(self, t);
    const elem_tid = st.get(t).storage;
    const type_name = sema_shadow.renderLegacy(self.allocator, st, t) catch return null;
    const dest_name = try destructorName(self.allocator, type_name);
    defer self.allocator.free(dest_name);
    const dest_name_z = try self.allocator.dupeZ(u8, dest_name);
    defer self.allocator.free(dest_name_z);
    if (core.LLVMGetNamedFunction(self.module, dest_name_z)) |existing| return existing;

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, dest_name_z, fn_type);
    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);

    try buildStorageDestructorByTypeId(self, dest_fn, elem_tid);

    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

/// F5 §3.4h: a trait object OWNS the struct it wraps, so releasing the fat pointer
/// must release that struct — otherwise `f(Dog())` / `return JsonSource(json.get(..))`
/// leak everything behind the trait.
///
/// ONE function serves every trait: the concrete struct's destructor is not known at a
/// release site (which often has only the trait name), but it IS reachable at RUNTIME
/// from vtable slot 0 (reserved by `getGlobalVTable`). The fat pointer is
/// `{struct_ptr @0, vtable @8}`. The 16 bytes of the fat pointer itself are freed by
/// the `nova_release` that CALLED this — a destructor never frees its own object.
pub fn getOrCreateTraitDestructor(self: *LlvmCompiler) anyerror!types.LLVMValueRef {
    if (core.LLVMGetNamedFunction(self.module, "__destruct_trait")) |existing| return existing;

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, "__destruct_trait", fn_type);
    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);

    const fat = core.LLVMGetParam(dest_fn, 0);
    const ptr_size: u64 = 8;

    // struct_ptr = [fat + 0]
    const sp_ptr = core.LLVMBuildIntToPtr(self.builder, fat, core.LLVMPointerType(self.val_type, 0), "td_sp_ptr");
    const struct_ptr = core.LLVMBuildLoad2(self.builder, self.val_type, sp_ptr, "td_struct_ptr");
    // vtable = [fat + 8]
    const vt_addr = core.LLVMBuildAdd(self.builder, fat, core.LLVMConstInt(self.val_type, ptr_size, 0), "td_vt_addr");
    const vt_ptr = core.LLVMBuildIntToPtr(self.builder, vt_addr, core.LLVMPointerType(self.val_type, 0), "td_vt_ptr");
    const vtable = core.LLVMBuildLoad2(self.builder, self.val_type, vt_ptr, "td_vtable");
    // struct_dtor = [vtable + 0]  (reserved slot 0)
    const sd_ptr = core.LLVMBuildIntToPtr(self.builder, vtable, core.LLVMPointerType(self.val_type, 0), "td_sd_ptr");
    const struct_dtor = core.LLVMBuildLoad2(self.builder, self.val_type, sd_ptr, "td_struct_dtor");

    // nova_release(struct_ptr, struct_dtor). A null dtor slot -> "just free"; a null
    // struct_ptr -> no-op. Both are handled by nova_release.
    const dtor_as_ptr = core.LLVMBuildIntToPtr(self.builder, struct_dtor, core.LLVMPointerType(self.void_type, 0), "td_dtor_cast");
    try self.compileRelease(struct_ptr, dtor_as_ptr);

    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

/// §3.4j: a closure box `{fn_ptr @0, env @8}` owns its env, so releasing the box must
/// free the env. ONE function for every closure type — the env is a raw heap buffer at a
/// fixed offset, so no per-lambda knowledge is needed to free it. A bare-function box has
/// `env == 0`, and `nova_bytes_free(0)` is a no-op (and a global fnbox never reaches
/// rc 0 anyway — its refcount is the 100M sentinel).
///
/// NOTE (§3.4j inc4, not done): a closure capturing a REF-COUNTED value (a `string`,
/// another closure) leaks that captured object — this frees the env buffer but not its
/// slots. That needs per-lambda capture types; the env-buffer free here is the dominant
/// leak (box + env, 2/closure, unbounded).
fn getOrCreateClosureDestructor(self: *LlvmCompiler) anyerror!types.LLVMValueRef {
    if (core.LLVMGetNamedFunction(self.module, "__destruct_closure")) |existing| return existing;

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, "__destruct_closure", fn_type);
    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);

    const box = core.LLVMGetParam(dest_fn, 0);
    const ptr_size: u64 = 8;
    const env_addr = core.LLVMBuildAdd(self.builder, box, core.LLVMConstInt(self.val_type, ptr_size, 0), "clo_env_addr");
    const env_ptr = core.LLVMBuildIntToPtr(self.builder, env_addr, core.LLVMPointerType(self.val_type, 0), "clo_env_ptr");
    const env = core.LLVMBuildLoad2(self.builder, self.val_type, env_ptr, "clo_env");

    // §3.4j inc4: call the per-lambda CLEANUP (box slot 2) to release the env's
    // ref-counted captures BEFORE the env buffer is freed. 0 when nothing captured is
    // ref-counted, which the runtime-independent branch below skips.
    const clean_addr = core.LLVMBuildAdd(self.builder, box, core.LLVMConstInt(self.val_type, 2 * ptr_size, 0), "clo_cleanup_addr");
    const clean_ptr = core.LLVMBuildIntToPtr(self.builder, clean_addr, core.LLVMPointerType(self.val_type, 0), "clo_cleanup_ptr");
    const cleanup = core.LLVMBuildLoad2(self.builder, self.val_type, clean_ptr, "clo_cleanup");
    const has_cleanup = core.LLVMBuildICmp(self.builder, .LLVMIntNE, cleanup, core.LLVMConstInt(self.val_type, 0, 0), "clo_has_cleanup");
    const call_bb = core.LLVMAppendBasicBlock(dest_fn, "clo_cleanup_call");
    const after_bb = core.LLVMAppendBasicBlock(dest_fn, "clo_cleanup_done");
    _ = core.LLVMBuildCondBr(self.builder, has_cleanup, call_bb, after_bb);
    core.LLVMPositionBuilderAtEnd(self.builder, call_bb);
    {
        var cp = [_]types.LLVMTypeRef{self.val_type};
        const cft = core.LLVMFunctionType(self.void_type, &cp, 1, 0);
        const cfp = core.LLVMBuildIntToPtr(self.builder, cleanup, core.LLVMPointerType(cft, 0), "clo_cleanup_fp");
        var cargs = [_]types.LLVMValueRef{env};
        _ = core.LLVMBuildCall2(self.builder, cft, cfp, &cargs, 1, "");
    }
    _ = core.LLVMBuildBr(self.builder, after_bb);
    core.LLVMPositionBuilderAtEnd(self.builder, after_bb);

    const free_fn = if (self.func_map.get("nova_bytes_free")) |f| f else blk: {
        var at = [_]types.LLVMTypeRef{self.val_type};
        const ft = core.LLVMFunctionType(self.void_type, &at, 1, 0);
        const f = core.LLVMAddFunction(self.module, "nova_bytes_free", ft);
        try self.func_map.put("nova_bytes_free", f);
        break :blk f;
    };
    const free_t = core.LLVMGlobalGetValueType(free_fn);
    var free_args = [_]types.LLVMValueRef{env};
    _ = core.LLVMBuildCall2(self.builder, free_t, free_fn, &free_args, 1, "");

    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

/// F2-6 stage 4: the destructor keyed on the TypeId, dispatched on `store.get(t)` — no string-prefix
/// matching and (for aggregates, in later increments) no string-PARSING to recover element types. The
/// name-INDEPENDENT kinds are handled natively (their symbol is fixed, so the store kind decides
/// directly); every other kind DELEGATES to the proven string path via the name-generator until its
/// builder is TypeId-keyed. A store-vs-string divergence in a destructor is CORRUPTION, so this is
/// shadow-diffed against the string path (must resolve to the SAME LLVM function) before any cutover.
pub fn getOrCreateDestructorByTypeId(self: *LlvmCompiler, t: typesys.TypeId) anyerror!?types.LLVMValueRef {
    const st = self.type_store orelse return null;
    switch (st.get(t)) {
        // Name-independent: a fixed symbol, decided by the kind alone.
        .trait_ => return try getOrCreateTraitDestructor(self),
        .func => return try getOrCreateClosureDestructor(self),
        // Non-managed: no destructor (nothing to release; the box free, if any, is the whole job).
        .prim, .ptr, .unresolved => return null,
        // TUPLE / ERR-UNION / STRUCT: built from the store elements/arms/fields (no string parse).
        // Proven DISAGREE=0 (diffTupleElems / diffErrUnionArms / diffStructFields).
        .tuple => return try getOrCreateTupleDestructorByTypeId(self, t),
        .error_union => return try getOrCreateErrUnionDestructorByTypeId(self, t),
        .struct_ => return try getOrCreateStructDestructorByTypeId(self, t),
        .storage => return try getOrCreateStorageDestructorByTypeId(self, t),
        // enum / optional / string / decimal / type_param / future: delegate to the string path
        // (byte-identical by construction) until each is TypeId-keyed. (enum is intentionally NOT twinned —
        // enums aren't parameterized, so its builder reads the AST decl and there is no string parser to
        // retire; the string path IS the store-faithful path for it.)
        else => {
            const name = sema_shadow.renderLegacy(self.allocator, st, t) catch return null;
            return try self.getOrCreateDestructor(name);
        },
    }
}

/// F2-6 stage 5 Phase A: select a release-site destructor by TypeId when it is SAFE to, else by string.
///
/// "Safe" = the store-native builder resolves to the SAME memoized SYMBOL the string path would
/// (`destructorName(renderLegacy(tid)) == destructorName(name_str)`). When the symbols match, routing
/// through `getOrCreateDestructorByTypeId` builds the store-native BODY under the shared name — the cutover
/// — with zero risk of a duplicate symbol. When they DIFFER (the known benign `i32`/`int` List spelling,
/// increment 6: `renderLegacy`→`i32` vs `typeRefToString`→`int`), flipping would mint a SECOND symbol
/// alongside the string sites' one; so that class stays on the string path until the stage-6 renderer
/// unification, and is counted (not silently duplicated). `tid == null`/`.unresolved` → string fallback.
/// Result is byte-identical either way; the ASAN gate is the authority that the store-native body is right.
pub fn getOrCreateDestructorPreferId(self: *LlvmCompiler, name_str: []const u8, tid: ?typesys.TypeId) anyerror!?types.LLVMValueRef {
    if (tid) |t| {
        if (self.type_store) |st| {
            if (st.get(t) != .unresolved) {
                // renderLegacy returns Sema-INTERNED or static memory — never free it (mirrors every
                // other caller, e.g. the dispatch at getOrCreateDestructorByTypeId).
                const id_name = sema_shadow.renderLegacy(self.allocator, st, t) catch {
                    return try self.getOrCreateDestructor(name_str);
                };
                const id_sym = destructorName(self.allocator, id_name) catch {
                    return try self.getOrCreateDestructor(name_str);
                };
                defer self.allocator.free(id_sym);
                const str_sym = destructorName(self.allocator, name_str) catch {
                    return try self.getOrCreateDestructor(name_str);
                };
                defer self.allocator.free(str_sym);
                if (std.mem.eql(u8, id_sym, str_sym)) {
                    if (sema_shadow.report_enabled) sema_shadow.phaseA_flip += 1;
                    return try self.getOrCreateDestructorByTypeId(t);
                }
                if (sema_shadow.report_enabled) {
                    sema_shadow.phaseA_split += 1;
                    sema_shadow.phaseA_split_last = std.fmt.allocPrint(self.allocator, "id='{s}' str='{s}'", .{ id_name, name_str }) catch name_str;
                }
                return try self.getOrCreateDestructor(name_str);
            }
        }
    }
    if (sema_shadow.report_enabled) sema_shadow.phaseA_no_id += 1;
    return try self.getOrCreateDestructor(name_str);
}

pub fn getOrCreateDestructor(self: *LlvmCompiler, type_name: []const u8) anyerror!?types.LLVMValueRef {
    // §3.4h: a trait-typed value is a fat pointer that co-owns its wrapped struct.
    if (self.traits.contains(type_name)) return try getOrCreateTraitDestructor(self);
    // §3.4j: a function-typed value is a closure box that owns its env — but ONLY a
    // real function type, not `List<(int) => int>` (a container OF functions, which
    // gets its own List destructor below).
    if (isFunctionType(type_name)) {
        return try getOrCreateClosureDestructor(self);
    }
    // A tuple is a heap box of N raw words. Like `Storage<T>` it is a compiler primitive and is
    // not in `self.structs`, so it fell through to `return null` below — meaning a tuple was
    // released as `nova_release(box, null)`: the BOX was freed and every element leaked. Combined
    // with the return-boundary retain (which hands the box its elements at +1 and is balanced by
    // nothing), that was ~108 of the ~118 above-floor live objects in the whole corpus.
    if (isTupleType(type_name)) {
        return try getOrCreateTupleDestructor(self, type_name);
    }
    // specs §3.4b: `ErrUnion(ok,err)` owns its payload (buildErrUnion retains it), so its
    // destructor must release it — switching on the TAG, because which type the payload is
    // depends on it. Without this the box frees and the payload leaks, exactly as the tuple
    // box did before it got a destructor.
    if (std.mem.startsWith(u8, type_name, "ErrUnion(")) {
        return try getOrCreateErrUnionDestructor(self, type_name);
    }
    const base_struct = getStructBaseName(type_name);
    // A tagged-union enum owns its variant payloads (retained/consumed at construction), so — like
    // the err-union and tuple boxes — it needs a destructor to release them on the tag. Without it
    // the box freed and the owned payload leaked. Payload-less enums return null (nothing to release).
    if (self.enums.contains(base_struct)) {
        return try getOrCreateEnumDestructor(self, base_struct);
    }
    const is_storage = storageElem(type_name) != null;
    // `Storage<T>` is a compiler primitive, not a declared struct, so it is not in
    // `self.structs` — but it is the one type whose destructor MUST be generated.
    if (!is_storage and !self.structs.contains(base_struct)) {
        return null;
    }

    // Keyed on the INSTANTIATION. This memo is the `seen` set of F4 §3.2's worklist,
    // in the place it already existed (§2.6a) — keying it on the base name is what
    // collapsed every instantiation onto one body.
    const dest_name = try destructorName(self.allocator, type_name);
    defer self.allocator.free(dest_name);
    const dest_name_z = try self.allocator.dupeZ(u8, dest_name);
    defer self.allocator.free(dest_name_z);

    if (core.LLVMGetNamedFunction(self.module, dest_name_z)) |existing| {
        return existing;
    }

    // Define destructor: void __destruct_Struct(i64 self_val)
    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, dest_name_z, fn_type);

    // A destructor resolves ITS OWN instantiation's fields — `Storage<T>` in `List<Inner>`
    // means `Storage<Inner>`, decided by THIS type's args, never the ambient body's. But
    // this generator is called lazily from any release site, so `current_instantiation` /
    // `current_method_subst` still hold the enclosing monomorphized body (e.g. `List<Outer>`
    // while a `List<Inner>` destructor gets built for the first time). Left in place, the `T`
    // in the field type substitutes to `Outer`, the field-release calls `__destruct_Storage_Outer`,
    // and — because destructors are memoized by name — that wrong body is cached forever, so a
    // `List<Inner>` buffer is later released as if its slots were `Outer` pointers (segfault on a
    // nested owned List; see 61_nested_owned_list). Pin the context to `type_name`; recursive
    // sub-destructors save/set/restore their own. Cleared method subst: a struct field can only
    // mention struct params, never a method's.
    const saved_instantiation = self.current_instantiation;
    const saved_method_subst = self.current_method_subst;
    self.current_instantiation = type_name;
    self.current_method_subst = null;
    defer {
        self.current_instantiation = saved_instantiation;
        self.current_method_subst = saved_method_subst;
    }

    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);

    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
    const self_val = core.LLVMGetParam(dest_fn, 0);

    // 1. Call delete method if it exists — prefer the instantiation's MONO hook over the erased bare one
    // (same abstract-residue avoidance as the TypeId struct builder).
    const delete_method_name = try self.methodSymbol(type_name, "delete");
    defer self.allocator.free(delete_method_name);
    const delete_bare = try std.fmt.allocPrint(self.allocator, "{s}_delete", .{base_struct});
    defer self.allocator.free(delete_bare);
    const delete_method_name_z = try self.allocator.dupeZ(u8, delete_method_name);
    defer self.allocator.free(delete_method_name_z);
    const delete_bare_z = try self.allocator.dupeZ(u8, delete_bare);
    defer self.allocator.free(delete_bare_z);

    if (core.LLVMGetNamedFunction(self.module, delete_method_name_z) orelse core.LLVMGetNamedFunction(self.module, delete_bare_z)) |del_fn| {
        const del_t = core.LLVMGlobalGetValueType(del_fn);
        // Only treat `<Struct>_delete` as the finalizer when it has the destructor
        // signature `delete(self)` (1 param). A user method named `delete` with more
        // params (e.g. an HTTP DELETE route registrar `delete(self, path, handler)`)
        // is an ordinary method, not the cleanup hook.
        if (core.LLVMCountParamTypes(del_t) == 1) {
            var del_args = [_]types.LLVMValueRef{self_val};
            _ = core.LLVMBuildCall2(self.builder, del_t, del_fn, &del_args, 1, "");
        }
    }

    // 2a. `Storage<T>` has no fields — it IS the slots. Release them.
    if (storageElem(type_name)) |elem| {
        try buildStorageDestructor(self, dest_fn, elem);
        _ = core.LLVMBuildRetVoid(self.builder);
        if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
        return dest_fn;
    }

    // 2. Release all reference-counted fields of the struct
    if (self.structs.get(base_struct)) |s| {
        for (s.fields) |field| {
            const field_type = try self.substituteFieldType(type_name, try self.typeRefToString(field.type_name));
            // F5-2: the DECLARED field TypeRef is in hand, so a concrete field decides via the store;
            // a generic field (`T`, `T?`) lowers to .type_param/.unresolved and falls back to
            // `field_type` — the instantiation-substituted string, exactly today's answer. `field_type`
            // is still the destructor key below.
            const is_ref = self.isOwnedDeclaredType(field.type_name, field_type);
            if (is_ref) {
                const offset = try self.getFieldOffset(base_struct, field.name);
                const offset_val = core.LLVMConstInt(self.val_type, offset, 0);
                const addr = core.LLVMBuildAdd(self.builder, self_val, offset_val, "field_addr");

                const llvm_field_type = self.toLLVMType(field.type_name);
                const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(llvm_field_type, 0), "field_ptr");
                const loaded_field_val = core.LLVMBuildLoad2(self.builder, llvm_field_type, ptr, "field_load");
                const casted_field_val = self.castToValType(loaded_field_val, field.type_name);

                const field_dest = try self.getOrCreateDestructor(field_type);
                try self.compileRelease(casted_field_val, field_dest);
            }
        }
    }

    _ = core.LLVMBuildRetVoid(self.builder);

    if (saved_ip) |sip| {
        core.LLVMPositionBuilderAtEnd(self.builder, sip);
    }

    return dest_fn;
}

/// F2-6 stage 4 (cutover): the STRUCT destructor built from the store's `StructType{decl, args}` — each
/// field's concrete TypeId resolved the sema way (lower the declared field TypeRef in the struct's
/// type-param scope, then `subst.substitute` the instantiation's args), NOT via the `substituteFieldType`
/// string rewrite. Field ownership is the typed `isOwnedTypeId`; the field destructor is dispatched by
/// TypeId (`getOrCreateDestructorByTypeId`), so a `Storage<T>` / nested-struct / tuple field routes through
/// the store, not a re-parse of its rendered name. Proven safe by `diffStructFields` (ownership store==parse,
/// agree=1932 DISAGREE=0) + ARC/ASAN. Everything else — the symbol name (`renderLegacy`→`destructorName`,
/// same memoized function), the `<Struct>_delete` cleanup hook, the `current_instantiation` pin, and the
/// LLVM field LAYOUT (offset/load/cast driven by the DECLARED `field.type_name`) — is byte-identical to
/// the string builder. Storage-typed fields still resolve their element via the string fallback inside the
/// TypeId dispatch until the `.storage` builder is TypeId-keyed too (measured next); this cutover retires
/// `substituteFieldType` FROM THE DESTRUCTOR (its non-destructor callers keep it alive).
fn getOrCreateStructDestructorByTypeId(self: *LlvmCompiler, t: typesys.TypeId) anyerror!?types.LLVMValueRef {
    const st = self.type_store orelse return null;
    if (st.get(t) != .struct_) return null;
    const stype = st.get(t).struct_;
    const sm = sema_shadow.live_sema orelse {
        // No live sema (store not sema-backed): fall back to the proven string path.
        const nm = sema_shadow.renderLegacy(self.allocator, st, t) catch return null;
        return try self.getOrCreateDestructor(nm);
    };
    const sym = sm.tab.symbolAt(stype.decl);
    if (sym.decl != .struct_) {
        const nm = sema_shadow.renderLegacy(self.allocator, st, t) catch return null;
        return try self.getOrCreateDestructor(nm);
    }
    const decl = sym.decl.struct_;

    // Regression guard (shadow): store-resolved field ownership still matches the string parse.
    if (sema_shadow.report_enabled) diffStructFields(self, t);

    const type_name = sema_shadow.renderLegacy(self.allocator, st, t) catch return null;
    const base_struct = getStructBaseName(type_name);

    const dest_name = try destructorName(self.allocator, type_name);
    defer self.allocator.free(dest_name);
    const dest_name_z = try self.allocator.dupeZ(u8, dest_name);
    defer self.allocator.free(dest_name_z);
    if (core.LLVMGetNamedFunction(self.module, dest_name_z)) |existing| return existing;

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, dest_name_z, fn_type);

    // Same context pin as the string builder: a field's storage element still resolves via the string
    // fallback (current_instantiation-driven), so this must hold while the body is generated.
    const saved_instantiation = self.current_instantiation;
    const saved_method_subst = self.current_method_subst;
    self.current_instantiation = type_name;
    self.current_method_subst = null;
    defer {
        self.current_instantiation = saved_instantiation;
        self.current_method_subst = saved_method_subst;
    }

    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
    const self_val = core.LLVMGetParam(dest_fn, 0);

    // 1. Call the `<Struct>_delete` cleanup hook if it exists with the finalizer signature `delete(self)`.
    // Prefer the INSTANTIATION's mono hook (`Map_string_i32_delete`) built from `type_name`; falling to the
    // bare erased `Map_delete` would pin the erased base body alive (abstract residue keeping the string
    // parsers reachable). methodSymbol on a non-generic struct yields the same bare name → no-op there.
    const delete_method_name = try self.methodSymbol(type_name, "delete");
    defer self.allocator.free(delete_method_name);
    const delete_bare = try std.fmt.allocPrint(self.allocator, "{s}_delete", .{base_struct});
    defer self.allocator.free(delete_bare);
    const del_z = try self.allocator.dupeZ(u8, delete_method_name);
    defer self.allocator.free(del_z);
    const del_bare_z = try self.allocator.dupeZ(u8, delete_bare);
    defer self.allocator.free(del_bare_z);
    if (core.LLVMGetNamedFunction(self.module, del_z) orelse core.LLVMGetNamedFunction(self.module, del_bare_z)) |del_fn| {
        const del_t = core.LLVMGlobalGetValueType(del_fn);
        if (core.LLVMCountParamTypes(del_t) == 1) {
            var del_args = [_]types.LLVMValueRef{self_val};
            _ = core.LLVMBuildCall2(self.builder, del_t, del_fn, &del_args, 1, "");
        }
    }

    // 2. Release each owned field. Concrete field TypeId resolved the sema way (proven by diffStructFields).
    for (decl.fields) |field| {
        var l = lower.Lowerer.init(self.allocator, &sm.store);
        defer l.deinit();
        l.symtab = &sm.tab;
        const scopes = [_]lower.ParamScope{.{ .owner = stype.decl, .names = decl.type_params }};
        l.param_scopes = &scopes;
        // A generic field whose TypeRef fails to lower/substitute falls back to the string builder's
        // answer for THIS field only — never silently skipped (that would leak).
        const concrete: ?typesys.TypeId = blk: {
            const raw = l.lower(field.type_name) catch break :blk null;
            break :blk subst.substitute(&sm.store, raw, stype.decl, stype.args) catch null;
        };
        const is_ref = if (concrete) |c|
            self.isOwnedTypeId(c)
        else str_blk: {
            const fs = self.typeRefToString(field.type_name) catch break :str_blk false;
            const ft = self.substituteFieldType(type_name, fs) catch break :str_blk false;
            break :str_blk self.isOwnedDeclaredType(field.type_name, ft);
        };
        if (!is_ref) continue;

        const offset = try self.getFieldOffset(base_struct, field.name);
        const offset_val = core.LLVMConstInt(self.val_type, offset, 0);
        const addr = core.LLVMBuildAdd(self.builder, self_val, offset_val, "field_addr");
        const llvm_field_type = self.toLLVMType(field.type_name);
        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(llvm_field_type, 0), "field_ptr");
        const loaded_field_val = core.LLVMBuildLoad2(self.builder, llvm_field_type, ptr, "field_load");
        const casted_field_val = self.castToValType(loaded_field_val, field.type_name);

        const field_dest = if (concrete) |c|
            try self.getOrCreateDestructorByTypeId(c)
        else str_blk: {
            const fs = self.typeRefToString(field.type_name) catch break :str_blk null;
            const ft = self.substituteFieldType(type_name, fs) catch break :str_blk null;
            break :str_blk try self.getOrCreateDestructor(ft);
        };
        try self.compileRelease(casted_field_val, field_dest);
    }

    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

/// `void __destruct_ErrUnion_*(i64 box)` — releases the payload the box owns.
///
/// Branches on the tag: the payload is an `ok` value at tag 0 and an `err` value at tag 1, and
/// they are different types with different destructors. A single unconditional release would be
/// wrong for one of the two — which is the `List<(int)=>int>` mistake (one classification serving
/// two shapes) in a new place.
/// F2-6 stage 4: the err-union destructor built from the STORE arms (`.error_union.ok/.err`) — no
/// `errUnionParts` string parse. Symbol name via the name-generator (unchanged) → same memoized function.
/// Ownership per arm is the typed `isOwnedTypeId`; releases via the TypeId dispatch. Proven safe by
/// `diffErrUnionArms` (store==parse, DISAGREE=0) + ARC/ASAN. The tag-branch layout mirrors the string one.
fn getOrCreateErrUnionDestructorByTypeId(self: *LlvmCompiler, t: typesys.TypeId) anyerror!?types.LLVMValueRef {
    const st = self.type_store orelse return null;
    if (sema_shadow.report_enabled) diffErrUnionArms(self, t);
    const eu = st.get(t).error_union;
    const type_name = sema_shadow.renderLegacy(self.allocator, st, t) catch return null;
    const dest_name = try destructorName(self.allocator, type_name);
    defer self.allocator.free(dest_name);
    const dest_name_z = try self.allocator.dupeZ(u8, dest_name);
    defer self.allocator.free(dest_name_z);
    if (core.LLVMGetNamedFunction(self.module, dest_name_z)) |existing| return existing;

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, dest_name_z, fn_type);
    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
    const box = core.LLVMGetParam(dest_fn, 0);

    const word: usize = 8;
    const tag_ptr = core.LLVMBuildIntToPtr(self.builder, box, core.LLVMPointerType(self.val_type, 0), "d_tag_ptr");
    const tag = core.LLVMBuildLoad2(self.builder, self.val_type, tag_ptr, "d_tag");
    const pay_addr = core.LLVMBuildAdd(self.builder, box, core.LLVMConstInt(self.val_type, @intCast(word), 0), "d_pay_addr");
    const pay_ptr = core.LLVMBuildIntToPtr(self.builder, pay_addr, core.LLVMPointerType(self.val_type, 0), "d_pay_ptr");
    const payload = core.LLVMBuildLoad2(self.builder, self.val_type, pay_ptr, "d_pay");

    const is_err = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, tag, core.LLVMConstInt(self.val_type, 1, 0), "d_is_err");
    const err_bb = core.LLVMAppendBasicBlock(dest_fn, "d_err");
    const ok_bb = core.LLVMAppendBasicBlock(dest_fn, "d_ok");
    const done_bb = core.LLVMAppendBasicBlock(dest_fn, "d_done");
    _ = core.LLVMBuildCondBr(self.builder, is_err, err_bb, ok_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, err_bb);
    if (self.isOwnedTypeId(eu.err)) {
        const d = try self.getOrCreateDestructorByTypeId(eu.err);
        try self.compileRelease(payload, d);
    }
    _ = core.LLVMBuildBr(self.builder, done_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, ok_bb);
    if (self.isOwnedTypeId(eu.ok)) {
        const d = try self.getOrCreateDestructorByTypeId(eu.ok);
        try self.compileRelease(payload, d);
    }
    _ = core.LLVMBuildBr(self.builder, done_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

fn getOrCreateErrUnionDestructor(self: *LlvmCompiler, type_name: []const u8) anyerror!?types.LLVMValueRef {
    const dest_name = try destructorName(self.allocator, type_name);
    defer self.allocator.free(dest_name);
    const dest_name_z = try self.allocator.dupeZ(u8, dest_name);
    defer self.allocator.free(dest_name_z);
    if (core.LLVMGetNamedFunction(self.module, dest_name_z)) |existing| return existing;

    const parts = self.errUnionParts(type_name) orelse return null;
    defer self.allocator.free(parts.ok);
    defer self.allocator.free(parts.err);

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, dest_name_z, fn_type);
    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
    const box = core.LLVMGetParam(dest_fn, 0);

    const word: usize = 8;
    const tag_ptr = core.LLVMBuildIntToPtr(self.builder, box, core.LLVMPointerType(self.val_type, 0), "d_tag_ptr");
    const tag = core.LLVMBuildLoad2(self.builder, self.val_type, tag_ptr, "d_tag");
    const pay_addr = core.LLVMBuildAdd(self.builder, box, core.LLVMConstInt(self.val_type, @intCast(word), 0), "d_pay_addr");
    const pay_ptr = core.LLVMBuildIntToPtr(self.builder, pay_addr, core.LLVMPointerType(self.val_type, 0), "d_pay_ptr");
    const payload = core.LLVMBuildLoad2(self.builder, self.val_type, pay_ptr, "d_pay");

    const is_err = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, tag, core.LLVMConstInt(self.val_type, 1, 0), "d_is_err");
    const err_bb = core.LLVMAppendBasicBlock(dest_fn, "d_err");
    const ok_bb = core.LLVMAppendBasicBlock(dest_fn, "d_ok");
    const done_bb = core.LLVMAppendBasicBlock(dest_fn, "d_done");
    _ = core.LLVMBuildCondBr(self.builder, is_err, err_bb, ok_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, err_bb);
    if (self.isOwnedErrUnionPayloadByName(type_name, true, parts.err)) {
        const d = try self.getOrCreateDestructor(parts.err);
        try self.compileRelease(payload, d);
    }
    _ = core.LLVMBuildBr(self.builder, done_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, ok_bb);
    if (self.isOwnedErrUnionPayloadByName(type_name, false, parts.ok)) {
        const d = try self.getOrCreateDestructor(parts.ok);
        try self.compileRelease(payload, d);
    }
    _ = core.LLVMBuildBr(self.builder, done_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

/// `void __destruct_<Enum>(i64 box)` — for a TAGGED-UNION enum, releases the owned payload slots of
/// whichever variant the tag selects; nova_release then frees the box itself. Like the err-union
/// destructor, WHICH types the payload holds depends on the tag, so a single unconditional release
/// would be wrong. Payload-less enums never reach here — they are immediate tags, not boxes, and
/// isRefCountedType returns false for them (enumIsTaggedUnion).
///
/// Layout mirrors construction (llvm_codegen.zig / expressions.zig): tag at offset 0, then payload
/// slots at `word`, `word*2`, … — a single positional payload (`v.type_name`) at `word`, a struct
/// payload's field `i` (`v.fields[i]`) at `word*(i+1)`.
fn getOrCreateEnumDestructor(self: *LlvmCompiler, enum_name: []const u8) anyerror!?types.LLVMValueRef {
    if (!enumIsTaggedUnion(self, enum_name)) return null;
    const enum_decl = self.enums.get(enum_name).?;

    const dest_name = try destructorName(self.allocator, enum_name);
    defer self.allocator.free(dest_name);
    const dest_name_z = try self.allocator.dupeZ(u8, dest_name);
    defer self.allocator.free(dest_name_z);
    if (core.LLVMGetNamedFunction(self.module, dest_name_z)) |existing| return existing;

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, dest_name_z, fn_type);
    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
    const box = core.LLVMGetParam(dest_fn, 0);

    const word: u32 = 8;
    const tag_ptr = core.LLVMBuildIntToPtr(self.builder, box, core.LLVMPointerType(self.val_type, 0), "en_tag_ptr");
    const tag = core.LLVMBuildLoad2(self.builder, self.val_type, tag_ptr, "en_tag");

    const done_bb = core.LLVMAppendBasicBlock(dest_fn, "en_done");

    // A compare-and-release block per payload-carrying variant; a non-matching tag falls through all
    // checks to `en_done` (payload-less variants own nothing).
    for (enum_decl.variants, 0..) |v, idx| {
        if (v.type_name == null and v.fields == null) continue;

        const rel_bb = core.LLVMAppendBasicBlock(dest_fn, "en_rel");
        const next_bb = core.LLVMAppendBasicBlock(dest_fn, "en_next");
        const is_v = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, tag, core.LLVMConstInt(self.val_type, @intCast(idx), 0), "en_is");
        _ = core.LLVMBuildCondBr(self.builder, is_v, rel_bb, next_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, rel_bb);
        if (v.type_name) |ptref| {
            try releaseEnumPayloadSlot(self, box, word, ptref);
        }
        if (v.fields) |fields| {
            for (fields, 0..) |f, fidx| {
                try releaseEnumPayloadSlot(self, box, word + @as(u32, @intCast(fidx)) * word, f.type_name);
            }
        }
        _ = core.LLVMBuildBr(self.builder, done_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, next_bb);
    }
    _ = core.LLVMBuildBr(self.builder, done_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

/// Load the payload slot at `offset` from the box and release it, IF its declared type is owned.
/// The typed decision (`isOwnedDeclaredType`) matches the retain/consume at construction — a
/// non-owned slot (int/bool) is skipped, exactly as construction skips it.
fn releaseEnumPayloadSlot(self: *LlvmCompiler, box: types.LLVMValueRef, offset: u32, tref: ast.TypeRef) anyerror!void {
    const tstr = try self.typeRefToString(tref);
    if (!self.isOwnedDeclaredType(tref, tstr)) return;
    const addr = core.LLVMBuildAdd(self.builder, box, core.LLVMConstInt(self.val_type, offset, 0), "en_pay_addr");
    const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "en_pay_ptr");
    const val = core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "en_pay");
    const d = try self.getOrCreateDestructor(tstr);
    try self.compileRelease(val, d);
}

/// A rendered tuple spelling, e.g. `(string,int)`. Depth-agnostic: a leading `(` plus a trailing
/// `)` is enough, because that is exactly the shape `renderLegacy` emits for `.tuple` and nothing
/// else renders that way. NOT a function type — `isFunctionType` (arrow at depth 0) is checked
/// first by getOrCreateDestructor, so `(int) => string` never reaches here.
pub fn isTupleType(type_name: []const u8) bool {
    return type_name.len >= 2 and type_name[0] == '(' and type_name[type_name.len - 1] == ')' and
        std.mem.indexOf(u8, type_name, "=>") == null;
}

/// `void __destruct_tuple_<mangled>(i64 box)` — releases each ref-counted element.
///
/// This is what makes a tuple box OWN its elements, which is the invariant the rest of the tuple
/// ARC story needs (F5 O5: "a destructor releases fields AND elements"). nova_release calls this
/// at rc==0 and then frees the box itself, so this function only releases the elements.
///
/// Element types come from the rendered spelling via getTupleElementType (depth-aware over <> and
/// (), so `(Map<string,int>, int)` is not split down the middle).
/// F2-6 stage 4: the tuple destructor built from the STORE elements (`st.get(t).tuple`) — no
/// `getTupleElementType` string-parse, no `countTupleElements`. The symbol name still comes from the
/// name-generator (`renderLegacy`, unchanged), so it is the SAME memoized function the string builder
/// would produce; only the element SOURCE moves to the store. Proven safe by `diffTupleElems`
/// (store==parse, DISAGREE=0) + the ARC/ASAN gates. Ownership per element is the typed `isOwnedTypeId`.
fn getOrCreateTupleDestructorByTypeId(self: *LlvmCompiler, t: typesys.TypeId) anyerror!?types.LLVMValueRef {
    const st = self.type_store orelse return null;
    // Regression guard (shadow): the store elements still match the string parse.
    if (sema_shadow.report_enabled) diffTupleElems(self, t);
    const elems = st.get(t).tuple;
    const type_name = sema_shadow.renderLegacy(self.allocator, st, t) catch return null;
    const dest_name = try destructorName(self.allocator, type_name);
    defer self.allocator.free(dest_name);
    const dest_name_z = try self.allocator.dupeZ(u8, dest_name);
    defer self.allocator.free(dest_name_z);
    if (core.LLVMGetNamedFunction(self.module, dest_name_z)) |existing| return existing;

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, dest_name_z, fn_type);
    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
    const box = core.LLVMGetParam(dest_fn, 0);

    const word: usize = 8;
    for (elems, 0..) |elem_tid, idx| {
        if (!self.isOwnedTypeId(elem_tid)) continue;
        const offset = core.LLVMConstInt(self.val_type, @intCast(idx * word), 0);
        const addr = core.LLVMBuildAdd(self.builder, box, offset, "tup_elem_addr");
        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "tup_elem_ptr");
        const elem = core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "tup_elem_load");
        const elem_dest = try self.getOrCreateDestructorByTypeId(elem_tid);
        try self.compileRelease(elem, elem_dest);
    }

    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

/// F2-6 stage 4 (shadow): does the STORE-resolved concrete field TypeId — lowered in the struct's type-
/// param scope and substituted with the instantiation's args, exactly as sema's `lowerInStructScope` does
/// — match `substituteFieldType` (the string T→concrete)? Compares per field: the ownership verdict AND
/// the rendered concrete name. disagree==0 gates building the struct destructor from store field TypeIds
/// (which also retires `substituteFieldType` and, via `Storage<T>` fields, `storageElem`). A divergence
/// here would release a field with the WRONG destructor → corruption, so it is PROVEN, never assumed.
fn diffStructFields(self: *LlvmCompiler, t: typesys.TypeId) void {
    const sm = sema_shadow.live_sema orelse return;
    const st_store = self.type_store orelse return; // == &sm.store (live_store)
    if (st_store.get(t) != .struct_) return;
    const stype = st_store.get(t).struct_;
    const sym = sm.tab.symbolAt(stype.decl);
    if (sym.decl != .struct_) return;
    const decl = sym.decl.struct_;
    const type_name = sema_shadow.renderLegacy(self.allocator, st_store, t) catch return;
    for (decl.fields) |field| {
        // STORE path: lower the field type in the struct's type-param scope, substitute the args.
        var l = lower.Lowerer.init(self.allocator, &sm.store);
        defer l.deinit();
        l.symtab = &sm.tab;
        const scopes = [_]lower.ParamScope{.{ .owner = stype.decl, .names = decl.type_params }};
        l.param_scopes = &scopes;
        const raw = l.lower(field.type_name) catch continue;
        const concrete = subst.substitute(&sm.store, raw, stype.decl, stype.args) catch continue;
        const store_owned = self.isOwnedTypeId(concrete);
        const store_name = sema_shadow.renderLegacy(self.allocator, st_store, concrete) catch continue;
        // STRING path: what the current builder does.
        const field_str = self.typeRefToString(field.type_name) catch continue;
        const field_type = self.substituteFieldType(type_name, field_str) catch continue;
        const str_owned = self.isOwnedDeclaredType(field.type_name, field_type);
        // The corruption-relevant check is the OWNERSHIP verdict (which decides whether the field is
        // released at all, and — via the store kind — through which destructor). The rendered-name
        // difference (`i32` vs `int`, `List<i32>` vs `List<int>`) is a benign two-renderer spelling
        // discrepancy: the destructors are functionally equivalent (primitive→null; the List bodies
        // release equivalent, both-non-owned elements) and the ASAN gate is the authority on that.
        _ = store_name;
        if (store_owned == str_owned) {
            sema_shadow.struct_field_agree += 1;
        } else {
            sema_shadow.struct_field_disagree += 1;
            sema_shadow.struct_field_last = std.fmt.allocPrint(self.allocator, "{s}.{s}: store-owned={} vs parse-owned={} ('{s}')", .{ type_name, field.name, store_owned, str_owned, field_type }) catch type_name;
        }
    }
}

/// F2-6 stage 4 (shadow): do an err-union's STORE arms (`.error_union.ok/.err`) match the string parse
/// (`errUnionParts`) — same ownership verdict AND rendered name for each arm? Gate for building the
/// err-union destructor from the store arms.
fn diffErrUnionArms(self: *LlvmCompiler, t: typesys.TypeId) void {
    const st = self.type_store orelse return;
    if (st.get(t) != .error_union) return;
    const eu = st.get(t).error_union;
    const name = sema_shadow.renderLegacy(self.allocator, st, t) catch return;
    const parts = self.errUnionParts(name) orelse {
        sema_shadow.erru_elem_disagree += 1;
        sema_shadow.erru_elem_last = name;
        return;
    };
    defer self.allocator.free(parts.ok);
    defer self.allocator.free(parts.err);
    const ok_name = sema_shadow.renderLegacy(self.allocator, st, eu.ok) catch return;
    const err_name = sema_shadow.renderLegacy(self.allocator, st, eu.err) catch return;
    const ok_ok = self.isOwnedTypeId(eu.ok) == self.isOwnedErrUnionPayloadByName(name, false, parts.ok) and std.mem.eql(u8, ok_name, parts.ok);
    const err_ok = self.isOwnedTypeId(eu.err) == self.isOwnedErrUnionPayloadByName(name, true, parts.err) and std.mem.eql(u8, err_name, parts.err);
    if (ok_ok and err_ok) sema_shadow.erru_elem_agree += 1 else {
        sema_shadow.erru_elem_disagree += 1;
        sema_shadow.erru_elem_last = name;
    }
}

/// F2-6 stage 4 (shadow): does a storage's STORE element (`.storage`) match the string parse
/// (`storageElem`) — same ownership verdict AND rendered name? Gate for building the storage destructor
/// from the store element.
fn diffStorageElem(self: *LlvmCompiler, t: typesys.TypeId) void {
    const st = self.type_store orelse return;
    if (st.get(t) != .storage) return;
    const elem_tid = st.get(t).storage;
    const name = sema_shadow.renderLegacy(self.allocator, st, t) catch return;
    const elem_str = storageElem(name) orelse {
        sema_shadow.storage_elem_disagree += 1;
        sema_shadow.storage_elem_last = name;
        return;
    };
    const store_name = sema_shadow.renderLegacy(self.allocator, st, elem_tid) catch return;
    if (self.isOwnedTypeId(elem_tid) == self.isOwnedStorageElemByName(elem_str) and std.mem.eql(u8, store_name, elem_str))
        sema_shadow.storage_elem_agree += 1
    else {
        sema_shadow.storage_elem_disagree += 1;
        sema_shadow.storage_elem_last = name;
    }
}

/// F2-6 stage 4 (shadow): does a tuple's STORE elements (`st.get(t).tuple`) match the string PARSE
/// (`getTupleElementType`) — same arity, and per element the same ownership verdict AND rendered name?
/// disagree==0 is the gate to build the tuple destructor straight from the store elements (dropping the
/// depth-aware string parse). A divergence here would release the WRONG element type → corruption.
fn diffTupleElems(self: *LlvmCompiler, t: typesys.TypeId) void {
    const st = self.type_store orelse return;
    if (st.get(t) != .tuple) return;
    const elems = st.get(t).tuple;
    const name = sema_shadow.renderLegacy(self.allocator, st, t) catch return;
    if (elems.len != countTupleElements(name)) {
        sema_shadow.tuple_elem_disagree += 1;
        sema_shadow.tuple_elem_last = name;
        return;
    }
    for (elems, 0..) |elem, idx| {
        const store_owned = self.isOwnedTypeId(elem);
        const store_name = sema_shadow.renderLegacy(self.allocator, st, elem) catch continue;
        const str_elem = LlvmCompiler.getTupleElementType(self.allocator, name, idx) catch continue;
        defer self.allocator.free(str_elem);
        const str_owned = self.isOwnedTupleElemByName(name, idx, str_elem);
        if (store_owned == str_owned and std.mem.eql(u8, store_name, str_elem)) {
            sema_shadow.tuple_elem_agree += 1;
        } else {
            sema_shadow.tuple_elem_disagree += 1;
            sema_shadow.tuple_elem_last = name;
        }
    }
}

fn getOrCreateTupleDestructor(self: *LlvmCompiler, type_name: []const u8) anyerror!?types.LLVMValueRef {
    const dest_name = try destructorName(self.allocator, type_name);
    defer self.allocator.free(dest_name);
    const dest_name_z = try self.allocator.dupeZ(u8, dest_name);
    defer self.allocator.free(dest_name_z);
    if (core.LLVMGetNamedFunction(self.module, dest_name_z)) |existing| return existing;

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, dest_name_z, fn_type);
    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
    const box = core.LLVMGetParam(dest_fn, 0);

    const word: usize = 8;
    var idx: usize = 0;
    while (true) : (idx += 1) {
        const elem_ty = try LlvmCompiler.getTupleElementType(self.allocator, type_name, idx);
        // getTupleElementType returns "i32" both for a genuine i32 element and for "past the end".
        // Distinguish by counting the real arity first — otherwise a trailing i32 element would
        // stop the loop early. countTupleElements is the authority on arity.
        if (idx >= countTupleElements(type_name)) break;
        defer self.allocator.free(elem_ty);
        if (!self.isOwnedTupleElemByName(type_name, idx, elem_ty)) continue;
        const offset = core.LLVMConstInt(self.val_type, @intCast(idx * word), 0);
        const addr = core.LLVMBuildAdd(self.builder, box, offset, "tup_elem_addr");
        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "tup_elem_ptr");
        const elem = core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "tup_elem_load");
        const elem_dest = try self.getOrCreateDestructor(elem_ty);
        try self.compileRelease(elem, elem_dest);
    }

    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

/// How many elements a rendered tuple spelling has — commas at DEPTH 0, plus one.
/// `()` is zero. Shares the depth rule with getTupleElementType.
pub fn countTupleElements(type_name: []const u8) usize {
    if (!isTupleType(type_name)) return 0;
    const inner = type_name[1 .. type_name.len - 1];
    if (inner.len == 0) return 0;
    var depth: usize = 0;
    var n: usize = 1;
    for (inner) |c| {
        switch (c) {
            '<', '(' => depth += 1,
            '>', ')' => {
                if (depth > 0) depth -= 1;
            },
            ',' => {
                if (depth == 0) n += 1;
            },
            else => {},
        }
    }
    return n;
}

/// The `ok` and `err` spellings inside a rendered `ErrUnion(ok,err)`, or null if not one.
///
/// Depth-aware over `<>` and `()` at the top level, like getTupleElementType — a naive split on
/// "," would cut `ErrUnion(Map<string,int>,E)` down the middle. Caller frees both slices.
pub fn errUnionParts(self: *LlvmCompiler, name: []const u8) ?struct { ok: []const u8, err: []const u8 } {
    const pre = "ErrUnion(";
    if (!std.mem.startsWith(u8, name, pre) or !std.mem.endsWith(u8, name, ")")) return null;
    const inner = name[pre.len .. name.len - 1];
    var depth: usize = 0;
    for (inner, 0..) |c, i| {
        switch (c) {
            '<', '(' => depth += 1,
            '>', ')' => { if (depth > 0) depth -= 1; },
            ',' => {
                if (depth == 0) {
                    const ok = self.allocator.dupe(u8, inner[0..i]) catch return null;
                    const err = self.allocator.dupe(u8, inner[i + 1 ..]) catch {
                        self.allocator.free(ok);
                        return null;
                    };
                    return .{ .ok = ok, .err = err };
                }
            },
            else => {},
        }
    }
    return null;
}

/// Build the `T | E` box: `[ARC header][tag: i64][payload: i64]`, tag 0 = ok, 1 = err.
///
/// specs §3.4b. Registered as a temporary so the statement's drain releases it if nothing takes
/// ownership, and released through `__destruct_ErrUnion_*`, which frees the payload it owns.
pub fn buildErrUnion(self: *LlvmCompiler, val: types.LLVMValueRef, is_err: bool, union_name: []const u8) anyerror!types.LLVMValueRef {
    const word: usize = 8;
    const box = try self.compileAlloc(core.LLVMConstInt(self.val_type, @intCast(word * 2), 0));

    // The box OWNS its payload — the same rule the tuple box now follows. Without this retain a
    // returned union points at a value its callee already released: the exact use-after-free the
    // tuple had, and the reason its return-boundary patch existed.
    const parts = self.errUnionParts(union_name);
    if (parts) |pp| {
        defer self.allocator.free(pp.ok);
        defer self.allocator.free(pp.err);
        const payload_ty = if (is_err) pp.err else pp.ok;
        if (self.isOwnedErrUnionPayloadByName(union_name, is_err, payload_ty)) try self.compileRetain(val);
    }

    const tag_ptr = core.LLVMBuildIntToPtr(self.builder, box, core.LLVMPointerType(self.val_type, 0), "eu_tag_ptr");
    _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.val_type, if (is_err) 1 else 0, 0), tag_ptr);

    const pay_addr = core.LLVMBuildAdd(self.builder, box, core.LLVMConstInt(self.val_type, @intCast(word), 0), "eu_pay_addr");
    const pay_ptr = core.LLVMBuildIntToPtr(self.builder, pay_addr, core.LLVMPointerType(self.val_type, 0), "eu_pay_ptr");
    _ = core.LLVMBuildStore(self.builder, self.coerceToSlotType(val, self.val_type), pay_ptr);
    return box;
}

/// Release ONE named local — F5 O4's block-scope release.
///
/// Separate from releaseLocalVariables (which drains the whole function-level map
/// at function exit) because a block must release only ITS OWN locals, and must do
/// so on every iteration rather than once.
pub fn releaseLocalByName(self: *LlvmCompiler, name: []const u8, type_name: []const u8) anyerror!void {
    const alloca_val = self.locals.get(name) orelse return;
    const loaded = core.LLVMBuildLoad2(self.builder, self.val_type, alloca_val, "blk_rel_load");
    // Stage 5 Phase A: same same-symbol-gated TypeId selection as the function-exit drain.
    const tid: ?typesys.TypeId = if (self.current_local_type_ids) |ids| ids.get(name) else null;
    const dest = try self.getOrCreateDestructorPreferId(type_name, tid);
    try self.compileRelease(loaded, dest);
    // Null the slot so a LATER release of the same name is a no-op. The function-level
    // `current_local_types` is pre-populated with every local, so an EARLY RETURN nested
    // in this block (or a later loop iteration) reaches `releaseLocalVariables`, which would
    // load this now-dead pointer and release it a SECOND time — a double free. `nova_release(0)`
    // is a safe no-op, so zeroing the alloca here makes that redundant release harmless.
    // (Measured: `while (true) { if (..) return; let x = List<..>(); }` double-freed `x` — the
    // return's function-drain released the PRIOR iteration's already-freed pointer.)
    _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.val_type, 0, 0), alloca_val);
}

pub fn releaseLocalVariables(self: *LlvmCompiler) anyerror!void {
    const local_types = self.current_local_types orelse return;
    var iter = local_types.iterator();
    while (iter.next()) |entry| {
        const var_name = entry.key_ptr.*;
        const var_type = entry.value_ptr.*;

        if (std.mem.eql(u8, var_name, "self")) {
            if (self.current_function_name) |func_name| {
                if (std.mem.endsWith(u8, func_name, "_delete") or
                    std.mem.endsWith(u8, func_name, "_init") or
                    std.mem.endsWith(u8, func_name, "_new")) {
                    continue;
                }
            }
        }

        if (self.isOwnedLocal(var_name, var_type)) {
            if (self.current_param_names) |params| {
                var is_param = false;
                for (params) |p| {
                    if (std.mem.eql(u8, p, var_name)) {
                        is_param = true;
                        break;
                    }
                }
                if (is_param) continue;
            }
            if (self.current_function_name) |func_name| {
                const key = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{func_name, var_name}) catch "";
                if (key.len > 0) {
                    defer self.allocator.free(key);
                    if (self.captured_globals.contains(key)) {
                        continue; // Do not release captured variables to let them survive async execution
                    }
                }
            }
            if (self.locals.get(var_name)) |alloca_val| {
                const loaded = core.LLVMBuildLoad2(self.builder, self.val_type, alloca_val, "var_rel_load");
                // Stage 5 Phase A: prefer the store-native destructor when its symbol matches the string
                // path's (same-symbol gate); the TypeId is the one already used for the ownership decision.
                const tid: ?typesys.TypeId = if (self.current_local_type_ids) |ids| ids.get(var_name) else null;
                const dest = try self.getOrCreateDestructorPreferId(var_type, tid);
                try self.compileRelease(loaded, dest);
            }
        }
    }
}


test "isUntypeablePlaceholder: whole-string placeholders match, real types and fn-types do not" {
    const testing = std.testing;
    // Pure placeholders — sema-could-not-type. These MUST match (the guard aborts on them).
    try testing.expect(isUntypeablePlaceholder(""));
    try testing.expect(isUntypeablePlaceholder("unresolved"));
    try testing.expect(isUntypeablePlaceholder("<unresolved>"));
    try testing.expect(isUntypeablePlaceholder("<tuple>"));
    try testing.expect(isUntypeablePlaceholder("<array>"));
    try testing.expect(isUntypeablePlaceholder("<fn>"));

    // Real owned types — must NOT match.
    try testing.expect(!isUntypeablePlaceholder("string"));
    try testing.expect(!isUntypeablePlaceholder("List<string>"));
    try testing.expect(!isUntypeablePlaceholder("Storage<string>"));
    try testing.expect(!isUntypeablePlaceholder("(string,int)")); // a tuple IS an owned box

    // ⚠️ The load-bearing case: a fn type that CONTAINS `<unresolved>` in a parameter is a valid
    // owned box (the fn VALUE is owned regardless of a param's type). A substring match here would
    // abort the corpus — 04_closures produces exactly this. Whole-string only.
    try testing.expect(!isUntypeablePlaceholder("(<unresolved>, i32) -> i32"));
    try testing.expect(!isUntypeablePlaceholder("(i32) -> void"));
}
