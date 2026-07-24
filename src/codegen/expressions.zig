const std = @import("std");
const ast = @import("../ast.zig");
const llvm = @import("llvm");
const types = llvm.types;
const core = llvm.core;

const LlvmCompiler = @import("llvm_codegen.zig").LlvmCompiler;
const sema_shadow = @import("../sema/shadow.zig");
const sema_infer = @import("../sema/infer.zig");
const sema_types = @import("../types.zig");
const types_mod = @import("types.zig");
const getStructBaseName = @import("types.zig").getStructBaseName;
const namesExistingOwner = @import("arc.zig").namesExistingOwner;
const getClosureUniqueId = LlvmCompiler.getClosureUniqueId;
const unescapeString = @import("llvm_codegen.zig").unescapeString;
const FunctionInfo = @import("llvm_codegen.zig").FunctionInfo;
const Scope = @import("llvm_codegen.zig").Scope;

// #6/#7: does this identifier name a *variable* in the current scope? Mirrors the
// lookups the `.ident` expression path does, in the same order (env capture ->
// captured global -> local). `.field_access` uses it to tell `some_var.field`
// (a field read) from `some_module.fn` (a function reference) — without it the
// flat namespace lets a global fn hijack a field of the same name.
/// Widen `*val` from a struct to the trait object `trait_name` IN PLACE when `branch` resolves to a
/// struct — the shared widen discipline used at every trait-widening site (let / field / tuple / if-expr
/// branch): construct the fat pointer, CONSUME the struct's own construction temp AND the fat-pointer
/// temp (so the statement drain frees neither — a second free of the struct is a UAF), then release the
/// struct's orphaned construction ref (constructTraitObject retained it). Returns true when it widened,
/// so the caller skips its takeOwnedElement (the widen already gave the +1). No-op (returns false) when
/// `trait_name` is null or the branch is not a struct.
pub fn widenBranchToTrait(self: *LlvmCompiler, branch: *const ast.Expression, val: *types.LLVMValueRef, trait_name: ?[]const u8) anyerror!bool {
    const tn = trait_name orelse return false;
    const st = (try self.resolveExpressionTypeName(branch)) orelse return false;
    if (!self.structs.contains(st)) return false;
    const orig = val.*;
    self.consumeTemporary(orig);
    val.* = try self.constructTraitObject(orig, st, tn);
    self.consumeTemporary(val.*);
    // Stage 5 Phase B: release the orphaned struct ref via its store-native dtor when the same-symbol
    // gate allows (the branch's TypeId is the concrete struct being widened); string fallback otherwise.
    const tid: ?sema_types.TypeId = if (self.typed_ir) |ir| ir.typeOf(branch) else null;
    const sdtor = try self.getOrCreateDestructorPreferId(st, tid);
    try self.compileRelease(orig, sdtor);
    return true;
}

pub fn identNamesVariable(self: *LlvmCompiler, name: []const u8) bool {
    if (self.envCaptureIndex(name) != null) return true;
    if (self.locals.contains(name)) return true;
    // A local promoted to a global (async/lambda capture) is keyed "{fn}_{name}"
    // and walked up the lambda-parent chain.
    var curr_fn = self.current_function_name;
    while (curr_fn) |fn_name| {
        const key = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ fn_name, name }) catch return false;
        defer self.allocator.free(key);
        if (self.captured_globals.contains(key)) return true;
        curr_fn = self.lambda_parents.get(fn_name);
    }
    return false;
}

// #18: a function value has exactly one representation — the box {fn_ptr, env},
// where fn_ptr's signature is fn(env, args...). A lambda is born that way (A1);
// a bare `fn` is not — it is a raw code pointer with no env parameter. Boxing
// that pointer as-is would still be wrong: the call path passes env as a hidden
// leading argument, shifting every user argument by one. So wrap the target in a
// thunk that swallows env and forwards the rest, and box the thunk instead.
//
// The box is a module-level constant rather than a heap alloc: a bare fn
// captures nothing, so there is no per-instance state and nothing to leak.
// Caching one box per target also preserves fn-value equality — `string.hash`
// evaluates to the same address everywhere, so map.nova's
// `self.hashFn == string.hash` keeps working.
pub fn buildBareFnBox(self: *LlvmCompiler, fn_val: types.LLVMValueRef) anyerror!types.LLVMValueRef {
    const fn_name = std.mem.span(core.LLVMGetValueName(fn_val));
    if (self.fn_box_globals.get(fn_name)) |box_g| {
        // §3.4j: the PAYLOAD pointer (global + 8) — the box carries an 8-byte ARC
        // header now, and this is a stable per-function address so fn-value equality
        // (`self.hashFn == string.hash`) still holds.
        return self.fnBoxReturn(box_g, fn_name);
    }

    const target_ft = core.LLVMGlobalGetValueType(fn_val);
    const arity = core.LLVMCountParamTypes(target_ft);

    // Thunk: fn(env, a1..aN) -> val_type. A uniform val_type signature is what
    // lets buildClosureCall invoke it without knowing the target's real types.
    const nparams: usize = @intCast(arity + 1);
    const params = try self.allocator.alloc(types.LLVMTypeRef, nparams);
    defer self.allocator.free(params);
    @memset(params, self.val_type);
    const thunk_ft = core.LLVMFunctionType(self.val_type, params.ptr, @intCast(nparams), 0);

    const thunk_name = try std.fmt.allocPrintSentinel(self.allocator, "__fnbox_thunk_{s}", .{fn_name}, 0);
    defer self.allocator.free(thunk_name);
    const thunk = core.LLVMAddFunction(self.module, thunk_name, thunk_ft);
    core.LLVMSetLinkage(thunk, .LLVMInternalLinkage);

    // Emit the thunk body out of line, then put the builder back where it was.
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    const entry_bb = core.LLVMAppendBasicBlock(thunk, "entry");
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);

    const fwd = try self.allocator.alloc(types.LLVMValueRef, @intCast(arity));
    defer self.allocator.free(fwd);
    for (fwd, 0..) |*slot, i| {
        slot.* = core.LLVMGetParam(thunk, @intCast(i + 1)); // +1 skips env
    }
    // buildCallWithCasts adapts the val_type args and return value to the
    // target's real signature (ptr/width casts, and void -> 0).
    const ret = try self.buildCallWithCasts(fn_val, fwd);
    _ = core.LLVMBuildRet(self.builder, ret);

    if (saved_ip) |sip| {
        core.LLVMPositionBuilderAtEnd(self.builder, sip);
    }

    // The box: `{fn_ptr, env=0}`, prefixed with an 8-byte ARC HEADER so it is a valid
    // reference-counted object (§3.4j). §3.4j makes function-typed values refcounted so
    // HEAP closures get freed — a bare function value shares that type, so this global
    // box would be released too. A `constant` global is read-only, so nova_release
    // writing its refcount would SEGFAULT. So: refcount = 100_000_000, the "never free
    // me" sentinel string literals use — releasing it merely decrements, and the global
    // is writable to allow it. Layout mirrors the heap header:
    // `{i32 refcount, i32 length, [2 x i64] payload}`; the returned pointer is the
    // PAYLOAD (global + 8), so `[ptr-8]` is the refcount and callers' `{fn @0, env @8}`
    // view is unchanged.
    const i32_t = self.i32_type;
    const payload_t = core.LLVMArrayType(self.val_type, 2);
    var box_fields = [_]types.LLVMTypeRef{ i32_t, i32_t, payload_t };
    const box_t = core.LLVMStructType(&box_fields, 3, 1);
    const box_name = try std.fmt.allocPrintSentinel(self.allocator, "__fnbox_{s}", .{fn_name}, 0);
    defer self.allocator.free(box_name);
    const box_g = core.LLVMAddGlobal(self.module, box_t, box_name);
    var slots = [_]types.LLVMValueRef{
        // wasm cannot place a function pointer in a static initializer (function
        // "addresses" are table indices, not link-time constants). Init the fn_ptr
        // slot to 0 and store the thunk into it at runtime (see fnBoxReturn). Native
        // keeps the constant — it is relocatable and needs no runtime store.
        if (self.is_wasm) core.LLVMConstInt(self.val_type, 0, 0) else core.LLVMConstPtrToInt(thunk, self.val_type),
        core.LLVMConstInt(self.val_type, 0, 0),
    };
    var box_init = [_]types.LLVMValueRef{
        core.LLVMConstInt(i32_t, 100000000, 0),
        core.LLVMConstInt(i32_t, 16, 0),
        core.LLVMConstArray(self.val_type, &slots, 2),
    };
    core.LLVMSetInitializer(box_g, core.LLVMConstStruct(&box_init, 3, 1));
    core.LLVMSetGlobalConstant(box_g, 0); // writable: nova_release decrements the rc
    core.LLVMSetLinkage(box_g, .LLVMInternalLinkage);

    try self.fn_box_globals.put(fn_name, box_g);
    return self.fnBoxReturn(box_g, fn_name);
}

// Compute the fnbox payload pointer (global + 8, past the ARC header). On wasm,
// also store the thunk's address into the fn_ptr slot at runtime — the static
// initializer left it 0 because function pointers can't be link-time constants
// there. Idempotent (same value every time) and the box global persists, so a
// later read (map.hashFn, a closure call) sees the populated slot. base+8 is
// exactly the fn_ptr slot, so the returned pointer is also the store target.
pub fn fnBoxReturn(self: *LlvmCompiler, box_g: types.LLVMValueRef, fn_name: []const u8) anyerror!types.LLVMValueRef {
    const base = core.LLVMBuildPtrToInt(self.builder, box_g, self.val_type, "fnbox_base");
    const ptr = core.LLVMBuildAdd(self.builder, base, core.LLVMConstInt(self.val_type, 8, 0), "fnbox_ptr");
    if (self.is_wasm) {
        const thunk_name = try std.fmt.allocPrintSentinel(self.allocator, "__fnbox_thunk_{s}", .{fn_name}, 0);
        defer self.allocator.free(thunk_name);
        const thunk = core.LLVMGetNamedFunction(self.module, thunk_name);
        if (thunk != null) {
            const slot = core.LLVMBuildIntToPtr(self.builder, ptr, self.ptr_type, "fnbox_slot");
            const thunk_addr = core.LLVMBuildPtrToInt(self.builder, thunk, self.val_type, "thunk_addr");
            _ = core.LLVMBuildStore(self.builder, thunk_addr, slot);
        }
    }
    return ptr;
}

// A1: call a closure value. `box_val` is the i64 heap box {fn_ptr, env}; the
// lambda's real signature is fn(env, user_args...), so we unpack the box and
// pass `env` as the hidden leading argument.
pub fn buildClosureCall(self: *LlvmCompiler, box_val: types.LLVMValueRef, call_args: []const ast.Expression) anyerror!types.LLVMValueRef {
    const es = self.valSlotSize();
    const box_ptr = core.LLVMBuildIntToPtr(self.builder, box_val, self.ptr_type, "clo_box");
    const fn_ptr_int = core.LLVMBuildLoad2(self.builder, self.val_type, box_ptr, "clo_fn");
    const env_off = core.LLVMConstInt(self.val_type, es, 0);
    const env_addr = core.LLVMBuildAdd(self.builder, box_val, env_off, "clo_env_addr");
    const env_ptr = core.LLVMBuildIntToPtr(self.builder, env_addr, self.ptr_type, "clo_env_ptr");
    const env_val = core.LLVMBuildLoad2(self.builder, self.val_type, env_ptr, "clo_env");
    const call_ptr = core.LLVMBuildIntToPtr(self.builder, fn_ptr_int, self.ptr_type, "clo_fn_ptr");

    const nparams = call_args.len + 1;
    const params = try self.allocator.alloc(types.LLVMTypeRef, nparams);
    defer self.allocator.free(params);
    @memset(params, self.val_type);
    const fn_t = core.LLVMFunctionType(self.val_type, params.ptr, @intCast(nparams), 0);

    const args = try self.allocator.alloc(types.LLVMValueRef, nparams);
    defer self.allocator.free(args);
    args[0] = env_val;
    for (call_args, 0..) |arg, idx| {
        args[idx + 1] = try self.compileCallArgument(arg);
    }
    return core.LLVMBuildCall2(self.builder, fn_t, call_ptr, args.ptr, @intCast(nparams), "closure_call");
}

// M3-C: the coroutine promise is { i64 result, i64 waiter } (both val_type; async
// is native-only). result carries the return value; waiter is the handle of a
// coroutine awaiting this one (0 = none), scheduled on completion.
pub fn coroPromiseType(self: *LlvmCompiler) types.LLVMTypeRef {
    var fields = [_]types.LLVMTypeRef{ self.val_type, self.val_type };
    return core.LLVMStructType(&fields, 2, 0);
}

pub fn coroPromiseSlot(self: *LlvmCompiler, promise_ptr: types.LLVMValueRef, idx: c_uint, name: [:0]const u8) types.LLVMValueRef {
    var indices = [_]types.LLVMValueRef{
        core.LLVMConstInt(self.i32_type, 0, 0),
        core.LLVMConstInt(self.i32_type, idx, 0),
    };
    return core.LLVMBuildInBoundsGEP2(self.builder, self.coroPromiseType(), promise_ptr, &indices, 2, name.ptr);
}

pub fn coroPromiseResultSlot(self: *LlvmCompiler, promise_ptr: types.LLVMValueRef) types.LLVMValueRef {
    return self.coroPromiseSlot(promise_ptr, 0, "coro.result.slot");
}

pub fn coroPromiseWaiterSlot(self: *LlvmCompiler, promise_ptr: types.LLVMValueRef) types.LLVMValueRef {
    return self.coroPromiseSlot(promise_ptr, 1, "coro.waiter.slot");
}

// M3-C: emit `llvm.coro.promise(handle, 8, false)` → ptr to that coroutine's
// { result, waiter } promise. Works on any coroutine handle (self or a child).
pub fn buildCoroPromisePtr(self: *LlvmCompiler, hdl: types.LLVMValueRef) types.LLVMValueRef {
    const promise_fn = self.func_map.get("llvm.coro.promise").?;
    const promise_t = core.LLVMGlobalGetValueType(promise_fn);
    var p_args = [_]types.LLVMValueRef{
        hdl,
        core.LLVMConstInt(self.i32_type, 8, 0), // promise alignment (val_type = i64)
        core.LLVMConstInt(self.i1_type, 0, 0), // from = false (handle → promise ptr)
    };
    return core.LLVMBuildCall2(self.builder, promise_t, promise_fn, &p_args, 3, "coro.promise");
}

// M3-D: block-drive an async fn call from a non-await context (e.g. a sync `main`
// or test calling an async fn). The ramp returns the root coroutine handle (parked
// at its initial suspend); we schedule it and run the Asio io_context to completion
// (`nova_run` — which resumes the root and every coroutine it awaits, and blocks on
// any pending timers/sockets), then read the result out of the root promise and
// destroy the frame. The event loop resumes coroutines via the raw switched-resume
// ABI in C++; this caller only reads the promise and destroys (compiler intrinsics).
pub fn buildDriveAsyncCall(self: *LlvmCompiler, fn_val: types.LLVMValueRef, args: []const types.LLVMValueRef) anyerror!types.LLVMValueRef {
    const hdl_i = try self.buildCallWithCasts(fn_val, args);
    return try self.buildDriveAsyncHandle(hdl_i);
}

// A1 async-first seam: drive an ALREADY-obtained coroutine handle to completion and read
// its promise result. Used by the free-fn/method drive above (which builds the ramp call
// first) AND by async trait dynamic dispatch, where the vtable indirect call yields the
// handle directly (no static fn_val to build the ramp from).
pub fn buildDriveAsyncHandle(self: *LlvmCompiler, hdl_i: types.LLVMValueRef) anyerror!types.LLVMValueRef {
    const sched_fn = self.func_map.get("nova_sched_schedule").?;
    const sched_t = core.LLVMGlobalGetValueType(sched_fn);
    var sched_args = [_]types.LLVMValueRef{hdl_i};
    _ = core.LLVMBuildCall2(self.builder, sched_t, sched_fn, &sched_args, 1, "");

    // Drive until the root has ACTUALLY completed. `nova_run` alone returns on an
    // idle io_context, which is not the same thing — reading the promise then
    // yields an unwritten slot (the `10_async_go` flake: `await` producing a stale
    // pointer). nova_run_root re-drains while a wakeup is in flight and aborts
    // loudly if one was genuinely lost.
    const run_fn = self.func_map.get("nova_run_root").?;
    const run_t = core.LLVMGlobalGetValueType(run_fn);
    var run_args = [_]types.LLVMValueRef{hdl_i};
    _ = core.LLVMBuildCall2(self.builder, run_t, run_fn, &run_args, 1, "");

    // Root has completed: read its result from the promise, then free the frame.
    const hdl = core.LLVMBuildIntToPtr(self.builder, hdl_i, self.ptr_type, "async.root");
    const prom = self.buildCoroPromisePtr(hdl);
    const rslot = self.coroPromiseResultSlot(prom);
    const result = core.LLVMBuildLoad2(self.builder, self.val_type, rslot, "async.result");

    // Serialised destroy (nova_coro_release) rather than a bare llvm.coro.destroy:
    // uniform with the awaiter sites below, and it costs nothing here (the root is
    // done and the loop has drained, so release finds no live scheduler state).
    const destroy_fn = self.func_map.get("nova_coro_release").?;
    const destroy_t = core.LLVMGlobalGetValueType(destroy_fn);
    var d_args = [_]types.LLVMValueRef{hdl_i};
    _ = core.LLVMBuildCall2(self.builder, destroy_t, destroy_fn, &d_args, 1, "");

    return result;
}

// M3-C: if `operand` is a direct call to an async fn, emit its ramp call and
// return the coroutine handle (i64) — the coroutine parked at its initial suspend,
// NOT block-driven. Returns null for anything else (only direct async calls are
// awaitable for now). Mirrors the resolution in compileExpression's `.call` arm.
pub fn awaitedCallHandle(self: *LlvmCompiler, operand: ast.Expression, is_spawn: bool) anyerror!?types.LLVMValueRef {
    // A direct `.call` OR a `.generic_call` (`await when_all<int>(hs)`) to an async fn. A generic
    // async call resolves to the (erased) base async fn, which IS registered in `async_fns`; without
    // ramping it here the await falls to the "await a handle" path, which assumes the coroutine was
    // already scheduled (by `spawn`) — but a direct await never scheduled it → runtime "lost wakeup".
    var callee_ident: []const u8 = undefined;
    var call_args: []const ast.Expression = undefined;
    // For a module-qualified callee (`async_util.when_all<int>`), the emitted symbol is the
    // full module path (`concurrency_async_util_when_all`), so we also carry the object name
    // to reconstruct `<obj>_<field>` and suffix-scan for it — mirroring the main call path.
    var obj_name: ?[]const u8 = null;
    // A1 async-first seam: `await obj.method(args)` — a non-generic async METHOD call.
    // The emitted symbol is `<ReceiverType>_<field>` (e.g. `PgConn_query`), so resolve the
    // receiver's static type here and ramp that mangled name directly. Set for the method
    // path only; free/module calls keep the ident/suffix-scan resolution below.
    var method_sym: ?[]const u8 = null;
    // When method_sym is set, the coroutine takes the receiver as its first parameter, so the
    // ramp must pass `self` as args[0] — captured here.
    var recv_expr: ?*const ast.Expression = null;
    switch (operand.kind) {
        .call => |c| {
            switch (c.callee.kind) {
                .ident => |n| callee_ident = n,
                .field_access => |fa| {
                    // Only a call whose receiver is a VARIABLE/expression of struct type is a
                    // method call; `module.fn(...)` (object names a module) is handled via the
                    // suffix-scan like the generic path. Resolve the receiver type to the
                    // struct, then form `<Base>_<field>` and check it is a registered async fn.
                    callee_ident = fa.field;
                    if (try self.resolveExpressionTypeName(fa.object)) |obj_ty_raw| {
                        // A1 async-first seam: `await traitObj.method(args)` — the receiver is
                        // TRAIT-typed, so dispatch is dynamic (no static `<Trait>_<field>` symbol).
                        // Emit the vtable indirect call; for an `async fn` trait method the slot
                        // holds the ramp, so it yields the coroutine handle — return it directly so
                        // the await machinery drives/suspends on it. Strip generic args (`Behavior<M>`
                        // -> `Behavior`) so a generic trait object dispatches too.
                        const obj_ty = getStructBaseName(obj_ty_raw);
                        if (self.traits.get(obj_ty)) |trait_decl| {
                            for (trait_decl.methods, 0..) |tm, idx| {
                                if (std.mem.eql(u8, tm.name, fa.field)) {
                                    if (!tm.is_async) return null;
                                    return try self.buildTraitVtableCall(fa, idx, c.args);
                                }
                            }
                            return null;
                        }
                        // MONO-FIRST (mirror the sync dispatch, llvm_codegen.zig ~1714): a receiver
                        // typed `ActorCell<i32>` must ramp the MONOMORPHIZED coroutine
                        // `ActorCell_i32_run`, NOT the erased `ActorCell_run`. getStructBaseName strips
                        // the `<i32>` — right for finding the trait/decl, wrong for the coroutine BODY.
                        // For a SYNC method the erased body links fine, so the sync path tolerates the
                        // erased fallback; an ASYNC method's erased ramp needs CoroSplit, and routing a
                        // concrete call to it (instead of the mono, which IS emitted+split) left
                        // `ActorCell_run.resume/.destroy` undefined at link. mangleTypeName turns
                        // `ActorCell<i32>` into the mono symbol prefix `ActorCell_i32`; try that first.
                        const mono_cand = blk: {
                            if (std.mem.indexOfScalar(u8, obj_ty_raw, '<') == null) break :blk null; // not an instantiation
                            const mangled = types_mod.mangleTypeName(self.allocator, obj_ty_raw) catch break :blk null;
                            defer self.allocator.free(mangled);
                            const mc = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mangled, fa.field }) catch break :blk null;
                            if (self.async_fns.contains(mc)) break :blk mc;
                            self.allocator.free(mc);
                            break :blk null;
                        };
                        const base = getStructBaseName(obj_ty);
                        const cand = mono_cand orelse try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ base, fa.field });
                        if (self.async_fns.contains(cand)) {
                            method_sym = cand;
                            recv_expr = fa.object;
                        } else {
                            self.allocator.free(cand);
                        }
                    }
                    if (fa.object.kind == .ident) obj_name = fa.object.kind.ident;
                },
                else => return null,
            }
            call_args = c.args;
        },
        .generic_call => |gc| {
            switch (gc.callee.kind) {
                .ident => |n| callee_ident = n,
                .field_access => |fa| {
                    callee_ident = fa.field;
                    if (fa.object.kind == .ident) obj_name = fa.object.kind.ident;
                },
                else => return null,
            }
            call_args = gc.args;
        },
        else => return null,
    }
    defer if (method_sym) |ms| self.allocator.free(ms);
    // F1-3b: resolve via the recorded SymbolId when it names a real emitted function (fail-safe
    // hasFunction guard; falls back to the scan otherwise), mirroring the main named-call path.
    const resolved = resolve: {
        // A1: an async method call resolves to its `<ReceiverType>_<field>` symbol directly.
        if (method_sym) |ms| break :resolve ms;
        if (operand.kind == .call) {
            if (self.typed_ir) |ir| {
                if (ir.symOf(&operand)) |sid| {
                    if (sema_shadow.live_sema) |sm| {
                        const legacy = sm.tab.symbolAt(sid).legacy_mangled;
                        if (self.hasFunction(legacy)) break :resolve legacy;
                    }
                }
            }
        }
        const base = try self.resolveCalleeName(callee_ident);
        if (self.async_fns.contains(base)) break :resolve base;
        // Module-qualified callee: the emitted symbol is `<module_prefix>_<field>` (e.g.
        // `concurrency_async_util_when_all`). Reconstruct `<obj>_<field>` and find the async
        // key that equals it OR ends in `_<obj>_<field>` — same suffix match as the main path.
        if (obj_name) |on| {
            const qual = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ on, callee_ident });
            defer self.allocator.free(qual);
            var it = self.async_fns.keyIterator();
            while (it.next()) |k| {
                const key = k.*;
                if (std.mem.eql(u8, key, qual)) break :resolve key;
                if (key.len > qual.len + 1 and key[key.len - qual.len - 1] == '_' and
                    std.mem.endsWith(u8, key, qual)) break :resolve key;
            }
        }
        break :resolve base;
    };
    if (!self.async_fns.contains(resolved)) return null;
    const fn_val = self.func_map.get(resolved) orelse return null;

    // A method coroutine takes the receiver as its first parameter, so prepend `self`.
    const recv_off: usize = if (recv_expr != null) 1 else 0;
    const args = try self.allocator.alloc(types.LLVMValueRef, call_args.len + recv_off);
    defer self.allocator.free(args);
    // A SPAWN reads its arguments ASYNCHRONOUSLY, after the spawning statement drains its
    // temporaries — so a trait object freshly WIDENED here (a fresh fat-pointer temp) would be
    // freed before the coroutine reads it → garbage vtable, method silently never runs. Collect
    // such widened args; below we retain each (survives the statement drain) and register it to be
    // released when the coroutine completes (nova_coro_hold_arg). An awaited call runs synchronously
    // within the await, so it needs none of this.
    var spawn_held = std.ArrayListUnmanaged(types.LLVMValueRef).empty;
    defer spawn_held.deinit(self.allocator);
    if (recv_expr) |re| args[0] = try self.compileCallArgument(re.*);
    for (call_args, 0..) |*arg, idx| {
        var val = try self.compileCallArgument(arg.*);
        // V1: value ↔ value-optional boundary on async-call args.
        val = try self.coerceValoptArg(val, arg, self.getFunctionParamTypeRef(resolved, idx + recv_off));
        // Trait widening — same as the synchronous call path. When the awaited coroutine's
        // parameter is a TRAIT and the argument is a concrete struct, coerce it to a fat
        // pointer here. Without this, `await f(concreteStruct)` for `f(x: SomeTrait)` passes a
        // raw struct pointer where the coroutine expects {struct_ptr, vtable} — and any trait
        // dispatch inside `f` then reads a garbage vtable (the method silently never runs). The
        // sync call path already does this; the async ramp path skipped it. `pidx` accounts for
        // the prepended receiver on a method coroutine.
        const pidx = idx + recv_off;
        if (self.getFunctionParamType(resolved, pidx)) |expected_type| {
            if (self.traits.contains(getStructBaseName(expected_type))) {
                if (try self.resolveExpressionTypeName(arg)) |struct_name| {
                    if (self.structs.contains(struct_name)) {
                        val = try self.constructTraitObject(val, struct_name, expected_type);
                        if (is_spawn) {
                            try self.compileRetain(val); // survive the spawning statement's drain
                            try spawn_held.append(self.allocator, val);
                        }
                    }
                }
            }
        }
        args[pidx] = val;
    }
    const handle = try self.buildCallWithCasts(fn_val, args); // ramp → handle
    // Register the retained trait args to be released when the coroutine completes — its
    // completion balances the retain above, so no leak and no early free (UAF).
    if (is_spawn and spawn_held.items.len > 0) {
        const hold_fn = self.func_map.get("nova_coro_hold_arg").?;
        const hold_t = core.LLVMGlobalGetValueType(hold_fn);
        const trait_dtor = try self.getOrCreateTraitDestructor();
        for (spawn_held.items) |held| {
            var h_args = [_]types.LLVMValueRef{ handle, held, trait_dtor };
            _ = core.LLVMBuildCall2(self.builder, hold_t, hold_fn, &h_args, 3, "");
        }
    }
    return handle;
}

// M3-C: lower `await inner()` inside an async fn. Register this coroutine as the
// awaited child's waiter, schedule the child, and SUSPEND self. On resume, read
// the child's result out of its promise and free it. Genuinely suspends — the
// remainder of the body compiles into the post-suspend `await.resume` block, so
// values live across the await are spilled into this coroutine's frame by CoroSplit.
// M3-D: emit a mid-body `llvm.coro.suspend` for the current async fn and leave the
// builder positioned in a fresh `await.resume` block (the resume path). The suspend
// default returns control to the resumer (this coroutine's `coro.ret`); case 1 is
// the cleanup/destroy path. Shared by child-await and timer-await.
pub fn buildAwaitSuspend(self: *LlvmCompiler) anyerror!void {
    const cur_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
    const resume_bb = core.LLVMAppendBasicBlock(cur_fn, "await.resume");
    const tok_ty = core.LLVMTokenTypeInContext(core.LLVMGetGlobalContext());
    const none_tok = core.LLVMConstNull(tok_ty);
    const suspend_fn = self.func_map.get("llvm.coro.suspend").?;
    const suspend_t = core.LLVMGlobalGetValueType(suspend_fn);
    var s_args = [_]types.LLVMValueRef{ none_tok, core.LLVMConstInt(self.i1_type, 0, 0) };
    const s = core.LLVMBuildCall2(self.builder, suspend_t, suspend_fn, &s_args, 2, "await.susp");
    const sw = core.LLVMBuildSwitch(self.builder, s, self.current_async_suspend_bb.?, 2);
    core.LLVMAddCase(sw, core.LLVMConstInt(self.i8_type, 0, 0), resume_bb);
    core.LLVMAddCase(sw, core.LLVMConstInt(self.i8_type, 1, 0), self.current_async_cleanup_bb.?);
    core.LLVMPositionBuilderAtEnd(self.builder, resume_bb);
}

// M3-D: if `operand` is a call to `sleep(ms)` (the concurrency sleep, as a bare
// ident or a `mod.sleep` field access), return the `ms` argument expression so the
// caller can lower it to a non-blocking timer await. Null otherwise.
pub fn awaitSleepMillis(self: *LlvmCompiler, operand: ast.Expression) ?ast.Expression {
    _ = self;
    if (operand.kind != .call) return null;
    const call = operand.kind.call;
    if (call.args.len != 1) return null;
    const is_sleep = switch (call.callee.kind) {
        .ident => |n| std.mem.eql(u8, n, "sleep"),
        .field_access => |fa| std.mem.eql(u8, fa.field, "sleep"),
        else => false,
    };
    if (!is_sleep) return null;
    return call.args[0];
}

// M3-D-6: detect `await chanRecv(ch)` (ident or `mod.chanRecv`) and return the
// channel argument so the caller can lower it to the async-channel receive loop.
pub fn awaitChanRecvArg(self: *LlvmCompiler, operand: ast.Expression) ?ast.Expression {
    _ = self;
    if (operand.kind != .call) return null;
    const call = operand.kind.call;
    if (call.args.len != 1) return null;
    const is_recv = switch (call.callee.kind) {
        .ident => |n| std.mem.eql(u8, n, "chanRecv"),
        .field_access => |fa| std.mem.eql(u8, fa.field, "chanRecv"),
        else => false,
    };
    if (!is_recv) return null;
    return call.args[0];
}

// M3-D-6: detect `await socketRecvAsync(fd,buf,max)` / `await socketAcceptAsync(fd)`
// (ident or `mod.fn`) — offloaded blocking socket I/O. Returns the call node.
pub fn awaitAsyncIoCall(self: *LlvmCompiler, operand: ast.Expression) ?ast.CallExpr {
    _ = self;
    if (operand.kind != .call) return null;
    const call = operand.kind.call;
    const name = switch (call.callee.kind) {
        .ident => |n| n,
        .field_access => |fa| fa.field,
        else => return null,
    };
    if ((std.mem.eql(u8, name, "socketRecvAsync") and call.args.len == 3) or
        (std.mem.eql(u8, name, "socketAcceptAsync") and call.args.len == 1) or
        (std.mem.eql(u8, name, "aaccept") and call.args.len == 1) or
        (std.mem.eql(u8, name, "aconnect") and call.args.len == 2) or
        (std.mem.eql(u8, name, "async_read") and call.args.len == 3) or
        (std.mem.eql(u8, name, "async_read_deadline") and call.args.len == 4) or
        (std.mem.eql(u8, name, "async_write") and call.args.len == 2))
    {
        return call;
    }
    return null;
}

