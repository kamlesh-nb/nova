// builtins.zig — F2 stage 2e: declare the builtins.
//
// `console` and `bytes` have NO .nova file. They are hardcoded inside codegen —
// `expressions.zig:942` (protocol.callDecoder), `:956` (bytes.*), the console
// branch at `:881-940`, and more — as a scatter of `mem.eql(u8, fa.object.kind.ident,
// "bytes")` special cases. So F2 could not type `console.log(...)` or
// `bytes.alloc(n)`: **there is nothing to resolve against.** F2 cannot type what
// was never declared, and that is not F2's bug — it is the same disease one level
// up, behaviour living in codegen instead of being declared.
//
// This is the first place the builtin surface is written down in ONE list.
//
// ⚠️ THE INTERESTING PART — this table is where the `ptr` lie is born.
// `bytes.alloc(n)` returns a raw ADDRESS. Codegen types it `i32`
// (codegen/types.zig:252 hardcodes `bytes.*` -> "i32"), which is precisely why the
// stdlib is full of `data: i32` / `buf: i32` / `handle: i32` (F3 §2.4, 9 structs,
// 53 call sites) — those fields are not integers, they are pointers, and they only
// survive because `i32` is secretly the 64-bit machine word. Declared here as
// `ptr` (F3 §3.2), the honest type. That makes this table F3's fix at the ROOT
// rather than at the 53 leaves: once `bytes.alloc` says `ptr`, every field holding
// its result is a type error until it says `ptr` too.
const std = @import("std");
const types = @import("../types.zig");

/// What a builtin yields. Deliberately small — this is a signature table, not a
/// type system; the type system is ../types.zig.
pub const Ret = enum { void_, int, long, ptr, string, bool_, decimal };

pub const Builtin = struct {
    /// The receiver it is used under: `bytes.alloc` -> "bytes".
    receiver: []const u8,
    name: []const u8,
    ret: Ret,
};

/// The complete builtin surface, recovered from codegen's special cases and from
/// what the stdlib actually calls. Counts are uses across src/std + conformance.
pub const table = [_]Builtin{
    // ---- bytes: raw memory. Every one of these traffics in ADDRESSES. --------
    .{ .receiver = "bytes", .name = "alloc", .ret = .ptr }, // x41 — NOT an int
    .{ .receiver = "bytes", .name = "alloc_persistent", .ret = .ptr }, // x10
    .{ .receiver = "bytes", .name = "new", .ret = .ptr },
    .{ .receiver = "bytes", .name = "new_persistent", .ret = .ptr },
    .{ .receiver = "bytes", .name = "new_with_allocator", .ret = .ptr }, // x3
    .{ .receiver = "bytes", .name = "free", .ret = .void_ }, // x29
    .{ .receiver = "bytes", .name = "read_byte", .ret = .int }, // x44
    .{ .receiver = "bytes", .name = "write_byte", .ret = .void_ }, // x107
    .{ .receiver = "bytes", .name = "read_ptr", .ret = .ptr }, // x23
    .{ .receiver = "bytes", .name = "write_ptr", .ret = .void_ }, // x17
    .{ .receiver = "bytes", .name = "read_i32", .ret = .int }, // x20
    .{ .receiver = "bytes", .name = "write_i32", .ret = .void_ }, // x18
    .{ .receiver = "bytes", .name = "read_string", .ret = .string },
    // decimal128 <-> raw 16 bytes (BSON decimal128 is exactly these 16 BID bytes). The BID payload IS
    // the wire format, so these are a straight memcpy — the MongoDB driver's decimal hook (specs §3.1).
    .{ .receiver = "bytes", .name = "write_decimal", .ret = .void_ },   // (dst: ptr, offset: int, d: decimal)
    .{ .receiver = "bytes", .name = "read_decimal", .ret = .decimal },  // (src: ptr, offset: int) -> decimal
    .{ .receiver = "bytes", .name = "ptr_size", .ret = .int }, // x17
    .{ .receiver = "bytes", .name = "length", .ret = .int }, // x2
    .{ .receiver = "bytes", .name = "len", .ret = .int },

    // ---- decimal: explicit int <-> decimal conversion (S3; no implicit coercion) ----
    .{ .receiver = "decimal", .name = "fromInt", .ret = .decimal }, // (n: int) -> decimal
    .{ .receiver = "decimal", .name = "toInt", .ret = .int },       // (d: decimal) -> int (truncates; traps on overflow)
    .{ .receiver = "decimal", .name = "fromString", .ret = .decimal }, // S4: (s: string) -> decimal (exact BID parse)

    // ---- console: all void ---------------------------------------------------
    .{ .receiver = "console", .name = "log", .ret = .void_ }, // x34
    .{ .receiver = "console", .name = "info", .ret = .void_ },
    .{ .receiver = "console", .name = "err", .ret = .void_ },
    .{ .receiver = "console", .name = "debug", .ret = .void_ },
};

