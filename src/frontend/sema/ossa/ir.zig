//! Ownership SSA (OSSA): the tiny control-flow IR the ARC-balance verifier
//! reasons over.
//!
//! This is NOT the language's main typed IR. It is a deliberately minimal,
//! ownership-only representation, modelled on Swift's OSSA, whose sole job is
//! to make lifetimes explicit enough that a checker can prove every owned
//! value is consumed exactly once along every path (no leak, no double-free,
//! no use-after-consume). The codegen ARC pass lowers a Kyte function into a
//! [`Func`] of basic blocks whose instructions are ownership events, then a
//! separate verifier walks it. Because the only things represented here are
//! creation, copy, borrow, and consumption of SSA values, the checker never
//! has to understand actual Kyte semantics: it only tracks the [`Ownership`]
//! discipline.
//!
//! The value model is classic SSA. Each [`Value`] is produced exactly once (by
//! the instruction whose `result` it is, or by a [`Phi`]) and identified by a
//! dense `u32` index into [`Func.values`], which is why [`Value`] is a
//! `u32`-backed enum rather than a pointer: it doubles as the slot number in the
//! per-function side table [`ValueInfo`]. The sentinel [`Value.none`] marks an
//! instruction that produces no result (a `destroy`, a `borrow_use`, etc.),
//! so the verifier can skip result-classification for it.
//!
//! Three ownership kinds ([`Ownership`]) drive the whole discipline: `owned`
//! values MUST be consumed once (by [`Op.destroy`], [`Op.move_out`], or an
//! owning terminator like [`Terminator.ret_owned`]); `borrowed` values are
//! non-owning views that must be scoped between a [`Op.borrow`] and an
//! [`Op.end_borrow`] and are NEVER consumed; `trivial` values carry no
//! obligation at all. [`consumesOperand`] is the single source of truth the
//! verifier uses to decide which operand an instruction consumes.
//!
//! Everything here is built through the [`Func`] builder methods, which keep the
//! `values` side table and the block instruction lists in lock-step: a builder
//! that emits an instruction also allocates the result [`Value`] with the right
//! [`Ownership`], so the two can never disagree. The IR owns its own heap
//! (phi input slices, terminator case slices, the array lists) and is freed by
//! [`Func.deinit`].

const std = @import("std");
const types = @import("../../types.zig");

/// Re-export of the compiler's canonical type identifier so OSSA values can
/// optionally carry the Kyte type they represent without depending on the full
/// types module at every use site. Ownership checking does not need the type;
/// it is threaded through purely for diagnostics and downstream lowering.
pub const TypeId = types.TypeId;

/// An SSA value: a dense index into [`Func.values`] wrapped in a `u32` enum.
///
/// Each value is defined exactly once. The enum is non-exhaustive (`_`) because
/// any index up to the current value count is legal; only [`none`] has a fixed
/// meaning. Using an enum instead of a bare `u32` keeps value ids from being
/// confused with block ids or raw counts at the type level.
pub const Value = enum(u32) {
    /// Sentinel meaning "no value". Used as the `result` of instructions that
    /// produce nothing (destroy, move_out, borrow_use, end_borrow) so the
    /// verifier can distinguish a value-producing instruction from a pure
    /// ownership event. Chosen as the max `u32` so it can never collide with a
    /// real dense index.
    none = 0xFFFF_FFFF,
    _,
    /// Returns the dense array index this value occupies in [`Func.values`].
    ///
    /// Only meaningful for real values, never for [`none`]; callers must have
    /// already excluded the sentinel (the verifier does this by checking
    /// `result != .none` first).
    pub fn index(self: Value) u32 {
        return @intFromEnum(self);
    }
};

/// A basic block, identified by its index into [`Func.blocks`].
///
/// Non-exhaustive `u32` enum for the same reason as [`Value`]: it keeps block
/// ids distinct from value ids and raw lengths at the type level. Unlike
/// [`Value`] there is no sentinel; a block reference is always a real block.
pub const Block = enum(u32) { _ };

