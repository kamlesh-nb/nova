const std = @import("std");
const ast = @import("ast.zig");
const builtins = @import("sema/builtins.zig");

/// A7 / F3 §5 stage 4b (ptr migration): map a builtin's `Ret` to a checker TypeRef.
/// `bytes.alloc` → `ptr` is the load-bearing one — it makes every field/return/let that
/// stores a raw address a TYPE ERROR until it is honestly typed `ptr` (F3 §3.2).
fn builtinRetType(r: builtins.Ret) ?ast.TypeRef {
    return switch (r) {
        .void_ => ast.TypeRef{ .ident = "void" },
        .int => ast.TypeRef{ .ident = "i32" },
        .long => ast.TypeRef{ .ident = "i64" },
        .ptr => ast.TypeRef{ .ident = "ptr" },
        .string => ast.TypeRef{ .ident = "string" },
        .bool_ => ast.TypeRef{ .ident = "bool" },
        .decimal => ast.TypeRef{ .ident = "decimal" },
    };
}

/// A7 / F3 §5 stage 4b: `from` is a `ptr` (word-width address) and `to` is a ≤32-bit
/// integer — storing it there truncates the address once `int` narrows to 32 bits.
/// This is the one direction the ptr migration must forbid.
fn isPtrTruncation(from: ast.TypeRef, to: ast.TypeRef) bool {
    if (from != .ident or to != .ident) return false;
    if (!std.mem.eql(u8, canonicalizeTypeName(from.ident), "ptr")) return false;
    const ct = canonicalizeTypeName(to.ident);
    return std.mem.eql(u8, ct, "i8") or std.mem.eql(u8, ct, "i16") or std.mem.eql(u8, ct, "i32");
}

/// A7 / F3 §5 stage 5: the inclusive value range of a fixed-width integer type, or null
/// for non-integers and for 64-bit types (an i64 literal always fits its own width).
const IntRange = struct { min: i128, max: i128 };
fn intTypeRange(name: []const u8) ?IntRange {
    const c = canonicalizeTypeName(name);
    // Unsigned: anything starting `u` (uint/ushort/ubyte/u8…) plus `byte` (= u8).
    const signed = !(std.mem.startsWith(u8, name, "u") or std.mem.eql(u8, name, "byte"));
    const w: u32 = if (std.mem.eql(u8, c, "i8")) 8 else if (std.mem.eql(u8, c, "i16")) 16 else if (std.mem.eql(u8, c, "i32")) 32 else return null;
    if (signed) {
        const half: i128 = @as(i128, 1) << @intCast(w - 1);
        return .{ .min = -half, .max = half - 1 };
    }
    return .{ .min = 0, .max = (@as(i128, 1) << @intCast(w)) - 1 };
}

/// A7 / F3 §5 stage 5: the bit-width of a fixed-width integer type name, or null for
/// non-fixed-int types (structs, string, ptr, float, generics). `ptr` is deliberately
/// excluded — ptr→int is the separate `isPtrTruncation` rule.
fn intWidthOf(name: []const u8) ?u32 {
    const c = canonicalizeTypeName(name);
    if (std.mem.eql(u8, c, "i8")) return 8;
    if (std.mem.eql(u8, c, "i16")) return 16;
    if (std.mem.eql(u8, c, "i32")) return 32;
    if (std.mem.eql(u8, c, "i64")) return 64;
    return null;
}

/// A widening integer conversion loses no value; a NARROWING one (wider → narrower) can,
/// so §6 requires an explicit `as`. True only when both are fixed-width ints and
/// `from` is strictly wider than `to`.
fn isNarrowingInt(from: ast.TypeRef, to: ast.TypeRef) bool {
    if (from != .ident or to != .ident) return false;
    const fw = intWidthOf(from.ident) orelse return false;
    const tw = intWidthOf(to.ident) orelse return false;
    return fw > tw;
}

/// Signedness of an integer type NAME (pre-canonical, so `int`≠`uint` is visible):
/// unsigned iff it starts with `u` (uint/ushort/u8…) or is `byte` (= u8).
fn intNameSigned(name: []const u8) bool {
    return !(std.mem.startsWith(u8, name, "u") or std.mem.eql(u8, name, "byte"));
}

/// A7 / F3 §5 stage 5 (§6): a SAME-WIDTH signedness change (`int`↔`uint`, `long`↔`ulong`,
/// …) reinterprets the bits — the same 32 bits mean a different value — so it needs an
/// explicit `as`. Different widths are handled by widening/narrowing rules, not here.
/// `canonicalizeTypeName` collapses int/uint to `i32`, so this reads the raw names.
fn isSignednessMismatch(from: ast.TypeRef, to: ast.TypeRef) bool {
    if (from != .ident or to != .ident) return false;
    const fw = intWidthOf(from.ident) orelse return false;
    const tw = intWidthOf(to.ident) orelse return false;
    if (fw != tw) return false;
    return intNameSigned(from.ident) != intNameSigned(to.ident);
}