/// Runtime externs: C functions the codegen declares (declarations.zig:111-1374)
/// and that .nova source calls directly, by bare name. Like `bytes`/`console` they
/// have NO .nova declaration — but unlike them they are not even namespaced, so
/// they collide with user functions in the flat namespace by construction (§10 #7).
///
/// A8 (2026-07-16): the compiler-injected `__i32_to_string`/`__bool_to_string` are
/// GONE — concat and `${}` interpolation now stringify via the runtime helpers
/// (nova_i64_to_string / nova_bool_to_string / nova_f64_to_string), and every stdlib
/// caller was migrated to `${}`.
pub const externs = [_]Builtin{
    .{ .receiver = "", .name = "nova_test_fail", .ret = .void_ }, // x34
    // The rest of the test harness's externs. codegen declares all four
    // (declarations.zig:208-224) but this table listed ONE, so F2 could not type
    // the other three and every call to them counted as a generics gap: 30 of the
    // 124 "F2 unresolved" divergences were three missing rows here.
    .{ .receiver = "", .name = "nova_test_reset", .ret = .void_ }, // declarations.zig:209 — void -> void
    .{ .receiver = "", .name = "nova_test_begin", .ret = .void_ }, // (ptr) -> void — names the running @test
    .{ .receiver = "", .name = "nova_test_did_fail", .ret = .int }, // :219 — void -> i32
    .{ .receiver = "", .name = "nova_test_fail_message", .ret = .string }, // :224 — void -> ptr(string)
    .{ .receiver = "", .name = "nova_arc_audit_report", .ret = .long }, // F5 §3.5.1 — leaked object count
    .{ .receiver = "", .name = "nova_exit", .ret = .void_ },
    .{ .receiver = "", .name = "nova_arg_count", .ret = .long }, // argc — env.args()
    .{ .receiver = "", .name = "nova_arg_at", .ret = .string }, // argv[i] as a Nova string
    .{ .receiver = "", .name = "nova_file_open", .ret = .ptr }, // FILE* — a pointer, not an fd (F3 §3.2)
    .{ .receiver = "", .name = "nova_file_close", .ret = .void_ },
    .{ .receiver = "", .name = "nova_file_write", .ret = .int },
    .{ .receiver = "", .name = "nova_file_seek", .ret = .int },
    .{ .receiver = "", .name = "nova_file_tell", .ret = .int },
    // read_all returns the INT byte-count read (io.cpp: `int nova_file_read_all`), NOT a
    // string. Typed `.string` it made codegen ARC-RELEASE the returned count as a pointer
    // (releasing address 21 for a 21-byte read) → SIGSEGV — the same trap flagged for recv
    // below. File.readText discards the count and reads into its own buffer.
    .{ .receiver = "", .name = "nova_file_read_all", .ret = .int },
    // double's raw IEEE-754 bits as a long (bit_cast), for binary wire formats (BSON double).
    .{ .receiver = "", .name = "nova_f64_bits", .ret = .long },
    .{ .receiver = "", .name = "nova_socket_send", .ret = .int },
    .{ .receiver = "", .name = "nova_socket_send_n", .ret = .int },
    // recv returns the INT byte-count received (its only caller uses it as `bytes.alloc(n)`
    // and `n <= 0`), NOT a string. Typed `.string` it made the codegen ARC-release the
    // integer count as if it were an owned string pointer — `nova_release(5)` reads a header
    // at address 5-8 = -3 and segfaults on clean teardown (latent; masked in the long-running
    // server that never tears these locals down). read() builds the string itself from the buffer.
    .{ .receiver = "", .name = "nova_socket_recv", .ret = .int },
    .{ .receiver = "", .name = "nova_socket_connect", .ret = .int },
    // D6: connect with a wall-clock deadline (ms) + apply per-socket recv/send timeout (ms).
    .{ .receiver = "", .name = "nova_socket_connect_timeout", .ret = .int },
    .{ .receiver = "", .name = "nova_socket_set_timeout", .ret = .int },
    .{ .receiver = "", .name = "nova_close", .ret = .void_ },
    // TDS-tunneled TLS (MSSQL driver): opaque ctx as ptr; handshake/write/read return int.
    .{ .receiver = "", .name = "nova_tds_tls_new", .ret = .ptr },
    .{ .receiver = "", .name = "nova_tds_tls_handshake", .ret = .int },
    .{ .receiver = "", .name = "nova_tds_tls_write", .ret = .int },
    .{ .receiver = "", .name = "nova_tds_tls_read", .ret = .int },
    .{ .receiver = "", .name = "nova_tds_tls_free", .ret = .void_ },
    // Async memory-BIO TLS (net/asynctls.nova pump).
    .{ .receiver = "", .name = "nova_mtls_new", .ret = .ptr },
    .{ .receiver = "", .name = "nova_mtls_new_server", .ret = .ptr },
    .{ .receiver = "", .name = "nova_mtls_handshake", .ret = .int },
    .{ .receiver = "", .name = "nova_mtls_feed", .ret = .void_ },
    .{ .receiver = "", .name = "nova_mtls_mark_closed", .ret = .void_ },
    .{ .receiver = "", .name = "nova_mtls_pull", .ret = .int },
    .{ .receiver = "", .name = "nova_mtls_pending_out", .ret = .int },
    .{ .receiver = "", .name = "nova_mtls_write", .ret = .int },
    .{ .receiver = "", .name = "nova_mtls_read", .ret = .int },
    .{ .receiver = "", .name = "nova_mtls_free", .ret = .void_ },
};

