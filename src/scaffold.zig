// scaffold.zig — `nova init` / `nova add feature` project scaffolding.

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


fn scaffoldFile(allocator: std.mem.Allocator, io: std.Io, project: []const u8, rel: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project, rel });
    defer allocator.free(full);
    if (std.mem.lastIndexOfScalar(u8, full, '/')) |slash| {
        const dir = full[0..slash];
        Io.Dir.createDirPath(.cwd(), io, dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }
    try Io.Dir.writeFile(.cwd(), io, .{ .data = content, .sub_path = full, .flags = .{} });
}

fn scaffoldWeb(allocator: std.mem.Allocator, io: std.Io, project: []const u8) !void {
    const f = struct { rel: []const u8, content: []const u8 };
    const files = [_]f{
        .{ .rel = "src/main.nova", .content = templates.web_main_sample },

        .{ .rel = "src/Features/Products/CreateProduct/command.nova", .content = templates.web_create_command_sample },
        .{ .rel = "src/Features/Products/CreateProduct/response.nova", .content = templates.web_create_response_sample },
        .{ .rel = "src/Features/Products/CreateProduct/validator.nova", .content = templates.web_create_validator_sample },
        .{ .rel = "src/Features/Products/CreateProduct/handler.nova", .content = templates.web_create_handler_sample },

        .{ .rel = "src/Features/Products/GetProductById/query.nova", .content = templates.web_get_query_sample },
        .{ .rel = "src/Features/Products/GetProductById/response.nova", .content = templates.web_get_response_sample },
        .{ .rel = "src/Features/Products/GetProductById/handler.nova", .content = templates.web_get_handler_sample },

        .{ .rel = "src/Features/Products/Shared/repository.nova", .content = templates.web_repository_sample },

        // View code lives in a `.nsx` file (same language as `.nova`; the extension keeps markup apart).
        .{ .rel = "src/Features/Products/views/product_card.nsx", .content = templates.web_view_sample },

        .{ .rel = "src/Domain/entities/product.nova", .content = templates.web_domain_entity_sample },
        .{ .rel = "wwwroot/index.html", .content = templates.web_index_html_sample },
        .{ .rel = "tests/features/products_test.nova", .content = templates.web_test_sample },

        // Tailwind CLI styling pipeline: `npm install` then `npm run css:watch`. tailwind.config.js lists
        // the content globs (including the `.nsx` views) so class changes hot-rebuild wwwroot/app.css.
        .{ .rel = "package.json", .content = templates.web_package_json_sample },
        .{ .rel = "tailwind.config.js", .content = templates.web_tailwind_config_sample },
        .{ .rel = "styles/app.css", .content = templates.web_tailwind_css_sample },
        .{ .rel = ".gitignore", .content = templates.web_gitignore_sample },
    };
    for (files) |file| try scaffoldFile(allocator, io, project, file.rel, file.content);
}

fn scaffoldDesktop(allocator: std.mem.Allocator, io: std.Io, project: []const u8) !void {
    try scaffoldFile(allocator, io, project, "src/main.nova", templates.desktop_main_sample);
}

pub fn cmdInit(allocator: std.mem.Allocator, init: std.process.Init, args: []const []const u8) !void {
    if (args.len < 3) {
        std.debug.print("Usage: nova init <console|web|desktop> --name <project_name>\n", .{});
        return;
    }
    var template_type = args[2];

    if (std.mem.eql(u8, template_type, "app")) {
        std.debug.print("note: `nova init app` is deprecated — use `nova init web` (or `desktop`). Scaffolding a web app.\n", .{});
        template_type = "web";
    }
    if (!std.mem.eql(u8, template_type, "console") and
        !std.mem.eql(u8, template_type, "web") and
        !std.mem.eql(u8, template_type, "desktop"))
    {
        std.debug.print("Invalid template type '{s}'. Expected 'console', 'web', or 'desktop'.\n", .{template_type});
        std.debug.print("Usage: nova init <console|web|desktop> --name <project_name>\n", .{});
        return;
    }

    var project_name: ?[]const u8 = null;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--name") or std.mem.eql(u8, args[i], "-n")) {
            if (i + 1 < args.len) {
                i += 1;
                project_name = args[i];
            } else {
                std.debug.print("Missing argument for name flag.\n", .{});
                return error.MissingNameArgument;
            }
        }
    }

    if (project_name == null) {
        std.debug.print("Error: Project name must be specified with --name <name> or -n <name>.\n", .{});
        std.debug.print("Usage: nova init <console|app> --name <project_name>\n", .{});
        return;
    }

    Io.Dir.createDirPath(.cwd(), init.io, project_name.?) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("Error creating directory '{s}': {any}\n", .{ project_name.?, err });
            return err;
        }
    };

    if (std.mem.eql(u8, template_type, "console")) {
        const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{project_name.?});
        defer allocator.free(src_dir);
        Io.Dir.createDirPath(.cwd(), init.io, src_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const tests_dir = try std.fmt.allocPrint(allocator, "{s}/tests", .{project_name.?});
        defer allocator.free(tests_dir);
        Io.Dir.createDirPath(.cwd(), init.io, tests_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const main_path = try std.fmt.allocPrint(allocator, "{s}/src/main.nova", .{project_name.?});
        defer allocator.free(main_path);
        try Io.Dir.writeFile(.cwd(), init.io, .{ .data = templates.console_main_sample, .sub_path = main_path, .flags = .{} });

        const test_path = try std.fmt.allocPrint(allocator, "{s}/tests/main_test.nova", .{project_name.?});
        defer allocator.free(test_path);
        try Io.Dir.writeFile(.cwd(), init.io, .{ .data = templates.console_test_sample, .sub_path = test_path, .flags = .{} });

        // VS Code F5 debugging: lldb-dap launch config + build task (Gap 4). Auto-loads the Nova lldb
        // data formatters so string/List/Map show their contents.
        const vscode_dir = try std.fmt.allocPrint(allocator, "{s}/.vscode", .{project_name.?});
        defer allocator.free(vscode_dir);
        Io.Dir.createDirPath(.cwd(), init.io, vscode_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        const launch_path = try std.fmt.allocPrint(allocator, "{s}/.vscode/launch.json", .{project_name.?});
        defer allocator.free(launch_path);
        try Io.Dir.writeFile(.cwd(), init.io, .{ .data = templates.vscode_launch_json, .sub_path = launch_path, .flags = .{} });
        const tasks_path = try std.fmt.allocPrint(allocator, "{s}/.vscode/tasks.json", .{project_name.?});
        defer allocator.free(tasks_path);
        try Io.Dir.writeFile(.cwd(), init.io, .{ .data = templates.vscode_tasks_json, .sub_path = tasks_path, .flags = .{} });
    } else if (std.mem.eql(u8, template_type, "web")) {
        try scaffoldWeb(allocator, init.io, project_name.?);
    } else {
        try scaffoldDesktop(allocator, init.io, project_name.?);
    }

    const project_json_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "name": "{s}",
        \\  "version": "0.1.0",
        \\  "type": "{s}",
        \\  "dependencies": []
        \\}}
        , .{ project_name.?, template_type });
    defer allocator.free(project_json_content);

    const project_json_path = try std.fmt.allocPrint(allocator, "{s}/project.json", .{project_name.?});
    defer allocator.free(project_json_path);
    try Io.Dir.writeFile(.cwd(), init.io, .{ .data = project_json_content, .sub_path = project_json_path, .flags = .{} });

    const gitignore_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{project_name.?});
    defer allocator.free(gitignore_path);
    Io.Dir.writeFile(.cwd(), init.io, .{ .data = "build/\n*.o\n", .sub_path = gitignore_path, .flags = .{} }) catch {};

    std.debug.print("Project '{s}' initialized successfully.\n", .{project_name.?});
}

