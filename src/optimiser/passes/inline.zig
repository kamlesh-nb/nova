// inline.zig — bounded inlining of small callees.
//
// Inlines a `call` to a small single-block callee by splicing the callee's instructions into the caller
// (allocating fresh caller Values for each callee Value and rewriting operands through that map), then
// replacing the call's result with the callee's returned value. Bounded by an instruction budget so code
// size cannot blow up. Single-block callees cover the tiny accessors and generated binders that Nova
// emits in quantity; inlining them removes call overhead and, more importantly, exposes cross-call ARC
// pairs to arc_elision.
//
// DORMANT on real code today: the lowering leaves `call.callee` a placeholder and there is no MIR call
// graph yet (that needs symbol resolution wiring the callee's MirFunc). The transform is implemented and
// unit-tested here so it is correct and ready; the pipeline pass is a no-op until the driver passes a
// callee map. See docs/design/optimiser.md.

const std = @import("std");
const mir = @import("../mir.zig");
const Pass = @import("../pass.zig").Pass;

pub const pass = Pass{ .name = "inline", .run = run };

// Pipeline entry: no callee graph is available at pass level, so this is a no-op. Activation is
// driver-level (inlineSmallCallees with a resolved callee map).
fn run(allocator: std.mem.Allocator, func: *mir.Func) anyerror!bool {
    _ = allocator;
    _ = func;
    return false;
}

pub const Callee = struct { sym: mir.SymbolId, func: *const mir.Func };

// Inline every call in `caller` to a small single-block callee from `callees`. Returns true if anything
// was inlined. `max_insts` bounds the callee size. Rebuilds each block's instruction list rather than
// mutating in place, so spliced instructions are never re-examined (single-level inlining per invocation;
// nested inlining would come from re-running the pass). A callee's `ret v` supplies the value that
// replaces the call's result.
pub fn inlineSmallCallees(allocator: std.mem.Allocator, caller: *mir.Func, callees: []const Callee, max_insts: usize) !bool {
    var changed = false;
    for (caller.blocks.items) |*b| {
        var out = std.ArrayListUnmanaged(mir.Inst).empty;
        errdefer out.deinit(allocator);
        for (b.insts.items) |inst| {
            if (inst.op == .call) {
                if (findCallee(callees, inst.op.call.callee)) |target| {
                    if (target != caller and target.blocks.items.len == 1 and target.blocks.items[0].insts.items.len <= max_insts) {
                        try spliceInto(allocator, caller, &out, inst.result, target);
                        changed = true;
                        continue;
                    }
                }
            }
            try out.append(allocator, inst);
        }
        b.insts.deinit(allocator);
        b.insts = out;
    }
    return changed;
}

fn findCallee(callees: []const Callee, sym: mir.SymbolId) ?*const mir.Func {
    for (callees) |c| if (c.sym == sym) return c.func;
    return null;
}

// Append a single-block callee's instructions (with operands remapped to fresh caller Values) onto `out`,
// and replace uses of the call's result with the callee's returned value.
fn spliceInto(allocator: std.mem.Allocator, caller: *mir.Func, out: *std.ArrayListUnmanaged(mir.Inst), call_result: mir.Value, callee: *const mir.Func) !void {
    const cblock = callee.blocks.items[0];

    const vmap = try allocator.alloc(mir.Value, callee.value_types.items.len);
    defer allocator.free(vmap);
    for (0..callee.value_types.items.len) |k| {
        vmap[k] = try caller.newValue(allocator, callee.value_types.items[k]);
    }

    for (cblock.insts.items) |cinst| {
        var ni = cinst;
        if (cinst.result != .invalid) ni.result = vmap[@intFromEnum(cinst.result)];
        // Duplicate any args slice before remapping: `ni = cinst` shares the callee's slice, and remapOp
        // mutates operands in place -- without a copy it would corrupt the (const) callee body.
        switch (ni.op) {
            .call => |*x| x.args = try allocator.dupe(mir.Value, x.args),
            .indirect_call => |*x| x.args = try allocator.dupe(mir.Value, x.args),
            .spawn_ => |*x| x.args = try allocator.dupe(mir.Value, x.args),
            else => {},
        }
        remapOp(&ni.op, vmap);
        try out.append(allocator, ni);
    }

    if (call_result != .invalid and cblock.term == .ret) {
        if (cblock.term.ret) |rv| mir.replaceUses(caller, call_result, vmap[@intFromEnum(rv)]);
    }
}

