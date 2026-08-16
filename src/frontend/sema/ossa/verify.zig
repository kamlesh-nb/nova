// OSSA-lite verifier (Track I / I3) — the REAL, non-vacuous ownership soundness check.
//
// Property (the OSSA linear-ownership invariant): every OWNED value is CONSUMED EXACTLY ONCE on every
// path from its definition to function exit. A consume is `destroy`, `move_out`, or a `ret_owned`
// terminator. Violations this catches:
//   - LEAK            : a value reaches a `ret_void`/`ret_trivial`/`br`-to-exit still live (0 consumes).
//   - DOUBLE-CONSUME  : a value consumed while already consumed (double-free shape).
//   - USE-AFTER-CONSUME: a borrow/use of a value after it was consumed.
//   - PATH-IMBALANCE  : at a control-flow join, one predecessor consumed a value and another did not
//                       (so some path leaks / some path double-frees downstream).
//
// Unlike the AST move-check (which was proven vacuous — it could never enter its violation state), this
// verifier's reject branches are reached by the unit tests below on deliberately-broken IR. Loops
// (back-edges) are conservatively DEFERRED in this first version (reported, never a false positive).

const std = @import("std");
const ir = @import("ir.zig");

pub const Kind = enum { leak, double_consume, use_after_consume, path_imbalance, deferred_loop };

pub const Diagnostic = struct {
    kind: Kind,
    /// offending value (or `.none` for a whole-function deferral).
    value: ir.Value,
};

pub const Result = struct {
    diagnostics: []Diagnostic,
    /// true if the function was fully checked (no loop deferral).
    complete: bool,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.diagnostics);
    }
    pub fn ok(self: *const Result) bool {
        return self.diagnostics.len == 0;
    }
};

const Set = std.DynamicBitSetUnmanaged;

/// Verify one function. Caller owns `Result.diagnostics`.
pub fn verify(gpa: std.mem.Allocator, func: *const ir.Func) !Result {
    var diags = std.ArrayListUnmanaged(Diagnostic).empty;
    errdefer diags.deinit(gpa);

    const nblocks = func.blocks.items.len;
    const nvals = func.values.items.len;
    if (nblocks == 0) return .{ .diagnostics = try diags.toOwnedSlice(gpa), .complete = true };

    // entry[b]: the live-owned set on entry to block b (null until first predecessor sets it).
    const entry = try gpa.alloc(?Set, nblocks);
    defer {
        for (entry) |*e| if (e.*) |*s| s.deinit(gpa);
        gpa.free(entry);
    }
    for (entry) |*e| e.* = null;

    // Blocks are emitted so that every FORWARD edge is index-increasing; the only index-decreasing edges
    // are loop BACK-edges (body -> header). So index order is a valid processing order: when we reach a
    // block, its entry set is already fixed by its forward (pre-loop) predecessor, and a back-edge is
    // handled by COMPARING (the loop must not change the live set) rather than propagating.
    entry[0] = try Set.initEmpty(gpa, nvals);

    var b: usize = 0;
    while (b < nblocks) : (b += 1) {
        var live = if (entry[b]) |s| try s.clone(gpa) else try Set.initEmpty(gpa, nvals);
        defer live.deinit(gpa);

        const blk = &func.blocks.items[b];
        for (blk.instrs.items) |ins| {
            // producers: an owned result becomes live.
            if (ins.result != .none and func.ownershipOf(ins.result) == .owned) {
                live.set(ins.result.index());
            }
            // consumers: the operand must be live; then it is removed.
            if (ir.consumesOperand(ins.op)) |v| {
                try checkConsume(gpa, &diags, &live, v, func);
            }
            // uses: a borrow / borrow_use / end_borrow of an owned value requires it still live.
            switch (ins.op) {
                .borrow => |x| try checkUse(gpa, &diags, &live, x.of, func),
                .borrow_use => |v| try checkUse(gpa, &diags, &live, v, func),
                .end_borrow => {},
                else => {},
            }
        }

        // terminator
        if (blk.term) |t| switch (t) {
            .ret_owned => |v| try checkConsume(gpa, &diags, &live, v, func),
            .ret_void, .ret_trivial => {
                // every owned value must have been consumed on this path.
                var it = live.iterator(.{});
                while (it.next()) |vi| try diags.append(gpa, .{ .kind = .leak, .value = @enumFromInt(@as(u32, @intCast(vi))) });
            },
            .br => |succ| try edge(gpa, &diags, entry, @intFromEnum(succ), &live),
            .cond_br => |cb| {
                try edge(gpa, &diags, entry, @intFromEnum(cb.then_blk), &live);
                try edge(gpa, &diags, entry, @intFromEnum(cb.else_blk), &live);
            },
            .switch_br => |sb| {
                for (sb.cases) |c| try edge(gpa, &diags, entry, @intFromEnum(c), &live);
                try edge(gpa, &diags, entry, @intFromEnum(sb.default_blk), &live);
            },
            .unreach => {},
        };
    }

    return .{ .diagnostics = try diags.toOwnedSlice(gpa), .complete = true };
}

