
const std = @import("std");
const types = @import("../types.zig");

pub const Ret = enum { void_, int, long, ptr, string, bool_, decimal, double, vec4, vec_u8x16, vec_u32x4, vec_u64x2 };

pub const Builtin = struct {

    receiver: []const u8,
    name: []const u8,
    ret: Ret,
};

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

    // Explicit SIMD (f64x4). Codegen lowers each to LLVM <4 x double> ops (see compileSimdCall).
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

    // FR-simd-L1 integer vectors. u8x16 (<16 x i8>), u32x4 (<4 x i32>), u64x2 (<2 x i64>). Codegen lowers
    // each to native LLVM vector ops (see compileSimdCall). load/store move a lane group to/from a byte
    // buffer at a byte offset; movemask collapses the sign bits of the 16 bytes to a 16-bit int.
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

    // FR-simd-L2: carryless multiply of two 64-bit scalars -> 128-bit product as u64x2. The GHASH
    // accelerator. Lowers to llvm.aarch64.neon.pmull64 on ARM, llvm.x86.pclmulqdq on x86, and a portable
    // inline software multiply otherwise. Named with the U64x2 suffix so it routes through compileIntSimd.
    .{ .receiver = "simd", .name = "clmulU64x2", .ret = .vec_u64x2 },

    // FR-simd-L5: extract lane `i` of a u64x2 as a 64-bit scalar (bit-exact; the value slot is i64). The
    // register-level alternative to store+reload for pulling a clmul product's lo/hi halves back to scalars.
    .{ .receiver = "simd", .name = "laneU64x2", .ret = .long },

    // FR-mem Tier 3: raw-address XOR. The generic mem builtins (load/store/rotl/rotr/ctz/clz/bswap) are
    // typed by the special-case in infer.zig; xorBytes is non-generic, so it lives in this table.
    .{ .receiver = "mem", .name = "xorBytes", .ret = .void_ },

    .{ .receiver = "console", .name = "log", .ret = .void_ },
    .{ .receiver = "console", .name = "info", .ret = .void_ },
    .{ .receiver = "console", .name = "err", .ret = .void_ },
    .{ .receiver = "console", .name = "debug", .ret = .void_ },
};

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

    // Lowered directly to the llvm.sqrt.f64 intrinsic (hardware fsqrt) in codegen -- not a runtime
    // symbol. math.fsqrt calls this so float-heavy code gets one instruction, not a Newton loop.
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
    // The wolfSSL TLS externs (nova_tds_tls_*, nova_mtls_*) were removed in M13; TLS is pure Nova now.
};

pub fn findExtern(name: []const u8) ?Builtin {
    for (externs) |b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

pub fn isReceiver(name: []const u8) bool {
    for (table) |b| {
        if (std.mem.eql(u8, b.receiver, name)) return true;
    }
    return false;
}

pub fn find(receiver: []const u8, name: []const u8) ?Builtin {
    for (table) |b| {
        if (std.mem.eql(u8, b.receiver, receiver) and std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

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

const testing = std.testing;

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

test "builtins: the address-yielding ones all agree" {
    for ([_][]const u8{ "alloc", "alloc_persistent", "new", "new_persistent", "new_with_allocator", "read_ptr" }) |n| {
        const b = find("bytes", n) orelse return error.TestExpectedEqual;
        try testing.expectEqual(Ret.ptr, b.ret);
    }
}

test "builtins: reads yield values, writes yield void" {
    try testing.expectEqual(Ret.int, find("bytes", "read_byte").?.ret);
    try testing.expectEqual(Ret.int, find("bytes", "read_i32").?.ret);
    try testing.expectEqual(Ret.int, find("bytes", "ptr_size").?.ret);
    try testing.expectEqual(Ret.void_, find("bytes", "write_byte").?.ret);
    try testing.expectEqual(Ret.void_, find("bytes", "write_i32").?.ret);
    try testing.expectEqual(Ret.void_, find("bytes", "write_ptr").?.ret);
    try testing.expectEqual(Ret.void_, find("bytes", "free").?.ret);
}

test "builtins: console is all void" {
    for ([_][]const u8{ "log", "info", "err", "debug" }) |n| {
        try testing.expectEqual(Ret.void_, find("console", n).?.ret);
    }
}

test "externs: the WHOLE test harness is declared, not just one of it" {

    try testing.expectEqual(Ret.void_, findExtern("nova_test_reset").?.ret);
    try testing.expectEqual(Ret.int, findExtern("nova_test_did_fail").?.ret);
    try testing.expectEqual(Ret.string, findExtern("nova_test_fail_message").?.ret);
    try testing.expectEqual(Ret.void_, findExtern("nova_test_fail").?.ret);
}

test "externs: bare-name runtime functions resolve" {

    try testing.expectEqual(Ret.void_, findExtern("nova_test_fail").?.ret);
    // nova_file_open was retired in M5 (file I/O moved to Nova over os/sys), so it no longer resolves.
    try testing.expect(findExtern("nova_file_open") == null);
    try testing.expect(findExtern("__i32_to_string") == null);
    try testing.expect(findExtern("not_an_extern") == null);
}

test "builtins: receivers are recognised; unknowns are not" {
    try testing.expect(isReceiver("bytes"));
    try testing.expect(isReceiver("console"));
    try testing.expect(!isReceiver("string"));
    try testing.expect(!isReceiver("nosuch"));
    try testing.expect(find("bytes", "no_such_method") == null);
    try testing.expect(find("console", "alloc") == null);
}
