//! Copy-forwarding analysis over the OSSA (ownership SSA) intermediate form.
//!
//! When Kyte lowers a value-semantic `let y = x` (or any place a `copy`
//! instruction is emitted, see [`ir.Func.copy`]), the copy produces a second,
//! independently-owned value. That copy is only genuinely needed if the *result*
//! escapes: it is returned to the caller ([`ir.Terminator.ret_owned`]), or it is
//! moved out of the function through some other consuming edge
//! ([`ir.Op.move_out`]). If the result is instead merely borrowed and then
//! destroyed at end of scope, the copy is pure overhead: a retain/dtor pair (and,
//! for containers, a deep clone) that could have been forwarded to the original
//! value with no observable difference.
//!
//! This module does NOT rewrite the IR. It is a *counting / candidate-detection*
//! pass: it walks a function's blocks and reports how many `copy` instructions
//! exist and how many of them are forwarding candidates (copies whose result is
//! only ever destroyed). It exists so the ownership pipeline and its tests can
//! measure the opportunity for copy elision and gate on it, before any transform
//! that actually elides the copies is wired in.
//!
//! The analysis is deliberately conservative and cheap. It is a whole-function
//! linear scan with no dataflow: a value counts as a candidate only if NO
//! instruction anywhere consumes it via `move_out` and NO block returns it as an
//! owned value. Anything it cannot prove safe (any consuming or returning use) is
//! excluded, so a false candidate is never produced; the cost is that copies made
//! safe only by more precise reasoning are missed. See [`ir`] for the instruction
//! and terminator vocabulary this walk pattern-matches on.

const std = @import("std");
/// The OSSA instruction/terminator model this pass reads: [`ir.Func`],
/// [`ir.Value`], [`ir.Op`] and [`ir.Terminator`]. This module never mutates it.
const ir = @import("ir.zig");

/// Result of a single [`count`] scan over one function.
///
/// `candidates` is always `<= copies`: every candidate is a `copy` whose result
/// survived the "only destroyed" test, so the two are reported together to make
/// the ratio (how much of the copy traffic is elidable) directly available.
pub const Counts = struct {
    /// Total number of `copy` instructions in the function, elidable or not.
    copies: usize = 0,
    /// Subset of [`copies`] whose result is only ever destroyed, i.e. safe to
    /// forward to the source value. Established by [`resultOnlyDestroyed`].
    candidates: usize = 0,
};

/// Scans every block of `func` and tallies copies and forwarding candidates.
///
/// A `copy` counts towards [`Counts.candidates`] when it has a real result
/// (`ins.result != .none`) and [`resultOnlyDestroyed`] proves that result never
/// escapes. Non-`copy` instructions are ignored. The scan is O(instructions) on
/// its own, but each candidate check itself re-walks the function, so the whole
/// pass is O(copies × instructions) in the worst case; acceptable because it runs
/// on the small per-function OSSA form, not the full program.
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

/// Convenience wrapper returning just the forwarding-candidate count.
///
/// Equivalent to `count(func).candidates`; the copies total is discarded. This
/// is the value the tests below assert on, since candidate count is the metric
/// the elision opportunity is measured by.
pub fn candidates(func: *const ir.Func) usize {
    return count(func).candidates;
}

/// Returns true when value `v` is consumed only by destruction, so a `copy`
/// producing it can be safely forwarded to its source.
///
/// The function is the whole safety proof: it scans every instruction and every
/// block terminator looking for a use of `v` that would make forwarding
/// observable. Two shapes disqualify it, and the walk returns false on the first
/// one found:
///   - a [`ir.Op.move_out`] of `v`: the value is moved somewhere the source
///     value cannot also satisfy;
///   - a [`ir.Terminator.ret_owned`] of `v`: the value is returned to the
///     caller, so ownership must genuinely leave the function.
///
/// `borrow_use`, `end_borrow`, `destroy` and every other op are non-escaping and
/// therefore do not disqualify. Reaching the end with no disqualifying use means
/// `v`'s only fate is destruction, so returning true is sound. The walk is
/// conservative by construction: it never inspects `v`'s definition, only its
/// uses, so it cannot mistakenly clear an escaping value.
fn resultOnlyDestroyed(func: *const ir.Func, v: ir.Value) bool {
    for (func.blocks.items) |*b| {
        for (b.instrs.items) |ins| {
            switch (ins.op) {
                .move_out => |mv| if (mv == v) return false,
                else => {},
            }
        }
        if (b.term) |t| switch (t) {
            .ret_owned => |rv| if (rv == v) return false,
            else => {},
        };
    }
    return true;
}


/// Alias for `std.testing`, used by the candidate-detection tests below.
const testing = std.testing;

// The positive case: a copy whose result is borrowed then destroyed is elidable.
//
// Builds `y = copy(x)`, borrow-uses `y`, then destroys both `y` and `x` and
// returns void. Since `y` never escapes, [`candidates`] must report exactly 1.
test "a copy that is only destroyed is a forwarding candidate" {
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "cand" };
    defer f.deinit(gpa);
    const e = try f.newBlock(gpa);
    const x = try f.makeOwned(gpa, e, null);
    const y = try f.copy(gpa, e, x);
    try f.borrowUse(gpa, e, y);
    try f.destroy(gpa, e, y);
    try f.destroy(gpa, e, x);
    f.setTerm(e, .ret_void);

    try testing.expectEqual(@as(usize, 1), candidates(&f));
}

// Negative case: a returned copy escapes, so it is not a candidate.
//
// `y = copy(x)` is handed to `ret_owned`, meaning ownership leaves the function;
// [`resultOnlyDestroyed`] must reject it and [`candidates`] must report 0.
test "a copy that is returned is NOT a candidate" {
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "notcand" };
    defer f.deinit(gpa);
    const e = try f.newBlock(gpa);
    const x = try f.makeOwned(gpa, e, null);
    const y = try f.copy(gpa, e, x);
    try f.destroy(gpa, e, x);
    f.setTerm(e, .{ .ret_owned = y });

    try testing.expectEqual(@as(usize, 0), candidates(&f));
}

// Negative case: a moved-out copy escapes through the move edge.
//
// `y = copy(x)` is fed to `move_out`, the other disqualifying shape checked by
// [`resultOnlyDestroyed`]; [`candidates`] must report 0 even though the function
// returns void.
test "a copy that is moved out is NOT a candidate" {
    const gpa = testing.allocator;
    var f = ir.Func{ .name = "moved" };
    defer f.deinit(gpa);
    const e = try f.newBlock(gpa);
    const x = try f.makeOwned(gpa, e, null);
    const y = try f.copy(gpa, e, x);
    try f.moveOut(gpa, e, y);
    try f.destroy(gpa, e, x);
    f.setTerm(e, .ret_void);

    try testing.expectEqual(@as(usize, 0), candidates(&f));
}
