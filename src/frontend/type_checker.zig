const std = @import("std");
const ast = @import("ast.zig");
const builtins = @import("sema/builtins.zig");

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

fn isPtrTruncation(from: ast.TypeRef, to: ast.TypeRef) bool {
    if (from != .ident or to != .ident) return false;
    if (!std.mem.eql(u8, canonicalizeTypeName(from.ident), "ptr")) return false;
    const ct = canonicalizeTypeName(to.ident);
    return std.mem.eql(u8, ct, "i8") or std.mem.eql(u8, ct, "i16") or std.mem.eql(u8, ct, "i32");
}

const IntRange = struct { min: i128, max: i128 };
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

fn intWidthOf(name: []const u8) ?u32 {
    const c = canonicalizeTypeName(name);
    if (std.mem.eql(u8, c, "i8")) return 8;
    if (std.mem.eql(u8, c, "i16")) return 16;
    if (std.mem.eql(u8, c, "i32")) return 32;
    if (std.mem.eql(u8, c, "i64")) return 64;
    return null;
}

fn isNarrowingInt(from: ast.TypeRef, to: ast.TypeRef) bool {
    if (from != .ident or to != .ident) return false;
    const fw = intWidthOf(from.ident) orelse return false;
    const tw = intWidthOf(to.ident) orelse return false;
    return fw > tw;
}

fn intNameSigned(name: []const u8) bool {
    return !(std.mem.startsWith(u8, name, "u") or std.mem.eql(u8, name, "byte"));
}

fn isSignednessMismatch(from: ast.TypeRef, to: ast.TypeRef) bool {
    if (from != .ident or to != .ident) return false;
    const fw = intWidthOf(from.ident) orelse return false;
    const tw = intWidthOf(to.ident) orelse return false;
    if (fw != tw) return false;
    return intNameSigned(from.ident) != intNameSigned(to.ident);
}

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

// F4-1 helpers: validate explicit struct-literal type args (`Foo<int>{ ... }`).
fn identOf(tr: ast.TypeRef) ?[]const u8 {
    return switch (tr) {
        .ident => |n| n,
        else => null,
    };
}

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

// True only for the memory-unsafe clash: one side is `string` (a heap pointer) and the other is a
// scalar primitive. That is the case that miscompiles into a pointer<->scalar reinterpret (stores an
// int where a string pointer is expected -> deref garbage). Kept deliberately narrow so tightening the
// check never false-positives on int<->long widening, optionals, `any`, or trait widening.
fn stringScalarClash(a: ast.TypeRef, b: ast.TypeRef) bool {
    const an = identOf(a) orelse return false;
    const bn = identOf(b) orelse return false;
    const a_str = std.mem.eql(u8, an, "string");
    const b_str = std.mem.eql(u8, bn, "string");
    if (a_str and isScalarPrim(bn)) return true;
    if (b_str and isScalarPrim(an)) return true;
    return false;
}