// M3-D-6: lower an offloaded async socket op. The blocking call runs on a worker
// thread; this coroutine parks (buildAwaitSuspend) and, on resume, reads the result
// the worker stashed. Keeps the coroutine scheduler thread free during the I/O.
pub fn buildAsyncIo(self: *LlvmCompiler, call: ast.CallExpr) anyerror!types.LLVMValueRef {
    const self_hi = core.LLVMBuildPtrToInt(self.builder, self.current_async_hdl.?, self.val_type, "aio.selfh");
    const name = switch (call.callee.kind) {
        .ident => |n| n,
        .field_access => |fa| fa.field,
        else => unreachable,
    };
    if (std.mem.eql(u8, name, "async_read_deadline")) {
        // true-async recv WITH a deadline: (sock, buf, max, ms) + self → nova_arecv_deadline.
        const a0 = try self.compileExpression(call.args[0]);
        const a1 = try self.compileExpression(call.args[1]);
        const a2 = try self.compileExpression(call.args[2]);
        const a3 = try self.compileExpression(call.args[3]);
        const f = self.func_map.get("nova_arecv_deadline").?;
        const t = core.LLVMGlobalGetValueType(f);
        var a = [_]types.LLVMValueRef{ a0, a1, a2, a3, self_hi };
        _ = core.LLVMBuildCall2(self.builder, t, f, &a, 5, "");
    } else if (std.mem.eql(u8, name, "socketRecvAsync") or std.mem.eql(u8, name, "async_read")) {
        // offload recv (fd) OR true-async async_read (socket handle): same 3 args.
        const a0 = try self.compileExpression(call.args[0]);
        const a1 = try self.compileExpression(call.args[1]);
        const a2 = try self.compileExpression(call.args[2]);
        const fname = if (std.mem.eql(u8, name, "async_read")) "nova_arecv" else "nova_io_recv_async";
        const f = self.func_map.get(fname).?;
        const t = core.LLVMGlobalGetValueType(f);
        var a = [_]types.LLVMValueRef{ a0, a1, a2, self_hi };
        _ = core.LLVMBuildCall2(self.builder, t, f, &a, 4, "");
    } else if (std.mem.eql(u8, name, "async_write")) {
        const sock = try self.compileExpression(call.args[0]);
        const data = try self.compileExpression(call.args[1]);
        const f = self.func_map.get("nova_asend").?;
        const t = core.LLVMGlobalGetValueType(f);
        var a = [_]types.LLVMValueRef{ sock, data, self_hi };
        _ = core.LLVMBuildCall2(self.builder, t, f, &a, 3, "");
    } else if (std.mem.eql(u8, name, "aconnect")) {
        const host = try self.compileExpression(call.args[0]);
        const port = try self.compileExpression(call.args[1]);
        const f = self.func_map.get("nova_aconnect").?;
        const t = core.LLVMGlobalGetValueType(f);
        var a = [_]types.LLVMValueRef{ host, port, self_hi };
        _ = core.LLVMBuildCall2(self.builder, t, f, &a, 3, "");
    } else { // socketAcceptAsync (offload) OR aaccept (true async): 1 arg
        const s = try self.compileExpression(call.args[0]);
        const fname = if (std.mem.eql(u8, name, "aaccept")) "nova_aaccept" else "nova_io_accept_async";
        const f = self.func_map.get(fname).?;
        const t = core.LLVMGlobalGetValueType(f);
        var a = [_]types.LLVMValueRef{ s, self_hi };
        _ = core.LLVMBuildCall2(self.builder, t, f, &a, 2, "");
    }
    try self.buildAwaitSuspend(); // park; runtime reschedules when the worker finishes
    const take = self.func_map.get("nova_io_take_result").?;
    const take_t = core.LLVMGlobalGetValueType(take);
    var ta = [_]types.LLVMValueRef{self_hi};
    return core.LLVMBuildCall2(self.builder, take_t, take, &ta, 1, "aio.result");
}

// M3-D-6: lower `await chanRecv(ch)`. Loop: nova_chan_recv either yields a value (into
// an out slot, status 1) or parks this coroutine (status 0); on park we suspend, and
// the runtime reschedules us when a `chanSend` arrives, then we retry. The out slot is
// only written on the ready path (no suspend between write and read), so it needs no
// frame spill.
pub fn buildChanRecv(self: *LlvmCompiler, ch_expr: ast.Expression) anyerror!types.LLVMValueRef {
    const self_hdl = self.current_async_hdl.?;
    const self_hi = core.LLVMBuildPtrToInt(self.builder, self_hdl, self.val_type, "chan.selfh");
    const ch = try self.compileExpression(ch_expr);
    const out = core.LLVMBuildAlloca(self.builder, self.val_type, "chan.out");

    const cur_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
    const loop_bb = core.LLVMAppendBasicBlock(cur_fn, "chan.loop");
    const susp_bb = core.LLVMAppendBasicBlock(cur_fn, "chan.susp");
    const resume_bb = core.LLVMAppendBasicBlock(cur_fn, "chan.resume");
    const done_bb = core.LLVMAppendBasicBlock(cur_fn, "chan.done");
    _ = core.LLVMBuildBr(self.builder, loop_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
    const recv_fn = self.func_map.get("nova_chan_recv").?;
    const recv_t = core.LLVMGlobalGetValueType(recv_fn);
    var r_args = [_]types.LLVMValueRef{ ch, self_hi, out };
    const status = core.LLVMBuildCall2(self.builder, recv_t, recv_fn, &r_args, 3, "chan.status");
    const is_ready = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, status, core.LLVMConstInt(self.val_type, 0, 0), "chan.ready");
    _ = core.LLVMBuildCondBr(self.builder, is_ready, done_bb, susp_bb);

    // susp_bb: park — suspend; on resume, retry the loop.
    core.LLVMPositionBuilderAtEnd(self.builder, susp_bb);
    const tok_ty = core.LLVMTokenTypeInContext(core.LLVMGetGlobalContext());
    const none_tok = core.LLVMConstNull(tok_ty);
    const suspend_fn = self.func_map.get("llvm.coro.suspend").?;
    const suspend_t = core.LLVMGlobalGetValueType(suspend_fn);
    var s_args = [_]types.LLVMValueRef{ none_tok, core.LLVMConstInt(self.i1_type, 0, 0) };
    const s = core.LLVMBuildCall2(self.builder, suspend_t, suspend_fn, &s_args, 2, "chan.susp.tok");
    const sw = core.LLVMBuildSwitch(self.builder, s, self.current_async_suspend_bb.?, 2);
    core.LLVMAddCase(sw, core.LLVMConstInt(self.i8_type, 0, 0), resume_bb);
    core.LLVMAddCase(sw, core.LLVMConstInt(self.i8_type, 1, 0), self.current_async_cleanup_bb.?);
    core.LLVMPositionBuilderAtEnd(self.builder, resume_bb);
    _ = core.LLVMBuildBr(self.builder, loop_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
    return core.LLVMBuildLoad2(self.builder, self.val_type, out, "chan.val");
}

// `await whenAny(buf, n)` — select/when_any over `n` future handles at `buf`. Loop:
// nova_when_any returns the ready index (>=0, and disarms us) or -1 (parks us as the waiter on
// all; the first to complete reschedules us to poll again). Mirrors buildChanRecv, but the ready
// value IS the return (the index), so no out slot — `idx` in the loop block dominates the done
// block (the only edge into it), so it is valid there.
pub fn buildWhenAny(self: *LlvmCompiler, buf_expr: ast.Expression, n_expr: ast.Expression, ms_expr: ?ast.Expression) anyerror!types.LLVMValueRef {
    const self_hdl = self.current_async_hdl.?;
    const self_hi = core.LLVMBuildPtrToInt(self.builder, self_hdl, self.val_type, "wany.selfh");
    const buf = try self.compileExpression(buf_expr);
    const n = try self.compileExpression(n_expr);
    // Deadline variant (`await whenAnyDeadline(buf, n, ms)`) also races the futures against a
    // timer — the whole-query deadline `select(query, timer)`. `ms` is compiled BEFORE the loop
    // (it does not change across polls), then passed to nova_when_any_deadline each iteration.
    const ms: ?types.LLVMValueRef = if (ms_expr) |m| try self.compileExpression(m) else null;

    const cur_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
    const loop_bb = core.LLVMAppendBasicBlock(cur_fn, "wany.loop");
    const susp_bb = core.LLVMAppendBasicBlock(cur_fn, "wany.susp");
    const resume_bb = core.LLVMAppendBasicBlock(cur_fn, "wany.resume");
    const done_bb = core.LLVMAppendBasicBlock(cur_fn, "wany.done");
    _ = core.LLVMBuildBr(self.builder, loop_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
    const idx = if (ms) |ms_val| blk: {
        const f = self.func_map.get("nova_when_any_deadline").?;
        const t = core.LLVMGlobalGetValueType(f);
        var a = [_]types.LLVMValueRef{ buf, n, ms_val, self_hi };
        break :blk core.LLVMBuildCall2(self.builder, t, f, &a, 4, "wany.idx");
    } else blk: {
        const f = self.func_map.get("nova_when_any").?;
        const t = core.LLVMGlobalGetValueType(f);
        var a = [_]types.LLVMValueRef{ buf, n, self_hi };
        break :blk core.LLVMBuildCall2(self.builder, t, f, &a, 3, "wany.idx");
    };
    // ready when idx != -1 (a valid index >= 0).
    const neg1 = core.LLVMConstInt(self.val_type, @bitCast(@as(i64, -1)), 0);
    const is_ready = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, idx, neg1, "wany.ready");
    _ = core.LLVMBuildCondBr(self.builder, is_ready, done_bb, susp_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, susp_bb);
    const tok_ty = core.LLVMTokenTypeInContext(core.LLVMGetGlobalContext());
    const none_tok = core.LLVMConstNull(tok_ty);
    const suspend_fn = self.func_map.get("llvm.coro.suspend").?;
    const suspend_t = core.LLVMGlobalGetValueType(suspend_fn);
    var s_args = [_]types.LLVMValueRef{ none_tok, core.LLVMConstInt(self.i1_type, 0, 0) };
    const s = core.LLVMBuildCall2(self.builder, suspend_t, suspend_fn, &s_args, 2, "wany.susp.tok");
    const sw = core.LLVMBuildSwitch(self.builder, s, self.current_async_suspend_bb.?, 2);
    core.LLVMAddCase(sw, core.LLVMConstInt(self.i8_type, 0, 0), resume_bb);
    core.LLVMAddCase(sw, core.LLVMConstInt(self.i8_type, 1, 0), self.current_async_cleanup_bb.?);
    core.LLVMPositionBuilderAtEnd(self.builder, resume_bb);
    _ = core.LLVMBuildBr(self.builder, loop_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
    return idx;
}

// M3-D-4: `go asyncCall()` — launch the coroutine to run concurrently and return
// its Future handle (i64). Unlike `await`, this does NOT suspend the current
// coroutine; both proceed. The launched task is scheduled onto the event loop, so on
// a multi-thread pool it can run on another core.
pub fn buildGo(self: *LlvmCompiler, g: ast.AwaitExpr, is_detached: bool) anyerror!types.LLVMValueRef {
    // is_spawn=true: hold widened trait-object args alive until the spawned coroutine completes.
    const inner_hi = (try self.awaitedCallHandle(g.operand.*, true)) orelse {
        std.debug.print("'go' requires a direct async fn call (M3-D-4)\n", .{});
        return error.GoUnsupportedOperand;
    };
    const fname = if (is_detached) "nova_sched_schedule_detached" else "nova_sched_schedule";
    const sched_fn = self.func_map.get(fname).?;
    const sched_t = core.LLVMGlobalGetValueType(sched_fn);
    var sched_args = [_]types.LLVMValueRef{inner_hi};
    _ = core.LLVMBuildCall2(self.builder, sched_t, sched_fn, &sched_args, 1, "");
    return inner_hi; // the Future handle
}

// M3-D-4: `await <future>` where the future is a handle from `go`. The task is
// already running (possibly done). `nova_await_future` atomically returns ready (1)
// or registers this coroutine as the waiter (0). If not ready we suspend; the
// runtime wakes us when the task completes. Then read the result and free the frame.
pub fn buildAwaitFuture(self: *LlvmCompiler, fut_hi: types.LLVMValueRef) anyerror!types.LLVMValueRef {
    const self_hdl = self.current_async_hdl.?;
    const self_hi = core.LLVMBuildPtrToInt(self.builder, self_hdl, self.val_type, "awaitf.selfh");
    const fut_h = core.LLVMBuildIntToPtr(self.builder, fut_hi, self.ptr_type, "awaitf.h");

    const fut_fn = self.func_map.get("nova_await_future").?;
    const fut_t = core.LLVMGlobalGetValueType(fut_fn);
    var f_args = [_]types.LLVMValueRef{ fut_hi, self_hi };
    const ready = core.LLVMBuildCall2(self.builder, fut_t, fut_fn, &f_args, 2, "awaitf.ready");

    const cur_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
    const susp_bb = core.LLVMAppendBasicBlock(cur_fn, "awaitf.susp");
    const read_bb = core.LLVMAppendBasicBlock(cur_fn, "awaitf.read");
    const is_ready = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, ready, core.LLVMConstInt(self.val_type, 0, 0), "awaitf.isready");
    _ = core.LLVMBuildCondBr(self.builder, is_ready, read_bb, susp_bb);

    // susp_bb: suspend; on resume, branch to read_bb.
    core.LLVMPositionBuilderAtEnd(self.builder, susp_bb);
    const resume_bb = core.LLVMAppendBasicBlock(cur_fn, "awaitf.resume");
    const tok_ty = core.LLVMTokenTypeInContext(core.LLVMGetGlobalContext());
    const none_tok = core.LLVMConstNull(tok_ty);
    const suspend_fn = self.func_map.get("llvm.coro.suspend").?;
    const suspend_t = core.LLVMGlobalGetValueType(suspend_fn);
    var s_args = [_]types.LLVMValueRef{ none_tok, core.LLVMConstInt(self.i1_type, 0, 0) };
    const s = core.LLVMBuildCall2(self.builder, suspend_t, suspend_fn, &s_args, 2, "awaitf.susp.tok");
    const sw = core.LLVMBuildSwitch(self.builder, s, self.current_async_suspend_bb.?, 2);
    core.LLVMAddCase(sw, core.LLVMConstInt(self.i8_type, 0, 0), resume_bb);
    core.LLVMAddCase(sw, core.LLVMConstInt(self.i8_type, 1, 0), self.current_async_cleanup_bb.?);
    core.LLVMPositionBuilderAtEnd(self.builder, resume_bb);
    _ = core.LLVMBuildBr(self.builder, read_bb);

    // read_bb: task complete — read its result, destroy its frame.
    core.LLVMPositionBuilderAtEnd(self.builder, read_bb);
    const prom = self.buildCoroPromisePtr(fut_h);
    const rslot = self.coroPromiseResultSlot(prom);
    const result = core.LLVMBuildLoad2(self.builder, self.val_type, rslot, "awaitf.result");
    // MUST be the serialised release, not llvm.coro.destroy. On the ready path
    // (nova_await_future returned 1 because the task already finished) the task's
    // scheduler lambda may still be reading the frame; a bare destroy frees it
    // underneath the scheduler. Two threads, one frame -- clean under
    // NOVA_THREADS=1, invisible to ASAN.
    const destroy_fn = self.func_map.get("nova_coro_release").?;
    const destroy_t = core.LLVMGlobalGetValueType(destroy_fn);
    var d_args = [_]types.LLVMValueRef{fut_hi};
    _ = core.LLVMBuildCall2(self.builder, destroy_t, destroy_fn, &d_args, 1, "");
    return result;
}

pub fn buildAwait(self: *LlvmCompiler, aw: ast.AwaitExpr) anyerror!types.LLVMValueRef {
    const self_hdl = self.current_async_hdl orelse {
        // Coloring should prevent this; guard anyway.
        std.debug.print("'await' used outside an async fn reached codegen\n", .{});
        return error.AwaitOutsideAsync;
    };

    // M3-D: `await sleep(ms)` is a non-blocking timer await — arm a steady_timer
    // and suspend this coroutine; the event loop resumes it when the timer fires
    // (the thread runs other coroutines meanwhile). Distinct from the blocking
    // sync `sleep(ms)`.
    if (self.awaitSleepMillis(aw.operand.*)) |ms_expr| {
        const ms_val = try self.compileExpression(ms_expr);
        const self_hi = core.LLVMBuildPtrToInt(self.builder, self_hdl, self.val_type, "await.selfh");
        const timer_fn = self.func_map.get("nova_await_timer").?;
        const timer_t = core.LLVMGlobalGetValueType(timer_fn);
        var t_args = [_]types.LLVMValueRef{ self_hi, ms_val };
        _ = core.LLVMBuildCall2(self.builder, timer_t, timer_fn, &t_args, 2, "");
        try self.buildAwaitSuspend();
        return core.LLVMConstInt(self.val_type, 0, 0); // await sleep → void/0
    }

    // M3-D-6: `await chanRecv(ch)` — receive from an async channel (parks until sent).
    if (self.awaitChanRecvArg(aw.operand.*)) |ch_expr| {
        return try self.buildChanRecv(ch_expr);
    }

    // select/when_any: `await whenAny(buf, n)` — first-ready index over `n` future handles;
    // `await whenAnyDeadline(buf, n, ms)` — the same, but also races them against an `ms` timer.
    if (aw.operand.kind == .call) {
        const c = aw.operand.kind.call;
        const nm: ?[]const u8 = switch (c.callee.kind) {
            .field_access => |fa| fa.field,
            .ident => |id| id,
            else => null,
        };
        if (nm) |name| {
            if (std.mem.eql(u8, name, "whenAny") and c.args.len == 2) {
                return try self.buildWhenAny(c.args[0], c.args[1], null);
            }
            if (std.mem.eql(u8, name, "whenAnyDeadline") and c.args.len == 3) {
                return try self.buildWhenAny(c.args[0], c.args[1], c.args[2]);
            }
        }
    }

    // M3-D-6: `await socketRecvAsync(...)` / `socketAcceptAsync(...)` — offloaded I/O.
    if (self.awaitAsyncIoCall(aw.operand.*)) |io_call| {
        return try self.buildAsyncIo(io_call);
    }

    // M3-D-4: if the operand isn't a direct async call, it's a Future handle from a
    // `go` launch (a value) — await it via the runtime future path (check-or-register).
    const inner_hi = (try self.awaitedCallHandle(aw.operand.*, false)) orelse {
        const fut_hi = try self.compileExpression(aw.operand.*);
        return try self.buildAwaitFuture(fut_hi);
    };
    const inner_h = core.LLVMBuildIntToPtr(self.builder, inner_hi, self.ptr_type, "await.child");

    // M3-D-3: register self as the child's waiter in the RUNTIME (before scheduling
    // the child), so the runtime wakes us after the child's resume returns — race-
    // free under multi-threaded execution (vs. the child scheduling us mid-epilogue).
    const self_hi = core.LLVMBuildPtrToInt(self.builder, self_hdl, self.val_type, "await.selfh");
    const reg_fn = self.func_map.get("nova_register_waiter").?;
    const reg_t = core.LLVMGlobalGetValueType(reg_fn);
    var reg_args = [_]types.LLVMValueRef{ inner_hi, self_hi };
    _ = core.LLVMBuildCall2(self.builder, reg_t, reg_fn, &reg_args, 2, "");

    // Schedule the child, then suspend self.
    const sched_fn = self.func_map.get("nova_sched_schedule").?;
    const sched_t = core.LLVMGlobalGetValueType(sched_fn);
    var sched_args = [_]types.LLVMValueRef{inner_hi};
    _ = core.LLVMBuildCall2(self.builder, sched_t, sched_fn, &sched_args, 1, "");

    try self.buildAwaitSuspend();

    // Resumed: the child has completed. Read its result and destroy its frame.
    const child_prom2 = self.buildCoroPromisePtr(inner_h);
    const child_rslot = self.coroPromiseResultSlot(child_prom2);
    const result = core.LLVMBuildLoad2(self.builder, self.val_type, child_rslot, "await.result");
    // Serialised release, same reason as buildAwaitFuture: the awaiter must not
    // free a frame the scheduler may still be reading.
    const destroy_fn = self.func_map.get("nova_coro_release").?;
    const destroy_t = core.LLVMGlobalGetValueType(destroy_fn);
    var d_args = [_]types.LLVMValueRef{inner_hi};
    _ = core.LLVMBuildCall2(self.builder, destroy_t, destroy_fn, &d_args, 1, "");
    return result;
}

/// §3.4j inc4: the per-lambda function that releases a closure env's REF-COUNTED
/// capture slots. Returns its address as an i64, or a 0 constant if this lambda
/// captured nothing ref-counted (the common case — most captures are ints).
///
/// `__destruct_closure` (generic, looked up by the closure's function TYPE) cannot know
/// which env slots are ref-counted — that is per-lambda. So the box carries this
/// function's pointer and the destructor calls it before freeing the env. The types
/// come from `current_local_types` at the CREATION site, where the captured variables
/// are in scope.
fn buildClosureCleanup(self: *LlvmCompiler, lambda_name: []const u8, span: ast.Span) anyerror!types.LLVMValueRef {
    const zero = core.LLVMConstInt(self.val_type, 0, 0);
    const caps = self.lambda_captures.get(lambda_name) orelse return zero;
    if (caps.items.len == 0) return zero;

    const name = try std.fmt.allocPrintSentinel(self.allocator, "__clocleanup_{s}", .{lambda_name}, 0);
    defer self.allocator.free(name);
    if (core.LLVMGetNamedFunction(self.module, name.ptr)) |existing| {
        return core.LLVMBuildPtrToInt(self.builder, existing, self.val_type, "cleanup_ptr");
    }

    // Which slots are ref-counted, and their types (for the right destructor).
    const es = self.valSlotSize();
    var slots = std.ArrayListUnmanaged(struct { i: usize, ty: []const u8 }).empty;
    defer slots.deinit(self.allocator);
    if (self.current_local_types) |lt| {
        for (caps.items, 0..) |cap, i| {
            if (lt.get(cap)) |ct| {
                if (self.isOwnedLocal(cap, ct)) try slots.append(self.allocator, .{ .i = i, .ty = ct });
            }
        }
    }
    if (slots.items.len == 0) return zero;
    _ = span;

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const clean_fn = core.LLVMAddFunction(self.module, name.ptr, fn_type);
    core.LLVMSetLinkage(clean_fn, .LLVMInternalLinkage);
    const entry_bb = core.LLVMAppendBasicBlock(clean_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);

    const env = core.LLVMGetParam(clean_fn, 0);
    for (slots.items) |s| {
        const off = core.LLVMConstInt(self.val_type, s.i * es, 0);
        const addr = core.LLVMBuildAdd(self.builder, env, off, "clo_cap_addr");
        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "clo_cap_ptr");
        const val = core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "clo_cap");
        const dest = self.getOrCreateDestructor(s.ty) catch null;
        try self.compileRelease(val, dest);
    }
    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);

    return core.LLVMBuildPtrToInt(self.builder, clean_fn, self.val_type, "cleanup_ptr");
}

/// F5 §3.4b — the temporary rule: an owned temporary dies at the end of the full
/// statement.
///
/// This wrapper is where a temporary is BORN. It registers the `+1`; `compileStatement`
/// drains the list at the statement's end, and a `let`/assign that binds the value
/// takes it off the list first (the binding is now its owner). What is left over is
/// exactly what nothing named — which is the leak.
///
/// The acquisition DECISION (owned vs borrowed) lives in `arc.acquisitionDisposition`
/// (the RAII "constructor" half). This choke point only ACTS on it: `.owned` → spill the
/// `+1` and register it for the statement drain; `.borrowed` → nothing. The rendered type
/// name is still resolved here for the drain's destructor lookup, and an unresolvable name
/// falls back to no-registration (behavior-identical to when the decision lived inline).
/// The no-init default constructor `S()` zero-fills, so a heap CONTAINER field (`List<T>`) lands as a
/// NULL handle and `S().field.push(..)` derefs null. Nova structs have no field defaults, so initialize
/// each List field to an empty container — the "zero value" of a container is empty, not null. (Map/Set
/// take constructor args — capacity, a hash fn — so they can't be defaulted this way; a struct using them
/// must supply its own `init`.) Called only on the NO-`init` constructor path; an explicit init owns field
/// setup. ARC: the fresh `List<T>()` temp is CONSUMED into the field (same O4 rule as struct_init), so the
/// field holds the sole reference and the end-of-statement drain doesn't free it underneath.
pub fn initDefaultContainerFields(self: *LlvmCompiler, struct_name: []const u8, instance_ptr: types.LLVMValueRef, span: ast.Span) anyerror!void {
    const sd = self.structs.get(struct_name) orelse return;
    for (sd.fields) |f| {
        const params = switch (f.type_name) {
            .generic => |g| if (std.mem.eql(u8, g.name, "List")) g.params else continue,
            else => continue,
        };
        var callee_expr = ast.Expression{ .kind = .{ .ident = "List" } };
        const list_ctor = ast.Expression{ .kind = .{ .generic_call = .{
            .callee = &callee_expr,
            .type_args = params,
            .args = &[_]ast.Expression{},
            .span = span,
        } } };
        const fv = try self.compileExpression(list_ctor);
        try self.takeOwnedElement(list_ctor.kind, fv);
        const offset = try self.getFieldOffset(struct_name, f.name);
        const offset_val = core.LLVMConstInt(self.val_type, offset, 0);
        const addr = core.LLVMBuildAdd(self.builder, instance_ptr, offset_val, "cf_addr");
        const llvm_ft = self.toLLVMType(f.type_name);
        const fptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(llvm_ft, 0), "cf_ptr");
        _ = core.LLVMBuildStore(self.builder, self.castFromValType(fv, llvm_ft), fptr);
    }
}

pub fn compileExpression(self: *LlvmCompiler, expr: ast.Expression) anyerror!types.LLVMValueRef {
    const val = try compileExpressionInner(self, expr);
    switch (self.acquisitionDisposition(&expr)) {
        .borrowed => return val,
        .owned => {},
    }
    const t = (try self.resolveExpressionTypeName(&expr)) orelse return val;
    const slot = try spillTemp(self, val);
    try self.pending_temps.append(self.allocator, .{ .val = val, .slot = slot, .type_name = t, .expr_id = expr.id });
    return val;
}

/// Park a temporary in a stack SLOT so the statement's drain can release it from a
/// different basic block than the one that produced it.
///
/// A temporary can be born inside a branch — `a ?? f()`, `cond ? f() : g()` — and the
/// drain runs at the statement's end, in the merge block. Releasing the SSA value
/// directly there is not merely wrong, it does not verify:
/// `Instruction does not dominate all uses` (13_serde). The value only exists on one
/// path; the slot exists on all of them.
///
/// Zeroed in the ENTRY block, so a branch that never ran leaves the slot 0 — and
/// `nova_release(0)` is already a no-op. The drain re-zeroes after releasing, which is
/// what makes this safe in a LOOP: without it, the next iteration would find the
/// previous iteration's freed pointer and release it a second time.
fn spillTemp(self: *LlvmCompiler, val: types.LLVMValueRef) anyerror!types.LLVMValueRef {
    const cur_bb = core.LLVMGetInsertBlock(self.builder);
    const fn_val = core.LLVMGetBasicBlockParent(cur_bb);
    const entry_bb = core.LLVMGetEntryBasicBlock(fn_val);
    if (core.LLVMGetFirstInstruction(entry_bb)) |first| {
        core.LLVMPositionBuilderBefore(self.builder, first);
    } else {
        core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
    }
    const slot = core.LLVMBuildAlloca(self.builder, self.val_type, "tmp_slot");
    _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.val_type, 0, 0), slot);
    core.LLVMPositionBuilderAtEnd(self.builder, cur_bb);
    _ = core.LLVMBuildStore(self.builder, val, slot);
    return slot;
}

/// Register a `+1` that was NOT produced through `compileExpression` — so the
/// statement's drain releases it like any other temporary.
///
/// The wrapper above only sees expressions. Codegen that builds an object with
/// `compileAlloc`/`LLVMBuildCall2` directly is invisible to it, and every leak left in
/// the corpus has been exactly that: the interpolation intermediates (§3.4c), the
/// erased closures (§3.4d), and the trait object (§3.4f). A rule only covers the paths
/// that go through its choke point; this is the door for the ones that do not.
/// The honest byte-width and LLVM type of an `Atomic<T>` cell, from the CANONICAL primitive
/// table — never from string equality on a spelling.
///
/// There were THREE copies of `is_i64 = t_name == "i64" or "u64" or "double"` at the three
/// Atomic construction sites, plus a FOURTH in `compileAtomicCall` (llvm_codegen.zig) fed by a
/// DIFFERENT rendering of the same type. `Atomic<long>` is spelled "long" by `typeRefToString`
/// (the AST) and "i64" by sema's renderer — so the allocation sites sized a 4-byte cell while
/// dispatch emitted 8-byte `nova_atomic_*_i64` calls. Every `Atomic<long>` load/store ran 4 bytes
/// past a 12-byte block (8-byte ARC header + 4 payload) into the adjacent heap object, and
/// `test_atomic_i64` PASSED the whole time — the overflow was silent and the value survived.
/// ASAN found it on the first run of `run.sh --asan`.
///
/// Four string tests for one question is four chances to disagree; this is one lookup.
pub fn atomicCell(self: *LlvmCompiler, t_name: []const u8) struct { bits: u32, is_i64: bool, size: usize, ty: types.LLVMTypeRef } {
    const bits: u32 = if (types_mod.cgPrim(t_name)) |pr| types_mod.reprBitWidth(pr.repr) else 32;
    const is_i64 = bits == 64;
    const llvm_ty = if (is_i64) self.i64_type else if (bits == 1) self.i1_type else self.i32_type;
    return .{ .bits = bits, .is_i64 = is_i64, .size = @max(1, bits / 8), .ty = llvm_ty };
}

/// specs §3.4 / P2-14: guard a member deref whose object is an optional.
///
/// `handle` is the object's i64 value; if the object expression is `T | undefined` and the value
/// is `undefined` (handle 0), reading a field/method reads through address 0 and SEGVs with no
/// explanation. This inserts `if (handle == 0) nova_optional_deref_fail("file:line");` before the
/// deref — an honest, located abort instead of UB. A no-op when the object is not optional, so it
/// costs nothing on ordinary struct access.
///
/// The decision (P2-14): keep the see-through ergonomics (`xs.get(i).field` resolves), make the
/// absent case a runtime trap rather than a compile error. Enforcing at compile time is the
/// eventual soundness win but needs flow-narrowing (§3.4a) to not be painful; until then this is
/// memory-safe and breaks nothing.
pub fn guardOptionalDeref(self: *LlvmCompiler, obj_expr: *const ast.Expression, handle: types.LLVMValueRef, span: ast.Span) anyerror!void {
    if (!self.isOptionalExpr(obj_expr)) return;
    const cur_bb = core.LLVMGetInsertBlock(self.builder);
    const cur_fn = core.LLVMGetBasicBlockParent(cur_bb);
    const is_null = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, handle, core.LLVMConstInt(self.val_type, 0, 0), "opt_is_null");
    const fail_bb = core.LLVMAppendBasicBlock(cur_fn, "opt_deref_fail");
    const ok_bb = core.LLVMAppendBasicBlock(cur_fn, "opt_deref_ok");
    _ = core.LLVMBuildCondBr(self.builder, is_null, fail_bb, ok_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, fail_bb);
    const loc_raw = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ span.file, span.line });
    defer self.allocator.free(loc_raw);
    const loc = try self.allocator.dupeZ(u8, loc_raw);
    defer self.allocator.free(loc);
    const loc_str = core.LLVMBuildGlobalString(self.builder, loc.ptr, "opt_loc");
    const loc_ptr = core.LLVMBuildBitCast(self.builder, loc_str, self.ptr_type, "opt_loc_ptr");
    const fail_fn = self.func_map.get("nova_optional_deref_fail").?;
    const fail_t = core.LLVMGlobalGetValueType(fail_fn);
    var args = [_]types.LLVMValueRef{loc_ptr};
    _ = core.LLVMBuildCall2(self.builder, fail_t, fail_fn, &args, 1, "");
    _ = core.LLVMBuildUnreachable(self.builder);

    core.LLVMPositionBuilderAtEnd(self.builder, ok_bb);
}

/// F2-6 stage 5 step 5 (shadow): codegen just performed `cg` (a drop at drain, or a move at consume)
/// on the temp born at `id`. Compare against the ownership pass's recorded op. A temp the pass never
/// saw (`.unassigned` id, or explicitly-registered) has no op — counted as `no_op`, not a disagreement.
fn diffTempOp(self: *LlvmCompiler, id: ast.ExprId, cg: sema_infer.OwnOp) void {
    const ir = self.typed_ir orelse return;
    const pass_op = ir.opOf(id) orelse {
        sema_shadow.op_no_op += 1;
        return;
    };
    if (pass_op == cg) {
        sema_shadow.op_agree += 1;
    } else {
        sema_shadow.op_disagree += 1;
        switch (cg) {
            .drop => sema_shadow.op_disagree_cg_drop += 1, // codegen dropped; pass said move
            .move => sema_shadow.op_disagree_cg_move += 1, // codegen moved; pass said drop
        }
        // Characterize the residue by the type the pass assigned (the disagreements cluster by type:
        // cg=move/pass=drop on `optional`; cg=drop/pass=move on `tuple`/`error_union`/`struct_` — the
        // return/aggregate positions where codegen copies-then-drops rather than moves). Kept as the
        // last-sample so the report can name the class without a full histogram.
        if (self.typed_ir) |tir| {
            if (self.type_store) |s| {
                if (tir.typeOf2(id)) |tid| sema_shadow.op_last_disagree = @tagName(s.get(tid));
            }
        }
    }
}