fn checkConsume(gpa: std.mem.Allocator, diags: *std.ArrayListUnmanaged(Diagnostic), live: *Set, v: ir.Value, func: *const ir.Func) !void {
    if (func.ownershipOf(v) != .owned) return; // trivial/borrowed are never consumed
    if (!live.isSet(v.index())) {
        try diags.append(gpa, .{ .kind = .double_consume, .value = v });
        return;
    }
    live.unset(v.index());
}

fn checkUse(gpa: std.mem.Allocator, diags: *std.ArrayListUnmanaged(Diagnostic), live: *Set, v: ir.Value, func: *const ir.Func) !void {
    if (func.ownershipOf(v) != .owned) return;
    if (!live.isSet(v.index())) {
        try diags.append(gpa, .{ .kind = .use_after_consume, .value = v });
    }
}

/// Handle a CFG edge cur -> succ carrying `live`.
///   FORWARD edge (succ not yet fixed): set/merge the successor's entry set. If it was already set by
///     another forward predecessor (a join), the two exit sets must be EQUAL — a mismatch means one path
///     consumed a value another did not (a path imbalance).
///   BACK edge (succ already fixed, i.e. a loop header we already processed): the live set arriving on
///     the back-edge must EQUAL the header's entry set, or the loop body changed net ownership per
///     iteration (an inner value left live = leak, or an outer value consumed = use-after-consume next
///     iteration). Either way, a path imbalance.
fn edge(gpa: std.mem.Allocator, diags: *std.ArrayListUnmanaged(Diagnostic), entry: []?Set, succ: usize, live: *const Set) !void {
    if (entry[succ]) |*existing| {
        var vi: usize = 0;
        while (vi < existing.bit_length) : (vi += 1) {
            if (existing.isSet(vi) != live.isSet(vi)) {
                try diags.append(gpa, .{ .kind = .path_imbalance, .value = @enumFromInt(@as(u32, @intCast(vi))) });
            }
        }
    } else {
        entry[succ] = try live.clone(gpa);
    }
}

// ─────────────────────────────────────────── tests ───────────────────────────────────────────

const testing = std.testing;

test "balanced straight-line function verifies clean" {
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "ok" };
    defer f.deinit(gpa);
    const e = try f.newBlock(gpa);
    const x = try f.makeOwned(gpa, e, null);
    try f.borrowUse(gpa, e, x);
    try f.destroy(gpa, e, x);
    f.setTerm(e, .ret_void);

    var r = try verify(gpa, &f);
    defer r.deinit(gpa);
    try testing.expect(r.ok());
    try testing.expect(r.complete);
}

test "leak: owned value never consumed is flagged" {
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "leak" };
    defer f.deinit(gpa);
    const e = try f.newBlock(gpa);
    _ = try f.makeOwned(gpa, e, null); // produced, never destroyed
    f.setTerm(e, .ret_void);

    var r = try verify(gpa, &f);
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(Kind.leak, r.diagnostics[0].kind);
}

test "double-consume is flagged" {
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "dbl" };
    defer f.deinit(gpa);
    const e = try f.newBlock(gpa);
    const x = try f.makeOwned(gpa, e, null);
    try f.destroy(gpa, e, x);
    try f.destroy(gpa, e, x); // second consume of x
    f.setTerm(e, .ret_void);

    var r = try verify(gpa, &f);
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(Kind.double_consume, r.diagnostics[0].kind);
}

