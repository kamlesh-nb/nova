// format.zig — `nova fmt` — format sources, reinjecting comments the pretty-printer drops.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const build_options = @import("build_options");
const ast = @import("frontend/ast.zig");
const lexer = @import("frontend/lexer.zig");
const parser = @import("frontend/parser.zig");
const formatter = @import("frontend/formatter.zig");
const type_checker = @import("frontend/type_checker.zig");
const templates = @import("templates.zig");
const llvm_codegen = @import("backend/codegen/llvm_codegen.zig");
const codegen_arc = @import("backend/codegen/arc.zig");
const sema_shadow = @import("frontend/sema/shadow.zig");
const sema_escape = @import("frontend/sema/escape.zig");
const sema_alpha = @import("frontend/sema/alpha.zig");
const sema_ids = @import("frontend/sema/ids.zig");
const sema_mod = @import("frontend/sema/sema.zig");
const sema_mono = @import("frontend/sema/mono.zig");
const pipeline = @import("pipeline.zig");


fn sameTokenStream(a: []const u8, b: []const u8) bool {
    var la = lexer.Lexer.init(a);
    var lb = lexer.Lexer.init(b);
    while (true) {
        const ta = la.nextToken();
        const tb = lb.nextToken();
        if (ta.type != tb.type) return false;
        if (!std.mem.eql(u8, ta.lexeme, tb.lexeme)) return false;
        if (ta.type == .eof) return true;
    }
}

const TokenSpan = struct { start: usize, end: usize };

fn codeTokenSpans(allocator: std.mem.Allocator, text: []const u8) ![]TokenSpan {
    var spans = std.ArrayList(TokenSpan).empty;
    errdefer spans.deinit(allocator);
    var lx = lexer.Lexer.init(text);
    while (true) {
        const t = lx.nextToken();
        if (t.type == .eof) break;
        try spans.append(allocator, .{ .start = lx.tok_start, .end = lx.pos });
    }
    return spans.toOwnedSlice(allocator);
}

const CommentIns = struct {
    offset: usize,
    text: []const u8,
    order: usize,
};

fn reinjectComments(allocator: std.mem.Allocator, source: []const u8, formatted: []const u8) ![]u8 {
    const s_spans = try codeTokenSpans(allocator, source);
    defer allocator.free(s_spans);
    const f_spans = try codeTokenSpans(allocator, formatted);
    defer allocator.free(f_spans);

    const n = s_spans.len;

    if (n != f_spans.len) return allocator.dupe(u8, formatted);

    var inserts = std.ArrayList(CommentIns).empty;
    defer inserts.deinit(allocator);
    var order: usize = 0;

    var i: usize = 0;
    while (i <= n) : (i += 1) {
        const gap_start = if (i == 0) 0 else s_spans[i - 1].end;
        const gap_end = if (i < n) s_spans[i].start else source.len;
        const has_prev = i > 0;
        var seen_nl = false;
        var j = gap_start;
        while (j < gap_end) {
            const c = source[j];
            if (c == '\n') {
                seen_nl = true;
                j += 1;
                continue;
            }
            if (c == ' ' or c == '\t' or c == '\r') {
                j += 1;
                continue;
            }
            if (c == '/' and j + 1 < gap_end and source[j + 1] == '/') {
                var k = j;
                while (k < gap_end and source[k] != '\n') k += 1;
                var te = k;
                while (te > j and (source[te - 1] == ' ' or source[te - 1] == '\t' or source[te - 1] == '\r')) te -= 1;
                const text = source[j..te];
                const trailing = has_prev and !seen_nl;
                try appendCommentInsert(allocator, &inserts, &order, formatted, f_spans, i, n, text, trailing);
                j = k;
                seen_nl = false;
            } else if (c == '/' and j + 1 < gap_end and source[j + 1] == '*') {
                var k = j + 2;
                while (k + 1 < gap_end and !(source[k] == '*' and source[k + 1] == '/')) k += 1;
                k = if (k + 1 < gap_end) k + 2 else gap_end;
                const text = source[j..k];
                const trailing = has_prev and !seen_nl;
                try appendCommentInsert(allocator, &inserts, &order, formatted, f_spans, i, n, text, trailing);
                j = k;
                seen_nl = false;
            } else {

                break;
            }
        }
    }

    if (inserts.items.len == 0) return allocator.dupe(u8, formatted);

    std.mem.sort(CommentIns, inserts.items, {}, struct {
        fn lt(_: void, a: CommentIns, b: CommentIns) bool {
            if (a.offset != b.offset) return a.offset < b.offset;
            return a.order < b.order;
        }
    }.lt);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    for (inserts.items) |ins| {
        const off = @min(ins.offset, formatted.len);
        if (off > cursor) try out.appendSlice(allocator, formatted[cursor..off]);
        try out.appendSlice(allocator, ins.text);
        cursor = off;
    }
    if (cursor < formatted.len) try out.appendSlice(allocator, formatted[cursor..]);

    for (inserts.items) |ins| allocator.free(ins.text);
    return out.toOwnedSlice(allocator);
}