pub fn registerTemporary(self: *LlvmCompiler, val: types.LLVMValueRef, type_name: []const u8) anyerror!void {
    const slot = try spillTemp(self, val);
    try self.pending_temps.append(self.allocator, .{ .val = val, .slot = slot, .type_name = type_name });
}

/// Take `val` off the pending list — something now OWNS it, so the statement's drain
/// must not release it. Called by `let x = e` and by assignment.
pub fn consumeTemporary(self: *LlvmCompiler, val: types.LLVMValueRef) void {
    var i = self.pending_temps.items.len;
    while (i > 0) {
        i -= 1;
        if (self.pending_temps.items[i].val == val) {
            // stage 5 step 5: codegen is MOVING this temp (a bind consumed it). Diff vs the pass's op.
            if (sema_shadow.report_enabled) diffTempOp(self, self.pending_temps.items[i].expr_id, .move);
            _ = self.pending_temps.orderedRemove(i);
            return;
        }
    }
}

/// Release every temporary produced since `mark`, then truncate to it.
///
/// `mark`, not "clear": statements nest (a `while` body's statements run inside the
/// `while` statement), and clearing would release an enclosing statement's temporaries
/// early — a use-after-free rather than a leak.
/// F2-6 stage 4 (shadow): does the temp's TypeId (recovered via `expr_id`) render to the SAME string
/// the drain currently keys its destructor on (`t.type_name`, captured at registration)? Proving this
/// agrees corpus-wide is the precondition for deriving the destructor from the TypeId and dropping the
/// stored string — a divergent destructor NAME is corruption, so it must be proven, not assumed.
fn diffDtorName(self: *LlvmCompiler, t: @import("llvm_codegen.zig").PendingTemp) void {
    if (t.expr_id == .unassigned) {
        sema_shadow.dtor_name_no_id += 1;
        return;
    }
    const ir = self.typed_ir orelse {
        sema_shadow.dtor_name_no_id += 1;
        return;
    };
    const st = self.type_store orelse {
        sema_shadow.dtor_name_no_id += 1;
        return;
    };
    // The CONCRETE TypeId (mono-aware), exactly as resolveExpressionTypeName's typeOfExprConcrete does.
    var tid: ?sema_types.TypeId = null;
    if (self.current_instantiation_id) |inst| tid = ir.typeOfInst(t.expr_id, inst);
    if (tid == null) tid = ir.typeOf2(t.expr_id);
    const t_id = tid orelse {
        sema_shadow.dtor_name_no_id += 1;
        return;
    };
    const rendered = sema_shadow.renderLegacy(self.allocator, st, t_id) catch {
        sema_shadow.dtor_name_no_id += 1;
        return;
    };
    const typed_name = self.substTypeParams(rendered) catch {
        sema_shadow.dtor_name_no_id += 1;
        return;
    };
    if (std.mem.eql(u8, typed_name, t.type_name)) {
        sema_shadow.dtor_name_agree += 1;
    } else {
        sema_shadow.dtor_name_disagree += 1;
        sema_shadow.dtor_name_last_disagree_string = t.type_name;
        sema_shadow.dtor_name_last_disagree_typed = typed_name;
    }
    // Does the RAW render (no substTypeParams) already match? If so corpus-wide, the concrete TypeId
    // (T resolved by the instantiation) needs NO string-level substitution at the drain — so
    // substTypeParams is redundant HERE and this drain can key on the TypeId directly.
    if (std.mem.eql(u8, rendered, t.type_name)) {
        sema_shadow.dtor_name_raw_agree += 1;
    } else {
        sema_shadow.dtor_name_raw_disagree += 1;
        sema_shadow.dtor_name_raw_last = rendered;
    }
}

/// F2-6 stage 4 (CUTOVER): the temp's destructor, DISPATCHED on its concrete TypeId (native for
/// trait/func/prim/ptr; delegating aggregates to the string path until each builder is TypeId-keyed).
/// Proven to resolve to the same LLVM function as the string path corpus-wide (agree=4302, DISAGREE=0).
/// Falls back to the stored string for the synthesized no-id temps (no `expr_id`).
fn drainDtor(self: *LlvmCompiler, t: @import("llvm_codegen.zig").PendingTemp) anyerror!?types.LLVMValueRef {
    if (t.expr_id != .unassigned) {
        if (self.typed_ir) |ir| {
            var tid: ?sema_types.TypeId = null;
            if (self.current_instantiation_id) |inst| tid = ir.typeOfInst(t.expr_id, inst);
            if (tid == null) tid = ir.typeOf2(t.expr_id);
            if (tid) |t_id| return self.getOrCreateDestructorByTypeId(t_id);
        }
    }
    return self.getOrCreateDestructor(t.type_name);
}

pub fn drainTemporaries(self: *LlvmCompiler, mark: usize) anyerror!void {
    if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) != null) {
        // The statement ended in `return`/`break`: the block is closed and nothing more
        // can be appended to it. The return path does its own releasing.
        self.pending_temps.shrinkRetainingCapacity(@min(mark, self.pending_temps.items.len));
        return;
    }
    while (self.pending_temps.items.len > mark) {
        const t = self.pending_temps.pop().?;
        // stage 5 step 5: codegen is DROPPING this temp at statement end. Diff vs the pass's op.
        if (sema_shadow.report_enabled) diffTempOp(self, t.expr_id, .drop);
        // stage 4: prove the destructor NAME is recoverable from the temp's TypeId (precondition for
        // keying the destructor on the TypeId and dropping the stored `type_name` string).
        if (sema_shadow.report_enabled) diffDtorName(self, t);
        // stage 4 CUTOVER: the destructor is DISPATCHED on the temp's concrete TypeId (store kind),
        // proven to resolve to the same function as the string path; the string survives only for
        // synthesized no-id temps. The name-diff below is the regression guard on the render path.
        const dest = drainDtor(self, t) catch null;
        // Load from the SLOT, not the SSA value: the producer may be in a branch this
        // block is not dominated by. A slot the branch never wrote reads 0, and
        // `nova_release(0)` is a no-op.
        const loaded = core.LLVMBuildLoad2(self.builder, self.val_type, t.slot, "tmp_rel");
        try self.compileRelease(loaded, dest);
        // Re-zero, or the next loop iteration releases this same freed pointer again.
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.val_type, 0, 0), t.slot);
    }
}

