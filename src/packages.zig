// packages.zig — `nova get` / restore — fetch and cache package git repos.

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


fn repoNameFromUrl(git_url: []const u8) ?[]const u8 {
    var len = git_url.len;
    while (len > 0 and git_url[len - 1] == '/') len -= 1;
    const trimmed = git_url[0..len];
    const last_slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return null;
    var repo = trimmed[last_slash + 1 ..];
    if (std.mem.endsWith(u8, repo, ".git")) repo = repo[0 .. repo.len - 4];
    if (repo.len == 0) return null;
    return repo;
}

fn cloneIntoCache(allocator: std.mem.Allocator, init: std.process.Init, git_url: []const u8) !bool {
    const repo_name = repoNameFromUrl(git_url) orelse {
        std.debug.print("Invalid git URL format: {s}\n", .{git_url});
        return error.InvalidGitUrl;
    };
    const home_path = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/";
    const target_dir = try std.fs.path.join(allocator, &[_][]const u8{ home_path, ".nova", "cache", repo_name });
    defer allocator.free(target_dir);

    if (Io.Dir.access(.cwd(), init.io, target_dir, .{})) |_| {
        std.debug.print("  {s} already cached ({s})\n", .{ repo_name, target_dir });
        return false;
    } else |_| {}

    std.debug.print("Cloning {s} into {s}...\n", .{ git_url, target_dir });
    var git_child = try std.process.spawn(init.io, .{
        .argv = &[_][]const u8{ "git", "clone", "--depth", "1", git_url, target_dir },
    });
    const git_term = try git_child.wait(init.io);
    switch (git_term) {
        .exited => |code| if (code != 0) {
            std.debug.print("git clone failed with exit code {d}\n", .{code});
            return error.GitCloneFailed;
        },
        else => {
            std.debug.print("git clone failed abnormally\n", .{});
            return error.GitCloneFailed;
        },
    }
    return true;
}

pub fn cmdRestore(allocator: std.mem.Allocator, init: std.process.Init) !void {
    const json_data = Io.Dir.readFileAlloc(.cwd(), init.io, "project.json", allocator, .unlimited) catch {
        std.debug.print("Error: project.json not found. Run 'nova init' first.\n", .{});
        return;
    };
    defer allocator.free(json_data);

    var parsed = std.json.parseFromSlice(pipeline.ProjectJson, allocator, json_data, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("Failed to parse project.json: {any}\n", .{err});
        return err;
    };
    defer parsed.deinit();

    if (parsed.value.dependencies.len == 0) {
        std.debug.print("No dependencies to restore.\n", .{});
        return;
    }
    std.debug.print("Restoring {d} dependenc{s} from project.json...\n", .{
        parsed.value.dependencies.len,
        if (parsed.value.dependencies.len == 1) "y" else "ies",
    });
    var fetched: usize = 0;
    for (parsed.value.dependencies) |dep| {
        if (try cloneIntoCache(allocator, init, dep)) fetched += 1;
    }
    std.debug.print("Restore complete: {d} fetched, {d} already cached.\n", .{ fetched, parsed.value.dependencies.len - fetched });
}

pub fn cmdGet(allocator: std.mem.Allocator, init: std.process.Init, args: []const []const u8) !void {
    if (args.len < 3) {

        return cmdRestore(allocator, init);
    }
    const git_url = args[2];
    _ = cloneIntoCache(allocator, init, git_url) catch |err| return err;

    const json_data = Io.Dir.readFileAlloc(.cwd(), init.io, "project.json", allocator, .unlimited) catch {
        std.debug.print("Error: project.json not found in current directory. Run 'nova init' first.\n", .{});
        return;
    };
    defer allocator.free(json_data);

    var parsed = std.json.parseFromSlice(pipeline.ProjectJson, allocator, json_data, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("Failed to parse project.json: {any}\n", .{err});
        return err;
    };
    defer parsed.deinit();

    var deps_list = std.ArrayList([]const u8).empty;
    defer deps_list.deinit(allocator);
    for (parsed.value.dependencies) |dep| {
        try deps_list.append(allocator, dep);
    }

    var already_exists = false;
    for (deps_list.items) |dep| {
        if (std.mem.eql(u8, dep, git_url)) {
            already_exists = true;
            break;
        }
    }

    if (!already_exists) {
        try deps_list.append(allocator, git_url);
    }

    const updated_project = pipeline.ProjectJson{
        .name = parsed.value.name,
        .version = parsed.value.version,
        .type = parsed.value.type,
        .dependencies = deps_list.items,
    };

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(updated_project, .{}, &out.writer);

    try Io.Dir.writeFile(.cwd(), init.io, .{ .data = out.written(), .sub_path = "project.json", .flags = .{} });
    std.debug.print("Dependency locked in project.json successfully.\n", .{});
}
