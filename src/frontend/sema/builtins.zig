//! The compiler-intrinsic call registry: the built-in `receiver.method(...)`
//! and bare `extern` runtime functions that sema knows the return type of
//! without ever seeing a Nova declaration for them.
//!
//! Nova's standard library is written in Nova and type-checks like any other
//! code, but a handful of primitives cannot be, they are the raw seam onto
//! machine memory, SIMD registers, the C++ runtime, and the async reactor.
//! `bytes.read_i32(p, off)`, `simd.addU32x4(a, b)`, and `nova_reactor_resume(h)`
//! have no Nova body to infer a type from; the codegen backend emits them
//! directly as loads/stores, LLVM vector ops, or `extern` calls. This module is
//! how the *front end* learns their signatures' return side so a call
//! expression can be typed and the rest of inference can proceed.
//!
//! There are two flavours, kept in two tables:
//!
//!   * [`table`], namespaced pseudo-methods written `receiver.name(args)`,
//!     where `receiver` is a magic module identifier (`bytes`, `simd`, `mem`,
//!     `decimal`, `console`) rather than a real value. [`isReceiver`] is what
//!     tells the resolver "`bytes` is not an undefined variable, it is a
//!     builtin namespace", and [`find`] resolves the specific method.
//!
//!   * [`externs`], bare-name functions (empty `receiver`) that bind straight
//!     to a symbol in the C++ runtime (`nova_*`) or the coroutine ABI
//!     (`currentCoro`, `coroStart`, ...). Resolved by [`findExtern`].
//!
//! Each entry records ONLY the return type, as a small [`Ret`] tag rather than a
//! full [`types.TypeId`]: the table is a compile-time constant and predates (and
//! is independent of) any particular [`types.TypeStore`] instance, so it stores a
//! store-agnostic enum and [`retType`] materialises the real `TypeId` on demand
//! against whichever store the current compilation is using. Argument types are
//! deliberately not modelled here, arguments are checked elsewhere; what
//! inference needs from this table is the value a call *yields*.
//!
//! Invariant worth stating because it is load-bearing and tested: address-
//! yielding builtins (`bytes.alloc`, `bytes.new`, `read_ptr`, ...) return [`Ret.ptr`],
//! NOT [`Ret.int`]. A pointer stored into a 32-bit `int` truncates on a 64-bit
//! target and produces a garbage address; the `.ptr` tag keeps them at pointer
//! width. See the `bytes.alloc returns a POINTER` test at the foot of this file.

const std = @import("std");
const types = @import("../types.zig");

/// The kind of value a builtin yields, as a store-independent tag.
///
/// This is a compact stand-in for a [`types.TypeId`] so that [`table`] and
/// [`externs`] can be `comptime` constants with no live [`types.TypeStore`] to
/// intern against. [`retType`] maps each variant to the concrete `TypeId` for a
/// given store. Note `int` is 32-bit and `long`/`ptr` are 64-bit width, which is
/// why memory-address builtins must use `.ptr`/`.long` and never `.int` (an
/// `int` would truncate the address). The `vec*` variants name the fixed SIMD
/// register shapes the `simd.*` intrinsics operate on.
pub const Ret = enum { void_, int, long, ptr, string, bool_, decimal, double, vec4, vec_u8x16, vec_u32x4, vec_u64x2 };

/// One registry entry: a `(receiver, name)` key and the [`Ret`] it returns.
///
/// Used both for namespaced methods in [`table`] (non-empty `receiver`) and for
/// bare runtime externs in [`externs`] (empty `receiver`). Only the return side
/// is described; argument arity and types are validated by the caller, not here.
pub const Builtin = struct {

    /// The builtin namespace this method hangs off, e.g. `"bytes"` or `"simd"`.
    /// Empty (`""`) for a bare [`externs`] function that has no receiver.
    receiver: []const u8,
    /// The method / function identifier as written in Nova source, matched
    /// verbatim by [`find`] and [`findExtern`] (exact byte comparison, no
    /// normalisation).
    name: []const u8,
    /// The type of value a call to this builtin evaluates to, deferred through
    /// [`Ret`] so the table can stay store-independent.
    ret: Ret,
};

