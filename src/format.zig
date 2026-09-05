//! The `kyte fmt` source formatter and its comment-preserving glue.
//!
//! This file is the CLI-side driver for the code formatter: it reads a `.ky`
//! file (or every file in the tree), runs it through the real pretty-printer in
//! [`frontend/formatter.zig`], and writes the result back in place. The
//! formatter itself only knows about the AST, so on its own it would DISCARD
//! every comment, because comments are lexer trivia that the parser throws away
//! before the AST is built. The bulk of this file exists to solve exactly that
//! problem: how to reformat code while putting the original comments back where
//! they belong.
//!
//! The strategy is token alignment. The formatter never adds, removes, splits,
//! or merges a code token: it only changes the whitespace between tokens. So the
//! source and the formatted output have the SAME sequence of code tokens, just
//! at different byte offsets. [`reinjectComments`] walks the gaps between
//! consecutive tokens in the source, finds any comment sitting in a gap, and
//! re-emits it into the corresponding gap of the formatted text, classifying it
//! as either a trailing comment (stays on the previous token's line) or a
//! leading comment (goes on its own line, re-indented to match the following
//! token). The i-th gap in the source maps to the i-th gap in the formatted
//! output precisely because the token counts match.
//!
//! Safety is enforced by a fail-closed invariant checked twice with
//! [`sameTokenStream`]: reformatting must not change the code token stream, and
//! neither must comment reinjection. If EITHER check fails the file is left
//! byte-for-byte untouched and a diagnostic is printed, rather than risk writing
//! back something that alters program meaning. This is why an unsupported
//! construct causes `kyte fmt` to skip a file instead of mangling it: correctness
//! is preferred over always-formatting.
//!
//! The entry point is [`cmdFmt`], dispatched from the CLI driver in
//! `src/main.zig` for the `kyte fmt` subcommand.

/// The Zig standard library, used here for allocation, slicing/`mem` helpers,
/// `ArrayList`, sorting, and `std.process.Init`.
const std = @import("std");
/// Compile-time build/target information (`@import("builtin")`). Imported for
/// availability alongside the other driver modules; not referenced directly in
/// this file.
const builtin = @import("builtin");
/// Alias for `std.Io`, the I/O abstraction. [`formatFile`] uses `Io.Dir` to read
/// and write files through the `init.io` implementation.
const Io = std.Io;
/// Generated build-time options module. Imported for availability alongside the
/// other driver modules; not referenced directly in this file.
const build_options = @import("build_options");
/// Kyte's AST node definitions. Imported for availability; the AST is produced
/// and consumed here only indirectly through [`parser`] and [`formatter`].
const ast = @import("frontend/ast.zig");
/// The lexer. [`sameTokenStream`] and [`codeTokenSpans`] drive `Lexer` directly
/// to tokenise source for the code-equality guard and gap scanning.
const lexer = @import("frontend/lexer.zig");
/// The parser. [`formatFile`] uses `Parser` to build the AST that the formatter
/// pretty-prints.
const parser = @import("frontend/parser.zig");
/// The AST pretty-printer that does the actual reformatting; [`formatFile`] runs
/// `Formatter.formatProgram` over the parsed program.
const formatter = @import("frontend/formatter.zig");
/// The semantic type checker. Imported for availability; formatting does not
/// type-check, so it is not referenced in this file.
const type_checker = @import("frontend/type_checker.zig");
/// Project/scaffold templates. Imported for availability; not referenced here.
const templates = @import("templates.zig");
/// The LLVM code generator. Imported for availability; not referenced here.
const llvm_codegen = @import("backend/codegen/llvm_codegen.zig");
/// The ARC (automatic reference counting) codegen support. Imported for
/// availability; not referenced here.
const codegen_arc = @import("backend/codegen/arc.zig");
/// The sema shadow-verifier pass. Imported for availability; not referenced here.
const sema_shadow = @import("frontend/sema/shadow.zig");
/// The escape-analysis sema pass. Imported for availability; not referenced here.
const sema_escape = @import("frontend/sema/escape.zig");
/// The alpha-renaming sema pass. Imported for availability; not referenced here.
const sema_alpha = @import("frontend/sema/alpha.zig");
/// The sema identifier/ID tables. Imported for availability; not referenced here.
const sema_ids = @import("frontend/sema/ids.zig");
/// The main semantic-analysis pass. Imported for availability; not referenced
/// here.
const sema_mod = @import("frontend/sema/sema.zig");
/// The monomorphisation sema pass. Imported for availability; not referenced
/// here.
const sema_mono = @import("frontend/sema/mono.zig");
/// The build/driver pipeline. [`cmdFmt`] calls `pipeline.findKyteFiles` to
/// discover every `.ky` source under the current directory in batch mode.
const pipeline = @import("pipeline.zig");