/// A bare-name runtime extern, e.g. `nova_test_fail(msg)`.
pub fn findExtern(name: []const u8) ?Builtin {
    for (externs) |b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

/// Is `name` a builtin receiver? Used to distinguish `bytes.alloc(n)` from a
/// variable's member — the same "is the object a variable" question F1 answers in
/// codegen, asked of a name that has no module either.
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

/// Resolve a builtin's return type against the type store.
pub fn retType(store: *types.TypeStore, r: Ret) !types.TypeId {
    return switch (r) {
        .void_ => store.voidT(),
        .int => store.intT(),
        .long => store.longT(),
        .ptr => store.ptrT(),
        .string => store.stringT(),
        .bool_ => store.boolT(),
        .decimal => store.decimalT(),
    };
}

// ---------------------------------------------------------------------------
// Tests (docs/design/README.md §2b).
// ---------------------------------------------------------------------------
const testing = std.testing;

test "builtins: bytes.alloc returns a POINTER, not an int" {
    // This is the whole point of the table. codegen/types.zig:252 hardcodes every
    // `bytes.*` to "i32", which is where `data: i32` / `buf: i32` / `handle: i32`
    // come from — 9 structs, 53 call sites (F3 §2.4). They are not integers; they
    // are addresses that only survive because i32 is secretly the machine word.
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();

    const alloc = find("bytes", "alloc").?;
    try testing.expectEqual(Ret.ptr, alloc.ret);
    const t = try retType(&store, alloc.ret);
    try testing.expect(store.get(t) == .ptr);
    try testing.expect(t != try store.intT()); // the lie, made inexpressible
    try testing.expect(!store.isOwned(t)); // a ptr is explicitly unowned (F5 O2)
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
    // codegen declares four (declarations.zig:208-224); this table had one. F2
    // cannot type what was never declared, so the three missing rows showed up as
    // 30 untypeable calls and got counted against generics. A table that is a
    // SUBSET of what codegen declares reports its own omissions as language gaps.
    try testing.expectEqual(Ret.void_, findExtern("nova_test_reset").?.ret);
    try testing.expectEqual(Ret.int, findExtern("nova_test_did_fail").?.ret);
    try testing.expectEqual(Ret.string, findExtern("nova_test_fail_message").?.ret);
    try testing.expectEqual(Ret.void_, findExtern("nova_test_fail").?.ret);
}

test "externs: bare-name runtime functions resolve" {
    // nova_test_fail is called 34x from assert.nova and declared in NO .nova file —
    // codegen declares it as a C extern. Bare-named, so it shares the flat
    // namespace with user code by construction.
    try testing.expectEqual(Ret.void_, findExtern("nova_test_fail").?.ret);
    try testing.expectEqual(Ret.ptr, findExtern("nova_file_open").?.ret);
    try testing.expect(findExtern("__i32_to_string") == null); // A8: deleted
    try testing.expect(findExtern("not_an_extern") == null);
}

test "builtins: receivers are recognised; unknowns are not" {
    try testing.expect(isReceiver("bytes"));
    try testing.expect(isReceiver("console"));
    try testing.expect(!isReceiver("string")); // a real module, not a builtin
    try testing.expect(!isReceiver("nosuch"));
    try testing.expect(find("bytes", "no_such_method") == null);
    try testing.expect(find("console", "alloc") == null); // receivers don't share
}
