// OSSA-lite — a minimal, ownership-aware IR for Nova (Track I of docs/design/ossa-lite-tasks.md).
//
// PURPOSE. Nova has no IR where ownership is explicit, which is the single root of two gaps
// (see docs/design/swift-arch-comparison.md): soundness is ASAN-TESTED not compile-time VERIFIED,
// and there is nowhere to do the one ARC optimisation LLVM cannot (ownership-forwarding). This IR is
// the shared substrate for BOTH: a verifier proving release-balance (soundness) and, later, an
// ownership-forwarding pass (perf). It is deliberately Swift-OSSA-*lite*: it models ONLY ownership,
// not arithmetic or control-flow computation. Everything an owned value can undergo is one of a small
// fixed set of ownership events, so the invariant a verifier must check is simply stated:
//
//   INVARIANT (OSSA): every OWNED value is CONSUMED exactly once on every path from its definition.
//   A consume is `destroy` (drop / release), `move_out` (transfer to a sink / consuming callee), or a
//   returning terminator. `copy` produces a NEW owned value that must itself be consumed once.
//   `borrow`/`borrow_use` do NOT consume. Trivial (non-refcounted) values have no obligation.
//
// This file is I1: the IR TYPES + a builder, with unit tests. It is not yet produced from Nova source
// (that is I2 — lowering) nor checked (I3 — the verifier). It is compiled + unit-tested via root.zig.

const std = @import("std");
const types = @import("../../types.zig");

pub const TypeId = types.TypeId;

/// SSA value handle. `none` is the null sentinel.
pub const Value = enum(u32) {
    none = 0xFFFF_FFFF,
    _,
    pub fn index(self: Value) u32 {
        return @intFromEnum(self);
    }
};

/// Basic-block handle.
pub const Block = enum(u32) { _ };

/// Ownership class of a value. This is the whole point of the IR.
pub const Ownership = enum {
    /// non-refcounted (int/bool/float/enum-tag/…): no consume obligation.
    trivial,
    /// carries a +1 reference that MUST be consumed exactly once.
    owned,
    /// a non-owning view of an owned value; must not outlive its source; never consumed.
    borrowed,
};

/// The ownership events. Producers define a new value; consumers take an owned operand exactly once;
/// borrow uses are non-consuming. This set is intentionally tiny — extend only when a real Nova
/// construct cannot be modelled by composing these (keep the verifier's job small).
pub const Op = union(enum) {
    // ── producers (define this instruction's result value) ──
    /// birth of a fresh owned value (+1): a heap allocation or an owned-returning call. result: owned
    make_owned,
    /// a trivial value (literal, arithmetic result, tag). result: trivial
    make_trivial,
    /// copy/dup an owned value (+1). The operand stays live; result is a NEW owned value. result: owned
    copy: Value,
    /// begin a borrow of an owned value (no refcount change). result: borrowed, tied to `.of`.
    borrow: struct { of: Value },

    // ── consumers (CONSUME their owned operand exactly once) ──
    /// drop / release an owned value (-1) — the scope-end destroy.
    destroy: Value,
    /// transfer an owned value OUT to a sink: store into an owned field, or pass to a consuming callee.
    move_out: Value,

    // ── non-consuming uses ──
    /// read / pass-by-borrow use of a value (owned or borrowed). Does not change ownership.
    borrow_use: Value,
    /// end a borrow previously begun with `borrow`.
    end_borrow: Value,
};

/// Block terminators. Only the ownership-relevant shape is modelled.
pub const Terminator = union(enum) {
    /// return, consuming an owned value (transfers the +1 to the caller).
    ret_owned: Value,
    /// return a trivial value (no consume).
    ret_trivial: Value,
    /// return nothing.
    ret_void,
    /// unconditional branch.
    br: Block,
    /// conditional branch on a trivial value.
    cond_br: struct { cond: Value, then_blk: Block, else_blk: Block },
    /// N-way dispatch (a `switch`): one successor per case plus a default. The discriminant is a borrow,
    /// so it is not represented — only the ownership-relevant successor edges are. `cases` is owned by the
    /// Func and freed in deinit.
    switch_br: struct { cases: []Block, default_blk: Block },
    /// no successor (diverges / trap).
    unreach,
};

/// One instruction: its defined result (or `.none` for pure consumers) and its op.
pub const Instr = struct {
    result: Value,
    op: Op,
};