/// Reports whether two source strings lex to the identical sequence of code
/// tokens (same token type and same lexeme, in order, up to `eof`).
///
/// This is the correctness gate the formatter relies on: because comments are
/// lexer trivia that never surface as tokens, two texts with equal token streams
/// differ only in whitespace and comments, i.e. the CODE is unchanged. Used by
/// [`formatFile`] to reject a formatting or reinjection result that would alter
/// program meaning. Note it compares only tokens, so it is deliberately blind to
/// whitespace and comment differences, which is exactly what makes it safe to
/// use as an equality check across a reformat.
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

/// A half-open byte range `[start, end)` locating one code token within its
/// source text. Produced by [`codeTokenSpans`] and consumed by
/// [`reinjectComments`] to reason about the gaps between adjacent tokens.
const TokenSpan = struct {
    /// Byte offset of the token's first character in the source text.
    start: usize,
    /// Byte offset one past the token's last character (exclusive end).
    end: usize,
};

/// Lexes `text` and returns the [`TokenSpan`] of every code token, excluding the
/// terminal `eof`.
///
/// The spans are taken from the lexer's own `tok_start`/`pos` cursor after each
/// `nextToken`, so they are exact byte offsets into `text`. The returned slice is
/// caller-owned and must be freed. The gaps BETWEEN these spans (and before the
/// first / after the last) are where all whitespace and comments live, which is
/// what [`reinjectComments`] scans.
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

/// One pending comment insertion into the formatted output, accumulated by
/// [`appendCommentInsert`] and later applied in offset order by
/// [`reinjectComments`].
///
/// Insertions are collected out of order (all leading/trailing decisions are made
/// per source gap) and then stably sorted, so both an `offset` and a tie-breaking
/// `order` are needed to reproduce the original comment sequence at a shared
/// insertion point.
const CommentIns = struct {
    /// Byte offset in the FORMATTED text at which `text` is to be spliced in.
    offset: usize,
    /// The fully rendered snippet to insert, including any leading space,
    /// re-computed indentation, and trailing newline. Heap-allocated and freed
    /// by [`reinjectComments`] once spliced.
    text: []const u8,
    /// Monotonic sequence number used as the sort tie-breaker so that multiple
    /// comments landing at the same `offset` keep their source order.
    order: usize,
};

/// Re-inserts the comments from `source` into the comment-stripped `formatted`
/// text, returning a newly allocated buffer the caller owns.
///
/// The algorithm relies on the token-alignment invariant: `source` and
/// `formatted` share the same code-token sequence, so their token gaps correspond
/// one-to-one. It lexes both into span lists and, for gap `i` (the whitespace
/// before token `i`, with gap `n` being the trailing region after the last
/// token), scans the source gap for `//` line comments and `/* */` block
/// comments. Each comment found is queued via [`appendCommentInsert`], classified
/// as trailing (no newline seen since the previous token, so it belongs at the
/// end of that token's line in the output) or leading (starts a fresh line,
/// re-indented to the following token). Queued inserts are stably sorted by
/// offset then discovery order and spliced into the output.
///
/// Fail-safe: if the two token counts differ (`n != f_spans.len`) the alignment
/// assumption is broken, so it gives up and returns a plain copy of `formatted`
/// unchanged rather than misplace comments. Likewise, if no comments were found
/// it returns a copy of `formatted` directly. The returned buffer is always a
/// fresh allocation regardless of path.
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
        /// Orders insertions by ascending `offset`, breaking ties by ascending
        /// `order`, so the sort is stable in source sequence at any single
        /// insertion point. This is what lets several comments in one gap keep
        /// their original relative order after the out-of-order collection pass.
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

