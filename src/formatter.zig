
const std = @import("std");
const ast = @import("ast.zig");

pub const Formatter = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayList(u8),
    indent_level: usize,
    source: []const u8,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Formatter {
        return Formatter{
            .allocator = allocator,
            .out = std.ArrayList(u8).empty,
            .indent_level = 0,
            .source = source,
        };
    }

    pub fn deinit(self: *Formatter) void {
        self.out.deinit(self.allocator);
    }

    fn writeIndent(self: *Formatter) !void {
        var i: usize = 0;
        while (i < self.indent_level) : (i += 1) {
            try self.out.appendSlice(self.allocator, "    ");
        }
    }

    fn write(self: *Formatter, str: []const u8) !void {
        try self.out.appendSlice(self.allocator, str);
    }

    fn print(self: *Formatter, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(self.allocator, fmt, args);
    }

    pub fn formatProgram(self: *Formatter, program: ast.Program) ![]const u8 {
        for (program.declarations, 0..) |decl, idx| {
            if (idx > 0) {

                try self.write("\n");
            }
            try self.formatDeclaration(decl);
        }
        return try self.out.toOwnedSlice(self.allocator);
    }

    fn getGenericString(self: *Formatter, span: ast.Span) []const u8 {
        if (span.start >= self.source.len or span.end > self.source.len) return "";
        const decl_str = self.source[span.start..span.end];
        var in_angle = false;
        var start_idx: ?usize = null;
        var end_idx: ?usize = null;
        var depth: usize = 0;

        for (decl_str, 0..) |c, idx| {
            if (c == '(' or c == '{') {
                if (!in_angle) break;
            }
            if (c == '<') {
                if (depth == 0) {
                    start_idx = idx;
                    in_angle = true;
                }
                depth += 1;
            }
            if (c == '>') {
                if (depth > 0) {
                    depth -= 1;
                    if (depth == 0) {
                        end_idx = idx;
                        break;
                    }
                }
            }
        }

        if (start_idx != null and end_idx != null) {
            return decl_str[start_idx.? .. end_idx.? + 1];
        }
        return "";
    }

    fn isPubDecl(self: *Formatter, span: ast.Span) bool {
        if (span.start == 0 or span.start >= self.source.len) return false;
        var idx = span.start;
        while (idx > 0) {
            idx -= 1;
            const c = self.source[idx];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') continue;
            if (c == 'b' and idx >= 2) {
                if (self.source[idx - 1] == 'u' and self.source[idx - 2] == 'p') {
                    if (idx - 2 == 0 or std.ascii.isWhitespace(self.source[idx - 3]) or self.source[idx - 3] == '}') {
                        return true;
                    }
                }
            }
            break;
        }
        return false;
    }

    fn formatDeclaration(self: *Formatter, decl: ast.Declaration) anyerror!void {
        switch (decl) {
            .import_decl => |id| {
                try self.writeIndent();
                try self.write("import ");
                for (id.module) |c| {
                    if (c == '/') {
                        try self.write(".");
                    } else {
                        try self.print("{c}", .{c});
                    }
                }
                try self.write(";\n");
            },
            .const_decl => |cd| {
                try self.writeIndent();
                if (cd.is_exported) {
                    try self.write("export ");
                }
                try self.print("const {s} = ", .{cd.name});
                try self.formatExpression(cd.value);
                try self.write(";\n");
            },
            .export_decl => |ed| {
                try self.writeIndent();
                try self.print("export {s} {s};\n", .{ @tagName(ed.kind), ed.name });
            },
            .fn_decl => |fd| {
                try self.formatFunctionDecl(fd, "");
            },
            .struct_decl => |sd| {
                try self.formatStructDecl(sd);
            },
            .union_decl => |ud| {
                try self.formatUnionDecl(ud);
            },
            .enum_decl => |ed| {
                try self.formatEnumDecl(ed);
            },
            .trait_decl => |td| {
                try self.formatTraitDecl(td);
            },
        }
    }

    fn formatAttributes(self: *Formatter, attrs: []const ast.Attribute) !void {
        for (attrs) |attr| {
            try self.writeIndent();
            switch (attr) {
                .serializable => try self.write("@serializable\n"),
                .@"test" => try self.write("@test\n"),
                else => {},
            }
        }
    }

    fn formatFunctionDecl(self: *Formatter, fd: ast.FunctionDecl, prefix: []const u8) !void {
        try self.formatAttributes(fd.attributes);
        try self.writeIndent();
        if (fd.is_exported) {
            try self.write("pub ");
        }

        if (fd.extern_lib) |lib| {
            try self.print("extern(\"{s}\") ", .{lib});
        } else if (fd.is_async) {

            try self.write("async ");
        }
        if (std.mem.eql(u8, fd.name, "init")) {
            try self.print("init(", .{});
        } else {
            try self.print("{s}fn {s}", .{prefix, fd.name});

            if (fd.type_params.len > 0) {
                try self.write("<");
                for (fd.type_params, 0..) |tp, i| {
                    if (i > 0) try self.write(", ");
                    try self.write(tp);
                }
                try self.write(">");
            }
            try self.write("(");
        }
        for (fd.params, 0..) |p, idx| {
            if (idx > 0) try self.write(", ");
            try self.write(p.name);
            if (p.type_name) |t| {
                try self.write(": ");
                try self.formatTypeRef(t);
            }
        }
        try self.write(")");
        if (fd.ret_type) |r| {
            try self.write(": ");
            try self.formatTypeRef(r);
        }
        if (fd.extern_lib != null) {
            try self.write(";\n");
        } else {
            try self.write(" ");
            try self.formatBlock(fd.body);
            try self.write("\n");
        }
    }

    fn formatStructDecl(self: *Formatter, sd: ast.StructDecl) !void {
        try self.formatAttributes(sd.attributes);
        try self.writeIndent();
        if (sd.is_public) {
            try self.write("pub ");
        }
        try self.print("struct {s}", .{sd.name});

        if (sd.type_params.len > 0) {
            try self.write("<");
            for (sd.type_params, 0..) |tp, i| {
                if (i > 0) try self.write(", ");
                try self.write(tp);
            }
            try self.write(">");
        }
        if (sd.impls.len > 0) {
            try self.write(" impl ");
            for (sd.impls, 0..) |impl, idx| {
                if (idx > 0) try self.write(", ");
                try self.write(impl.name);
                if (impl.type_args.len > 0) {
                    try self.write("<");
                    for (impl.type_args, 0..) |ta, ti| {
                        if (ti > 0) try self.write(", ");
                        try self.formatTypeRef(ta);
                    }
                    try self.write(">");
                }
            }
        }
        try self.write(" {\n");
        self.indent_level += 1;

        for (sd.fields) |field| {
            try self.writeIndent();
            if (field.is_public) {
                try self.write("pub ");
            }
            try self.print("{s}: ", .{field.name});
            try self.formatTypeRef(field.type_name);
            try self.write(",\n");
        }

        if (sd.fields.len > 0 and sd.methods.len > 0) {
            try self.write("\n");
        }

        for (sd.methods, 0..) |method, idx| {
            if (idx > 0) try self.write("\n");
            var prefix_buf: [32]u8 = undefined;
            var f_idx: usize = 0;
            if (method.is_public) {
                std.mem.copyForwards(u8, prefix_buf[f_idx..], "pub ");
                f_idx += 4;
            }

            try self.formatFunctionDecl(method.decl, prefix_buf[0..f_idx]);
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.write("}\n");
    }

    fn formatUnionDecl(self: *Formatter, ud: ast.UnionDecl) !void {
        try self.writeIndent();
        if (ud.is_public) {
            try self.write("pub ");
        }
        try self.print("union {s} {{\n", .{ud.name});
        self.indent_level += 1;
        for (ud.fields) |field| {
            try self.writeIndent();
            if (field.is_public) {
                try self.write("pub ");
            }
            try self.print("{s}: ", .{field.name});
            try self.formatTypeRef(field.type_name);
            try self.write(",\n");
        }
        self.indent_level -= 1;
        try self.writeIndent();
        try self.write("}\n");
    }

    fn formatEnumDecl(self: *Formatter, ed: ast.EnumDecl) !void {
        try self.formatAttributes(ed.attributes);
        try self.writeIndent();
        if (self.isPubDecl(ed.span)) {
            try self.write("pub ");
        }
        try self.print("enum {s} {{\n", .{ed.name});
        self.indent_level += 1;

        for (ed.variants) |variant| {
            try self.writeIndent();
            try self.write(variant.name);
            if (variant.value) |val| {
                try self.print(" = {d}", .{val});
            } else if (variant.fields) |fields| {
                try self.write(" {\n");
                self.indent_level += 1;
                for (fields) |f| {
                    try self.writeIndent();
                    if (f.is_public) try self.write("pub ");
                    try self.print("{s}: ", .{f.name});
                    try self.formatTypeRef(f.type_name);
                    try self.write(",\n");
                }
                self.indent_level -= 1;
                try self.writeIndent();
                try self.write("}");
            } else if (variant.type_name) |t| {
                try self.write("(");
                try self.formatTypeRef(t);
                try self.write(")");
            }
            try self.write(",\n");
        }

        if (ed.variants.len > 0 and ed.methods.len > 0) {
            try self.write("\n");
        }

        for (ed.methods, 0..) |method, idx| {
            if (idx > 0) try self.write("\n");
            var prefix_buf: [32]u8 = undefined;
            var f_idx: usize = 0;
            if (method.is_public) {
                std.mem.copyForwards(u8, prefix_buf[f_idx..], "pub ");
                f_idx += 4;
            }

            try self.formatFunctionDecl(method.decl, prefix_buf[0..f_idx]);
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.write("}\n");
    }

    fn formatTraitDecl(self: *Formatter, td: ast.TraitDecl) !void {
        try self.writeIndent();
        if (td.is_public) {
            try self.write("pub ");
        }
        try self.print("trait {s}", .{td.name});

        if (td.type_params.len > 0) {
            try self.write("<");
            for (td.type_params, 0..) |tp, i| {
                if (i > 0) try self.write(", ");
                try self.write(tp);
            }
            try self.write(">");
        }
        try self.write(" {\n");
        self.indent_level += 1;
        for (td.methods) |m| {
            try self.writeIndent();

            if (m.is_async) try self.write("async ");
            try self.print("fn {s}(", .{m.name});
            for (m.params, 0..) |p, idx| {
                if (idx > 0) try self.write(", ");
                try self.write(p.name);
                if (p.type_name) |t| {
                    try self.write(": ");
                    try self.formatTypeRef(t);
                }
            }
            try self.write(")");
            if (m.ret_type) |r| {
                try self.write(": ");
                try self.formatTypeRef(r);
            }
            try self.write(";\n");
        }
        self.indent_level -= 1;
        try self.writeIndent();
        try self.write("}\n");
    }

    fn formatBlock(self: *Formatter, block: ast.Block) !void {
        try self.write("{\n");
        self.indent_level += 1;
        for (block.statements) |stmt| {
            try self.formatStatement(stmt);
        }
        self.indent_level -= 1;
        try self.writeIndent();
        try self.write("}");
    }

    fn formatStatement(self: *Formatter, stmt: ast.Statement) anyerror!void {
        switch (stmt) {
            .block => |b| {
                try self.writeIndent();
                try self.formatBlock(b);
                try self.write("\n");
            },
            .let_stmt => |l| {
                try self.writeIndent();
                if (l.is_const) {
                    try self.write("const ");
                } else {
                    try self.write("let ");
                }
                if (l.names) |names| {
                    try self.write("(");
                    for (names, 0..) |n, idx| {
                        if (idx > 0) try self.write(", ");
                        try self.write(n);
                    }
                    try self.write(")");
                } else {
                    try self.write(l.name);
                }
                if (l.type_name) |t| {
                    try self.write(": ");
                    try self.formatTypeRef(t);
                }
                if (l.init) |init_expr| {
                    try self.write(" = ");
                    try self.formatExpression(init_expr);
                }
                try self.write(";\n");
            },
            .expr_stmt => |e| {
                try self.writeIndent();
                try self.formatExpression(e.expr);
                try self.write(";\n");
            },
            .defer_stmt => |d| {
                try self.writeIndent();
                try self.write("defer ");
                try self.formatExpression(d.expr);
                try self.write(";\n");
            },
            .if_stmt => |i| {
                try self.writeIndent();
                try self.formatIfStmtNoIndent(i);
                try self.write("\n");
            },
            .while_stmt => |w| {
                try self.writeIndent();
                try self.write("while (");
                try self.formatExpression(w.condition);
                try self.write(") ");
                if (w.body.* == .block) {
                    try self.formatBlock(w.body.block);
                } else {
                    try self.write("{\n");
                    self.indent_level += 1;
                    try self.formatStatement(w.body.*);
                    self.indent_level -= 1;
                    try self.writeIndent();
                    try self.write("}");
                }
                try self.write("\n");
            },
            .for_stmt => |f| {
                try self.writeIndent();
                try self.write("for (");
                if (f.iterator) |it| {

                    switch (it.binding) {
                        .item => |name| try self.write(name),
                        .destructure => |d| {
                            try self.write("(");
                            try self.write(d.key);
                            try self.write(", ");
                            try self.write(d.value);
                            try self.write(")");
                        },
                    }
                    try self.write(" in ");
                    try self.formatExpression(it.iterable.*);
                } else {

                    if (f.initializer) |init_stmt| {
                        try self.formatStatementNoIndentNoNewline(init_stmt.*);
                    } else {
                        try self.write(";");
                    }
                    if (f.condition) |cond| {
                        try self.write(" ");
                        try self.formatExpression(cond);
                    }
                    try self.write(";");
                    if (f.increment) |incr| {
                        try self.write(" ");
                        try self.formatExpression(incr);
                    }
                }
                try self.write(") ");
                if (f.body.* == .block) {
                    try self.formatBlock(f.body.block);
                } else {
                    try self.write("{\n");
                    self.indent_level += 1;
                    try self.formatStatement(f.body.*);
                    self.indent_level -= 1;
                    try self.writeIndent();
                    try self.write("}");
                }
                try self.write("\n");
            },
            .switch_stmt => |sw| {
                try self.writeIndent();
                try self.write("switch (");
                try self.formatExpression(sw.discriminant);
                try self.write(") {\n");
                self.indent_level += 1;
                for (sw.cases) |case| {
                    try self.writeIndent();
                    try self.write("case ");
                    for (case.values, 0..) |val, idx| {
                        if (idx > 0) try self.write(", ");
                        try self.formatExpression(val);
                    }
                    try self.write(": ");
                    if (case.body.* == .block) {
                        try self.formatBlock(case.body.block);
                        try self.write("\n");
                    } else {
                        try self.write("{\n");
                        self.indent_level += 1;
                        try self.formatStatement(case.body.*);
                        self.indent_level -= 1;
                        try self.writeIndent();
                        try self.write("}\n");
                    }
                }
                if (sw.default_case) |def| {
                    try self.writeIndent();
                    try self.write("default: ");
                    if (def.* == .block) {
                        try self.formatBlock(def.block);
                        try self.write("\n");
                    } else {
                        try self.write("{\n");
                        self.indent_level += 1;
                        try self.formatStatement(def.*);
                        self.indent_level -= 1;
                        try self.writeIndent();
                        try self.write("}\n");
                    }
                }
                self.indent_level -= 1;
                try self.writeIndent();
                try self.write("}\n");
            },
            .return_stmt => |r| {
                try self.writeIndent();
                try self.write("return");
                if (r.value) |val| {
                    try self.write(" ");
                    try self.formatExpression(val);
                }
                try self.write(";\n");
            },
            .break_stmt => {
                try self.writeIndent();
                try self.write("break;\n");
            },
            .continue_stmt => {
                try self.writeIndent();
                try self.write("continue;\n");
            },
}
    }

    fn formatIfStmtNoIndent(self: *Formatter, i: ast.IfStmt) anyerror!void {
        try self.write("if (");
        try self.formatExpression(i.condition);
        try self.write(") ");
        if (i.then_branch.* == .block) {
            try self.formatBlock(i.then_branch.block);
        } else {

            try self.formatStatementNoIndentNoNewline(i.then_branch.*);
        }
        if (i.else_branch) |eb| {
            try self.write(" else ");
            if (eb.* == .block) {
                try self.formatBlock(eb.block);
            } else if (eb.* == .if_stmt) {
                try self.formatIfStmtNoIndent(eb.if_stmt);
            } else {
                try self.formatStatementNoIndentNoNewline(eb.*);
            }
        }
    }

    fn formatStatementNoIndentNoNewline(self: *Formatter, stmt: ast.Statement) anyerror!void {
        switch (stmt) {
            .let_stmt => |l| {
                if (l.is_const) {
                    try self.write("const ");
                } else {
                    try self.write("let ");
                }
                if (l.names) |names| {
                    try self.write(" (");
                    for (names, 0..) |n, idx| {
                        if (idx > 0) try self.write(", ");
                        try self.write(n);
                    }
                    try self.write(")");
                } else {
                    try self.write(l.name);
                }
                if (l.type_name) |t| {
                    try self.write(": ");
                    try self.formatTypeRef(t);
                }
                if (l.init) |init_expr| {
                    try self.write(" = ");
                    try self.formatExpression(init_expr);
                }
                try self.write(";");
            },
            .expr_stmt => |e| {
                try self.formatExpression(e.expr);
                try self.write(";");
            },
            .break_stmt => try self.write("break;"),
            .continue_stmt => try self.write("continue;"),
            .return_stmt => |r| {
                try self.write("return");
                if (r.value) |v| {
                    try self.write(" ");
                    try self.formatExpression(v);
                }
                try self.write(";");
            },
            else => {

                try self.formatStatement(stmt);

                if (self.out.items.len > 0 and self.out.items[self.out.items.len - 1] == '\n') {
                    _ = self.out.pop();
                }
            },
        }
    }

    fn opPrecedence(op: ast.BinaryOp) i32 {
        return switch (op) {
            .assign => 1,
            .bit_or, .Or => 2,
            .bit_xor => 3,
            .bit_and, .And => 4,
            .eq, .ne => 5,
            .lt, .gt, .le, .ge => 6,
            .shl, .shr => 7,
            .add, .sub => 8,
            .mul, .div, .mod => 9,
        };
    }

    fn binOpToStr(op: ast.BinaryOp) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .gt => ">",
            .le => "<=",
            .ge => ">=",
            .bit_and => "&",
            .bit_or => "|",
            .bit_xor => "^",
            .assign => "=",
            .And => "&&",
            .Or => "||",
            .shl => "<<",
            .shr => ">>",
        };
    }

    fn formatBinaryChild(self: *Formatter, child: ast.Expression, parent_op: ast.BinaryOp, is_right: bool) !void {
        switch (child.kind) {
            .binary => |bin| {
                const parent_prec = opPrecedence(parent_op);
                const child_prec = opPrecedence(bin.op);
                if (child_prec < parent_prec or (child_prec == parent_prec and is_right)) {
                    try self.write("(");
                    try self.formatExpression(child);
                    try self.write(")");
                    return;
                }
            },
            else => {},
        }
        try self.formatExpression(child);
    }

    fn formatExpression(self: *Formatter, expr: ast.Expression) anyerror!void {
        switch (expr.kind) {
            .range => |r| {
                try self.formatExpression(r.start.*);
                try self.write(if (r.inclusive) "..=" else "..");
                try self.formatExpression(r.end.*);
            },
            .await_expr => |aw| {
                try self.write("await ");
                try self.formatExpression(aw.operand.*);
            },
            .go_expr => |g| {
                try self.write("go ");
                try self.formatExpression(g.operand.*);
            },
            .literal => |lit| {
                switch (lit) {
                    .integer => |val| try self.print("{d}", .{val}),
                    .float => |val| {
                        var buf: [64]u8 = undefined;
                        const str = try std.fmt.bufPrint(&buf, "{d}", .{val});
                        try self.write(str);
                        if (std.mem.indexOfScalar(u8, str, '.') == null and std.mem.indexOfScalar(u8, str, 'e') == null) {
                            try self.write(".0");
                        }
                    },
                    .decimal => |d| try self.print("{s}m", .{d}),
                    .string => |val| try self.print("\"{s}\"", .{val}),
                    .bool => |val| try self.write(if (val) "true" else "false"),
                    .null => try self.write("null"),
                    .undefined => try self.write("undefined"),
                    .array => |elems| {
                        try self.write("[");
                        for (elems, 0..) |elem, idx| {
                            if (idx > 0) try self.write(", ");
                            try self.formatExpression(elem);
                        }
                        try self.write("]");
                    },
                    .object => |fields| {
                        try self.write("{");
                        for (fields, 0..) |f, idx| {
                            if (idx > 0) try self.write(", ");
                            try self.print("{s}: ", .{f.name});
                            try self.formatExpression(f.value);
                        }
                        try self.write("}");
                    },
                }
            },
            .ident => |name| try self.write(name),
            .binary => |bin| {
                try self.formatBinaryChild(bin.left.*, bin.op, false);
                try self.print(" {s} ", .{binOpToStr(bin.op)});
                try self.formatBinaryChild(bin.right.*, bin.op, true);
            },
            .unary => |un| {
                try self.write(switch (un.op) {
                    .neg => "-",
                    .not => "!",
                    .bit_not => "~",
                });
                if (un.operand.kind == .binary) {
                    try self.write("(");
                    try self.formatExpression(un.operand.*);
                    try self.write(")");
                } else {
                    try self.formatExpression(un.operand.*);
                }
            },
            .call => |c| {
                try self.formatExpression(c.callee.*);
                try self.write("(");
                for (c.args, 0..) |arg, idx| {
                    if (idx > 0) try self.write(", ");
                    try self.formatExpression(arg);
                }
                try self.write(")");
            },
            .generic_call => |gc| {
                try self.formatExpression(gc.callee.*);
                try self.write("<");
                for (gc.type_args, 0..) |t, idx| {
                    if (idx > 0) try self.write(", ");
                    try self.formatTypeRef(t);
                }
                try self.write(">(");
                for (gc.args, 0..) |arg, idx| {
                    if (idx > 0) try self.write(", ");
                    try self.formatExpression(arg);
                }
                try self.write(")");
            },
            .field_access => |fa| {
                try self.formatExpression(fa.object.*);
                try self.print(".{s}", .{fa.field});
            },
            .index => |ind| {
                try self.formatExpression(ind.object.*);
                try self.write("[");
                try self.formatExpression(ind.index.*);
                try self.write("]");
            },
            .struct_init => |si| {
                try self.print("{s} {{", .{si.type_name});
                for (si.fields, 0..) |f, idx| {
                    if (idx > 0) try self.write(", ");
                    try self.print("{s}: ", .{f.name});
                    try self.formatExpression(f.value);
                }
                try self.write("}");
            },
            .enum_init => |ei| {
                try self.print("{s}.{s}", .{ei.enum_name, ei.variant});
                if (ei.fields.len > 0) {
                    try self.write(" {");
                    for (ei.fields, 0..) |f, idx| {
                        if (idx > 0) try self.write(", ");
                        try self.print("{s}: ", .{f.name});
                        try self.formatExpression(f.value);
                    }
                    try self.write("}");
                }
            },
            .cast => |c| {
                try self.formatExpression(c.expr.*);
                try self.write(" as ");
                try self.formatTypeRef(c.target_type);
            },
            .optional_chaining => |oc| {
                try self.formatExpression(oc.object.*);
                try self.print("?.{s}", .{oc.field});
            },
            .nullish_coalesce => |nc| {
                try self.formatExpression(nc.left.*);
                try self.write(" ?? ");
                try self.formatExpression(nc.right.*);
            },
            .jsx_element => |jsx| {
                try self.print("<{s}", .{jsx.tag});
                for (jsx.attributes) |attr| {
                    try self.print(" {s}=", .{attr.name});
                    switch (attr.value) {
                        .string_literal => |s| try self.print("\"{s}\"", .{s}),
                        .expression => |e| {
                            try self.write("{");
                            try self.formatExpression(e);
                            try self.write("}");
                        },
                    }
                }
                if (jsx.children.len == 0) {
                    try self.write(" />");
                } else {
                    try self.write(">");
                    for (jsx.children) |child| {
                        switch (child) {
                            .element => |el| try self.formatExpression(.{ .kind = .{ .jsx_element = el } }),
                            .expression => |e| {
                                try self.write("{");
                                try self.formatExpression(e);
                                try self.write("}");
                            },
                            .statement => |stmt| {
                                try self.write("{");
                                try self.formatStatement(stmt);
                                try self.write("}");
                            },
                            .text => |t| try self.write(t),
                        }
                    }
                    try self.print("</{s}>", .{jsx.tag});
                }
            },
            .closure => |cl| {
                try self.write("(");
                for (cl.params, 0..) |p, idx| {
                    if (idx > 0) try self.write(", ");
                    try self.write(p);
                }
                try self.write(") => ");
                switch (cl.body) {
                    .expr => |e| try self.formatExpression(e.*),
                    .block => |b| try self.formatBlock(b),
                }
            },
            .tuple => |t| {
                try self.write("(");
                for (t, 0..) |elem, idx| {
                    if (idx > 0) try self.write(", ");
                    try self.formatExpression(elem);
                }
                try self.write(")");
            },
            .if_expr => |ife| {
                try self.write("if (");
                try self.formatExpression(ife.condition.*);
                try self.write(") ");
                try self.formatExpression(ife.then_branch.*);
                try self.write(" else ");
                try self.formatExpression(ife.else_branch.*);
            },
            .try_expr => |inner| {
                try self.write("try ");
                try self.formatExpression(inner.*);
            },
            .catch_expr => |ce| {
                try self.formatExpression(ce.expr.*);
                try self.write(" catch ");
                if (ce.err_name) |n| { try self.write("("); try self.write(n); try self.write(") "); }
                try self.formatExpression(ce.handler.*);
            },
            .block_expr => |b| {
                try self.formatBlock(b);
            },
            .template_expr => |temp| {

                try self.write("`");
                for (temp.parts) |part| {
                    switch (part.kind) {
                        .literal => |lit| {
                            if (lit == .string) {
                                try self.write(lit.string);
                            } else {
                                try self.write("${");
                                try self.formatExpression(part);
                                try self.write("}");
                            }
                        },
                        else => {
                            try self.write("${");
                            try self.formatExpression(part);
                            try self.write("}");
                        },
                    }
                }
                try self.write("`");
            },
        }
    }

    fn formatTypeRef(self: *Formatter, tr: ast.TypeRef) anyerror!void {
        switch (tr) {
            .ident => |name| try self.write(name),
            .error_union => |eu| {

                try self.formatTypeRef(eu.ok.*);
                try self.write(" | ");
                try self.formatTypeRef(eu.err.*);
            },
            .optional => |sub| {
                try self.formatTypeRef(sub.*);
                try self.write(" | undefined");
            },
            .fixed_array => |fa| {
                try self.formatTypeRef(fa.element.*);
                try self.print("[{d}]", .{fa.length});
            },
            .generic => |g| {
                try self.write(g.name);
                try self.write("<");
                for (g.params, 0..) |p, idx| {
                    if (idx > 0) try self.write(", ");
                    try self.formatTypeRef(p);
                }
                try self.write(">");
            },
            .func => |f| {

                try self.write("(");
                for (f.params, 0..) |p, idx| {
                    if (idx > 0) try self.write(", ");
                    try self.formatTypeRef(p);
                }
                try self.write(") -> ");
                try self.formatTypeRef(f.ret.*);
            },
            .tuple => |t| {
                try self.write("(");
                for (t, 0..) |p, idx| {
                    if (idx > 0) try self.write(", ");
                    try self.formatTypeRef(p);
                }
                try self.write(")");
            },
        }
    }
};

const testing = std.testing;

test "formatter: `&` and `|` print as operators, not the dead and/or keywords" {

    try testing.expectEqualStrings("&", Formatter.binOpToStr(.bit_and));
    try testing.expectEqualStrings("|", Formatter.binOpToStr(.bit_or));
    try testing.expectEqualStrings("&&", Formatter.binOpToStr(.And));
    try testing.expectEqualStrings("||", Formatter.binOpToStr(.Or));
}

test "formatter: every operator round-trips through the lexer" {

    for ([_]ast.BinaryOp{
        .add, .sub, .mul, .div, .mod,
        .eq,  .ne,  .lt,  .gt,  .le, .ge,
        .bit_and, .bit_or, .And, .Or, .shl, .shr, .assign,
    }) |op| {
        const s = Formatter.binOpToStr(op);
        try testing.expect(s.len > 0);

        for (s) |c| try testing.expect(!std.ascii.isAlphabetic(c));
    }
}