/// One incoming arm of a phi: the value that predecessor `pred` carries into the join.
pub const PhiInput = struct { pred: Block, value: Value };

/// An owned-value phi at a control-flow JOIN. When a variable is bound to DIFFERENT owned values on
/// different incoming edges (e.g. an outer local reassigned in one branch but not another), the join
/// unifies them: each predecessor MOVES its `inputs[i].value` into the phi as its edge is taken (a
/// consume on that edge), and the phi's `result` is a single fresh owned value live at the join. This is
/// exactly the linear-ownership move-merge; the verifier applies it edge-by-edge (see verify.zig `edge`).
pub const Phi = struct { result: Value, inputs: []PhiInput };

pub const BasicBlock = struct {
    instrs: std.ArrayListUnmanaged(Instr) = .empty,
    phis: std.ArrayListUnmanaged(Phi) = .empty,
    term: ?Terminator = null,
};

const ValueInfo = struct {
    own: Ownership,
    /// the type this value carries (for diagnostics / later passes); `unset` allowed for I1.
    ty: ?TypeId = null,
};

/// One function's ownership IR. Arena-free: caller supplies an allocator and calls `deinit`.
pub const Func = struct {
    name: []const u8 = "",
    values: std.ArrayListUnmanaged(ValueInfo) = .empty,
    blocks: std.ArrayListUnmanaged(BasicBlock) = .empty,

    pub fn deinit(self: *Func, gpa: std.mem.Allocator) void {
        for (self.blocks.items) |*b| {
            b.instrs.deinit(gpa);
            for (b.phis.items) |ph| gpa.free(ph.inputs);
            b.phis.deinit(gpa);
            if (b.term) |t| switch (t) {
                .switch_br => |sb| gpa.free(sb.cases),
                else => {},
            };
        }
        self.blocks.deinit(gpa);
        self.values.deinit(gpa);
    }

    pub fn ownershipOf(self: *const Func, v: Value) Ownership {
        return self.values.items[v.index()].own;
    }

    pub fn newBlock(self: *Func, gpa: std.mem.Allocator) !Block {
        const id: u32 = @intCast(self.blocks.items.len);
        try self.blocks.append(gpa, .{});
        return @enumFromInt(id);
    }

    fn newValue(self: *Func, gpa: std.mem.Allocator, own: Ownership, ty: ?TypeId) !Value {
        const id: u32 = @intCast(self.values.items.len);
        try self.values.append(gpa, .{ .own = own, .ty = ty });
        return @enumFromInt(id);
    }

    fn blockPtr(self: *Func, b: Block) *BasicBlock {
        return &self.blocks.items[@intFromEnum(b)];
    }

    fn emit(self: *Func, gpa: std.mem.Allocator, b: Block, result: Value, op: Op) !void {
        try self.blockPtr(b).instrs.append(gpa, .{ .result = result, .op = op });
    }

    // ── builder: producers ──
    pub fn makeOwned(self: *Func, gpa: std.mem.Allocator, b: Block, ty: ?TypeId) !Value {
        const v = try self.newValue(gpa, .owned, ty);
        try self.emit(gpa, b, v, .make_owned);
        return v;
    }
    pub fn makeTrivial(self: *Func, gpa: std.mem.Allocator, b: Block, ty: ?TypeId) !Value {
        const v = try self.newValue(gpa, .trivial, ty);
        try self.emit(gpa, b, v, .make_trivial);
        return v;
    }
    pub fn copy(self: *Func, gpa: std.mem.Allocator, b: Block, src: Value) !Value {
        const v = try self.newValue(gpa, .owned, self.values.items[src.index()].ty);
        try self.emit(gpa, b, v, .{ .copy = src });
        return v;
    }
    pub fn borrow(self: *Func, gpa: std.mem.Allocator, b: Block, of: Value) !Value {
        const v = try self.newValue(gpa, .borrowed, self.values.items[of.index()].ty);
        try self.emit(gpa, b, v, .{ .borrow = .{ .of = of } });
        return v;
    }

    // ── builder: consumers / uses (define no result) ──
    pub fn destroy(self: *Func, gpa: std.mem.Allocator, b: Block, v: Value) !void {
        try self.emit(gpa, b, .none, .{ .destroy = v });
    }
    pub fn moveOut(self: *Func, gpa: std.mem.Allocator, b: Block, v: Value) !void {
        try self.emit(gpa, b, .none, .{ .move_out = v });
    }
    pub fn borrowUse(self: *Func, gpa: std.mem.Allocator, b: Block, v: Value) !void {
        try self.emit(gpa, b, .none, .{ .borrow_use = v });
    }
    pub fn endBorrow(self: *Func, gpa: std.mem.Allocator, b: Block, v: Value) !void {
        try self.emit(gpa, b, .none, .{ .end_borrow = v });
    }

    /// Add an owned-value phi at join block `b`. `inputs` is copied (the Func owns the slice). Returns the
    /// fresh owned result value, live at the join. `ty` is carried for diagnostics only.
    pub fn addPhi(self: *Func, gpa: std.mem.Allocator, b: Block, inputs: []const PhiInput, ty: ?TypeId) !Value {
        const result = try self.newValue(gpa, .owned, ty);
        const owned_inputs = try gpa.dupe(PhiInput, inputs);
        errdefer gpa.free(owned_inputs);
        try self.blockPtr(b).phis.append(gpa, .{ .result = result, .inputs = owned_inputs });
        return result;
    }

    pub fn setTerm(self: *Func, b: Block, term: Terminator) void {
        self.blockPtr(b).term = term;
    }
};