fn compileExpressionInner(self: *LlvmCompiler, expr: ast.Expression) anyerror!types.LLVMValueRef {
    switch (expr.kind) {
        .literal => |lit| {
            switch (lit) {
                .integer => |val| {
                    return core.LLVMConstInt(self.val_type, @intCast(val), 0);
                },
                .bool => |b| {
                    const val: u64 = if (b) 1 else 0;
                    return core.LLVMConstInt(self.val_type, val, 0);
                },
                .null, .undefined => {
                    return core.LLVMConstInt(self.val_type, 0, 0);
                },
                .string => |str| {
                    return try self.getOrCreateStringLiteral(str);
                },
                .array => |arr| {
                    const element_size: usize = 8;
                    const size_val = core.LLVMConstInt(self.val_type, arr.len * element_size, 0);

                    // Allocate array on heap
                    const array_ptr_val = try self.compileAlloc(size_val);

                    // Initialize array elements
                    for (arr, 0..) |elem, idx| {
                        const offset = core.LLVMConstInt(self.val_type, idx * element_size, 0);
                        const val = try self.compileExpression(elem);
                        const addr = core.LLVMBuildAdd(self.builder, array_ptr_val, offset, "array_elem_addr");
                        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "array_elem_ptr");
                        _ = core.LLVMBuildStore(self.builder, val, ptr);
                    }

                    return array_ptr_val;
                },
                .float => |val| {
                    // A7 / F3 §5 stage 4: a float literal IS a real `double`. It reaches
                    // the i64 ABI (a call arg, a collection slot, a return) through the
                    // boundary coercions (castFromValType/coerceToSlotType); it stays
                    // `double` when it flows straight into float arithmetic or a float slot.
                    return core.LLVMConstReal(core.LLVMDoubleType(), val);
                },
                .decimal => |digits| {
                    // specs §3.1: a `decimal` literal — hand the EXACT digit string to the runtime's
                    // decimal128 (BID) parser, which returns a fresh 16-byte heap decimal (a val_type
                    // pointer). No f64 round-trip: `0.1m` must be exact.
                    const cstr = try self.allocator.dupeZ(u8, digits);
                    defer self.allocator.free(cstr);
                    const str_global = core.LLVMBuildGlobalString(self.builder, cstr.ptr, "dec_lit");
                    const str_ptr = core.LLVMBuildBitCast(self.builder, str_global, self.ptr_type, "dec_lit_ptr");
                    const from_fn = self.func_map.get("nova_decimal_from_string").?;
                    const from_t = core.LLVMGlobalGetValueType(from_fn);
                    var args = [_]types.LLVMValueRef{str_ptr};
                    return core.LLVMBuildCall2(self.builder, from_t, from_fn, &args, 1, "dec_from_str");
                },
                else => {
                    std.debug.print("Literal type not supported yet: {s}\n", .{@tagName(lit)});
                    return error.UnsupportedLiteral;
                },
            }
        },
        .ident => |name| {
            // A1: read a captured variable from the closure's heap environment.
            if (self.envCaptureIndex(name)) |idx| {
                const addr = try self.envSlotAddr(idx);
                const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "env_ptr_load");
                return core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "env_capture_load");
            }
            var curr_fn = self.current_function_name;
            while (curr_fn) |fn_name| {
                const key = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ fn_name, name });
                defer self.allocator.free(key);
                if (self.captured_globals.get(key)) |global_var| {
                    return core.LLVMBuildLoad2(self.builder, self.val_type, global_var, "captured_load");
                }
                curr_fn = self.lambda_parents.get(fn_name);
            }
            if (self.locals.get(name)) |alloca_val| {
                // A7 / F3 §5 stage 4: load the slot's HONEST type. A float local is an
                // `alloca double`, so this yields a real `double` that flows straight
                // into float arithmetic — no bitcast sandwich. Captured/global-backed
                // "locals" are not alloca instructions; those stay val_type (i64).
                const slot_ty = if (core.LLVMIsAAllocaInst(alloca_val) != null)
                    core.LLVMGetAllocatedType(alloca_val)
                else
                    self.val_type;
                const loaded = core.LLVMBuildLoad2(self.builder, slot_ty, alloca_val, "");
                // V1 value-optional boxing (CONSUME — narrowed read): the SLOT holds a boxed value
                // optional (`int?`), but if the checker narrowed THIS use to the bare inner value
                // (`if (x != undefined) { … x … }` rebinds `x` to `int`, infer.zig:2037), the use type
                // is a `.prim` while the slot is `.optional(.prim)`. That desync IS the T?→T transition:
                // unbox. Every other read of a value-optional local (null-check `x != undefined`, `??`
                // left, a copy into another `int?`) keeps the use typed `.optional`, so it is NOT
                // unboxed here and stays a box. This one rule covers narrowing, narrowed arithmetic
                // (`x + 1`), and narrowed arg-passing — H2 forbids UNguarded value use of an optional.
                if (self.current_local_type_ids) |ids| {
                    if (ids.get(name)) |slot_tid| {
                        if (self.type_store) |st| {
                            if (self.valueOptionalInner(slot_tid) != null) {
                                const use_is_bare_prim = if (self.typeOfExprConcrete(&expr)) |ut|
                                    st.get(ut) == .prim
                                else
                                    false;
                                if (use_is_bare_prim) {
                                    return try self.buildValoptUnbox(self.coerceToSlotType(loaded, self.val_type));
                                }
                            }
                        }
                    }
                }
                return loaded;
            } else if (self.constants.get(name)) |val| {
                return try self.compileExpression(val);
            } else {
                const resolved = try self.resolveCalleeName(name);
                if (self.func_map.get(resolved)) |func_val| {
                    // #18: a bare fn used as a value is boxed like any closure.
                    return try self.buildBareFnBox(func_val);
                }
                std.debug.print("Identifier '{s}' not found\n", .{name});
                return error.IdentifierNotFound;
            }
        },
        .binary => |bin| {
            if (bin.op == .assign) {
                const r_val = try self.compileExpression(bin.right.*);
                // F5 O4 "x = e | e produces OWNED -> move". The target is the owner
                // now, so the statement's drain must not release it — same rule as
                // `let x = e`, and for the same reason.
                self.consumeTemporary(r_val);
                switch (bin.left.kind) {
                    .ident => |name| {
                        // A1: assigning a captured variable writes into the env slot.
                        if (self.envCaptureIndex(name)) |idx| {
                            const addr = try self.envSlotAddr(idx);
                            const eptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "env_ptr_store");
                            _ = core.LLVMBuildStore(self.builder, r_val, eptr);
                            return r_val;
                        }
                        var ptr: ?types.LLVMValueRef = null;
                        var curr_fn = self.current_function_name;
                        while (curr_fn) |fn_name| {
                            const fmt_key = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ fn_name, name });
                            defer self.allocator.free(fmt_key);
                            if (self.captured_globals.get(fmt_key)) |global_var| {
                                ptr = global_var;
                                break;
                            }
                            curr_fn = self.lambda_parents.get(fn_name);
                        }
                        if (ptr == null) {
                            ptr = self.locals.get(name);
                        }
                        const alloca_val = ptr orelse {
                            std.debug.print("Variable '{s}' not found on assignment left\n", .{name});
                            return error.VariableNotFound;
                        };

                        var target_type: ?[]const u8 = null;
                        if (self.current_local_types) |lt| {
                            target_type = lt.get(name);
                        }

                        if (target_type) |tt| {
                            if (self.isOwnedLocal(name, tt)) {
                                const is_r_var = (bin.right.kind == .ident or bin.right.kind == .field_access or bin.right.kind == .index);
                                if (is_r_var) {
                                    try self.compileRetain(r_val);
                                }
                                const old_val = core.LLVMBuildLoad2(self.builder, self.val_type, alloca_val, "old_val");
                                // Stage 5 Phase A: prefer the store-native destructor for the OLD value by
                                // the local's known TypeId (same-symbol gate); string fallback otherwise.
                                const old_tid: ?sema_types.TypeId = if (self.current_local_type_ids) |ids| ids.get(name) else null;
                                const dest = try self.getOrCreateDestructorPreferId(tt, old_tid);
                                try self.compileRelease(old_val, dest);
                            }
                        }

                        // Widen a struct RHS to the trait object when the target variable is
                        // trait-typed (`g: G; g = B{}`) — else a raw struct lands in a trait slot and
                        // a later method reads garbage as its vtable → SEGV. This MIRRORS the `let`
                        // widening (statements.zig): the fresh fat pointer is CONSUMED (the variable
                        // owns it, so the statement drain must not free it — that was the reassignment
                        // double-free), and the struct's orphaned construction ref is released (the
                        // trait object retained the struct, so its own +1 has no other owner).
                        var stored_val = r_val;
                        if (target_type) |tt| {
                            if (self.traits.contains(tt)) {
                                if (try self.resolveExpressionTypeName(bin.right)) |rt| {
                                    if (self.structs.contains(rt)) {
                                        const orig_struct = r_val;
                                        stored_val = try self.constructTraitObject(orig_struct, rt, tt);
                                        self.consumeTemporary(stored_val);
                                        // Stage 5 Phase B: store-native dtor via the same-symbol gate.
                                        const rtid: ?sema_types.TypeId = if (self.typed_ir) |ir| ir.typeOf(bin.right) else null;
                                        const sdtor = try self.getOrCreateDestructorPreferId(rt, rtid);
                                        try self.compileRelease(orig_struct, sdtor);
                                    }
                                }
                            }
                        }
                        // A7 / F3 §5 stage 4: coerce to the slot's honest type (double
                        // for a float local), same as the `let` store.
                        const slot_ty = if (core.LLVMIsAAllocaInst(alloca_val) != null)
                            core.LLVMGetAllocatedType(alloca_val)
                        else
                            self.val_type;
                        _ = core.LLVMBuildStore(self.builder, self.coerceToSlotType(stored_val, slot_ty), alloca_val);
                        return stored_val;
                    },
                    .field_access => |fa| {
                        const obj_ptr = try self.compileExpression(fa.object.*);
                        const obj_type = try self.resolveExpressionTypeName(fa.object);
                        if (obj_type) |struct_name| {
                            if (self.isStructType(struct_name)) {
                                const base_struct = getStructBaseName(struct_name);
                                var field_type_ref = ast.TypeRef{ .ident = "i32" };
                                if (self.structs.get(base_struct)) |s| {
                                    for (s.fields) |field| {
                                        if (std.mem.eql(u8, field.name, fa.field)) {
                                            field_type_ref = field.type_name;
                                            break;
                                        }
                                    }
                                } else if (self.unions.get(base_struct)) |u| {
                                    for (u.fields) |field| {
                                        if (std.mem.eql(u8, field.name, fa.field)) {
                                            field_type_ref = field.type_name;
                                            break;
                                        }
                                    }
                                }

                                const offset = try self.getFieldOffset(struct_name, fa.field);
                                const offset_val = core.LLVMConstInt(self.val_type, offset, 0);
                                const addr = core.LLVMBuildAdd(self.builder, obj_ptr, offset_val, "field_addr");

                                const llvm_field_type = self.toLLVMType(field_type_ref);
                                const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(llvm_field_type, 0), "field_ptr");

                                const f_type_str = try self.typeRefToString(field_type_ref);
                                // F5-2: declared field type lowered to a TypeId; `f_type_str` is the fallback.
                                if (self.isOwnedDeclaredType(field_type_ref, f_type_str)) {
                                    const is_r_var = (bin.right.kind == .ident or bin.right.kind == .field_access or bin.right.kind == .index);
                                    if (is_r_var) {
                                        try self.compileRetain(r_val);
                                    }
                                    const old_field_val = core.LLVMBuildLoad2(self.builder, llvm_field_type, ptr, "old_field_val");
                                    const casted_old = self.castToValType(old_field_val, field_type_ref);
                                    // Stage 5 Phase D (#6): the declared field TypeRef gives a TypeId, so
                                    // select the OLD field value's destructor store-native via the same-
                                    // symbol gate; f_type_str is the fallback.
                                    const f_tid = self.tidForTypeRef(field_type_ref);
                                    const dest = try self.getOrCreateDestructorPreferId(f_type_str, f_tid);
                                    try self.compileRelease(casted_old, dest);
                                }

                                // Widen a struct RHS to the trait object when the field is trait-typed
                                // (`self.g = A{}` where `g: G` — the stdlib's init()-body pattern). Same
                                // discipline as the `.ident` reassignment arm: r_val's temp was already
                                // consumed (line 963), so just CONSUME the fresh fat pointer (the field
                                // owns it, released by the struct destructor) and release the struct's
                                // orphaned construction ref. Without this a raw struct lands in the trait
                                // field slot → garbage vtable → SEGV. The ownership block above already
                                // released the OLD field value (the prior trait object).
                                var stored_r = r_val;
                                if (field_type_ref == .ident and self.traits.contains(field_type_ref.ident)) {
                                    if (try self.resolveExpressionTypeName(bin.right)) |rt| {
                                        if (self.structs.contains(rt)) {
                                            const orig_struct = r_val;
                                            stored_r = try self.constructTraitObject(orig_struct, rt, field_type_ref.ident);
                                            self.consumeTemporary(stored_r);
                                            // Stage 5 Phase B: store-native dtor via the same-symbol gate.
                                            const rtid: ?sema_types.TypeId = if (self.typed_ir) |ir| ir.typeOf(bin.right) else null;
                                            const sdtor = try self.getOrCreateDestructorPreferId(rt, rtid);
                                            try self.compileRelease(orig_struct, sdtor);
                                        }
                                    }
                                }

                                const casted_r_val = self.castFromValType(stored_r, llvm_field_type);
                                _ = core.LLVMBuildStore(self.builder, casted_r_val, ptr);
                                return stored_r;
                            }
                        }
                        return error.FieldAccessObjectNotStruct;
                    },
                    else => {
                        std.debug.print("Unsupported assignment target: {s}\n", .{@tagName(bin.left.kind)});
                        return error.UnsupportedAssignmentTarget;
                    },
                }
            }

            const left_type = try self.resolveExpressionTypeName(bin.left);
            const right_type = try self.resolveExpressionTypeName(bin.right);
            // F2-6: a string operand is detected by TypeId FIRST (isStringExpr) — the rendered STRING
            // misnames a destructured tuple element as "i32" (its tuple type doesn't round-trip), so a
            // string-concat `v + e` fell through to a NUMERIC add on the string pointer → garbage. The
            // rendered-string check stays as a fallback for exprs with no recorded TypeId.
            const is_string_concat = blk: {
                if (self.isStringExpr(bin.left) or self.isStringExpr(bin.right)) break :blk true;
                if (left_type) |lt| {
                    if (std.mem.eql(u8, lt, "string")) break :blk true;
                }
                if (right_type) |rt| {
                    if (std.mem.eql(u8, rt, "string")) break :blk true;
                }
                break :blk false;
            };
            const is_string_comparison = blk: {
                if (bin.left.kind == .literal and (bin.left.kind.literal == .null or bin.left.kind.literal == .undefined)) break :blk false;
                if (bin.right.kind == .literal and (bin.right.kind.literal == .null or bin.right.kind.literal == .undefined)) break :blk false;

                if (self.isStringExpr(bin.left) or self.isStringExpr(bin.right)) break :blk true;
                if (left_type) |lt| {
                    if (std.mem.eql(u8, lt, "string")) break :blk true;
                }
                if (right_type) |rt| {
                    if (std.mem.eql(u8, rt, "string")) break :blk true;
                }
                break :blk false;
            };
            const is_float_op = blk: {
                if (left_type) |lt| {
                    if (std.mem.eql(u8, lt, "f32") or std.mem.eql(u8, lt, "float") or
                        std.mem.eql(u8, lt, "f64") or std.mem.eql(u8, lt, "double")) break :blk true;
                }
                if (right_type) |rt| {
                    if (std.mem.eql(u8, rt, "f32") or std.mem.eql(u8, rt, "float") or
                        std.mem.eql(u8, rt, "f64") or std.mem.eql(u8, rt, "double")) break :blk true;
                }
                break :blk false;
            };

            var l_val = try self.compileExpression(bin.left.*);
            var r_val = try self.compileExpression(bin.right.*);

            // V1 value-optional boxing (CONSUME — bare comparison / arithmetic): `list.get(0) != 10`,
            // `opt + 1`. An operand whose type is a value-type optional is a BOXED pointer; used against
            // a REAL value it must be UNBOXED first, or the box pointer is compared/added as a raw
            // integer (the `list[0] != 10` failure). A NULL-CHECK is excluded: when the OTHER operand is
            // the `undefined`/`null` literal, the box-vs-`0` compare IS the presence test — leave the box.
            // (Absent unboxes to 0, matching the pre-boxing behavior of a bare comparison; presence is
            // still recoverable via `== undefined`, which this exclusion preserves.)
            {
                const l_is_undef = bin.left.kind == .literal and (bin.left.kind.literal == .undefined or bin.left.kind.literal == .null);
                const r_is_undef = bin.right.kind == .literal and (bin.right.kind.literal == .undefined or bin.right.kind.literal == .null);
                if (!r_is_undef and self.exprYieldsValoptBox(bin.left)) {
                    l_val = try self.buildValoptUnbox(self.coerceToSlotType(l_val, self.val_type));
                }
                if (!l_is_undef and self.exprYieldsValoptBox(bin.right)) {
                    r_val = try self.buildValoptUnbox(self.coerceToSlotType(r_val, self.val_type));
                }
            }

            // decimal128 arithmetic (specs §3.1 Stage 2): operands are heap decimals; route each
            // operator to its runtime BID op. `+ - * / %` allocate a FRESH result decimal (an owned
            // temp the enclosing statement's drain releases); comparisons call nova_decimal_cmp,
            // which yields {-1,0,1}, then test that against 0. The operand temps (if any) drain as
            // usual — the runtime only READS them. There is no implicit int↔decimal conversion in
            // Stage 2: a MIXED `decimal <op> non-decimal` is an honest error, not an integer op that
            // would mangle the decimal pointer (write `price * 2m`, not `price * 2`).
            {
                const l_is_dec = if (left_type) |lt| std.mem.eql(u8, lt, "decimal") else false;
                const r_is_dec = if (right_type) |rt| std.mem.eql(u8, rt, "decimal") else false;
                // `optionalDecimal == undefined` / `== null` is a NULL-CHECK, not decimal arithmetic:
                // an absent optional decimal is a null pointer, so let it fall through to the general
                // pointer/int comparison (compare the decimal-slot value against 0). Same exemption the
                // string comparison makes above — otherwise the mixed-operand guard below rejects it.
                const other_is_null_lit =
                    (bin.left.kind == .literal and (bin.left.kind.literal == .null or bin.left.kind.literal == .undefined)) or
                    (bin.right.kind == .literal and (bin.right.kind.literal == .null or bin.right.kind.literal == .undefined));
                if ((l_is_dec or r_is_dec) and !other_is_null_lit) {
                    if (!(l_is_dec and r_is_dec)) {
                        std.debug.print("decimal arithmetic requires BOTH operands to be `decimal` (Stage 2 has no implicit conversion): use an `m` literal, e.g. `2m`\n", .{});
                        return error.UnsupportedBinaryOp;
                    }
                    const dec_fn_name: ?[]const u8 = switch (bin.op) {
                        .add => "nova_decimal_add",
                        .sub => "nova_decimal_sub",
                        .mul => "nova_decimal_mul",
                        .div => "nova_decimal_div",
                        .mod => "nova_decimal_mod",
                        .eq, .ne, .lt, .gt, .le, .ge => "nova_decimal_cmp",
                        else => null,
                    };
                    const fname = dec_fn_name orelse {
                        std.debug.print("Binary operator not supported for decimal: {s}\n", .{@tagName(bin.op)});
                        return error.UnsupportedBinaryOp;
                    };
                    const dec_fn = self.func_map.get(fname).?;
                    const fn_t = core.LLVMGlobalGetValueType(dec_fn);
                    var dargs = [_]types.LLVMValueRef{ l_val, r_val };
                    const call = core.LLVMBuildCall2(self.builder, fn_t, dec_fn, &dargs, 2, "dec_op");
                    switch (bin.op) {
                        .eq, .ne, .lt, .gt, .le, .ge => {
                            // cmp -> {-1,0,1}; turn it into the boolean this relational operator means.
                            const zero = core.LLVMConstInt(self.val_type, 0, 0);
                            const pred = switch (bin.op) {
                                .eq => types.LLVMIntPredicate.LLVMIntEQ,
                                .ne => types.LLVMIntPredicate.LLVMIntNE,
                                .lt => types.LLVMIntPredicate.LLVMIntSLT,
                                .gt => types.LLVMIntPredicate.LLVMIntSGT,
                                .le => types.LLVMIntPredicate.LLVMIntSLE,
                                .ge => types.LLVMIntPredicate.LLVMIntSGE,
                                else => unreachable,
                            };
                            const cmp = core.LLVMBuildICmp(self.builder, pred, call, zero, "dec_cmp");
                            return core.LLVMBuildZExt(self.builder, cmp, self.val_type, "dec_cmp_ext");
                        },
                        else => return call, // a fresh decimal +1
                    }
                }
            }

            if (is_float_op) {
                // A7 / F3 §5 stage 4: float arithmetic operates on and RETURNS real
                // `double`. `asDouble` (an identity bitcast when the operand is already
                // double — LLVM folds it) reconciles operands that arrived across the
                // i64 ABI; the result stays `double` and only crosses back to i64 at a
                // boundary. This is what deletes the double↔i64 bitcast sandwich.
                l_val = core.LLVMBuildBitCast(self.builder, l_val, core.LLVMDoubleType(), "l_double");
                r_val = core.LLVMBuildBitCast(self.builder, r_val, core.LLVMDoubleType(), "r_double");
                switch (bin.op) {
                    .add => return core.LLVMBuildFAdd(self.builder, l_val, r_val, "faddtmp"),
                    .sub => return core.LLVMBuildFSub(self.builder, l_val, r_val, "fsubtmp"),
                    .mul => return core.LLVMBuildFMul(self.builder, l_val, r_val, "fmultmp"),
                    .div => return core.LLVMBuildFDiv(self.builder, l_val, r_val, "fdivtmp"),
                    .mod => return core.LLVMBuildFRem(self.builder, l_val, r_val, "fremtmp"),
                    .eq, .ne, .lt, .gt, .le, .ge => {
                        const pred = switch (bin.op) {
                            .eq => types.LLVMRealPredicate.LLVMRealOEQ,
                            .ne => types.LLVMRealPredicate.LLVMRealONE,
                            .lt => types.LLVMRealPredicate.LLVMRealOLT,
                            .gt => types.LLVMRealPredicate.LLVMRealOGT,
                            .le => types.LLVMRealPredicate.LLVMRealOLE,
                            .ge => types.LLVMRealPredicate.LLVMRealOGE,
                            else => unreachable,
                        };
                        const cmp = core.LLVMBuildFCmp(self.builder, pred, l_val, r_val, "fcmptmp");
                        return core.LLVMBuildZExt(self.builder, cmp, self.val_type, "zexttmp");
                    },
                    else => {
                        std.debug.print("Binary operator not supported for floats: {s}\n", .{@tagName(bin.op)});
                        return error.UnsupportedFloatBinaryOp;
                    },
                }
            }

            // A7 / F3 §5 stage 5: the honest width + signedness of this integer op's
            // result — drives 32-bit wrap and signed-vs-unsigned opcode selection below.
            // `null` for non-integer ops (string, bool, pointer-only), which are untouched.
            const iop = intOpKind(left_type, right_type);

            switch (bin.op) {
                .add => {
                    // F5: a `numToString` result is a FRESH +1 string, consumed by string_concat
                    // (which copies, it does not retain). If we don't release it, every `"n: " + i`
                    // leaks the intermediate — measured on 24_stringify (8 live). Track which operands
                    // we minted so they can be released after the concat.
                    var l_minted = false;
                    var r_minted = false;
                    if (is_string_concat) {
                        // A8: stringify each non-string operand via the runtime helpers
                        // (int/bool/float), not the injected `__i32_to_string`.
                        const left_is_str = if (left_type) |lt| std.mem.eql(u8, lt, "string") else false;
                        if (!left_is_str) {
                            l_val = try self.numToString(l_val, left_type);
                            l_minted = true;
                        }
                        const right_is_str = if (right_type) |rt| std.mem.eql(u8, rt, "string") else false;
                        if (!right_is_str) {
                            r_val = try self.numToString(r_val, right_type);
                            r_minted = true;
                        }
                    }
                    if (is_string_concat) {
                        var concat_fn = self.func_map.get("string_concat");
                        if (concat_fn == null) {
                            var iter = self.func_map.iterator();
                            while (iter.next()) |entry| {
                                const key = entry.key_ptr.*;
                                if (std.mem.endsWith(u8, key, "_string_concat") or std.mem.eql(u8, key, "string_concat")) {
                                    concat_fn = entry.value_ptr.*;
                                    break;
                                }
                            }
                        }
                        const final_concat_fn = concat_fn orelse {
                            std.debug.print("Error: string_concat function not found in func_map\n", .{});
                            return error.StringConcatFnNotFound;
                        };
                        var args = [_]types.LLVMValueRef{ l_val, r_val };
                        const fn_t = core.LLVMGlobalGetValueType(final_concat_fn);
                        const concat_res = core.LLVMBuildCall2(self.builder, fn_t, final_concat_fn, &args, 2, "concat_tmp");
                        // Release the minted numToString temporaries — concat copied them.
                        if (l_minted) try self.compileRelease(l_val, null);
                        if (r_minted) try self.compileRelease(r_val, null);
                        return concat_res;
                    }
                    // A7 / F3 §5 stage 5: wrap to the honest int width (2³¹ for `int`).
                    const res = core.LLVMBuildAdd(self.builder, l_val, r_val, "addtmp");
                    return if (iop) |k| self.canonicalizeInt(res, k.width, k.signed) else res;
                },
                .sub => {
                    const res = core.LLVMBuildSub(self.builder, l_val, r_val, "subtmp");
                    return if (iop) |k| self.canonicalizeInt(res, k.width, k.signed) else res;
                },
                .mul => {
                    const res = core.LLVMBuildMul(self.builder, l_val, r_val, "multmp");
                    return if (iop) |k| self.canonicalizeInt(res, k.width, k.signed) else res;
                },
                .div => {
                    // Unsigned types divide with `udiv` (F3 §5 "real unsigned"); the result
                    // is already in-range, so no post-canonicalisation is needed.
                    const unsigned = if (iop) |k| !k.signed else false;
                    return if (unsigned)
                        core.LLVMBuildUDiv(self.builder, l_val, r_val, "udivtmp")
                    else
                        core.LLVMBuildSDiv(self.builder, l_val, r_val, "divtmp");
                },
                .mod => {
                    const unsigned = if (iop) |k| !k.signed else false;
                    return if (unsigned)
                        core.LLVMBuildURem(self.builder, l_val, r_val, "uremtmp")
                    else
                        core.LLVMBuildSRem(self.builder, l_val, r_val, "modtmp");
                },
                .shl => {
                    const res = core.LLVMBuildShl(self.builder, l_val, r_val, "shltmp");
                    return if (iop) |k| self.canonicalizeInt(res, k.width, k.signed) else res;
                },
                .shr => {
                    // Unsigned right-shift is logical (`lshr`), signed is arithmetic (`ashr`).
                    // The i64 pipeline holds an `int` sign-extended, so for an UNSIGNED
                    // shift the value must first be reduced to its zero-extended canonical
                    // form or the high bits leak in; canonicalize both, then lshr.
                    const unsigned = if (iop) |k| !k.signed else false;
                    if (unsigned) {
                        if (iop) |k| {
                            const lc = self.canonicalizeInt(l_val, k.width, false);
                            return core.LLVMBuildLShr(self.builder, lc, r_val, "lshrtmp");
                        }
                        return core.LLVMBuildLShr(self.builder, l_val, r_val, "lshrtmp");
                    }
                    return core.LLVMBuildAShr(self.builder, l_val, r_val, "shrtmp");
                },
                .And, .bit_and => return core.LLVMBuildAnd(self.builder, l_val, r_val, "andtmp"),
                .Or, .bit_or => return core.LLVMBuildOr(self.builder, l_val, r_val, "ortmp"),
                .bit_xor => return core.LLVMBuildXor(self.builder, l_val, r_val, "xortmp"),
                .eq, .ne, .lt, .gt, .le, .ge => {
                    if (is_string_comparison and (bin.op == .eq or bin.op == .ne)) {
                        var eql_fn = self.func_map.get("string_eql");
                        if (eql_fn == null) {
                            var iter = self.func_map.iterator();
                            while (iter.next()) |entry| {
                                const key = entry.key_ptr.*;
                                if (std.mem.endsWith(u8, key, "_string_eql") or std.mem.eql(u8, key, "string_eql")) {
                                    eql_fn = entry.value_ptr.*;
                                    break;
                                }
                            }
                        }
                        const final_eql_fn = eql_fn orelse {
                            std.debug.print("Error: string_eql function not found in func_map\n", .{});
                            return error.StringEqlFnNotFound;
                        };
                        var args = [_]types.LLVMValueRef{ l_val, r_val };
                        const fn_t = core.LLVMGlobalGetValueType(final_eql_fn);
                        const eql_val = core.LLVMBuildCall2(self.builder, fn_t, final_eql_fn, &args, 2, "eql_tmp");
                        if (bin.op == .eq) {
                            return eql_val;
                        } else {
                            const zero = core.LLVMConstInt(self.val_type, 0, 0);
                            const cmp = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, eql_val, zero, "not_eql");
                            return core.LLVMBuildZExt(self.builder, cmp, self.val_type, "not_eql_ext");
                        }
                    }
                    // A7 / F3 §5 stage 5: unsigned operands use unsigned relational
                    // predicates (ULT/UGT/…) so e.g. a large `uint` compares as positive.
                    const unsigned = if (iop) |k| !k.signed else false;
                    const pred = switch (bin.op) {
                        .eq => types.LLVMIntPredicate.LLVMIntEQ,
                        .ne => types.LLVMIntPredicate.LLVMIntNE,
                        .lt => if (unsigned) types.LLVMIntPredicate.LLVMIntULT else types.LLVMIntPredicate.LLVMIntSLT,
                        .gt => if (unsigned) types.LLVMIntPredicate.LLVMIntUGT else types.LLVMIntPredicate.LLVMIntSGT,
                        .le => if (unsigned) types.LLVMIntPredicate.LLVMIntULE else types.LLVMIntPredicate.LLVMIntSLE,
                        .ge => if (unsigned) types.LLVMIntPredicate.LLVMIntUGE else types.LLVMIntPredicate.LLVMIntSGE,
                        else => unreachable,
                    };
                    // For an unsigned compare the i64 pipeline's sign-extended form would
                    // misorder values with the high bit set, so reduce to zero-extended
                    // canonical form first.
                    if (unsigned) {
                        if (iop) |k| {
                            l_val = self.canonicalizeInt(l_val, k.width, false);
                            r_val = self.canonicalizeInt(r_val, k.width, false);
                        }
                    }
                    const l_t = core.LLVMTypeOf(l_val);
                    const r_t = core.LLVMTypeOf(r_val);
                    const l_kind = core.LLVMGetTypeKind(l_t);
                    const r_kind = core.LLVMGetTypeKind(r_t);
                    if (l_kind == types.LLVMTypeKind.LLVMIntegerTypeKind and r_kind == types.LLVMTypeKind.LLVMIntegerTypeKind) {
                        const l_width = core.LLVMGetIntTypeWidth(l_t);
                        const r_width = core.LLVMGetIntTypeWidth(r_t);
                        if (l_width < r_width) {
                            l_val = core.LLVMBuildSExt(self.builder, l_val, r_t, "l_ext");
                        } else if (r_width < l_width) {
                            r_val = core.LLVMBuildSExt(self.builder, r_val, l_t, "r_ext");
                        }
                    }
                    const cmp = core.LLVMBuildICmp(self.builder, pred, l_val, r_val, "cmptmp");
                    return core.LLVMBuildZExt(self.builder, cmp, self.val_type, "zexttmp");
                },
                else => {
                    std.debug.print("Binary operator not supported: {s}\n", .{@tagName(bin.op)});
                    return error.UnsupportedBinaryOp;
                },
            }
        },
        .unary => |uni| {
            const operand_val = try self.compileExpression(uni.operand.*);
            const operand_type = try self.resolveExpressionTypeName(uni.operand);
            const is_float_op = blk: {
                if (operand_type) |ot| {
                    if (std.mem.eql(u8, ot, "f32") or std.mem.eql(u8, ot, "float") or
                        std.mem.eql(u8, ot, "f64") or std.mem.eql(u8, ot, "double")) break :blk true;
                }
                break :blk false;
            };

            switch (uni.op) {
                .neg => {
                    if (is_float_op) {
                        // A7 / F3 §5 stage 4: negation returns real `double` (see the arith case).
                        const operand_double = core.LLVMBuildBitCast(self.builder, operand_val, core.LLVMDoubleType(), "neg_double");
                        return core.LLVMBuildFNeg(self.builder, operand_double, "fnegtmp");
                    }
                    const zero = core.LLVMConstInt(self.val_type, 0, 0);
                    return core.LLVMBuildSub(self.builder, zero, operand_val, "negtmp");
                },
                .not => {
                    const zero = core.LLVMConstInt(self.val_type, 0, 0);
                    const cmp = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, operand_val, zero, "nottmp");
                    return core.LLVMBuildZExt(self.builder, cmp, self.val_type, "zexttmp");
                },
                .bit_not => {
                    // One's complement: `~x == x xor -1` (all-ones at the value width).
                    return core.LLVMBuildNot(self.builder, operand_val, "bitnottmp");
                },
            }
        },
        .if_expr => |ie| {
            const cond_val = try self.compileExpression(ie.condition.*);
            const cond_i1 = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, cond_val, core.LLVMConstInt(self.val_type, 0, 0), "ifcond");

            const current_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
            const then_bb = core.LLVMAppendBasicBlock(current_fn, "then");
            const else_bb = core.LLVMAppendBasicBlock(current_fn, "else");
            const merge_bb = core.LLVMAppendBasicBlock(current_fn, "ifcont");

            _ = core.LLVMBuildCondBr(self.builder, cond_i1, then_bb, else_bb);

            // Compile then branch
            // A7 / F3 §5 stage 4: the phi merges on the i64 ABI word; a float branch now
            // yields a real `double`, so reinterpret it to i64 bits at this merge boundary.
            //
            // ARC (if_expr owned cutover): when the result is managed, the phi TAKES ownership of the
            // selected branch's value — so on THIS edge, apply the store-into-aggregate move/dup rule
            // to the branch value: retain a borrowed branch (the phi needs its own +1), move a fresh
            // one OFF the statement drain (else both branch temps drain while the bind holds the
            // selected — freed — one: the pre-cutover UAF). The retain/move is emitted IN the branch
            // block, so it only runs on the taken edge (per-edge drop). The phi itself is registered as
            // the owned temp by `acquisitionDisposition(.if_expr)` when this returns.
            // When the if-expr's result type is a trait (`let o: G = if (c) A{} else B{}`), a struct
            // branch must be WIDENED to the trait object ON ITS OWN EDGE — else a raw struct reaches the
            // phi and the trait slot → garbage vtable → SEGV. The phi then merges two fat pointers and
            // owns the selected one (acquisitionDisposition(.if_expr)); each branch consumes its fresh
            // fat pointer here and releases the struct's orphaned construction ref (the widen discipline).
            const if_result_trait: ?[]const u8 = blk: {
                const rt = (self.resolveExpressionTypeName(&expr) catch null) orelse break :blk null;
                break :blk if (self.traits.contains(rt)) rt else null;
            };

            core.LLVMPositionBuilderAtEnd(self.builder, then_bb);
            var then_raw = try self.compileExpression(ie.then_branch.*);
            const then_widened = try self.widenBranchToTrait(ie.then_branch, &then_raw, if_result_trait);
            if (!then_widened and self.isOwnedExpr(ie.then_branch)) try self.takeOwnedElement(ie.then_branch.kind, then_raw);
            const then_val = self.coerceToSlotType(then_raw, self.val_type);
            _ = core.LLVMBuildBr(self.builder, merge_bb);
            const then_bb_end = core.LLVMGetInsertBlock(self.builder);

            // Compile else branch
            core.LLVMPositionBuilderAtEnd(self.builder, else_bb);
            var else_raw = try self.compileExpression(ie.else_branch.*);
            const else_widened = try self.widenBranchToTrait(ie.else_branch, &else_raw, if_result_trait);
            if (!else_widened and self.isOwnedExpr(ie.else_branch)) try self.takeOwnedElement(ie.else_branch.kind, else_raw);
            const else_val = self.coerceToSlotType(else_raw, self.val_type);
            _ = core.LLVMBuildBr(self.builder, merge_bb);
            const else_bb_end = core.LLVMGetInsertBlock(self.builder);

            core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);

            const phi = core.LLVMBuildPhi(self.builder, self.val_type, "ifphi");
            var incoming_vals = [_]types.LLVMValueRef{ then_val, else_val };
            var incoming_bbs = [_]types.LLVMBasicBlockRef{ then_bb_end, else_bb_end };
            core.LLVMAddIncoming(phi, &incoming_vals, &incoming_bbs, 2);

            return phi;
        },
        .call => |call| {
            // Handle console.log specially
            if (call.callee.kind == .field_access) {
                const fa = call.callee.kind.field_access;
                if (fa.object.kind == .ident) {
                } else {
                }
                const is_console = fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "console");
                const is_log = std.mem.eql(u8, fa.field, "log");
                const is_info = std.mem.eql(u8, fa.field, "info");
                const is_debug = std.mem.eql(u8, fa.field, "debug");
                const is_err = std.mem.eql(u8, fa.field, "err");
                if (is_console and (is_log or is_info or is_debug or is_err)) {
                    if (call.args.len == 1) {
                        // &call.args[0], not &<a local copy>: the pointer must
                        // point INTO the AST for the TypedIr key to mean anything.
                        const arg = call.args[0];
                        const type_name = try self.resolveExpressionTypeName(&call.args[0]);
                        if (type_name) |t| {
                            if (std.mem.eql(u8, t, "string")) {
                                const str_ptr = try self.compileExpression(arg);
                                if (self.is_wasm) {
                                    // WASM environment log(ptr, len)
                                    // Read string length from ptr - 4
                                    const offset = core.LLVMConstInt(self.val_type, 4, 0);
                                    const addr_sub = core.LLVMBuildSub(self.builder, str_ptr, offset, "len_addr");
                                    const len_ptr = core.LLVMBuildIntToPtr(self.builder, addr_sub, self.ptr_type, "len_ptr");
                                    const len_val = core.LLVMBuildLoad2(self.builder, self.val_type, len_ptr, "len_val");

                                    var args = [_]types.LLVMValueRef{ str_ptr, len_val };
                                    const fn_t = core.LLVMGlobalGetValueType(self.log_fn.?);
                                    _ = core.LLVMBuildCall2(self.builder, fn_t, self.log_fn.?, &args, 2, "");
                                } else {
                                    const ptr = core.LLVMBuildIntToPtr(self.builder, str_ptr, self.ptr_type, "puts_ptr");
                                    var args = [_]types.LLVMValueRef{ptr};
                                    const log_fn_to_call = if (is_info)
                                        self.nova_log_info_fn.?
                                    else if (is_debug)
                                        self.nova_log_debug_fn.?
                                    else if (is_err)
                                        self.nova_log_err_fn.?
                                    else
                                        self.nova_log_string_fn.?;
                                    const fn_t = core.LLVMGlobalGetValueType(log_fn_to_call);
                                    _ = core.LLVMBuildCall2(self.builder, fn_t, log_fn_to_call, &args, 1, "");
                                }
                            } else if (std.mem.eql(u8, t, "bool")) {
                                const val = try self.compileExpression(arg);
                                const helper = self.func_map.get("__log_bool") orelse return error.HelperNotFound;
                                var args = [_]types.LLVMValueRef{val};
                                const fn_t = core.LLVMGlobalGetValueType(helper);
                                _ = core.LLVMBuildCall2(self.builder, fn_t, helper, &args, 1, "");
                            } else {
                                const val = try self.compileExpression(arg);
                                const helper = self.func_map.get("__log_i32") orelse return error.HelperNotFound;
                                var args = [_]types.LLVMValueRef{val};
                                const fn_t = core.LLVMGlobalGetValueType(helper);
                                _ = core.LLVMBuildCall2(self.builder, fn_t, helper, &args, 1, "");
                            }
                        } else {
                            const val = try self.compileExpression(arg);
                            const helper = self.func_map.get("__log_i32") orelse return error.HelperNotFound;
                            var args = [_]types.LLVMValueRef{val};
                            const fn_t = core.LLVMGlobalGetValueType(helper);
                            _ = core.LLVMBuildCall2(self.builder, fn_t, helper, &args, 1, "");
                        }
                    }
                    return core.LLVMConstInt(self.val_type, 0, 0);
                }

                if (fa.object.kind == .ident and std.mem.endsWith(u8, fa.object.kind.ident, "protocol") and std.mem.eql(u8, fa.field, "callDecoder")) {
                    const decoder_ptr = try self.compileExpression(call.args[0]);
                    const fixed_data = try self.compileExpression(call.args[1]);
                    const heap_data = try self.compileExpression(call.args[2]);
                    const col_names = try self.compileExpression(call.args[3]);
                    const col_types = try self.compileExpression(call.args[4]);

                    var params = [_]types.LLVMTypeRef{ self.val_type, self.val_type, self.val_type, self.val_type };
                    const fn_type = core.LLVMFunctionType(self.val_type, &params, 4, 0);
                    const fn_ptr = core.LLVMBuildIntToPtr(self.builder, decoder_ptr, self.ptr_type, "fn_ptr");

                    var args = [_]types.LLVMValueRef{ fixed_data, heap_data, col_names, col_types };
                    return core.LLVMBuildCall2(self.builder, fn_type, fn_ptr, &args, 4, "call_decoder_res");
                }
                // `s.get(i)` / `s.set(i, v)` on a `Storage<T>` — specs.md §3.8.
                // THE ONLY implementation. A slot holds T DIRECTLY, which is what
                // removes `allocCopy`'s box and its one-leak-per-push.
                //
                // Dispatched on the RECEIVER'S TYPE, not on a name: `bytes` above is a
                // magic identifier, but a Storage is an ordinary value held in an
                // ordinary field (`self.data`), so the only thing that identifies it
                // is its type.
                //
                // There WAS a second copy (`compileStorageCall`, llvm_codegen.zig) with
                // the OPPOSITE semantics — its `get` retained and its `set` did not,
                // exactly inverting this one. It was dead: instrumented across the whole
                // corpus, ZERO hits, because this path reaches a Storage call first.
                // Deleted 2026-07-16.
                //
                // ⚠️ It mattered, because `a53827f` — "fix(F5 O4): `Storage<T>.get`
                // transfers ownership — a read returns +1, not a borrow" — landed in the
                // DEAD one. **O4's rule #1 was therefore never in force**, and is still
                // not: `get` below does NOT retain (measured: `List_string_get` has
                // retain=0). Anything reasoning from "a call result is owned" is
                // reasoning from a premise this file does not implement.
                //
                // `set` DOES retain and release the old — that half of O4 is real, and
                // it is what a container relies on to keep its elements alive. Enabling
                // `get`'s retain requires the temporary-release rule in the same change
                // or `newData.set(i, self.data.get(i))` becomes +2 with no owner for the
                // temporary (F5 §3.4b: the three rules only balance together).
                if (try self.resolveExpressionTypeName(fa.object)) |obj_t| {
                    if (std.mem.startsWith(u8, obj_t, "Storage<")) {
                        const elem = obj_t["Storage<".len .. obj_t.len - 1];
                        const base = try self.compileExpression(fa.object.*);
                        const eight = core.LLVMConstInt(self.val_type, 8, 0);

                        if (std.mem.eql(u8, fa.field, "get")) {
                            const idx = try self.compileExpression(call.args[0]);
                            const off = core.LLVMBuildMul(self.builder, idx, eight, "stg_g_off");
                            const addr = core.LLVMBuildAdd(self.builder, base, off, "stg_g_addr");
                            const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "stg_g_ptr");
                            const loaded = core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "stg_g");
                            // F5 O4 rule #1, "return | transfer to caller" — enabled for
                            // real this time. The collection KEEPS its reference (a read
                            // is not a pop), so the reader needs one of its own.
                            //
                            // This is what makes "a call result is owned" TRUE, and it is
                            // ONLY sound alongside temporary-release: `newData.set(i,
                            // self.data.get(i))` is now +1 (get) +1 (set) with the get's
                            // result owned by nobody. See the drain in statements.zig.
                            if (self.isOwnedStorageElem(fa.object, elem)) {
                                try self.compileRetain(loaded);
                            }
                            return loaded;
                        }
                        if (std.mem.eql(u8, fa.field, "set")) {
                            const idx = try self.compileExpression(call.args[0]);
                            const val = try self.compileExpression(call.args[1]);
                            const off = core.LLVMBuildMul(self.builder, idx, eight, "stg_s_off");
                            const addr = core.LLVMBuildAdd(self.builder, base, off, "stg_s_addr");
                            const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "stg_s_ptr");
                            // O4's store rule: retain the new, release the old, in
                            // that order — `s.set(i, x)` where x is already the slot's
                            // value must not free it between the two.
                            if (self.isOwnedStorageElem(fa.object, elem)) {
                                try self.compileRetain(val);
                                const old = core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "stg_s_old");
                                const elem_dest = try self.getOrCreateDestructor(elem);
                                try self.compileRelease(old, elem_dest);
                            }
                            _ = core.LLVMBuildStore(self.builder, val, ptr);
                            return core.LLVMConstInt(self.val_type, 0, 0);
                        }
                    }
                }

                // S3: explicit int <-> decimal conversion namespace (`decimal.fromInt`/`decimal.toInt`).
                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "decimal")) {
                    if (std.mem.eql(u8, fa.field, "fromInt")) {
                        const n = try self.compileExpression(call.args[0]);
                        const fn_val = self.func_map.get("nova_decimal_from_int").?;
                        const fn_t = core.LLVMGlobalGetValueType(fn_val);
                        var args = [_]types.LLVMValueRef{n};
                        // A fresh heap decimal (+1); the statement drain releases it via its inferred
                        // `decimal` type, exactly like the arithmetic ops above.
                        return core.LLVMBuildCall2(self.builder, fn_t, fn_val, &args, 1, "dec_from_int");
                    }
                    if (std.mem.eql(u8, fa.field, "toInt")) {
                        const d = try self.compileExpression(call.args[0]);
                        const fn_val = self.func_map.get("nova_decimal_to_int").?;
                        const fn_t = core.LLVMGlobalGetValueType(fn_val);
                        var args = [_]types.LLVMValueRef{d};
                        return core.LLVMBuildCall2(self.builder, fn_t, fn_val, &args, 1, "dec_to_int");
                    }
                    // S4: parse a RUNTIME string -> decimal (exact, round-half-even to 34 digits). The same
                    // BID parser the literal path uses; Nova strings are NUL-terminated (core.cpp) and decimal
                    // text is pure ASCII, so the string pointer is C-compatible. Unblocks exact DB numeric
                    // columns and serde. A fresh heap decimal (+1) drained by its inferred `decimal` type.
                    if (std.mem.eql(u8, fa.field, "fromString")) {
                        const s = try self.compileExpression(call.args[0]);
                        // A runtime Nova string may NOT be NUL-terminated (a `string.slice` view is exactly
                        // its length). Read the LENGTH from the header (i32 at ptr-4) and hand it, with the
                        // data pointer, to the length-bounded parser — never scan for a NUL.
                        const four = core.LLVMConstInt(self.val_type, 4, 0);
                        const len_addr = core.LLVMBuildSub(self.builder, s, four, "dec_len_addr");
                        const i32ptr = core.LLVMPointerType(self.i32_type, 0);
                        const len_ptr = core.LLVMBuildIntToPtr(self.builder, len_addr, i32ptr, "dec_len_ptr");
                        const len_i32 = core.LLVMBuildLoad2(self.builder, self.i32_type, len_ptr, "dec_len_i32");
                        const len = core.LLVMBuildZExt(self.builder, len_i32, self.val_type, "dec_len");
                        const s_ptr = core.LLVMBuildIntToPtr(self.builder, s, self.ptr_type, "dec_fromstr_ptr");
                        const from_fn = self.func_map.get("nova_decimal_from_string_n").?;
                        const from_t = core.LLVMGlobalGetValueType(from_fn);
                        var args = [_]types.LLVMValueRef{ s_ptr, len };
                        return core.LLVMBuildCall2(self.builder, from_t, from_fn, &args, 2, "dec_from_string_n");
                    }
                }

                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "bytes")) {
                    if (std.mem.eql(u8, fa.field, "alloc")) {
                        const size = try self.compileExpression(call.args[0]);
                        return try self.compileAlloc(size);
                    }
                    if (std.mem.eql(u8, fa.field, "alloc_persistent")) {
                        const size = try self.compileExpression(call.args[0]);
                        return try self.compileAllocPersistent(size);
                    }
                    if (std.mem.eql(u8, fa.field, "free")) {
                        const ptr = try self.compileExpression(call.args[0]);
                        return try self.compileFree(ptr);
                    }
                    if (std.mem.eql(u8, fa.field, "write_byte")) {
                        const ptr_val = try self.compileExpression(call.args[0]);
                        const offset_val = try self.compileExpression(call.args[1]);
                        const byte_val_raw = try self.compileExpression(call.args[2]);

                        const addr = core.LLVMBuildAdd(self.builder, ptr_val, offset_val, "addr");
                        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "write_ptr");
                        const byte_val = core.LLVMBuildTrunc(self.builder, byte_val_raw, self.i8_type, "byte_val");
                        _ = core.LLVMBuildStore(self.builder, byte_val, ptr);
                        return core.LLVMConstInt(self.val_type, 0, 0);
                    }
                    if (std.mem.eql(u8, fa.field, "write_i32")) {
                        const ptr_val = try self.compileExpression(call.args[0]);
                        const offset_val = try self.compileExpression(call.args[1]);
                        const i32_val_raw = try self.compileExpression(call.args[2]);

                        const addr = core.LLVMBuildAdd(self.builder, ptr_val, offset_val, "addr");
                        const i32_ptr_type = core.LLVMPointerType(self.i32_type, 0);
                        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, i32_ptr_type, "write_ptr");
                        const i32_val = core.LLVMBuildTrunc(self.builder, i32_val_raw, self.i32_type, "i32_val");
                        _ = core.LLVMBuildStore(self.builder, i32_val, ptr);
                        return core.LLVMConstInt(self.val_type, 0, 0);
                    }
                    if (std.mem.eql(u8, fa.field, "ptr_size")) {
                        return core.LLVMConstInt(self.val_type, 8, 0);
                    }
                    if (std.mem.eql(u8, fa.field, "read_ptr")) {
                        const ptr_val = try self.compileExpression(call.args[0]);
                        const offset_val = try self.compileExpression(call.args[1]);
                        const addr = core.LLVMBuildAdd(self.builder, ptr_val, offset_val, "addr");
                        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "read_ptr");
                        return core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "ptr_val");
                    }
                    if (std.mem.eql(u8, fa.field, "write_ptr")) {
                        const ptr_val = try self.compileExpression(call.args[0]);
                        const offset_val = try self.compileExpression(call.args[1]);
                        const val_to_write = try self.compileExpression(call.args[2]);
                        const addr = core.LLVMBuildAdd(self.builder, ptr_val, offset_val, "addr");
                        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "write_ptr");
                        _ = core.LLVMBuildStore(self.builder, val_to_write, ptr);
                        return core.LLVMConstInt(self.val_type, 0, 0);
                    }
                    if (std.mem.eql(u8, fa.field, "read_byte")) {
                        const ptr_val = try self.compileExpression(call.args[0]);
                        const offset_val = try self.compileExpression(call.args[1]);

                        const addr = core.LLVMBuildAdd(self.builder, ptr_val, offset_val, "addr");
                        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "read_ptr");
                        const byte_val = core.LLVMBuildLoad2(self.builder, self.i8_type, ptr, "byte_val");
                        return core.LLVMBuildZExt(self.builder, byte_val, self.val_type, "byte_val_ext");
                    }
                    if (std.mem.eql(u8, fa.field, "read_i32")) {
                        const ptr_val = try self.compileExpression(call.args[0]);
                        const offset_val = try self.compileExpression(call.args[1]);

                        const addr = core.LLVMBuildAdd(self.builder, ptr_val, offset_val, "addr");
                        const i32_ptr_type = core.LLVMPointerType(self.i32_type, 0);
                        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, i32_ptr_type, "read_ptr");
                        const i32_val = core.LLVMBuildLoad2(self.builder, self.i32_type, ptr, "i32_val");
                        return core.LLVMBuildZExt(self.builder, i32_val, self.val_type, "i32_val_ext");
                    }
                    // decimal128 <-> raw 16 bytes: the decimal value IS a pointer to its 16-byte BID
                    // payload, which is BYTE-IDENTICAL to BSON decimal128, so both ops are a 16-byte
                    // (two 8-byte word) memcpy. write copies the decimal's payload into the buffer; read
                    // allocates a fresh decimal (+1, ARC-managed) and copies the buffer's 16 bytes in.
                    if (std.mem.eql(u8, fa.field, "write_decimal")) {
                        const dst = try self.compileExpression(call.args[0]);
                        const offset = try self.compileExpression(call.args[1]);
                        const dec = try self.compileExpression(call.args[2]);
                        const i64ptr = core.LLVMPointerType(self.val_type, 0);
                        const eight = core.LLVMConstInt(self.val_type, 8, 0);
                        const dst_addr = core.LLVMBuildAdd(self.builder, dst, offset, "dec_dst_addr");
                        const s0 = core.LLVMBuildIntToPtr(self.builder, dec, i64ptr, "dec_s0");
                        const d0 = core.LLVMBuildIntToPtr(self.builder, dst_addr, i64ptr, "dec_d0");
                        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildLoad2(self.builder, self.val_type, s0, "dw0"), d0);
                        const s1 = core.LLVMBuildIntToPtr(self.builder, core.LLVMBuildAdd(self.builder, dec, eight, "s1a"), i64ptr, "dec_s1");
                        const d1 = core.LLVMBuildIntToPtr(self.builder, core.LLVMBuildAdd(self.builder, dst_addr, eight, "d1a"), i64ptr, "dec_d1");
                        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildLoad2(self.builder, self.val_type, s1, "dw1"), d1);
                        return core.LLVMConstInt(self.val_type, 0, 0);
                    }
                    if (std.mem.eql(u8, fa.field, "read_decimal")) {
                        const src = try self.compileExpression(call.args[0]);
                        const offset = try self.compileExpression(call.args[1]);
                        const dec = try self.compileAlloc(core.LLVMConstInt(self.val_type, 16, 0)); // fresh 16-byte heap, +1
                        const i64ptr = core.LLVMPointerType(self.val_type, 0);
                        const eight = core.LLVMConstInt(self.val_type, 8, 0);
                        const src_addr = core.LLVMBuildAdd(self.builder, src, offset, "dec_src_addr");
                        const s0 = core.LLVMBuildIntToPtr(self.builder, src_addr, i64ptr, "dec_rs0");
                        const d0 = core.LLVMBuildIntToPtr(self.builder, dec, i64ptr, "dec_rd0");
                        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildLoad2(self.builder, self.val_type, s0, "rw0"), d0);
                        const s1 = core.LLVMBuildIntToPtr(self.builder, core.LLVMBuildAdd(self.builder, src_addr, eight, "rs1a"), i64ptr, "dec_rs1");
                        const d1 = core.LLVMBuildIntToPtr(self.builder, core.LLVMBuildAdd(self.builder, dec, eight, "rd1a"), i64ptr, "dec_rd1");
                        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildLoad2(self.builder, self.val_type, s1, "rw1"), d1);
                        return dec;
                    }
                    if (std.mem.eql(u8, fa.field, "read_string")) {
                        const fn_val = self.func_map.get("__read_string") orelse {
                            std.debug.print("Helper function '__read_string' not found\n", .{});
                            return error.HelperNotFound;
                        };
                        const fn_t = core.LLVMGlobalGetValueType(fn_val);

                        const args = try self.allocator.alloc(types.LLVMValueRef, 2);
                        defer self.allocator.free(args);
                        args[0] = try self.compileExpression(call.args[0]);
                        args[1] = try self.compileExpression(call.args[1]);

                        return core.LLVMBuildCall2(self.builder, fn_t, fn_val, args.ptr, 2, "read_string_call");
                    }
                }
                return try self.compileMethodOrNamespacedCall(fa, call.args);
            }

            if (call.callee.kind == .ident) {
                const name = call.callee.kind.ident;
                // F1-3b: a constructor call `Type(...)`. Resolve the struct by NAME directly, never
                // through resolveCalleeName's func_map suffix scan. The scan can only ever return a
                // FUNCTION name (func_map/functions entries), so it can never turn a non-struct ident
                // into a struct — `resolveCalleeName("Storage")` scanned for a `_Storage` fn (none),
                // returned `"Storage"` unchanged, and isStructType resolved it anyway; for a non-struct
                // ident (`fn`, `pred`) it returned the name unchanged too. So the scan was pure waste on
                // BOTH branches. `name` IS the canonical struct key (isStructType looks it up directly).
                // Measured on 13_serde: constructor + non-struct-ident scan reaches (Storage/JsonValue/
                // List/Map + fn/pred) all leave the fallback.
                // F1 module-scoped types: a colliding constructor `Widget()` — resolve the module-unique
                // struct name from the call's own typed result so it builds THIS module's constructor.
                // Overrides only when the result is a registered struct whose base differs from the bare
                // ident (the colliding case); untouched otherwise.
                var resolved_struct_name = name;
                if (self.isCollidingStruct(name)) {
                    if (try self.resolveExpressionTypeName(&expr)) |rt| {
                        const rt_base = getStructBaseName(rt);
                        if (self.isStructType(rt_base)) resolved_struct_name = rt_base;
                    }
                    }
                if (self.isStructType(resolved_struct_name)) {
                    const struct_size = self.getTypeSize(ast.TypeRef{ .ident = resolved_struct_name }, false);
                    const instance_ptr = try self.compileAlloc(core.LLVMConstInt(self.val_type, struct_size, 0));

                    // The constructor fn was DEFINED via methodSymbol → mangleTypeName(owner) (which
                    // escapes chars like '-' in a module-scoped name, e.g. `nova-lang`→`nova_dalang`), so
                    // the lookup must mangle identically — building `{name}_init` raw missed a colliding
                    // struct's init. methodSymbol is the single source of truth for a method symbol name.
                    const init_name = try self.methodSymbol(resolved_struct_name, "init");
                    defer self.allocator.free(init_name);
                    const new_name = try self.methodSymbol(resolved_struct_name, "new");
                    defer self.allocator.free(new_name);

                    // M3 (F4 mono completion) precondition: a GENERIC constructor call
                    // (`Pair<int,string>(..)`) must target the MONO symbol `Pair_i32_string_init`, not the
                    // erased `Pair_init` — otherwise the erased body cannot be suppressed AND a call routed
                    // to it runs with `A`/`B` unresolved. The instantiation is the call's own result type.
                    // Prefer the mono init when it exists; fall back to the bare init/new otherwise. (The
                    // f45_erased_fallback counter never saw this because constructors bypass the method-
                    // call path it tracks.)
                    var mono_init: ?[]const u8 = null;
                    if (try self.resolveExpressionTypeName(&expr)) |inst| {
                        if (!std.mem.eql(u8, getStructBaseName(inst), inst)) { // has type args
                            const mi = try self.methodSymbol(inst, "init");
                            if (self.func_map.get(mi) != null) mono_init = mi else self.allocator.free(mi);
                        }
                    }
                    defer if (mono_init) |mi| self.allocator.free(mi);

                    const fn_val_opt = (if (mono_init) |mi| self.func_map.get(mi) else null) orelse
                        self.func_map.get(init_name) orelse self.func_map.get(new_name);

                    if (fn_val_opt) |fn_val| {
                        const total_args = call.args.len + 1;
                        const args = try self.allocator.alloc(types.LLVMValueRef, total_args);
                        defer self.allocator.free(args);

                        args[0] = instance_ptr;
                        const actual_fn_name = if (mono_init) |mi| mi else if (self.func_map.get(init_name) != null) init_name else new_name;
                        for (call.args, 0..) |*arg, idx| {
                            var val = try self.compileCallArgument(arg.*);
                            // V1: value ↔ value-optional boundary on constructor args.
                            val = try self.coerceValoptArg(val, arg, self.getFunctionParamTypeRef(actual_fn_name, idx + 1));
                            if (self.getFunctionParamType(actual_fn_name, idx + 1)) |expected_type| {
                                if (self.traits.contains(getStructBaseName(expected_type))) {
                                    if (try self.resolveExpressionTypeName(arg)) |struct_name| {
                                        if (self.structs.contains(struct_name)) {
                                            val = try self.constructTraitObject(val, struct_name, expected_type);
                                        }
                                    }
                                }
                            }
                            args[idx + 1] = val;
                        }

                        _ = try self.buildCallWithCasts(fn_val, args);
                    } else {
                        try self.initDefaultContainerFields(resolved_struct_name, instance_ptr, call.span);
                    }
                    return instance_ptr;
                }

                var is_captured = self.envCaptureIndex(name) != null;
                var curr_fn = self.current_function_name;
                while (curr_fn) |fn_name| {
                    const key = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ fn_name, name });
                    defer self.allocator.free(key);
                    if (self.captured_globals.contains(key)) {
                        is_captured = true;
                        break;
                    }
                    curr_fn = self.lambda_parents.get(fn_name);
                }
                if (self.locals.contains(name) or is_captured) {
                    // A1: indirect call on a closure value (box {fn_ptr, env}).
                    const box_val = try self.compileExpression(call.callee.*);
                    return try self.buildClosureCall(box_val, call.args);
                }

                // F1 stage 3b CUTOVER: resolve via the SymbolId sema recorded (symOf(call) ->
                // legacy_mangled, the exact emitted name the symbol table computes) when it names a
                // real emitted function — validated DISAGREE=0 against the func_map suffix scan
                // across the corpus. The `hasFunction` guard makes it FAIL-SAFE: a wrong or
                // incomplete SymbolId name never selects a phantom; it falls through to the scan,
                // which still serves externs (exact match) and any un-recorded call. This is the
                // first call path off the 227-line scan; the scan stays until every path is over.
                const resolved_name = resolve: {
                    if (self.typed_ir) |ir| {
                        if (ir.symOf(&expr)) |sid| {
                            if (sema_shadow.live_sema) |sm| {
                                const legacy = sm.tab.symbolAt(sid).legacy_mangled;
                                if (self.hasFunction(legacy)) {
                                    if (sema_shadow.report_enabled) sema_shadow.f1_3b_agree += 1;
                                    break :resolve legacy;
                                }
                            }
                        }
                    }
                    if (sema_shadow.report_enabled) {
                        sema_shadow.f1_3b_sym_absent += 1;
                        sema_shadow.noteF13bAbsent(name);
                    }
                    break :resolve try self.resolveCalleeName(name);
                };
                const fn_val = self.func_map.get(resolved_name) orelse {
                    std.debug.print("Function '{s}' not found\n", .{resolved_name});
                    return error.FunctionNotFound;
                };

                // T3 FFI: a call to an `extern("lib") fn` marshals its string args/return across
                // the C-ABI boundary. A `string` param becomes a fresh NUL-terminated C string
                // (freed after the call); a `string` return is copied into a Nova string. Other
                // types (int/long/bool/ptr/struct) pass through buildCallWithCasts unchanged.
                if (self.ffi_externs.get(resolved_name)) |ffd| {
                    const args = try self.allocator.alloc(types.LLVMValueRef, call.args.len);
                    defer self.allocator.free(args);
                    // (nova_string_value, cstr_temp) pairs to free after the call.
                    var to_free = std.ArrayListUnmanaged([2]types.LLVMValueRef).empty;
                    defer to_free.deinit(self.allocator);
                    for (call.args, 0..) |*arg, idx| {
                        const val = try self.compileCallArgument(arg.*);
                        const is_str_param = idx < ffd.params.len and if (ffd.params[idx].type_name) |t|
                            std.mem.eql(u8, self.typeRefToString(t) catch "", "string")
                        else
                            false;
                        if (is_str_param) {
                            const to_cstr = self.func_map.get("nova_ffi_to_cstr").?;
                            var one = [_]types.LLVMValueRef{val};
                            const cstr = try self.buildCallWithCasts(to_cstr, &one);
                            try to_free.append(self.allocator, .{ val, cstr });
                            args[idx] = cstr;
                        } else {
                            args[idx] = val;
                        }
                    }
                    var ret = try self.buildCallWithCasts(fn_val, args);
                    for (to_free.items) |pair| {
                        const free_fn = self.func_map.get("nova_ffi_free_cstr").?;
                        var fa = [_]types.LLVMValueRef{ pair[0], pair[1] };
                        _ = try self.buildCallWithCasts(free_fn, &fa);
                    }
                    const ret_is_str = if (ffd.ret_type) |t|
                        std.mem.eql(u8, self.typeRefToString(t) catch "", "string")
                    else
                        false;
                    if (ret_is_str) {
                        const from_cstr = self.func_map.get("nova_ffi_from_cstr").?;
                        var one = [_]types.LLVMValueRef{ret};
                        ret = try self.buildCallWithCasts(from_cstr, &one);
                    }
                    return ret;
                }

                // Compile arguments
                const args = try self.allocator.alloc(types.LLVMValueRef, call.args.len);
                defer self.allocator.free(args);
                for (call.args, 0..) |*arg, idx| {
                    var val = try self.compileCallArgument(arg.*);
                    // V1: box/unbox at the value ↔ value-optional argument boundary (`equalInt(m.get(k), 10)`).
                    val = try self.coerceValoptArg(val, arg, self.getFunctionParamTypeRef(resolved_name, idx));
                    if (self.getFunctionParamType(resolved_name, idx)) |expected_type| {
                        if (self.traits.contains(getStructBaseName(expected_type))) {
                            if (try self.resolveExpressionTypeName(arg)) |struct_name| {
                                if (self.structs.contains(struct_name)) {
                                    val = try self.constructTraitObject(val, struct_name, expected_type);
                                }
                            }
                        }
                    }
                    args[idx] = val;
                }

                // M3-C: calling an async fn from a (non-await) context blocks:
                // run the coroutine to completion and yield its promise value.
                // Real suspension via `await` is separate (later in M3-C).
                if (self.async_fns.contains(resolved_name)) {
                    return try self.buildDriveAsyncCall(fn_val, args);
                }

                return try self.buildCallWithCasts(fn_val, args);
            }

            // A1: indirect call fallback — closure value (box {fn_ptr, env}).
            const box_val = try self.compileExpression(call.callee.*);
            return try self.buildClosureCall(box_val, call.args);
        },
        .generic_call => |gc| {
            if (gc.callee.kind == .field_access) {
                const fa = gc.callee.kind.field_access;
                // Typed mediator routing (flagship): `router.get<Q>(path)` on a
                // struct that has an `__addRoute` method lowers to
                // `router.__addRoute("GET", path, __mediator_dispatch_Q)`. The
                // dispatch fn (source-generated per RequestHandler<Q,R> impl, see
                // generateMediatorDispatch) embeds the handler — auto-discovery —
                // and passing its bare name yields a function value.
                if (routeVerbMethod(fa.field)) |method_str| {
                    if (gc.type_args.len == 1 and gc.args.len == 1) {
                        if (try self.resolveExpressionTypeName(fa.object)) |obj_ty| {
                            if (self.structs.get(getStructBaseName(obj_ty))) |rsd| {
                                if (structHasMethod(rsd, "__addRoute")) {
                                    // router.get<Q>(path) -> router.__addRoute("GET", path, "Q").
                                    // The route is keyed by the request-type NAME; the
                                    // Router dispatches via __mediator_dispatch_by_name.
                                    const q = try self.typeRefToString(gc.type_args[0]);
                                    var synth_args = [_]ast.Expression{
                                        .{ .kind = .{ .literal = .{ .string = method_str } } },
                                        gc.args[0],
                                        .{ .kind = .{ .literal = .{ .string = q } } },
                                    };
                                    const synth_fa = ast.FieldAccess{ .object = fa.object, .field = "__addRoute", .span = fa.span };
                                    return try self.compileMethodOrNamespacedCall(synth_fa, &synth_args);
                                }
                            }
                        }
                    }
                }
                if (std.mem.eql(u8, fa.field, "Atomic")) {
                    const target_type = gc.type_args[0];
                    const t_name = try self.typeRefToString(target_type);

                    const cell = self.atomicCell(t_name);
                    const size_val = core.LLVMConstInt(self.val_type, cell.size, 0);

                    // Allocate 4/8 bytes for the actual atomic value
                    const atomic_val_ptr = try self.compileAlloc(size_val);

                    // Store the initial value
                    const initial_val = try self.compileExpression(gc.args[0]);
                    const llvm_field_type = self.atomicCell(t_name).ty;
                    const casted_initial = self.castFromValType(initial_val, llvm_field_type);
                    const ptr = core.LLVMBuildIntToPtr(self.builder, atomic_val_ptr, core.LLVMPointerType(llvm_field_type, 0), "init_ptr");
                    _ = core.LLVMBuildStore(self.builder, casted_initial, ptr);

                    // Allocate Atomic struct wrapper
                    const struct_size = self.getTypeSize(ast.TypeRef{ .ident = "Atomic" }, false);
                    const struct_ptr_val = try self.compileAlloc(core.LLVMConstInt(self.val_type, struct_size, 0));

                    // Store atomic_val_ptr into Atomic.ptr (offset 0)
                    const ptr_dest = core.LLVMBuildIntToPtr(self.builder, struct_ptr_val, core.LLVMPointerType(self.ptr_type, 0), "struct_ptr_dest");
                    _ = core.LLVMBuildStore(self.builder, core.LLVMBuildIntToPtr(self.builder, atomic_val_ptr, self.ptr_type, "cast_ptr"), ptr_dest);

                    return struct_ptr_val;
                }
                if (fa.object.kind == .ident and
                    (std.mem.eql(u8, fa.object.kind.ident, "json") or std.mem.eql(u8, fa.object.kind.ident, "JsonValue") or
                        std.mem.eql(u8, fa.object.kind.ident, "yaml") or std.mem.eql(u8, fa.object.kind.ident, "YamlValue")) and
                    std.mem.eql(u8, fa.field, "parse"))
                {
                    const is_yaml = std.mem.eql(u8, fa.object.kind.ident, "yaml") or std.mem.eql(u8, fa.object.kind.ident, "YamlValue");
                    var target_type = gc.type_args[0];
                    // F4-5: inside a specialized generic-method body, the type arg may be the method's
                    // param (`json.parse<T>`); substitute it to the concrete type so the binder resolves
                    // (`GetUser__bind`, not a lookup for a struct literally named `T`). No-op elsewhere.
                    if (target_type == .ident and self.current_method_subst != null) {
                        for (self.current_method_subst.?) |b| {
                            if (std.mem.eql(u8, b.name, target_type.ident)) {
                                target_type = ast.TypeRef{ .ident = b.concrete };
                                break;
                            }
                        }
                    }
                    const input_expr = gc.args[0];
                    return try self.compileGenericParse(is_yaml, target_type, input_expr);
                }
                // F4-5: `serde.bind<T>(src)` -> `<T>__bind(src)`. Reifies the generated binder; inside
                // a specialized method body `T` is substituted to the concrete type first.
                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "serde") and
                    std.mem.eql(u8, fa.field, "bind") and gc.type_args.len == 1)
                {
                    // Reify `serde.bind<T>(src)` to `<T>__bind(src)`. Compile the source arg and WIDEN it
                    // to the `ValueSource` trait object HERE — a concrete source (`source.fromJson(...)` →
                    // `JsonSource`, an `orm.RowSource`) reaches `__bind`'s `src: ValueSource` param as a raw
                    // struct otherwise, and `__bind`'s first `src.getInt(...)` reads a garbage vtable. (When
                    // the arg is ALREADY a `ValueSource` — e.g. a method/fn param — it is not a struct, so no
                    // widening; passed through unchanged. This is why `serde.bind<T>` worked inside a generic
                    // method whose `src` param was already `ValueSource`, but NOT `serde.bind<Dto>(fromJson())`
                    // at a direct call site.)
                    const rendered = try self.resolveReifyTypeName(gc.type_args[0]);
                    const binder_name = try std.fmt.allocPrint(self.allocator, "{s}__bind", .{rendered});
                    defer self.allocator.free(binder_name);
                    const resolved_binder = try self.resolveCalleeName(binder_name);
                    const fn_val = self.func_map.get(resolved_binder) orelse self.func_map.get(binder_name) orelse {
                        std.debug.print("serde.bind: binder '{s}' not found\n", .{binder_name});
                        return error.FunctionNotFound;
                    };
                    var arg_val = try self.compileCallArgument(gc.args[0]);
                    if (try self.resolveExpressionTypeName(&gc.args[0])) |sname| {
                        if (self.structs.contains(sname)) {
                            arg_val = try self.constructTraitObject(arg_val, sname, "ValueSource");
                        }
                    }
                    var bargs = [_]types.LLVMValueRef{arg_val};
                    const bound = try self.buildCallWithCasts(fn_val, &bargs);
                    // No manual registerTemporary here: unlike the old synthesized-`.call` (which had no
                    // ExprId), this returns from the OUTER `serde.bind<T>(...)` generic_call node, which DOES
                    // carry an ExprId — so the ordinary disposition/temp tracking owns it. A `let x = ...`
                    // consumes it; an immediate use drains it at statement end. Registering it again here
                    // double-counted, so `let a = serde.bind<Dto>(src)` released the bound struct twice → UAF.
                    return bound;
                }
                // Write-side mirror: `serde.dump<T>(obj, sink)` -> `<T>__dump(obj, sink)`. `obj` is a
                // concrete `T` struct (passed as-is); `sink` is widened to `ValueSink` here for the same
                // vtable reason as `serde.bind`'s src. Returns void.
                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "serde") and
                    std.mem.eql(u8, fa.field, "dump") and gc.type_args.len == 1 and gc.args.len == 2)
                {
                    const rendered = try self.resolveReifyTypeName(gc.type_args[0]);
                    const dumper_name = try std.fmt.allocPrint(self.allocator, "{s}__dump", .{rendered});
                    defer self.allocator.free(dumper_name);
                    const resolved_dumper = try self.resolveCalleeName(dumper_name);
                    const fn_val = self.func_map.get(resolved_dumper) orelse self.func_map.get(dumper_name) orelse {
                        std.debug.print("serde.dump: dumper '{s}' not found\n", .{dumper_name});
                        return error.FunctionNotFound;
                    };
                    const obj_val = try self.compileCallArgument(gc.args[0]);
                    var sink_val = try self.compileCallArgument(gc.args[1]);
                    if (try self.resolveExpressionTypeName(&gc.args[1])) |sname| {
                        if (self.structs.contains(sname)) {
                            sink_val = try self.constructTraitObject(sink_val, sname, "ValueSink");
                        }
                    }
                    var dargs = [_]types.LLVMValueRef{ obj_val, sink_val };
                    return try self.buildCallWithCasts(fn_val, &dargs);
                }
                // F4-5: `serde.typeName<T>()` -> the concrete type's name as a string literal.
                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "serde") and
                    std.mem.eql(u8, fa.field, "typeName") and gc.type_args.len == 1)
                {
                    const rendered = try self.resolveReifyTypeName(gc.type_args[0]);
                    return try self.getOrCreateStringLiteral(rendered);
                }
                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "protocol") and std.mem.eql(u8, fa.field, "callDecoder")) {
                    const decoder_ptr = try self.compileExpression(gc.args[0]);
                    const fixed_data = try self.compileExpression(gc.args[1]);
                    const heap_data = try self.compileExpression(gc.args[2]);
                    const col_names = try self.compileExpression(gc.args[3]);
                    const col_types = try self.compileExpression(gc.args[4]);

                    var params = [_]types.LLVMTypeRef{ self.val_type, self.val_type, self.val_type, self.val_type };
                    const fn_type = core.LLVMFunctionType(self.val_type, &params, 4, 0);
                    const fn_ptr = core.LLVMBuildIntToPtr(self.builder, decoder_ptr, self.ptr_type, "fn_ptr");

                    var args = [_]types.LLVMValueRef{ fixed_data, heap_data, col_names, col_types };
                    return core.LLVMBuildCall2(self.builder, fn_type, fn_ptr, &args, 4, "call_decoder_res");
                }
                const obj_type = try self.resolveExpressionTypeName(fa.object);
                if (obj_type) |struct_name| {
                    const base_struct = getStructBaseName(struct_name);
                    if (std.mem.eql(u8, base_struct, "BTreeConnection") and
                        (std.mem.eql(u8, fa.field, "query") or std.mem.eql(u8, fa.field, "queryStruct")))
                    {
                        const target_type = gc.type_args[0];
                        const sql_expr = gc.args[0];
                        const params_expr = gc.args[1];
                        return try self.compileBTreeQuery(target_type, fa.object.*, sql_expr, params_expr);
                    }
                }
                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "Atomic") and std.mem.eql(u8, fa.field, "new"))
                {
                    const target_type = gc.type_args[0];
                    const t_name = try self.typeRefToString(target_type);

                    const cell = self.atomicCell(t_name);
                    const size_val = core.LLVMConstInt(self.val_type, cell.size, 0);

                    // Allocate 4/8 bytes for the actual atomic value
                    const atomic_val_ptr = try self.compileAlloc(size_val);

                    // Store the initial value
                    const initial_val = try self.compileExpression(gc.args[0]);
                    const llvm_field_type = self.atomicCell(t_name).ty;
                    const casted_initial = self.castFromValType(initial_val, llvm_field_type);
                    const ptr = core.LLVMBuildIntToPtr(self.builder, atomic_val_ptr, core.LLVMPointerType(llvm_field_type, 0), "init_ptr");
                    _ = core.LLVMBuildStore(self.builder, casted_initial, ptr);

                    // Allocate Atomic struct wrapper
                    const struct_size = self.getTypeSize(ast.TypeRef{ .ident = "Atomic" }, false);
                    const struct_ptr_val = try self.compileAlloc(core.LLVMConstInt(self.val_type, struct_size, 0));

                    // Store atomic_val_ptr into Atomic.ptr (offset 0)
                    const ptr_dest = core.LLVMBuildIntToPtr(self.builder, struct_ptr_val, core.LLVMPointerType(self.ptr_type, 0), "struct_ptr_dest");
                    _ = core.LLVMBuildStore(self.builder, core.LLVMBuildIntToPtr(self.builder, atomic_val_ptr, self.ptr_type, "cast_ptr"), ptr_dest);

                    return struct_ptr_val;
                }

                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "bytes") and std.mem.eql(u8, fa.field, "new_persistent")) {
                    const target_type = gc.type_args[0];
                    var size: usize = 8;
                    switch (target_type) {
                        .ident => |name| {
                            size = self.getTypeSize(ast.TypeRef{ .ident = name }, false);
                        },
                        .generic => |g| {
                            size = self.getTypeSize(ast.TypeRef{ .ident = g.name }, false);
                        },
                        else => {},
                    }
                    const size_val = core.LLVMConstInt(self.val_type, size, 0);
                    return try self.compileAllocPersistent(size_val);
                }
                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "bytes") and std.mem.eql(u8, fa.field, "new_with_allocator")) {
                    if (self.locals.get("self")) |self_alloca| {
                        return core.LLVMBuildLoad2(self.builder, self.val_type, self_alloca, "self_val");
                    }
                    const target_type = gc.type_args[0];
                    var size: usize = 8;
                    switch (target_type) {
                        .ident => |name| {
                            size = self.getTypeSize(ast.TypeRef{ .ident = name }, false);
                        },
                        .generic => |g| {
                            size = self.getTypeSize(ast.TypeRef{ .ident = g.name }, false);
                        },
                        else => {},
                    }
                    const size_val = core.LLVMConstInt(self.val_type, size, 0);
                    const alloc_val = try self.compileExpression(gc.args[0]);

                    const offset = try self.getFieldOffset("Allocator", "kind");
                    const offset_val = core.LLVMConstInt(self.val_type, offset, 0);
                    const addr = core.LLVMBuildAdd(self.builder, alloc_val, offset_val, "kind_addr");
                    const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "kind_ptr");
                    const kind_val = core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "kind_val");

                    const is_c_alloc = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, kind_val, core.LLVMConstInt(self.val_type, 1, 0), "is_c_alloc");

                    const current_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
                    const then_bb = core.LLVMAppendBasicBlock(current_fn, "alloc_c");
                    const else_bb = core.LLVMAppendBasicBlock(current_fn, "alloc_arena");
                    const merge_bb = core.LLVMAppendBasicBlock(current_fn, "alloc_merge");

                    _ = core.LLVMBuildCondBr(self.builder, is_c_alloc, then_bb, else_bb);

                    // Then block (C allocator / persistent)
                    core.LLVMPositionBuilderAtEnd(self.builder, then_bb);
                    const p_val = try self.compileAllocPersistent(size_val);
                    _ = core.LLVMBuildBr(self.builder, merge_bb);
                    const then_end_bb = core.LLVMGetInsertBlock(self.builder);

                    // Else block (Arena allocator)
                    core.LLVMPositionBuilderAtEnd(self.builder, else_bb);
                    const a_val = try self.compileAlloc(size_val);
                    _ = core.LLVMBuildBr(self.builder, merge_bb);
                    const else_end_bb = core.LLVMGetInsertBlock(self.builder);

                    // Merge block
                    core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
                    const phi = core.LLVMBuildPhi(self.builder, self.val_type, "alloc_res");
                    var incoming_vals = [_]types.LLVMValueRef{ p_val, a_val };
                    var incoming_bbs = [_]types.LLVMBasicBlockRef{ then_end_bb, else_end_bb };
                    core.LLVMAddIncoming(phi, &incoming_vals, &incoming_bbs, 2);
                    return phi;
                }
                // F4-5: explicit-generic method call — `app.get<GetUser>(path)` routes to the
                // specialized body `App_get__GetUser`. Falls through to the ordinary method path
                // when there is no such specialization (returns null).
                if (try self.compileExplicitGenericMethodCall(gc.callee.kind.field_access, gc.type_args, gc.args)) |v| {
                    return v;
                }
                // M3 (F4 mono completion): a MODULE-QUALIFIED generic constructor `map.Map<string,int>(..)`
                // delegates below to compileMethodOrNamespacedCall, which DROPS gc.type_args and builds the
                // ERASED `Map_init` (fnbox/hashFn left in the erased body's ABI). Route it to the mono init
                // here — parallel to the bare-ident generic-ctor path (~2400) — so it targets
                // `Map_string_i32_init`. Guard: the object is a MODULE (an untyped ident), the field IS a
                // struct type, and there ARE type args (a genuine generic constructor, not a method call).
                {
                    const cfa = gc.callee.kind.field_access;
                    if (gc.type_args.len > 0 and cfa.object.kind == .ident and
                        self.isStructType(cfa.field) and
                        (try self.resolveExpressionTypeName(cfa.object)) == null)
                    {
                        const g_ref = ast.TypeRef{ .generic = .{ .name = cfa.field, .params = gc.type_args } };
                        const struct_size = self.getTypeSize(g_ref, false);
                        const instance_ptr = try self.compileAlloc(core.LLVMConstInt(self.val_type, struct_size, 0));
                        var mono_init: ?[]const u8 = null;
                        if (try self.resolveExpressionTypeName(&expr)) |inst| {
                            if (!std.mem.eql(u8, getStructBaseName(inst), inst)) {
                                const mi = try self.methodSymbol(inst, "init");
                                if (self.func_map.get(mi) != null) mono_init = mi else self.allocator.free(mi);
                            }
                        }
                        defer if (mono_init) |mi| self.allocator.free(mi);
                        const base_init = try self.methodSymbol(cfa.field, "init");
                        defer self.allocator.free(base_init);
                        const base_new = try self.methodSymbol(cfa.field, "new");
                        defer self.allocator.free(base_new);
                        const fn_val_opt = (if (mono_init) |mi| self.func_map.get(mi) else null) orelse
                            self.func_map.get(base_init) orelse self.func_map.get(base_new);
                        if (fn_val_opt) |fn_val| {
                            const args = try self.allocator.alloc(types.LLVMValueRef, gc.args.len + 1);
                            defer self.allocator.free(args);
                            // Trait-widening for a MODULE-QUALIFIED generic constructor
                            // (`actor.ActorCell<int>(mbox, s)`) — the mirror of the bare-ident path
                            // below. A concrete struct arg for a trait-typed init param (`behavior:
                            // Behavior<M>`) must be widened to a fat pointer here; otherwise the raw
                            // struct lands in the trait field and the actor's `_vtable_<S>_<Trait>` is
                            // never emitted (the vtable is minted on-demand by constructTraitObject).
                            const init_decl: ?*const ast.FunctionDecl = blk: {
                                const sd = self.structs.get(cfa.field) orelse break :blk null;
                                for (sd.methods) |*m| {
                                    if (std.mem.eql(u8, m.decl.name, "init") or std.mem.eql(u8, m.decl.name, "new")) break :blk &m.decl;
                                }
                                break :blk null;
                            };
                            args[0] = instance_ptr;
                            for (gc.args, 0..) |arg, idx| {
                                var val = try self.compileCallArgument(arg);
                                if (init_decl) |idcl| {
                                    if (idx < idcl.params.len) {
                                        if (idcl.params[idx].type_name) |trt| {
                                            const expected_type = try self.typeRefToString(trt); // transient
                                            if (self.traits.contains(getStructBaseName(expected_type))) {
                                                if (try self.resolveExpressionTypeName(&arg)) |struct_name| {
                                                    if (self.structs.contains(struct_name)) {
                                                        val = try self.constructTraitObject(val, struct_name, expected_type);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                args[idx + 1] = val;
                            }
                            _ = try self.buildCallWithCasts(fn_val, args);
                            return instance_ptr;
                        }
                    }
                }
                // MODULE-QUALIFIED generic FREE fn: `client.getJson<Info>(args)` → the monomorphized spec
                // `web_client_getJson__Info`. Parallel to the generic-constructor hook above and the bare-
                // ident generic-call routing below. Guard: the object is a MODULE (an untyped ident), the
                // field is NOT a struct type (that's the constructor case), there ARE type args, and a spec
                // actually exists. Without this, `compileMethodOrNamespacedCall` drops the type args and
                // looks for the erased base — which a sync generic free fn no longer emits.
                {
                    const cfa = gc.callee.kind.field_access;
                    // ASYNC generic fns keep their erased base and are dispatched via the coroutine ramp
                    // (or the no-await synchronous-completion path), NOT a synchronous spec call — routing
                    // `async_util.selectAny<int>(fs)` to `..._selectAny__int` here would return a raw future
                    // instead of running it. Skip the hook when the field names an async fn.
                    var isAsyncField = false;
                    {
                        var it = self.async_fns.keyIterator();
                        while (it.next()) |k| {
                            const key = k.*;
                            if (std.mem.endsWith(u8, key, cfa.field) and
                                (key.len == cfa.field.len or key[key.len - cfa.field.len - 1] == '_'))
                            {
                                isAsyncField = true;
                                break;
                            }
                        }
                    }
                    if (!isAsyncField and gc.type_args.len > 0 and cfa.object.kind == .ident and
                        !self.isStructType(cfa.field) and
                        (try self.resolveExpressionTypeName(cfa.object)) == null)
                    {
                        if (try self.findNamespacedSpec(cfa.object.kind.ident, cfa.field, gc.type_args)) |fn_val| {
                            const args = try self.allocator.alloc(types.LLVMValueRef, gc.args.len);
                            defer self.allocator.free(args);
                            for (gc.args, 0..) |*arg, idx| {
                                var val = try self.compileCallArgument(arg.*);
                                // Trait-widen a concrete struct arg to a trait param (see the ident path).
                                if (self.getFunctionParamType(cfa.field, idx)) |expected_type| {
                                    if (self.traits.contains(getStructBaseName(expected_type))) {
                                        if (try self.resolveExpressionTypeName(arg)) |struct_name| {
                                            if (self.structs.contains(struct_name)) {
                                                val = try self.constructTraitObject(val, struct_name, expected_type);
                                            }
                                        }
                                    }
                                }
                                args[idx] = val;
                            }
                            return try self.buildCallWithCasts(fn_val, args);
                        }
                    }
                }
                return try self.compileMethodOrNamespacedCall(gc.callee.kind.field_access, gc.args);
            }
            if (gc.callee.kind == .ident) {
                const name = gc.callee.kind.ident;
                // F1-3b: a generic constructor call `List<int>()` / `Storage<T>(n)` / `Atomic<T>()`.
                // Resolve the struct/builtin by NAME directly — never through resolveCalleeName's
                // suffix scan, which can only return a FUNCTION name and so never maps a non-struct
                // ident to a struct. `name` IS the canonical key (isStructType / the Atomic/Storage
                // eql checks look it up directly). This takes generic-container construction
                // (List/Storage/Map) off the fallback.
                // F1 module-scoped types: a colliding struct constructor `Widget()` needs the module-
                // unique struct name so it builds THIS module's constructor. The call's own typed result
                // (from the IR) already carries it — override only when that resolves to a registered
                // struct whose base differs from the bare ident (exactly the colliding case; a generic
                // container like `List<int>()` resolves to base "List" == name, so it's untouched).
                var resolved_struct_name = name;
                if (self.isCollidingStruct(name)) {
                    if (try self.resolveExpressionTypeName(&expr)) |rt| {
                        const rt_base = getStructBaseName(rt);
                        if (self.isStructType(rt_base)) resolved_struct_name = rt_base;
                    }
                    }
                if (std.mem.eql(u8, resolved_struct_name, "Atomic")) {
                    const target_type = gc.type_args[0];
                    const t_name = try self.typeRefToString(target_type);

                    const cell = self.atomicCell(t_name);
                    const size_val = core.LLVMConstInt(self.val_type, cell.size, 0);

                    // Allocate 4/8 bytes for the actual atomic value
                    const atomic_val_ptr = try self.compileAlloc(size_val);

                    // Store the initial value
                    const initial_val = try self.compileExpression(gc.args[0]);
                    const llvm_field_type = self.atomicCell(t_name).ty;
                    const casted_initial = self.castFromValType(initial_val, llvm_field_type);
                    const ptr = core.LLVMBuildIntToPtr(self.builder, atomic_val_ptr, core.LLVMPointerType(llvm_field_type, 0), "init_ptr");
                    _ = core.LLVMBuildStore(self.builder, casted_initial, ptr);

                    // Allocate Atomic struct wrapper
                    const struct_size = self.getTypeSize(ast.TypeRef{ .ident = "Atomic" }, false);
                    const struct_ptr_val = try self.compileAlloc(core.LLVMConstInt(self.val_type, struct_size, 0));

                    // Store atomic_val_ptr into Atomic.ptr (offset 0)
                    const ptr_dest = core.LLVMBuildIntToPtr(self.builder, struct_ptr_val, core.LLVMPointerType(self.ptr_type, 0), "struct_ptr_dest");
                    _ = core.LLVMBuildStore(self.builder, core.LLVMBuildIntToPtr(self.builder, atomic_val_ptr, self.ptr_type, "cast_ptr"), ptr_dest);

                    return struct_ptr_val;
                }

                // `Storage<T>(n)` — specs.md §3.8. Not a struct: Storage<T> IS the
                // buffer, so it allocates n slots and returns the pointer. The 8-byte
                // header records n*8 as the byte length, which IS the slot count
                // (/8) — no capacity field, no second source of truth.
                if (std.mem.eql(u8, resolved_struct_name, "Storage")) {
                    const n = try self.compileExpression(gc.args[0]);
                    const eight = core.LLVMConstInt(self.val_type, 8, 0);
                    const bytes_needed = core.LLVMBuildMul(self.builder, n, eight, "stg_bytes");
                    return try self.compileAllocPersistent(bytes_needed);
                }

                if (self.isStructType(resolved_struct_name)) {
                    const g_ref = ast.TypeRef{
                        .generic = .{
                            .name = resolved_struct_name,
                            .params = gc.type_args,
                        }
                    };
                    const struct_size = self.getTypeSize(g_ref, false);
                    const instance_ptr = try self.compileAlloc(core.LLVMConstInt(self.val_type, struct_size, 0));

                    var gen_name = try self.allocator.dupe(u8, resolved_struct_name);
                    for (gc.type_args) |t| {
                        const t_str = try self.typeRefToString(t);
                        const old_gen_name = gen_name;
                        gen_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ old_gen_name, t_str });
                        self.allocator.free(old_gen_name);
                    }

                    // methodSymbol → mangleTypeName is the single source of truth for a constructor
                    // symbol name; building it raw missed a module-scoped struct's init (whose owner has
                    // escaped chars, e.g. '-' → '_da'). Non-colliding names mangle to themselves.
                    const init_name = try self.methodSymbol(gen_name, "init");
                    defer self.allocator.free(init_name);
                    const new_name = try self.methodSymbol(gen_name, "new");
                    defer self.allocator.free(new_name);
                    self.allocator.free(gen_name);

                    const base_init_name = try self.methodSymbol(resolved_struct_name, "init");
                    defer self.allocator.free(base_init_name);
                    const base_new_name = try self.methodSymbol(resolved_struct_name, "new");
                    defer self.allocator.free(base_new_name);

                    // M3 (F4 mono completion) precondition: `gen_name` is built from `typeRefToString` of
                    // each type arg (`Pair_int_string`), but the MONO body is defined from the sema
                    // instantiation's `renderLegacy` (`Pair_i32_string`) — the `int`/`i32` two-renderer
                    // split makes `init_name` miss and the call fall to the ERASED `Pair_init` (A/B
                    // unresolved). Resolve the call's own instantiation type (renderLegacy) and prefer that
                    // mono symbol, so a concrete generic constructor targets its mono body and the erased
                    // one becomes suppressible.
                    var mono_init: ?[]const u8 = null;
                    if (try self.resolveExpressionTypeName(&expr)) |inst| {
                        if (!std.mem.eql(u8, getStructBaseName(inst), inst)) {
                            const mi = try self.methodSymbol(inst, "init");
                            if (self.func_map.get(mi) != null) mono_init = mi else self.allocator.free(mi);
                        }
                    }
                    defer if (mono_init) |mi| self.allocator.free(mi);

                    const fn_val_opt = (if (mono_init) |mi| self.func_map.get(mi) else null) orelse
                                       self.func_map.get(init_name) orelse
                                       self.func_map.get(new_name) orelse
                                       self.func_map.get(base_init_name) orelse
                                       self.func_map.get(base_new_name);

                    if (fn_val_opt) |fn_val| {
                        const total_args = gc.args.len + 1;
                        const args = try self.allocator.alloc(types.LLVMValueRef, total_args);
                        defer self.allocator.free(args);

                        // The init's DECLARED param types come straight from the struct decl's `init`
                        // method (`self.structs`), NOT from getFunctionParamType — whose struct-method
                        // branch walks `instantiationsOf`, which is EMPTY for a CROSS-MODULE (imported)
                        // struct, so it returned null even for the base name and the widening silently
                        // no-oped. That left a raw struct in a trait field (later dispatch reads a
                        // garbage vtable) and, for an imported actor, the `_vtable_<S>_<Trait>` was never
                        // emitted at all. Reading the decl directly is instantiation-independent.
                        const init_decl: ?*const ast.FunctionDecl = blk: {
                            const sd = self.structs.get(resolved_struct_name) orelse break :blk null;
                            for (sd.methods) |*m| {
                                if (std.mem.eql(u8, m.decl.name, "init") or std.mem.eql(u8, m.decl.name, "new")) break :blk &m.decl;
                            }
                            break :blk null;
                        };
                        args[0] = instance_ptr;
                        for (gc.args, 0..) |arg, idx| {
                            var val = try self.compileCallArgument(arg);
                            // Trait-widening — a concrete struct arg passed to a trait-typed init
                            // param must become a fat pointer, EXACTLY as the non-generic `.call`
                            // constructor path does. Without this, `Cell<int>(cnt)` stored the raw
                            // struct into a `Beh<M>` field, and the later `self.beh.recv(..)` dispatch
                            // read a garbage vtable off the struct's body → wild jump (SIGSEGV). The
                            // generic-trait FIELD (`Beh<M>`) now types as `.trait_` (lower.zig), so
                            // the field slot really is a fat pointer expecting a widened value.
                            if (init_decl) |idcl| {
                                if (idx < idcl.params.len) {
                                    if (idcl.params[idx].type_name) |trt| {
                                        const expected_type = try self.typeRefToString(trt); // transient; not freed (may alias)
                                        if (self.traits.contains(getStructBaseName(expected_type))) {
                                            if (try self.resolveExpressionTypeName(&arg)) |struct_name| {
                                                if (self.structs.contains(struct_name)) {
                                                    val = try self.constructTraitObject(val, struct_name, expected_type);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            args[idx + 1] = val;
                        }

                        _ = try self.buildCallWithCasts(fn_val, args);
                    } else {
                        try self.initDefaultContainerFields(resolved_struct_name, instance_ptr, gc.span);
                    }
                    return instance_ptr;
                }

                if (self.locals.contains(name)) {
                    // A1: indirect call on a closure value (box {fn_ptr, env}).
                    const box_val = try self.compileExpression(gc.callee.*);
                    return try self.buildClosureCall(box_val, gc.args);
                }

                const resolved_name = try self.resolveCalleeName(name);
                // FREE-FN MONOMORPHIZATION: prefer the specialized body `maybe__int` when it exists (built
                // the same way the emission loop names it — `<resolved base>__<mangled type-arg>`), so a
                // generic free fn compiles with T→concrete (value-optional returns box correctly, V1).
                // Falls back to the erased base when no spec was emitted (inferred-arg / non-generic).
                var callee_name = resolved_name;
                var spec_buf: ?[]const u8 = null;
                defer if (spec_buf) |s| self.allocator.free(s);
                if (gc.type_args.len > 0) {
                    var nb = std.ArrayListUnmanaged(u8).empty;
                    errdefer nb.deinit(self.allocator);
                    try nb.appendSlice(self.allocator, resolved_name);
                    for (gc.type_args) |ta| {
                        const rendered = try self.typeRefToString(ta);
                        const ma = try types_mod.mangleTypeName(self.allocator, rendered);
                        defer self.allocator.free(ma);
                        try nb.appendSlice(self.allocator, "__");
                        try nb.appendSlice(self.allocator, ma);
                    }
                    const cand = try nb.toOwnedSlice(self.allocator);
                    if (self.func_map.contains(cand)) {
                        spec_buf = cand;
                        callee_name = cand;
                    } else {
                        self.allocator.free(cand);
                    }
                }
                const fn_val = self.func_map.get(callee_name) orelse {
                    std.debug.print("Function '{s}' not found\n", .{callee_name});
                    return error.FunctionNotFound;
                };

                // Compile arguments (compileCallArgument applies the V1 value-optional consume-unbox).
                // TRAIT-WIDENING: a concrete struct arg passed to a TRAIT-typed param must become a fat
                // pointer {struct, vtable} — exactly as the non-generic call path does. Without it, a
                // `readId<T>(src: ValueSource)` monomorphized call receives a raw struct where the body
                // expects {ptr, vtable} → garbage vtable → SEGV on the first trait dispatch. Param types
                // come from the BASE fn (`name`); the spec shares them (only the type-params substitute).
                const args = try self.allocator.alloc(types.LLVMValueRef, gc.args.len);
                defer self.allocator.free(args);
                for (gc.args, 0..) |*arg, idx| {
                    var val = try self.compileCallArgument(arg.*);
                    if (self.getFunctionParamType(name, idx)) |expected_type| {
                        if (self.traits.contains(getStructBaseName(expected_type))) {
                            if (try self.resolveExpressionTypeName(arg)) |struct_name| {
                                if (self.structs.contains(struct_name)) {
                                    val = try self.constructTraitObject(val, struct_name, expected_type);
                                }
                            }
                        }
                    }
                    args[idx] = val;
                }

                return try self.buildCallWithCasts(fn_val, args);
            }
            return error.UnsupportedCallTarget;
        },
        .struct_init => |si| {
            if (self.findEnumByVariant(si.type_name)) |enum_name| {
                var tag: u32 = 0;
                var total_size: u32 = 0;
                try self.getEnumTagAndSize(enum_name, si.type_name, &tag, &total_size);

                const union_ptr = try self.compileAlloc(core.LLVMConstInt(self.val_type, total_size, 0));

                // Store tag
                const tag_val = core.LLVMConstInt(self.val_type, tag, 0);
                const tag_ptr = core.LLVMBuildIntToPtr(self.builder, union_ptr, core.LLVMPointerType(self.val_type, 0), "tag_ptr");
                _ = core.LLVMBuildStore(self.builder, tag_val, tag_ptr);

                // Store fields
                const enum_decl = self.enums.get(enum_name).?;
                const ptr_size = @as(u32, 8);
                for (enum_decl.variants) |v| {
                    if (std.mem.eql(u8, v.name, si.type_name)) {
                        if (v.fields) |payload_fields| {
                            for (si.fields) |f_init| {
                                for (payload_fields, 0..) |pf, idx| {
                                    if (std.mem.eql(u8, f_init.name, pf.name)) {
                                        const f_val = try self.compileExpression(f_init.value);
                                        const pf_type_str = try self.typeRefToString(pf.type_name);
                                        // F5-2: declared payload-field type lowered to a TypeId; `pf_type_str` is the fallback.
                                        // The box takes ownership so `__destruct_<Enum>` can release: retain an
                                        // r-var, consume a fresh temp (else the drain frees it early).
                                        if (self.isOwnedDeclaredType(pf.type_name, pf_type_str)) {
                                            try self.takeOwnedElement(f_init.value.kind, f_val);
                                        }
                                        const offset = core.LLVMConstInt(self.val_type, ptr_size + idx * ptr_size, 0);
                                        const addr = core.LLVMBuildAdd(self.builder, union_ptr, offset, "payload_addr");
                                        const dest_ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "payload_ptr");
                                        _ = core.LLVMBuildStore(self.builder, f_val, dest_ptr);
                                        break;
                                    }
                                }
                            }
                        }
                        break;
                    }
                }

                return union_ptr;
            }

            if (self.unions.get(si.type_name)) |u| {
                var max_size = self.getTypeSize(ast.TypeRef{ .ident = si.type_name }, false);
                if (max_size == 0) max_size = 8;
                const size_val = core.LLVMConstInt(self.val_type, max_size, 0);
                const union_ptr_val = try self.compileAlloc(size_val);
                for (si.fields) |f_init| {
                    var field_type_ref = ast.TypeRef{ .ident = "i32" };
                    for (u.fields) |f| {
                        if (std.mem.eql(u8, f.name, f_init.name)) {
                            field_type_ref = f.type_name;
                            break;
                        }
                    }
                    const field_val = try self.compileExpression(f_init.value);
                    const f_type_str = try self.typeRefToString(field_type_ref);
                    // F5-2: declared field type lowered to a TypeId; `f_type_str` is the fallback.
                    // F5 O4 (see the struct arm above for the full rationale): retain a BORROWED field,
                    // consume a FRESH one. Blanket-retain leaked non-temp struct-literal fields;
                    // is_r_var-only use-after-freed constructor-temp fields.
                    if (self.isOwnedDeclaredType(field_type_ref, f_type_str)) {
                        try self.takeOwnedElement(f_init.value.kind, field_val);
                    }
                    const llvm_field_type = self.toLLVMType(field_type_ref);
                    const ptr = core.LLVMBuildIntToPtr(self.builder, union_ptr_val, core.LLVMPointerType(llvm_field_type, 0), "union_field_ptr");
                    const casted_field_val = self.castFromValType(field_val, llvm_field_type);
                    _ = core.LLVMBuildStore(self.builder, casted_field_val, ptr);
                }
                return union_ptr_val;
            }

            const s = self.structs.get(si.type_name) orelse {
                return error.StructNotFound;
            };
            const total_size = self.getTypeSize(ast.TypeRef{ .ident = si.type_name }, false);
            const size_val = core.LLVMConstInt(self.val_type, total_size, 0);

            // Allocate struct on heap
            const struct_ptr_val = try self.compileAlloc(size_val);

            // Initialize fields
            for (si.fields) |f_init| {
                const offset = try self.getFieldOffset(si.type_name, f_init.name);
                const offset_val = core.LLVMConstInt(self.val_type, offset, 0);
                var field_val = try self.compileExpression(f_init.value);

                var field_type_ref = ast.TypeRef{ .ident = "i32" };
                for (s.fields) |f| {
                    if (std.mem.eql(u8, f.name, f_init.name)) {
                        field_type_ref = f.type_name;
                        break;
                    }
                }

                const f_type_str = try self.typeRefToString(field_type_ref);

                // Widen a struct field value to the trait object when the field's declared type is a
                // trait (`Holder{ g: A{} }` where `g: G`). Sema does not retype the literal here, so
                // codegen widens with the same discipline as the let / tuple-element paths: CONSUME the
                // struct's own construction temp (else the statement drain frees it a 2nd time → UAF) and
                // the fat-pointer temp (the struct field owns it, released by the struct destructor), then
                // release the struct's orphaned construction ref. Without this a raw struct sits in the
                // trait field slot → garbage vtable → SEGV. Field init from an ALREADY-trait value
                // (`Holder{ g: x }`, x: G) skips this (resolveExpressionTypeName is not a struct name).
                var widened_field = false;
                if (field_type_ref == .ident and self.traits.contains(field_type_ref.ident)) {
                    if (try self.resolveExpressionTypeName(&f_init.value)) |st_name| {
                        if (self.structs.contains(st_name)) {
                            const orig = field_val;
                            self.consumeTemporary(orig);
                            field_val = try self.constructTraitObject(orig, st_name, field_type_ref.ident);
                            self.consumeTemporary(field_val);
                            // Stage 5 Phase B: store-native dtor via the same-symbol gate.
                            const stid: ?sema_types.TypeId = if (self.typed_ir) |ir| ir.typeOf(&f_init.value) else null;
                            const sdtor = try self.getOrCreateDestructorPreferId(st_name, stid);
                            try self.compileRelease(orig, sdtor);
                            widened_field = true;
                        }
                    }
                }
                // F5-2: declared field type lowered to a TypeId; `f_type_str` is the fallback.
                //
                // F5 O4 "aggregate takes ownership" — the struct needs exactly ONE owning reference to
                // an owned field, and how to get it depends on what the field value IS:
                //   * a BORROWED value (an existing variable: ident / field_access / index) is owned
                //     elsewhere, so the struct must RETAIN to make its own reference (rc+1; the owner
                //     and the struct destructor each release later, balanced).
                //   * a FRESH owned value (a constructor call `List<string>()`, a nested struct literal
                //     `Inner{...}`) already carries one reference the struct can just TAKE. If it is a
                //     drainable pending TEMPORARY (a constructor result), CONSUMING it removes it from
                //     the end-of-statement drain so the struct's field keeps the sole reference (rc 1,
                //     destructor -> 0). If it is NOT a drainable temp (a struct literal), consume is a
                //     no-op and the reference transfers untouched (rc 1, destructor -> 0).
                // Both fresh cases need NO retain. The earlier `is_r_var`-only guard left the
                // constructor-temp case unowned -> the drain freed it under the field -> use-after-free
                // (m1: Bag{items: List()}); a blanket retain then LEAKED the non-temp struct-literal
                // case (rc stuck at 1: retain 2, no drain, destructor 1). Consuming the temp in the
                // fresh branch is the single rule that balances all three. The corpus tripped neither
                // (it builds fields via `init(){ self.x = List() }`), so both bugs hid behind a green
                // --asan/--arc gate — see conformance/cases/41 and 42.
                if (!widened_field and self.isOwnedDeclaredType(field_type_ref, f_type_str)) {
                    try self.takeOwnedElement(f_init.value.kind, field_val);
                }

                const addr = core.LLVMBuildAdd(self.builder, struct_ptr_val, offset_val, "field_addr");
                const llvm_field_type = self.toLLVMType(field_type_ref);
                const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(llvm_field_type, 0), "field_ptr");
                const casted_field_val = self.castFromValType(field_val, llvm_field_type);
                _ = core.LLVMBuildStore(self.builder, casted_field_val, ptr);
            }

            return struct_ptr_val;
        },
        .field_access => |fa| {
            if (fa.object.kind == .ident) {
                const obj_name = fa.object.kind.ident;
                if (self.enums.get(obj_name)) |enum_decl| {
                    var is_tagged = false;
                    for (enum_decl.variants) |v| {
                        if (v.type_name != null or v.fields != null) {
                            is_tagged = true;
                            break;
                        }
                    }

                    if (is_tagged) {
                        var tag: u32 = 0;
                        var total_size: u32 = 0;
                        try self.getEnumTagAndSize(obj_name, fa.field, &tag, &total_size);

                        const union_ptr = try self.compileAlloc(core.LLVMConstInt(self.val_type, total_size, 0));

                        // Store tag
                        const tag_val = core.LLVMConstInt(self.val_type, tag, 0);
                        const tag_ptr = core.LLVMBuildIntToPtr(self.builder, union_ptr, core.LLVMPointerType(self.val_type, 0), "tag_ptr");
                        _ = core.LLVMBuildStore(self.builder, tag_val, tag_ptr);

                        return union_ptr;
                    } else {
                        for (enum_decl.variants, 0..) |v, idx| {
                            if (std.mem.eql(u8, v.name, fa.field)) {
                                const val = v.value orelse @as(i64, @intCast(idx));
                                return core.LLVMConstInt(self.val_type, @intCast(val), 0);
                            }
                        }
                    }
                }

                // F2: module-qualified constant access — `webview.HINT_FIXED`. When the object
                // is a MODULE namespace (not a value/variable) and the field names a known
                // `pub const`, resolve to that constant. Guarded on `!identNamesVariable` so a
                // genuine struct-field read (`someVar.field`) is never hijacked.
                if (!self.identNamesVariable(obj_name)) {
                    if (self.constants.get(fa.field)) |val| {
                        return try self.compileExpression(val);
                    }
                }
            }

            // If accessing a function, return its function pointer (or index).
            //
            // #6/#7: only a **module namespace** can name a function here
            // (`string.hash`). If the object is a *variable*, `x.field` is a field
            // read and nothing else — even when some global fn happens to share the
            // field's name. Without this guard the flat namespace (§10 #7) leaked
            // into field access: `f.payload` on a `Frame` resolved to a user
            // `fn payload` via the `func_map.get(fa.field)` fallback below, so the
            // btree driver parsed a *function address* as a string — `s.length` read
            // instruction bytes as a length, and `string_slice` then read wild. That
            // was misfiled for months as "string heap corruption" (§8); the heap was
            // never corrupt.
            const obj_is_variable = fa.object.kind == .ident and
                self.identNamesVariable(fa.object.kind.ident);
            if (fa.object.kind == .ident and !obj_is_variable) {
                const mod_name = fa.object.kind.ident;
                const full_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, fa.field });
                defer self.allocator.free(full_name);
                var fn_val_opt: ?types.LLVMValueRef = self.func_map.get(full_name) orelse self.func_map.get(fa.field);
                if (fn_val_opt == null) {
                    var iter = self.func_map.iterator();
                    while (iter.next()) |entry| {
                        const key = entry.key_ptr.*;
                        const suffix_len = full_name.len + 1;
                        if (key.len >= suffix_len) {
                            const suffix = key[key.len - suffix_len..];
                            if (suffix[0] == '_' and std.mem.eql(u8, suffix[1..], full_name)) {
                                fn_val_opt = entry.value_ptr.*;
                                break;
                            }
                        }
                    }
                }
                if (fn_val_opt) |fn_val| {
                    // #18: `string.hash` as a value is boxed like any closure.
                    return try self.buildBareFnBox(fn_val);
                }
            }

            // If field is length/len
            if (std.mem.eql(u8, fa.field, "length") or std.mem.eql(u8, fa.field, "len")) {
                const obj_type = try self.resolveExpressionTypeName(fa.object);
                const is_struct = if (obj_type) |name| self.isStructType(name) else false;
                if (!is_struct) {
                    // String length: load 4-byte i32 from str - 4
                    const str_ptr = try self.compileExpression(fa.object.*);
                    // §3.4/P2-14: `.length` on an ABSENT string optional read from `0 - 4` → raw crash.
                    // The struct-field path below guards; this builtin early-return skipped it. Guard
                    // here too so `let s = xs.get(i); s.length` traps with the located "narrow it first"
                    // message instead of crashing unguarded. No-op when `fa.object` is not optional.
                    try self.guardOptionalDeref(fa.object, str_ptr, fa.span);
                    const offset = core.LLVMConstInt(self.val_type, 4, 0);
                    const addr = core.LLVMBuildSub(self.builder, str_ptr, offset, "len_addr");
                    const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "len_ptr");
                    const len_val = core.LLVMBuildLoad2(self.builder, self.i32_type, ptr, "len_val");
                    return core.LLVMBuildZExt(self.builder, len_val, self.val_type, "len_val_ext");
                }
            }

            // If field is Result ok/value/error checks. Gate on the object NOT being a
            // struct (mirroring the .value/.length cases below/above), so a user struct
            // with an `ok`/`error` field accesses its real field instead of the Result
            // sugar constant. (`error` is a very common field name.)
            if (std.mem.eql(u8, fa.field, "ok")) {
                const obj_type = try self.resolveExpressionTypeName(fa.object);
                const is_struct = if (obj_type) |name| self.isStructType(name) else false;
                if (!is_struct) {
                    return core.LLVMConstInt(self.val_type, 1, 0);
                }
            }
            if (std.mem.eql(u8, fa.field, "error")) {
                const obj_type = try self.resolveExpressionTypeName(fa.object);
                const is_struct = if (obj_type) |name| self.isStructType(name) else false;
                if (!is_struct) {
                    return core.LLVMConstInt(self.val_type, 0, 0);
                }
            }
            if (std.mem.eql(u8, fa.field, "value")) {
                const obj_type = try self.resolveExpressionTypeName(fa.object);
                const is_struct = if (obj_type) |name| self.isStructType(name) else false;
                if (!is_struct) {
                    return try self.compileExpression(fa.object.*);
                }
            }

            // Normal struct field access
            const obj_ptr = try self.compileExpression(fa.object.*);
            // §3.4/P2-14: if `fa.object` is an optional, trap on `undefined` instead of reading
            // a field through address 0. No-op for a plain struct.
            try self.guardOptionalDeref(fa.object, obj_ptr, fa.span);
            const obj_type = try self.resolveExpressionTypeName(fa.object) orelse {
                return error.StructTypeNotFound;
            };

            const base_struct = getStructBaseName(obj_type);
            var field_type_ref = ast.TypeRef{ .ident = "i32" };
            if (self.structs.get(base_struct)) |s| {
                for (s.fields) |field| {
                    if (std.mem.eql(u8, field.name, fa.field)) {
                        field_type_ref = field.type_name;
                        break;
                    }
                }
            } else if (self.unions.get(base_struct)) |u| {
                for (u.fields) |field| {
                    if (std.mem.eql(u8, field.name, fa.field)) {
                        field_type_ref = field.type_name;
                        break;
                    }
                }
            }

            const offset = try self.getFieldOffset(obj_type, fa.field);
            const offset_val = core.LLVMConstInt(self.val_type, offset, 0);
            const addr = core.LLVMBuildAdd(self.builder, obj_ptr, offset_val, "field_addr");
            const llvm_field_type = self.toLLVMType(field_type_ref);
            const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(llvm_field_type, 0), "field_ptr");
            const raw_val = core.LLVMBuildLoad2(self.builder, llvm_field_type, ptr, "field_val");
            return self.castToValType(raw_val, field_type_ref);
        },
        .closure => |cl| {
            // F4 4b: resolve the lambda for THIS instantiation. Inside
            // `Map_string_i32_keys` that is the copy compiled with K = string, whose
            // `result.push(k)` binds to `List_string_push` (which retains) rather than
            // the erased `List_push` (which does not).
            //
            // Falls back to the erased lambda when there is no instantiation-specific
            // one — a closure in an ordinary function has only the `null` key.
            const ckey = try self.closureKey(cl.span, self.current_instantiation);
            defer self.allocator.free(ckey);
            const lambda_name = self.closure_lambdas.get(ckey) orelse blk: {
                const base_key = try self.closureKeyM(cl.span, null, null);
                defer self.allocator.free(base_key);
                break :blk self.closure_lambdas.get(base_key) orelse return error.LambdaNotFound;
            };
            const fn_val = self.func_map.get(lambda_name) orelse return error.LambdaValueNotFound;
            const fn_ptr_int = core.LLVMBuildPtrToInt(self.builder, fn_val, self.val_type, "lambda_ptr_int");

            const es = self.valSlotSize();
            // Build the environment: snapshot each captured variable's CURRENT
            // value into a per-instance heap struct (persistent so returned
            // closures outlive the creating frame).
            var env_int = core.LLVMConstInt(self.val_type, 0, 0);
            if (self.lambda_captures.get(lambda_name)) |caps| {
                if (caps.items.len > 0) {
                    const env_size = core.LLVMConstInt(self.val_type, caps.items.len * es, 0);
                    env_int = try self.compileAllocPersistent(env_size);
                    for (caps.items, 0..) |cap, i| {
                        const cap_val = try self.compileExpression(ast.Expression{ .kind = .{ .ident = cap } });
                        // §3.4j O4 "capture into closure env | retain (env becomes an
                        // owner)". Without this the env holds a BORROW: when the creating
                        // scope releases the captured variable, the closure's slot dangles
                        // — measured as a use-after-free, not a leak (a returned closure
                        // over `string.concat(..)` gave back garbage). The corpus only
                        // passed because it captures string LITERALS (sentinel refcount,
                        // never freed). Retained here, released by `__destruct_closure`.
                        if (self.current_local_types) |lt| {
                            if (lt.get(cap)) |ct| {
                                if (self.isOwnedLocal(cap, ct)) try self.compileRetain(cap_val);
                            }
                        }
                        const off = core.LLVMConstInt(self.val_type, i * es, 0);
                        const addr = core.LLVMBuildAdd(self.builder, env_int, off, "env_init_addr");
                        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "env_init_ptr");
                        _ = core.LLVMBuildStore(self.builder, cap_val, ptr);
                    }
                }
            }

            // §3.4j inc4: a per-lambda CLEANUP fn that releases the env's refcounted
            // captures. Stored in the box so the GENERIC `__destruct_closure` (looked up
            // by function TYPE, which cannot know per-lambda captures) can call it. 0
            // when nothing captured is ref-counted. Only heap closures reach
            // `__destruct_closure` (a global fnbox has the 100M sentinel refcount), so
            // only heap boxes carry this third slot.
            const cleanup_int = try buildClosureCleanup(self, lambda_name, cl.span);

            // Build the closure box {fn_ptr @0, env @8, cleanup @16}; the box pointer IS
            // the value. Callers of the closure read only fn@0/env@8, unchanged.
            const box_size = core.LLVMConstInt(self.val_type, 3 * es, 0);
            const box_int = try self.compileAllocPersistent(box_size);
            const box_ptr0 = core.LLVMBuildIntToPtr(self.builder, box_int, self.ptr_type, "box_ptr0");
            _ = core.LLVMBuildStore(self.builder, fn_ptr_int, box_ptr0);
            const off1 = core.LLVMConstInt(self.val_type, es, 0);
            const addr1 = core.LLVMBuildAdd(self.builder, box_int, off1, "box_addr1");
            const box_ptr1 = core.LLVMBuildIntToPtr(self.builder, addr1, self.ptr_type, "box_ptr1");
            _ = core.LLVMBuildStore(self.builder, env_int, box_ptr1);
            const off2 = core.LLVMConstInt(self.val_type, 2 * es, 0);
            const addr2 = core.LLVMBuildAdd(self.builder, box_int, off2, "box_addr2");
            const box_ptr2 = core.LLVMBuildIntToPtr(self.builder, addr2, self.ptr_type, "box_ptr2");
            _ = core.LLVMBuildStore(self.builder, cleanup_int, box_ptr2);
            return box_int;
        },
        .index => |idx| {
            const obj_ptr = try self.compileExpression(idx.object.*);
            // §3.4/P2-14: indexing an ABSENT optional (`let s = xs.get(i); s[0]`) read from address 0 →
            // raw crash. Guard it like the struct-field and `.length` paths, so it traps with the
            // located "narrow it first" message. No-op when `idx.object` is not optional.
            try self.guardOptionalDeref(idx.object, obj_ptr, idx.span);
            var offset_val = try self.compileExpression(idx.index.*);

            const obj_type = try self.resolveExpressionTypeName(idx.object);
            const is_string = if (obj_type) |t| std.mem.eql(u8, t, "string") else false;

            if (is_string) {
                const addr = core.LLVMBuildAdd(self.builder, obj_ptr, offset_val, "index_addr");
                const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "index_ptr");
                const byte_val = core.LLVMBuildLoad2(self.builder, self.i8_type, ptr, "byte_val");
                return core.LLVMBuildZExt(self.builder, byte_val, self.val_type, "byte_val_ext");
            } else {
                const element_size: usize = 8;
                const el_size_val = core.LLVMConstInt(self.val_type, element_size, 0);
                offset_val = core.LLVMBuildMul(self.builder, offset_val, el_size_val, "index_offset_mul");

                const addr = core.LLVMBuildAdd(self.builder, obj_ptr, offset_val, "index_addr");
                const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "index_ptr");
                return core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "index_val");
            }
        },
        .tuple => |tuple_exprs| {
            const element_size: usize = 8;
            const size_val = core.LLVMConstInt(self.val_type, tuple_exprs.len * element_size, 0);

            // Allocate tuple on heap
            const tuple_ptr_val = try self.compileAlloc(size_val);

            // Initialize tuple elements.
            //
            // F5 O4 "store-to-field | the aggregate takes ownership": the box RETAINS each
            // ref-counted element, exactly as a struct's field store does. Previously it stored
            // each word RAW and owned nothing, so a returned tuple pointed at elements its callee
            // had already freed — patched over by a retain at the RETURN boundary (statements.zig),
            // which was guarded syntactically on `v.kind == .tuple` and so only fired for a tuple
            // LITERAL in return position: `let t = (k,v); return t;` was still a use-after-free.
            // Owning at construction fixes both, and is what the tuple destructor balances against.
            for (tuple_exprs, 0..) |te, idx| {
                const offset = core.LLVMConstInt(self.val_type, idx * element_size, 0);
                var val = try self.compileExpression(te);
                // Widen a struct element to the trait object when the tuple's element type is a trait
                // (`(1, A{}): (int, G)` — sema types the element AS the trait via contextual typing).
                // Mirrors the let/assignment widening: consume the fresh fat pointer (the tuple box
                // owns it, released by __destruct_tuple) and release the struct's orphaned construction
                // ref. Without this a raw struct sits in the trait slot → garbage vtable → SEGV.
                var widened = false;
                if (self.tupleElemTraitName(&expr, idx)) |trait_name| {
                    if (try self.resolveExpressionTypeName(&tuple_exprs[idx])) |st_name| {
                        if (self.structs.contains(st_name)) {
                            const orig = val;
                            // Consume the STRUCT's own construction temporary BEFORE widening:
                            // otherwise the statement drain releases it a SECOND time (the manual
                            // release below is the only one it should get) — freeing A inside the
                            // producer while the trait object in the tuple still points at it (UAF).
                            // Mirrors the let-widening discipline (statements.zig), where the struct
                            // temp was already consumed by the single-binding consume before widening.
                            self.consumeTemporary(orig);
                            val = try self.constructTraitObject(orig, st_name, trait_name);
                            self.consumeTemporary(val);
                            // Stage 5 Phase B: store-native dtor via the same-symbol gate.
                            const stid: ?sema_types.TypeId = if (self.typed_ir) |ir| ir.typeOf(&tuple_exprs[idx]) else null;
                            const sdtor = try self.getOrCreateDestructorPreferId(st_name, stid);
                            try self.compileRelease(orig, sdtor);
                            widened = true;
                        }
                    }
                }
                // F5-2 / F5 O4: the tuple box takes ownership of each managed element (decided via the
                // store). Retain a BORROWED element, consume a FRESH one — the shared store-into-
                // aggregate move/dup rule in `takeOwnedElement` (same as the struct field-store).
                // Blanket-retaining leaked non-temp struct-literal elements; see conformance/cases/42.
                if (!widened and self.isOwnedExpr(&tuple_exprs[idx])) {
                    try self.takeOwnedElement(te.kind, val);
                }
                const addr = core.LLVMBuildAdd(self.builder, tuple_ptr_val, offset, "tuple_elem_addr");
                const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "tuple_elem_ptr");
                _ = core.LLVMBuildStore(self.builder, val, ptr);
            }

            return tuple_ptr_val;
        },
        // specs §3.4b: `try f()` — if f returned the ERROR side, return that box unchanged from
        // the enclosing function; otherwise yield the unwrapped ok payload.
        //
        // Returning the box UNCHANGED (rather than rebuilding it) is what makes propagation
        // cheap and keeps the error's payload — and its ownership — untouched on the way up.
        .try_expr => |inner| {
            const box = try self.compileExpression(inner.*);
            const word: usize = 8;
            const cur_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));

            const tag_ptr = core.LLVMBuildIntToPtr(self.builder, box, core.LLVMPointerType(self.val_type, 0), "try_tag_ptr");
            const tag = core.LLVMBuildLoad2(self.builder, self.val_type, tag_ptr, "try_tag");
            const is_err = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, tag, core.LLVMConstInt(self.val_type, 1, 0), "try_is_err");

            const prop_bb = core.LLVMAppendBasicBlock(cur_fn, "try_propagate");
            const cont_bb = core.LLVMAppendBasicBlock(cur_fn, "try_ok");
            _ = core.LLVMBuildCondBr(self.builder, is_err, prop_bb, cont_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, prop_bb);
            // E1: a `try` that PROPAGATES is an error-path return — fire the active errdefers first.
            try self.runErrdefers();
            _ = core.LLVMBuildRet(self.builder, box);

            core.LLVMPositionBuilderAtEnd(self.builder, cont_bb);
            const pay_addr = core.LLVMBuildAdd(self.builder, box, core.LLVMConstInt(self.val_type, @intCast(word), 0), "try_pay_addr");
            const pay_ptr = core.LLVMBuildIntToPtr(self.builder, pay_addr, core.LLVMPointerType(self.val_type, 0), "try_pay_ptr");
            const payload = core.LLVMBuildLoad2(self.builder, self.val_type, pay_ptr, "try_pay");
            // The box OWNS its payload (buildErrUnion retained it; __destruct_ErrUnion releases it when
            // the box temp drains at statement end). Extracting the ok payload here takes a reference
            // OUT of the box, so RETAIN it — the yielded value now has its own owner (a `let`, or the
            // statement drain). Register it as a temporary EXACTLY ONCE, here, with the payload type.
            //
            // ⚠️ `.try_expr` is deliberately `.borrowed` in `acquisitionDisposition` (see it): if it
            // were owned, the wrapper would auto-register this SAME payload a SECOND time, and `let r = try f()` would
            // consume one registration while the other DRAINED — one release too many. Combined with the
            // box's __destruct and the local's scope-exit, that over-released an owned payload (probe 04
            // / 14min): a genuine double-free (a UAF under --asan) that the old return-path band-aid
            // masked by leaking the box instead. One retain, one registration, and the box owns-then-
            // frees its copy — balanced. (F5, task #14, 2026-07-19.)
            if (self.errUnionParts(try self.resolveExpressionTypeName(inner) orelse "")) |pp| {
                defer self.allocator.free(pp.ok);
                defer self.allocator.free(pp.err);
                if (self.isOwnedErrUnionOk(inner, pp.ok)) {
                    try self.compileRetain(payload);
                    try registerTemporary(self, payload, try self.allocator.dupe(u8, pp.ok));
                }
            }
            return payload;
        },
        // `f() catch h` / `f() catch (e) h` — the failure-side twin of `??`.
        //
        // Spilled to a SLOT rather than phi'd on the SSA values: the handler may be a block that
        // diverges (`return`), so the two paths do not always merge — and a phi over a value born
        // in a branch that did not run fails LLVM verification outright ("Instruction does not
        // dominate all uses"), which is the same trap the temporary rule hit (F5 §3.4c).
        .catch_expr => |ce| {
            const box = try self.compileExpression(ce.expr.*);
            const word: usize = 8;
            const cur_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
            const slot = try spillTemp(self, core.LLVMConstInt(self.val_type, 0, 0));

            const tag_ptr = core.LLVMBuildIntToPtr(self.builder, box, core.LLVMPointerType(self.val_type, 0), "c_tag_ptr");
            const tag = core.LLVMBuildLoad2(self.builder, self.val_type, tag_ptr, "c_tag");
            const is_err = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, tag, core.LLVMConstInt(self.val_type, 1, 0), "c_is_err");
            const pay_addr = core.LLVMBuildAdd(self.builder, box, core.LLVMConstInt(self.val_type, @intCast(word), 0), "c_pay_addr");
            const pay_ptr = core.LLVMBuildIntToPtr(self.builder, pay_addr, core.LLVMPointerType(self.val_type, 0), "c_pay_ptr");

            var parts_ok_refcounted = false;
            var parts_err_refcounted = false;
            if (self.errUnionParts(try self.resolveExpressionTypeName(ce.expr) orelse "")) |pp| {
                defer self.allocator.free(pp.ok);
                defer self.allocator.free(pp.err);
                parts_ok_refcounted = self.isOwnedErrUnionOk(ce.expr, pp.ok);
                parts_err_refcounted = self.isOwnedErrUnionErr(ce.expr, pp.err);
            }
            const err_bb = core.LLVMAppendBasicBlock(cur_fn, "catch_err");
            const ok_bb = core.LLVMAppendBasicBlock(cur_fn, "catch_ok");
            const done_bb = core.LLVMAppendBasicBlock(cur_fn, "catch_done");
            _ = core.LLVMBuildCondBr(self.builder, is_err, err_bb, ok_bb);

            // error path: bind `e` to the UNWRAPPED error (a plain enum, so `switch (e)` works).
            //
            // The slot is created HERE. `e` is not a `let`, and the local collectors walk
            // STATEMENTS — `catch` is an expression, so nothing ever allocated it and the handler
            // died with "Identifier 'e' not found". Its TYPE is registered too: without that, `e`
            // is untyped and `"msg: " + e` stringifies the pointer — the `4299572560` bug, which
            // is the `8472` bug, which is this whole feature's reason for existing.
            core.LLVMPositionBuilderAtEnd(self.builder, err_bb);
            if (ce.err_name) |n| {
                var alloca_val = self.locals.get(n);
                if (alloca_val == null) {
                    const entry_bb = core.LLVMGetEntryBasicBlock(cur_fn);
                    const cur = core.LLVMGetInsertBlock(self.builder);
                    if (core.LLVMGetFirstInstruction(entry_bb)) |first| {
                        core.LLVMPositionBuilderBefore(self.builder, first);
                    } else core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
                    const nz = try self.allocator.dupeZ(u8, n);
                    defer self.allocator.free(nz);
                    const a = core.LLVMBuildAlloca(self.builder, self.val_type, nz.ptr);
                    _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.val_type, 0, 0), a);
                    core.LLVMPositionBuilderAtEnd(self.builder, cur);
                    try self.locals.put(try self.allocator.dupe(u8, n), a);
                    alloca_val = a;
                    if (self.errUnionParts(try self.resolveExpressionTypeName(ce.expr) orelse "")) |pp| {
                        defer self.allocator.free(pp.ok);
                        defer self.allocator.free(pp.err);
                        if (self.current_local_types) |lt| {
                            try lt.put(try self.allocator.dupe(u8, n), try self.allocator.dupe(u8, pp.err));
                        }
                    }
                }
                const err_val = core.LLVMBuildLoad2(self.builder, self.val_type, pay_ptr, "c_err");
                // The err payload belongs to the box (which drains) — the binding `e` needs its OWN
                // reference, exactly as the ok path retains below. Without this an OWNED err payload
                // (e.g. a payload-carrying enum, now that enums are owned) is released twice: once by
                // `__destruct_ErrUnion` and once by `e`'s scope-exit — a use-after-free (33_error_union).
                if (parts_err_refcounted) try self.compileRetain(err_val);
                _ = core.LLVMBuildStore(self.builder, err_val, alloca_val.?);
            }
            const hv = try self.compileExpression(ce.handler.*);
            if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) == null) {
                _ = core.LLVMBuildStore(self.builder, self.coerceToSlotType(hv, self.val_type), slot);
                _ = core.LLVMBuildBr(self.builder, done_bb);
            }

            core.LLVMPositionBuilderAtEnd(self.builder, ok_bb);
            const okv = core.LLVMBuildLoad2(self.builder, self.val_type, pay_ptr, "c_pay");
            // ok path: the payload belongs to the box (which drains) — retain, as `try` does.
            if (parts_ok_refcounted) try self.compileRetain(okv);
            _ = core.LLVMBuildStore(self.builder, okv, slot);
            _ = core.LLVMBuildBr(self.builder, done_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
            const result = core.LLVMBuildLoad2(self.builder, self.val_type, slot, "catch_val");
            // F5 §3.4c, the `??` rule: this SELECTS a value rather than making one, so it takes
            // over its operands' temporaries — otherwise `let m = f() catch (e) reason(e);`
            // consumes the LOADED SLOT (a different SSA value) and the drain frees `reason(e)`'s
            // string out from under `m`. `??` yields a phi and hit this exact trap; the slot here
            // is the same shape.
            self.consumeTemporary(hv);
            return result;
        },
        .nullish_coalesce => |nc| {
            const current_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
            // A7 / F3 §5 stage 4: the null check and the phi are on the i64 ABI word.
            // A float operand now arrives as a real `double`; reinterpret it to i64 bits
            // here (the merge is a boundary) so the ICmp and the phi stay well-typed.
            // A no-op for the refcounted pointers the ownership logic below tracks.
            const left_val = self.coerceToSlotType(try self.compileExpression(nc.left.*), self.val_type);
            // V1 value-optional boxing (CONSUME): when the left is a value-type optional (`int?`, …)
            // it is a BOXED pointer. The null-check below (`left_val != 0`) still decides present vs
            // absent, but the phi must carry the UNBOXED value on the present edge — `left_present`.
            // A present box is non-null, so unboxing here (in left_bb, before the branch) is always on
            // a real box on the taken edge; `nova_valopt_unbox(0)` returns 0 harmlessly on the other.
            // The box's OWN lifetime is untouched: a fresh producer box (`m.get(k) ?? d`) stays on the
            // statement drain and is freed at statement end (value already extracted); a borrowed box
            // (`x ?? d`) is owned by its local. So the pointer-ownership dance below is SKIPPED for a
            // value-optional (the phi is a non-owned prim, not the box).
            const nc_is_valopt = self.exprYieldsValoptBox(nc.left);
            const left_present = if (nc_is_valopt) try self.buildValoptUnbox(left_val) else left_val;
            const left_bb_end = core.LLVMGetInsertBlock(self.builder);

            const rhs_bb = core.LLVMAppendBasicBlock(current_fn, "nc_rhs");
            const merge_bb = core.LLVMAppendBasicBlock(current_fn, "nc_merge");

            const cond_i1 = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, left_val, core.LLVMConstInt(self.val_type, 0, 0), "is_not_null");
            _ = core.LLVMBuildCondBr(self.builder, cond_i1, merge_bb, rhs_bb);

            // Compile RHS branch
            core.LLVMPositionBuilderAtEnd(self.builder, rhs_bb);
            var rhs_val = self.coerceToSlotType(try self.compileExpression(nc.right.*), self.val_type);
            // If the coalesce result is a TRAIT (the left operand's type, e.g. `map.get(k): Greeter`)
            // but the default is a bare STRUCT (`?? Ada{}`), widen the default to the trait object —
            // otherwise selecting it yields a raw struct whose first words are read as {ptr, vtable}
            // → garbage vtable → SEGV. This is ONLY the default-operand widening; it does not touch
            // the general `??` ownership (short-circuit means the widened box is built only when the
            // default is actually selected, so no leak when the left survives).
            if (try self.resolveExpressionTypeName(nc.left)) |lt| {
                if (self.traits.contains(lt)) {
                    if (try self.resolveExpressionTypeName(nc.right)) |rt| {
                        if (self.structs.contains(rt)) {
                            rhs_val = try self.constructTraitObject(rhs_val, rt, lt);
                        }
                    }
                }
            }
            // A1 FIX: a BORROWED-owner default (`?? d`, d an ident/field/index naming an existing owner)
            // must be retained HERE, in rhs_bb, where rhs_val is defined and this block runs ONLY when the
            // default is selected. Emitting it at the merge (as the left retain safely can, since left_val
            // dominates the merge and retain(0) is a no-op on the null-and-take-rhs edge) fails LLVM
            // dominance — rhs_val is undefined on the left-survived edge — AND would wrongly retain the
            // default when the left survived. A FRESH producer default is consumed at the merge instead.
            if (!nc_is_valopt and namesExistingOwner(nc.right.kind) and self.isOwnedExpr(nc.right)) {
                try self.compileRetain(rhs_val);
            }
            _ = core.LLVMBuildBr(self.builder, merge_bb);
            const rhs_bb_end = core.LLVMGetInsertBlock(self.builder);

            // Merge block
            core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
            const phi = core.LLVMBuildPhi(self.builder, self.val_type, "nc_phi");
            var incoming_vals = [_]types.LLVMValueRef{ left_present, rhs_val };
            var incoming_bbs = [_]types.LLVMBasicBlockRef{ left_bb_end, rhs_bb_end };
            core.LLVMAddIncoming(phi, &incoming_vals, &incoming_bbs, 2);

            // F5 §3.4b: OWNERSHIP FLOWS THROUGH THE PHI. `a ?? b` yields whichever
            // operand survived, so this expression TAKES OVER their temporaries — and
            // the wrapper then registers the phi as the temporary in their place
            // (`acquisitionDisposition` treats `.nullish_coalesce` as owned).
            //
            // Leaving the operands registered is a DOUBLE RELEASE, because the phi is a
            // different SSA value from either operand: `let i0 = o.items.get(0) ?? Item()`
            // binds i0 to the PHI, so `let`'s consume misses `get`'s temporary, which is
            // then released at the statement's end while i0 releases the same object at
            // scope exit. Measured: exactly this, on 13_serde's test_list_of_structs,
            // an Item `{sku, qty=5}` released twice.
            // PER-EDGE ownership (mirror the if-expr fix): the phi is the OWNED result, so each
            // operand must contribute exactly one owned reference. A FRESH producer temp is MOVED
            // (consume). A BORROWED-owned operand (ident/field/index naming an existing owner) is
            // RETAINED — else the phi releases a reference it never acquired while the owner also
            // releases it: the `let h = m.get(); (h ?? d)` double-free on a struct/trait value
            // (a plain consume was a no-op on the borrow, so nothing balanced the phi's release).
            // NOTE: this is the ONE ownership mechanism for `??`; the old `return x ?? default`
            // retain-on-return special case is REMOVED (statements.zig) so it no longer doubles this.
            // V1: a value-optional `??` yields a NON-owned prim (the phi is the unboxed value, not the
            // box). The left box's lifetime is handled outside this dance — a fresh producer box is
            // freed by the statement drain, a borrowed box by its owning local — and the right default
            // is a bare value. So NONE of the pointer retain/consume applies; skip it entirely.
            if (!nc_is_valopt) {
                if (namesExistingOwner(nc.left.kind) and self.isOwnedExpr(nc.left)) {
                    // left_val dominates the merge (defined in left_bb, a predecessor); retain(0) is a no-op on
                    // the null-and-take-rhs edge, so retaining here counts +1 exactly when the left survives.
                    try self.compileRetain(left_val);
                } else {
                    self.consumeTemporary(left_val);
                }
                // The BORROWED-owner right was already retained in rhs_bb (dominance + only-when-selected). A
                // FRESH producer right is a pending temp the phi takes over, so consume it here.
                if (!(namesExistingOwner(nc.right.kind) and self.isOwnedExpr(nc.right))) {
                    self.consumeTemporary(rhs_val);
                }
            }

            return phi;
        },
        .jsx_element => |jsx| {
            return try self.compileJsxElement(jsx);
        },
        .block_expr => |be| {
            const func = FunctionInfo{
                .name = self.current_function_name orelse "main",
                .param_count = 0,
                .param_names = &[_][]const u8{},
                .return_type = "void",
                .body = ast.Block{ .statements = &[_]ast.Statement{}, .span = be.span },
            };
            try self.scopes.append(self.allocator, Scope{ .deferred_statements = std.ArrayList(ast.Expression).empty });
            for (be.statements) |s| {
                if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) != null) {
                    break;
                }
                try self.compileStatement(s, func);
            }
            var scope = self.scopes.pop().?;
            if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) == null) {
                var idx = scope.deferred_statements.items.len;
                while (idx > 0) {
                    idx -= 1;
                    _ = try self.compileExpression(scope.deferred_statements.items[idx]);
                }
            }
            scope.deferred_statements.deinit(self.allocator);
            return core.LLVMConstInt(self.val_type, 0, 0);
        },
        .template_expr => |te| {
            const sb_new = self.getFunc("StringBuilder_init") orelse {
                std.debug.print("Error: 'StringBuilder_init' not found. Make sure to import collections/string_builder.\n", .{});
                return error.StringBuilderNewNotFound;
            };
            const sb_toString = self.getFunc("StringBuilder_toString") orelse {
                std.debug.print("Error: 'StringBuilder_toString' not found.\n", .{});
                return error.StringBuilderToStringNotFound;
            };
            const sb_delete = self.getFunc("StringBuilder_delete") orelse {
                std.debug.print("Error: 'StringBuilder_delete' not found.\n", .{});
                return error.StringBuilderDeleteNotFound;
            };

            // 1. Create the string builder
            const sb_size = self.getTypeSize(ast.TypeRef{ .ident = "StringBuilder" }, false);
            const sb_val = try self.compileAlloc(core.LLVMConstInt(self.val_type, sb_size, 0));
            const sb_new_t = core.LLVMGlobalGetValueType(sb_new);
            var sb_args = [_]types.LLVMValueRef{sb_val};
            _ = core.LLVMBuildCall2(self.builder, sb_new_t, sb_new, &sb_args, 1, "");

            // 2. Save outer builder and set current
            const outer_sb = self.current_string_builder;
            self.current_string_builder = sb_val;
            defer self.current_string_builder = outer_sb;

            // 3. Compile parts (they will automatically append to current_string_builder)
            // |*part|, not |part|: `&part` on a by-value capture is a STACK address
            // — it resolves fine but can never match the TypedIr, which is what the
            // stage-3 diff reported as "not in the IR".
            for (te.parts) |*part| {
                if (part.kind == .block_expr) {
                    _ = try self.compileExpression(part.*);
                } else {
                    const val = try self.compileExpression(part.*);
                    const expr_type = try self.resolveExpressionTypeName(part);
                    try self.compileAppendToStringBuilder(sb_val, val, expr_type, part.*);
                }
            }

            // 4. Get toString()
            const sb_toString_t = core.LLVMGlobalGetValueType(sb_toString);
            var toString_args = [_]types.LLVMValueRef{sb_val};
            const final_str = core.LLVMBuildCall2(self.builder, sb_toString_t, sb_toString, &toString_args, 1, "final_str");

            // 5. Delete the builder's BUFFER, then free the builder OBJECT.
            //
            // `StringBuilder.delete()` frees `self.buf` and zeroes it — it does NOT
            // free `self`. The object came from `compileAlloc` at rc=1 and nothing ever
            // gave that back, so EVERY template literal leaked one 24-byte builder.
            //
            // The survivors said so exactly: `{buf=0, len=4}` x100 and `{buf=0, len=2}`
            // x10 for 200 `` `k${i}` `` evaluations — buf zeroed by delete(), len still
            // holding the key's length. That is a StringBuilder and nothing else.
            const sb_delete_t = core.LLVMGlobalGetValueType(sb_delete);
            _ = core.LLVMBuildCall2(self.builder, sb_delete_t, sb_delete, &toString_args, 1, "");
            // null destructor: `delete` above already released what the object owned,
            // and the destructor would only call it a second time.
            try self.compileRelease(sb_val, null);

            return final_str;
        },
        .cast => |c| {
            const val = try self.compileExpression(c.expr.*);
            const target = try self.typeRefToString(c.target_type);
            const src_opt = try self.resolveExpressionTypeName(c.expr);

            // Trait -> concrete struct downcast: a trait object stores the underlying
            // struct pointer at offset 0 ({struct_ptr, vtable}). Load it so subsequent
            // field access lands on the real struct, not the trait fat pointer.
            if (src_opt) |src| {
                if (self.traits.contains(src) and self.isStructType(target)) {
                    const sp_ptr = core.LLVMBuildIntToPtr(self.builder, val, core.LLVMPointerType(self.val_type, 0), "downcast_sp_ptr");
                    const struct_ptr = core.LLVMBuildLoad2(self.builder, self.val_type, sp_ptr, "downcast_struct_ptr");
                    // F5 (task #13): the fat pointer OWNS this struct (constructTraitObject retained it,
                    // llvm_codegen.zig:1114). The downcast previously returned a BORROW, yet
                    // `let m = msg as T` releases m at scope exit anyway — balanced ONLY because struct
                    // literals were not drainable temporaries. Now that `.struct_init` IS a temporary
                    // (`acquisitionDisposition` = owned), that borrow-plus-scope-release becomes a THIRD release ->
                    // use-after-free via __destruct_trait (probe 13c / 12_traits_dispatch). Retain so `m`
                    // is a genuine INDEPENDENT owned reference, and register it as a temporary so an
                    // UNBOUND downcast (`(msg as T).field`) drains too. Same discipline as the .try_expr
                    // payload (2462). This pairs with `.struct_init` becoming a temp; neither is correct
                    // alone (see docs/design/F5-downcast-struct_init-plan.md for the refcount table).
                    try self.compileRetain(struct_ptr);
                    try registerTemporary(self, struct_ptr, try self.allocator.dupe(u8, target));
                    return struct_ptr;
                }
            }

            // Numeric float<->int conversions (native only; values are val_type i64).
            if (!self.is_wasm) {
                const isFloatName = struct {
                    fn f(n: []const u8) bool {
                        return std.mem.eql(u8, n, "f64") or std.mem.eql(u8, n, "double") or
                            std.mem.eql(u8, n, "f32") or std.mem.eql(u8, n, "float");
                    }
                }.f;
                const target_is_float = isFloatName(target);
                const src_is_float = if (src_opt) |s| isFloatName(s) else false;
                if (src_is_float and !target_is_float) {
                    // f64 -> int: reinterpret bits as double, then FPToSI.
                    const dbl = core.LLVMBuildBitCast(self.builder, val, core.LLVMDoubleType(), "cast_f2i_dbl");
                    return core.LLVMBuildFPToSI(self.builder, dbl, self.val_type, "cast_f2i");
                }
                if (!src_is_float and target_is_float) {
                    // int -> f64: SIToFP, then store the double's bits in val_type.
                    const dbl = core.LLVMBuildSIToFP(self.builder, val, core.LLVMDoubleType(), "cast_i2f");
                    return core.LLVMBuildBitCast(self.builder, dbl, self.val_type, "cast_i2f_val");
                }
            }
            return val;
        },
        .await_expr => |aw| {
            return try self.buildAwait(aw);
        },
        .go_expr => |g| {
            return try self.buildGo(g, false);
        },
        else => {
            std.debug.print("Expression type not supported in LLVM yet: {s}\n", .{@tagName(expr.kind)});
            return error.UnsupportedExpression;
        },
    }
}

