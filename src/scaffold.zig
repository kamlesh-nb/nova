//! Project scaffolding for the `nova init` and `nova add-feature` CLI commands.
//!
//! This module turns an empty directory into a working Nova project by writing
//! a fixed set of starter files and directories to disk. It is the code behind
//! `nova init <console|web|desktop> --name X [--framework <htmx|datastar|unpoly|htmz|alpine>]` and
//! `nova add-feature <name>`. It
//! deals purely in filesystem effects: it creates directories, writes template
//! text into files, and prints progress to stderr. It does not compile, parse,
//! or type-check anything.
//!
//! Every file body it emits is a compile-time constant string held in
//! [`templates`] (`templates.zig`). This module owns only the *layout* decision,
//! which relative paths exist and what template fills each one, while
//! `templates.zig` owns the *content*. The `console` and `desktop` layouts are a
//! couple of files; the `web` layout mirrors an ASP.NET-style vertical-slice
//! structure (`src/Features/<Area>/<UseCase>/{command,query,handler,...}.nova`),
//! so it is factored out into [`scaffoldWeb`] with a data-driven table of
//! path/content pairs.
//!
//! Design notes and invariants:
//!
//!   - All I/O goes through Zig 0.16's `std.Io` interface passed down from the
//!     CLI driver, and every write targets a path relative to `.cwd()`. The
//!     project directory itself is created first; per-file parent directories
//!     are then created lazily by [`scaffoldFile`], which is why a template can
//!     name a deeply nested path without the layout code pre-creating each
//!     level.
//!
//!   - Directory creation is idempotent: `error.PathAlreadyExists` is swallowed
//!     everywhere so re-running `nova init` over an existing tree overwrites the
//!     files rather than failing. This is a deliberate "regenerate in place"
//!     policy, not accidental error suppression.
//!
//!   - The many `frontend/`, `backend/`, `sema/`, and [`pipeline`] imports below
//!     are NOT used by the scaffolding logic; they are re-exported/kept so this
//!     file compiles against the same module graph as the rest of the CLI. The
//!     scaffolding itself needs only `std`, [`templates`], and `std.Io`.

/// The Zig standard library, used here for allocation, formatting, and path
/// string manipulation.
const std = @import("std");
/// Compile-time build/target information. Present for parity with the rest of
/// the CLI module graph; the scaffolding logic does not branch on it.
const builtin = @import("builtin");
/// Shorthand for `std.Io`, the Zig 0.16 I/O interface. All directory creation
/// and file writes in this module go through `Io.Dir`.
const Io = std.Io;
/// Generated build options (feature flags, versions). Kept for module-graph
/// parity; unused by the scaffolding code paths.
const build_options = @import("build_options");
/// Compiler AST types. Imported for module-graph consistency, not used here.
const ast = @import("frontend/ast.zig");
/// The lexer. Imported for module-graph consistency, not used here.
const lexer = @import("frontend/lexer.zig");
/// The parser. Imported for module-graph consistency, not used here.
const parser = @import("frontend/parser.zig");
/// The source formatter. Imported for module-graph consistency, not used here.
const formatter = @import("frontend/formatter.zig");
/// The type checker. Imported for module-graph consistency, not used here.
const type_checker = @import("frontend/type_checker.zig");
/// The compile-time string constants for every scaffolded file's body. This is
/// the one import the scaffolding actually depends on: it supplies the content
/// each template path is filled with.
const templates = @import("templates.zig");
/// LLVM code generator. Imported for module-graph consistency, not used here.
const llvm_codegen = @import("backend/codegen/llvm_codegen.zig");
/// ARC codegen support. Imported for module-graph consistency, not used here.
const codegen_arc = @import("backend/codegen/arc.zig");
/// Semantic-analysis shadow-diff pass. Imported for parity, not used here.
const sema_shadow = @import("frontend/sema/shadow.zig");
/// Escape-analysis pass. Imported for parity, not used here.
const sema_escape = @import("frontend/sema/escape.zig");
/// Alpha-renaming pass. Imported for parity, not used here.
const sema_alpha = @import("frontend/sema/alpha.zig");
/// Symbol/type-id assignment pass. Imported for parity, not used here.
const sema_ids = @import("frontend/sema/ids.zig");
/// The core semantic-analysis driver. Imported for parity, not used here.
const sema_mod = @import("frontend/sema/sema.zig");
/// The monomorphization pass. Imported for parity, not used here.
const sema_mono = @import("frontend/sema/mono.zig");
/// The compile pipeline orchestrator. Imported for parity, not used here.
const pipeline = @import("pipeline.zig");


