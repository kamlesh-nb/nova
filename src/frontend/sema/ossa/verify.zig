//! Ownership-SSA (OSSA) balance verifier: the self-check that proves every
//! owned value in a function is consumed exactly once on every path.
//!
//! Nova is reference-counted, not garbage-collected, so the codegen that emits
//! `nova_retain`/`nova_release` pairs is where memory correctness is actually
//! decided. This pass exists to catch a mistake in that emission BEFORE it
//! reaches a running binary. It runs over the ownership IR built in
//! [`ir`] (a small SSA form where each value carries an [`ir.Ownership`]) and
//! answers one question per function: does the ownership stay balanced?
//!
//! ## What "balanced" means
//!
//! Every [`ir.Ownership.owned`] value must be consumed exactly once along every
//! control-flow path from where it is produced to every function exit. The pass
//! walks each block forward, maintaining a `live` set (a bitset indexed by SSA
//! value id) of owned values that have been produced but not yet consumed:
//!
//!   * producing an owned result (any instruction whose result is `owned`) SETS
//!     its bit;
//!   * a consuming instruction (see [`ir.consumesOperand`]) or an `ret_owned`
//!     terminator UNSETS its bit, and if the bit was already clear, that is a
//!     [`Kind.double_consume`];
//!   * a borrow / borrow_use of an owned value that is not live is a
//!     [`Kind.use_after_consume`] (the value was already given away);
//!   * anything still live at a `ret_void`/`ret_trivial` terminator is a
//!     [`Kind.leak`] (produced, never consumed).
//!
//! ## How joins and loops are checked (the path-imbalance idea)
//!
//! The pass is a single forward sweep over blocks in index order, NOT an
//! iterative dataflow fixpoint. Each block's live-in set is recorded in
//! [`entry`] by the FIRST predecessor edge that reaches it (see [`edge`]); every
//! later predecessor edge compares its own live set against that recorded set
//! and reports a [`Kind.path_imbalance`] for any value that disagrees. That is
//! how "consumed on the then-branch but not the else-branch" is caught: the two
//! edges into the join disagree on one bit.
//!
//! Reassignment across a join is expressed with phi nodes, so [`edge`] applies
//! each successor phi as it crosses the edge, consuming the incoming operand
//! (the old value dies at the merge) and producing the phi result (the merged
//! value becomes live). This is what lets a loop-header phi keep an owned local
//! balanced across iterations without the sweep needing to converge: the header
//! is only visited once, and the back-edge is validated against the recorded
//! live-in rather than re-propagated.
//!
//! Because the sweep is single-pass, correctness depends on the IR being
//! well-formed SSA with phis at every merge of an owned value; the verifier
//! reports imbalance rather than looping to a fixpoint, which keeps it O(blocks
//! + edges) and terminating on any graph.
//!
//! The result always has `complete = true` today; the field exists so a future
//! bailout (e.g. a size or shape the pass refuses to reason about) can report a
//! partial verdict without the caller mistaking "gave up" for "verified clean".

const std = @import("std");
/// The ownership IR this pass consumes: values, blocks, phis, terminators, and
/// the [`ir.Func.ownershipOf`] / [`ir.consumesOperand`] queries that drive the
/// live-set bookkeeping.
const ir = @import("ir.zig");

/// The category of an ownership-balance defect the verifier can report.
///
/// `deferred_loop` is reserved and not currently produced by [`verify`]; the
/// other four map directly to the live-set transitions described in the module
/// header: [`Kind.leak`] (owned but never consumed at a value return),
/// [`Kind.double_consume`] (consumed when not live), [`Kind.use_after_consume`]
/// (borrowed after being consumed), and [`Kind.path_imbalance`] (predecessor
/// edges into a block disagree on whether a value is still live).
pub const Kind = enum { leak, double_consume, use_after_consume, path_imbalance, deferred_loop };

/// One reported ownership-balance defect: what went wrong and which SSA value
/// it concerns.
pub const Diagnostic = struct {
    /// The category of the defect. See [`Kind`].
    kind: Kind,
    /// The offending SSA value, the owned value that leaked, was consumed
    /// twice, was used after consumption, or disagreed across a merge.
    value: ir.Value,
};