fn isFloatTypeName(n: []const u8) bool {
    return std.mem.eql(u8, n, "f64") or std.mem.eql(u8, n, "double") or
        std.mem.eql(u8, n, "f32") or std.mem.eql(u8, n, "float");
}

// A7 / F3 §5 stage 5: the honest width + signedness of an integer binary op's RESULT,
// derived from its operand type names. `null` = not an integer op (float, bool, string,
// or a non-primitive/unknown pair) — leave those to their existing codegen. When both
// sides are integers the WIDER wins (value-preserving widening, §6); at equal width an
// unsigned side makes the result unsigned. This width is what arithmetic wraps to, and
// this signedness picks signed-vs-unsigned opcodes (div/rem/shr/compare).
const IntOpKind = struct { width: u32, signed: bool };
fn intOpKind(left_name: ?[]const u8, right_name: ?[]const u8) ?IntOpKind {
    const kindOf = struct {
        fn f(name: ?[]const u8) ?IntOpKind {
            const n = name orelse return null;
            const p = types_mod.cgPrim(n) orelse return null;
            // integer reprs only — not bool (.i1), floats, or non-primitives
            if (!(p.repr == .i8 or p.repr == .i16 or p.repr == .i32 or p.repr == .word or p.repr == .i64)) return null;
            return .{ .width = types_mod.reprBitWidth(p.repr), .signed = p.signed };
        }
    }.f;
    const l = kindOf(left_name);
    const r = kindOf(right_name);
    if (l == null and r == null) return null;
    if (l == null) return r;
    if (r == null) return l;
    const lk = l.?;
    const rk = r.?;
    if (lk.width > rk.width) return lk;
    if (rk.width > lk.width) return rk;
    // equal width: unsigned dominates (matches C's usual-arithmetic-conversions rank rule)
    return .{ .width = lk.width, .signed = lk.signed and rk.signed };
}