/// Writes `content` to `<project>/<rel>`, creating any missing parent
/// directories first.
///
/// This is the single primitive the layout functions build on. It joins the
/// project root and the relative path, and if that joined path contains a `/`,
/// it creates the leading directory chain via `createDirPath` (idempotently:
/// `error.PathAlreadyExists` is not an error). This is what lets a template
/// table name a deeply nested path such as
/// `src/Features/Products/CreateProduct/handler.nova` without any caller
/// pre-creating the intervening directories.
///
/// The joined path is heap-allocated from `allocator` and freed before return.
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

/// The hypermedia frameworks `nova init web --framework` accepts. All are a natural fit for this
/// template's "handler returns an HTML fragment" model: htmx/htmz/unpoly/alpine swap that fragment into
/// the page (differing only in how they target it), and datastar drives reactive signals (its server
/// actions want an SSE stream, which Nova serves via `web.sse`). SPA/JSON frameworks are deliberately
/// excluded -- they are a different, non-hypermedia model.
const web_frameworks = [_][]const u8{ "htmx", "datastar", "unpoly", "htmz", "alpine" };

fn isValidFramework(framework: []const u8) bool {
    for (web_frameworks) |f| {
        if (std.mem.eql(u8, framework, f)) return true;
    }
    return false;
}

/// Returns the `index.html` body for the chosen hypermedia `framework`. The templates differ only in the
/// CDN `<script>`/snippet they load and the demo widget they wire up; everything else in the scaffolded
/// tree is framework-agnostic. Assumes `framework` was already validated by [`isValidFramework`].
fn indexHtmlFor(framework: []const u8) []const u8 {
    if (std.mem.eql(u8, framework, "datastar")) return templates.web_index_html_datastar;
    if (std.mem.eql(u8, framework, "unpoly")) return templates.web_index_html_unpoly;
    if (std.mem.eql(u8, framework, "htmz")) return templates.web_index_html_htmz;
    if (std.mem.eql(u8, framework, "alpine")) return templates.web_index_html_alpine;
    return templates.web_index_html_htmx;
}

/// Writes the full ASP.NET-style web-app starter tree into `project`.
///
/// The `web` template is the largest layout: a vertical-slice structure where each use case
/// (CreateProduct, GetProductById) has its own folder of command/query/response/validator/handler files,
/// plus a shared repository, an `.nsx` view, a domain entity, static `wwwroot`, tests, and the
/// Tailwind/npm tooling files. Rather than a long sequence of explicit writes, the layout is expressed as
/// a data table of `{ rel, content }` pairs driven through [`scaffoldFile`], so adding a file to the
/// template is a one-line table entry. `framework` selects only which `wwwroot/index.html` is written
/// (see [`indexHtmlFor`]); the rest of the tree is identical.
fn scaffoldWeb(allocator: std.mem.Allocator, io: std.Io, project: []const u8, framework: []const u8) !void {
    // Anonymous record type for one entry in the web-layout table: a project
    // relative path and the template body to write there.
    const f = struct { rel: []const u8, content: []const u8 };
    // The complete set of files that make up a scaffolded web app, each
    // pairing a relative path with its template constant from [`templates`].
    const files = [_]f{
        .{ .rel = "src/main.nova", .content = templates.web_main_sample },

        // app.yaml: the project-root manifest -- app config (read into `app.config`) and, when deployed,
        // the orchestrator workload manifest, in one file. Fixed name, always at the project root.
        .{ .rel = "app.yaml", .content = templates.web_app_yaml_sample },

        .{ .rel = "src/Features/Products/routes.nova", .content = templates.web_routes_sample },

        .{ .rel = "src/Features/Products/CreateProduct/command.nova", .content = templates.web_create_command_sample },
        .{ .rel = "src/Features/Products/CreateProduct/validator.nova", .content = templates.web_create_validator_sample },
        .{ .rel = "src/Features/Products/CreateProduct/handler.nova", .content = templates.web_create_handler_sample },

        .{ .rel = "src/Features/Products/GetProductById/query.nova", .content = templates.web_get_query_sample },
        .{ .rel = "src/Features/Products/GetProductById/handler.nova", .content = templates.web_get_handler_sample },

        .{ .rel = "src/Features/Products/Shared/repository.nova", .content = templates.web_repository_sample },

        .{ .rel = "src/Features/Products/views/product_card.nsx", .content = templates.web_view_sample },

        // Clean-arch Domain layer: entities model the persisted rows, DTOs are the
        // request/response shapes bound and returned by the feature slices.
        .{ .rel = "src/Domain/Entities/Product.nova", .content = templates.web_domain_entity_sample },
        .{ .rel = "src/Domain/Dtos/ProductDto.nova", .content = templates.web_get_response_sample },
        .{ .rel = "src/Domain/Dtos/CreateProductDto.nova", .content = templates.web_create_response_sample },
        .{ .rel = "wwwroot/index.html", .content = indexHtmlFor(framework) },
        .{ .rel = "tests/features/products_test.nova", .content = templates.web_test_sample },

        .{ .rel = "package.json", .content = templates.web_package_json_sample },
        .{ .rel = "tailwind.config.js", .content = templates.web_tailwind_config_sample },
        .{ .rel = "styles/app.css", .content = templates.web_tailwind_css_sample },
        .{ .rel = ".gitignore", .content = templates.web_gitignore_sample },
    };
    for (files) |file| try scaffoldFile(allocator, io, project, file.rel, file.content);
}