/// The verdict of a [`verify`] run: the list of defects plus whether the pass
/// reached a full conclusion.
pub const Result = struct {
    /// Every defect found, in the order encountered during the forward sweep.
    /// Empty means the function is ownership-balanced. Owned by the result;
    /// release with [`Result.deinit`].
    diagnostics: []Diagnostic,
    /// True when the pass ran to completion. Always true today (see the module
    /// header); reserved so a future bailout can distinguish "verified" from
    /// "declined to verify" without an empty [`Result.diagnostics`] reading as a
    /// clean bill of health.
    complete: bool,

    /// Frees the [`Result.diagnostics`] slice with the same allocator that
    /// [`verify`] used to produce it.
    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.diagnostics);
    }
    /// True when no defects were reported. Note this checks only that the
    /// diagnostics list is empty; pair it with [`Result.complete`] to be sure
    /// the verdict is also final.
    pub fn ok(self: *const Result) bool {
        return self.diagnostics.len == 0;
    }
};

/// The per-block live-set representation: an unmanaged bitset indexed by SSA
/// value id, one bit per owned value that is currently produced-but-unconsumed.
const Set = std.DynamicBitSetUnmanaged;

/// Verifies that every owned value in `func` is consumed exactly once on every
/// path, returning the collected [`Diagnostic`]s.
///
/// Runs a single forward sweep over blocks in index order (see the module
/// header for why one pass suffices). For each block it clones the live-in set
/// recorded in [`entry`], applies every instruction, producing owned results
/// into the set, consuming operands out of it via [`checkConsume`], and
/// validating borrows via [`checkUse`], then hands the resulting live set to
/// the terminator: `ret_owned` consumes, `ret_void`/`ret_trivial` flags any
/// survivor as a [`Kind.leak`], and branch terminators propagate to successors
/// through [`edge`].
///
/// An empty function (no blocks) is vacuously balanced. The caller owns the
/// returned [`Result`] and must call [`Result.deinit`]. Returns an allocator
/// error only; ownership defects are reported in the result, not as errors.
pub fn verify(gpa: std.mem.Allocator, func: *const ir.Func) !Result {
    var diags = std.ArrayListUnmanaged(Diagnostic).empty;
    errdefer diags.deinit(gpa);

    const nblocks = func.blocks.items.len;
    const nvals = func.values.items.len;
    if (nblocks == 0) return .{ .diagnostics = try diags.toOwnedSlice(gpa), .complete = true };

    const entry = try gpa.alloc(?Set, nblocks);
    defer {
        for (entry) |*e| if (e.*) |*s| s.deinit(gpa);
        gpa.free(entry);
    }
    for (entry) |*e| e.* = null;

    entry[0] = try Set.initEmpty(gpa, nvals);

    var b: usize = 0;
    while (b < nblocks) : (b += 1) {
        var live = if (entry[b]) |s| try s.clone(gpa) else try Set.initEmpty(gpa, nvals);
        defer live.deinit(gpa);

        const blk = &func.blocks.items[b];
        for (blk.instrs.items) |ins| {
            if (ins.result != .none and func.ownershipOf(ins.result) == .owned) {
                live.set(ins.result.index());
            }
            if (ir.consumesOperand(ins.op)) |v| {
                try checkConsume(gpa, &diags, &live, v, func);
            }
            switch (ins.op) {
                .borrow => |x| try checkUse(gpa, &diags, &live, x.of, func),
                .borrow_use => |v| try checkUse(gpa, &diags, &live, v, func),
                .end_borrow => {},
                else => {},
            }
        }

        if (blk.term) |t| switch (t) {
            .ret_owned => |v| try checkConsume(gpa, &diags, &live, v, func),
            .ret_void, .ret_trivial => {
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

/// Records a consumption of owned value `v` against the current `live` set.
///
/// Non-owned values (trivial/borrowed) are ignored, so callers may pass any
/// operand blindly. If `v` is owned and its bit is set, it is cleared (the value
/// is now consumed). If the bit is already clear, the value was consumed twice
/// on this path, which is appended as a [`Kind.double_consume`] and the set is
/// left unchanged.
fn checkConsume(gpa: std.mem.Allocator, diags: *std.ArrayListUnmanaged(Diagnostic), live: *Set, v: ir.Value, func: *const ir.Func) !void {
    if (func.ownershipOf(v) != .owned) return;
    if (!live.isSet(v.index())) {
        try diags.append(gpa, .{ .kind = .double_consume, .value = v });
        return;
    }
    live.unset(v.index());
}

/// Validates a non-consuming use (a `borrow` or `borrow_use`) of value `v`.
///
/// Unlike [`checkConsume`] this does NOT alter the `live` set: a borrow reads
/// the value without taking ownership. Non-owned values are ignored. If `v` is
/// owned but no longer live, it was borrowed after having been consumed, which
/// is appended as a [`Kind.use_after_consume`].
fn checkUse(gpa: std.mem.Allocator, diags: *std.ArrayListUnmanaged(Diagnostic), live: *Set, v: ir.Value, func: *const ir.Func) !void {
    if (func.ownershipOf(v) != .owned) return;
    if (!live.isSet(v.index())) {
        try diags.append(gpa, .{ .kind = .use_after_consume, .value = v });
    }
}

/// Propagates the live set across one control-flow edge from block `cur` to
/// successor `succ`, applying phis and either recording or checking `succ`'s
/// live-in.
///
/// Works on a private clone of `live_in` so the caller's set (which may feed
/// several successors) is untouched. First it walks `succ`'s phi nodes: for the
/// input whose predecessor is `cur`, the incoming owned operand is consumed (a
/// clear-when-already-clear bit is a [`Kind.double_consume`]) and the owned phi
/// result is made live, modelling reassignment at the merge. The `break` after
/// the matching input assumes at most one input per predecessor.
///
/// Then it reconciles with [`entry`]`[succ]`: if this is the first edge to reach
/// `succ`, the computed set becomes the recorded live-in; otherwise every bit is
/// compared against the recorded set and each disagreement is a
/// [`Kind.path_imbalance`]. This first-writer-wins-then-compare scheme is what
/// makes the single forward sweep sound without iterating to a fixpoint.
fn edge(gpa: std.mem.Allocator, diags: *std.ArrayListUnmanaged(Diagnostic), entry: []?Set, func: *const ir.Func, cur: usize, succ: usize, live_in: *const Set) !void {
    var live = try live_in.clone(gpa);
    defer live.deinit(gpa);

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


/// Alias for the standard testing namespace used by the unit tests below.
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
    _ = try f.makeOwned(gpa, e, null);
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
    try f.destroy(gpa, e, x);
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
    try f.borrowUse(gpa, e, x);
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

    try f.destroy(gpa, then_b, x);
    f.setTerm(then_b, .{ .br = join });
    f.setTerm(else_b, .{ .br = join });

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
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "phi_reassign" };
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

    const r_phi = try f.addPhi(gpa, join, &.{ .{ .pred = then_b, .value = x1 }, .{ .pred = e, .value = x0 } }, null);
    try f.destroy(gpa, join, r_phi);
    f.setTerm(join, .ret_void);

    var r = try verify(gpa, &f);
    defer r.deinit(gpa);
    try testing.expect(r.ok());
    try testing.expect(r.complete);
}

test "loop-header phi: outer local reassigned each iteration, unified by a header phi, verifies clean" {
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "loop_phi" };
    defer f.deinit(gpa);
    const entry = try f.newBlock(gpa);
    const header = try f.newBlock(gpa);
    const body = try f.newBlock(gpa);
    const exit = try f.newBlock(gpa);

    const x0 = try f.makeOwned(gpa, entry, null);
    f.setTerm(entry, .{ .br = header });

    const xb = try f.makeOwned(gpa, body, null);
    const xh = try f.addPhi(gpa, header, &.{ .{ .pred = entry, .value = x0 }, .{ .pred = body, .value = xb } }, null);
    const c = try f.makeTrivial(gpa, header, null);
    f.setTerm(header, .{ .cond_br = .{ .cond = c, .then_blk = body, .else_blk = exit } });

    try f.destroy(gpa, body, xh);
    f.setTerm(body, .{ .br = header });

    try f.destroy(gpa, exit, xh);
    f.setTerm(exit, .ret_void);

    var r = try verify(gpa, &f);
    defer r.deinit(gpa);
    try testing.expect(r.ok());
    try testing.expect(r.complete);
}

test "N-input phi (switch-style): three cases each reassign the same local, unified at the join" {
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
    f.setTerm(join, .ret_void);

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
    const e = try f.newBlock(gpa);
    const header = try f.newBlock(gpa);
    const body = try f.newBlock(gpa);
    const exit = try f.newBlock(gpa);

    const x = try f.makeOwned(gpa, e, null);
    f.setTerm(e, .{ .br = header });
    const c = try f.makeTrivial(gpa, header, null);
    f.setTerm(header, .{ .cond_br = .{ .cond = c, .then_blk = body, .else_blk = exit } });
    try f.borrowUse(gpa, body, x);
    f.setTerm(body, .{ .br = header });
    try f.destroy(gpa, exit, x);
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
    const e = try f.newBlock(gpa);
    const header = try f.newBlock(gpa);
    const body = try f.newBlock(gpa);
    const exit = try f.newBlock(gpa);

    f.setTerm(e, .{ .br = header });
    const c = try f.makeTrivial(gpa, header, null);
    f.setTerm(header, .{ .cond_br = .{ .cond = c, .then_blk = body, .else_blk = exit } });
    _ = try f.makeOwned(gpa, body, null);
    f.setTerm(body, .{ .br = header });
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
