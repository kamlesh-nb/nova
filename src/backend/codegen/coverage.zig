//! Code-coverage block registry for the LLVM codegen backend.
//!
//! When Nova is compiled with coverage instrumentation enabled, codegen needs
//! to (a) assign a small, stable integer ID to every source construct it wants
//! to count, and (b) emit a durable, out-of-band description of what each ID
//! means so a post-run report can map raw counters back to file/line/column.
//! This module is that bookkeeping half: [`CoverageRegistry`] hands out the IDs
//! during compilation, and [`CoverageRegistry.writeMetadataFile`] serialises the
//! ID → location table to a sidecar JSON file. The actual runtime counters (the
//! per-ID hit array bumped at execution) live elsewhere; this side only owns the
//! metadata that gives those counters meaning.
//!
//! The central invariant is ID stability: the ID for a given block must be the
//! same every time that block is asked about within a single compile, so codegen
//! can emit a counter increment against it and the metadata will agree.
//! [`CoverageRegistry.registerBlock`] enforces this by de-duplicating on
//! `(file_path, line)`, asking twice about the same line returns the first ID
//! rather than minting a new one. IDs are simply the insertion index into
//! [`CoverageRegistry.blocks`], which keeps them dense and contiguous (`0..N`) so
//! the runtime can size its counter array as a flat `[N]` and index directly.
//!
//! The metadata writer deliberately uses libc `fwrite`/`fopen` via `extern`
//! rather than Zig's `std.fs`/`std.json`: it hand-rolls a tiny JSON emitter with
//! manual escaping so it has no dependency on the JSON stringifier and stays a
//! self-contained C-FFI leaf. The output filename `__nova_cov_metadata.json` is
//! fixed and written to the process's current working directory.

const std = @import("std");
/// AST types for the frontend. Imported so this module can sit in the codegen
/// backend alongside the passes that create coverage blocks from AST nodes;
/// currently unreferenced by the code below but kept for that adjacency.
const ast = @import("../../frontend/ast.zig");

/// libc `fopen`: opens `__nova_cov_metadata.json` for writing. Used instead of
/// `std.fs` so the metadata emitter stays a pure C-FFI leaf. Returns null on
/// failure, which [`CoverageRegistry.writeMetadataFile`] maps to an error.
extern fn fopen(filename: [*c]const u8, modes: [*c]const u8) ?*anyopaque;
/// libc `fclose`: closes the metadata file handle. Called via `defer` so the
/// stream is released on every exit path of [`CoverageRegistry.writeMetadataFile`].
extern fn fclose(stream: ?*anyopaque) c_int;
/// libc `fwrite`: writes `n` elements of `size` bytes from `ptr` to `stream`.
/// The metadata emitter drives all of its JSON output through this one call,
/// byte-buffer by byte-buffer, so no buffered-writer abstraction is needed.
extern fn fwrite(ptr: ?*const anyopaque, size: usize, n: usize, stream: ?*anyopaque) usize;

/// One instrumented source location and the metadata that describes it.
///
/// Produced by [`CoverageRegistry.registerBlock`] and later serialised, one JSON
/// object per block, by [`CoverageRegistry.writeMetadataFile`]. `file_path` and
/// `description` are heap copies owned by the registry (freed in
/// [`CoverageRegistry.deinit`]); the caller's originals are not retained.
pub const CoverageBlock = struct {
    /// Dense, contiguous identifier (`0..N`) equal to this block's insertion
    /// index in [`CoverageRegistry.blocks`]. The runtime uses it to index its
    /// flat counter array, so it must stay stable for the whole compile.
    id: usize,
    /// Source file this block belongs to. Owned copy; freed on deinit. Together
    /// with [`CoverageBlock.line`] it forms the de-duplication key.
    file_path: []const u8,
    /// 1-based (as supplied by codegen) source line of the block. Half of the
    /// de-dup key: two registrations on the same file and line collapse to one.
    line: usize,
    /// Source column of the block. Recorded for the report but NOT part of the
    /// de-dup key, so the first registration on a line fixes the column reported.
    col: usize,
    /// Human-readable label for the block (e.g. what construct it counts).
    /// Owned copy; freed on deinit. Escaped for `"` and `\` when serialised.
    description: []const u8,
};

