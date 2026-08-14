const std = @import("std");
const ast = @import("../../frontend/ast.zig");

extern fn fopen(filename: [*c]const u8, modes: [*c]const u8) ?*anyopaque;
extern fn fclose(stream: ?*anyopaque) c_int;
extern fn fwrite(ptr: ?*const anyopaque, size: usize, n: usize, stream: ?*anyopaque) usize;

pub const CoverageBlock = struct {
    id: usize,
    file_path: []const u8,
    line: usize,
    col: usize,
    description: []const u8,
};

pub const CoverageRegistry = struct {
    allocator: std.mem.Allocator,
    blocks: std.ArrayList(CoverageBlock),

    pub fn init(allocator: std.mem.Allocator) CoverageRegistry {
        return .{
            .allocator = allocator,
            .blocks = std.ArrayList(CoverageBlock).empty,
        };
    }

    pub fn deinit(self: *CoverageRegistry) void {
        for (self.blocks.items) |block| {
            self.allocator.free(block.file_path);
            self.allocator.free(block.description);
        }
        self.blocks.deinit(self.allocator);
    }

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
