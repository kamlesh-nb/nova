
const std = @import("std");
const types = @import("../types.zig");

pub const Ret = enum { void_, int, long, ptr, string, bool_, decimal };

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
    .{ .receiver = "", .name = "nova_file_open", .ret = .ptr },
    .{ .receiver = "", .name = "nova_file_close", .ret = .void_ },
    .{ .receiver = "", .name = "nova_file_write", .ret = .int },
    .{ .receiver = "", .name = "nova_file_seek", .ret = .int },
    .{ .receiver = "", .name = "nova_file_tell", .ret = .int },

    .{ .receiver = "", .name = "nova_file_read_all", .ret = .int },

    .{ .receiver = "", .name = "nova_f64_bits", .ret = .long },

    .{ .receiver = "", .name = "nova_mutex_create", .ret = .long },
    .{ .receiver = "", .name = "nova_mutex_lock", .ret = .void_ },
    .{ .receiver = "", .name = "nova_mutex_unlock", .ret = .void_ },

    .{ .receiver = "", .name = "nova_thread_id", .ret = .long },
    .{ .receiver = "", .name = "nova_worker_count", .ret = .long },

    .{ .receiver = "", .name = "nova_pin_next_coro", .ret = .void_ },

    .{ .receiver = "", .name = "currentCoro", .ret = .long },
    .{ .receiver = "", .name = "coroSuspend", .ret = .void_ },
    .{ .receiver = "", .name = "coroStart", .ret = .long },
    .{ .receiver = "", .name = "nova_reactor_resume", .ret = .long },
    .{ .receiver = "", .name = "nova_run_reactors", .ret = .void_ },
    .{ .receiver = "", .name = "nova_set_reuseport", .ret = .long },

    .{ .receiver = "", .name = "nova_hold_all_reactors", .ret = .void_ },

    .{ .receiver = "", .name = "nova_spin_create", .ret = .long },
    .{ .receiver = "", .name = "nova_spin_lock", .ret = .void_ },
    .{ .receiver = "", .name = "nova_spin_unlock", .ret = .void_ },
    .{ .receiver = "", .name = "nova_socket_send", .ret = .int },
    .{ .receiver = "", .name = "nova_socket_send_n", .ret = .int },

    .{ .receiver = "", .name = "nova_socket_recv", .ret = .int },
    .{ .receiver = "", .name = "nova_socket_connect", .ret = .int },

    .{ .receiver = "", .name = "nova_socket_connect_timeout", .ret = .int },
    .{ .receiver = "", .name = "nova_socket_set_timeout", .ret = .int },
    .{ .receiver = "", .name = "nova_close", .ret = .void_ },

    .{ .receiver = "", .name = "nova_process_try_wait", .ret = .int },
    .{ .receiver = "", .name = "nova_process_pid", .ret = .long },
    .{ .receiver = "", .name = "nova_aserver_listen_addr", .ret = .long },
    .{ .receiver = "", .name = "nova_process_spawn_isolated", .ret = .ptr },

    .{ .receiver = "", .name = "nova_tds_tls_new", .ret = .ptr },
    .{ .receiver = "", .name = "nova_tds_tls_handshake", .ret = .int },
    .{ .receiver = "", .name = "nova_tds_tls_write", .ret = .int },
    .{ .receiver = "", .name = "nova_tds_tls_read", .ret = .int },
    .{ .receiver = "", .name = "nova_tds_tls_free", .ret = .void_ },

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
    try testing.expectEqual(Ret.ptr, findExtern("nova_file_open").?.ret);
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