/// The ownership class of an SSA value, the property the whole verifier exists
/// to check.
pub const Ownership = enum {
    /// No ownership obligation: copyable and discardable freely (e.g. an
    /// integer). Neither produced by a consuming instruction nor requiring one.
    trivial,
    /// Must be consumed EXACTLY ONCE on every path, by [`Op.destroy`],
    /// [`Op.move_out`], or an owning terminator. Consuming zero times is a
    /// leak; consuming twice is a double-free.
    owned,
    /// A non-owning view of an [`owned`] value. Must live within a
    /// [`Op.borrow`]/[`Op.end_borrow`] scope and is NEVER consumed; see
    /// [`consumesOperand`], which never reports a borrow as consuming.
    borrowed,
};

/// A single ownership event. The verifier's alphabet: every instruction is one
/// of these, and its `result` (when not [`Value.none`]) is the value it defines.
pub const Op = union(enum) {
    /// Introduce a fresh [`Ownership.owned`] value with no operands (e.g. a
    /// heap allocation or the entry of an owned function argument).
    make_owned,
    /// Introduce a fresh [`Ownership.trivial`] value with no operands (e.g. a
    /// primitive literal). Carries no consumption obligation.
    make_trivial,
    /// Produce a second independently-`owned` value from `Value` (a deep copy /
    /// retain). Both the source and the copy must subsequently be consumed.
    copy: Value,
    /// Create a [`Ownership.borrowed`] view of `of`. The borrow does not consume
    /// its subject; the subject stays owned and must still be destroyed after
    /// the borrow ends.
    borrow: struct { of: Value },

    /// Consume `Value`, discharging its ownership obligation by releasing it.
    destroy: Value,
    /// Consume `Value` by moving it OUT of this function (e.g. handed to a
    /// callee or stored into an escaping location). Also discharges the
    /// obligation, but ownership transfers rather than being released here.
    move_out: Value,

    /// Read through a borrowed value. A non-consuming use; the borrow remains
    /// live afterwards. Also used on owned values as an ordinary read.
    borrow_use: Value,
    /// Close the scope opened by [`Op.borrow`] for `Value`, after which the
    /// borrowed view may no longer be used and the underlying owned value is
    /// available to be consumed.
    end_borrow: Value,
};

/// How a basic block ends. Every well-formed block has exactly one terminator,
/// which is what makes the control-flow graph explicit for the verifier's
/// path enumeration.
pub const Terminator = union(enum) {
    /// Return `Value`, transferring its ownership to the caller. Counts as a
    /// consumption of that [`Ownership.owned`] value.
    ret_owned: Value,
    /// Return a [`Ownership.trivial`] `Value`. Carries no consumption
    /// obligation; distinguished from [`ret_owned`] so the verifier does not
    /// treat it as discharging ownership.
    ret_trivial: Value,
    /// Return with no value.
    ret_void,
    /// Unconditional branch to `Block`.
    br: Block,
    /// Branch to `then_blk` or `else_blk` depending on `cond`. The verifier
    /// walks both successors, so an owned value must be consumed on each.
    cond_br: struct { cond: Value, then_blk: Block, else_blk: Block },
    /// Multi-way branch: one successor per entry of `cases`, plus `default_blk`.
    /// The `cases` slice is heap-owned by the [`Func`] and freed in
    /// [`Func.deinit`].
    switch_br: struct { cases: []Block, default_blk: Block },
    /// Unreachable terminator. Marks a block that cannot be reached at runtime,
    /// so no consumption obligations flow through it.
    unreach,
};

/// One instruction: an [`Op`] plus the [`Value`] it defines.
///
/// `result` is [`Value.none`] for pure ownership events that produce nothing;
/// otherwise it is the freshly-allocated value id, whose [`Ownership`] is
/// recorded in [`Func.values`] at the same time the instruction is emitted.
pub const Instr = struct {
    /// The value this instruction defines, or [`Value.none`] if it produces
    /// none.
    result: Value,
    /// The ownership event itself.
    op: Op,
};

/// One incoming edge of a [`Phi`]: the value flowing in from predecessor block
/// `pred`.
pub const PhiInput = struct {
    /// The predecessor block this input arrives from.
    pred: Block,
    /// The value that predecessor contributes to the phi's result.
    value: Value,
};

/// An SSA phi node: merges values from multiple predecessors into one result.
///
/// Modelled separately from [`Instr`] because phis are conceptually parallel and
/// live at the head of a block rather than in the instruction stream. The
/// `inputs` slice is heap-owned by the [`Func`]; [`Func.deinit`] frees it and
/// [`Func.setPhiInputs`] reallocates it.
pub const Phi = struct {
    /// The merged value this phi defines.
    result: Value,
    /// One entry per predecessor edge; owned by the containing [`Func`].
    inputs: []PhiInput,
};

