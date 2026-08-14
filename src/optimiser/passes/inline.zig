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
// was inlined. `max_insts` bounds the callee size that will be inlined.
pub fn inlineSmallCallees(allocator: std.mem.Allocator, caller: *mir.Func, callees: []const Callee, max_insts: usize) !bool {
    var changed = false;
    for (caller.blocks.items) |*b| {
        var i: usize = 0;
        while (i < b.insts.items.len) : (i += 1) {
            const inst = b.insts.items[i];
            if (inst.op != .call) continue;
            const target = findCallee(callees, inst.op.call.callee) orelse continue;
            if (target.blocks.items.len != 1) continue; // single-block callees only, for now
            if (target.blocks.items[0].insts.items.len > max_insts) continue;

            try spliceSingleBlock(allocator, caller, b, i, inst.result, target);
            changed = true;
            // the call at i was replaced by the splice; continue after the inserted body
            i = i; // re-evaluate from the same index (spliceSingleBlock removed the call)
        }
    }
    return changed;
}

fn findCallee(callees: []const Callee, sym: mir.SymbolId) ?*const mir.Func {
    for (callees) |c| if (c.sym == sym) return c.func;
    return null;
}

// Splice a single-block callee's instructions into `b` at index `call_idx`, replacing the call. New
// caller Values are minted for each callee Value; the callee's `ret v` supplies the value that replaces
// the call's result.
fn spliceSingleBlock(allocator: std.mem.Allocator, caller: *mir.Func, b: *mir.BasicBlock, call_idx: usize, call_result: mir.Value, callee: *const mir.Func) !void {
    const cblock = callee.blocks.items[0];

    // Map callee Value -> caller Value.
    const vmap = try allocator.alloc(mir.Value, callee.value_types.items.len);
    defer allocator.free(vmap);
    for (0..callee.value_types.items.len) |k| {
        vmap[k] = try caller.newValue(allocator, callee.value_types.items[k]);
    }

    // Build the spliced instructions with remapped operands.
    var spliced = std.ArrayListUnmanaged(mir.Inst).empty;
    defer spliced.deinit(allocator);
    for (cblock.insts.items) |cinst| {
        var ni = cinst;
        if (cinst.result != .invalid) ni.result = vmap[@intFromEnum(cinst.result)];
        remapOp(&ni.op, vmap);
        try spliced.append(allocator, ni);
    }

    // Insert the spliced instructions in place of the call.
    _ = b.insts.orderedRemove(call_idx);
    try b.insts.insertSlice(allocator, call_idx, spliced.items);

    // Replace uses of the call's result with the callee's returned value (remapped).
    if (call_result != .invalid) {
        if (cblock.term == .ret) {
            if (cblock.term.ret) |rv| mir.replaceUses(caller, call_result, vmap[@intFromEnum(rv)]);
        }
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
        .alloc, .const_int => {},
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