fn appendCommentInsert(
    allocator: std.mem.Allocator,
    inserts: *std.ArrayList(CommentIns),
    order: *usize,
    formatted: []const u8,
    f_spans: []const TokenSpan,
    i: usize,
    n: usize,
    text: []const u8,
    trailing: bool,
) !void {
    if (trailing and i >= 1) {

        const base = f_spans[i - 1].start;
        const line_end = std.mem.indexOfScalarPos(u8, formatted, base, '\n') orelse formatted.len;
        const rendered = try std.fmt.allocPrint(allocator, " {s}", .{text});
        try inserts.append(allocator, .{ .offset = line_end, .text = rendered, .order = order.* });
    } else if (i < n) {

        const base = f_spans[i].start;
        const line_start = if (std.mem.lastIndexOfScalar(u8, formatted[0..base], '\n')) |nl| nl + 1 else 0;
        var ind_end = line_start;
        while (ind_end < base and (formatted[ind_end] == ' ' or formatted[ind_end] == '\t')) ind_end += 1;
        const indent = formatted[line_start..ind_end];
        const rendered = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{ indent, text });
        try inserts.append(allocator, .{ .offset = line_start, .text = rendered, .order = order.* });
    } else {

        const rendered = try std.fmt.allocPrint(allocator, "{s}\n", .{text});
        try inserts.append(allocator, .{ .offset = formatted.len, .text = rendered, .order = order.* });
    }
    order.* += 1;
}

fn formatFile(allocator: std.mem.Allocator, init: std.process.Init, file_path: []const u8) !void {
    const source = try Io.Dir.readFileAlloc(.cwd(), init.io, file_path, allocator, .unlimited);
    defer allocator.free(source);

    var p = try parser.Parser.init(allocator, source, file_path, false);
    defer p.deinit();
    const program = p.parseProgram() catch |err| {
        std.debug.print("Parser error in file: {s}\n", .{file_path});
        return err;
    };

    var f = formatter.Formatter.init(allocator, source);
    defer f.deinit();

    const formatted = try f.formatProgram(program);
    defer allocator.free(formatted);

    if (!sameTokenStream(source, formatted)) {
        if (init.environ_map.get("NOVA_FMT_DEBUG") != null) {
            var la = lexer.Lexer.init(source);
            var lb = lexer.Lexer.init(formatted);
            while (true) {
                const ta = la.nextToken();
                const tb = lb.nextToken();
                if (ta.type != tb.type or !std.mem.eql(u8, ta.lexeme, tb.lexeme)) {
                    std.debug.print("  [fmt-diff] src={s}'{s}' (L{d}) vs fmt={s}'{s}' (L{d})\n", .{ @tagName(ta.type), ta.lexeme, ta.line, @tagName(tb.type), tb.lexeme, tb.line });
                    break;
                }
                if (ta.type == .eof) break;
            }
        }
        std.debug.print("skipped '{s}': formatter would alter code (unsupported construct) — file left unchanged\n", .{file_path});
        return;
    }

    const with_comments = try reinjectComments(allocator, source, formatted);
    defer allocator.free(with_comments);
    if (!sameTokenStream(source, with_comments)) {
        std.debug.print("skipped '{s}': comment reinjection would alter code — file left unchanged\n", .{file_path});
        return;
    }

    try Io.Dir.writeFile(.cwd(), init.io, .{ .data = with_comments, .sub_path = file_path, .flags = .{} });
}

pub fn cmdFmt(allocator: std.mem.Allocator, init: std.process.Init, args: []const []const u8) !void {
    if (args.len >= 3) {
        const file_path = args[2];
        formatFile(allocator, init, file_path) catch |err| {
            std.debug.print("Error formatting file '{s}': {any}\n", .{ file_path, err });
        };
    } else {
        var list = std.ArrayList([]const u8).empty;
        defer {
            for (list.items) |item| allocator.free(item);
            list.deinit(allocator);
        }
        try pipeline.findNovaFiles(allocator, init.io, .cwd(), ".", &list);
        if (list.items.len == 0) {
            std.debug.print("No .nova files found to format.\n", .{});
            return;
        }
        var formatted_count: usize = 0;
        for (list.items) |file_path| {
            formatFile(allocator, init, file_path) catch |err| {
                std.debug.print("Error formatting file '{s}': {any}\n", .{ file_path, err });
                continue;
            };
            formatted_count += 1;
        }
        std.debug.print("Formatted {d} files.\n", .{formatted_count});
    }
}