fn isWideIntTypeName(n: []const u8) bool {
    return std.mem.eql(u8, n, "long") or std.mem.eql(u8, n, "ulong") or
        std.mem.eql(u8, n, "i64") or std.mem.eql(u8, n, "u64");
}

/// A7 / F3 §5 stage 5: wrap an integer arithmetic result to its honest width. Values
/// live in the i64 pipeline, but an `int` result must behave as 32-bit — so truncate to
/// `width` and re-extend (sign- or zero-, per `signed`). This is what makes `int`
/// overflow wrap at 2³¹ and makes native and wasm agree (both hold a canonical 32-bit
/// value). A no-op at width ≥ 64 (`long`/`ptr` already fill the word).
pub fn canonicalizeInt(self: *LlvmCompiler, val: types.LLVMValueRef, width: u32, signed: bool) types.LLVMValueRef {
    if (width >= 64) return val;
    const iw = core.LLVMIntType(width);
    const truncd = core.LLVMBuildTrunc(self.builder, val, iw, "int_trunc");
    return if (signed)
        core.LLVMBuildSExt(self.builder, truncd, self.val_type, "int_sext")
    else
        core.LLVMBuildZExt(self.builder, truncd, self.val_type, "int_zext");
}

/// A8: stringify a non-string primitive for concat/interpolation via the RUNTIME
/// helpers (nova_i64_to_string / nova_bool_to_string / nova_f64_to_string) — replacing
/// the compiler-injected `__i32_to_string`/`__bool_to_string` Nova prelude. `val` is the
/// i64-pipeline value; floats are bitcast back to double first. Returns a fresh (+1)
/// Nova string.
/// Stringify a numeric/bool primitive VALUE through the runtime helpers. The `is_float`/`is_bool`
/// flags are the ONLY thing that varies; both the name-based (`numToString`) and TypeId-based
/// (`numToStringT`) entries compute them and delegate here.
pub fn numToStringImpl(self: *LlvmCompiler, val: types.LLVMValueRef, is_float: bool, is_bool: bool) !types.LLVMValueRef {
    if (is_float) {
        const f = self.func_map.get("nova_f64_to_string") orelse return error.HelperNotFound;
        const ft = core.LLVMGlobalGetValueType(f);
        const dbl = core.LLVMBuildBitCast(self.builder, val, core.LLVMDoubleType(), "concat_f2d");
        var a = [_]types.LLVMValueRef{dbl};
        return core.LLVMBuildCall2(self.builder, ft, f, &a, 1, "f64_str");
    }
    if (is_bool) {
        const f = self.func_map.get("nova_bool_to_string") orelse return error.HelperNotFound;
        const ft = core.LLVMGlobalGetValueType(f);
        var a = [_]types.LLVMValueRef{val};
        return core.LLVMBuildCall2(self.builder, ft, f, &a, 1, "bool_str");
    }
    const f = self.func_map.get("nova_i64_to_string") orelse return error.HelperNotFound;
    const ft = core.LLVMGlobalGetValueType(f);
    var a = [_]types.LLVMValueRef{val};
    return core.LLVMBuildCall2(self.builder, ft, f, &a, 1, "i64_str");
}