fn writeVscodeConfig(allocator: std.mem.Allocator, io: std.Io, project: []const u8) !void {
    const vscode_dir = try std.fmt.allocPrint(allocator, "{s}/.vscode", .{project});
    defer allocator.free(vscode_dir);
    Io.Dir.createDirPath(.cwd(), io, vscode_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    const launch_path = try std.fmt.allocPrint(allocator, "{s}/.vscode/launch.json", .{project});
    defer allocator.free(launch_path);
    try Io.Dir.writeFile(.cwd(), io, .{ .data = templates.vscode_launch_json, .sub_path = launch_path, .flags = .{} });
    const tasks_path = try std.fmt.allocPrint(allocator, "{s}/.vscode/tasks.json", .{project});
    defer allocator.free(tasks_path);
    try Io.Dir.writeFile(.cwd(), io, .{ .data = templates.vscode_tasks_json, .sub_path = tasks_path, .flags = .{} });
}

fn scaffoldDesktop(allocator: std.mem.Allocator, io: std.Io, project: []const u8) !void {
    try scaffoldFile(allocator, io, project, "src/main.nova", templates.desktop_main_sample);
}

pub fn cmdInit(allocator: std.mem.Allocator, init: std.process.Init, args: []const []const u8) !void {
    if (args.len < 3) {
        std.debug.print("Usage: nova init <console|web|desktop> --name <project_name> [--framework <htmx|datastar|unpoly|htmz|alpine>]\n", .{});
        return;
    }
    var template_type = args[2];

    if (std.mem.eql(u8, template_type, "app")) {
        std.debug.print("note: `nova init app` is deprecated, use `nova init web` (or `desktop`). Scaffolding a web app.\n", .{});
        template_type = "web";
    }
    if (!std.mem.eql(u8, template_type, "console") and
        !std.mem.eql(u8, template_type, "web") and
        !std.mem.eql(u8, template_type, "desktop"))
    {
        std.debug.print("Invalid template type '{s}'. Expected 'console', 'web', or 'desktop'.\n", .{template_type});
        std.debug.print("Usage: nova init <console|web|desktop> --name <project_name> [--framework <htmx|datastar|unpoly|htmz|alpine>]\n", .{});
        return;
    }

    var project_name: ?[]const u8 = null;
    // The hypermedia framework wired into a `web` app's wwwroot/index.html: which CDN <script> it loads
    // and the demo widget it ships. Defaults to htmx (its fragment-swap model matches the fragment the
    // scaffolded handlers already return). Ignored for console/desktop.
    var framework: []const u8 = "htmx";
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
        } else if (std.mem.eql(u8, args[i], "--framework") or std.mem.eql(u8, args[i], "-f")) {
            if (i + 1 < args.len) {
                i += 1;
                framework = args[i];
            } else {
                std.debug.print("Missing argument for --framework flag (expected one of htmx|datastar|unpoly|htmz|alpine).\n", .{});
                return error.MissingFrameworkArgument;
            }
        }
    }

    if (!isValidFramework(framework)) {
        std.debug.print("Invalid framework '{s}'. Expected one of: htmx, datastar, unpoly, htmz, alpine.\n", .{framework});
        std.debug.print("Usage: nova init web --name <project_name> [--framework <htmx|datastar|unpoly|htmz|alpine>]\n", .{});
        return;
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
    } else if (std.mem.eql(u8, template_type, "web")) {
        try scaffoldWeb(allocator, init.io, project_name.?, framework);
    } else {
        try scaffoldDesktop(allocator, init.io, project_name.?);
    }

    try writeVscodeConfig(allocator, init.io, project_name.?);

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

    if (std.mem.eql(u8, template_type, "web")) {
        std.debug.print("Project '{s}' initialized successfully (hypermedia framework: {s}).\n", .{ project_name.?, framework });
    } else {
        std.debug.print("Project '{s}' initialized successfully.\n", .{project_name.?});
    }
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
