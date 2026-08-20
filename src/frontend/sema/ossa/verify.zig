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
            .br => |succ| try edge(gpa, &diags, entry, func, b, @intFromEnum(succ), &live),
            .cond_br => |cb| {
                try edge(gpa, &diags, entry, func, b, @intFromEnum(cb.then_blk), &live);
                try edge(gpa, &diags, entry, func, b, @intFromEnum(cb.else_blk), &live);
            },
            .switch_br => |sb| {
                for (sb.cases) |c| try edge(gpa, &diags, entry, func, b, @intFromEnum(c), &live);
                try edge(gpa, &diags, entry, func, b, @intFromEnum(sb.default_blk), &live);
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

/// Handle a CFG edge cur -> succ carrying `live_in`.
///   PHIS: if `succ` has owned-value phis, this edge MOVES its input value into each phi (a consume on
///     this edge) and the phi's result becomes live at the join. Applied on a private copy of `live_in`
///     so a block with two successors (cond_br) does not corrupt the shared exit set.
///   FORWARD edge (succ not yet fixed): set/merge the successor's entry set. If it was already set by
///     another forward predecessor (a join), the two exit sets (after phi application) must be EQUAL — a
///     mismatch means one path consumed a value another did not (a path imbalance).
///   BACK edge (succ already fixed, i.e. a loop header we already processed): the live set arriving on
///     the back-edge must EQUAL the header's entry set, or the loop body changed net ownership per
///     iteration (an inner value left live = leak, or an outer value consumed = use-after-consume next
///     iteration). Either way, a path imbalance.
fn edge(gpa: std.mem.Allocator, diags: *std.ArrayListUnmanaged(Diagnostic), entry: []?Set, func: *const ir.Func, cur: usize, succ: usize, live_in: *const Set) !void {
    var live = try live_in.clone(gpa);
    defer live.deinit(gpa);

    // Apply succ's phis for THIS predecessor: consume the input `cur` supplies, produce the phi result.
    for (func.blocks.items[succ].phis.items) |ph| {
        for (ph.inputs) |in| {
            if (@intFromEnum(in.pred) != cur) continue;
            if (func.ownershipOf(in.value) == .owned) {
                if (!live.isSet(in.value.index())) {
                    try diags.append(gpa, .{ .kind = .double_consume, .value = in.value });
                } else live.unset(in.value.index());
            }
            if (func.ownershipOf(ph.result) == .owned) live.set(ph.result.index());
            break;
        }
    }

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

test "phi join: outer local reassigned on the THEN path, unified by a phi, verifies clean" {
    // Models `let x = alloc(); if c { x = alloc(); } use x; drop x;`
    //   entry:  x0 = make_owned; cond_br -> then, join
    //   then:   destroy x0; x1 = make_owned; br join
    //   join:   phi r = [then: x1, entry: x0]; destroy r; ret_void
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "phi_reassign" };
    defer f.deinit(gpa);
    const e = try f.newBlock(gpa);
    const then_b = try f.newBlock(gpa);
    const join = try f.newBlock(gpa);

    const x0 = try f.makeOwned(gpa, e, null);
    const c = try f.makeTrivial(gpa, e, null);
    f.setTerm(e, .{ .cond_br = .{ .cond = c, .then_blk = then_b, .else_blk = join } });

    try f.destroy(gpa, then_b, x0); // reassign drops the old value...
    const x1 = try f.makeOwned(gpa, then_b, null); // ...and binds a new one
    f.setTerm(then_b, .{ .br = join });

    const r_phi = try f.addPhi(gpa, join, &.{ .{ .pred = then_b, .value = x1 }, .{ .pred = e, .value = x0 } }, null);
    try f.destroy(gpa, join, r_phi);
    f.setTerm(join, .ret_void);

    var r = try verify(gpa, &f);
    defer r.deinit(gpa);
    try testing.expect(r.ok());
    try testing.expect(r.complete);
}

test "loop-header phi: outer local reassigned each iteration, unified by a header phi, verifies clean" {
    // Models `let x = alloc(); while c { x = alloc(); } drop x;`
    //   entry:  x0 = make_owned; br header
    //   header: phi xh = [entry: x0, body: xb]; cond_br -> body, exit
    //   body:   destroy xh; xb = make_owned; br header   (back-edge)
    //   exit:   destroy xh; ret_void
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "loop_phi" };
    defer f.deinit(gpa);
    const entry = try f.newBlock(gpa);
    const header = try f.newBlock(gpa);
    const body = try f.newBlock(gpa);
    const exit = try f.newBlock(gpa);

    const x0 = try f.makeOwned(gpa, entry, null);
    f.setTerm(entry, .{ .br = header });

    // header phi: entry input x0, back-edge input xb (created below, in the body).
    const xb = try f.makeOwned(gpa, body, null); // allocate the value id now; emitted in body below
    const xh = try f.addPhi(gpa, header, &.{ .{ .pred = entry, .value = x0 }, .{ .pred = body, .value = xb } }, null);
    const c = try f.makeTrivial(gpa, header, null);
    f.setTerm(header, .{ .cond_br = .{ .cond = c, .then_blk = body, .else_blk = exit } });

    try f.destroy(gpa, body, xh); // reassign drops the loop-carried value...
    // xb already emitted above (make_owned in body) — it is the rebind.
    f.setTerm(body, .{ .br = header }); // back-edge

    try f.destroy(gpa, exit, xh);
    f.setTerm(exit, .ret_void);

    var r = try verify(gpa, &f);
    defer r.deinit(gpa);
    try testing.expect(r.ok());
    try testing.expect(r.complete);
}