/// The namespaced builtin methods, keyed by `receiver.name`.
///
/// Groups: `bytes.*` is the raw heap-memory seam (allocate, free, typed
/// load/store, and pointer/length introspection) that the `bytes` intrinsic
/// module and the ARC-managed containers are built on; `decimal.*` bridges
/// `int`/`String` to the runtime's `decimal` type; `simd.*` maps one-to-one onto
/// LLVM vector operations over the fixed lane shapes (`f64x4`, `u8x16`, `u32x4`,
/// `u64x2`), including the carry-less multiply (`clmulU64x2`) used by GHASH and
/// lane/high-multiply helpers used by wide-integer crypto; `mem.xorBytes` is a
/// bulk XOR; and `console.*` are the debug-print sinks. [`isReceiver`] treats the
/// left of the dot as a namespace, and [`find`] resolves the exact method.
///
/// Ordering is by receiver for readability only; lookups are linear scans, so
/// position carries no meaning.
pub const table = [_]Builtin{

    .{ .receiver = "bytes", .name = "alloc", .ret = .ptr },
    .{ .receiver = "bytes", .name = "alloc_persistent", .ret = .ptr },
    .{ .receiver = "bytes", .name = "new", .ret = .ptr },
    .{ .receiver = "bytes", .name = "new_persistent", .ret = .ptr },
    .{ .receiver = "bytes", .name = "new_with_allocator", .ret = .ptr },
    .{ .receiver = "bytes", .name = "free", .ret = .void_ },
    .{ .receiver = "bytes", .name = "read_byte", .ret = .int },
    .{ .receiver = "bytes", .name = "write_byte", .ret = .void_ },
    .{ .receiver = "bytes", .name = "read_ptr", .ret = .ptr },
    .{ .receiver = "bytes", .name = "write_ptr", .ret = .void_ },
    .{ .receiver = "bytes", .name = "read_i32", .ret = .int },
    .{ .receiver = "bytes", .name = "write_i32", .ret = .void_ },
    .{ .receiver = "bytes", .name = "read_string", .ret = .string },

    .{ .receiver = "bytes", .name = "write_decimal", .ret = .void_ },
    .{ .receiver = "bytes", .name = "read_decimal", .ret = .decimal },
    .{ .receiver = "bytes", .name = "ptr_size", .ret = .int },
    .{ .receiver = "bytes", .name = "length", .ret = .int },
    .{ .receiver = "bytes", .name = "len", .ret = .int },

    .{ .receiver = "decimal", .name = "fromInt", .ret = .decimal },
    .{ .receiver = "decimal", .name = "toInt", .ret = .int },
    .{ .receiver = "decimal", .name = "fromString", .ret = .decimal },

    .{ .receiver = "simd", .name = "splat4", .ret = .vec4 },
    .{ .receiver = "simd", .name = "make4", .ret = .vec4 },
    .{ .receiver = "simd", .name = "load4", .ret = .vec4 },
    .{ .receiver = "simd", .name = "add4", .ret = .vec4 },
    .{ .receiver = "simd", .name = "sub4", .ret = .vec4 },
    .{ .receiver = "simd", .name = "mul4", .ret = .vec4 },
    .{ .receiver = "simd", .name = "div4", .ret = .vec4 },
    .{ .receiver = "simd", .name = "fma4", .ret = .vec4 },
    .{ .receiver = "simd", .name = "sum4", .ret = .double },
    .{ .receiver = "simd", .name = "store4", .ret = .void_ },

    .{ .receiver = "simd", .name = "splatU8x16", .ret = .vec_u8x16 },
    .{ .receiver = "simd", .name = "loadU8x16", .ret = .vec_u8x16 },
    .{ .receiver = "simd", .name = "storeU8x16", .ret = .void_ },
    .{ .receiver = "simd", .name = "addU8x16", .ret = .vec_u8x16 },
    .{ .receiver = "simd", .name = "subU8x16", .ret = .vec_u8x16 },
    .{ .receiver = "simd", .name = "andU8x16", .ret = .vec_u8x16 },
    .{ .receiver = "simd", .name = "orU8x16", .ret = .vec_u8x16 },
    .{ .receiver = "simd", .name = "xorU8x16", .ret = .vec_u8x16 },
    .{ .receiver = "simd", .name = "eqU8x16", .ret = .vec_u8x16 },
    .{ .receiver = "simd", .name = "movemaskU8x16", .ret = .int },

    .{ .receiver = "simd", .name = "splatU32x4", .ret = .vec_u32x4 },
    .{ .receiver = "simd", .name = "loadU32x4", .ret = .vec_u32x4 },
    .{ .receiver = "simd", .name = "storeU32x4", .ret = .void_ },
    .{ .receiver = "simd", .name = "addU32x4", .ret = .vec_u32x4 },
    .{ .receiver = "simd", .name = "subU32x4", .ret = .vec_u32x4 },
    .{ .receiver = "simd", .name = "andU32x4", .ret = .vec_u32x4 },
    .{ .receiver = "simd", .name = "orU32x4", .ret = .vec_u32x4 },
    .{ .receiver = "simd", .name = "xorU32x4", .ret = .vec_u32x4 },
    .{ .receiver = "simd", .name = "shlU32x4", .ret = .vec_u32x4 },
    .{ .receiver = "simd", .name = "shrU32x4", .ret = .vec_u32x4 },

    .{ .receiver = "simd", .name = "splatU64x2", .ret = .vec_u64x2 },
    .{ .receiver = "simd", .name = "loadU64x2", .ret = .vec_u64x2 },
    .{ .receiver = "simd", .name = "storeU64x2", .ret = .void_ },
    .{ .receiver = "simd", .name = "addU64x2", .ret = .vec_u64x2 },
    .{ .receiver = "simd", .name = "subU64x2", .ret = .vec_u64x2 },
    .{ .receiver = "simd", .name = "andU64x2", .ret = .vec_u64x2 },
    .{ .receiver = "simd", .name = "orU64x2", .ret = .vec_u64x2 },
    .{ .receiver = "simd", .name = "xorU64x2", .ret = .vec_u64x2 },
    .{ .receiver = "simd", .name = "shlU64x2", .ret = .vec_u64x2 },
    .{ .receiver = "simd", .name = "shrU64x2", .ret = .vec_u64x2 },

    .{ .receiver = "simd", .name = "clmulU64x2", .ret = .vec_u64x2 },

    .{ .receiver = "simd", .name = "laneU64x2", .ret = .long },

    .{ .receiver = "simd", .name = "mulhi64", .ret = .long },

    .{ .receiver = "simd", .name = "castU64x2", .ret = .vec_u64x2 },
    .{ .receiver = "simd", .name = "castU8x16", .ret = .vec_u8x16 },
    .{ .receiver = "simd", .name = "castU32x4", .ret = .vec_u32x4 },

    .{ .receiver = "mem", .name = "xorBytes", .ret = .void_ },

    .{ .receiver = "console", .name = "log", .ret = .void_ },
    .{ .receiver = "console", .name = "info", .ret = .void_ },
    .{ .receiver = "console", .name = "err", .ret = .void_ },
    .{ .receiver = "console", .name = "debug", .ret = .void_ },
};