/// True if `op` consumes an owned operand (used by the future verifier + forwarding pass). The single
/// place that classifies consumption, so both passes agree.
pub fn consumesOperand(op: Op) ?Value {
    return switch (op) {
        .destroy => |v| v,
        .move_out => |v| v,
        else => null,
    };
}

// ─────────────────────────────────────────── tests ───────────────────────────────────────────

test "build a straight-line owned lifetime and read back ownership" {
    const gpa = std.testing.allocator;
    var f = Func{ .name = "t" };
    defer f.deinit(gpa);

    const entry = try f.newBlock(gpa);
    const x = try f.makeOwned(gpa, entry, null); // let x = alloc()  (+1)
    try f.borrowUse(gpa, entry, x); // read x (borrow)
    try f.destroy(gpa, entry, x); // drop x at scope end (-1)
    f.setTerm(entry, .ret_void);

    try std.testing.expectEqual(Ownership.owned, f.ownershipOf(x));
    try std.testing.expectEqual(@as(usize, 1), f.blocks.items.len);
    try std.testing.expectEqual(@as(usize, 3), f.blocks.items[0].instrs.items.len);
}

test "copy produces a second owned value; consumers are classified" {
    const gpa = std.testing.allocator;
    var f = Func{ .name = "t2" };
    defer f.deinit(gpa);

    const entry = try f.newBlock(gpa);
    const a = try f.makeOwned(gpa, entry, null);
    const b = try f.copy(gpa, entry, a); // let b = a  (dup, +1) -> new owned value
    try f.destroy(gpa, entry, a);
    f.setTerm(entry, .{ .ret_owned = b }); // return b (consumes b)

    try std.testing.expectEqual(Ownership.owned, f.ownershipOf(b));

    // Count producers vs consumers of owned values in the entry block (a taste of the I3 verifier):
    // owned produced = {a, b} = 2; consumed = destroy(a) + ret_owned(b) = 2 -> balanced.
    var owned_produced: usize = 0;
    var consumed: usize = 0;
    for (f.blocks.items[0].instrs.items) |ins| {
        if (ins.result != .none and f.ownershipOf(ins.result) == .owned) owned_produced += 1;
        if (consumesOperand(ins.op) != null) consumed += 1;
    }
    // the ret_owned terminator consumes the remaining one:
    switch (f.blocks.items[0].term.?) {
        .ret_owned => consumed += 1,
        else => {},
    }
    try std.testing.expectEqual(owned_produced, consumed);
}

test "borrow is non-owning and never consumed" {
    const gpa = std.testing.allocator;
    var f = Func{ .name = "t3" };
    defer f.deinit(gpa);

    const entry = try f.newBlock(gpa);
    const owned = try f.makeOwned(gpa, entry, null);
    const view = try f.borrow(gpa, entry, owned);
    try f.borrowUse(gpa, entry, view);
    try f.endBorrow(gpa, entry, view);
    try f.destroy(gpa, entry, owned);
    f.setTerm(entry, .ret_void);

    try std.testing.expectEqual(Ownership.borrowed, f.ownershipOf(view));
    try std.testing.expect(consumesOperand(.{ .borrow_use = view }) == null);
}