pub fn numToString(self: *LlvmCompiler, val: types.LLVMValueRef, type_name: ?[]const u8) !types.LLVMValueRef {
    const is_float = if (type_name) |tn| isFloatTypeName(tn) else false;
    const is_bool = if (type_name) |tn| std.mem.eql(u8, tn, "bool") else false;
    return self.numToStringImpl(val, is_float, is_bool);
}

/// F2-6 stage 4: stringify a primitive from its TYPE, not a rendered name — dispatches on the
/// store's `PrimKind` (float/bool/int). Returns null for a non-primitive or `void`, so the caller
/// can fall through. This is the TypeId-based twin of `numToString`; it lets the interpolation
/// PRIMITIVE decision (compileAppendToStringBuilder) run entirely off the store.
pub fn numToStringT(self: *LlvmCompiler, val: types.LLVMValueRef, tid: sema_types.TypeId) !?types.LLVMValueRef {
    const st = self.type_store orelse return null;
    switch (st.get(tid)) {
        .prim => |p| switch (p.kind) {
            .void_ => return null,
            .float => return try self.numToStringImpl(val, true, false),
            .bool => return try self.numToStringImpl(val, false, true),
            .int => return try self.numToStringImpl(val, false, false),
        },
        else => return null,
    }
}

pub fn compileAppendToStringBuilder(self: *LlvmCompiler, sb_val: types.LLVMValueRef, val: types.LLVMValueRef, expr_type_opt: ?[]const u8, opt_part: ?ast.Expression) !void {
    const sb_append = self.func_map.get("StringBuilder_append") orelse {
        std.debug.print("Error: 'StringBuilder_append' not found.\n", .{});
        return error.StringBuilderAppendNotFound;
    };
    const sb_append_t = core.LLVMGlobalGetValueType(sb_append);

    // NO retain of the builder. The old comment here claimed "the callee
    // consumes/releases its receiver parameter" — it does not: a PARAMETER is never
    // registered as an owned local (only `let` bindings are), so nothing in
    // `StringBuilder_append` releases `self`. The retain was therefore a +1 per part
    // with no matching -1, and every template literal leaked its 24-byte builder:
    // survivors showed `{buf=0, len=4}` x100 for 200 `` `k${i}` `` evaluations.
    //
    // O4 has the rule: "pass as argument | BORROW — the callee does not retain unless
    // it stores". `append` does not store its receiver.

    // NO retain of the part. `append` COPIES the part's bytes into the builder's buffer and
    // never stores the pointer (the same reason the builder itself is not retained, above) —
    // so an interpolated part is BORROWED, exactly like any read-only call argument (O4: "pass
    // as argument | BORROW"). The old code retained an owned VAR part (`${s}` for a heap-string
    // variable/parameter) with no matching release, leaking that string once per interpolation:
    // `wrap(s) => `<${s}>`` leaked its argument, and `xs.map(f).map(g)` leaked the intermediate
    // elements through exactly this path (the closure body interpolates its owned string arg).
    // A FRESH part (a call/`??` temporary) is released by the statement drain as usual; a var
    // part is released by its owner at scope exit. Neither needs a +1 here.
    // F2-6 stage 3 (cutover, increment 1 — interpolation, the `.string` case): decide the
    // stringify branch for a STRING part on the TYPE STORE (`typeOf(part) == .string`), not on the
    // rendered name (`== "string"`). This is the first codegen type-KIND *decision* moved off the
    // string engine and onto the IR. `typeOf` is authoritative for a typed value; an UNRESOLVED type
    // (a closure param sema did not type — F2-6 §4) has no entry, so it falls through to the
    // rendered-name path below (which reads current_local_types) — the closure interpolation still
    // works. Behavior-identical on concretes (`--shadow` proves the store agrees with the string).
    // The primitive path stays name-based for now (numToString dispatches on the name; a TypeId-based
    // numToString is a later increment) — and this order avoids the null-name crash on a prim part.
    if (opt_part) |part| {
        if (self.typed_ir) |ir| {
            if (self.type_store) |st| {
                if (ir.typeOf(&part)) |tid| {
                    switch (st.get(tid)) {
                        .string => {
                            var args = [_]types.LLVMValueRef{ sb_val, val };
                            _ = core.LLVMBuildCall2(self.builder, sb_append_t, sb_append, &args, 2, "");
                            return;
                        },
                        // A non-string primitive stringifies via the runtime helper, chosen from the
                        // store's PrimKind — no rendered name. numToStringT returns null for `void`,
                        // which falls through. The temp is fresh (+1) and `append` copies it, so it is
                        // dead immediately — release it.
                        .prim => {
                            if (try self.numToStringT(val, tid)) |str_temp| {
                                var args = [_]types.LLVMValueRef{ sb_val, str_temp };
                                _ = core.LLVMBuildCall2(self.builder, sb_append_t, sb_append, &args, 2, "");
                                try self.compileRelease(str_temp, null);
                                return;
                            }
                        },
                        // specs §3.1: a `decimal` stringifies via the runtime's decimal128 formatter. The
                        // returned string is fresh (+1); `append` copies it, so release it immediately.
                        .decimal => {
                            const to_fn = self.func_map.get("nova_decimal_to_string").?;
                            const to_t = core.LLVMGlobalGetValueType(to_fn);
                            var da = [_]types.LLVMValueRef{val};
                            const str_temp = core.LLVMBuildCall2(self.builder, to_t, to_fn, &da, 1, "dec_to_str");
                            var args = [_]types.LLVMValueRef{ sb_val, str_temp };
                            _ = core.LLVMBuildCall2(self.builder, sb_append_t, sb_append, &args, 2, "");
                            try self.compileRelease(str_temp, null);
                            return;
                        },
                        // owned / unresolved / type_param → the rendered-name path below (owned
                        // append-as-is; an unresolved closure param reads current_local_types).
                        else => {},
                    }
                }
            }
        }
    }

    if (expr_type_opt) |t| {
        if (std.mem.eql(u8, t, "string")) {
            var args = [_]types.LLVMValueRef{ sb_val, val };
            _ = core.LLVMBuildCall2(self.builder, sb_append_t, sb_append, &args, 2, "");
            return;
        } else if (types_mod.isPrimitiveTypeName(t) and !std.mem.eql(u8, t, "void") and !std.mem.eql(u8, t, "any")) {
            // A8: any non-string primitive (int/uint/long/byte/short, bool, float/double)
            // stringifies through the runtime helpers, not the injected `__i32_to_string`.
            // The converted string is a FRESH (+1) temporary that `append` copies and never
            // stores, so it is dead immediately — release it (the temporary rule can't see
            // it: it is built here directly, not via compileExpression).
            const str_temp = try self.numToString(val, t);
            var args = [_]types.LLVMValueRef{ sb_val, str_temp };
            _ = core.LLVMBuildCall2(self.builder, sb_append_t, sb_append, &args, 2, "");
            try self.compileRelease(str_temp, null);
            return;
        }
    }
    // Fallback: append as-is
    var args = [_]types.LLVMValueRef{ sb_val, val };
    _ = core.LLVMBuildCall2(self.builder, sb_append_t, sb_append, &args, 2, "");
}