pub fn cmdAddFeature(allocator: std.mem.Allocator, init: std.process.Init, name: []const u8) !void {
    const feature_dir_path = try std.fmt.allocPrint(allocator, "features/{s}", .{name});
    defer allocator.free(feature_dir_path);
    Io.Dir.createDirPath(.cwd(), init.io, feature_dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    const model_path = try std.fmt.allocPrint(allocator, "features/{s}/model.nova", .{name});
    defer allocator.free(model_path);
    try Io.Dir.writeFile(.cwd(), init.io, .{ .data = "// Model layer\n", .sub_path = model_path, .flags = .{} });
    const service_path = try std.fmt.allocPrint(allocator, "features/{s}/service.nova", .{name});
    defer allocator.free(service_path);
    try Io.Dir.writeFile(.cwd(), init.io, .{ .data = "// Service layer\n", .sub_path = service_path, .flags = .{} });
    const view_path = try std.fmt.allocPrint(allocator, "features/{s}/view.nova", .{name});
    defer allocator.free(view_path);
    try Io.Dir.writeFile(.cwd(), init.io, .{ .data = "// View layer\n", .sub_path = view_path, .flags = .{} });
    const handler_path = try std.fmt.allocPrint(allocator, "features/{s}/{s}.nova", .{ name, name });
    defer allocator.free(handler_path);
    const handler_content = try std.fmt.allocPrint(allocator, "// Handler layer for {s}\n", .{name});
    defer allocator.free(handler_content);
    try Io.Dir.writeFile(.cwd(), init.io, .{ .data = handler_content, .sub_path = handler_path, .flags = .{} });

    const json_data = Io.Dir.readFileAlloc(.cwd(), init.io, "project.json", allocator, .unlimited) catch {
        std.debug.print("No project.json found, skipping registration.\n", .{});
        return;
    };
    defer allocator.free(json_data);

    var new_json = std.ArrayList(u8).empty;
    defer new_json.deinit(allocator);

    const match_str = "\"features\": [";
    if (std.mem.indexOf(u8, json_data, match_str)) |pos| {
        try new_json.appendSlice(allocator, json_data[0 .. pos + match_str.len]);
        const is_empty = std.mem.indexOf(u8, json_data[pos + match_str.len ..], "\"") == null or
            (std.mem.indexOf(u8, json_data[pos + match_str.len ..], "]") orelse 0) < (std.mem.indexOf(u8, json_data[pos + match_str.len ..], "\"") orelse 0);

        const feature_item = if (is_empty)
            try std.fmt.allocPrint(allocator, "\n    \"{s}\"", .{name})
        else
            try std.fmt.allocPrint(allocator, "\n    \"{s}\",", .{name});
        defer allocator.free(feature_item);
        try new_json.appendSlice(allocator, feature_item);
        try new_json.appendSlice(allocator, json_data[pos + match_str.len ..]);

        try Io.Dir.writeFile(.cwd(), init.io, .{ .data = new_json.items, .sub_path = "project.json", .flags = .{} });
    }
    std.debug.print("Feature '{s}' scaffolded and registered successfully.\n", .{name});
}