/// A basic block: phis at the head, a straight-line list of instructions, and a
/// single terminator.
pub const BasicBlock = struct {
    /// The instruction stream, in execution order.
    instrs: std.ArrayListUnmanaged(Instr) = .empty,
    /// The block's phi nodes, evaluated on entry before the instructions.
    phis: std.ArrayListUnmanaged(Phi) = .empty,
    /// How the block ends. `null` while the block is still being built; a
    /// well-formed block has this set before verification via
    /// [`Func.setTerm`].
    term: ?Terminator = null,
};

/// Per-value side table entry, indexed by [`Value.index`].
///
/// Kept out-of-line from [`Value`] (which is just an id) so the dense array in
/// [`Func.values`] is the single home for a value's ownership class and type.
const ValueInfo = struct {
    /// The value's [`Ownership`] class, the fact the verifier reads via
    /// [`Func.ownershipOf`].
    own: Ownership,
    /// The Kyte type this value represents, if tracked. Optional because
    /// ownership checking does not require it.
    ty: ?TypeId = null,
};

/// One function's OSSA body plus the builder API that constructs it.
///
/// Holds two parallel stores: [`values`] (the per-value side table) and
/// [`blocks`] (the CFG). The builder methods (`makeOwned`, `copy`, `borrow`,
/// `destroy`, ...) are the only intended way to grow either, and they keep the
/// two consistent by allocating a value's [`ValueInfo`] at the same moment the
/// instruction that defines it is appended. Owns all its heap; free with
/// [`deinit`].
pub const Func = struct {
    /// The function's name, for diagnostics. Borrowed, not owned.
    name: []const u8 = "",
    /// Dense side table of every SSA value, indexed by [`Value.index`]. Grows by
    /// one each time a value-defining instruction or phi is emitted.
    values: std.ArrayListUnmanaged(ValueInfo) = .empty,
    /// The basic blocks of this function, indexed by [`Block`].
    blocks: std.ArrayListUnmanaged(BasicBlock) = .empty,

    /// Frees everything the function owns: each block's instruction and phi
    /// lists, every phi's heap-allocated `inputs` slice, any `switch_br` case
    /// slice, and the two top-level array lists.
    ///
    /// Note the two nested frees that are easy to miss: phi `inputs` (allocated
    /// by [`addPhi`]/[`setPhiInputs`]) and `switch_br.cases`. Everything else is
    /// inline in the array lists.
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

    /// Returns the [`Ownership`] class of value `v` by reading its
    /// [`ValueInfo`]. This is the query the verifier uses to decide a value's
    /// obligations. Panics on [`Value.none`] (its index is not a valid slot).
    pub fn ownershipOf(self: *const Func, v: Value) Ownership {
        return self.values.items[v.index()].own;
    }

    /// Appends a fresh empty [`BasicBlock`] and returns its [`Block`] id.
    ///
    /// The id is simply the block's position, so blocks are numbered in
    /// creation order. The caller populates it via the emit helpers and sets
    /// its terminator with [`setTerm`].
    pub fn newBlock(self: *Func, gpa: std.mem.Allocator) !Block {
        const id: u32 = @intCast(self.blocks.items.len);
        try self.blocks.append(gpa, .{});
        return @enumFromInt(id);
    }

    /// Allocates a new SSA value with ownership `own` and optional type `ty`,
    /// returning its [`Value`] id.
    ///
    /// Private because value creation must stay paired with emitting the
    /// instruction that defines it; the public `makeOwned`/`copy`/`borrow`/...
    /// builders call this and then [`emit`] so the side table and instruction
    /// stream never drift apart.
    fn newValue(self: *Func, gpa: std.mem.Allocator, own: Ownership, ty: ?TypeId) !Value {
        const id: u32 = @intCast(self.values.items.len);
        try self.values.append(gpa, .{ .own = own, .ty = ty });
        return @enumFromInt(id);
    }

    /// Returns a mutable pointer to block `b`'s storage. Private helper used by
    /// the emit/phi/terminator methods; the pointer is valid only until the
    /// `blocks` list next reallocates.
    fn blockPtr(self: *Func, b: Block) *BasicBlock {
        return &self.blocks.items[@intFromEnum(b)];
    }

    /// Appends an [`Instr`] with the given `result` and `op` to block `b`.
    /// Private; the public builders call this after allocating the result
    /// value with [`newValue`].
    fn emit(self: *Func, gpa: std.mem.Allocator, b: Block, result: Value, op: Op) !void {
        try self.blockPtr(b).instrs.append(gpa, .{ .result = result, .op = op });
    }

    /// Emits a [`Op.make_owned`] into block `b` and returns the new
    /// [`Ownership.owned`] value it defines.
    pub fn makeOwned(self: *Func, gpa: std.mem.Allocator, b: Block, ty: ?TypeId) !Value {
        const v = try self.newValue(gpa, .owned, ty);
        try self.emit(gpa, b, v, .make_owned);
        return v;
    }
    /// Emits a [`Op.make_trivial`] into block `b` and returns the new
    /// [`Ownership.trivial`] value it defines.
    pub fn makeTrivial(self: *Func, gpa: std.mem.Allocator, b: Block, ty: ?TypeId) !Value {
        const v = try self.newValue(gpa, .trivial, ty);
        try self.emit(gpa, b, v, .make_trivial);
        return v;
    }
    /// Emits a [`Op.copy`] of `src` into block `b`, returning a second,
    /// independently-`owned` value. The copy inherits `src`'s type. Both the
    /// source and the result must be consumed.
    pub fn copy(self: *Func, gpa: std.mem.Allocator, b: Block, src: Value) !Value {
        const v = try self.newValue(gpa, .owned, self.values.items[src.index()].ty);
        try self.emit(gpa, b, v, .{ .copy = src });
        return v;
    }
    /// Emits a [`Op.borrow`] of `of` into block `b`, returning a
    /// [`Ownership.borrowed`] view. The view inherits `of`'s type, does not
    /// consume it, and must be closed with [`endBorrow`].
    pub fn borrow(self: *Func, gpa: std.mem.Allocator, b: Block, of: Value) !Value {
        const v = try self.newValue(gpa, .borrowed, self.values.items[of.index()].ty);
        try self.emit(gpa, b, v, .{ .borrow = .{ .of = of } });
        return v;
    }

    /// Emits a [`Op.destroy`] of `v` (result [`Value.none`]), consuming it by
    /// release.
    pub fn destroy(self: *Func, gpa: std.mem.Allocator, b: Block, v: Value) !void {
        try self.emit(gpa, b, .none, .{ .destroy = v });
    }
    /// Emits a [`Op.move_out`] of `v` (result [`Value.none`]), consuming it by
    /// transferring ownership out of the function.
    pub fn moveOut(self: *Func, gpa: std.mem.Allocator, b: Block, v: Value) !void {
        try self.emit(gpa, b, .none, .{ .move_out = v });
    }
    /// Emits a [`Op.borrow_use`] of `v` (result [`Value.none`]): a non-consuming
    /// read.
    pub fn borrowUse(self: *Func, gpa: std.mem.Allocator, b: Block, v: Value) !void {
        try self.emit(gpa, b, .none, .{ .borrow_use = v });
    }
    /// Emits a [`Op.end_borrow`] of `v` (result [`Value.none`]), closing the
    /// borrow scope opened by [`borrow`].
    pub fn endBorrow(self: *Func, gpa: std.mem.Allocator, b: Block, v: Value) !void {
        try self.emit(gpa, b, .none, .{ .end_borrow = v });
    }

    /// Adds a [`Phi`] to the head of block `b` merging `inputs`, and returns the
    /// [`Ownership.owned`] value it defines.
    ///
    /// The `inputs` slice is COPIED into function-owned memory (the caller's
    /// slice may be a temporary); the copy is freed by [`deinit`]. `errdefer`
    /// frees the copy if appending the phi fails. Use [`setPhiInputs`] to
    /// rewrite the edges later, which is needed when the predecessor values are
    /// not yet known at phi-creation time.
    pub fn addPhi(self: *Func, gpa: std.mem.Allocator, b: Block, inputs: []const PhiInput, ty: ?TypeId) !Value {
        const result = try self.newValue(gpa, .owned, ty);
        const owned_inputs = try gpa.dupe(PhiInput, inputs);
        errdefer gpa.free(owned_inputs);
        try self.blockPtr(b).phis.append(gpa, .{ .result = result, .inputs = owned_inputs });
        return result;
    }

    /// Replaces the inputs of the `phi_index`-th phi in block `b` with a fresh
    /// copy of `inputs`.
    ///
    /// Frees the previous `inputs` slice and installs a newly-duped one, so the
    /// phi's result id is preserved while its incoming edges change. This is the
    /// second half of the build-phi-then-fill-edges pattern that lets a phi be
    /// created before its predecessors' values exist.
    pub fn setPhiInputs(self: *Func, gpa: std.mem.Allocator, b: Block, phi_index: usize, inputs: []const PhiInput) !void {
        const ph = &self.blockPtr(b).phis.items[phi_index];
        const owned = try gpa.dupe(PhiInput, inputs);
        gpa.free(ph.inputs);
        ph.inputs = owned;
    }

    /// Sets block `b`'s [`Terminator`]. Overwrites any previous terminator.
    ///
    /// Note: if `term` is a [`Terminator.switch_br`] its `cases` slice is taken
    /// as function-owned and will be freed by [`deinit`]; overwriting a prior
    /// `switch_br` here does NOT free the old cases slice.
    pub fn setTerm(self: *Func, b: Block, term: Terminator) void {
        self.blockPtr(b).term = term;
    }
};

