// OSSA-lite ownership-forwarding analysis (Track A — perf). E2-GATED: this MEASURES headroom before any
// transform is built, per the standing rule in docs/design/sil-arc-optimiser-direction.md (an ARC pass
// must show a measured delta before coverage work).
//
// The one ARC optimisation LLVM cannot do is elide a retain/release pair that is semantically redundant.
// On the OSSA IR the clearest such pattern is a REDUNDANT COPY: a `copy` (an owned dup, i.e. `let y = x`
// which retains) whose result is NEVER moved out or returned — only borrowed and then destroyed. Its +1
// is dead weight: the borrows could read the source directly and the copy+destroy pair be removed
// (ownership-forwarding). Counting these across the corpus tells us whether forwarding has any headroom.
//
// A copy is a candidate iff its result value is consumed ONLY by a `destroy` (never `move_out` or a
// `ret_owned` terminator). We do NOT transform here — only count.

const std = @import("std");
const ir = @import("ir.zig");

pub const Counts = struct { copies: usize = 0, candidates: usize = 0 };

/// Count total owned `copy` (dup) ops and, of those, how many are forwarding candidates. Reporting both
/// separates "no headroom because there are no dup-copies at all" from "copies exist but are all consumed".
pub fn count(func: *const ir.Func) Counts {
    var c = Counts{};
    for (func.blocks.items) |*b| {
        for (b.instrs.items) |ins| {
            switch (ins.op) {
                .copy => {
                    c.copies += 1;
                    if (ins.result != .none and resultOnlyDestroyed(func, ins.result)) c.candidates += 1;
                },
                else => {},
            }
        }
    }
    return c;
}

/// Number of redundant-copy (forwarding) candidates in one function.
pub fn candidates(func: *const ir.Func) usize {
    return count(func).candidates;
}

/// True if `v` is consumed only by a `destroy` — never `move_out`, never a `ret_owned` terminator. (A
/// value with no consumer at all cannot arise for an owned copy in a well-formed function, but if it did
/// it would not be a forwarding candidate either, so require at least the destroy implicitly by the
/// "never transferred" test: any transfer disqualifies it.)
fn resultOnlyDestroyed(func: *const ir.Func, v: ir.Value) bool {
    for (func.blocks.items) |*b| {
        for (b.instrs.items) |ins| {
            switch (ins.op) {
                .move_out => |mv| if (mv == v) return false, // transferred out: its +1 is needed
                else => {},
            }
        }
        if (b.term) |t| switch (t) {
            .ret_owned => |rv| if (rv == v) return false, // returned: its +1 is needed
            else => {},
        };
    }
    return true;
}

// ─────────────────────────────────────────── tests ───────────────────────────────────────────

const testing = std.testing;

test "a copy that is only destroyed is a forwarding candidate" {
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "cand" };
    defer f.deinit(gpa);
    const e = try f.newBlock(gpa);
    const x = try f.makeOwned(gpa, e, null);
    const y = try f.copy(gpa, e, x); // let y = x  (dup)
    try f.borrowUse(gpa, e, y); // y only read
    try f.destroy(gpa, e, y); // ...then dropped -> redundant copy
    try f.destroy(gpa, e, x);
    f.setTerm(e, .ret_void);

    try testing.expectEqual(@as(usize, 1), candidates(&f));
}

test "a copy that is returned is NOT a candidate" {
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "notcand" };
    defer f.deinit(gpa);
    const e = try f.newBlock(gpa);
    const x = try f.makeOwned(gpa, e, null);
    const y = try f.copy(gpa, e, x); // let y = x
    try f.destroy(gpa, e, x);
    f.setTerm(e, .{ .ret_owned = y }); // y is returned -> its +1 is needed

    try testing.expectEqual(@as(usize, 0), candidates(&f));
}

test "a copy that is moved out is NOT a candidate" {
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "moved" };
    defer f.deinit(gpa);
    const e = try f.newBlock(gpa);
    const x = try f.makeOwned(gpa, e, null);
    const y = try f.copy(gpa, e, x);
    try f.moveOut(gpa, e, y); // transferred to a sink -> needed
    try f.destroy(gpa, e, x);
    f.setTerm(e, .ret_void);

    try testing.expectEqual(@as(usize, 0), candidates(&f));
}