fn remapOp(op: *mir.Inst.Op, vmap: []const mir.Value) void {
    // Reuse the shared rewrite by walking each callee value; simplest correct approach for small callees.
    switch (op.*) {
        .binop => |*x| {
            x.lhs = vmap[@intFromEnum(x.lhs)];
            x.rhs = vmap[@intFromEnum(x.rhs)];
        },
        .load => |*x| x.addr = vmap[@intFromEnum(x.addr)],
        .store => |*x| {
            x.addr = vmap[@intFromEnum(x.addr)];
            x.val = vmap[@intFromEnum(x.val)];
        },
        .gep => |*x| x.base = vmap[@intFromEnum(x.base)],
        .cast => |*x| x.val = vmap[@intFromEnum(x.val)],
        .retain => |*x| x.val = vmap[@intFromEnum(x.val)],
        .release => |*x| x.val = vmap[@intFromEnum(x.val)],
        .await_ => |*x| x.fut = vmap[@intFromEnum(x.fut)],
        .call => |*x| for (x.args) |*arg| {
            arg.* = vmap[@intFromEnum(arg.*)];
        },
        .indirect_call => |*x| {
            x.receiver = vmap[@intFromEnum(x.receiver)];
            for (x.args) |*arg| arg.* = vmap[@intFromEnum(arg.*)];
        },
        .spawn_ => |*x| for (x.args) |*arg| {
            arg.* = vmap[@intFromEnum(arg.*)];
        },
        .struct_new => |*x| for (x.args) |*arg| {
            arg.* = vmap[@intFromEnum(arg.*)];
        },
        .field_get => |*x| x.base = vmap[@intFromEnum(x.base)],
        .field_set => |*x| {
            x.base = vmap[@intFromEnum(x.base)];
            x.val = vmap[@intFromEnum(x.val)];
        },
        .alloc, .const_int, .param => {},
    }
}

// --- unit test: inline a tiny accessor callee ---

test "inlines a single-block callee returning a constant" {
    const a = std.testing.allocator;

    // callee: fn() -> 42
    var callee = mir.Func{ .sym = @enumFromInt(7) };
    defer callee.deinit(a);
    const cb = try callee.newBlock(a);
    const cv = try callee.emit(a, cb, @enumFromInt(0), .{ .const_int = 42 });
    callee.setTerm(cb, .{ .ret = cv });

    // caller: r = call #7(); ret r
    var caller = mir.Func{ .sym = @enumFromInt(1) };
    defer caller.deinit(a);
    const b = try caller.newBlock(a);
    const empty_args = try a.alloc(mir.Value, 0);
    defer a.free(empty_args);
    const empty_owns = try a.alloc(bool, 0);
    defer a.free(empty_owns);
    const r = try caller.emit(a, b, @enumFromInt(0), .{ .call = .{ .callee = @enumFromInt(7), .args = empty_args, .takes_ownership = empty_owns } });
    caller.setTerm(b, .{ .ret = r });

    const callees = [_]Callee{.{ .sym = @enumFromInt(7), .func = &callee }};
    const ch = try inlineSmallCallees(a, &caller, &callees, 8);
    try std.testing.expect(ch);

    // the call is gone; a const_int 42 was spliced in
    var found_const = false;
    var found_call = false;
    for (caller.block(b).insts.items) |inst| {
        if (inst.op == .const_int and inst.op.const_int == 42) found_const = true;
        if (inst.op == .call) found_call = true;
    }
    try std.testing.expect(found_const);
    try std.testing.expect(!found_call);
}