/// Returns the value an instruction consumes, or `null` if it consumes none.
///
/// This is the verifier's single source of truth for what discharges an owned
/// value's obligation: only [`Op.destroy`] and [`Op.move_out`] consume; copies,
/// borrows, and non-consuming uses do not. Owning terminators
/// ([`Terminator.ret_owned`]) are handled separately by the caller because they
/// live on blocks, not in the instruction stream.
pub fn consumesOperand(op: Op) ?Value {
    return switch (op) {
        .destroy => |v| v,
        .move_out => |v| v,
        else => null,
    };
}


// Sanity-checks the builder on the simplest shape: one owned value created,
// used through a non-consuming borrow_use, then destroyed. Asserts the value
// reads back as owned and that the block accumulated exactly the three emitted
// instructions.
test "build a straight-line owned lifetime and read back ownership" {
    const gpa = std.testing.allocator;
    var f = Func{ .name = "t" };
    defer f.deinit(gpa);

    const entry = try f.newBlock(gpa);
    const x = try f.makeOwned(gpa, entry, null);
    try f.borrowUse(gpa, entry, x);
    try f.destroy(gpa, entry, x);
    f.setTerm(entry, .ret_void);

    try std.testing.expectEqual(Ownership.owned, f.ownershipOf(x));
    try std.testing.expectEqual(@as(usize, 1), f.blocks.items.len);
    try std.testing.expectEqual(@as(usize, 3), f.blocks.items[0].instrs.items.len);
}