/// The compile-time value of an integer literal, accounting for a leading unary `-`
/// (`-2147483648` parses as `neg(2147483648)`, and 2147483648 alone overflows i32 but
/// the negation is i32-min). Returns null when the expression is not an integer literal.
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

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList([]const u8),
    file_sources: *std.StringHashMap([]const u8),
    enums: std.StringHashMap(ast.EnumDecl),
    variables: std.StringHashMap(ast.TypeRef),
    structs: std.StringHashMap(ast.StructDecl),
    unions: std.StringHashMap(ast.UnionDecl),
    traits: std.StringHashMap(ast.TraitDecl),
    functions: std.StringHashMap(ast.FunctionDecl),
    // Function names that appear more than once across the merged program (e.g.
    // same bare name in two modules). Arg-count checking skips these because we
    // can't tell which overload a bare-name call resolves to without namespacing.
    ambiguous_fns: std.StringHashMap(void),
    // F1-3b N2: the set of "<file>\x00<fn-name>" pairs — which FILE defines which function. A bare
    // call to an ambiguous name is UNAMBIGUOUS when the calling file itself defines that name (the
    // scan resolved it via current_module_prefix before ever reaching the ambiguity check —
    // `contains` inside string.nova is string's own). So N2 fires only when the caller's file does
    // NOT define the name. Keys owned by allocator.
    fn_def_sites: std.StringHashMap(void),
    fn_first_line: std.StringHashMap(usize) = undefined,
    current_struct: ?[]const u8,
    current_ret_type: ?ast.TypeRef = null,
    // M3-B: function coloring — true while checking the body of an `async fn`.
    // `await` is only legal when this is set.
    in_async: bool = false,

    pub fn init(allocator: std.mem.Allocator, file_sources: *std.StringHashMap([]const u8)) TypeChecker {
        return TypeChecker{
            .allocator = allocator,
            .errors = std.ArrayList([]const u8).empty,
            .file_sources = file_sources,
            .enums = std.StringHashMap(ast.EnumDecl).init(allocator),
            .variables = std.StringHashMap(ast.TypeRef).init(allocator),
            .structs = std.StringHashMap(ast.StructDecl).init(allocator),
            .unions = std.StringHashMap(ast.UnionDecl).init(allocator),
            .traits = std.StringHashMap(ast.TraitDecl).init(allocator),
            .functions = std.StringHashMap(ast.FunctionDecl).init(allocator),
            .ambiguous_fns = std.StringHashMap(void).init(allocator),
            .fn_def_sites = std.StringHashMap(void).init(allocator),
            .fn_first_line = std.StringHashMap(usize).init(allocator),
            .current_struct = null,
        };
    }

    /// F1-3b N2: does `file` define a function named `name`? (locality — see `fn_def_sites`.)
    fn fileDefinesFn(self: *TypeChecker, file: []const u8, name: []const u8) bool {
        const key = std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ file, name }) catch return false;
        defer self.allocator.free(key);
        return self.fn_def_sites.contains(key);
    }

    pub fn deinit(self: *TypeChecker) void {
        for (self.errors.items) |err| {
            self.allocator.free(err);
        }
        self.errors.deinit(self.allocator);
        self.enums.deinit();
        self.variables.deinit();
        self.structs.deinit();
        self.unions.deinit();
        self.traits.deinit();
        self.functions.deinit();
        self.ambiguous_fns.deinit();
        var it = self.fn_def_sites.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.fn_def_sites.deinit();
    }

    fn addError(self: *TypeChecker, span: ast.Span, comptime fmt: []const u8, args: anytype) void {
        const user_msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(user_msg);

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

    pub fn check(self: *TypeChecker, program: ast.Program) !void {
        for (program.declarations) |decl| {
            if (decl == .enum_decl) {
                try self.enums.put(decl.enum_decl.name, decl.enum_decl);
            }
            if (decl == .struct_decl) {
                // F1 module-scoped types: same-named structs in different modules COEXIST — each
                // resolves to its own via findTypeInModule (sema, resolves a bare name to the LOCAL
                // definition first) + scopedStructName (codegen keys colliding structs by module). The
                // former "defined in two modules" hard error is retired; no collision diagnostic needed.
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
                // F1-3b N2: record that this file defines this fn name (locality).
                // F4/F1-6: Nova has NO function overloading (specs.md §"No ... overloading"), so two
                // functions with the SAME name in the SAME module (file) are a REDEFINITION, not an
                // overload set — and codegen would silently dedup them by name (declarations.zig),
                // dropping one, so calls resolve to the survivor and produce garbage. Reject it here as
                // a located error. Keyed on (file, name) so same-named functions in DIFFERENT modules
                // still coexist (module-prefixed symbols never collide). A recurrence at the SAME line
                // is a benign double-inclusion of one decl (proven: 0 different-line recurrences across
                // the corpus), so only a DIFFERENT line is a genuine second definition.
                // GENERATED code is exempt: the compiler emits `<Struct>__bind`/`__toJson` into the single
                // `<serde-generated>` pseudo-file, so two same-named `@serializable` structs in DIFFERENT
                // user modules produce two identical-named binders there — a benign collision (the binder
                // is a pure function of the struct's fields), NOT a user redefinition. Only real source
                // files are checked. (helpers/test_harness are likewise synthetic.)
                const gen_file = std.mem.eql(u8, decl.fn_decl.span.file, "<serde-generated>") or
                    std.mem.eql(u8, decl.fn_decl.span.file, "helpers.nova") or
                    std.mem.eql(u8, decl.fn_decl.span.file, "test_harness.nova");
                const key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ decl.fn_decl.span.file, decl.fn_decl.name });
                if (self.fn_def_sites.contains(key)) {
                    if (self.fn_first_line.get(key)) |ln| {
                        if (!gen_file and ln != decl.fn_decl.span.line) {
                            self.addError(decl.fn_decl.span, "duplicate function '{s}' — already defined at line {d} in this module (Nova has no overloading)", .{ decl.fn_decl.name, ln });
                        }
                    }
                    self.allocator.free(key);
                } else {
                    try self.fn_def_sites.put(key, {});
                    try self.fn_first_line.put(try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ decl.fn_decl.span.file, decl.fn_decl.name }), decl.fn_decl.span.line);
                }
            }
        }

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
            std.debug.print("Type checking failed with {d} error(s):\n", .{self.errors.items.len});
            for (self.errors.items) |err| {
                std.debug.print("  {s}\n", .{err});
            }
            return error.TypeCheckError;
        }
    }

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

    fn checkBoolCondition(self: *TypeChecker, cond: ast.Expression, span: ast.Span) void {
        const t = self.resolveExprType(cond) orelse return; // unknown → skip
        if (t != .ident) return;
        const n = t.ident;
        // Flag only clearly-non-bool primitives; skip bool/any/unknown/other to
        // avoid false positives while the resolver is still coarse.
        if (std.mem.eql(u8, n, "string") or std.mem.eql(u8, n, "i32") or
            std.mem.eql(u8, n, "f64") or std.mem.eql(u8, n, "i64"))
        {
            self.addError(span, "condition must be a bool, got '{s}'", .{n});
        }
    }

    fn checkFunction(self: *TypeChecker, func: ast.FunctionDecl) anyerror!void {
        self.checkDuplicateTypeParams(func.name, func.type_params, func.span);
        self.variables.clearRetainingCapacity();

        for (func.params) |param| {
            if (param.type_name) |t| {
                self.rejectUnimplementedType(t, param.span);
                try self.variables.put(param.name, t);
            }
        }
        if (func.ret_type) |rt| self.rejectUnimplementedType(rt, func.span);

        const prev_ret = self.current_ret_type;
        self.current_ret_type = func.ret_type;
        defer self.current_ret_type = prev_ret;
        const prev_async = self.in_async;
        self.in_async = func.is_async;
        defer self.in_async = prev_async;
        try self.checkBlock(func.body);
    }

    fn typeRefName(t: ast.TypeRef) []const u8 {
        return switch (t) {
            .ident => |n| n,
            else => "<type>",
        };
    }

    /// A7 / F3 §3.2a: `decimal` is now IMPLEMENTED (IEEE 754-2008 decimal128, BID — specs §3.1), a
    /// 16-byte ARC heap object, so it is accepted like any other type. Still rejects `i128`/`u128`,
    /// removed by F3 (zero users). Recurses so `i128[]` / `List<u128>` are caught too.
    fn rejectUnimplementedType(self: *TypeChecker, t: ast.TypeRef, span: ast.Span) void {
        switch (t) {
            .ident => |n| {
                if (std.mem.eql(u8, n, "i128") or std.mem.eql(u8, n, "u128")) {
                    self.addError(span, "type '128-bit integer' was removed (F3 §3.1); use 'long' or 'i64'", .{});
                }
            },
            .optional => |inner| self.rejectUnimplementedType(inner.*, span),
            .error_union => |eu| {
                self.rejectUnimplementedType(eu.ok.*, span);
                self.rejectUnimplementedType(eu.err.*, span);
            },
            .fixed_array => |fa| self.rejectUnimplementedType(fa.element.*, span),
            .generic => |g| for (g.params) |p| self.rejectUnimplementedType(p, span),
            .func => |f| {
                for (f.params) |p| self.rejectUnimplementedType(p, span);
                self.rejectUnimplementedType(f.ret.*, span);
            },
            .tuple => |items| for (items) |i| self.rejectUnimplementedType(i, span),
        }
    }

    fn checkReturnType(self: *TypeChecker, value: ast.Expression, span: ast.Span) void {
        const rt = self.current_ret_type orelse return;
        if (rt == .ident and (std.mem.eql(u8, rt.ident, "void") or std.mem.eql(u8, rt.ident, "any"))) return;
        // Skip when the declared return is a generic type parameter (single upper) —
        // including `T | undefined` — since values flow through the uniform i32
        // representation there (e.g. `get<T>(): T | undefined { return bytes.read_i32(..) }`
        // legitimately returns the i32 word as the erased element). Unwrap optionals so
        // the skip still applies; otherwise A7's `bytes.*` typing turns this into a false
        // ptr-migration positive.
        const rt_core = if (rt == .optional) rt.optional.* else rt;
        if (rt_core == .ident and rt_core.ident.len == 1) return;
        // A polymorphic integer literal (`return 4000000000` from a `uint` fn) adapts to
        // the return type — exempt from narrowing/signedness, same as a `let` initializer.
        //
        // ⚠️ But ONLY when the declared return is actually numeric. A literal adapts to a
        // numeric WIDTH; it does not adapt to `string`. Exempting every int literal
        // unconditionally silently disabled this whole check for literal returns, so
        // `fn f(): string { return 42; }` compiled and segfaulted — which is precisely
        // expect_fail/return_type_mismatch, the case this function exists for. The harness
        // could not see it because a segfault also exits non-zero. (Fixed 2026-07-17.)
        if (intLiteralValue(value) != null) {
            if (rt_core != .ident) return; // non-ident return shape → unknown, stay quiet
            if (isNumericTypeName(rt_core.ident)) return; // numeric absorbs the literal
            // else: fall through — an int literal returned from a non-numeric fn is a real error
        }
        const vt = self.resolveExprType(value) orelse return; // unknown → skip
        // Only flag when we resolved a concrete named type. Non-ident results (e.g.
        // a nested field access through an imported struct the resolver couldn't fully
        // type) are treated as unknown to avoid false positives in Nova's loose system.
        if (vt != .ident) return;
        if (!self.assignable(vt, rt)) {
            self.addError(span, "return type mismatch: returning '{s}' from a function declared to return '{s}'", .{ typeRefName(vt), typeRefName(rt) });
        }
    }

    // True when a concrete struct implements the named trait (checks its `impls`).
    fn structImplementsTrait(self: *TypeChecker, struct_name: []const u8, trait_name: []const u8) bool {
        const base = canonicalizeTypeName(struct_name);
        const s = self.structs.get(base) orelse return false;
        for (s.impls) |impl| {
            if (std.mem.eql(u8, impl.name, trait_name)) return true;
        }
        return false;
    }

    // Assignability: structural compatibility, plus a concrete struct is assignable to
    // a trait type it implements (trait-object coercion happens in codegen).
    fn assignable(self: *TypeChecker, from: ast.TypeRef, to: ast.TypeRef) bool {
        // A7 / F3 §5 stage 5: a narrowing conversion or a same-width signedness change
        // needs an explicit `as` (§6). Both checked BEFORE isTypeCompatible, whose
        // numeric↔numeric permissiveness (and int/uint→i32 canonicalisation) would
        // otherwise wave `long`→`int` and `int`↔`uint` through.
        if (isNarrowingInt(from, to)) return false;
        if (isSignednessMismatch(from, to)) return false;
        if (isTypeCompatible(from, to)) return true;
        if (to == .ident and from == .ident and self.traits.contains(to.ident)) {
            if (self.structImplementsTrait(from.ident, to.ident)) return true;
        }
        // Generic trait object: a struct implementing `Trait<A>` is assignable to `Trait<A>`
        // (e.g. `let b: Box<int> = intBox`). The declared type is `.generic { name, params }`; the
        // struct's `impl` records the trait by its BASE name, so match on that (trait-object
        // coercion + the per-instantiation vtable happen in codegen).
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
        // A7 / F3 §5 stage 4b (ptr migration). `ptr` is word-width; `int`/`i32` narrows
        // to 32 bits at stage 5. The ONLY unsafe flow is a `ptr` (a real address) landing
        // in a ≤32-bit integer — that truncates. Everything width-safe is allowed here so
        // the flush targets exactly the truncating sites:
        //   • int/long/any-numeric → ptr  (a size, offset, or the literal 0/null becoming
        //     an address; widening, never lossy)
        //   • ptr → long (i64)            (width-safe; some runtime handles are `long`)
        // `ptr → i8/i16/i32` is deliberately NOT allowed and falls through to `false`.
        if (from == .ident and to == .ident) {
            const cf = canonicalizeTypeName(from.ident);
            const ct = canonicalizeTypeName(to.ident);
            if (std.mem.eql(u8, ct, "ptr") and isNumericTypeName(cf)) return true;
            if (std.mem.eql(u8, cf, "ptr") and std.mem.eql(u8, ct, "i64")) return true;
        }
        return false;
    }

    fn checkBlock(self: *TypeChecker, block: ast.Block) anyerror!void {
        for (block.statements) |stmt| {
            try self.checkStatement(stmt);
        }

    }

    fn checkStatement(self: *TypeChecker, stmt: ast.Statement) anyerror!void {
        switch (stmt) {
            .block => |b| try self.checkBlock(b),
            .let_stmt => |ls| {
                if (ls.init) |init_walk| try self.checkExpr(init_walk);
                if (ls.type_name) |t| {
                    self.rejectUnimplementedType(t, ls.span);
                    try self.variables.put(ls.name, t);
                    if (ls.init) |init_expr| {
                        // A7 / F3 §5 stage 5: a literal that does not fit the declared
                        // fixed-width integer type is a hard error, not a silent 32-bit
                        // wrap (§6: narrowing needs an explicit cast). `let n: int =
                        // 5000000000` must say "use `long`", not quietly become 705032704.
                        if (t == .ident) {
                            if (intTypeRange(t.ident)) |range| {
                                if (intLiteralValue(init_expr)) |v| {
                                    if (v < range.min or v > range.max) {
                                        self.addError(ls.span, "integer literal {d} is out of range for '{s}' — use a wider type (e.g. 'long') or an explicit cast", .{ v, t.ident });
                                    }
                                }
                            }
                        }
                        // An integer literal is polymorphic — it has no inherent width or
                        // signedness and adapts to the target (its fit is gated by the
                        // range check above), so it is exempt from the narrowing/signedness
                        // rules. `let u: uint = 4000000000` and `let b: byte = 5` are fine.
                        const init_is_int_literal = intLiteralValue(init_expr) != null;
                        if (self.resolveExprType(init_expr)) |init_t| {
                            // Only flag clean ident-to-type mismatches; skip when the
                            // initializer's type couldn't be cleanly resolved (non-ident),
                            // to avoid false positives on nested/imported field access.
                            if (init_t == .ident and !init_is_int_literal and !self.assignable(init_t, t)) {
                                if (isNarrowingInt(init_t, t)) {
                                    self.addError(ls.span, "narrowing conversion: '{s}' cannot be implicitly stored into '{s}' — use an explicit cast (F3 §6)", .{ typeRefName(init_t), typeRefName(t) });
                                } else if (isSignednessMismatch(init_t, t)) {
                                    self.addError(ls.span, "signedness mismatch: '{s}' and '{s}' differ in sign — use an explicit cast (F3 §6)", .{ typeRefName(init_t), typeRefName(t) });
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

    // Param count of a struct's `init` constructor, or null if the struct has no
    // explicit init (field construction / default). Used to reject constructor calls
    // with the wrong argument count before they reach codegen (which would otherwise
    // emit an ill-formed call, e.g. `Map<i32,i32>()` → `Map_init` with just self →
    // LLVM verification failure).
    fn structInitParamCount(self: *TypeChecker, struct_name: []const u8) ?usize {
        const s = self.structs.get(struct_name) orelse return null;
        for (s.methods) |m| {
            if (std.mem.eql(u8, m.decl.name, "init")) {
                return m.decl.params.len;
            }
        }
        return null;
    }

    // A2/A3: recursively walk an expression, validating what we can. Currently
    // enforces generic instantiation arity; extend with more checks over time.
    fn checkExpr(self: *TypeChecker, expr: ast.Expression) anyerror!void {
        switch (expr.kind) {
            .generic_call => |gc| {
                if (gc.callee.kind == .ident) {
                    const name = gc.callee.kind.ident;
                    var expected: ?usize = null;
                    if (self.structs.get(name)) |s| {
                        expected = s.type_params.len;
                    } else if (self.functions.get(name)) |f| {
                        expected = f.type_params.len;
                    }
                    // Only enforce when the callee is a known decl; skip unknowns
                    // (builtins/intrinsics) to avoid false positives. Enforces both
                    // too-few/too-many type args AND type args on a non-generic type.
                    if (expected) |exp| {
                        if (gc.type_args.len != exp) {
                            self.addError(gc.span, "generic '{s}' expects {d} type argument(s), got {d}", .{ name, exp, gc.type_args.len });
                        }
                    }
                    // Constructor value-arg count, e.g. `Map<K,V>(cap, hashFn)`.
                    if (self.structs.contains(name)) {
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
                // Arg-count check for a plain top-level function call, but only
                // when unambiguous (no cross-module name collision) and not a
                // locally-shadowed name (a closure-valued variable). Conservative
                // → no false positives.
                if (c.callee.kind == .ident) {
                    const name = c.callee.kind.ident;
                    // Non-generic constructor call, e.g. `Point(x, y)`.
                    if (!self.variables.contains(name) and self.structs.contains(name)) {
                        if (self.structInitParamCount(name)) |init_params| {
                            if (c.args.len != init_params) {
                                self.addError(c.span, "constructor '{s}' expects {d} argument(s), got {d}", .{ name, init_params, c.args.len });
                            }
                        }
                    }
                    if (!self.ambiguous_fns.contains(name) and !self.variables.contains(name)) {
                        if (self.functions.get(name)) |f| {
                            if (c.args.len != f.params.len) {
                                self.addError(c.span, "function '{s}' expects {d} argument(s), got {d}", .{ name, f.params.len, c.args.len });
                            }
                        }
                    }
                    // F1-3b / F1 §2.3 N2: a BARE call to a name that two or more functions share
                    // (`contains` = string.contains AND assert.contains) is AMBIGUOUS — a compile
                    // error, never an arbitrary pick. This detection used to live in codegen's
                    // func_map suffix SCAN, the last thing keeping that 227-line fallback alive; the
                    // checker already knows the name is ambiguous (`ambiguous_fns`, populated on a
                    // bare-name collision at registration), so erroring HERE — with a source span,
                    // upgrading the old span-less codegen abort (F1 stage 7) — lets the scan be
                    // deleted. Not a variable (a closure value shadows), not a struct (constructor),
                    // and only for a plain-ident callee (a qualified `string.contains(...)` is a
                    // field_access and unambiguous).
                    if (self.ambiguous_fns.contains(name) and !self.variables.contains(name) and !self.structs.contains(name) and !self.fileDefinesFn(c.span.file, name)) {
                        self.addError(c.span, "call to '{s}' is ambiguous — more than one function is named '{s}' across the imported modules. Qualify it (e.g. `module.{s}(...)`).", .{ name, name, name });
                    }
                }
                try self.checkExpr(c.callee.*);
                for (c.args) |a| try self.checkExpr(a);
            },
            .binary => |b| {
                try self.checkExpr(b.left.*);
                try self.checkExpr(b.right.*);
                // A7 / F3 §5 stage 4b: catch a `ptr` (raw address) stored into a ≤32-bit
                // integer target — `self.data = bytes.alloc(...)` where `data: int`. This
                // is the assignment counterpart of the let/return checks; without it, field
                // stores would silently truncate at stage 5. Deliberately NARROW: it fires
                // ONLY on the ptr→narrow-int direction, so it does not tighten Nova's
                // otherwise-loose assignment checking.
                if (b.op == .assign and intLiteralValue(b.right.*) == null) {
                    if (self.resolveExprType(b.right.*)) |rt| {
                        if (self.resolveExprType(b.left.*)) |lt| {
                            if (isPtrTruncation(rt, lt)) {
                                self.addError(b.span, "pointer truncation: a 'ptr' (raw address) cannot be stored into '{s}' — type the target 'ptr' (F3 §3.2)", .{typeRefName(lt)});
                            } else if (isNarrowingInt(rt, lt)) {
                                self.addError(b.span, "narrowing conversion: '{s}' cannot be implicitly stored into '{s}' — use an explicit cast (F3 §6)", .{ typeRefName(rt), typeRefName(lt) });
                            } else if (isSignednessMismatch(rt, lt)) {
                                self.addError(b.span, "signedness mismatch: '{s}' and '{s}' differ in sign — use an explicit cast (F3 §6)", .{ typeRefName(rt), typeRefName(lt) });
                            }
                        }
                    }
                }
            },
            .unary => |u| try self.checkExpr(u.operand.*),
            .field_access => |fa| try self.checkExpr(fa.object.*),
            .index => |idx| {
                try self.checkExpr(idx.object.*);
                try self.checkExpr(idx.index.*);
            },
            .struct_init => |si| {
                for (si.fields) |field| try self.checkExpr(field.value);
                // C3: a struct literal must initialize EVERY declared field — fields have no defaults,
                // so an omitted field is left null/zero. For a trait- or owned-typed field that null then
                // SEGVs on first use (`Holder{}` where `g: G` → `h.g.v()` derefs a null vtable). Only
                // plain structs are checked (an enum-variant payload `E.V{...}` names a variant, and a
                // generic instantiation whose name carries type args resolves to null here — both skip).
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
                            if (self.structInitParamCount(si.type_name) != null) {
                                self.addError(si.span, "struct literal '{s}{{ … }}' is missing field '{s}' — initialize every field, or use the constructor '{s}(…)'", .{ si.type_name, df.name, si.type_name });
                            } else {
                                self.addError(si.span, "struct literal '{s}{{ … }}' is missing field '{s}' — every field must be initialized (fields have no defaults)", .{ si.type_name, df.name });
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
                // Function coloring: `await` is only legal inside an `async fn`.
                if (!self.in_async) {
                    self.addError(aw.span, "'await' is only allowed inside an 'async fn'", .{});
                }
                try self.checkExpr(aw.operand.*);
            },
            .go_expr => |g| {
                // `go <async-call>` launches a concurrent task; only legal in async.
                if (!self.in_async) {
                    self.addError(g.span, "'go' is only allowed inside an 'async fn'", .{});
                }
                try self.checkExpr(g.operand.*);
            },
            else => {},
        }
    }

    fn checkSwitch(self: *TypeChecker, ss: ast.SwitchStmt) anyerror!void {
        const disc_type = self.resolveExprType(ss.discriminant) orelse return;

        switch (disc_type) {
            .ident => |enum_name| {
                if (self.enums.get(enum_name)) |enum_decl| {
                    const variants = enum_decl.variants;
                    var covered = std.StringHashMap(bool).init(self.allocator);
                    defer covered.deinit();

                    for (variants) |v| {
                        try covered.put(v.name, false);
                    }

                    for (ss.cases) |case| {
                        for (case.values) |val| {
                            if (val.kind == .field_access) {
                                const fa = val.kind.field_access;
                                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, enum_name)) {
                                    try covered.put(fa.field, true);
                                }
                            } else if (val.kind == .call) {
                                const call = val.kind.call;
                                if (call.callee.kind == .field_access) {
                                    const fa = call.callee.kind.field_access;
                                    if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, enum_name)) {
                                        try covered.put(fa.field, true);
                                        for (variants) |v| {
                                            if (std.mem.eql(u8, v.name, fa.field)) {
                                                if (v.type_name) |payload_type| {
                                                    if (call.args.len > 0 and call.args[0].kind == .ident) {
                                                        const arg_name = call.args[0].kind.ident;
                                                        try self.variables.put(arg_name, payload_type);
                                                    }
                                                }
                                                break;
                                            }
                                        }
                                    }
                                }
                            } else if (val.kind == .struct_init) {
                                const si = val.kind.struct_init;
                                try covered.put(si.type_name, true);
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
                }
            },
            else => {},
        }
    }

    // Substitute a generic function's type PARAMETERS with the call's type ARGUMENTS throughout a
    // type — RECURSIVELY, so `foo<int>()` declared `fn foo<T>(): T` resolves to `int`, `List<T>` to
    // `List<int>`, `T | undefined` to `int | undefined`, etc. (substTraitType only handled a bare
    // top-level `T`.) Nested forms allocate fresh TypeRefs; an OOM falls back to the unsubstituted
    // type (the prior behaviour), never a crash.
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

    /// A method that IMPLEMENTS a trait method is part of that trait's PUBLIC contract, so it is
    /// callable wherever the trait is — even if the `impl` block did not repeat `pub` (the trait
    /// method's visibility governs, and trait methods are the public API). Without this, calling
    /// `h.handle(req)` on a `struct H impl RequestHandler { fn handle(...) ... }` was rejected as
    /// "private" whenever `h`'s type resolved to the struct — which happens for CALL-form
    /// construction (`H()`) bound to a `let`, while BRACE-form (`H{}`) skipped the check and hid
    /// the inconsistency (see conformance/cases/56, which uses the brace form).
    fn methodIsTraitContract(self: *TypeChecker, s: ast.StructDecl, method_name: []const u8) bool {
        for (s.impls) |impl| {
            const td = self.traits.get(impl.name) orelse continue;
            for (td.methods) |tm| {
                if (std.mem.eql(u8, tm.name, method_name)) return true;
            }
        }
        return false;
    }

    fn resolveExprType(self: *TypeChecker, expr: ast.Expression) ?ast.TypeRef {
        switch (expr.kind) {
            .ident => |name| {
                return self.variables.get(name);
            },
            .cast => |c| {
                return c.target_type;
            },
            .await_expr => |aw| {
                // Until Future<T> wrapping lands (workstream C), an async fn's
                // declared return type flows through directly, so `await e` has the
                // same type as `e`. Keeps await transparent to the type system.
                return self.resolveExprType(aw.operand.*);
            },
            .go_expr => |g| {
                // `go asyncCall()` yields a Future carrying the call's result type;
                // represented transparently as that type so `await <future>` types.
                return self.resolveExprType(g.operand.*);
            },
            .binary => |bin| {
                if (bin.op == .assign) {
                    return self.resolveExprType(bin.left.*);
                }
                // `+` with a string operand is string concatenation → string.
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
                // decimal128 arithmetic (specs §3.1 Stage 2): `decimal <op> decimal` stays `decimal`
                // for `+ - * / %`; comparisons fall through to the bool arm below. Without this the
                // result resolved to `i32`, so `let x: decimal = a + b` looked like a type mismatch.
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
                // A7 / F3 §5 stage 4b: pointer arithmetic stays a pointer. `buf + offset`
                // (address + index) is an address, not a narrowing int — typing it `ptr`
                // keeps a `let p = self.buf + i` honest so it does not become a truncation
                // site. Only for +/- (scaling a pointer); `ptr * n` etc. is nonsensical.
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
                // Comparison and LOGICAL operators (&&, ||) produce bool; bitwise
                // (&, |, via .bit_and/.bit_or), shifts and arithmetic stay numeric.
                return switch (bin.op) {
                    .eq, .ne, .lt, .gt, .le, .ge, .And, .Or => ast.TypeRef{ .ident = "bool" },
                    else => ast.TypeRef{ .ident = "i32" },
                };
            },
            .literal => |lit| {
                return switch (lit) {
                    .integer => ast.TypeRef{ .ident = "i32" },
                    .float => ast.TypeRef{ .ident = "f64" },
                    // specs §3.1: a `9.99m` literal is a decimal128 — without this the decimal-arith
                    // special-case below saw a `null`-typed operand and `let x = a / b` / a decimal
                    // return resolved to i32 (the S3 deferred quirk). Now `decimal <op> decimal` types.
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
                                    if (!field.is_public) {
                                        const in_same_struct = if (self.current_struct) |curr| std.mem.eql(u8, curr, struct_name) else false;
                                        if (!in_same_struct) {
                                            self.addError(fa.span, "Field '{s}' of struct '{s}' is private", .{ fa.field, struct_name });
                                        }
                                    }
                                    return field.type_name;
                                }
                            }
                        } else if (self.unions.get(struct_name)) |u| {
                            for (u.fields) |field| {
                                if (std.mem.eql(u8, field.name, fa.field)) {
                                    if (!field.is_public) {
                                        const in_same_struct = if (self.current_struct) |curr| std.mem.eql(u8, curr, struct_name) else false;
                                        if (!in_same_struct) {
                                            self.addError(fa.span, "Field '{s}' of union '{s}' is private", .{ fa.field, struct_name });
                                        }
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
                    // A7 / F3 §5 stage 4b: builtin receivers (`bytes`, `console`) have no
                    // .nova declaration and are not variables, so resolve them from the
                    // builtin table BEFORE the general path (which would bail at the
                    // `bytes`-is-not-a-variable lookup). This is what makes `bytes.alloc`
                    // resolve to `ptr` and flush every address-holding int.
                    if (fa.object.kind == .ident) {
                        if (builtins.find(fa.object.kind.ident, fa.field)) |b| {
                            return builtinRetType(b.ret);
                        }
                    }
                    const obj_type = self.resolveExprType(fa.object.*) orelse return null;
                    switch (obj_type) {
                        .ident => |struct_name| {
                            if (self.structs.get(struct_name)) |s| {
                                for (s.methods) |m| {
                                    if (std.mem.eql(u8, m.decl.name, fa.field)) {
                                        if (!m.is_public) {
                                            const in_same_struct = if (self.current_struct) |curr| std.mem.eql(u8, curr, struct_name) else false;
                                            if (!in_same_struct and !self.methodIsTraitContract(s, fa.field)) {
                                                self.addError(fa.span, "Method '{s}' of struct '{s}' is private", .{ fa.field, struct_name });
                                            }
                                        }
                                        return m.decl.ret_type orelse ast.TypeRef{ .ident = "void" };
                                    }
                                }
                            } else if (self.enums.get(struct_name)) |e| {
                                for (e.methods) |m| {
                                    if (std.mem.eql(u8, m.decl.name, fa.field)) {
                                        if (!m.is_public) {
                                            const in_same_struct = if (self.current_struct) |curr| std.mem.eql(u8, curr, struct_name) else false;
                                            if (!in_same_struct) {
                                                self.addError(fa.span, "Method '{s}' of enum '{s}' is private", .{ fa.field, struct_name });
                                            }
                                        }
                                        return m.decl.ret_type orelse ast.TypeRef{ .ident = "void" };
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                }
                // Bare function call foo(...) → the function's declared return type;
                // constructor call Foo(...) → the struct type.
                if (call.callee.kind == .ident) {
                    const name = call.callee.kind.ident;
                    if (self.functions.get(name)) |f| {
                        return f.ret_type orelse ast.TypeRef{ .ident = "void" };
                    }
                    if (self.structs.contains(name)) {
                        return ast.TypeRef{ .ident = name };
                    }
                }
                return null;
            },
            .generic_call => |gc| {
                // Generic constructor Foo<...>(...) → the struct type; generic
                // function call foo<...>(...) → the function's declared return type.
                if (gc.callee.kind == .ident) {
                    const name = gc.callee.kind.ident;
                    if (self.structs.contains(name)) {
                        return ast.TypeRef{ .ident = name };
                    }
                    if (self.functions.get(name)) |f| {
                        const rt = f.ret_type orelse return ast.TypeRef{ .ident = "void" };
                        // Substitute the call's type args into the declared return type, so
                        // `foo<int>()` on `fn foo<T>(): T` is `int`, not the abstract `T`.
                        return self.substReturnType(rt, f.type_params, gc.type_args);
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
            else => return null,
        }
    }

    fn checkStruct(self: *TypeChecker, s: ast.StructDecl) !void {
        self.current_struct = s.name;
        defer self.current_struct = null;
        self.checkDuplicateTypeParams(s.name, s.type_params, s.span);
        // F4/F1-6: no overloading — two methods with the same name on one struct are a redefinition
        // (codegen would emit a colliding `<Owner>_<method>` symbol). Reject, like trait methods do.
        for (s.methods, 0..) |m1, i| {
            for (s.methods[i + 1 ..]) |m2| {
                if (std.mem.eql(u8, m1.decl.name, m2.decl.name)) {
                    self.addError(m2.decl.span, "duplicate method '{s}' in '{s}' — Nova has no overloading", .{ m2.decl.name, s.name });
                }
            }
        }
        for (s.fields) |f| self.rejectUnimplementedType(f.type_name, f.span);
        for (s.methods) |m| {
            self.variables.clearRetainingCapacity();
            // A7 / F3 §5 stage 4b: register `self` up front so CONSTRUCTOR bodies (which
            // have an implicit self, no `self:` param) resolve `self.field` — otherwise
            // `self.data = bytes.alloc(...)` in an `init` is invisible and the ptr
            // truncation there slips past the check. An explicit `self:` param below
            // overrides this with its precise (possibly generic-instantiated) type.
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
            // A1 async-first seam: an `async fn` METHOD makes `spawn`/`await` legal in its
            // body, exactly like an async free fn (checkFunction). Without this the method
            // body is checked with in_async=false and every await is rejected.
            const prev_async = self.in_async;
            self.in_async = m.decl.is_async;
            try self.checkBlock(m.decl.body);
            self.in_async = prev_async;
            self.current_ret_type = prev_ret;
        }

        // Trait Implementation Checks
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
                        // A1 async-first seam: the impl's async-ness MUST match the trait's.
                        // A mismatch is unsafe — the vtable slot would hold a plain function
                        // where dynamic dispatch expects a coroutine ramp (or vice versa), and
                        // the drive/await would run a non-coroutine as one (crash).
                        if (m.decl.is_async != trait_method.is_async) {
                            self.addError(m.decl.span, "Method '{s}' in struct '{s}' must be {s} to match trait '{s}'", .{ trait_method.name, s.name, if (trait_method.is_async) "'async'" else "non-async", trait_name });
                        }
                        if (m.decl.params.len != trait_method.params.len) {
                            self.addError(m.decl.span, "Method '{s}' in struct '{s}' has parameter count mismatch with trait '{s}' (expected {d}, found {d})", .{ trait_method.name, s.name, trait_name, trait_method.params.len, m.decl.params.len });
                        } else {
                            // Generic traits: substitute the trait's type params
                            // (e.g. Q, R) with this impl's type args before comparing,
                            // so `impl Handler<GetUser, UserDto>`'s handle(req: GetUser)
                            // matches the trait's handle(req: Q).
                            const tparams = trait_decl.type_params;
                            const targs = impl.type_args;
                            for (m.decl.params, 0..) |p, i| {
                                // The receiver is always the implementing struct.
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

        for (e.methods) |m| {
            self.variables.clearRetainingCapacity();
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

fn canonicalizeTypeName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "byte") or std.mem.eql(u8, name, "ubyte")) return "i8";
    if (std.mem.eql(u8, name, "short") or std.mem.eql(u8, name, "ushort")) return "i16";
    if (std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "uint")) return "i32";
    if (std.mem.eql(u8, name, "long") or std.mem.eql(u8, name, "ulong")) return "i64";
    if (std.mem.eql(u8, name, "double")) return "f64";
    if (std.mem.eql(u8, name, "float")) return "f32";
    // `decimal` stays `decimal` — it is a distinct heap type (decimal128), not an integer.
    
    // Normalize built-in signed/unsigned names
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

fn isTypeCompatible(from: ast.TypeRef, to: ast.TypeRef) bool {
    if ((from == .ident and std.mem.eql(u8, from.ident, "any")) or
        (to == .ident and std.mem.eql(u8, to.ident, "any"))) {
        return true;
    }
    // Erased generics: a generic type and its bare-name ident are the same runtime
    // type, so `List` is compatible with `List<string>` and vice versa.
    if (from == .ident and to == .generic) {
        return std.mem.eql(u8, canonicalizeTypeName(from.ident), canonicalizeTypeName(to.generic.name));
    }
    if (from == .generic and to == .ident) {
        return std.mem.eql(u8, canonicalizeTypeName(from.generic.name), canonicalizeTypeName(to.ident));
    }
    // A concrete value of type T satisfies an optional `T | undefined`.
    if (to == .optional and from != .optional) {
        return isTypeCompatible(from, to.optional.*);
    }
    // specs §3.4b: a function declared `T | E` may return EITHER side —
    //     return "x";                     -> the ok case
    //     return DiError.NotRegistered(k) -> the err case
    // so both satisfy the union. The reverse is deliberately NOT allowed (handled below by the
    // tag check): a `T | E` does not satisfy a plain `T`, because that would let the error be
    // used as if it were the value — which is the entire point of the feature.
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
            
            // Allow implicit conversion between any two numeric types, or between numeric and custom/pointer types.
            // NOTE: this numeric<->anything permissiveness is LOAD-BEARING — Nova's uniform representation
            // stores strings/lists/structs as i32 pointers, so the stdlib routinely mixes i32 and pointer
            // types. Tightening it (e.g. requiring both sides numeric) breaks all stdlib compilation.
            // Sound assignment/return type checking needs the resolver to track Nova-level types separately
            // from their i32 representation first (A3, deeper). See conformance/expect_fail/PENDING.md.
            if (isNumericTypeName(c_from) and isNumericTypeName(c_to)) {
                return true;
            }

            return false;
        },
        .optional => |opt_from| return isTypeCompatible(opt_from.*, to.optional.*),
        // specs §3.4b: an error union is compatible only with the SAME error union. It is
        // deliberately NOT compatible with its own `ok` type — `string | DbError` must not
        // silently become a `string`; that check is the whole point of the feature.
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

// Generic-trait substitution: replace a trait type parameter name (Q, R, TReq…)
// with the concrete type argument the impl supplied, e.g. Q -> GetUser for
// `impl Handler<GetUser, UserDto>`. Bare-ident substitution covers the trait
// method signatures the flagship needs (`req: Q`, `: R`); compound forms
// (`List<Q>`, `Q | Error`) are left as-is for now.
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