/// A structured, span-carrying diagnostic, kept alongside the pretty-printed
/// `errors` strings so tooling (the language server) can map each error back to
/// a source range instead of scraping the ANSI-formatted text. The message here
/// is the plain, human-readable text with no terminal colour codes.
pub const Diagnostic = struct {
    file: []const u8,
    /// Byte offset of the reported node's start (reliable, unlike span.end).
    start: usize,
    line: usize,
    col: usize,
    message: []const u8,
};

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList([]const u8),
    /// Span-carrying view of the same errors, for tooling (see `Diagnostic`).
    structured: std.ArrayList(Diagnostic),
    /// When true, `check` does not print the failure summary to stderr. The
    /// language server sets this so its stderr stays clean; the CLI leaves it off.
    silent: bool = false,
    file_sources: *std.StringHashMap([]const u8),
    enums: std.StringHashMap(ast.EnumDecl),
    variables: std.StringHashMap(ast.TypeRef),
    structs: std.StringHashMap(ast.StructDecl),
    // Struct names defined in MORE THAN ONE module (e.g. stdlib db.nova `Cursor` vs a driver's
    // `Cursor`). `structs` is a flat name->decl map (last writer wins), so it cannot tell which
    // module a bare `Cursor(...)` at a given call site means. The authoritative sema pass resolves
    // that module-correctly; the legacy arity/narrowing checks below would validate against the
    // WRONG decl, so they skip colliding names.
    colliding_structs: std.StringHashMap(void),
    // Same as colliding_structs but for enums: a same-named enum in another module. The exhaustiveness
    // check keys enums by bare name, so it would validate one module's switch against the OTHER module's
    // variant set. Defer to the authoritative sema pass for colliding enums (S3).
    colliding_enums: std.StringHashMap(void),
    unions: std.StringHashMap(ast.UnionDecl),
    traits: std.StringHashMap(ast.TraitDecl),
    functions: std.StringHashMap(ast.FunctionDecl),

    ambiguous_fns: std.StringHashMap(void),

    fn_def_sites: std.StringHashMap(void),
    fn_first_line: std.StringHashMap(usize) = undefined,
    current_struct: ?[]const u8,
    current_ret_type: ?ast.TypeRef = null,

    in_async: bool = false,

    in_awaited: bool = false,

    is_wasm: bool = false,

    pub fn init(allocator: std.mem.Allocator, file_sources: *std.StringHashMap([]const u8)) TypeChecker {
        return TypeChecker{
            .allocator = allocator,
            .errors = std.ArrayList([]const u8).empty,
            .structured = std.ArrayList(Diagnostic).empty,
            .file_sources = file_sources,
            .enums = std.StringHashMap(ast.EnumDecl).init(allocator),
            .variables = std.StringHashMap(ast.TypeRef).init(allocator),
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
        for (self.structured.items) |d| {
            self.allocator.free(d.message);
        }
        self.structured.deinit(self.allocator);
        self.enums.deinit();
        self.variables.deinit();
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

    fn addError(self: *TypeChecker, span: ast.Span, comptime fmt: []const u8, args: anytype) void {
        const user_msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(user_msg);

        // Keep a span-carrying copy for tooling (the language server maps these
        // onto editor ranges). Best-effort: a failed dupe just skips the entry.
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

    // Detect value structs whose fields transitively contain the struct itself BY VALUE (infinite size).
    // The by-value edge is a bare `.ident` field whose type is another declared VALUE struct; a `class`
    // field (heap reference), an optional, a container/generic, a tuple, a function, or an array field all
    // introduce indirection and break the cycle. Colours: 0 unvisited, 1 on the current DFS stack, 2 done.
    fn checkValueStructCycles(self: *TypeChecker) void {
        var state = std.StringHashMap(u8).init(self.allocator);
        defer state.deinit();
        var it = self.structs.iterator();
        while (it.next()) |e| {
            const sd = e.value_ptr.*;
            if (sd.is_reference) continue; // only value structs can be inline/infinite
            if ((state.get(sd.name) orelse 0) == 0) self.dfsValueStructCycle(sd.name, &state);
        }
    }

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
                    else => continue, // optional/generic/tuple/func/array -> indirection, breaks the cycle
                };
                const cd = self.structs.get(child) orelse continue;
                if (cd.is_reference) continue; // a `class` field is a pointer, not inline
                if (self.colliding_structs.contains(child)) continue; // ambiguous cross-module name; defer
                switch (state.get(child) orelse 0) {
                    1 => self.addError(fld.span, "value struct '{s}' contains itself by value through field '{s}: {s}' — a `struct` stored inline cannot form a cycle (infinite size). Make one of the types a `class` (a heap reference), or hold it behind an optional or a container.", .{ name, fld.name, child }),
                    0 => self.dfsValueStructCycle(child, state),
                    else => {},
                }
            }
        }
        state.put(name, 2) catch {};
    }

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
                // A same-named struct from a DIFFERENT module is a collision (module scoping lets
                // them coexist). Record it so the flat-map arity/narrowing checks below defer to sema.
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

        // A `struct` (value type) that transitively contains ITSELF by value has infinite size and is
        // unsound (it was silently accepted before, then mislaid out or crashed on use). Reject it here.
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
        const t = self.resolveExprType(cond) orelse return;
        if (t != .ident) return;
        const n = t.ident;

        if (std.mem.eql(u8, n, "string") or std.mem.eql(u8, n, "i32") or
            std.mem.eql(u8, n, "f64") or std.mem.eql(u8, n, "i64"))
        {
            self.addError(span, "condition must be a bool, got '{s}'", .{n});
        }
    }

    // Does executing this statement GUARANTEE the function returns/diverges (never falls through to the
    // next statement)? Conservative: anything uncertain answers TRUE so a valid function is never flagged.
    // In particular an expr-statement (which may be a call that panics/exits/throws) and loops/switch are
    // treated as returning; only a `let`/`break`/`continue`/`defer`, or an `if` without a returning `else`,
    // clearly falls through.
    fn stmtDefinitelyReturns(self: *TypeChecker, stmt: ast.Statement) bool {
        return switch (stmt) {
            .return_stmt => true,
            .block => |b| self.blockDefinitelyReturns(b),
            .if_stmt => |ifs| blk: {
                const eb = ifs.else_branch orelse break :blk false; // no else -> can fall through
                break :blk self.stmtDefinitelyReturns(ifs.then_branch.*) and self.stmtDefinitelyReturns(eb.*);
            },
            .while_stmt, .for_stmt, .switch_stmt => true, // may diverge or be exhaustive -> never flag
            .expr_stmt => true, // may be a call that panics/exits/throws -> never flag a call ending
            .let_stmt, .break_stmt, .continue_stmt, .defer_stmt => false,
        };
    }

    fn blockDefinitelyReturns(self: *TypeChecker, b: ast.Block) bool {
        if (b.statements.len == 0) return false;
        return self.stmtDefinitelyReturns(b.statements[b.statements.len - 1]);
    }

    fn checkFunction(self: *TypeChecker, func: ast.FunctionDecl) anyerror!void {
        self.checkDuplicateTypeParams(func.name, func.type_params, func.span);
        self.variables.clearRetainingCapacity();

        for (func.params) |param| {
            if (param.type_name) |t| {
                self.rejectUnimplementedType(t, param.span, func.type_params, true);
                try self.variables.put(param.name, t);
            }
        }
        if (func.ret_type) |rt| self.rejectUnimplementedType(rt, func.span, func.type_params, true);

        // Missing-return: a non-void function whose body can fall off the end returns garbage on that path.
        // Only for a concrete non-void return, an in-repo body (not extern), and using the conservative
        // "definitely returns" analysis above so nothing valid is flagged.
        if (func.extern_lib == null) {
            if (func.ret_type) |rt| {
                const is_voidish = rt == .ident and (std.mem.eql(u8, rt.ident, "void") or std.mem.eql(u8, rt.ident, "any"));
                if (!is_voidish and !self.blockDefinitelyReturns(func.body)) {
                    self.addError(func.span, "function '{s}' has return type '{s}' but can finish without returning a value — add a `return` on every path (or an ending loop/return)", .{ func.name, typeRefName(rt) });
                }
            }
        }

        if (self.is_wasm and func.is_async) {
            self.addError(func.span, "'async fn {s}' is not available on the wasm target — async has no coroutine runtime in wasm. Move it into a `@native {{ ... }}` block (and provide a synchronous or host-imported `@wasm {{ ... }}` alternative).", .{func.name});
        }
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

    // A type name is KNOWN if it is a builtin primitive, an in-scope type parameter, `Self`, or a declared
    // struct/trait/enum/union (all modules are merged before checking, so imported types are registered).
    fn isKnownTypeName(self: *TypeChecker, name: []const u8, tparams: []const []const u8) bool {
        for (tparams) |tp| if (std.mem.eql(u8, name, tp)) return true;
        if (std.mem.eql(u8, name, "Self")) return true;
        const c = canonicalizeTypeName(name); // int->i32, long->i64, byte->i8, ...
        const builtin_types = [_][]const u8{
            "i8", "i16", "i32", "i64", "i128", "f32", "f64", "bool", "string", "void",
            "any", "char", "ptr", "uptr", "usize", "isize", "never", "unit", "decimal", "byte",
            "future", "channel", // compiler builtin generics (future<T> is special-cased in sema/lower)
            "u8x16", "u32x4", "u64x2", "f64x4", // FR-simd-L1 SIMD vector types (spellable, see sema/lower)
        };
        for (builtin_types) |b| if (std.mem.eql(u8, c, b) or std.mem.eql(u8, name, b)) return true;
        return self.structs.contains(name) or self.traits.contains(name) or self.enums.contains(name) or
            self.unions.contains(name) or self.structs.contains(c);
    }

    // `check_unknown` gates the undefined-type rejection: true only where the type-param scope handed in
    // `tparams` is exactly right (top-level function signatures and struct fields). Elsewhere (e.g. a `let`
    // annotation inside a generic method, whose type params are not threaded here) it stays false so the
    // pass keeps its original i128-only behavior and can never false-flag an in-scope type parameter.
    fn rejectUnimplementedType(self: *TypeChecker, t: ast.TypeRef, span: ast.Span, tparams: []const []const u8, check_unknown_in: bool) void {
        // Never flag unknowns in COMPILER-GENERATED sources (`<mediator-generated>` etc.): they reference
        // framework types the generator knows are valid, and are not user-authored, so a diagnostic there is
        // noise. The i128 removal check still runs everywhere.
        const check_unknown = check_unknown_in and !(span.file.len > 0 and span.file[0] == '<');
        switch (t) {
            .ident => |n| {
                if (std.mem.eql(u8, n, "i128") or std.mem.eql(u8, n, "u128")) {
                    self.addError(span, "type '128-bit integer' was removed (F3 §3.1); use 'long' or 'i64'", .{});
                    return;
                }
                if (check_unknown and !self.isKnownTypeName(n, tparams)) {
                    self.addError(span, "unknown type '{s}' — not a primitive, type parameter, or declared struct/enum/trait", .{n});
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
                    self.addError(span, "unknown type '{s}' — not a primitive, type parameter, or declared struct/enum/trait", .{g.name});
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

    fn structImplementsTrait(self: *TypeChecker, struct_name: []const u8, trait_name: []const u8) bool {
        const base = canonicalizeTypeName(struct_name);
        const s = self.structs.get(base) orelse return false;
        for (s.impls) |impl| {
            if (std.mem.eql(u8, impl.name, trait_name)) return true;
        }
        return false;
    }

    // Reject instantiating a bounded type parameter with a concrete type that does not satisfy the bound.
    // For each `where TP: TraitA + TraitB`, resolve TP to its concrete type argument and require that a
    // KNOWN struct declares each KNOWN trait (`struct S impl TraitA`). Deliberately conservative to stay
    // additive (never rejects a program that compiled before): a bound whose concrete arg is a primitive, a
    // type parameter, or an unknown name is skipped, as is a bound naming an unknown trait. `structImplements
    // Trait` is nominal, matching how Nova structs declare conformance, so this cannot false-flag a real impl.
    fn checkGenericBounds(self: *TypeChecker, decl_name: []const u8, type_params: []const []const u8, where_bounds: []const ast.WhereBound, type_args: []const ast.TypeRef, span: ast.Span) void {
        for (where_bounds) |wb| {
            // Position of the constrained type parameter among the declared parameters.
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
            // Only enforce against a KNOWN, non-colliding struct. A primitive / type-parameter / unknown name
            // is left to the structural used-bound path and never newly rejected here.
            const cbase = canonicalizeTypeName(cname);
            if (!self.structs.contains(cbase)) continue;
            if (self.colliding_structs.contains(cbase)) continue;
            for (wb.traits) |trait_name| {
                if (trait_name.len == 0) continue;
                if (!self.traits.contains(trait_name)) continue; // unknown/advisory bound: do not enforce
                if (!self.structImplementsTrait(cbase, trait_name)) {
                    self.addError(span, "type argument '{s}' does not satisfy the bound '{s}: {s}' on generic '{s}' (struct '{s}' does not implement trait '{s}')", .{ cname, wb.type_param, trait_name, decl_name, cname, trait_name });
                }
            }
        }
    }

    // Reject a call argument whose scalar CATEGORY differs from the parameter's (a string where an int is
    // expected, a bool where a string is expected, ...). Without this the arg's bits are silently read as
    // the wrong scalar at runtime -- e.g. `f("hi")` for `f(a: int)` printed a garbage 33914905. Deliberately
    // narrow: fires ONLY when BOTH arg and param resolve to KNOWN scalar primitives in DIFFERENT categories,
    // so structs, generics/type-params, traits, optionals, `any`, and all numeric-vs-numeric pairs are left
    // to the existing `assignable`/narrowing rules and can never be false-flagged here.
    fn checkArgTypes(self: *TypeChecker, args: []const ast.Expression, params: []const ast.Param, call_span: ast.Span) void {
        const n = @min(args.len, params.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const pt = params[i].type_name orelse continue;
            if (pt != .ident) continue;
            const pcat = primCategory(pt.ident);
            if (pcat == .other) continue; // param is not a scalar primitive -> not our concern
            if (intLiteralValue(args[i]) != null) continue; // an int/float literal is fine for any numeric param
            const at = self.resolveExprType(args[i]) orelse continue;
            if (at != .ident) continue;
            const acat = primCategory(at.ident);
            if (acat == .other) continue; // arg type not a known scalar primitive -> skip (conservative)
            if (acat != pcat) {
                const sp = if (args[i].span.line != 0) args[i].span else call_span;
                self.addError(sp, "argument {d}: cannot pass '{s}' where parameter '{s}: {s}' expects '{s}'", .{ i + 1, typeRefName(at), params[i].name, typeRefName(pt), typeRefName(pt) });
            }
        }
    }

    // Reject implicit TRAIT -> CONCRETE narrowing for each (arg, param) pair. A trait value is a fat
    // pointer {struct_ptr, vtable} that may hold ANY implementation, so it cannot be silently treated as a
    // specific concrete struct (previously miscompiled into a use-after-free). Require an explicit `as`
    // downcast, or a trait-typed parameter. Concrete -> trait widening stays allowed. Shared by free-function
    // calls and method calls so the rejection is uniform across both callee shapes.
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
                self.addError(args[i].span, "cannot pass a trait object '{s}' to concrete parameter '{s}: {s}' — a trait value may hold any implementation, so narrowing it needs an explicit downcast ('<expr> as {s}'), or the parameter should take the trait type '{s}'", .{ at.ident, params[i].name, pt.ident, pt.ident, at.ident });
            }
        }
    }

    // Same narrowing rejection for a GENERIC method call (e.g. List<Dog>.push(traitVal)): a method param typed
    // as a type-parameter (T) is substituted with the receiver's instantiation arg (Dog) before the check, so
    // pushing a trait into a List<Concrete> is caught (it otherwise miscompiles -- the trait fat pointer gets
    // stored as the concrete element and reads garbage). Concrete->trait widening (List<Trait>) stays allowed.
    fn rejectNarrowingArgsSubst(self: *TypeChecker, args: []const ast.Expression, params: []const ast.Param, tparams: []const []const u8, targs: []const ast.TypeRef) void {
        const npairs = @min(args.len, params.len);
        var i: usize = 0;
        while (i < npairs) : (i += 1) {
            var pt = params[i].type_name orelse continue;
            if (pt != .ident) continue;
            // Substitute a type-parameter name (T) with the instantiation's concrete type arg.
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
                self.addError(args[i].span, "cannot pass a trait object '{s}' to a concrete element/parameter of type '{s}' — a trait value may hold any implementation, so narrowing it needs an explicit downcast ('<expr> as {s}')", .{ at.ident, pt.ident, pt.ident });
            }
        }
    }

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
                // L3/C-chk-7: tuple destructuring `let (a,b,...) = e` must bind exactly as many names as
                // the tuple has elements; a mismatch bound garbage. Bind each name to its element type.
                if (ls.names) |names| {
                    if (ls.init) |init_expr| {
                        if (self.resolveExprType(init_expr)) |it| {
                            if (it == .tuple) {
                                const arity = it.tuple.len;
                                if (names.len != arity) {
                                    self.addError(ls.span, "tuple destructuring binds {d} name(s) but the tuple has {d} element(s) — the counts must match", .{ names.len, arity });
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
                                        self.addError(ls.span, "integer literal {d} is out of range for '{s}' — use a wider type (e.g. 'long') or an explicit cast", .{ v, t.ident });
                                    }
                                }
                            }
                        }

                        const init_is_int_literal = intLiteralValue(init_expr) != null;
                        if (self.resolveExprType(init_expr)) |init_t| {

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

    fn structInitParamCount(self: *TypeChecker, struct_name: []const u8) ?usize {
        const s = self.structs.get(struct_name) orelse return null;
        for (s.methods) |m| {
            if (std.mem.eql(u8, m.decl.name, "init")) {
                return m.decl.params.len;
            }
        }
        return null;
    }

    // The `init` constructor's parameters (constructor args align 1:1, no implicit self). Used to reject an
    // implicit trait->concrete narrowing passed to a CONSTRUCTOR arg -- the same unsound path as a free/method
    // call arg, just via `StructName(traitValue)` where the init parameter is a concrete struct.
    fn structInitParams(self: *TypeChecker, struct_name: []const u8) ?[]ast.Param {
        const s = self.structs.get(struct_name) orelse return null;
        for (s.methods) |m| {
            if (std.mem.eql(u8, m.decl.name, "init")) return m.decl.params;
        }
        return null;
    }

    fn checkExpr(self: *TypeChecker, expr: ast.Expression) anyerror!void {
        switch (expr.kind) {
            .generic_call => |gc| {
                const awaited_here = self.in_awaited;
                self.in_awaited = false;
                if (self.in_async and !awaited_here and self.callTargetsAsync(gc.callee.*)) {
                    self.addError(gc.span, "async call must be 'await'ed (or 'spawn'ed) inside an 'async fn' — a bare call block-drives the coroutine and would deadlock the event loop", .{});
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

                    // Enforce declared `where T: Trait` bounds against the EXPLICIT type arguments, even when
                    // the generic body never calls the bounded method (the unused-bound case). Conservative:
                    // only rejects when the concrete argument is a KNOWN struct that does NOT declare the
                    // required KNOWN trait -- primitives, type parameters, and unknown names are left alone so
                    // no currently-valid program is newly rejected.
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
                    self.addError(c.span, "async call must be 'await'ed (or 'spawn'ed) inside an 'async fn' — a bare call block-drives the coroutine and would deadlock the event loop", .{});
                }

                if (c.callee.kind == .ident) {
                    const name = c.callee.kind.ident;

                    if (!self.variables.contains(name) and self.structs.contains(name) and !self.colliding_structs.contains(name)) {
                        if (self.structInitParamCount(name)) |init_params| {
                            if (c.args.len != init_params) {
                                self.addError(c.span, "constructor '{s}' expects {d} argument(s), got {d}", .{ name, init_params, c.args.len });
                            }
                        }
                        // Soundness: a constructor arg passed to a CONCRETE init parameter cannot be a trait
                        // object (same unsound trait->concrete narrowing as a call arg -- e.g. Holder(traitVal)
                        // where init(d: Dog)). Reject it; require an explicit `as` downcast.
                        if (self.structInitParams(name)) |ip| { self.rejectNarrowingArgs(c.args, ip); self.checkArgTypes(c.args, ip, c.span); }
                    }
                    if (!self.ambiguous_fns.contains(name) and !self.variables.contains(name)) {
                        if (self.functions.get(name)) |f| {
                            if (c.args.len != f.params.len) {
                                self.addError(c.span, "function '{s}' expects {d} argument(s), got {d}", .{ name, f.params.len, c.args.len });
                            }
                            // Soundness: reject an implicit TRAIT -> CONCRETE narrowing at a call argument.
                            // A trait value is a fat pointer {struct_ptr, vtable}; a concrete parameter
                            // expects the bare struct, and the trait may hold ANY implementation. Passing it
                            // implicitly is unsound (and previously miscompiled into a use-after-free). Make
                            // the intent explicit with a downcast. Concrete -> trait widening stays allowed.
                            self.rejectNarrowingArgs(c.args, f.params);
                            self.checkArgTypes(c.args, f.params, c.span);
                        }
                    }

                    if (self.ambiguous_fns.contains(name) and !self.variables.contains(name) and !self.structs.contains(name) and !self.fileDefinesFn(c.span.file, name)) {
                        self.addError(c.span, "call to '{s}' is ambiguous — more than one function is named '{s}' across the imported modules. Qualify it (e.g. `module.{s}(...)`).", .{ name, name, name });
                    }
                } else if (c.callee.kind == .field_access) {
                    // Same soundness rule for METHOD calls: `obj.method(traitArg)` where the method parameter
                    // is a concrete struct. Resolve the receiver's struct, find the method, and align the args
                    // with its parameters (skipping the implicit `self` at index 0).
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
                            // Generic receiver (e.g. List<Dog>): substitute the struct's type params with the
                            // instantiation args before the narrowing check, so pushing a trait into a
                            // List<Concrete> is rejected.
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
                // coroStart(<async call>) detaches (spawns) the coroutine — like `spawn`, it consumes the
                // async call rather than block-driving it, so a bare async call passed to coroStart inside
                // an async fn is allowed (the reactor drives the detached coroutine).
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
                                self.addError(b.span, "pointer truncation: a 'ptr' (raw address) cannot be stored into '{s}' — type the target 'ptr' (F3 §3.2)", .{typeRefName(lt)});
                            } else if (isNarrowingInt(rt, lt)) {
                                self.addError(b.span, "narrowing conversion: '{s}' cannot be implicitly stored into '{s}' — use an explicit cast (F3 §6)", .{ typeRefName(rt), typeRefName(lt) });
                            } else if (isSignednessMismatch(rt, lt)) {
                                self.addError(b.span, "signedness mismatch: '{s}' and '{s}' differ in sign — use an explicit cast (F3 §6)", .{ typeRefName(rt), typeRefName(lt) });
                            } else if (rt == .ident and lt == .ident and
                                self.traits.contains(rt.ident) and self.structs.contains(lt.ident) and
                                !self.traits.contains(lt.ident) and !std.mem.eql(u8, rt.ident, lt.ident))
                            {
                                // Soundness (L1): a trait object cannot be implicitly narrowed to a concrete
                                // struct on assignment (same UAF class as a call/constructor arg).
                                self.addError(b.span, "cannot assign a trait object '{s}' to a concrete '{s}' target — a trait value may hold any implementation, so narrowing it needs an explicit downcast ('<expr> as {s}')", .{ rt.ident, lt.ident, lt.ident });
                            }
                        }
                    }
                }
            },
            .literal => |lit| {
                // Fixed arrays are PRIMITIVES ONLY. Elements are stored as the raw 8-byte value-word
                // with no per-element ARC, so a reference/complex element (struct, string, trait) would
                // be reinterpreted as an integer and read back as garbage. Reject it with a pointer to
                // List<T>, which owns its elements. (Value primitives: int/long/double/float/bool/byte.)
                if (lit == .array) {
                    for (lit.array) |*elem| {
                        try self.checkExpr(elem.*);
                        // Reject by resolved type when known...
                        if (self.resolveExprType(elem.*)) |et| {
                            if (et != .ident or !isScalarPrim(et.ident)) {
                                self.addError(expr.span, "array elements must be a primitive type (int, long, double, float, bool, byte); got '{s}' — use List for reference or complex element types", .{typeRefName(et)});
                                break;
                            }
                        } else if (elem.kind == .struct_init or elem.kind == .tuple or
                            (elem.kind == .literal and elem.kind.literal == .array))
                        {
                            // ...and by form for the non-primitive constructors the checker cannot
                            // resolve to a name (a struct/tuple/nested-array element is a reference/
                            // aggregate, stored as a raw word -> read back as garbage).
                            self.addError(expr.span, "array elements must be a primitive type (int, long, double, float, bool, byte); a struct, tuple, or nested array is not allowed — use List for those", .{});
                            break;
                        }
                    }
                } else if (lit == .array_repeat) {
                    try self.checkExpr(lit.array_repeat.value.*);
                    const v = lit.array_repeat.value.*;
                    if (self.resolveExprType(v)) |et| {
                        if (et != .ident or !isScalarPrim(et.ident)) {
                            self.addError(expr.span, "array elements must be a primitive type (int, long, double, float, bool, byte); got '{s}' — use List for reference or complex element types", .{typeRefName(et)});
                        }
                    } else if (v.kind == .struct_init or v.kind == .tuple or (v.kind == .literal and v.kind.literal == .array)) {
                        self.addError(expr.span, "array elements must be a primitive type (int, long, double, float, bool, byte); a struct, tuple, or nested array is not allowed — use List for those", .{});
                    }
                }
            },
            .unary => |u| try self.checkExpr(u.operand.*),
            .field_access => |fa| try self.checkExpr(fa.object.*),
            .index => |idx| {
                try self.checkExpr(idx.object.*);
                try self.checkExpr(idx.index.*);
                // L1/K6: reject `[]` on a definitely-non-indexable type (a scalar, user struct, or enum).
                // Fail-open on unknowns/type-params/generics so valid generic code is never rejected.
                if (self.resolveExprType(idx.object.*)) |obj_ty| {
                    if (self.indexableTypeStatus(obj_ty)) |ok| {
                        if (!ok) self.addError(idx.object.*.span, "cannot index a value of type '{s}' with `[]` — `[]` is only valid on strings, arrays, tuples, and byte buffers (List/Map use `.get`)", .{typeRefName(obj_ty)});
                    }
                }
            },
            .struct_init => |si| {
                for (si.fields) |field| try self.checkExpr(field.value);

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

                    // F4-1: explicit type args (`Foo<int>{ ... }`) are now carried on the AST. Validate
                    // them: arity against the struct's type params, then — for each field whose declared
                    // type is one of those params — reject a value that clashes with the bound arg. The
                    // clash check is narrow (string vs scalar, the memory-unsafe case) on purpose; once a
                    // contradiction is an error, survivors agree with field inference, so monomorphization
                    // stays correct without any further rewiring.
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
                                    const b = bound orelse break; // field type is concrete, not a param
                                    const actual = self.resolveExprType(lf.value) orelse break;
                                    if (stringScalarClash(b, actual)) {
                                        self.addError(lf.span, "type argument mismatch: field '{s}' has type '{s}' (from explicit '{s}<…>'), but the value is '{s}'", .{ lf.name, identOf(b) orelse "?", si.type_name, identOf(actual) orelse "?" });
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
                    self.addError(aw.span, "'await' is not available on the wasm target — async/await has no coroutine runtime in wasm. Guard native code with `@native {{ ... }}` and provide a wasm path with `@wasm {{ ... }}`.", .{});
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
                    self.addError(g.span, "'spawn' is not available on the wasm target — there is no coroutine runtime in wasm. Guard native code with `@native {{ ... }}`.", .{});
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

    // The enum named by a case value of the form `Enum.Variant` or `Enum.Variant(..)`. Used to recover the
    // switched enum when the discriminant's own type could not be resolved, so exhaustiveness is still checked.
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

    // Coverage-only exhaustiveness check (no payload binding) for a switch whose discriminant type could not
    // be resolved but whose cases name a known enum. Every non-guarded case that names a variant covers it; an
    // uncovered variant with no `default` is an error. Additive: fires only for a genuine enum switch that is
    // missing a variant, so an integer/other switch (literal case values) never triggers it.
    fn checkEnumCoverageOnly(self: *TypeChecker, enum_name: []const u8, ss: ast.SwitchStmt) anyerror!void {
        const enum_decl = self.enums.get(enum_name) orelse return;
        if (ss.default_case != null) return; // a default handles every remaining variant
        var covered = std.StringHashMap(bool).init(self.allocator);
        defer covered.deinit();
        for (enum_decl.variants) |v| try covered.put(v.name, false);
        for (ss.cases) |case| {
            if (case.guard != null) continue; // a guarded case may not match -> does not satisfy exhaustiveness
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

    fn checkSwitch(self: *TypeChecker, ss: ast.SwitchStmt) anyerror!void {
        const disc_type = self.resolveExprType(ss.discriminant) orelse {
            // Untypeable discriminant: still enforce exhaustiveness if the cases name a known enum. This closes
            // the fail-open edge where an unresolved discriminant skipped the exhaustiveness check entirely.
            if (self.recoverEnumFromCases(ss.cases)) |en| try self.checkEnumCoverageOnly(en, ss);
            return;
        };

        switch (disc_type) {
            .ident => |enum_name| {
                // A colliding enum's bare-name entry may be the WRONG module's decl, so exhaustiveness
                // here would report phantom "unhandled variant" errors. Sema resolves it module-correctly.
                if (self.colliding_enums.contains(enum_name)) return;
                if (self.enums.get(enum_name)) |enum_decl| {
                    const variants = enum_decl.variants;
                    var covered = std.StringHashMap(bool).init(self.allocator);
                    defer covered.deinit();

                    for (variants) |v| {
                        try covered.put(v.name, false);
                    }

                    for (ss.cases) |case| {
                        // A guarded case may not match even when its value does, so it does NOT satisfy
                        // exhaustiveness -- the switch still needs a `default`.
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
                                                    // Tuple-form multi-payload pattern `Rect(w, h)`: bind each
                                                    // positional binding to the matching payload field's type.
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
                        // The guard is checked after the payload bindings it may reference are in scope.
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
                    // A switch lowers to an LLVM integer switch, so only enums and integer types are
                    // valid discriminants. Strings/floats/structs used to compile to garbage (every
                    // case label collapsed to 0 -> a "duplicate switch case" verifier crash or the
                    // wrong branch). Reject them loudly instead.
                    self.addError(ss.span, "switch discriminant must be an enum or integer type, got '{s}' — use if/else chains for strings and other types", .{enum_name});
                }
            },
            else => {},
        }
    }

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

    // Unify a declared parameter type against an actual argument type, binding any type parameters it
    // names (`v: T` binds T; `xs: List<T>` binds T against a `List<Dog>` argument, etc.). Writes into
    // `binds` (parallel to `tparams`); a param already bound is left as-is (first binding wins).
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

    // Infer the type arguments of a generic function call from its argument types (no explicit `<T>`).
    // Returns a slice parallel to `f.type_params`, or null if any parameter could not be bound (leave
    // the return type unresolved rather than guess). Enables `let x: int = id(42)` where `id<T>(v: T): T`
    // -- inference INTO a typed let, which previously returned the raw `T` and failed the compat check (B1-let).
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

    // L1/K6 fail-closed index check: is `[]` valid on a value of this type? Returns true (indexable),
    // false (definitely NOT -- reject), or null (unknown / type-param -- allow, stay fail-open). `[]` is
    // valid on string, ptr/byte buffers, fixed arrays, and tuples; List/Map are indexed via `.get`, not
    // `[]`, so a plain struct/enum/scalar is never `[]`-indexable.
    fn indexableTypeStatus(self: *TypeChecker, tr: ast.TypeRef) ?bool {
        return switch (tr) {
            .fixed_array, .tuple => true,
            .ident => |name| blk: {
                const n = canonicalizeTypeName(name);
                if (std.mem.eql(u8, n, "string") or std.mem.eql(u8, n, "ptr") or
                    std.mem.eql(u8, n, "bytes") or std.mem.eql(u8, n, "RawBuffer")) break :blk true;
                if (isScalarPrimitiveName(n)) break :blk false;
                if (self.structs.contains(name) or self.enums.contains(name)) break :blk false;
                break :blk null; // unknown / type-param -> allow
            },
            else => null, // generic (List/Map use .get), optional, error_union, func -> do not reject
        };
    }

    // Module-private visibility (§8): a non-`pub` member is accessible from anywhere in the SAME MODULE
    // (source file) as its declaration, not only from within the declaring type's own methods. Cross-module
    // access still requires `pub`. This matches how Nova is actually used (a same-file test reads a non-pub
    // field, e.g. corpus 260). `decl_file`/`access_file` come from the decl's and the access's spans.
    fn memberAccessible(self: *TypeChecker, decl_file: []const u8, access_file: []const u8, type_name: []const u8) bool {
        if (std.mem.eql(u8, decl_file, access_file)) return true; // same module
        if (self.current_struct) |curr| {
            if (std.mem.eql(u8, curr, type_name)) return true; // within the type's own methods
        }
        return false;
    }

    fn resolveExprType(self: *TypeChecker, expr: ast.Expression) ?ast.TypeRef {
        switch (expr.kind) {
            .ident => |name| {
                return self.variables.get(name);
            },
            // An inferred `let p = P{...}` / `E.Variant(...)` binds p to the named type, so index/other
            // checks that resolve the variable's type see the struct/enum. Safe now that privacy is
            // module-private (same-file member access no longer false-fires; L1/K6 inferred case is caught).
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
                                        self.addError(fa.span, "Field '{s}' of struct '{s}' is private — it is accessible only within its own module (add `pub` to use it across modules)", .{ fa.field, struct_name });
                                    }
                                    return field.type_name;
                                }
                            }
                        } else if (self.unions.get(struct_name)) |u| {
                            for (u.fields) |field| {
                                if (std.mem.eql(u8, field.name, fa.field)) {
                                    if (!field.is_public and !self.memberAccessible(u.span.file, fa.span.file, struct_name)) {
                                        self.addError(fa.span, "Field '{s}' of union '{s}' is private — it is accessible only within its own module (add `pub` to use it across modules)", .{ fa.field, struct_name });
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
                        // Module-qualified constructor: `module.StructName(...)` -> StructName. The object
                        // is a module (not a typed value, so it resolves to null) and the field names a
                        // struct. Without this, any value derived from such a constructor (e.g.
                        // `let d = novadb.NovaDriver()`) stays untyped, which blocks later type checks.
                        if (self.structs.contains(fa.field)) return ast.TypeRef{ .ident = fa.field };
                        return null;
                    };
                    switch (obj_type) {
                        .ident => |struct_name| {
                            if (self.structs.get(struct_name)) |s| {
                                for (s.methods) |m| {
                                    if (std.mem.eql(u8, m.decl.name, fa.field)) {
                                        if (!m.is_public and !self.memberAccessible(s.span.file, fa.span.file, struct_name) and !self.methodIsTraitContract(s, fa.field)) {
                                            self.addError(fa.span, "Method '{s}' of struct '{s}' is private — it is accessible only within its own module (add `pub` to use it across modules)", .{ fa.field, struct_name });
                                        }
                                        return m.decl.ret_type orelse ast.TypeRef{ .ident = "void" };
                                    }
                                }
                            } else if (self.enums.get(struct_name)) |e| {
                                for (e.methods) |m| {
                                    if (std.mem.eql(u8, m.decl.name, fa.field)) {
                                        if (!m.is_public and !self.memberAccessible(e.span.file, fa.span.file, struct_name)) {
                                            self.addError(fa.span, "Method '{s}' of enum '{s}' is private — it is accessible only within its own module (add `pub` to use it across modules)", .{ fa.field, struct_name });
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
                        // A generic function called without explicit `<T>` (inference): resolve the return
                        // type by inferring the type args from the arguments, so a typed context can check
                        // against the concrete type instead of the raw type-parameter (B1-let).
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
                        // Carry the type args on the constructed type (e.g. Box<Dog> -> .generic) so downstream
                        // checks -- notably generic-method narrowing (List<Dog>.push(traitVal)) -- can see the
                        // instantiation. Bare (non-generic) constructors stay .ident.
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
                    // Module-qualified generic constructor, e.g. `list.List<Dog>()`: the callee is
                    // module.Struct. Carry the type args so generic-method narrowing sees the instantiation.
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
                    self.addError(m2.decl.span, "duplicate method '{s}' in '{s}' — Nova has no overloading", .{ m2.decl.name, s.name });
                }
            }
        }
        for (s.fields) |f| self.rejectUnimplementedType(f.type_name, f.span, s.type_params, true);
        for (s.methods) |m| {
            self.variables.clearRetainingCapacity();

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

        // An `exception` must provide a `message(self): string` method. This is what makes an
        // exception more than a plain enum: any caller can turn it into a message with e.message().
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
                self.addError(e.span, "exception '{s}' must define a `message(self): string` method — every exception provides a human-readable message. Add `fn message(self: {s}): string {{ ... }}`.", .{ e.name, e.name });
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

// Coarse category of a SCALAR primitive, used only to reject a CROSS-CATEGORY call argument (e.g. a
// string where an int is expected) — the silent-garbage class where the arg pointer/bits are read as the
// wrong scalar. Same-category pairs (int vs long, etc.) return the SAME category so they are never flagged
// here: numeric widening/narrowing stays governed by the existing `assignable` rules, not this check.
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