test "N-input phi (switch-style): three cases each reassign the same local, unified at the join" {
    // entry: x0; switch_br -> c1, c2, default
    // c1: destroy x0; x1=make_owned; br join
    // c2: destroy x0; x2=make_owned; br join
    // default: destroy x0; x3=make_owned; br join
    // join: phi r = [c1:x1, c2:x2, default:x3]; destroy r; ret_void
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "switch_phi" };
    defer f.deinit(gpa);
    const e = try f.newBlock(gpa);
    const c1 = try f.newBlock(gpa);
    const c2 = try f.newBlock(gpa);
    const def = try f.newBlock(gpa);
    const join = try f.newBlock(gpa);

    const x0 = try f.makeOwned(gpa, e, null);
    const cases = try gpa.dupe(ir.Block, &.{ c1, c2 });
    f.setTerm(e, .{ .switch_br = .{ .cases = cases, .default_blk = def } });

    try f.destroy(gpa, c1, x0);
    const x1 = try f.makeOwned(gpa, c1, null);
    f.setTerm(c1, .{ .br = join });
    try f.destroy(gpa, c2, x0);
    const x2 = try f.makeOwned(gpa, c2, null);
    f.setTerm(c2, .{ .br = join });
    try f.destroy(gpa, def, x0);
    const x3 = try f.makeOwned(gpa, def, null);
    f.setTerm(def, .{ .br = join });

    const r = try f.addPhi(gpa, join, &.{
        .{ .pred = c1, .value = x1 }, .{ .pred = c2, .value = x2 }, .{ .pred = def, .value = x3 },
    }, null);
    try f.destroy(gpa, join, r);
    f.setTerm(join, .ret_void);

    var res = try verify(gpa, &f);
    defer res.deinit(gpa);
    try testing.expect(res.ok());
    try testing.expect(res.complete);
}

test "phi join: forgetting to consume the phi result is a leak" {
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "phi_leak" };
    defer f.deinit(gpa);
    const e = try f.newBlock(gpa);
    const then_b = try f.newBlock(gpa);
    const join = try f.newBlock(gpa);

    const x0 = try f.makeOwned(gpa, e, null);
    const c = try f.makeTrivial(gpa, e, null);
    f.setTerm(e, .{ .cond_br = .{ .cond = c, .then_blk = then_b, .else_blk = join } });
    try f.destroy(gpa, then_b, x0);
    const x1 = try f.makeOwned(gpa, then_b, null);
    f.setTerm(then_b, .{ .br = join });

    _ = try f.addPhi(gpa, join, &.{ .{ .pred = then_b, .value = x1 }, .{ .pred = e, .value = x0 } }, null);
    f.setTerm(join, .ret_void); // phi result never consumed -> leak

    var r = try verify(gpa, &f);
    defer r.deinit(gpa);
    var saw_leak = false;
    for (r.diagnostics) |d| if (d.kind == .leak) {
        saw_leak = true;
    };
    try testing.expect(saw_leak);
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
