//! Front-end, name-and-type sanity pass over a whole Nova [`ast.Program`].
//!
//! This is the FIRST checker the compiler runs, before the authoritative typed
//! IR in `sema/` (infer/mono/ownership/lower). Its job is deliberately narrow:
//! catch the mistakes that are cheap to catch on the raw AST and turn into a
//! clear, source-annotated diagnostic, so the user sees a good message rather
//! than a downstream mono/codegen crash or a confusing `sema` error. It is a
//! best-effort structural pass, NOT a sound type system: [`resolveExprType`]
//! returns `?ast.TypeRef` and gives up (`null`) the moment it cannot be sure,
//! and every check is written to stay silent unless it is confident an error is
//! real. A false negative here is fine (the real type engine will catch it); a
//! false positive is a bug because it rejects valid code.
//!
//! What it actually enforces, roughly in the order the checks fire:
//!   - Declaration hygiene: duplicate functions (Nova has NO overloading, see
//!     [`TypeChecker.check`]), duplicate methods/variants/type-params, structs
//!     that would be infinite-size by containing themselves by value
//!     ([`TypeChecker.checkValueStructCycles`]).
//!   - Type existence: unknown type names, and the removed 128-bit integer
//!     types, are rejected in [`TypeChecker.rejectUnimplementedType`].
//!   - Arity and narrowing on calls/constructors/closures: wrong argument
//!     counts, and the numeric-safety rules from spec F3 (no implicit narrowing
//!     int conversion, no signedness flip, no `ptr`→narrow-int truncation, no
//!     integer literal out of range for its declared type).
//!   - Control-flow: a non-void function must return on every path
//!     ([`TypeChecker.blockDefinitelyReturns`]); a `switch` over an enum must be
//!     exhaustive or have a default ([`TypeChecker.checkSwitch`]).
//!   - async/await colouring: an `async` call inside an `async fn` must be
//!     `await`ed or `spawn`ed (a bare call would block-drive the coroutine and
//!     deadlock the reactor), and `await`/`spawn`/`async` are rejected on the
//!     wasm target, which has no coroutine runtime.
//!   - Trait conformance: a `struct`/`enum` that declares `impl Trait` must
//!     supply every method with the matching async-ness, arity, parameter
//!     types, and return type (with the trait's type parameters substituted).
//!   - Module privacy: a non-`pub` field or method is only reachable from its
//!     own module (its own source file) or from inside its own type.
//!
//! Design notes worth knowing before editing:
//!   - Type names are compared through [`canonicalizeTypeName`], which folds the
//!     friendly spellings (`int`/`long`/`byte`/`double`/`u32`...) onto a canonical
//!     `iN`/`fN` name. Signedness is recovered separately from the ORIGINAL name
//!     ([`intNameSigned`]) because canonicalisation is lossy about sign.
//!   - Diagnostics are emitted TWICE by [`TypeChecker.addError`]: a plain
//!     structured record (for the LSP) and a coloured, source-quoted string (for
//!     the terminal). The pass keeps going after an error and only fails at the
//!     end of [`TypeChecker.check`] if any were recorded.
//!   - Colliding declarations (the same struct/enum name defined in two
//!     different files, tracked in `colliding_structs`/`colliding_enums`) are
//!     mostly SKIPPED rather than checked, because we cannot know which
//!     definition a use refers to and would risk a false positive.
//!   - The `isVariable*`/`exprReferences*` free functions at the bottom are a
//!     small ownership-flow helper set (does a variable get `delete`d in a
//!     `defer`, or returned) used by other passes; they are pure AST walkers.

const std = @import("std");
const ast = @import("ast.zig");
const builtins = @import("sema/builtins.zig");

/// Maps a builtin function's abstract return kind ([`builtins.Ret`]) to the
/// concrete [`ast.TypeRef`] the checker reasons about, so a call like
/// `s.len()` resolves to `i32` and participates in later type checks.
///
/// Returns `null` only for `builtins.Ret` variants that carry no meaningful
/// Nova type. Note the SIMD lanes map to Nova's vector spellings (`f64x4`,
/// `u8x16`, ...), which the rest of the checker treats as plain idents.
fn builtinRetType(r: builtins.Ret) ?ast.TypeRef {
    return switch (r) {
        .void_ => ast.TypeRef{ .ident = "void" },
        .int => ast.TypeRef{ .ident = "i32" },
        .long => ast.TypeRef{ .ident = "i64" },
        .ptr => ast.TypeRef{ .ident = "ptr" },
        .string => ast.TypeRef{ .ident = "string" },
        .bool_ => ast.TypeRef{ .ident = "bool" },
        .decimal => ast.TypeRef{ .ident = "decimal" },
        .double => ast.TypeRef{ .ident = "f64" },
        .vec4 => ast.TypeRef{ .ident = "f64x4" },
        .vec_u8x16 => ast.TypeRef{ .ident = "u8x16" },
        .vec_u32x4 => ast.TypeRef{ .ident = "u32x4" },
        .vec_u64x2 => ast.TypeRef{ .ident = "u64x2" },
    };
}

/// True when storing `from` into `to` would truncate a raw address, i.e.
/// `from` is `ptr` and `to` is a narrower-than-64-bit signed int (`i8`/`i16`/
/// `i32`).
///
/// This is the F3 §3.2 rule: a `ptr` holds a full 64-bit address, so silently
/// putting it in an `int` (`i32`) chops the top half and yields a garbage
/// pointer. Only these three narrow widths trip it; `ptr`→`i64` is handled as an
/// allowed conversion in [`TypeChecker.assignable`], not here.
fn isPtrTruncation(from: ast.TypeRef, to: ast.TypeRef) bool {
    if (from != .ident or to != .ident) return false;
    if (!std.mem.eql(u8, canonicalizeTypeName(from.ident), "ptr")) return false;
    const ct = canonicalizeTypeName(to.ident);
    return std.mem.eql(u8, ct, "i8") or std.mem.eql(u8, ct, "i16") or std.mem.eql(u8, ct, "i32");
}

/// The inclusive value range `[min, max]` an integer type can represent.
///
/// Held as `i128` so both signed and unsigned 8/16/32-bit ranges fit exactly.
/// Produced by [`intTypeRange`] and used to reject out-of-range literals.
const IntRange = struct {
    /// Smallest representable value (negative for signed types, `0` unsigned).
    min: i128,
    /// Largest representable value.
    max: i128,
};
/// Computes the representable [`IntRange`] for a small integer type spelled
/// `name`, or `null` for anything wider than 32 bits or not an integer.
///
/// Only 8/16/32-bit widths are ranged because those are the only widths whose
/// bounds are cheap to enforce against literals; `i64`/`long` is left
/// unchecked (its range is effectively "any literal"). Signedness is read from
/// the ORIGINAL `name` (an `u`-prefix or `byte`), since the canonical name from
/// [`canonicalizeTypeName`] loses the sign.
fn intTypeRange(name: []const u8) ?IntRange {
    const c = canonicalizeTypeName(name);

    const signed = !(std.mem.startsWith(u8, name, "u") or std.mem.eql(u8, name, "byte"));
    const w: u32 = if (std.mem.eql(u8, c, "i8")) 8 else if (std.mem.eql(u8, c, "i16")) 16 else if (std.mem.eql(u8, c, "i32")) 32 else return null;
    if (signed) {
        const half: i128 = @as(i128, 1) << @intCast(w - 1);
        return .{ .min = -half, .max = half - 1 };
    }
    return .{ .min = 0, .max = (@as(i128, 1) << @intCast(w)) - 1 };
}

/// Bit width of an integer type spelled `name` (8/16/32/64), or `null` if it
/// is not one of the recognised integer types.
///
/// Works on the canonical name, so `int`, `i32` and `u32` all report 32. Used
/// by the narrowing/signedness checks to compare widths regardless of sign.
fn intWidthOf(name: []const u8) ?u32 {
    const c = canonicalizeTypeName(name);
    if (std.mem.eql(u8, c, "i8")) return 8;
    if (std.mem.eql(u8, c, "i16")) return 16;
    if (std.mem.eql(u8, c, "i32")) return 32;
    if (std.mem.eql(u8, c, "i64")) return 64;
    return null;
}

/// True when `from` is a wider integer than `to`, so storing it implicitly
/// would drop high bits (a narrowing conversion, forbidden by F3 §6).
///
/// Both operands must be integer idents; any non-integer or non-ident type
/// yields `false` (this check does not apply). Width is compared via
/// [`intWidthOf`], so sign is ignored here (see [`isSignednessMismatch`] for
/// the same-width sign case).
fn isNarrowingInt(from: ast.TypeRef, to: ast.TypeRef) bool {
    if (from != .ident or to != .ident) return false;
    const fw = intWidthOf(from.ident) orelse return false;
    const tw = intWidthOf(to.ident) orelse return false;
    return fw > tw;
}

/// Whether the integer type spelled `name` is signed.
///
/// Decided from the ORIGINAL spelling, not the canonical name, because
/// canonicalisation collapses `u32`→`i32` and loses the sign. The rule is:
/// signed unless the name starts with `u` (`uint`, `u8`, `ulong`, ...) or is
/// exactly `byte` (which Nova treats as unsigned).
fn intNameSigned(name: []const u8) bool {
    return !(std.mem.startsWith(u8, name, "u") or std.mem.eql(u8, name, "byte"));
}

/// True when `from` and `to` are integers of the SAME width but differ in
/// signedness (e.g. `i32` into `u32`), which F3 §6 requires an explicit cast
/// for because the bit pattern's meaning changes.
///
/// Different widths return `false` here so the caller reports them as narrowing
/// instead (see [`isNarrowingInt`]); non-integer operands also return `false`.
fn isSignednessMismatch(from: ast.TypeRef, to: ast.TypeRef) bool {
    if (from != .ident or to != .ident) return false;
    const fw = intWidthOf(from.ident) orelse return false;
    const tw = intWidthOf(to.ident) orelse return false;
    if (fw != tw) return false;
    return intNameSigned(from.ident) != intNameSigned(to.ident);
}

/// Evaluates `expr` to a compile-time integer if it is a bare integer literal
/// or the negation of one; otherwise `null`.
///
/// Only these two shapes are folded (a literal, and unary `-` over a literal),
/// which is enough to range-check `let x: i8 = -129` and to recognise a literal
/// argument so it can skip the stricter typed-argument checks. Recurses through
/// exactly one `neg` so `- -5` is not folded. Anything else (identifiers,
/// arithmetic) returns `null`.
fn intLiteralValue(expr: ast.Expression) ?i128 {
    switch (expr.kind) {
        .literal => |lit| return switch (lit) {
            .integer => |v| @as(i128, v),
            else => null,
        },
        .unary => |u| {
            if (u.op == .neg) {
                if (intLiteralValue(u.operand.*)) |v| return -v;
            }
            return null;
        },
        else => return null,
    }
}

/// Returns the bare type name if `tr` is an `.ident` type, else `null`.
///
/// A convenience for the many checks that only care about simple named types
/// and want to bail on optionals, generics, tuples, etc.
fn identOf(tr: ast.TypeRef) ?[]const u8 {
    return switch (tr) {
        .ident => |n| n,
        else => null,
    };
}

/// Convention-equality of two field names for the `..from` mapper spread:
/// case-insensitive and ignoring underscores, so `image_url` matches `imageUrl`
/// and `full_name` matches `fullName`. Shared conceptually with the codegen
/// matcher in `expressions.zig` (kept in sync by hand).
pub fn fieldConvEq(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and a[i] == '_') i += 1;
        while (j < b.len and b[j] == '_') j += 1;
        if (i >= a.len or j >= b.len) break;
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        i += 1;
        j += 1;
    }
    while (i < a.len and a[i] == '_') i += 1;
    while (j < b.len and b[j] == '_') j += 1;
    return i >= a.len and j >= b.len;
}