// Checks the ownership accounting the verifier relies on: a copy yields a
// second owned value, and across the block the count of owned values PRODUCED
// (by instruction results) equals the count CONSUMED (by consumesOperand plus
// an owning ret_owned terminator). Balance is exactly the invariant OSSA
// exists to enforce.
test "copy produces a second owned value; consumers are classified" {
    const gpa = std.testing.allocator;
    var f = Func{ .name = "t2" };
    defer f.deinit(gpa);

    const entry = try f.newBlock(gpa);
    const a = try f.makeOwned(gpa, entry, null);
    const b = try f.copy(gpa, entry, a);
    try f.destroy(gpa, entry, a);
    f.setTerm(entry, .{ .ret_owned = b });

    try std.testing.expectEqual(Ownership.owned, f.ownershipOf(b));

    var owned_produced: usize = 0;
    var consumed: usize = 0;
    for (f.blocks.items[0].instrs.items) |ins| {
        if (ins.result != .none and f.ownershipOf(ins.result) == .owned) owned_produced += 1;
        if (consumesOperand(ins.op) != null) consumed += 1;
    }
    switch (f.blocks.items[0].term.?) {
        .ret_owned => consumed += 1,
        else => {},
    }
    try std.testing.expectEqual(owned_produced, consumed);
}

// Confirms the borrow discipline: a borrowed view classifies as borrowed, is
// used and ended within its scope while the underlying owned value is destroyed
// separately, and consumesOperand reports a borrow_use as consuming nothing.
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