/// Bare-name functions that bind directly to a runtime or ABI symbol.
///
/// These have an empty receiver and are resolved by [`findExtern`]. They fall
/// into a few families: the `nova_test_*` unit-test harness hooks; the coroutine
/// / reactor ABI (`currentCoro`, `coroStart`, `nova_reactor_*`, `nova_run_reactors`)
/// that async lowering calls into; locking and threading primitives
/// (`nova_mutex_*`, `nova_spin_*`, `nova_thread_id`); low-level numeric and
/// protocol helpers (`nova_f64_bits`, `nova_pg_be_f64` for Postgres big-endian
/// wire decode, `nova_html_find_meta`); process control (`nova_exit`,
/// `nova_process_*`, `nova_arg_*`); and tracing (`nova_trace_*`). A name absent
/// from this table is NOT a builtin extern and must resolve some other way (see
/// the `bare-name runtime functions resolve` test).
pub const externs = [_]Builtin{
    .{ .receiver = "", .name = "nova_test_fail", .ret = .void_ },

    .{ .receiver = "", .name = "nova_test_reset", .ret = .void_ },
    .{ .receiver = "", .name = "nova_test_begin", .ret = .void_ },
    .{ .receiver = "", .name = "nova_test_did_fail", .ret = .int },
    .{ .receiver = "", .name = "nova_test_fail_message", .ret = .string },
    .{ .receiver = "", .name = "nova_arc_audit_report", .ret = .long },
    .{ .receiver = "", .name = "nova_exit", .ret = .void_ },
    .{ .receiver = "", .name = "nova_arg_count", .ret = .long },
    .{ .receiver = "", .name = "nova_arg_at", .ret = .string },

    .{ .receiver = "", .name = "nova_f64_bits", .ret = .long },
    .{ .receiver = "", .name = "nova_pg_be_f64", .ret = .double },
    .{ .receiver = "", .name = "nova_pg_be_i64", .ret = .long },
    .{ .receiver = "", .name = "nova_html_find_meta", .ret = .int },

    .{ .receiver = "", .name = "nova_f64_sqrt", .ret = .double },

    .{ .receiver = "", .name = "nova_mutex_create", .ret = .long },
    .{ .receiver = "", .name = "nova_mutex_lock", .ret = .void_ },
    .{ .receiver = "", .name = "nova_mutex_unlock", .ret = .void_ },

    .{ .receiver = "", .name = "nova_thread_id", .ret = .long },
    .{ .receiver = "", .name = "nova_worker_count", .ret = .long },

    .{ .receiver = "", .name = "nova_pin_next_coro", .ret = .void_ },

    .{ .receiver = "", .name = "nova_trace_msg", .ret = .void_ },
    .{ .receiver = "", .name = "nova_trace_kv", .ret = .void_ },
    .{ .receiver = "", .name = "nova_trace_enabled", .ret = .int },

    .{ .receiver = "", .name = "currentCoro", .ret = .long },
    .{ .receiver = "", .name = "coroSuspend", .ret = .void_ },
    .{ .receiver = "", .name = "coroStart", .ret = .long },
    .{ .receiver = "", .name = "nova_reactor_resume", .ret = .long },
    .{ .receiver = "", .name = "nova_run_reactors", .ret = .void_ },
    .{ .receiver = "", .name = "nova_reactor_set_current", .ret = .void_ },
    .{ .receiver = "", .name = "nova_reactor_current", .ret = .long },
    .{ .receiver = "", .name = "nova_reactor_set_timer", .ret = .void_ },
    .{ .receiver = "", .name = "nova_reactor_cancel_timer", .ret = .void_ },
    .{ .receiver = "", .name = "nova_reactor_batch_begin", .ret = .void_ },
    .{ .receiver = "", .name = "nova_mono_ms", .ret = .long },
    .{ .receiver = "", .name = "nova_reactor_wake_register", .ret = .void_ },
    .{ .receiver = "", .name = "nova_reactor_post", .ret = .void_ },
    .{ .receiver = "", .name = "nova_reactor_drain_one", .ret = .long },
    .{ .receiver = "", .name = "nova_evfilt_user", .ret = .long },

    .{ .receiver = "", .name = "nova_hold_all_reactors", .ret = .void_ },

    .{ .receiver = "", .name = "nova_spin_create", .ret = .long },
    .{ .receiver = "", .name = "nova_spin_lock", .ret = .void_ },
    .{ .receiver = "", .name = "nova_spin_unlock", .ret = .void_ },
    .{ .receiver = "", .name = "nova_close", .ret = .void_ },
    .{ .receiver = "", .name = "nova_getrandom", .ret = .void_ },

    .{ .receiver = "", .name = "nova_process_try_wait", .ret = .int },
    .{ .receiver = "", .name = "nova_process_pid", .ret = .long },
    .{ .receiver = "", .name = "nova_aserver_listen_addr", .ret = .long },
    .{ .receiver = "", .name = "nova_process_spawn_isolated", .ret = .ptr },
};