test "use-after-consume is flagged" {
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "uac" };
    defer f.deinit(gpa);
    const e = try f.newBlock(gpa);
    const x = try f.makeOwned(gpa, e, null);
    try f.destroy(gpa, e, x);
    try f.borrowUse(gpa, e, x); // read after drop
    f.setTerm(e, .ret_void);

    var r = try verify(gpa, &f);
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(Kind.use_after_consume, r.diagnostics[0].kind);
}

test "conditional path imbalance: consumed on one branch only" {
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "imbal" };
    defer f.deinit(gpa);
    const e = try f.newBlock(gpa);
    const then_b = try f.newBlock(gpa);
    const else_b = try f.newBlock(gpa);
    const join = try f.newBlock(gpa);

    const x = try f.makeOwned(gpa, e, null);
    const c = try f.makeTrivial(gpa, e, null);
    f.setTerm(e, .{ .cond_br = .{ .cond = c, .then_blk = then_b, .else_blk = else_b } });

    try f.destroy(gpa, then_b, x); // consumed on the THEN path only
    f.setTerm(then_b, .{ .br = join });
    f.setTerm(else_b, .{ .br = join }); // ELSE leaves x live -> imbalance at join

    f.setTerm(join, .ret_void);

    var r = try verify(gpa, &f);
    defer r.deinit(gpa);
    try testing.expect(r.complete);
    var saw_imbalance = false;
    for (r.diagnostics) |d| if (d.kind == .path_imbalance) {
        saw_imbalance = true;
    };
    try testing.expect(saw_imbalance);
}

test "balanced across both branches verifies clean" {
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "bal2" };
    defer f.deinit(gpa);
    const e = try f.newBlock(gpa);
    const then_b = try f.newBlock(gpa);
    const else_b = try f.newBlock(gpa);
    const join = try f.newBlock(gpa);

    const x = try f.makeOwned(gpa, e, null);
    const c = try f.makeTrivial(gpa, e, null);
    f.setTerm(e, .{ .cond_br = .{ .cond = c, .then_blk = then_b, .else_blk = else_b } });
    try f.destroy(gpa, then_b, x);
    f.setTerm(then_b, .{ .br = join });
    try f.destroy(gpa, else_b, x);
    f.setTerm(else_b, .{ .br = join });
    f.setTerm(join, .ret_void);

    var r = try verify(gpa, &f);
    defer r.deinit(gpa);
    try testing.expect(r.ok());
}

test "balanced loop (owned local borrowed across the loop) verifies clean" {
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "loop_ok" };
    defer f.deinit(gpa);
    const e = try f.newBlock(gpa); // 0: pre-loop
    const header = try f.newBlock(gpa); // 1
    const body = try f.newBlock(gpa); // 2
    const exit = try f.newBlock(gpa); // 3

    const x = try f.makeOwned(gpa, e, null);
    f.setTerm(e, .{ .br = header });
    const c = try f.makeTrivial(gpa, header, null);
    f.setTerm(header, .{ .cond_br = .{ .cond = c, .then_blk = body, .else_blk = exit } });
    try f.borrowUse(gpa, body, x); // read x each iteration (borrow, no consume)
    f.setTerm(body, .{ .br = header }); // back-edge
    try f.destroy(gpa, exit, x); // drop after the loop
    f.setTerm(exit, .ret_void);

    var r = try verify(gpa, &f);
    defer r.deinit(gpa);
    try testing.expect(r.complete);
    try testing.expect(r.ok());
}

test "loop that leaks an inner owned value each iteration is flagged" {
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "loop_leak" };
    defer f.deinit(gpa);
    const e = try f.newBlock(gpa); // 0
    const header = try f.newBlock(gpa); // 1
    const body = try f.newBlock(gpa); // 2
    const exit = try f.newBlock(gpa); // 3

    f.setTerm(e, .{ .br = header });
    const c = try f.makeTrivial(gpa, header, null);
    f.setTerm(header, .{ .cond_br = .{ .cond = c, .then_blk = body, .else_blk = exit } });
    _ = try f.makeOwned(gpa, body, null); // an owned value born each iteration, never destroyed
    f.setTerm(body, .{ .br = header }); // back-edge: live set now has the extra value -> mismatch
    f.setTerm(exit, .ret_void);

    var r = try verify(gpa, &f);
    defer r.deinit(gpa);
    try testing.expect(r.complete);
    var saw = false;
    for (r.diagnostics) |d| if (d.kind == .path_imbalance) {
        saw = true;
    };
    try testing.expect(saw);
}