/// Renders one source comment into a [`CommentIns`] and appends it to `inserts`,
/// deciding WHERE in the formatted text it should land.
///
/// Three placements, matching the three kinds of gap:
///   - `trailing` (and there is a previous token): the comment stays on the same
///     line as the previous code token. The offset is the end of that token's
///     line in the formatted output (`line_end`), and the text is prefixed with a
///     single space (`" {s}"`), no newline.
///   - leading, and there is a following token (`i < n`): the comment gets its
///     own line placed just before token `i`. The output line's existing indent
///     (the run of spaces/tabs before token `i`) is measured and reused so the
///     comment aligns with the code it precedes, and a trailing newline is added.
///   - otherwise (`i == n`, the trailing region past the last token): the comment
///     is appended at end of file with a newline.
///
/// `order.*` is captured into the insert and then incremented, giving each
/// comment a stable tie-break rank for the later sort in [`reinjectComments`].
/// `f_spans`, `i`, and `n` describe the formatted token spans and the current gap
/// index; `n` is the token count so `i == n` denotes the after-last gap.
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

/// Formats a single `.ky` file in place, preserving its comments, and only
/// writes back if doing so provably does not change the code.
///
/// The pipeline is: read the file, parse it to an AST (a parse error is reported
/// with the file name and propagated), pretty-print via
/// [`frontend/formatter.zig`], then guard the result with [`sameTokenStream`]. If
/// the formatter would alter the code token stream (an unsupported construct) the
/// file is left untouched and skipped; with `KYTE_FMT_DEBUG` set in the
/// environment it additionally prints the first diverging token pair to aid
/// diagnosis. It then re-injects comments with [`reinjectComments`] and runs the
/// SAME guard a second time, skipping on failure. Only when both guards pass is
/// the comment-preserved text written back over `file_path`.
///
/// `init` carries the I/O implementation and the environment map used for the
/// read, the write, and the `KYTE_FMT_DEBUG` lookup.
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
        if (init.environ_map.get("KYTE_FMT_DEBUG") != null) {
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
        std.debug.print("skipped '{s}': formatter would alter code (unsupported construct), file left unchanged\n", .{file_path});
        return;
    }

    const with_comments = try reinjectComments(allocator, source, formatted);
    defer allocator.free(with_comments);
    if (!sameTokenStream(source, with_comments)) {
        std.debug.print("skipped '{s}': comment reinjection would alter code, file left unchanged\n", .{file_path});
        return;
    }

    try Io.Dir.writeFile(.cwd(), init.io, .{ .data = with_comments, .sub_path = file_path, .flags = .{} });
}

/// CLI entry point for `kyte fmt`, dispatched from the driver in `src/main.zig`.
///
/// With an explicit path argument (`args.len >= 3`, i.e. `kyte fmt <file>`) it
/// formats just that file. Otherwise it recursively discovers every `.ky` file
/// under the current directory via [`pipeline.findKyteFiles`] and formats each,
/// then prints a count. Per-file errors are caught and reported without aborting
/// the batch: a failure on one file logs a message and, in the directory mode,
/// `continue`s to the next (note the printed `Formatted N files` count is the
/// number ATTEMPTED, incremented before the possible error, not strictly the
/// number successfully rewritten). The discovered file list is owned here and
/// freed on exit.
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
        try pipeline.findKyteFiles(allocator, init.io, .cwd(), ".", &list);
        if (list.items.len == 0) {
            std.debug.print("No .ky files found to format.\n", .{});
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