/// Looks up a bare runtime extern by exact name, or `null` if it is not one.
///
/// Linear scan over [`externs`]. Returning `null` is meaningful, not an error:
/// it tells the resolver this identifier is not a known runtime symbol so it can
/// fall through to normal name resolution.
pub fn findExtern(name: []const u8) ?Builtin {
    for (externs) |b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

/// Reports whether `name` is a builtin namespace (the left side of a
/// `receiver.method` builtin call).
///
/// Used during resolution to distinguish a magic namespace like `bytes` or
/// `simd` from an ordinary undefined variable, so `bytes.alloc(...)` is not
/// flagged as "use of unknown identifier `bytes`". A receiver is recognised if
/// ANY entry in [`table`] carries it.
pub fn isReceiver(name: []const u8) bool {
    for (table) |b| {
        if (std.mem.eql(u8, b.receiver, name)) return true;
    }
    return false;
}

/// Resolves a specific namespaced builtin method, or `null` if that
/// receiver/name pair is not registered.
///
/// Both components must match exactly. A `null` here means the call is not a
/// builtin method (e.g. `console.alloc`, `alloc` exists only under `bytes`),
/// which is a normal resolution outcome rather than an error. Linear scan over
/// [`table`].
pub fn find(receiver: []const u8, name: []const u8) ?Builtin {
    for (table) |b| {
        if (std.mem.eql(u8, b.receiver, receiver) and std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

/// Materialises the concrete [`types.TypeId`] for a [`Ret`] tag against a live
/// type store.
///
/// This is the bridge from the store-independent table to a real type: each
/// [`Ret`] variant is mapped to the corresponding interned type in `store`
/// (e.g. `.ptr` → `store.ptrT()`, `.vec_u64x2` → `store.vecU64x2T()`). Called
/// once a builtin call has been resolved via [`find`] / [`findExtern`] and its
/// result type is needed for inference. Propagates any error from the store's
/// type constructors.
pub fn retType(store: *types.TypeStore, r: Ret) !types.TypeId {
    return switch (r) {
        .void_ => store.voidT(),
        .int => store.intT(),
        .long => store.longT(),
        .ptr => store.ptrT(),
        .string => store.stringT(),
        .bool_ => store.boolT(),
        .decimal => store.decimalT(),
        .double => store.doubleT(),
        .vec4 => store.vecF64x4T(),
        .vec_u8x16 => store.vecU8x16T(),
        .vec_u32x4 => store.vecU32x4T(),
        .vec_u64x2 => store.vecU64x2T(),
    };
}

/// Alias for `std.testing`, the fixture namespace for the tests below.
const testing = std.testing;

// Guards the load-bearing invariant that `bytes.alloc` returns [`Ret.ptr`],
// materialises to a pointer type, is distinct from `int`, and is not ARC-owned
// (the raw allocation is not a reference-counted heap object).
test "builtins: bytes.alloc returns a POINTER, not an int" {

    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();

    const alloc = find("bytes", "alloc").?;
    try testing.expectEqual(Ret.ptr, alloc.ret);
    const t = try retType(&store, alloc.ret);
    try testing.expect(store.get(t) == .ptr);
    try testing.expect(t != try store.intT());
    try testing.expect(!store.isOwned(t));
}

// Checks that every builtin which hands back a memory address agrees on
// [`Ret.ptr`], so none of them silently truncates a pointer to `int`.
test "builtins: the address-yielding ones all agree" {
    for ([_][]const u8{ "alloc", "alloc_persistent", "new", "new_persistent", "new_with_allocator", "read_ptr" }) |n| {
        const b = find("bytes", n) orelse return error.TestExpectedEqual;
        try testing.expectEqual(Ret.ptr, b.ret);
    }
}

// Checks the `bytes` read/write symmetry: typed reads (`read_byte`, `read_i32`,
// `ptr_size`) yield a value, while the mutating writes and `free` yield
// [`Ret.void_`].
test "builtins: reads yield values, writes yield void" {
    try testing.expectEqual(Ret.int, find("bytes", "read_byte").?.ret);
    try testing.expectEqual(Ret.int, find("bytes", "read_i32").?.ret);
    try testing.expectEqual(Ret.int, find("bytes", "ptr_size").?.ret);
    try testing.expectEqual(Ret.void_, find("bytes", "write_byte").?.ret);
    try testing.expectEqual(Ret.void_, find("bytes", "write_i32").?.ret);
    try testing.expectEqual(Ret.void_, find("bytes", "write_ptr").?.ret);
    try testing.expectEqual(Ret.void_, find("bytes", "free").?.ret);
}

// Checks that all `console.*` logging sinks return [`Ret.void_`] (they are
// side-effecting prints, not expressions).
test "builtins: console is all void" {
    for ([_][]const u8{ "log", "info", "err", "debug" }) |n| {
        try testing.expectEqual(Ret.void_, find("console", n).?.ret);
    }
}

// Checks that the full `nova_test_*` harness surface is registered in
// [`externs`] with the right return types, not just an arbitrary one of them
// (a regression guard against dropping a hook when editing the table).
test "externs: the WHOLE test harness is declared, not just one of it" {

    try testing.expectEqual(Ret.void_, findExtern("nova_test_reset").?.ret);
    try testing.expectEqual(Ret.int, findExtern("nova_test_did_fail").?.ret);
    try testing.expectEqual(Ret.string, findExtern("nova_test_fail_message").?.ret);
    try testing.expectEqual(Ret.void_, findExtern("nova_test_fail").?.ret);
}

// Checks [`findExtern`] both ways: a registered name resolves, and names that
// are NOT builtin externs (a real runtime symbol not in the table, an internal
// codegen helper, and pure nonsense) all return `null`.
test "externs: bare-name runtime functions resolve" {

    try testing.expectEqual(Ret.void_, findExtern("nova_test_fail").?.ret);
    try testing.expect(findExtern("nova_file_open") == null);
    try testing.expect(findExtern("__i32_to_string") == null);
    try testing.expect(findExtern("not_an_extern") == null);
}

// Checks [`isReceiver`] and [`find`] together: known namespaces (`bytes`,
// `console`) are recognised, a non-namespace type name (`string`) and nonsense
// are not, and [`find`] rejects both an unknown method and a method borrowed
// from the wrong receiver.
test "builtins: receivers are recognised; unknowns are not" {
    try testing.expect(isReceiver("bytes"));
    try testing.expect(isReceiver("console"));
    try testing.expect(!isReceiver("string"));
    try testing.expect(!isReceiver("nosuch"));
    try testing.expect(find("bytes", "no_such_method") == null);
    try testing.expect(find("console", "alloc") == null);
}