/// Whether `name` is one of the scalar primitive type names allowed as a raw
/// array element (see the array-literal check in [`TypeChecker.checkExpr`]).
///
/// The list is matched by EXACT spelling (no canonicalisation), so both the
/// friendly names (`int`, `long`, `double`) and the explicit-width names
/// (`i32`, `u64`, `f64`) are accepted. Struct/tuple/reference element types are
/// deliberately absent because a fixed array stores primitives inline. Compare
/// [`isScalarPrimitiveName`], a similar but not identical list used for
/// indexability.
fn isScalarPrim(name: []const u8) bool {
    const scalars = [_][]const u8{
        "int",  "long", "byte", "bool",   "float", "double", "char",
        "uint", "ulong", "short", "ushort", "i8",   "i16",    "i32",
        "i64",  "u8",   "u16",  "u32",    "u64",  "f32",    "f64",
    };
    for (scalars) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

/// True when one of `a`/`b` is `string` and the other is a scalar primitive,
/// i.e. a clearly incompatible pairing that no implicit conversion bridges.
///
/// Used when checking an explicitly-parameterised struct literal
/// (`Box<string>{ value: 3 }`): if the type argument says `string` but the
/// value resolves to a number (or vice versa) this catches it. Order-agnostic;
/// returns `false` unless exactly one side is `string`.
fn stringScalarClash(a: ast.TypeRef, b: ast.TypeRef) bool {
    const an = identOf(a) orelse return false;
    const bn = identOf(b) orelse return false;
    const a_str = std.mem.eql(u8, an, "string");
    const b_str = std.mem.eql(u8, bn, "string");
    if (a_str and isScalarPrim(bn)) return true;
    if (b_str and isScalarPrim(an)) return true;
    return false;
}

/// A machine-readable type-check error, one per call to
/// [`TypeChecker.addError`].
///
/// This is the structured counterpart to the coloured terminal string; it is
/// what an LSP or other tool consumes. The `message` is an owned copy freed in
/// [`TypeChecker.deinit`]; the `file` slice is borrowed from the AST span.
pub const Diagnostic = struct {
    /// Source file the error points into.
    file: []const u8,
    /// Byte offset of the error within `file`.
    start: usize,
    /// 1-based line number of the error.
    line: usize,
    /// 1-based column number of the error.
    col: usize,
    /// Human-readable error text (owned, freed on [`TypeChecker.deinit`]).
    message: []const u8,
};

/// The recorded parameter signature of a closure bound to a name, so a later
/// call through that name can be arity- and type-checked.
///
/// Only parameter types are kept (each optional, since a closure parameter may
/// be untyped); the return type is not needed for the checks that consume this.
/// Populated in [`TypeChecker.checkStatement`] when a `let` binds a closure or
/// aliases another closure-typed name.
const ClosureSig = struct {
    /// Declared type of each parameter, `null` where the closure left it out.
    param_types: []const ?ast.TypeRef,
};

/// The whole-program structural type checker.
///
/// One instance is built with [`init`], loaded with a program via [`check`]
/// (which first indexes every declaration into the symbol tables below, then
/// walks bodies), and torn down with [`deinit`]. It owns a set of
/// string-keyed symbol tables (all keyed by declaration NAME, so same-named
/// declarations across modules are tracked as collisions rather than
/// distinguished) plus a small amount of per-function scratch state
/// (`variables`, `closure_sigs`, `current_ret_type`, `in_async`) that is reset
/// as it enters each function/method body.
pub const TypeChecker = struct {
    /// Allocator for all owned strings, symbol tables, and scratch buffers.
    allocator: std.mem.Allocator,
    /// Coloured, source-quoted error strings for terminal output; each is owned
    /// and freed in [`deinit`]. Non-empty at the end of [`check`] means the
    /// pass fails with `error.TypeCheckError`.
    errors: std.ArrayList([]const u8),
    /// Structured [`Diagnostic`] records, the LSP-facing mirror of `errors`.
    structured: std.ArrayList(Diagnostic),
    /// When true, suppress printing the error summary to stderr in [`check`]
    /// (the caller still learns of failure via the returned error). Set by
    /// tooling that wants the structured diagnostics without console noise.
    silent: bool = false,
    /// Borrowed map from file name to that file's full source text, used by
    /// [`addError`] to quote the offending line under the message.
    file_sources: *std.StringHashMap([]const u8),
    /// All enum declarations, keyed by name.
    enums: std.StringHashMap(ast.EnumDecl),
    /// Types of the variables in scope for the body currently being checked;
    /// cleared at the start of each function/method (see [`checkFunction`]).
    variables: std.StringHashMap(ast.TypeRef),
    /// Signatures of closures bound to names in the current scope, so calls
    /// through those names can be arity/type-checked. Also per-body scratch.
    closure_sigs: std.StringHashMap(ClosureSig),
    /// All struct declarations, keyed by name.
    structs: std.StringHashMap(ast.StructDecl),
    /// Names of structs defined in MORE THAN ONE file. Such names are ambiguous,
    /// so most checks skip them to avoid a false positive against the wrong
    /// definition.
    colliding_structs: std.StringHashMap(void),
    /// Names of enums defined in more than one file; skipped like
    /// [`colliding_structs`] during exhaustiveness and switch checks.
    colliding_enums: std.StringHashMap(void),
    /// All union declarations, keyed by name.
    unions: std.StringHashMap(ast.UnionDecl),
    /// All trait declarations, keyed by name.
    traits: std.StringHashMap(ast.TraitDecl),
    /// All top-level function declarations, keyed by name (last one wins; see
    /// [`ambiguous_fns`] for names that appeared more than once).
    functions: std.StringHashMap(ast.FunctionDecl),

    /// Function names that appear in more than one imported module. A bare call
    /// to such a name is reported as ambiguous unless the current file defines
    /// its own (see [`fileDefinesFn`]).
    ambiguous_fns: std.StringHashMap(void),

    /// Set of `"<file>\x00<name>"` keys recording where each function is
    /// defined, used to detect a genuine duplicate definition (same name, same
    /// file, different line) vs. the same name across modules. Keys are owned.
    fn_def_sites: std.StringHashMap(void),
    /// Maps the same `"<file>\x00<name>"` key to the FIRST line the function was
    /// seen on, so a duplicate can name the original location. Keys are owned.
    fn_first_line: std.StringHashMap(usize) = undefined,
    /// Name of the struct/enum whose body is currently being checked, used by
    /// [`memberAccessible`] to allow a type to touch its own private members.
    current_struct: ?[]const u8,
    /// Declared return type of the function/method currently being checked, so
    /// `return <expr>` can be type-checked in [`checkReturnType`].
    current_ret_type: ?ast.TypeRef = null,

    /// True while inside an `async fn` body; gates the "async call must be
    /// awaited" and `await`/`spawn` placement checks.
    in_async: bool = false,

    /// True while checking the operand of an `await`/`spawn` (or the args of
    /// `coroStart`), meaning a nested async call here is legitimately driven and
    /// must NOT be flagged. Saved/restored around each such operand.
    in_awaited: bool = false,

    /// True when compiling for the wasm target, which has no coroutine runtime;
    /// enables the diagnostics that reject `async`/`await`/`spawn`.
    is_wasm: bool = false,

    /// Constructs an empty checker with all symbol tables initialised.
    ///
    /// `file_sources` is borrowed (not owned) and must outlive the checker; it
    /// is only read, to quote source lines in error messages.
    pub fn init(allocator: std.mem.Allocator, file_sources: *std.StringHashMap([]const u8)) TypeChecker {
        return TypeChecker{
            .allocator = allocator,
            .errors = std.ArrayList([]const u8).empty,
            .structured = std.ArrayList(Diagnostic).empty,
            .file_sources = file_sources,
            .enums = std.StringHashMap(ast.EnumDecl).init(allocator),
            .variables = std.StringHashMap(ast.TypeRef).init(allocator),
            .closure_sigs = std.StringHashMap(ClosureSig).init(allocator),
            .structs = std.StringHashMap(ast.StructDecl).init(allocator),
            .colliding_structs = std.StringHashMap(void).init(allocator),
            .colliding_enums = std.StringHashMap(void).init(allocator),
            .unions = std.StringHashMap(ast.UnionDecl).init(allocator),
            .traits = std.StringHashMap(ast.TraitDecl).init(allocator),
            .functions = std.StringHashMap(ast.FunctionDecl).init(allocator),
            .ambiguous_fns = std.StringHashMap(void).init(allocator),
            .fn_def_sites = std.StringHashMap(void).init(allocator),
            .fn_first_line = std.StringHashMap(usize).init(allocator),
            .current_struct = null,
        };
    }

    /// Whether `file` contains its own definition of function `name`.
    ///
    /// Consulted when a call name is ambiguous across modules: if the calling
    /// file defines the function itself, the local definition wins and no
    /// ambiguity error is raised. Builds the same `"<file>\x00<name>"` key as
    /// [`check`] and returns `false` on allocation failure.
    fn fileDefinesFn(self: *TypeChecker, file: []const u8, name: []const u8) bool {
        const key = std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ file, name }) catch return false;
        defer self.allocator.free(key);
        return self.fn_def_sites.contains(key);
    }

    /// Releases every owned allocation: the error strings, the structured
    /// diagnostic messages, all symbol tables, and the owned keys in
    /// [`fn_def_sites`].
    pub fn deinit(self: *TypeChecker) void {
        for (self.errors.items) |err| {
            self.allocator.free(err);
        }
        self.errors.deinit(self.allocator);
        for (self.structured.items) |d| {
            self.allocator.free(d.message);
        }
        self.structured.deinit(self.allocator);
        self.enums.deinit();
        self.variables.deinit();
        self.closure_sigs.deinit();
        self.structs.deinit();
        self.colliding_structs.deinit();
        self.colliding_enums.deinit();
        self.unions.deinit();
        self.traits.deinit();
        self.functions.deinit();
        self.ambiguous_fns.deinit();
        var it = self.fn_def_sites.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.fn_def_sites.deinit();
    }

    /// Records one diagnostic at `span`, formatting `fmt`/`args` into the
    /// message.
    ///
    /// Produces BOTH outputs: a structured [`Diagnostic`] appended to
    /// `structured`, and a coloured terminal string (bold file:line:col,
    /// red `error:`, the offending source line, and a green `^` caret under the
    /// column) appended to `errors`. The caret line is only added when the
    /// source for `span.file` is available in [`file_sources`] and the line is
    /// found. All allocation failures are swallowed (the diagnostic is simply
    /// dropped) so error reporting can never itself fail the compile. Recording
    /// an error does not stop the pass; [`check`] fails at the end if any exist.
    fn addError(self: *TypeChecker, span: ast.Span, comptime fmt: []const u8, args: anytype) void {
        const user_msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(user_msg);

        if (self.allocator.dupe(u8, user_msg)) |plain| {
            self.structured.append(self.allocator, .{
                .file = span.file,
                .start = span.start,
                .line = span.line,
                .col = span.col,
                .message = plain,
            }) catch self.allocator.free(plain);
        } else |_| {}

        const src = self.file_sources.get(span.file) orelse "";

        var msg_list = std.ArrayList(u8).empty;
        defer msg_list.deinit(self.allocator);

        const line_fmt_1 = std.fmt.allocPrint(self.allocator, "\x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m {s}\x1b[0m\n", .{ span.file, span.line, span.col, user_msg }) catch return;
        defer self.allocator.free(line_fmt_1);
        msg_list.appendSlice(self.allocator, line_fmt_1) catch {};

        if (src.len > 0) {
            var line_num: usize = 1;
            var start_idx: usize = 0;
            var i: usize = 0;
            while (i < src.len) : (i += 1) {
                if (src[i] == '\n') {
                    if (line_num == span.line) {
                        break;
                    }
                    line_num += 1;
                    start_idx = i + 1;
                }
            }
            const end_idx = i;
            if (line_num == span.line) {
                const line_content = src[start_idx..end_idx];
                const line_fmt_2 = std.fmt.allocPrint(self.allocator, " {d: >4} | {s}\n", .{ span.line, line_content }) catch return;
                defer self.allocator.free(line_fmt_2);
                msg_list.appendSlice(self.allocator, line_fmt_2) catch {};

                msg_list.appendSlice(self.allocator, "      | ") catch {};
                var col_idx: usize = 1;
                while (col_idx < span.col) : (col_idx += 1) {
                    msg_list.appendSlice(self.allocator, " ") catch {};
                }
                msg_list.appendSlice(self.allocator, "\x1b[1;32m^\x1b[0m\n") catch {};
            }
        }

        const formatted = msg_list.toOwnedSlice(self.allocator) catch return;
        self.errors.append(self.allocator, formatted) catch {};
    }

    /// Reports every value `struct` that would be infinite-size by containing
    /// itself (directly or transitively) as a by-value field.
    ///
    /// A `struct` is stored inline, so a cycle of value structs has no finite
    /// layout. Reference types (`class`, `is_reference`) break the cycle, so
    /// they are skipped as roots and as edges. Runs a three-colour DFS
    /// ([`dfsValueStructCycle`]) over the struct graph; `state` maps each name
    /// to 0=unvisited, 1=on the current path, 2=done.
    fn checkValueStructCycles(self: *TypeChecker) void {
        var state = std.StringHashMap(u8).init(self.allocator);
        defer state.deinit();
        var it = self.structs.iterator();
        while (it.next()) |e| {
            const sd = e.value_ptr.*;
            if (sd.is_reference) continue;
            if ((state.get(sd.name) orelse 0) == 0) self.dfsValueStructCycle(sd.name, &state);
        }
    }

    /// One depth-first visit of struct `name` in the value-cycle search.
    ///
    /// Marks `name` grey (1) on entry, recurses into each by-value struct field
    /// whose type is another non-reference struct, and marks it black (2) on
    /// exit. Encountering a grey child (`state == 1`) means the field closes a
    /// cycle back onto the current path, so it reports the error on that field's
    /// span. Reference-typed children and children whose name is a known
    /// collision are skipped (an edge through them cannot force infinite size, or
    /// is too ambiguous to trust). Called from [`checkValueStructCycles`].
    fn dfsValueStructCycle(self: *TypeChecker, name: []const u8, state: *std.StringHashMap(u8)) void {
        state.put(name, 1) catch return;
        const sd = self.structs.get(name) orelse {
            state.put(name, 2) catch {};
            return;
        };
        if (!sd.is_reference) {
            for (sd.fields) |fld| {
                const child = switch (fld.type_name) {
                    .ident => |n| n,
                    else => continue,
                };
                const cd = self.structs.get(child) orelse continue;
                if (cd.is_reference) continue;
                if (self.colliding_structs.contains(child)) continue;
                switch (state.get(child) orelse 0) {
                    1 => self.addError(fld.span, "value struct '{s}' contains itself by value through field '{s}: {s}', a `struct` stored inline cannot form a cycle (infinite size). Make one of the types a `class` (a heap reference), or hold it behind an optional or a container.", .{ name, fld.name, child }),
                    0 => self.dfsValueStructCycle(child, state),
                    else => {},
                }
            }
        }
        state.put(name, 2) catch {};
    }

    /// Type-checks a whole [`ast.Program`], the pass entry point.
    ///
    /// Runs in two phases. First it INDEXES every top-level declaration into the
    /// symbol tables (enums, structs, unions, traits, functions), detecting
    /// cross-file name collisions and same-file duplicate function definitions
    /// as it goes (Nova has no overloading, so a second definition of a name on
    /// a different line in the same module is an error; generated files such as
    /// `<serde-generated>` are exempt). Then it runs the value-struct cycle
    /// check and walks each function/struct/enum/const/trait body.
    ///
    /// Returns `error.TypeCheckError` if any diagnostic was recorded, after
    /// printing the summary unless [`silent`]. The two-phase order matters:
    /// bodies can reference declarations that appear later in the file, so all
    /// names must be indexed before any body is checked.
    pub fn check(self: *TypeChecker, program: ast.Program) !void {
        for (program.declarations) |decl| {
            if (decl == .enum_decl) {
                if (self.enums.get(decl.enum_decl.name)) |existing| {
                    if (!std.mem.eql(u8, existing.span.file, decl.enum_decl.span.file)) {
                        try self.colliding_enums.put(decl.enum_decl.name, {});
                    }
                }
                try self.enums.put(decl.enum_decl.name, decl.enum_decl);
            }
            if (decl == .struct_decl) {
                if (self.structs.get(decl.struct_decl.name)) |existing| {
                    if (!std.mem.eql(u8, existing.span.file, decl.struct_decl.span.file)) {
                        try self.colliding_structs.put(decl.struct_decl.name, {});
                    }
                }
                try self.structs.put(decl.struct_decl.name, decl.struct_decl);
            }
            if (decl == .union_decl) {
                try self.unions.put(decl.union_decl.name, decl.union_decl);
            }
            if (decl == .trait_decl) {
                try self.traits.put(decl.trait_decl.name, decl.trait_decl);
            }
            if (decl == .fn_decl) {
                if (self.functions.contains(decl.fn_decl.name)) {
                    try self.ambiguous_fns.put(decl.fn_decl.name, {});
                }
                try self.functions.put(decl.fn_decl.name, decl.fn_decl);

                const gen_file = std.mem.eql(u8, decl.fn_decl.span.file, "<serde-generated>") or
                    std.mem.eql(u8, decl.fn_decl.span.file, "helpers.nova") or
                    std.mem.eql(u8, decl.fn_decl.span.file, "test_harness.nova");
                const key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ decl.fn_decl.span.file, decl.fn_decl.name });
                if (self.fn_def_sites.contains(key)) {
                    if (self.fn_first_line.get(key)) |ln| {
                        if (!gen_file and ln != decl.fn_decl.span.line) {
                            self.addError(decl.fn_decl.span, "duplicate function '{s}', already defined at line {d} in this module (Nova has no overloading)", .{ decl.fn_decl.name, ln });
                        }
                    }
                    self.allocator.free(key);
                } else {
                    try self.fn_def_sites.put(key, {});
                    try self.fn_first_line.put(try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ decl.fn_decl.span.file, decl.fn_decl.name }), decl.fn_decl.span.line);
                }
            }
        }

        self.checkValueStructCycles();

        for (program.declarations) |decl| {
            switch (decl) {
                .fn_decl => |f| try self.checkFunction(f),
                .struct_decl => |s| try self.checkStruct(s),
                .enum_decl => |e| try self.checkEnum(e),
                .const_decl => |c| try self.checkConst(c),
                .trait_decl => |t| try self.checkTrait(t),
                else => {},
            }
        }

        if (self.errors.items.len > 0) {
            if (!self.silent) {
                std.debug.print("Type checking failed with {d} error(s):\n", .{self.errors.items.len});
                for (self.errors.items) |err| {
                    std.debug.print("  {s}\n", .{err});
                }
            }
            return error.TypeCheckError;
        }
    }

    /// Reports any type parameter name that appears twice in the same generic
    /// declaration (e.g. `fn f<T, T>()`), which would make `T` ambiguous.
    ///
    /// O(n^2) pairwise comparison, fine for the handful of type params a
    /// declaration ever has. `decl_name` and `span` are only used to phrase and
    /// locate the diagnostic.
    fn checkDuplicateTypeParams(self: *TypeChecker, decl_name: []const u8, type_params: []const []const u8, span: ast.Span) void {
        var i: usize = 0;
        while (i < type_params.len) : (i += 1) {
            var j: usize = i + 1;
            while (j < type_params.len) : (j += 1) {
                if (std.mem.eql(u8, type_params[i], type_params[j])) {
                    self.addError(span, "duplicate type parameter '{s}' in '{s}'", .{ type_params[i], decl_name });
                }
            }
        }
    }

    /// Flags an `if`/`while` condition that resolves to an obviously non-bool
    /// type, so `if (someString)` is rejected rather than silently coerced.
    ///
    /// Intentionally conservative: it only complains for a small set of types it
    /// is SURE about (`string`, `i32`, `f64`, `i64`). Any type it cannot resolve,
    /// or that is not in that set, is left alone to avoid false positives on the
    /// front-end's incomplete type inference.
    fn checkBoolCondition(self: *TypeChecker, cond: ast.Expression, span: ast.Span) void {
        const t = self.resolveExprType(cond) orelse return;
        if (t != .ident) return;
        const n = t.ident;

        if (std.mem.eql(u8, n, "string") or std.mem.eql(u8, n, "i32") or
            std.mem.eql(u8, n, "f64") or std.mem.eql(u8, n, "i64"))
        {
            self.addError(span, "condition must be a bool, got '{s}'", .{n});
        }
    }

    /// Conservative control-flow test: does executing `stmt` guarantee the
    /// function returns (or otherwise cannot fall through past it)?
    ///
    /// Drives the "non-void function might finish without returning" diagnostic
    /// in [`checkFunction`]. An `if` counts only when BOTH branches definitely
    /// return. Loops and `switch` are treated as definitely-returning here (a
    /// deliberate over-approximation: it assumes such a construct is used as the
    /// function's terminal, e.g. an infinite loop or an exhaustive switch, and
    /// prefers not to nag). `expr_stmt` is also treated as terminal to allow a
    /// trailing call that diverges. Compare [`blockDefinitelyReturns`].
    fn stmtDefinitelyReturns(self: *TypeChecker, stmt: ast.Statement) bool {
        return switch (stmt) {
            .return_stmt => true,
            .block => |b| self.blockDefinitelyReturns(b),
            .if_stmt => |ifs| blk: {
                const eb = ifs.else_branch orelse break :blk false;
                break :blk self.stmtDefinitelyReturns(ifs.then_branch.*) and self.stmtDefinitelyReturns(eb.*);
            },
            .while_stmt, .for_stmt, .switch_stmt => true,
            .expr_stmt => true,
            .let_stmt, .break_stmt, .continue_stmt, .defer_stmt => false,
        };
    }

    /// Whether block `b` definitely returns, i.e. its LAST statement does.
    ///
    /// Only the final statement is examined because anything earlier is not the
    /// fall-through point; an empty block never returns. Delegates to
    /// [`stmtDefinitelyReturns`].
    fn blockDefinitelyReturns(self: *TypeChecker, b: ast.Block) bool {
        if (b.statements.len == 0) return false;
        return self.stmtDefinitelyReturns(b.statements[b.statements.len - 1]);
    }

    /// Checks a single top-level function declaration end to end.
    ///
    /// Resets the per-body scratch state (`variables`, `closure_sigs`), binds
    /// each typed parameter into scope, and validates: duplicate type params,
    /// that parameter and return types exist ([`rejectUnimplementedType`]), that
    /// a non-void non-`extern` function returns on every path
    /// ([`blockDefinitelyReturns`]), and that an `async fn` is not compiled for
    /// wasm. It then sets `current_ret_type`/`in_async` (restored on exit via
    /// `defer`) so nested `return` and async-colouring checks see the right
    /// context, and walks the body.
    fn checkFunction(self: *TypeChecker, func: ast.FunctionDecl) anyerror!void {
        self.checkDuplicateTypeParams(func.name, func.type_params, func.span);
        self.variables.clearRetainingCapacity();
            self.closure_sigs.clearRetainingCapacity();

        for (func.params) |param| {
            if (param.type_name) |t| {
                self.rejectUnimplementedType(t, param.span, func.type_params, true);
                try self.variables.put(param.name, t);
            }
        }
        if (func.ret_type) |rt| self.rejectUnimplementedType(rt, func.span, func.type_params, true);

        if (func.extern_lib == null) {
            if (func.ret_type) |rt| {
                const is_voidish = rt == .ident and (std.mem.eql(u8, rt.ident, "void") or std.mem.eql(u8, rt.ident, "any"));
                if (!is_voidish and !self.blockDefinitelyReturns(func.body)) {
                    self.addError(func.span, "function '{s}' has return type '{s}' but can finish without returning a value, add a `return` on every path (or an ending loop/return)", .{ func.name, typeRefName(rt) });
                }
            }
        }

        if (self.is_wasm and func.is_async) {
            self.addError(func.span, "'async fn {s}' is not available on the wasm target, async has no coroutine runtime in wasm. Move it into a `@native {{ ... }}` block (and provide a synchronous or host-imported `@wasm {{ ... }}` alternative).", .{func.name});
        }
        const prev_ret = self.current_ret_type;
        self.current_ret_type = func.ret_type;
        defer self.current_ret_type = prev_ret;
        const prev_async = self.in_async;
        self.in_async = func.is_async;
        defer self.in_async = prev_async;
        try self.checkBlock(func.body);
    }

    /// Short display name of a type for use inside error messages.
    ///
    /// Returns the bare identifier for `.ident` types and the placeholder
    /// `"<type>"` for compound types (optional/generic/tuple/...), which is enough
    /// for the diagnostics that call it since they concern named types.
    fn typeRefName(t: ast.TypeRef) []const u8 {
        return switch (t) {
            .ident => |n| n,
            else => "<type>",
        };
    }

    /// Whether `name` denotes a type the compiler knows about in the current
    /// context: an in-scope type parameter, `Self`, a builtin primitive, or a
    /// declared struct/trait/enum/union.
    ///
    /// Checked against both the raw and [`canonicalizeTypeName`]-folded spelling
    /// so `int` and `i32` both resolve. Used by [`rejectUnimplementedType`] to
    /// flag references to types that do not exist.
    fn isKnownTypeName(self: *TypeChecker, name: []const u8, tparams: []const []const u8) bool {
        for (tparams) |tp| if (std.mem.eql(u8, name, tp)) return true;
        if (std.mem.eql(u8, name, "Self")) return true;
        const c = canonicalizeTypeName(name);
        const builtin_types = [_][]const u8{
            "i8", "i16", "i32", "i64", "i128", "f32", "f64", "bool", "string", "void",
            "any", "char", "ptr", "uptr", "usize", "isize", "never", "unit", "decimal", "byte",
            "future", "channel",
            "u8x16", "u32x4", "u64x2", "f64x4",
        };
        for (builtin_types) |b| if (std.mem.eql(u8, c, b) or std.mem.eql(u8, name, b)) return true;
        return self.structs.contains(name) or self.traits.contains(name) or self.enums.contains(name) or
            self.unions.contains(name) or self.structs.contains(c);
    }

    /// Recursively validates that every named type inside `t` exists, and
    /// rejects the types Nova has removed.
    ///
    /// Two rules fire: the 128-bit integer types `i128`/`u128` were removed in
    /// F3 §3.1 and always error; and, when `check_unknown_in` is set and the
    /// span is from a real source file (not a synthetic `<...>` file), any named
    /// type that is not known via [`isKnownTypeName`] errors. Descends through
    /// optionals, error unions, arrays, generic params, function types, and
    /// tuples so a bad type nested anywhere is caught. `check_unknown` is forced
    /// off for synthetic spans (whose file name begins with `<`) because
    /// generated code may legitimately mention types this pass has not indexed.
    fn rejectUnimplementedType(self: *TypeChecker, t: ast.TypeRef, span: ast.Span, tparams: []const []const u8, check_unknown_in: bool) void {
        const check_unknown = check_unknown_in and !(span.file.len > 0 and span.file[0] == '<');
        switch (t) {
            .ident => |n| {
                if (std.mem.eql(u8, n, "i128") or std.mem.eql(u8, n, "u128")) {
                    self.addError(span, "type '128-bit integer' was removed (F3 §3.1); use 'long' or 'i64'", .{});
                    return;
                }
                if (check_unknown and !self.isKnownTypeName(n, tparams)) {
                    self.addError(span, "unknown type '{s}', not a primitive, type parameter, or declared struct/enum/trait", .{n});
                }
            },
            .optional => |inner| self.rejectUnimplementedType(inner.*, span, tparams, check_unknown),
            .error_union => |eu| {
                self.rejectUnimplementedType(eu.ok.*, span, tparams, check_unknown);
                self.rejectUnimplementedType(eu.err.*, span, tparams, check_unknown);
            },
            .fixed_array => |fa| self.rejectUnimplementedType(fa.element.*, span, tparams, check_unknown),
            .generic => |g| {
                if (check_unknown and !self.isKnownTypeName(g.name, tparams)) {
                    self.addError(span, "unknown type '{s}', not a primitive, type parameter, or declared struct/enum/trait", .{g.name});
                }
                for (g.params) |p| self.rejectUnimplementedType(p, span, tparams, check_unknown);
            },
            .func => |f| {
                for (f.params) |p| self.rejectUnimplementedType(p, span, tparams, check_unknown);
                self.rejectUnimplementedType(f.ret.*, span, tparams, check_unknown);
            },
            .tuple => |items| for (items) |i| self.rejectUnimplementedType(i, span, tparams, check_unknown),
        }
    }

    /// Checks that `return <value>` is compatible with the enclosing function's
    /// declared return type ([`current_ret_type`]).
    ///
    /// Bails early in the cases it cannot or should not judge: `void`/`any`
    /// returns, single-character type names (a heuristic for erased generic type
    /// parameters like `T`), an integer literal returned into any numeric type,
    /// and anything whose value type it cannot resolve or that is not a simple
    /// ident. Otherwise it uses [`assignable`], which also enforces the F3
    /// narrowing/signedness rules, and reports a mismatch. Only the OK arm of an
    /// optional return type is compared (an optional target accepts its inner).
    fn checkReturnType(self: *TypeChecker, value: ast.Expression, span: ast.Span) void {
        const rt = self.current_ret_type orelse return;
        if (rt == .ident and (std.mem.eql(u8, rt.ident, "void") or std.mem.eql(u8, rt.ident, "any"))) return;

        const rt_core = if (rt == .optional) rt.optional.* else rt;
        if (rt_core == .ident and rt_core.ident.len == 1) return;

        if (intLiteralValue(value) != null) {
            if (rt_core != .ident) return;
            if (isNumericTypeName(rt_core.ident)) return;

        }
        const vt = self.resolveExprType(value) orelse return;

        if (vt != .ident) return;
        if (!self.assignable(vt, rt)) {
            self.addError(span, "return type mismatch: returning '{s}' from a function declared to return '{s}'", .{ typeRefName(vt), typeRefName(rt) });
        }
    }

    /// Whether the struct `struct_name` declares `impl trait_name`.
    ///
    /// Looks up the struct by its [`canonicalizeTypeName`]-folded name and scans
    /// its `impls`. Used both for generic-bound satisfaction
    /// ([`checkGenericBounds`]) and for accepting a struct where a trait type is
    /// expected ([`assignable`]). Returns `false` if the struct is unknown.
    fn structImplementsTrait(self: *TypeChecker, struct_name: []const u8, trait_name: []const u8) bool {
        const base = canonicalizeTypeName(struct_name);
        const s = self.structs.get(base) orelse return false;
        for (s.impls) |impl| {
            if (std.mem.eql(u8, impl.name, trait_name)) return true;
        }
        return false;
    }

    /// Verifies that each supplied `type_args` satisfies the `where`-clause
    /// trait bounds on a generic function/struct.
    ///
    /// For every bound `T: SomeTrait`, it finds `T`'s position among
    /// `type_params`, takes the matching concrete argument, and, if that
    /// argument is a declared (non-colliding) struct, checks it implements the
    /// trait via [`structImplementsTrait`]. Missing arguments, non-struct
    /// arguments, empty or unknown trait names, and colliding structs are all
    /// skipped rather than errored, keeping the check to cases it is sure about.
    fn checkGenericBounds(self: *TypeChecker, decl_name: []const u8, type_params: []const []const u8, where_bounds: []const ast.WhereBound, type_args: []const ast.TypeRef, span: ast.Span) void {
        for (where_bounds) |wb| {
            var idx: ?usize = null;
            for (type_params, 0..) |tp, i| {
                if (std.mem.eql(u8, tp, wb.type_param)) {
                    idx = i;
                    break;
                }
            }
            const ti = idx orelse continue;
            if (ti >= type_args.len) continue;
            const concrete = type_args[ti];
            const cname: []const u8 = switch (concrete) {
                .ident => |n| n,
                .generic => |g| g.name,
                else => continue,
            };
            const cbase = canonicalizeTypeName(cname);
            if (!self.structs.contains(cbase)) continue;
            if (self.colliding_structs.contains(cbase)) continue;
            for (wb.traits) |trait_name| {
                if (trait_name.len == 0) continue;
                if (!self.traits.contains(trait_name)) continue;
                if (!self.structImplementsTrait(cbase, trait_name)) {
                    self.addError(span, "type argument '{s}' does not satisfy the bound '{s}: {s}' on generic '{s}' (struct '{s}' does not implement trait '{s}')", .{ cname, wb.type_param, trait_name, decl_name, cname, trait_name });
                }
            }
        }
    }

    /// Checks that each argument's primitive CATEGORY matches its parameter's,
    /// so you cannot pass a `bool` where a number is wanted, or text where a
    /// bool is wanted, etc.
    ///
    /// Comparison is by [`primCategory`] (numeric / boolean / text / other), not
    /// exact type, so e.g. any numeric argument is accepted for a numeric
    /// parameter here (the finer narrowing/signedness rules live elsewhere).
    /// Parameters typed as anything other than a primitive ident (`.other`), and
    /// integer-literal arguments, are skipped. Only the first
    /// `min(args, params)` positions are checked. The error is anchored at the
    /// argument's span when available, else the whole call.
    fn checkArgTypes(self: *TypeChecker, args: []const ast.Expression, params: []const ast.Param, call_span: ast.Span) void {
        const n = @min(args.len, params.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const pt = params[i].type_name orelse continue;
            if (pt != .ident) continue;
            const pcat = primCategory(pt.ident);
            if (pcat == .other) continue;
            if (intLiteralValue(args[i]) != null) continue;
            const at = self.resolveExprType(args[i]) orelse continue;
            if (at != .ident) continue;
            const acat = primCategory(at.ident);
            if (acat == .other) continue;
            if (acat != pcat) {
                const sp = if (args[i].span.line != 0) args[i].span else call_span;
                self.addError(sp, "argument {d}: cannot pass '{s}' where parameter '{s}: {s}' expects '{s}'", .{ i + 1, typeRefName(at), params[i].name, typeRefName(pt), typeRefName(pt) });
            }
        }
    }

    /// Rejects passing a trait object where a concrete struct parameter is
    /// declared.
    ///
    /// A trait value may hold any implementation, so handing it to a parameter
    /// typed as one specific struct would be an unchecked downcast; Nova
    /// requires an explicit `as` instead. Fires only when the parameter type is
    /// a declared struct that is NOT itself a trait, the argument resolves to a
    /// trait type, and the two names differ. See [`rejectNarrowingArgsSubst`]
    /// for the variant that first substitutes generic type parameters.
    fn rejectNarrowingArgs(self: *TypeChecker, args: []const ast.Expression, params: []const ast.Param) void {
        const npairs = @min(args.len, params.len);
        var i: usize = 0;
        while (i < npairs) : (i += 1) {
            const pt = params[i].type_name orelse continue;
            if (pt != .ident) continue;
            if (!self.structs.contains(pt.ident) or self.traits.contains(pt.ident)) continue;
            const at = self.resolveExprType(args[i]) orelse continue;
            if (at != .ident) continue;
            if (self.traits.contains(at.ident) and !std.mem.eql(u8, at.ident, pt.ident)) {
                self.addError(args[i].span, "cannot pass a trait object '{s}' to concrete parameter '{s}: {s}', a trait value may hold any implementation, so narrowing it needs an explicit downcast ('<expr> as {s}'), or the parameter should take the trait type '{s}'", .{ at.ident, params[i].name, pt.ident, pt.ident, at.ident });
            }
        }
    }

    /// Like [`rejectNarrowingArgs`], but first substitutes the enclosing
    /// generic's type parameters into each parameter type.
    ///
    /// Used when checking a call on a generic receiver (e.g. a method on
    /// `List<T>` instantiated as `List<Widget>`): a parameter declared as the
    /// type variable `T` is replaced by its concrete binding `targs[k]` before
    /// the trait-object-to-concrete check, so the diagnostic reasons about the
    /// real element type rather than the erased `T`.
    fn rejectNarrowingArgsSubst(self: *TypeChecker, args: []const ast.Expression, params: []const ast.Param, tparams: []const []const u8, targs: []const ast.TypeRef) void {
        const npairs = @min(args.len, params.len);
        var i: usize = 0;
        while (i < npairs) : (i += 1) {
            var pt = params[i].type_name orelse continue;
            if (pt != .ident) continue;
            var k: usize = 0;
            while (k < tparams.len and k < targs.len) : (k += 1) {
                if (std.mem.eql(u8, tparams[k], pt.ident)) {
                    pt = targs[k];
                    break;
                }
            }
            if (pt != .ident) continue;
            if (!self.structs.contains(pt.ident) or self.traits.contains(pt.ident)) continue;
            const at = self.resolveExprType(args[i]) orelse continue;
            if (at != .ident) continue;
            if (self.traits.contains(at.ident) and !std.mem.eql(u8, at.ident, pt.ident)) {
                self.addError(args[i].span, "cannot pass a trait object '{s}' to a concrete element/parameter of type '{s}', a trait value may hold any implementation, so narrowing it needs an explicit downcast ('<expr> as {s}')", .{ at.ident, pt.ident, pt.ident });
            }
        }
    }

    /// Whether a value of type `from` may be stored/returned into a slot of type
    /// `to`, applying Nova's assignment rules.
    ///
    /// It first REJECTS the F3 numeric-safety violations (narrowing int,
    /// signedness flip), then accepts structural compatibility
    /// ([`isTypeCompatible`]), a struct assigned to a trait it implements (plain
    /// or generic trait target), and the two deliberate pointer conversions:
    /// any numeric into `ptr`, and `ptr` into `i64` (a full-width address round
    /// trip). Everything else is not assignable.
    fn assignable(self: *TypeChecker, from: ast.TypeRef, to: ast.TypeRef) bool {

        if (isNarrowingInt(from, to)) return false;
        if (isSignednessMismatch(from, to)) return false;
        if (isTypeCompatible(from, to)) return true;
        if (to == .ident and from == .ident and self.traits.contains(to.ident)) {
            if (self.structImplementsTrait(from.ident, to.ident)) return true;
        }

        if (to == .generic and self.traits.contains(to.generic.name)) {
            const from_name: ?[]const u8 = switch (from) {
                .ident => |n| n,
                .generic => |g| g.name,
                else => null,
            };
            if (from_name) |fnm| {
                if (self.structImplementsTrait(fnm, to.generic.name)) return true;
            }
        }

        if (from == .ident and to == .ident) {
            const cf = canonicalizeTypeName(from.ident);
            const ct = canonicalizeTypeName(to.ident);
            if (std.mem.eql(u8, ct, "ptr") and isNumericTypeName(cf)) return true;
            if (std.mem.eql(u8, cf, "ptr") and std.mem.eql(u8, ct, "i64")) return true;
        }
        return false;
    }

    /// Checks every statement in a block, in order.
    ///
    /// Note it does NOT open a new variable scope: bindings introduced inside
    /// the block persist in `variables` for the rest of the current function.
    /// This front-end pass models a single flat scope per body, which is
    /// adequate for its structural checks (the authoritative scoping lives in
    /// `sema/`).
    fn checkBlock(self: *TypeChecker, block: ast.Block) anyerror!void {
        for (block.statements) |stmt| {
            try self.checkStatement(stmt);
        }

    }

    /// Checks one statement and records the bindings it introduces.
    ///
    /// The heavy case is `let`: it validates the initialiser expression,
    /// supports tuple destructuring (binding each name to its element type and
    /// checking the arity matches), range-checks an integer literal against a
    /// declared small-int type, and enforces the F3 narrowing/signedness rules
    /// between the initialiser's type and the declared type (falling back to a
    /// generic "type mismatch" for other incompatibilities). It also records
    /// declared/inferred variable types into `variables` and closure signatures
    /// into `closure_sigs` so later statements can be checked. `if`/`while`
    /// additionally run [`checkBoolCondition`]; `return` runs
    /// [`checkReturnType`]. `for` only recurses into its body because the loop
    /// variable's element type is not modelled here.
    fn checkStatement(self: *TypeChecker, stmt: ast.Statement) anyerror!void {
        switch (stmt) {
            .block => |b| try self.checkBlock(b),
            .let_stmt => |ls| {
                if (ls.init) |init_walk| try self.checkExpr(init_walk);
                if (ls.names) |names| {
                    if (ls.init) |init_expr| {
                        if (self.resolveExprType(init_expr)) |it| {
                            if (it == .tuple) {
                                const arity = it.tuple.len;
                                if (names.len != arity) {
                                    self.addError(ls.span, "tuple destructuring binds {d} name(s) but the tuple has {d} element(s), the counts must match", .{ names.len, arity });
                                }
                                for (names, 0..) |nm, i| {
                                    if (i < arity) try self.variables.put(nm, it.tuple[i]);
                                }
                            }
                        }
                    }
                }
                if (ls.type_name) |t| {
                    self.rejectUnimplementedType(t, ls.span, &[_][]const u8{}, false);
                    try self.variables.put(ls.name, t);
                    if (ls.init) |init_expr| {

                        if (t == .ident) {
                            if (intTypeRange(t.ident)) |range| {
                                if (intLiteralValue(init_expr)) |v| {
                                    if (v < range.min or v > range.max) {
                                        self.addError(ls.span, "integer literal {d} is out of range for '{s}', use a wider type (e.g. 'long') or an explicit cast", .{ v, t.ident });
                                    }
                                }
                            }
                        }

                        const init_is_int_literal = intLiteralValue(init_expr) != null;
                        if (self.resolveExprType(init_expr)) |init_t| {

                            if (init_t == .ident and !init_is_int_literal and !self.assignable(init_t, t)) {
                                if (isNarrowingInt(init_t, t)) {
                                    self.addError(ls.span, "narrowing conversion: '{s}' cannot be implicitly stored into '{s}', use an explicit cast (F3 §6)", .{ typeRefName(init_t), typeRefName(t) });
                                } else if (isSignednessMismatch(init_t, t)) {
                                    self.addError(ls.span, "signedness mismatch: '{s}' and '{s}' differ in sign, use an explicit cast (F3 §6)", .{ typeRefName(init_t), typeRefName(t) });
                                } else {
                                    self.addError(ls.span, "Type mismatch: variable initialization expression is incompatible with declared type", .{});
                                }
                            }
                        }
                    }
                } else if (ls.init) |init_expr| {
                    if (self.resolveExprType(init_expr)) |t| {
                        try self.variables.put(ls.name, t);
                    }
                }
                if (ls.names == null) {
                    if (ls.init) |init_expr| {
                        if (init_expr.kind == .closure) {
                            try self.closure_sigs.put(ls.name, .{ .param_types = init_expr.kind.closure.param_types });
                        } else if (init_expr.kind == .ident) {
                            if (self.closure_sigs.get(init_expr.kind.ident)) |sig| {
                                try self.closure_sigs.put(ls.name, sig);
                            }
                        }
                    }
                }
            },
            .if_stmt => |is| {
                try self.checkExpr(is.condition);
                self.checkBoolCondition(is.condition, is.span);
                try self.checkStatement(is.then_branch.*);
                if (is.else_branch) |eb| {
                    try self.checkStatement(eb.*);
                }
            },
            .while_stmt => |ws| {
                try self.checkExpr(ws.condition);
                self.checkBoolCondition(ws.condition, ws.span);
                try self.checkStatement(ws.body.*);
            },
            .expr_stmt => |es| try self.checkExpr(es.expr),
            .return_stmt => |rs| {
                if (rs.value) |v| {
                    try self.checkExpr(v);
                    self.checkReturnType(v, rs.span);
                }
            },
            .for_stmt => |fs| {
                try self.checkStatement(fs.body.*);
            },
            .switch_stmt => |ss| {
                try self.checkSwitch(ss);
            },
.defer_stmt => |ds| {
                try self.checkExpr(ds.expr);
            },
            else => {},
        }
    }

    /// Number of parameters on struct `struct_name`'s `init` constructor, or
    /// `null` if the struct is unknown or defines no `init`.
    ///
    /// Lets constructor calls be arity-checked. Returns the RAW parameter count
    /// (including any leading `self`), matching how constructor calls are
    /// written. See [`structInitParams`] for the parameters themselves.
    fn structInitParamCount(self: *TypeChecker, struct_name: []const u8) ?usize {
        const s = self.structs.get(struct_name) orelse return null;
        for (s.methods) |m| {
            if (std.mem.eql(u8, m.decl.name, "init")) {
                return m.decl.params.len;
            }
        }
        return null;
    }

    /// The parameter list of struct `struct_name`'s `init` constructor, or
    /// `null` if there is none.
    ///
    /// Used to run [`checkArgTypes`] and [`rejectNarrowingArgs`] on constructor
    /// arguments. Complements [`structInitParamCount`].
    fn structInitParams(self: *TypeChecker, struct_name: []const u8) ?[]ast.Param {
        const s = self.structs.get(struct_name) orelse return null;
        for (s.methods) |m| {
            if (std.mem.eql(u8, m.decl.name, "init")) return m.decl.params;
        }
        return null;
    }

    /// Recursively checks an expression and everything nested inside it.
    ///
    /// This is the workhorse for expression-level diagnostics. By expression
    /// kind it enforces: async colouring (a bare call to an `async` target
    /// inside an `async fn` must be awaited/spawned), generic and constructor
    /// arity, generic `where`-bound satisfaction, ambiguous cross-module calls,
    /// argument category/narrowing/trait-object rules on functions, methods,
    /// constructors and closures, assignment narrowing/signedness/pointer/trait
    /// rules on `=`, the "array elements must be primitive" rule on array
    /// literals, `[]` indexability, struct-literal completeness and explicit
    /// type-argument matching, and wasm rejection of `await`/`spawn`.
    ///
    /// The `in_awaited` flag is saved and cleared around ordinary call operands
    /// but SET around the operands of `await`/`spawn`/`coroStart`, so an async
    /// call that is legitimately driven is not flagged. Any type it cannot
    /// resolve simply skips the corresponding check.
    fn checkExpr(self: *TypeChecker, expr: ast.Expression) anyerror!void {
        switch (expr.kind) {
            .generic_call => |gc| {
                const awaited_here = self.in_awaited;
                self.in_awaited = false;
                if (self.in_async and !awaited_here and self.callTargetsAsync(gc.callee.*)) {
                    self.addError(gc.span, "async call must be 'await'ed (or 'spawn'ed) inside an 'async fn', a bare call block-drives the coroutine and would deadlock the event loop", .{});
                }
                if (gc.callee.kind == .ident) {
                    const name = gc.callee.kind.ident;
                    var expected: ?usize = null;
                    if (self.structs.get(name)) |s| {
                        expected = s.type_params.len;
                    } else if (self.functions.get(name)) |f| {
                        expected = f.type_params.len;
                    }

                    if (expected) |exp| {
                        if (gc.type_args.len != exp) {
                            self.addError(gc.span, "generic '{s}' expects {d} type argument(s), got {d}", .{ name, exp, gc.type_args.len });
                        }
                    }

                    if (self.functions.get(name)) |f| {
                        if (f.where_bounds.len > 0 and gc.type_args.len == f.type_params.len) {
                            self.checkGenericBounds(name, f.type_params, f.where_bounds, gc.type_args, gc.span);
                        }
                    }

                    if (self.structs.contains(name) and !self.colliding_structs.contains(name)) {
                        if (self.structInitParamCount(name)) |init_params| {
                            if (gc.args.len != init_params) {
                                self.addError(gc.span, "constructor '{s}' expects {d} argument(s), got {d}", .{ name, init_params, gc.args.len });
                            }
                        }
                    }
                }
                try self.checkExpr(gc.callee.*);
                for (gc.args) |a| try self.checkExpr(a);
            },
            .call => |c| {

                const awaited_here = self.in_awaited;
                self.in_awaited = false;

                if (self.in_async and !awaited_here and self.callTargetsAsync(c.callee.*)) {
                    self.addError(c.span, "async call must be 'await'ed (or 'spawn'ed) inside an 'async fn', a bare call block-drives the coroutine and would deadlock the event loop", .{});
                }

                if (c.callee.kind == .ident) {
                    const name = c.callee.kind.ident;

                    if (!self.variables.contains(name) and self.structs.contains(name) and !self.colliding_structs.contains(name)) {
                        if (self.structInitParamCount(name)) |init_params| {
                            if (c.args.len != init_params) {
                                self.addError(c.span, "constructor '{s}' expects {d} argument(s), got {d}", .{ name, init_params, c.args.len });
                            }
                        }
                        if (self.structInitParams(name)) |ip| { self.rejectNarrowingArgs(c.args, ip); self.checkArgTypes(c.args, ip, c.span); }
                    }
                    if (!self.ambiguous_fns.contains(name) and !self.variables.contains(name)) {
                        if (self.functions.get(name)) |f| {
                            if (c.args.len != f.params.len) {
                                self.addError(c.span, "function '{s}' expects {d} argument(s), got {d}", .{ name, f.params.len, c.args.len });
                            }
                            self.rejectNarrowingArgs(c.args, f.params);
                            self.checkArgTypes(c.args, f.params, c.span);
                        }
                    }

                    if (self.closure_sigs.get(name)) |sig| {
                        if (c.args.len != sig.param_types.len) {
                            self.addError(c.span, "closure '{s}' expects {d} argument(s), got {d}", .{ name, sig.param_types.len, c.args.len });
                        } else if (sig.param_types.len > 0) {
                            const tmp = self.allocator.alloc(ast.Param, sig.param_types.len) catch null;
                            if (tmp) |params| {
                                defer self.allocator.free(params);
                                for (sig.param_types, 0..) |pt, i| {
                                    params[i] = .{ .name = "", .type_name = pt, .span = c.span };
                                }
                                self.checkArgTypes(c.args, params, c.span);
                                self.rejectNarrowingArgs(c.args, params);
                            }
                        }
                    }

                    if (self.ambiguous_fns.contains(name) and !self.variables.contains(name) and !self.structs.contains(name) and !self.fileDefinesFn(c.span.file, name)) {
                        self.addError(c.span, "call to '{s}' is ambiguous, more than one function is named '{s}' across the imported modules. Qualify it (e.g. `module.{s}(...)`).", .{ name, name, name });
                    }
                } else if (c.callee.kind == .field_access) {
                    const fa = c.callee.kind.field_access;
                    if (self.resolveExprType(fa.object.*)) |obj_type| {
                        if (obj_type == .ident) {
                            if (self.structs.get(obj_type.ident)) |s| {
                                for (s.methods) |m| {
                                    if (std.mem.eql(u8, m.decl.name, fa.field)) {
                                        var mparams = m.decl.params;
                                        if (mparams.len > 0 and std.mem.eql(u8, mparams[0].name, "self")) mparams = mparams[1..];
                                        self.rejectNarrowingArgs(c.args, mparams);

                                        self.checkArgTypes(c.args, mparams, c.span);
                                        break;
                                    }
                                }
                            }
                        } else if (obj_type == .generic) {
                            if (self.structs.get(obj_type.generic.name)) |s| {
                                for (s.methods) |m| {
                                    if (std.mem.eql(u8, m.decl.name, fa.field)) {
                                        var mparams = m.decl.params;
                                        if (mparams.len > 0 and std.mem.eql(u8, mparams[0].name, "self")) mparams = mparams[1..];
                                        self.rejectNarrowingArgsSubst(c.args, mparams, s.type_params, obj_type.generic.params);
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
                try self.checkExpr(c.callee.*);
                if (c.callee.kind == .ident and std.mem.eql(u8, c.callee.kind.ident, "coroStart")) {
                    const saved = self.in_awaited;
                    self.in_awaited = true;
                    for (c.args) |a| try self.checkExpr(a);
                    self.in_awaited = saved;
                } else {
                    for (c.args) |a| try self.checkExpr(a);
                }
            },
            .binary => |b| {
                try self.checkExpr(b.left.*);
                try self.checkExpr(b.right.*);

                if (b.op == .assign and intLiteralValue(b.right.*) == null) {
                    if (self.resolveExprType(b.right.*)) |rt| {
                        if (self.resolveExprType(b.left.*)) |lt| {
                            if (isPtrTruncation(rt, lt)) {
                                self.addError(b.span, "pointer truncation: a 'ptr' (raw address) cannot be stored into '{s}', type the target 'ptr' (F3 §3.2)", .{typeRefName(lt)});
                            } else if (isNarrowingInt(rt, lt)) {
                                self.addError(b.span, "narrowing conversion: '{s}' cannot be implicitly stored into '{s}', use an explicit cast (F3 §6)", .{ typeRefName(rt), typeRefName(lt) });
                            } else if (isSignednessMismatch(rt, lt)) {
                                self.addError(b.span, "signedness mismatch: '{s}' and '{s}' differ in sign, use an explicit cast (F3 §6)", .{ typeRefName(rt), typeRefName(lt) });
                            } else if (rt == .ident and lt == .ident and
                                self.traits.contains(rt.ident) and self.structs.contains(lt.ident) and
                                !self.traits.contains(lt.ident) and !std.mem.eql(u8, rt.ident, lt.ident))
                            {
                                self.addError(b.span, "cannot assign a trait object '{s}' to a concrete '{s}' target, a trait value may hold any implementation, so narrowing it needs an explicit downcast ('<expr> as {s}')", .{ rt.ident, lt.ident, lt.ident });
                            }
                        }
                    }
                }
            },
            .literal => |lit| {
                if (lit == .array) {
                    for (lit.array) |*elem| {
                        try self.checkExpr(elem.*);
                        if (self.resolveExprType(elem.*)) |et| {
                            if (et != .ident or !isScalarPrim(et.ident)) {
                                self.addError(expr.span, "array elements must be a primitive type (int, long, double, float, bool, byte); got '{s}', use List for reference or complex element types", .{typeRefName(et)});
                                break;
                            }
                        } else if (elem.kind == .struct_init or elem.kind == .tuple or
                            (elem.kind == .literal and elem.kind.literal == .array))
                        {
                            self.addError(expr.span, "array elements must be a primitive type (int, long, double, float, bool, byte); a struct, tuple, or nested array is not allowed, use List for those", .{});
                            break;
                        }
                    }
                } else if (lit == .array_repeat) {
                    try self.checkExpr(lit.array_repeat.value.*);
                    const v = lit.array_repeat.value.*;
                    if (self.resolveExprType(v)) |et| {
                        if (et != .ident or !isScalarPrim(et.ident)) {
                            self.addError(expr.span, "array elements must be a primitive type (int, long, double, float, bool, byte); got '{s}', use List for reference or complex element types", .{typeRefName(et)});
                        }
                    } else if (v.kind == .struct_init or v.kind == .tuple or (v.kind == .literal and v.kind.literal == .array)) {
                        self.addError(expr.span, "array elements must be a primitive type (int, long, double, float, bool, byte); a struct, tuple, or nested array is not allowed, use List for those", .{});
                    }
                }
            },
            .unary => |u| try self.checkExpr(u.operand.*),
            .field_access => |fa| try self.checkExpr(fa.object.*),
            .index => |idx| {
                try self.checkExpr(idx.object.*);
                try self.checkExpr(idx.index.*);
                if (self.resolveExprType(idx.object.*)) |obj_ty| {
                    if (self.indexableTypeStatus(obj_ty)) |ok| {
                        if (!ok) self.addError(idx.object.*.span, "cannot index a value of type '{s}' with `[]`, `[]` is only valid on strings, arrays, tuples, and byte buffers (List/Map use `.get`)", .{typeRefName(obj_ty)});
                    }
                }
            },
            .struct_init => |si| {
                for (si.fields) |field| try self.checkExpr(field.value);

                // A `..from(expr)` spread fills every target field not named
                // explicitly, by convention, from a same-named field of the
                // source struct. Resolve the source struct so the missing-field
                // check below treats convention-covered fields as satisfied.
                var spread_src: ?[]const u8 = null;
                if (si.spread) |sp| {
                    try self.checkExpr(sp.*);
                    if (self.resolveExprType(sp.*)) |src_ty| spread_src = identOf(src_ty);
                }

                if (self.structs.get(si.type_name)) |s| {
                    for (s.fields) |df| {
                        var found = false;
                        for (si.fields) |lf| {
                            if (std.mem.eql(u8, lf.name, df.name)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            if (spread_src) |sn| {
                                if (self.structs.get(sn)) |ss| {
                                    for (ss.fields) |sf| {
                                        if (fieldConvEq(df.name, sf.name)) {
                                            found = true;
                                            break;
                                        }
                                    }
                                }
                            }
                        }
                        if (!found) {
                            if (self.structInitParamCount(si.type_name) != null) {
                                self.addError(si.span, "struct literal '{s}{{ ... }}' is missing field '{s}', initialize every field, or use the constructor '{s}(...)'", .{ si.type_name, df.name, si.type_name });
                            } else {
                                self.addError(si.span, "struct literal '{s}{{ ... }}' is missing field '{s}', every field must be initialized (fields have no defaults)", .{ si.type_name, df.name });
                            }
                        }
                    }

                    if (si.type_args.len > 0) {
                        if (s.type_params.len != si.type_args.len) {
                            self.addError(si.span, "'{s}' takes {d} type argument(s), but {d} were given", .{ si.type_name, s.type_params.len, si.type_args.len });
                        } else {
                            for (si.fields) |lf| {
                                for (s.fields) |df| {
                                    if (!std.mem.eql(u8, df.name, lf.name)) continue;
                                    const pname = identOf(df.type_name) orelse break;
                                    var bound: ?ast.TypeRef = null;
                                    for (s.type_params, 0..) |tp, i| {
                                        if (std.mem.eql(u8, tp, pname)) {
                                            bound = si.type_args[i];
                                            break;
                                        }
                                    }
                                    const b = bound orelse break;
                                    const actual = self.resolveExprType(lf.value) orelse break;
                                    if (stringScalarClash(b, actual)) {
                                        self.addError(lf.span, "type argument mismatch: field '{s}' has type '{s}' (from explicit '{s}<...>'), but the value is '{s}'", .{ lf.name, identOf(b) orelse "?", si.type_name, identOf(actual) orelse "?" });
                                    }
                                    break;
                                }
                            }
                        }
                    }
                }
            },
            .tuple => |elems| {
                for (elems) |e| try self.checkExpr(e);
            },
            .if_expr => |ie| {
                try self.checkExpr(ie.condition.*);
                try self.checkExpr(ie.then_branch.*);
                try self.checkExpr(ie.else_branch.*);
            },
            .template_expr => |te| {
                for (te.parts) |p| try self.checkExpr(p);
            },
            .block_expr => |be| try self.checkBlock(be),
            .await_expr => |aw| {
                if (self.is_wasm) {
                    self.addError(aw.span, "'await' is not available on the wasm target, async/await has no coroutine runtime in wasm. Guard native code with `@native {{ ... }}` and provide a wasm path with `@wasm {{ ... }}`.", .{});
                }

                if (!self.in_async) {
                    self.addError(aw.span, "'await' is only allowed inside an 'async fn'", .{});
                }
                const saved = self.in_awaited;
                self.in_awaited = true;
                try self.checkExpr(aw.operand.*);
                self.in_awaited = saved;
            },
            .go_expr => |g| {
                if (self.is_wasm) {
                    self.addError(g.span, "'spawn' is not available on the wasm target, there is no coroutine runtime in wasm. Guard native code with `@native {{ ... }}`.", .{});
                }

                if (!self.in_async) {
                    self.addError(g.span, "'spawn' is only allowed inside an 'async fn'", .{});
                }
                const saved = self.in_awaited;
                self.in_awaited = true;
                try self.checkExpr(g.operand.*);
                self.in_awaited = saved;
            },
            else => {},
        }
    }

    /// Whether `name` is an integer-like type that a `switch` may discriminate
    /// on directly (all int widths, plus `bool` and `char`).
    ///
    /// Matched by exact spelling. Used by [`checkSwitch`] to decide, when the
    /// discriminant is not an enum, whether the `switch` is nonetheless valid
    /// or should be reported as switching on an unsupported type (strings, for
    /// instance, must use if/else chains).
    fn isSwitchableIntType(name: []const u8) bool {
        const ints = [_][]const u8{
            "int",   "uint",  "long",  "ulong", "short", "ushort", "byte", "ubyte", "sbyte",
            "i8",    "i16",   "i32",   "i64",   "u8",    "u16",    "u32",  "u64",   "bool",
            "char",
        };
        for (ints) |i| {
            if (std.mem.eql(u8, name, i)) return true;
        }
        return false;
    }

    /// Best-effort recovery of the enum being switched on by inspecting the case
    /// patterns, for when the discriminant expression's type could not be
    /// resolved.
    ///
    /// Scans each case value for a `Enum.Variant` field access or a
    /// `Enum.Variant(...)` call whose object is an ident that names a known,
    /// non-colliding enum, and returns that enum name. Lets [`checkSwitch`]
    /// still perform exhaustiveness checking ([`checkEnumCoverageOnly`]) even
    /// when discriminant inference failed. Returns `null` if no case reveals an
    /// enum.
    fn recoverEnumFromCases(self: *TypeChecker, cases: []const ast.SwitchCase) ?[]const u8 {
        for (cases) |case| {
            for (case.values) |val| {
                const obj_name: ?[]const u8 = switch (val.kind) {
                    .field_access => |fa| if (fa.object.kind == .ident) fa.object.kind.ident else null,
                    .call => |c| if (c.callee.kind == .field_access and c.callee.kind.field_access.object.kind == .ident) c.callee.kind.field_access.object.kind.ident else null,
                    else => null,
                };
                if (obj_name) |on| {
                    if (self.enums.contains(on) and !self.colliding_enums.contains(on)) return on;
                }
            }
        }
        return null;
    }

    /// Exhaustiveness-only check for a `switch` over `enum_name`, used on the
    /// recovery path where the payload bindings do not need establishing.
    ///
    /// Marks each variant covered by an unguarded case (a guarded case may not
    /// fire, so it does not count towards coverage) and reports every variant
    /// left unhandled. Returns immediately if the switch has a default case
    /// (which covers the remainder). Compare the fuller [`checkSwitch`], which
    /// also binds payload variables into scope.
    fn checkEnumCoverageOnly(self: *TypeChecker, enum_name: []const u8, ss: ast.SwitchStmt) anyerror!void {
        const enum_decl = self.enums.get(enum_name) orelse return;
        if (ss.default_case != null) return;
        var covered = std.StringHashMap(bool).init(self.allocator);
        defer covered.deinit();
        for (enum_decl.variants) |v| try covered.put(v.name, false);
        for (ss.cases) |case| {
            if (case.guard != null) continue;
            for (case.values) |val| {
                const fname: ?[]const u8 = switch (val.kind) {
                    .field_access => |fa| if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, enum_name)) fa.field else null,
                    .call => |c| if (c.callee.kind == .field_access and c.callee.kind.field_access.object.kind == .ident and std.mem.eql(u8, c.callee.kind.field_access.object.kind.ident, enum_name)) c.callee.kind.field_access.field else null,
                    .struct_init => |si| si.type_name,
                    else => null,
                };
                if (fname) |f| try covered.put(f, true);
            }
        }
        var it = covered.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.*) {
                self.addError(ss.span, "Enum variant '{s}.{s}' not handled in switch statement", .{ enum_name, entry.key_ptr.* });
            }
        }
    }

    /// Checks a `switch` statement: enum exhaustiveness, payload binding, and
    /// discriminant validity.
    ///
    /// If the discriminant resolves to an enum, it walks every case, marking
    /// unguarded matches as covering their variant AND binding any payload
    /// (tuple-style `Variant(x)` or struct-style `Variant{ field }`) into
    /// `variables` so the case body type-checks, then reports any uncovered
    /// variant when there is no default. If the discriminant resolves to a
    /// non-enum ident that is not a [`isSwitchableIntType`], it reports an
    /// invalid discriminant. If the discriminant type cannot be resolved at all,
    /// it falls back to [`recoverEnumFromCases`] + [`checkEnumCoverageOnly`].
    fn checkSwitch(self: *TypeChecker, ss: ast.SwitchStmt) anyerror!void {
        const disc_type = self.resolveExprType(ss.discriminant) orelse {
            if (self.recoverEnumFromCases(ss.cases)) |en| try self.checkEnumCoverageOnly(en, ss);
            return;
        };

        switch (disc_type) {
            .ident => |enum_name| {
                if (self.colliding_enums.contains(enum_name)) return;
                if (self.enums.get(enum_name)) |enum_decl| {
                    const variants = enum_decl.variants;
                    var covered = std.StringHashMap(bool).init(self.allocator);
                    defer covered.deinit();

                    for (variants) |v| {
                        try covered.put(v.name, false);
                    }

                    for (ss.cases) |case| {
                        const covers = case.guard == null;
                        for (case.values) |val| {
                            if (val.kind == .field_access) {
                                const fa = val.kind.field_access;
                                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, enum_name)) {
                                    if (covers) try covered.put(fa.field, true);
                                }
                            } else if (val.kind == .call) {
                                const call = val.kind.call;
                                if (call.callee.kind == .field_access) {
                                    const fa = call.callee.kind.field_access;
                                    if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, enum_name)) {
                                        if (covers) try covered.put(fa.field, true);
                                        for (variants) |v| {
                                            if (std.mem.eql(u8, v.name, fa.field)) {
                                                if (v.type_name) |payload_type| {
                                                    if (call.args.len > 0 and call.args[0].kind == .ident) {
                                                        const arg_name = call.args[0].kind.ident;
                                                        try self.variables.put(arg_name, payload_type);
                                                    }
                                                } else if (v.fields) |payload_fields| {
                                                    for (call.args, 0..) |arg, i| {
                                                        if (i < payload_fields.len and arg.kind == .ident) {
                                                            try self.variables.put(arg.kind.ident, payload_fields[i].type_name);
                                                        }
                                                    }
                                                }
                                                break;
                                            }
                                        }
                                    }
                                }
                            } else if (val.kind == .struct_init) {
                                const si = val.kind.struct_init;
                                if (covers) try covered.put(si.type_name, true);
                                for (variants) |v| {
                                    if (std.mem.eql(u8, v.name, si.type_name)) {
                                        if (v.fields) |payload_fields| {
                                            for (si.fields) |f_init| {
                                                for (payload_fields) |pf| {
                                                    if (std.mem.eql(u8, f_init.name, pf.name)) {
                                                        if (f_init.value.kind == .ident) {
                                                            try self.variables.put(f_init.value.kind.ident, pf.type_name);
                                                        }
                                                        break;
                                                    }
                                                }
                                            }
                                        }
                                        break;
                                    }
                                }
                            }
                        }
                        if (case.guard) |g| try self.checkExpr(g);
                    }

                    var unhandled = std.ArrayList([]const u8).empty;
                    defer unhandled.deinit(self.allocator);

                    var it = covered.iterator();
                    while (it.next()) |entry| {
                        if (!entry.value_ptr.*) {
                            try unhandled.append(self.allocator, entry.key_ptr.*);
                        }
                    }

                    if (unhandled.items.len > 0 and ss.default_case == null) {
                        for (unhandled.items) |name| {
                            self.addError(ss.span, "Enum variant '{s}.{s}' not handled in switch statement", .{ enum_name, name });
                        }
                    }
                } else if (!isSwitchableIntType(enum_name)) {
                    self.addError(ss.span, "switch discriminant must be an enum or integer type, got '{s}', use if/else chains for strings and other types", .{enum_name});
                }
            },
            else => {},
        }
    }

    /// Substitutes concrete type arguments for a generic function's type
    /// parameters throughout a type, used to specialise an inferred return type.
    ///
    /// Recurses through every compound type form (optional, error union,
    /// generic, tuple, fixed array, function) rebuilding nodes with the
    /// allocator, and replaces a bare `.ident` that matches a `tparams[i]` with
    /// `targs[i]`. On any allocation failure it returns the original (un-subbed)
    /// node, which is a safe conservative fallback for this best-effort pass.
    /// The allocated substitution nodes are not individually freed (the checker's
    /// arena outlives them). Compare [`unifyTypeParam`], which goes the other
    /// way (inferring the bindings from actual argument types).
    fn substReturnType(self: *TypeChecker, tr: ast.TypeRef, tparams: []const []const u8, targs: []const ast.TypeRef) ast.TypeRef {
        switch (tr) {
            .ident => |name| {
                for (tparams, 0..) |tp, i| {
                    if (i < targs.len and std.mem.eql(u8, tp, name)) return targs[i];
                }
                return tr;
            },
            .optional => |inner| {
                const p = self.allocator.create(ast.TypeRef) catch return tr;
                p.* = self.substReturnType(inner.*, tparams, targs);
                return ast.TypeRef{ .optional = p };
            },
            .error_union => |eu| {
                const ok = self.allocator.create(ast.TypeRef) catch return tr;
                const err = self.allocator.create(ast.TypeRef) catch return tr;
                ok.* = self.substReturnType(eu.ok.*, tparams, targs);
                err.* = self.substReturnType(eu.err.*, tparams, targs);
                return ast.TypeRef{ .error_union = .{ .ok = ok, .err = err } };
            },
            .generic => |g| {
                const new_params = self.allocator.alloc(ast.TypeRef, g.params.len) catch return tr;
                for (g.params, 0..) |pp, i| new_params[i] = self.substReturnType(pp, tparams, targs);
                return ast.TypeRef{ .generic = .{ .name = g.name, .params = new_params } };
            },
            .tuple => |elems| {
                const new_elems = self.allocator.alloc(ast.TypeRef, elems.len) catch return tr;
                for (elems, 0..) |e, i| new_elems[i] = self.substReturnType(e, tparams, targs);
                return ast.TypeRef{ .tuple = new_elems };
            },
            .fixed_array => |fa| {
                const el = self.allocator.create(ast.TypeRef) catch return tr;
                el.* = self.substReturnType(fa.element.*, tparams, targs);
                return ast.TypeRef{ .fixed_array = .{ .element = el, .length = fa.length } };
            },
            .func => |f| {
                const ret = self.allocator.create(ast.TypeRef) catch return tr;
                ret.* = self.substReturnType(f.ret.*, tparams, targs);
                const new_params = self.allocator.alloc(ast.TypeRef, f.params.len) catch return tr;
                for (f.params, 0..) |pp, i| new_params[i] = self.substReturnType(pp, tparams, targs);
                return ast.TypeRef{ .func = .{ .params = new_params, .ret = ret } };
            },
        }
    }

    fn methodIsTraitContract(self: *TypeChecker, s: ast.StructDecl, method_name: []const u8) bool {
        for (s.impls) |impl| {
            const td = self.traits.get(impl.name) orelse continue;
            for (td.methods) |tm| {
                if (std.mem.eql(u8, tm.name, method_name)) return true;
            }
        }
        return false;
    }

    fn callTargetsAsync(self: *TypeChecker, callee: ast.Expression) bool {
        switch (callee.kind) {
            .ident => |name| {

                if (self.variables.contains(name)) return false;
                if (self.functions.get(name)) |f| return f.is_async;
                return false;
            },
            .field_access => |fa| {

                if (fa.object.kind == .ident) {
                    if (builtins.find(fa.object.kind.ident, fa.field) != null) return false;
                }
                const obj_type = self.resolveExprType(fa.object.*) orelse return false;
                const tname: []const u8 = switch (obj_type) {
                    .ident => |n| n,
                    .generic => |g| g.name,
                    else => return false,
                };
                if (self.structs.get(tname)) |s| {
                    for (s.methods) |m| {
                        if (std.mem.eql(u8, m.decl.name, fa.field)) return m.decl.is_async;
                    }
                } else if (self.traits.get(tname)) |t| {
                    for (t.methods) |tm| {
                        if (std.mem.eql(u8, tm.name, fa.field)) return tm.is_async;
                    }
                } else if (self.enums.get(tname)) |e| {
                    for (e.methods) |m| {
                        if (std.mem.eql(u8, m.decl.name, fa.field)) return m.decl.is_async;
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    fn unifyTypeParam(self: *TypeChecker, decl: ast.TypeRef, actual: ast.TypeRef, tparams: []const []const u8, binds: []?ast.TypeRef) void {
        switch (decl) {
            .ident => |nm| {
                for (tparams, 0..) |tp, i| {
                    if (std.mem.eql(u8, tp, nm)) {
                        if (binds[i] == null) binds[i] = actual;
                        return;
                    }
                }
            },
            .optional => |inner| {
                if (actual == .optional) self.unifyTypeParam(inner.*, actual.optional.*, tparams, binds);
            },
            .generic => |g| {
                if (actual == .generic and g.params.len == actual.generic.params.len) {
                    for (g.params, 0..) |p, i| self.unifyTypeParam(p, actual.generic.params[i], tparams, binds);
                }
            },
            else => {},
        }
    }

    fn inferGenericTypeArgs(self: *TypeChecker, f: ast.FunctionDecl, args: []const ast.Expression) ?[]ast.TypeRef {
        if (f.type_params.len == 0) return null;
        const binds = self.allocator.alloc(?ast.TypeRef, f.type_params.len) catch return null;
        for (binds) |*b| b.* = null;
        const n = @min(f.params.len, args.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const decl = f.params[i].type_name orelse continue;
            const actual = self.resolveExprType(args[i]) orelse continue;
            self.unifyTypeParam(decl, actual, f.type_params, binds);
        }
        const out = self.allocator.alloc(ast.TypeRef, f.type_params.len) catch return null;
        for (binds, 0..) |b, k| out[k] = b orelse return null;
        return out;
    }

    fn indexableTypeStatus(self: *TypeChecker, tr: ast.TypeRef) ?bool {
        return switch (tr) {
            .fixed_array, .tuple => true,
            .ident => |name| blk: {
                const n = canonicalizeTypeName(name);
                if (std.mem.eql(u8, n, "string") or std.mem.eql(u8, n, "ptr") or
                    std.mem.eql(u8, n, "bytes") or std.mem.eql(u8, n, "RawBuffer")) break :blk true;
                if (isScalarPrimitiveName(n)) break :blk false;
                if (self.structs.contains(name) or self.enums.contains(name)) break :blk false;
                break :blk null;
            },
            else => null,
        };
    }

    fn memberAccessible(self: *TypeChecker, decl_file: []const u8, access_file: []const u8, type_name: []const u8) bool {
        if (std.mem.eql(u8, decl_file, access_file)) return true;
        if (self.current_struct) |curr| {
            if (std.mem.eql(u8, curr, type_name)) return true;
        }
        return false;
    }

    fn resolveExprType(self: *TypeChecker, expr: ast.Expression) ?ast.TypeRef {
        switch (expr.kind) {
            .ident => |name| {
                return self.variables.get(name);
            },
            .struct_init => |si| return ast.TypeRef{ .ident = si.type_name },
            .enum_init => |ei| return ast.TypeRef{ .ident = ei.enum_name },
            .cast => |c| {
                return c.target_type;
            },
            .await_expr => |aw| {

                return self.resolveExprType(aw.operand.*);
            },
            .go_expr => |g| {

                return self.resolveExprType(g.operand.*);
            },
            .binary => |bin| {
                if (bin.op == .assign) {
                    return self.resolveExprType(bin.left.*);
                }

                if (bin.op == .add) {
                    var is_str = false;
                    if (self.resolveExprType(bin.left.*)) |lt| {
                        if (lt == .ident and std.mem.eql(u8, lt.ident, "string")) is_str = true;
                    }
                    if (self.resolveExprType(bin.right.*)) |rtt| {
                        if (rtt == .ident and std.mem.eql(u8, rtt.ident, "string")) is_str = true;
                    }
                    if (is_str) return ast.TypeRef{ .ident = "string" };
                }

                switch (bin.op) {
                    .add, .sub, .mul, .div, .mod => {
                        const ld = self.resolveExprType(bin.left.*);
                        const rd = self.resolveExprType(bin.right.*);
                        const l_dec = ld != null and ld.? == .ident and std.mem.eql(u8, ld.?.ident, "decimal");
                        const r_dec = rd != null and rd.? == .ident and std.mem.eql(u8, rd.?.ident, "decimal");
                        if (l_dec or r_dec) return ast.TypeRef{ .ident = "decimal" };
                    },
                    else => {},
                }

                if (bin.op == .add or bin.op == .sub) {
                    const lp = self.resolveExprType(bin.left.*);
                    const rp = self.resolveExprType(bin.right.*);
                    const l_is_ptr = lp != null and lp.? == .ident and std.mem.eql(u8, canonicalizeTypeName(lp.?.ident), "ptr");
                    const r_is_ptr = rp != null and rp.? == .ident and std.mem.eql(u8, canonicalizeTypeName(rp.?.ident), "ptr");
                    if (l_is_ptr or r_is_ptr) return ast.TypeRef{ .ident = "ptr" };
                }
                if (bin.op == .add) {
                    return ast.TypeRef{ .ident = "i32" };
                }

                return switch (bin.op) {
                    .eq, .ne, .lt, .gt, .le, .ge, .And, .Or => ast.TypeRef{ .ident = "bool" },
                    else => ast.TypeRef{ .ident = "i32" },
                };
            },
            .literal => |lit| {
                return switch (lit) {
                    .integer => ast.TypeRef{ .ident = "i32" },
                    .float => ast.TypeRef{ .ident = "f64" },

                    .decimal => ast.TypeRef{ .ident = "decimal" },
                    .bool => ast.TypeRef{ .ident = "bool" },
                    .string => ast.TypeRef{ .ident = "string" },
                    else => null,
                };
            },
            .field_access => |fa| {
                const obj_type = self.resolveExprType(fa.object.*) orelse return null;
                switch (obj_type) {
                    .ident => |struct_name| {
                        if (self.structs.get(struct_name)) |s| {
                            for (s.fields) |field| {
                                if (std.mem.eql(u8, field.name, fa.field)) {
                                    if (!field.is_public and !self.memberAccessible(s.span.file, fa.span.file, struct_name)) {
                                        self.addError(fa.span, "Field '{s}' of struct '{s}' is private, it is accessible only within its own module (add `pub` to use it across modules)", .{ fa.field, struct_name });
                                    }
                                    return field.type_name;
                                }
                            }
                        } else if (self.unions.get(struct_name)) |u| {
                            for (u.fields) |field| {
                                if (std.mem.eql(u8, field.name, fa.field)) {
                                    if (!field.is_public and !self.memberAccessible(u.span.file, fa.span.file, struct_name)) {
                                        self.addError(fa.span, "Field '{s}' of union '{s}' is private, it is accessible only within its own module (add `pub` to use it across modules)", .{ fa.field, struct_name });
                                    }
                                    return field.type_name;
                                }
                            }
                        }
                    },
                    else => {},
                }
                return null;
            },
            .call => |call| {
                if (call.callee.kind == .field_access) {
                    const fa = call.callee.kind.field_access;

                    if (fa.object.kind == .ident) {
                        if (builtins.find(fa.object.kind.ident, fa.field)) |b| {
                            return builtinRetType(b.ret);
                        }
                    }
                    const obj_type = self.resolveExprType(fa.object.*) orelse {
                        if (self.structs.contains(fa.field)) return ast.TypeRef{ .ident = fa.field };
                        return null;
                    };
                    switch (obj_type) {
                        .ident => |struct_name| {
                            if (self.structs.get(struct_name)) |s| {
                                for (s.methods) |m| {
                                    if (std.mem.eql(u8, m.decl.name, fa.field)) {
                                        if (!m.is_public and !self.memberAccessible(s.span.file, fa.span.file, struct_name) and !self.methodIsTraitContract(s, fa.field)) {
                                            self.addError(fa.span, "Method '{s}' of struct '{s}' is private, it is accessible only within its own module (add `pub` to use it across modules)", .{ fa.field, struct_name });
                                        }
                                        return m.decl.ret_type orelse ast.TypeRef{ .ident = "void" };
                                    }
                                }
                            } else if (self.enums.get(struct_name)) |e| {
                                for (e.methods) |m| {
                                    if (std.mem.eql(u8, m.decl.name, fa.field)) {
                                        if (!m.is_public and !self.memberAccessible(e.span.file, fa.span.file, struct_name)) {
                                            self.addError(fa.span, "Method '{s}' of enum '{s}' is private, it is accessible only within its own module (add `pub` to use it across modules)", .{ fa.field, struct_name });
                                        }
                                        return m.decl.ret_type orelse ast.TypeRef{ .ident = "void" };
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                }

                if (call.callee.kind == .ident) {
                    const name = call.callee.kind.ident;
                    if (self.functions.get(name)) |f| {
                        const rt = f.ret_type orelse return ast.TypeRef{ .ident = "void" };
                        if (f.type_params.len > 0) {
                            if (self.inferGenericTypeArgs(f, call.args)) |targs| {
                                return self.substReturnType(rt, f.type_params, targs);
                            }
                        }
                        return rt;
                    }
                    if (self.structs.contains(name)) {
                        return ast.TypeRef{ .ident = name };
                    }
                }
                return null;
            },
            .generic_call => |gc| {

                if (gc.callee.kind == .ident) {
                    const name = gc.callee.kind.ident;
                    if (self.structs.contains(name)) {
                        if (gc.type_args.len > 0) {
                            return ast.TypeRef{ .generic = .{ .name = name, .params = gc.type_args } };
                        }
                        return ast.TypeRef{ .ident = name };
                    }
                    if (self.functions.get(name)) |f| {
                        const rt = f.ret_type orelse return ast.TypeRef{ .ident = "void" };

                        return self.substReturnType(rt, f.type_params, gc.type_args);
                    }
                } else if (gc.callee.kind == .field_access) {
                    const fname = gc.callee.kind.field_access.field;
                    if (self.structs.contains(fname)) {
                        if (gc.type_args.len > 0) {
                            return ast.TypeRef{ .generic = .{ .name = fname, .params = gc.type_args } };
                        }
                        return ast.TypeRef{ .ident = fname };
                    }
                }
                return null;
            },
            .if_expr => |ie| {
                return self.resolveExprType(ie.then_branch.*);
            },
            .jsx_element => {
                return ast.TypeRef{ .ident = "string" };
            },
            .block_expr => {
                return ast.TypeRef{ .ident = "string" };
            },
            .template_expr => {
                return ast.TypeRef{ .ident = "string" };
            },
            .unary => |un| {
                return switch (un.op) {
                    .not => ast.TypeRef{ .ident = "bool" },
                    .neg, .bit_not => self.resolveExprType(un.operand.*) orelse ast.TypeRef{ .ident = "i32" },
                };
            },
            .index => |ix| {
                const obj_t = self.resolveExprType(ix.object.*) orelse return null;
                switch (obj_t) {
                    .generic => |g| {
                        if (std.mem.eql(u8, g.name, "List") and g.params.len >= 1) return g.params[0];
                        if (std.mem.eql(u8, g.name, "Array") and g.params.len >= 1) return g.params[0];
                        if (std.mem.eql(u8, g.name, "Map") and g.params.len >= 2) return g.params[1];
                    },
                    .fixed_array => |fa| return fa.element.*,
                    .ident => |n| {
                        if (std.mem.eql(u8, n, "string")) return ast.TypeRef{ .ident = "i32" };
                    },
                    else => {},
                }
                return null;
            },
            .tuple => |elems| {
                const types_buf = self.allocator.alloc(ast.TypeRef, elems.len) catch return null;
                for (elems, 0..) |el, i| {
                    types_buf[i] = self.resolveExprType(el) orelse {
                        self.allocator.free(types_buf);
                        return null;
                    };
                }
                return ast.TypeRef{ .tuple = types_buf };
            },
            else => return null,
        }
    }

    fn checkStruct(self: *TypeChecker, s: ast.StructDecl) !void {
        self.current_struct = s.name;
        defer self.current_struct = null;
        self.checkDuplicateTypeParams(s.name, s.type_params, s.span);

        for (s.methods, 0..) |m1, i| {
            for (s.methods[i + 1 ..]) |m2| {
                if (std.mem.eql(u8, m1.decl.name, m2.decl.name)) {
                    self.addError(m2.decl.span, "duplicate method '{s}' in '{s}', Nova has no overloading", .{ m2.decl.name, s.name });
                }
            }
        }
        for (s.fields) |f| self.rejectUnimplementedType(f.type_name, f.span, s.type_params, true);
        for (s.methods) |m| {
            self.variables.clearRetainingCapacity();
            self.closure_sigs.clearRetainingCapacity();

            try self.variables.put("self", ast.TypeRef{ .ident = s.name });
            for (m.decl.params) |param| {
                if (std.mem.eql(u8, param.name, "self")) {
                    const t = param.type_name orelse ast.TypeRef{ .ident = s.name };
                    try self.variables.put("self", t);
                } else if (param.type_name) |t| {
                    try self.variables.put(param.name, t);
                }
            }
            const prev_ret = self.current_ret_type;
            self.current_ret_type = m.decl.ret_type;

            const prev_async = self.in_async;
            if (self.is_wasm and m.decl.is_async) {
                self.addError(m.decl.span, "async method '{s}' is not available on the wasm target (no coroutine runtime). Guard native code with `@native {{ ... }}`.", .{m.decl.name});
            }
            self.in_async = m.decl.is_async;
            try self.checkBlock(m.decl.body);
            self.in_async = prev_async;
            self.current_ret_type = prev_ret;
        }

        for (s.impls) |impl| {
            const trait_name = impl.name;
            const trait_decl = self.traits.get(trait_name) orelse {
                self.addError(s.span, "Struct '{s}' implements undefined trait '{s}'", .{ s.name, trait_name });
                continue;
            };

            for (trait_decl.methods) |trait_method| {
                var found_method = false;
                for (s.methods) |m| {
                    if (std.mem.eql(u8, m.decl.name, trait_method.name)) {
                        found_method = true;

                        if (m.decl.is_async != trait_method.is_async) {
                            self.addError(m.decl.span, "Method '{s}' in struct '{s}' must be {s} to match trait '{s}'", .{ trait_method.name, s.name, if (trait_method.is_async) "'async'" else "non-async", trait_name });
                        }
                        if (m.decl.params.len != trait_method.params.len) {
                            self.addError(m.decl.span, "Method '{s}' in struct '{s}' has parameter count mismatch with trait '{s}' (expected {d}, found {d})", .{ trait_method.name, s.name, trait_name, trait_method.params.len, m.decl.params.len });
                        } else {

                            const tparams = trait_decl.type_params;
                            const targs = impl.type_args;
                            for (m.decl.params, 0..) |p, i| {

                                if (i == 0 and std.mem.eql(u8, p.name, "self")) continue;
                                const want = substOptTraitType(trait_method.params[i].type_name, tparams, targs);
                                if (!optTypesAreEqual(p.type_name, want)) {
                                    self.addError(p.span, "Method '{s}' in struct '{s}' has type mismatch for parameter '{s}' with trait '{s}'", .{ trait_method.name, s.name, p.name, trait_name });
                                }
                            }
                        }

                        const want_ret = substOptTraitType(trait_method.ret_type, trait_decl.type_params, impl.type_args);
                        if (!optTypesAreEqual(m.decl.ret_type, want_ret)) {
                            self.addError(m.decl.span, "Method '{s}' in struct '{s}' has return type mismatch with trait '{s}'", .{ trait_method.name, s.name, trait_name });
                        }
                        break;
                    }
                }

                if (!found_method) {
                    self.addError(s.span, "Struct '{s}' is missing implementation of trait method '{s}' defined in trait '{s}'", .{ s.name, trait_method.name, trait_name });
                }
            }
        }
    }

    fn checkTrait(self: *TypeChecker, t: ast.TraitDecl) !void {
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        for (t.methods) |m| {
            if (seen.contains(m.name)) {
                self.addError(m.span, "Duplicate method '{s}' in trait '{s}'", .{ m.name, t.name });
            } else {
                try seen.put(m.name, {});
            }
        }
    }

    fn checkEnum(self: *TypeChecker, e: ast.EnumDecl) !void {
        self.current_struct = e.name;
        defer self.current_struct = null;

        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        for (e.variants) |v| {
            if (seen.contains(v.name)) {
                self.addError(v.span, "Duplicate enum variant '{s}' in enum '{s}'", .{ v.name, e.name });
            } else {
                try seen.put(v.name, {});
            }
        }

        if (e.is_exception) {
            var has_message = false;
            for (e.methods) |m| {
                if (!std.mem.eql(u8, m.decl.name, "message")) continue;
                const is_instance = m.decl.params.len > 0 and std.mem.eql(u8, m.decl.params[0].name, "self");
                const rt = m.decl.ret_type;
                const returns_string = rt != null and rt.? == .ident and std.mem.eql(u8, rt.?.ident, "string");
                if (is_instance and returns_string) {
                    has_message = true;
                    break;
                }
            }
            if (!has_message) {
                self.addError(e.span, "exception '{s}' must define a `message(self): string` method, every exception provides a human-readable message. Add `fn message(self: {s}): string {{ ... }}`.", .{ e.name, e.name });
            }
        }

        for (e.methods) |m| {
            self.variables.clearRetainingCapacity();
            self.closure_sigs.clearRetainingCapacity();
            for (m.decl.params) |param| {
                if (std.mem.eql(u8, param.name, "self")) {
                    const t = param.type_name orelse ast.TypeRef{ .ident = e.name };
                    try self.variables.put("self", t);
                } else if (param.type_name) |t| {
                    try self.variables.put(param.name, t);
                }
            }
            const prev_ret = self.current_ret_type;
            self.current_ret_type = m.decl.ret_type;
            const prev_async = self.in_async;
            if (self.is_wasm and m.decl.is_async) {
                self.addError(m.decl.span, "async method '{s}' is not available on the wasm target (no coroutine runtime). Guard native code with `@native {{ ... }}`.", .{m.decl.name});
            }
            self.in_async = m.decl.is_async;
            try self.checkBlock(m.decl.body);
            self.in_async = prev_async;
            self.current_ret_type = prev_ret;
        }
    }

    fn checkConst(self: *TypeChecker, c: ast.ConstDecl) !void {
        _ = self;
        _ = c;
    }
};

fn isScalarPrimitiveName(n: []const u8) bool {
    const scalars = [_][]const u8{ "int", "long", "short", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "usize", "uint", "ulong", "ushort", "f32", "f64", "float", "double", "bool", "decimal", "byte", "char", "void" };
    for (scalars) |s| if (std.mem.eql(u8, n, s)) return true;
    return false;
}

fn canonicalizeTypeName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "byte") or std.mem.eql(u8, name, "ubyte")) return "i8";
    if (std.mem.eql(u8, name, "short") or std.mem.eql(u8, name, "ushort")) return "i16";
    if (std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "uint")) return "i32";
    if (std.mem.eql(u8, name, "long") or std.mem.eql(u8, name, "ulong")) return "i64";
    if (std.mem.eql(u8, name, "double")) return "f64";
    if (std.mem.eql(u8, name, "float")) return "f32";

    if (std.mem.eql(u8, name, "u8")) return "i8";
    if (std.mem.eql(u8, name, "u16")) return "i16";
    if (std.mem.eql(u8, name, "u32")) return "i32";
    if (std.mem.eql(u8, name, "u64")) return "i64";
    if (std.mem.eql(u8, name, "u128")) return "i128";
    return name;
}

fn typesAreEqual(a: ast.TypeRef, b: ast.TypeRef) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    switch (a) {
        .ident => |id_a| return std.mem.eql(u8, canonicalizeTypeName(id_a), canonicalizeTypeName(b.ident)),
        .optional => |opt_a| return typesAreEqual(opt_a.*, b.optional.*),
        .error_union => |eu_a| return typesAreEqual(eu_a.ok.*, b.error_union.ok.*) and
            typesAreEqual(eu_a.err.*, b.error_union.err.*),
        .fixed_array => |fa_a| {
            return fa_a.length == b.fixed_array.length and typesAreEqual(fa_a.element.*, b.fixed_array.element.*);
        },
        .generic => |g_a| {
            if (!std.mem.eql(u8, g_a.name, b.generic.name)) return false;
            if (g_a.params.len != b.generic.params.len) return false;
            for (g_a.params, 0..) |p, i| {
                if (!typesAreEqual(p, b.generic.params[i])) return false;
            }
            return true;
        },
        .func => |f_a| {
            if (f_a.params.len != b.func.params.len) return false;
            for (f_a.params, 0..) |p, i| {
                if (!typesAreEqual(p, b.func.params[i])) return false;
            }
            return typesAreEqual(f_a.ret.*, b.func.ret.*);
        },
        .tuple => |t_a| {
            if (t_a.len != b.tuple.len) return false;
            for (t_a, 0..) |p, i| {
                if (!typesAreEqual(p, b.tuple[i])) return false;
            }
            return true;
        },
    }
}

fn isNumericTypeName(name: []const u8) bool {
    const c = canonicalizeTypeName(name);
    return std.mem.eql(u8, c, "i8") or std.mem.eql(u8, c, "i16") or std.mem.eql(u8, c, "i32") or
           std.mem.eql(u8, c, "i64") or std.mem.eql(u8, c, "i128") or std.mem.eql(u8, c, "f32") or
           std.mem.eql(u8, c, "f64");
}

const PrimCat = enum { numeric, boolean, text, other };
fn primCategory(name: []const u8) PrimCat {
    if (isNumericTypeName(name)) return .numeric;
    const c = canonicalizeTypeName(name);
    if (std.mem.eql(u8, c, "bool")) return .boolean;
    if (std.mem.eql(u8, c, "string")) return .text;
    return .other;
}

fn isTypeCompatible(from: ast.TypeRef, to: ast.TypeRef) bool {
    if ((from == .ident and std.mem.eql(u8, from.ident, "any")) or
        (to == .ident and std.mem.eql(u8, to.ident, "any"))) {
        return true;
    }

    if (from == .ident and to == .generic) {
        return std.mem.eql(u8, canonicalizeTypeName(from.ident), canonicalizeTypeName(to.generic.name));
    }
    if (from == .generic and to == .ident) {
        return std.mem.eql(u8, canonicalizeTypeName(from.generic.name), canonicalizeTypeName(to.ident));
    }

    if (to == .optional and from != .optional) {
        return isTypeCompatible(from, to.optional.*);
    }

    if (to == .error_union and from != .error_union) {
        return isTypeCompatible(from, to.error_union.ok.*) or
            isTypeCompatible(from, to.error_union.err.*);
    }
    if (std.meta.activeTag(from) != std.meta.activeTag(to)) return false;
    switch (from) {
        .ident => |id_from| {
            const id_to = to.ident;
            const c_from = canonicalizeTypeName(id_from);
            const c_to = canonicalizeTypeName(id_to);
            if (std.mem.eql(u8, c_from, c_to)) return true;

            if (isNumericTypeName(c_from) and isNumericTypeName(c_to)) {
                return true;
            }

            return false;
        },
        .optional => |opt_from| return isTypeCompatible(opt_from.*, to.optional.*),

        .error_union => |eu_from| return isTypeCompatible(eu_from.ok.*, to.error_union.ok.*) and
            isTypeCompatible(eu_from.err.*, to.error_union.err.*),
        .fixed_array => |fa_from| {
            return fa_from.length == to.fixed_array.length and isTypeCompatible(fa_from.element.*, to.fixed_array.element.*);
        },
        .generic => |g_from| {
            if (!std.mem.eql(u8, g_from.name, to.generic.name)) return false;
            if (g_from.params.len != to.generic.params.len) return false;
            for (g_from.params, 0..) |p, i| {
                if (!isTypeCompatible(p, to.generic.params[i])) return false;
            }
            return true;
        },
        .func => |f_from| {
            if (f_from.params.len != to.func.params.len) return false;
            for (f_from.params, 0..) |p, i| {
                if (!isTypeCompatible(p, to.func.params[i])) return false;
            }
            return isTypeCompatible(f_from.ret.*, to.func.ret.*);
        },
        .tuple => |t_from| {
            if (t_from.len != to.tuple.len) return false;
            for (t_from, 0..) |p, i| {
                if (!isTypeCompatible(p, to.tuple[i])) return false;
            }
            return true;
        },
    }
}

fn optTypesAreEqual(a_opt: ?ast.TypeRef, b_opt: ?ast.TypeRef) bool {
    if (a_opt == null and b_opt == null) return true;
    if (a_opt == null or b_opt == null) return false;
    return typesAreEqual(a_opt.?, b_opt.?);
}

fn substTraitType(tr: ast.TypeRef, tparams: []const []const u8, targs: []const ast.TypeRef) ast.TypeRef {
    switch (tr) {
        .ident => |name| {
            for (tparams, 0..) |tp, i| {
                if (i < targs.len and std.mem.eql(u8, tp, name)) return targs[i];
            }
            return tr;
        },
        else => return tr,
    }
}

fn substOptTraitType(tr: ?ast.TypeRef, tparams: []const []const u8, targs: []const ast.TypeRef) ?ast.TypeRef {
    return if (tr) |t| substTraitType(t, tparams, targs) else null;
}

fn isConstructorCall(expr: ast.Expression) bool {
    switch (expr) {
        .call => |c| {
            return isCalleeConstructor(c.callee.*);
        },
        .generic_call => |gc| {
            return isCalleeConstructor(gc.callee.*);
        },
        else => return false,
    }
}

fn isCalleeConstructor(callee: ast.Expression) bool {
    switch (callee) {
        .ident => |id| {
            if (id.len > 0 and std.ascii.isUpper(id[0])) return true;
            return std.mem.eql(u8, id, "new") or
                   std.mem.eql(u8, id, "init") or
                   std.mem.endsWith(u8, id, "_new") or
                   std.mem.endsWith(u8, id, "_init") or
                   std.mem.startsWith(u8, id, "new_") or
                   std.mem.eql(u8, id, "new_buffered") or
                   std.mem.eql(u8, id, "new_mutex") or
                   std.mem.eql(u8, id, "new_condvar") or
                   std.mem.eql(u8, id, "new_rwlock");
        },
        .field_access => |fa| {
            const field = fa.field;
            if (field.len > 0 and std.ascii.isUpper(field[0])) return true;
            return std.mem.eql(u8, field, "new") or
                   std.mem.eql(u8, field, "init") or
                   std.mem.eql(u8, field, "new_buffered") or
                   std.mem.eql(u8, field, "new_mutex") or
                   std.mem.eql(u8, field, "new_condvar") or
                   std.mem.eql(u8, field, "new_rwlock");
        },
        else => return false,
    }
}

fn isVariableDeferred(stmt: ast.Statement, var_name: []const u8) bool {
    switch (stmt) {
        .block => |b| {
            for (b.statements) |s| {
                if (isVariableDeferred(s, var_name)) return true;
            }
        },
        .if_stmt => |is| {
            if (isVariableDeferred(is.then_branch.*, var_name)) return true;
            if (is.else_branch) |eb| {
                if (isVariableDeferred(eb.*, var_name)) return true;
            }
        },
        .while_stmt => |ws| {
            if (isVariableDeferred(ws.body.*, var_name)) return true;
        },
        .for_stmt => |fs| {
            if (isVariableDeferred(fs.body.*, var_name)) return true;
        },
        .defer_stmt => |ds| {
            switch (ds.expr) {
                .call => |c| {
                    switch (c.callee.*) {
                        .field_access => |fa| {
                            switch (fa.object.*) {
                                .ident => |id| {
                                    if (std.mem.eql(u8, id, var_name)) {
                                        if (std.mem.startsWith(u8, fa.field, "delete")) {
                                            return true;
                                        }
                                    }
                                },
                                else => {},
                            }
                        },
                        .ident => |id| {
                            if (std.mem.startsWith(u8, id, "delete")) {
                                if (c.args.len > 0) {
                                    switch (c.args[0]) {
                                        .ident => |arg_id| {
                                            if (std.mem.eql(u8, arg_id, var_name)) {
                                                return true;
                                            }
                                        },
                                        else => {},
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                },
                .generic_call => |gc| {
                    switch (gc.callee.*) {
                        .field_access => |fa| {
                            switch (fa.object.*) {
                                .ident => |id| {
                                    if (std.mem.eql(u8, id, var_name)) {
                                        if (std.mem.startsWith(u8, fa.field, "delete")) {
                                            return true;
                                        }
                                    }
                                },
                                else => {},
                            }
                        },
                        .ident => |id| {
                            if (std.mem.startsWith(u8, id, "delete")) {
                                if (gc.args.len > 0) {
                                    switch (gc.args[0]) {
                                        .ident => |arg_id| {
                                            if (std.mem.eql(u8, arg_id, var_name)) {
                                                return true;
                                            }
                                        },
                                        else => {},
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        },
        else => {},
    }
    return false;
}

fn isVariableReturned(stmt: ast.Statement, var_name: []const u8) bool {
    switch (stmt) {
        .block => |b| {
            for (b.statements) |s| {
                if (isVariableReturned(s, var_name)) return true;
            }
        },
        .if_stmt => |is| {
            if (isVariableReturned(is.then_branch.*, var_name)) return true;
            if (is.else_branch) |eb| {
                if (isVariableReturned(eb.*, var_name)) return true;
            }
        },
        .while_stmt => |ws| {
            if (isVariableReturned(ws.body.*, var_name)) return true;
        },
        .for_stmt => |fs| {
            if (isVariableReturned(fs.body.*, var_name)) return true;
        },
        .return_stmt => |rs| {
            if (rs.value) |val| {
                if (exprReferencesVariable(val, var_name)) return true;
            }
        },
        .switch_stmt => |ss| {
            for (ss.cases) |c| {
                if (isVariableReturned(c.body.*, var_name)) return true;
            }
            if (ss.default_case) |dc| {
                if (isVariableReturned(dc.*, var_name)) return true;
            }
        },
else => {},
    }
    return false;
}

fn exprReferencesVariable(expr: ast.Expression, var_name: []const u8) bool {
    switch (expr) {
        .ident => |id| return std.mem.eql(u8, id, var_name),
        .call => |c| {
            if (exprReferencesVariable(c.callee.*, var_name)) return true;
            for (c.args) |arg| {
                if (exprReferencesVariable(arg, var_name)) return true;
            }
        },
        .generic_call => |gc| {
            if (exprReferencesVariable(gc.callee.*, var_name)) return true;
            for (gc.args) |arg| {
                if (exprReferencesVariable(arg, var_name)) return true;
            }
        },
        .tuple => |t| {
            for (t) |elem| {
                if (exprReferencesVariable(elem, var_name)) return true;
            }
        },
        .field_access => |fa| {
            return exprReferencesVariable(fa.object.*, var_name);
        },
        .binary => |b| {
            return exprReferencesVariable(b.left.*, var_name) or exprReferencesVariable(b.right.*, var_name);
        },
        .unary => |u| {
            return exprReferencesVariable(u.operand.*, var_name);
        },
        .index => |idx| {
            return exprReferencesVariable(idx.object.*, var_name) or exprReferencesVariable(idx.index.*, var_name);
        },
        .struct_init => |si| {
            for (si.fields) |field| {
                if (exprReferencesVariable(field.value, var_name)) return true;
            }
        },
        .enum_init => |ei| {
            for (ei.fields) |field| {
                if (exprReferencesVariable(field.value, var_name)) return true;
            }
        },
        .cast => |c| {
            return exprReferencesVariable(c.expr.*, var_name);
        },
        .optional_chaining => |oc| {
            return exprReferencesVariable(oc.object.*, var_name);
        },
        .nullish_coalesce => |nc| {
            return exprReferencesVariable(nc.left.*, var_name) or exprReferencesVariable(nc.right.*, var_name);
        },
        .if_expr => |ife| {
            return exprReferencesVariable(ife.condition.*, var_name) or exprReferencesVariable(ife.then_branch.*, var_name) or exprReferencesVariable(ife.else_branch.*, var_name);
        },
        .closure => |cl| {
            switch (cl.body) {
                .expr => |e| return exprReferencesVariable(e.*, var_name),
                .block => |b| return isVariableReturned(ast.Statement{ .block = b }, var_name),
            }
        },
        .template_expr => |te| {
            for (te.parts) |p| {
                if (exprReferencesVariable(p, var_name)) return true;
            }
        },
        .block_expr => {},
        .literal => {},
        else => {},
    }
    return false;
}