/// Owns the set of instrumented [`CoverageBlock`]s for one compilation and
/// serialises them to the coverage-metadata sidecar.
///
/// The registry is append-and-dedup only: blocks are added through
/// [`CoverageRegistry.registerBlock`] and never removed or reordered, which is
/// what makes each block's ID (its index) stable for the compile. It owns the
/// duplicated `file_path`/`description` strings of every block and frees them in
/// [`CoverageRegistry.deinit`].
pub const CoverageRegistry = struct {
    /// Allocator backing [`CoverageRegistry.blocks`] and the per-block string
    /// copies. The same allocator must be used for the matching frees in deinit.
    allocator: std.mem.Allocator,
    /// Registered blocks in insertion order; a block's index IS its
    /// [`CoverageBlock.id`]. Never reordered, so IDs stay valid.
    blocks: std.ArrayList(CoverageBlock),

    /// Creates an empty registry bound to `allocator`.
    ///
    /// The block list starts empty; the caller must call
    /// [`CoverageRegistry.deinit`] to release it and the owned strings.
    pub fn init(allocator: std.mem.Allocator) CoverageRegistry {
        return .{
            .allocator = allocator,
            .blocks = std.ArrayList(CoverageBlock).empty,
        };
    }

    /// Frees every block's owned `file_path`/`description` copy, then the block
    /// list itself. Must be called exactly once; the registry is unusable after.
    pub fn deinit(self: *CoverageRegistry) void {
        for (self.blocks.items) |block| {
            self.allocator.free(block.file_path);
            self.allocator.free(block.description);
        }
        self.blocks.deinit(self.allocator);
    }

    /// Interns a source location and returns its stable coverage ID.
    ///
    /// If a block with the same `file_path` and `line` was already registered,
    /// its existing [`CoverageBlock.id`] is returned and no new block is created
    /// (the passed `col`/`description` are then ignored), this is what lets
    /// codegen ask about a line more than once and always emit the same counter.
    /// Otherwise a fresh block is appended: the new ID is the current length,
    /// `file_path` and `description` are DUPLICATED into registry-owned memory,
    /// and the ID is returned.
    ///
    /// The de-dup scan is linear over all blocks, so registration is O(N) per
    /// call. Returns an allocator error if either string dup or the append fails.
    pub fn registerBlock(self: *CoverageRegistry, file_path: []const u8, line: usize, col: usize, description: []const u8) !usize {
        for (self.blocks.items) |block| {
            if (std.mem.eql(u8, block.file_path, file_path) and block.line == line) {
                return block.id;
            }
        }

        const id = self.blocks.items.len;
        const file_path_dup = try self.allocator.dupe(u8, file_path);
        const description_dup = try self.allocator.dupe(u8, description);
        try self.blocks.append(self.allocator, .{
            .id = id,
            .file_path = file_path_dup,
            .line = line,
            .col = col,
            .description = description_dup,
        });
        return id;
    }

    /// Serialises the whole block table to `__nova_cov_metadata.json` in the
    /// current working directory.
    ///
    /// Emits a JSON array of objects, each carrying `id`, `file_path`, `line`,
    /// `col`, and `description`, hand-formatted with two-space indentation and a
    /// trailing comma on every element but the last. String values are escaped
    /// manually: `file_path` escapes `\` (Windows paths), and `description`
    /// escapes both `\` and `"`. This is the metadata a coverage report joins
    /// against the runtime's hit counters to produce a per-block coverage view.
    ///
    /// Numeric fields are formatted through a shared 64-byte stack buffer, which
    /// is ample for the `"field": <usize>,` fragments produced here. Returns
    /// `error.FileOpenFailed` if the output file cannot be opened, or a
    /// formatting error from `bufPrint`; the handle is always closed via `defer`.
    pub fn writeMetadataFile(self: *CoverageRegistry) !void {
        const file = fopen("__nova_cov_metadata.json", "w") orelse {
            std.debug.print("Failed to open __nova_cov_metadata.json for writing\n", .{});
            return error.FileOpenFailed;
        };
        defer _ = fclose(file);

        _ = fwrite("[\n", 1, 2, file);
        for (self.blocks.items, 0..) |block, i| {
            _ = fwrite("  {\n", 1, 4, file);

            var buf: [64]u8 = undefined;
            const id_str = try std.fmt.bufPrint(&buf, "    \"id\": {d},\n", .{block.id});
            _ = fwrite(id_str.ptr, 1, id_str.len, file);

            _ = fwrite("    \"file_path\": \"", 1, 18, file);
            for (block.file_path) |char| {
                if (char == '\\') {
                    _ = fwrite("\\\\", 1, 2, file);
                } else {
                    var c_buf = [_]u8{char};
                    _ = fwrite(&c_buf, 1, 1, file);
                }
            }
            _ = fwrite("\",\n", 1, 3, file);

            const line_str = try std.fmt.bufPrint(&buf, "    \"line\": {d},\n", .{block.line});
            _ = fwrite(line_str.ptr, 1, line_str.len, file);

            const col_str = try std.fmt.bufPrint(&buf, "    \"col\": {d},\n", .{block.col});
            _ = fwrite(col_str.ptr, 1, col_str.len, file);

            _ = fwrite("    \"description\": \"", 1, 20, file);
            for (block.description) |char| {
                if (char == '\\') {
                    _ = fwrite("\\\\", 1, 2, file);
                } else if (char == '"') {
                    _ = fwrite("\\\"", 1, 2, file);
                } else {
                    var c_buf = [_]u8{char};
                    _ = fwrite(&c_buf, 1, 1, file);
                }
            }
            _ = fwrite("\"\n", 1, 2, file);

            if (i + 1 < self.blocks.items.len) {
                _ = fwrite("  },\n", 1, 5, file);
            } else {
                _ = fwrite("  }\n", 1, 4, file);
            }
        }
        _ = fwrite("]\n", 1, 2, file);
    }
};