pub fn compileJsxElement(self: *LlvmCompiler, jsx: ast.JsxElement) anyerror!types.LLVMValueRef {
    const sb_new = self.getFunc("StringBuilder_init") orelse {
        std.debug.print("Error: 'StringBuilder_init' not found. Make sure to import collections/string_builder.\n", .{});
        return error.StringBuilderNewNotFound;
    };
    const sb_append = self.getFunc("StringBuilder_append") orelse {
        std.debug.print("Error: 'StringBuilder_append' not found.\n", .{});
        return error.StringBuilderAppendNotFound;
    };
    const sb_toString = self.getFunc("StringBuilder_toString") orelse {
        std.debug.print("Error: 'StringBuilder_toString' not found.\n", .{});
        return error.StringBuilderToStringNotFound;
    };
    const sb_delete = self.getFunc("StringBuilder_delete") orelse {
        std.debug.print("Error: 'StringBuilder_delete' not found.\n", .{});
        return error.StringBuilderDeleteNotFound;
    };

    // Create the string builder
    const sb_size = self.getTypeSize(ast.TypeRef{ .ident = "StringBuilder" }, false);
    const sb_val = try self.compileAlloc(core.LLVMConstInt(self.val_type, sb_size, 0));
    const sb_new_t = core.LLVMGlobalGetValueType(sb_new);
    var sb_args = [_]types.LLVMValueRef{sb_val};
    _ = core.LLVMBuildCall2(self.builder, sb_new_t, sb_new, &sb_args, 1, "");

    // Save outer builder and set current
    const outer_sb = self.current_string_builder;
    self.current_string_builder = sb_val;
    defer self.current_string_builder = outer_sb;

    // Helper closures
    const append_val_fn = struct {
        fn run(c: *LlvmCompiler, sb: types.LLVMValueRef, append_func: types.LLVMValueRef, val: types.LLVMValueRef) void {
            const append_t = core.LLVMGlobalGetValueType(append_func);
            c.compileRetain(sb) catch {};
            var args = [_]types.LLVMValueRef{ sb, val };
            _ = core.LLVMBuildCall2(c.builder, append_t, append_func, &args, 2, "");
        }
    }.run;

    const append_literal_fn = struct {
        fn run(c: *LlvmCompiler, sb: types.LLVMValueRef, append_func: types.LLVMValueRef, text: []const u8) !void {
            const expr = ast.Expression{ .kind = .{ .literal = .{ .string = text } } };
            const str_val = try c.compileExpression(expr);
            const append_t = core.LLVMGlobalGetValueType(append_func);
            try c.compileRetain(sb);
            var args = [_]types.LLVMValueRef{ sb, str_val };
            _ = core.LLVMBuildCall2(c.builder, append_t, append_func, &args, 2, "");
        }
    }.run;

    const append_expr_fn = struct {
        // Takes a POINTER: `expr: ast.Expression` made `&expr` a stack address,
        // which the stage-3 diff reported as "not in the IR" — a key that can
        // never match. Introduced by the stage-3-prep refactor and caught by the
        // diff, not by the compiler.
        fn run(c: *LlvmCompiler, sb: types.LLVMValueRef, append_func: types.LLVMValueRef, expr: *const ast.Expression) !void {
            const val = try c.compileExpression(expr.*);
            const type_name = try c.resolveExpressionTypeName(expr);
            if (type_name) |t| {
                // F5-2: retain gate via the store; `t` is still used below for the string/primitive dispatch.
                if (c.isOwnedExpr(expr)) {
                    const is_var = (expr.kind == .ident or expr.kind == .field_access or expr.kind == .index);
                    if (is_var) {
                        try c.compileRetain(val);
                    }
                }
                if (std.mem.eql(u8, t, "string")) {
                    append_val_fn(c, sb, append_func, val);
                    return;
                } else if (types_mod.isPrimitiveTypeName(t) and !std.mem.eql(u8, t, "void") and !std.mem.eql(u8, t, "any")) {
                    // A8: int/bool/float via the runtime helpers (was `__i32_to_string`).
                    const str_temp = try c.numToString(val, t);
                    append_val_fn(c, sb, append_func, str_temp);
                    return;
                }
            }
            // Fallback / default
            append_val_fn(c, sb, append_func, val);
        }
    }.run;

    // 1. Append "<tag"
    const tag_open = try std.fmt.allocPrint(self.allocator, "<{s}", .{jsx.tag});
    defer self.allocator.free(tag_open);
    try append_literal_fn(self, sb_val, sb_append, tag_open);

    // 2. Append attributes
    for (jsx.attributes) |attr| {
        const attr_prefix = try std.fmt.allocPrint(self.allocator, " {s}=\"", .{attr.name});
        defer self.allocator.free(attr_prefix);
        try append_literal_fn(self, sb_val, sb_append, attr_prefix);

        switch (attr.value) {
            .string_literal => |lit| {
                try append_literal_fn(self, sb_val, sb_append, lit);
            },
            .expression => |*expr| {
                try append_expr_fn(self, sb_val, sb_append, expr);
            },
        }

        try append_literal_fn(self, sb_val, sb_append, "\"");
    }

    const has_children = jsx.children.len > 0;
    if (!has_children) {
        try append_literal_fn(self, sb_val, sb_append, "/>");
    } else {
        try append_literal_fn(self, sb_val, sb_append, ">");

        // 3. Append children
        for (jsx.children) |child| {
            switch (child) {
                .text => |txt| {
                    try append_literal_fn(self, sb_val, sb_append, txt);
                },
                .element => |sub_el| {
                    const sub_str = try self.compileJsxElement(sub_el);
                    append_val_fn(self, sb_val, sb_append, sub_str);
                },
                .expression => |*expr| {
                    try append_expr_fn(self, sb_val, sb_append, expr);
                },
                .statement => |stmt| {
                    const dummy_func = FunctionInfo{
                        .name = self.current_function_name orelse "main",
                        .param_count = 0,
                        .param_names = &[_][]const u8{},
                        .return_type = "void",
                        .body = ast.Block{ .statements = &[_]ast.Statement{}, .span = ast.Span{ .file = "", .line = 0, .col = 0, .start = 0, .end = 0 } },
                    };
                    try self.compileStatement(stmt, dummy_func);
                },
            }
        }

        // 4. Append "</tag>"
        const tag_close = try std.fmt.allocPrint(self.allocator, "</{s}>", .{jsx.tag});
        defer self.allocator.free(tag_close);
        try append_literal_fn(self, sb_val, sb_append, tag_close);
    }

    // 5. Get toString()
    const sb_toString_t = core.LLVMGlobalGetValueType(sb_toString);
    var toString_args = [_]types.LLVMValueRef{sb_val};
    const final_str = core.LLVMBuildCall2(self.builder, sb_toString_t, sb_toString, &toString_args, 1, "final_str");

    // 6. Delete builder
    const sb_delete_t = core.LLVMGlobalGetValueType(sb_delete);
    _ = core.LLVMBuildCall2(self.builder, sb_delete_t, sb_delete, &toString_args, 1, "");

    return final_str;
}

pub fn compileBTreeQuery(
    self: *LlvmCompiler,
    target_type: ast.TypeRef,
    conn_expr: ast.Expression,
    sql_expr: ast.Expression,
    params_expr: ast.Expression,
) anyerror!types.LLVMValueRef {
    const type_str = try self.typeRefToString(target_type);
    
    const tmp_fn_name = try std.fmt.allocPrint(self.allocator, "decode_binary_row_{s}", .{type_str});
    defer self.allocator.free(tmp_fn_name);
    const fn_name = try self.allocator.dupeZ(u8, tmp_fn_name);
    defer self.allocator.free(fn_name);
    
    var decoder_fn = self.func_map.get(fn_name);
    if (decoder_fn == null) {
        var params = [_]types.LLVMTypeRef{ self.val_type, self.val_type, self.val_type, self.val_type };
        const fn_type = core.LLVMFunctionType(self.val_type, &params, 4, 0);
        decoder_fn = core.LLVMAddFunction(self.module, fn_name.ptr, fn_type);
        try self.func_map.put(fn_name, decoder_fn.?);

        const current_bb = core.LLVMGetInsertBlock(self.builder);
        const entry_bb = core.LLVMAppendBasicBlock(decoder_fn.?, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);

        const fixed_data = core.LLVMGetParam(decoder_fn.?, 0);
        const heap_data = core.LLVMGetParam(decoder_fn.?, 1);
        const col_names = core.LLVMGetParam(decoder_fn.?, 2);
        const col_types = core.LLVMGetParam(decoder_fn.?, 3);

        const decoded_struct = try self.compileDecodeBinaryRow(target_type, fixed_data, heap_data, col_names, col_types);
        _ = core.LLVMBuildRet(self.builder, decoded_struct);

        core.LLVMPositionBuilderAtEnd(self.builder, current_bb);
    }

    const query_internal_fn = self.func_map.get("BTreeConnection_queryInternal") orelse return error.QueryInternalNotFound;
    const query_internal_fn_t = core.LLVMGlobalGetValueType(query_internal_fn);
    
    const self_val = try self.compileExpression(conn_expr);
    const sql_val = try self.compileExpression(sql_expr);
    const params_val = try self.compileExpression(params_expr);
    const decoder_ptr = core.LLVMBuildPtrToInt(self.builder, decoder_fn.?, self.val_type, "decoder_ptr");

    var query_args = [_]types.LLVMValueRef{ self_val, sql_val, params_val, decoder_ptr };
    return core.LLVMBuildCall2(self.builder, query_internal_fn_t, query_internal_fn, &query_args, 4, "query_res");
}

pub fn compileDecodeBinaryRow(
    self: *LlvmCompiler,
    target_type: ast.TypeRef,
    fixed_data_val: types.LLVMValueRef,
    heap_data_val: types.LLVMValueRef,
    col_names_val: types.LLVMValueRef,
    col_types_val: types.LLVMValueRef,
) anyerror!types.LLVMValueRef {

    const type_str = try self.typeRefToString(target_type);
    
    // Find the helper functions
    const find_fn = self.getFunc("findColumnIndex") orelse return error.HelperNotFound;
    const find_fn_t = core.LLVMGlobalGetValueType(find_fn);

    const offset_fn = self.getFunc("getColumnOffset") orelse return error.HelperNotFound;
    const offset_fn_t = core.LLVMGlobalGetValueType(offset_fn);

    const read_str_fn = self.getFunc("__read_string") orelse return error.HelperNotFound;
    const read_str_fn_t = core.LLVMGlobalGetValueType(read_str_fn);

    // Get struct declaration of T
    const s_decl = self.structs.get(type_str) orelse return error.StructDeclNotFound;
    const total_size = self.getTypeSize(target_type, false);
    const size_val = core.LLVMConstInt(self.val_type, total_size, 0);
    const struct_ptr = try self.compileAlloc(size_val);

    for (s_decl.fields) |field| {
        const field_name_str = try self.getOrCreateStringLiteral(field.name);
        
        // col_idx = findColumnIndex(col_names, field_name)
        var find_args = [_]types.LLVMValueRef{ col_names_val, field_name_str };
        const col_idx = core.LLVMBuildCall2(self.builder, find_fn_t, find_fn, &find_args, 2, "col_idx");

        // Check if col_idx != -1
        const minus_one = core.LLVMConstInt(self.val_type, @bitCast(@as(i64, -1)), 0);
        const col_idx_found = core.LLVMBuildICmp(self.builder, .LLVMIntNE, col_idx, minus_one, "col_idx_found");

        const current_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
        const then_bb = core.LLVMAppendBasicBlock(current_fn, "decode_field_found");
        const else_bb = core.LLVMAppendBasicBlock(current_fn, "decode_field_not_found");
        const merge_bb = core.LLVMAppendBasicBlock(current_fn, "decode_field_merge");

        _ = core.LLVMBuildCondBr(self.builder, col_idx_found, then_bb, else_bb);

        // --- Then block: Decode field from binary buffers ---
        core.LLVMPositionBuilderAtEnd(self.builder, then_bb);
        
        // 1. col_offset = getColumnOffset(col_types, col_idx)
        var offset_args = [_]types.LLVMValueRef{ col_types_val, col_idx };
        const col_offset = core.LLVMBuildCall2(self.builder, offset_fn_t, offset_fn, &offset_args, 2, "col_offset");

        // 2. Extract based on field.type_name
        const f_type_str = try self.typeRefToString(field.type_name);
        const llvm_field_type = self.toLLVMType(field.type_name);
        
        var decoded_val: types.LLVMValueRef = undefined;
        if (std.mem.eql(u8, f_type_str, "bool")) {
            const addr = core.LLVMBuildAdd(self.builder, fixed_data_val, col_offset, "addr");
            const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "byte_ptr");
            const byte_val = core.LLVMBuildLoad2(self.builder, self.i8_type, ptr, "byte_val");
            decoded_val = core.LLVMBuildZExt(self.builder, byte_val, self.val_type, "decoded_val");
        } else if (std.mem.eql(u8, f_type_str, "i32") or std.mem.eql(u8, f_type_str, "int")) {
            const addr = core.LLVMBuildAdd(self.builder, fixed_data_val, col_offset, "addr");
            const i32_ptr_type = core.LLVMPointerType(self.i32_type, 0);
            const ptr = core.LLVMBuildIntToPtr(self.builder, addr, i32_ptr_type, "i32_ptr");
            const i32_val = core.LLVMBuildLoad2(self.builder, self.i32_type, ptr, "i32_val");
            decoded_val = core.LLVMBuildSExt(self.builder, i32_val, self.val_type, "decoded_val");
        } else if (std.mem.eql(u8, f_type_str, "i64") or std.mem.eql(u8, f_type_str, "long") or std.mem.eql(u8, f_type_str, "double") or std.mem.eql(u8, f_type_str, "decimal")) {
            const addr = core.LLVMBuildAdd(self.builder, fixed_data_val, col_offset, "addr");
            const i64_ptr_type = core.LLVMPointerType(self.i64_type, 0);
            const ptr = core.LLVMBuildIntToPtr(self.builder, addr, i64_ptr_type, "i64_ptr");
            decoded_val = core.LLVMBuildLoad2(self.builder, self.i64_type, ptr, "decoded_val");
        } else if (std.mem.eql(u8, f_type_str, "string")) {
            // Read 4-byte heap offset
            const addr = core.LLVMBuildAdd(self.builder, fixed_data_val, col_offset, "addr");
            const u32_ptr_type = core.LLVMPointerType(self.i32_type, 0);
            const ptr = core.LLVMBuildIntToPtr(self.builder, addr, u32_ptr_type, "u32_ptr");
            const heap_offset = core.LLVMBuildLoad2(self.builder, self.i32_type, ptr, "heap_offset");
            const heap_offset_ext = core.LLVMBuildZExt(self.builder, heap_offset, self.val_type, "heap_offset_ext");

            // Read string len from heap_data
            const str_addr = core.LLVMBuildAdd(self.builder, heap_data_val, heap_offset_ext, "str_addr");
            const str_len_ptr = core.LLVMBuildIntToPtr(self.builder, str_addr, u32_ptr_type, "str_len_ptr");
            const str_len = core.LLVMBuildLoad2(self.builder, self.i32_type, str_len_ptr, "str_len");
            const str_len_ext = core.LLVMBuildZExt(self.builder, str_len, self.val_type, "str_len_ext");

            // Character pointer: heap_data_val + heap_offset_ext + 4
            const chars_addr = core.LLVMBuildAdd(self.builder, heap_data_val, heap_offset_ext, "chars_addr");
            const chars_ptr = core.LLVMBuildAdd(self.builder, chars_addr, core.LLVMConstInt(self.val_type, 4, 0), "chars_ptr");

            // Call __read_string(chars_ptr, str_len_ext)
            var read_args = [_]types.LLVMValueRef{ chars_ptr, str_len_ext };
            decoded_val = core.LLVMBuildCall2(self.builder, read_str_fn_t, read_str_fn, &read_args, 2, "read_str");
        } else {
            decoded_val = core.LLVMConstInt(self.val_type, 0, 0);
        }

        _ = core.LLVMBuildBr(self.builder, merge_bb);
        const then_end_bb = core.LLVMGetInsertBlock(self.builder);

        // --- Else block: Field not found in query ---
        core.LLVMPositionBuilderAtEnd(self.builder, else_bb);
        const default_val = core.LLVMConstInt(self.val_type, 0, 0);
        _ = core.LLVMBuildBr(self.builder, merge_bb);
        const else_end_bb = core.LLVMGetInsertBlock(self.builder);

        // --- Merge block ---
        core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
        const phi_val = core.LLVMBuildPhi(self.builder, self.val_type, "field_phi");
        var incoming_vals = [_]types.LLVMValueRef{ decoded_val, default_val };
        var incoming_bbs = [_]types.LLVMBasicBlockRef{ then_end_bb, else_end_bb };
        core.LLVMAddIncoming(phi_val, &incoming_vals, &incoming_bbs, 2);

        // Store into struct_ptr at field offset
        const f_offset = try self.getFieldOffset(type_str, field.name);
        const f_offset_val = core.LLVMConstInt(self.val_type, f_offset, 0);
        const f_addr = core.LLVMBuildAdd(self.builder, struct_ptr, f_offset_val, "f_addr");
        const f_dest_ptr = core.LLVMBuildIntToPtr(self.builder, f_addr, core.LLVMPointerType(llvm_field_type, 0), "f_dest_ptr");
        const casted = self.castFromValType(phi_val, llvm_field_type);
        _ = core.LLVMBuildStore(self.builder, casted, f_dest_ptr);
    }

    return struct_ptr;
}

pub fn compileGenericParse(self: *LlvmCompiler, is_yaml: bool, target_type: ast.TypeRef, input_expr: ast.Expression) anyerror!types.LLVMValueRef {
    const input_val = try self.compileExpression(input_expr);

    const parse_fn_name = if (is_yaml) "serde_yaml_parse" else "serde_json_parse";
    var parse_fn = self.func_map.get(parse_fn_name);
    if (parse_fn == null) {
        var iter = self.func_map.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.endsWith(u8, key, parse_fn_name)) {
                parse_fn = entry.value_ptr.*;
                break;
            }
        }
    }
    const final_parse_fn = parse_fn orelse {
        std.debug.print("Parse function '{s}' not found\n", .{parse_fn_name});
        return error.ParseFunctionNotFound;
    };
    const parsed_val = try self.buildCallWithCasts(final_parse_fn, &[_]types.LLVMValueRef{input_val});

    const result_val = try self.convertValueToType(is_yaml, parsed_val, target_type);

    const type_name = if (is_yaml) "YamlValue" else "JsonValue";
    if (try self.getOrCreateDestructor(type_name)) |dest_fn| {
        try self.compileRelease(parsed_val, dest_fn);
    } else {
        try self.compileRelease(parsed_val, null);
    }

    return result_val;
}

pub fn getFunc(self: *LlvmCompiler, name: []const u8) ?types.LLVMValueRef {
    if (std.mem.eql(u8, name, "List_init") or std.mem.eql(u8, name, "List_new")) {
        var debug_iter = self.func_map.iterator();
        while (debug_iter.next()) |entry| {
            if (std.mem.indexOf(u8, entry.key_ptr.*, "List_") != null) {
                std.debug.print("  func_map key={s}\n", .{entry.key_ptr.*});
            }
        }
    }
    if (self.func_map.get(name)) |v| return v;
    var iter = self.func_map.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.endsWith(u8, key, name)) {
            return entry.value_ptr.*;
        }
    }
    return null;
}

/// F4-5: render a reify type argument to its concrete name. Inside a specialized generic-method
/// body the arg may be the method's param (`T`), so substitute it to the concrete type; elsewhere
/// this is just `typeRefToString`. Used by the `serde.bind<T>` / `serde.typeName<T>` reifies.
pub fn resolveReifyTypeName(self: *LlvmCompiler, type_ref: ast.TypeRef) anyerror![]const u8 {
    if (type_ref == .ident and self.current_method_subst != null) {
        for (self.current_method_subst.?) |b| {
            if (std.mem.eql(u8, b.name, type_ref.ident)) return b.concrete;
        }
    }
    return try self.typeRefToString(type_ref);
}

pub fn convertValueToType(self: *LlvmCompiler, is_yaml: bool, val: types.LLVMValueRef, type_ref: ast.TypeRef) anyerror!types.LLVMValueRef {
    const type_str = try self.typeRefToString(type_ref);

    const get_fn_name = if (is_yaml) "serde_yaml_get" else "serde_json_get";
    const get_fn = self.getFunc(get_fn_name) orelse return error.GetFunctionNotFound;

    if (std.mem.eql(u8, type_str, "i32") or std.mem.eql(u8, type_str, "i64") or std.mem.eql(u8, type_str, "int") or std.mem.eql(u8, type_str, "long") or std.mem.eql(u8, type_str, "double") or std.mem.eql(u8, type_str, "decimal") or std.mem.eql(u8, type_str, "float") or std.mem.eql(u8, type_str, "f32") or std.mem.eql(u8, type_str, "f64")) {
        const asNum_name = if (is_yaml) "serde_yaml_asNumber" else "serde_json_asNumber";
        const asNum_fn = self.getFunc(asNum_name) orelse return error.AsNumberFunctionNotFound;
        try self.compileRetain(val);
        const res = try self.buildCallWithCasts(asNum_fn, &[_]types.LLVMValueRef{val});
        const llvm_t = self.toLLVMType(type_ref);
        return self.castFromValType(res, llvm_t);
    }

    if (std.mem.eql(u8, type_str, "bool")) {
        const asBool_name = if (is_yaml) "serde_yaml_asBool" else "serde_json_asBool";
        const asBool_fn = self.getFunc(asBool_name) orelse return error.AsBoolFunctionNotFound;
        try self.compileRetain(val);
        const res = try self.buildCallWithCasts(asBool_fn, &[_]types.LLVMValueRef{val});
        const llvm_t = self.toLLVMType(type_ref);
        return self.castFromValType(res, llvm_t);
    }

    if (std.mem.eql(u8, type_str, "string")) {
        const asStr_name = if (is_yaml) "serde_yaml_asString" else "serde_json_asString";
        const asStr_fn = self.getFunc(asStr_name) orelse return error.AsStringFunctionNotFound;
        try self.compileRetain(val);
        const res = try self.buildCallWithCasts(asStr_fn, &[_]types.LLVMValueRef{val});
        try self.compileRetain(res);
        return res;
    }

    if (self.structs.get(type_str)) |s_decl| {
        const total_size = self.getTypeSize(type_ref, false);
        const size_val = core.LLVMConstInt(self.val_type, total_size, 0);
        const struct_ptr = try self.compileAlloc(size_val);

        for (s_decl.fields) |field| {
            const offset = try self.getFieldOffset(type_str, field.name);
            const offset_val = core.LLVMConstInt(self.val_type, offset, 0);

            const field_name_str = try self.getOrCreateStringLiteral(field.name);
            try self.compileRetain(val);
            const field_json_val = try self.buildCallWithCasts(get_fn, &[_]types.LLVMValueRef{ val, field_name_str });

            const converted_val = try self.convertValueToType(is_yaml, field_json_val, field.type_name);

            const addr = core.LLVMBuildAdd(self.builder, struct_ptr, offset_val, "field_addr");
            const llvm_field_type = self.toLLVMType(field.type_name);
            const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(llvm_field_type, 0), "field_ptr");
            const casted = self.castFromValType(converted_val, llvm_field_type);
            _ = core.LLVMBuildStore(self.builder, casted, ptr);
        }

        return struct_ptr;
    }

    if (std.mem.startsWith(u8, type_str, "List<")) {
        const open_angle = std.mem.indexOfScalar(u8, type_str, '<') orelse return error.InvalidGenericType;
        const close_angle = std.mem.indexOfScalar(u8, type_str, '>') orelse return error.InvalidGenericType;
        const sub_item_type_str = type_str[open_angle + 1 .. close_angle];
        const sub_item_type = ast.TypeRef{ .ident = sub_item_type_str };

        const asArray_name = if (is_yaml) "serde_yaml_asArray" else "serde_json_asArray";
        const asArray_fn = self.getFunc(asArray_name) orelse return error.AsArrayFunctionNotFound;
        try self.compileRetain(val);
        const arr_val = try self.buildCallWithCasts(asArray_fn, &[_]types.LLVMValueRef{val});

        const list_new = self.getFunc("List_init") orelse return error.ListNewNotFound;
        const list_size = self.getFunc("List_size") orelse return error.ListSizeNotFound;
        const list_get = self.getFunc("List_get") orelse return error.ListGetNotFound;
        const list_push = self.getFunc("List_push") orelse return error.ListPushNotFound;

        const list_size_type = self.getTypeSize(ast.TypeRef{ .ident = "List" }, false);
        const new_list_val = try self.compileAlloc(core.LLVMConstInt(self.val_type, list_size_type, 0));
        const list_new_t = core.LLVMGlobalGetValueType(list_new);
        var list_args = [_]types.LLVMValueRef{new_list_val};
        _ = core.LLVMBuildCall2(self.builder, list_new_t, list_new, &list_args, 1, "");

        const size_t = core.LLVMGlobalGetValueType(list_size);
        var size_args = [_]types.LLVMValueRef{arr_val};
        try self.compileRetain(arr_val);
        const size_val = core.LLVMBuildCall2(self.builder, size_t, list_size, &size_args, 1, "arr_size");

        const current_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
        const loop_cond_bb = core.LLVMAppendBasicBlock(current_fn, "list_loop_cond");
        const loop_body_bb = core.LLVMAppendBasicBlock(current_fn, "list_loop_body");
        const loop_end_bb = core.LLVMAppendBasicBlock(current_fn, "list_loop_end");

        const idx_var = try self.compileAlloc(core.LLVMConstInt(self.val_type, 4, 0));
        const idx_ptr = core.LLVMBuildIntToPtr(self.builder, idx_var, core.LLVMPointerType(self.i32_type, 0), "idx_ptr");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i32_type, 0, 0), idx_ptr);

        _ = core.LLVMBuildBr(self.builder, loop_cond_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_cond_bb);
        const current_idx = core.LLVMBuildLoad2(self.builder, self.i32_type, idx_ptr, "current_idx");
        const casted_idx = self.castToValType(current_idx, ast.TypeRef{ .ident = "i32" });
        const cmp = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntSLT, casted_idx, size_val, "loop_cmp");
        _ = core.LLVMBuildCondBr(self.builder, cmp, loop_body_bb, loop_end_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_body_bb);
        const get_t = core.LLVMGlobalGetValueType(list_get);
        var get_args = [_]types.LLVMValueRef{ arr_val, casted_idx };
        try self.compileRetain(arr_val);
        const elem_val = core.LLVMBuildCall2(self.builder, get_t, list_get, &get_args, 2, "elem_val");

        const converted_elem = try self.convertValueToType(is_yaml, elem_val, sub_item_type);

        const push_t = core.LLVMGlobalGetValueType(list_push);
        var push_args = [_]types.LLVMValueRef{ new_list_val, converted_elem };
        try self.compileRetain(new_list_val);
        _ = core.LLVMBuildCall2(self.builder, push_t, list_push, &push_args, 2, "");

        const next_idx = core.LLVMBuildAdd(self.builder, current_idx, core.LLVMConstInt(self.i32_type, 1, 0), "next_idx");
        _ = core.LLVMBuildStore(self.builder, next_idx, idx_ptr);
        _ = core.LLVMBuildBr(self.builder, loop_cond_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_end_bb);
        if (try self.getOrCreateDestructor("List")) |dest_fn| {
            try self.compileRelease(arr_val, dest_fn);
        } else {
            try self.compileRelease(arr_val, null);
        }
        return new_list_val;
    }

    return core.LLVMConstInt(self.val_type, 0, 0);
}

// Map an HTTP-verb route method name to its wire method string, or null if the
// field isn't a route verb. Used by the typed-mediator `router.get<Q>(path)`
// lowering (flagship framework layer).
fn routeVerbMethod(field: []const u8) ?[]const u8 {
    const verbs = [_]struct { f: []const u8, m: []const u8 }{
        .{ .f = "get", .m = "GET" },       .{ .f = "post", .m = "POST" },
        .{ .f = "put", .m = "PUT" },       .{ .f = "delete", .m = "DELETE" },
        .{ .f = "patch", .m = "PATCH" },   .{ .f = "options", .m = "OPTIONS" },
        .{ .f = "head", .m = "HEAD" },
    };
    for (verbs) |v| if (std.mem.eql(u8, field, v.f)) return v.m;
    return null;
}

fn structHasMethod(sd: ast.StructDecl, name: []const u8) bool {
    for (sd.methods) |m| if (std.mem.eql(u8, m.decl.name, name)) return true;
    return false;
}
