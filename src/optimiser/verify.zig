// verify.zig — the MIR verifier.
//
// Runs after every pass in debug builds. Checks the invariants that keep the optimiser honest: SSA has
// exactly one definition per value; block arguments match every predecessor's terminator arguments;
// every use is dominated by its definition; operand types are consistent; and ARC is balanced (each
// value's retains and releases net to its ownership contract). A pass that breaks any invariant fails
// loudly at the pass boundary, not later as a mysterious miscompile. See docs/design/optimiser.md.
// M0: signature + result shape only; the checks are filled in with the lowering (M2).

const std = @import("std");
const mir = @import("mir.zig");

pub const Error = struct {
    kind: Kind,
    detail: []const u8,

    pub const Kind = enum {
        multiple_defs, // an SSA value defined more than once
        use_before_def, // a use not dominated by its definition
        block_arg_mismatch, // predecessor terminator args do not match block params
        type_mismatch, // operand types inconsistent for the instruction
        arc_imbalance, // retains and releases do not net to the ownership contract
    };
};

// Verify a function. Returns the list of violations (empty = well-formed). M0 stub: no checks yet.
pub fn verify(allocator: std.mem.Allocator, func: *const mir.Func) ![]Error {
    _ = func;
    return allocator.alloc(Error, 0);
}
