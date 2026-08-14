
const std = @import("std");
const ast = @import("../ast.zig");

pub const SymbolId = enum(u32) { _ };
pub const ModuleId = enum(u32) { _ };

pub const SymbolKind = enum { function, method, struct_, enum_, union_, trait_, constant };

pub const Visibility = enum { public, private };

pub const Symbol = struct {

    name: []const u8,
    module: ModuleId,
    kind: SymbolKind,
    visibility: Visibility,

    owner: ?[]const u8,
    span: ast.Span,

    legacy_mangled: []const u8,

    canonical_mangled: []const u8,

    decl: Decl = .none,

    scoped_name: ?[]const u8 = null,
};

pub const Decl = union(enum) {
    none,
    function: *const ast.FunctionDecl,
    struct_: *const ast.StructDecl,
    enum_: *const ast.EnumDecl,
    trait_: *const ast.TraitDecl,
    constant: *const ast.ConstDecl,
};

pub const Module = struct {
    id: ModuleId,

    path: []const u8,

    file: []const u8,
};

pub fn canonicalModulePath(allocator: std.mem.Allocator, file: []const u8, root_file: []const u8) !?[]const u8 {
    if (file.len == 0) return null;
    if (std.mem.eql(u8, file, root_file)) return null;
    if (std.mem.eql(u8, file, "helpers.nova") or std.mem.eql(u8, file, "test_harness.nova")) return null;

    var path = file;

    const roots = [_][]const u8{ "src/std/", "src/lib/" };
    var stripped = false;
    for (roots) |r| {
        if (std.mem.indexOf(u8, path, r)) |pos| {
            path = path[pos + r.len ..];
            stripped = true;
            break;
        }
    }
    if (!stripped) {

        if (std.mem.indexOf(u8, path, ".nova/std/")) |pos| {
            path = path[pos + ".nova/std/".len ..];
            stripped = true;
        }
    }

    const ext = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    const base = path[0..ext];
    const out = try allocator.alloc(u8, base.len + (if (stripped) @as(usize, 4) else 0));
    var w: usize = 0;
    if (stripped) {
        @memcpy(out[0..4], "std.");
        w = 4;
    }
    for (base) |c| {
        out[w] = if (c == '/' or c == '\\') '.' else c;
        w += 1;
    }
    return out[0..w];
}

pub fn canonicalModulePrefix(allocator: std.mem.Allocator, file: []const u8, root_file: []const u8) !?[]const u8 {
    if (file.len == 0) return null;
    if (std.mem.eql(u8, file, root_file)) return null;
    if (std.mem.eql(u8, file, "helpers.nova") or std.mem.eql(u8, file, "test_harness.nova")) return null;
    var path = file;
    const roots = [_][]const u8{ "src/std/", "src/lib/", ".nova/std/", ".nova/lib/" };
    for (roots) |r| {
        if (std.mem.indexOf(u8, path, r)) |pos| {
            path = path[pos + r.len ..];
            break;
        }
    }
    const ext = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    const base = path[0..ext];
    const out = try allocator.alloc(u8, base.len);
    for (base, 0..) |c, i| out[i] = if (c == '/' or c == '\\' or c == '.') '_' else c;
    return out;
}

pub fn legacyModulePrefix(allocator: std.mem.Allocator, file: []const u8, root_file: []const u8) !?[]const u8 {
    if (file.len == 0) return null;
    if (std.mem.eql(u8, file, root_file)) return null;
    if (std.mem.eql(u8, file, "helpers.nova") or std.mem.eql(u8, file, "test_harness.nova")) return null;
    var path = file;
    if (std.mem.startsWith(u8, path, "src/std/")) {
        path = path["src/std/".len..];
    } else if (std.mem.startsWith(u8, path, "src/lib/")) {
        path = path["src/lib/".len..];
    }
    const ext = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    const base = path[0..ext];
    const out = try allocator.alloc(u8, base.len);
    for (base, 0..) |c, i| out[i] = if (c == '/' or c == '\\' or c == '.') '_' else c;
    return out;
}

pub const Import = struct {
    importer: ModuleId,
    imported: ModuleId,
    segment: []const u8,
};

pub const SymbolTable = struct {
    allocator: std.mem.Allocator,
    symbols: std.ArrayListUnmanaged(Symbol) = .empty,
    modules: std.ArrayListUnmanaged(Module) = .empty,

    imports: std.ArrayListUnmanaged(Import) = .empty,

    owned: std.ArrayListUnmanaged([]const u8) = .empty,
    root_file: []const u8 = "",

    colliding_types: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: std.mem.Allocator) SymbolTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SymbolTable) void {
        for (self.owned.items) |s| self.allocator.free(s);
        self.owned.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.imports.deinit(self.allocator);
        self.colliding_types.deinit(self.allocator);
    }

    pub fn scopedNameFor(self: *const SymbolTable, name: []const u8, file: []const u8) ?[]const u8 {
        if (!self.colliding_types.contains(name)) return null;
        for (self.symbols.items) |s| {
            if (!isTypeSym(s.kind) or !std.mem.eql(u8, s.name, name)) continue;
            const mfile = self.modules.items[@intFromEnum(s.module)].file;
            if (std.mem.eql(u8, mfile, file)) return s.scoped_name;
        }
        return null;
    }

    fn computeScopedName(self: *SymbolTable, name: []const u8, file: []const u8) !?[]const u8 {
        const prefix = try legacyModulePrefix(self.allocator, file, self.root_file);
        if (prefix) |p| {
            defer self.allocator.free(p);
            return try self.own(try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ p, name }));
        }
        return try self.own(try std.fmt.allocPrint(self.allocator, "root_{s}", .{name}));
    }

    fn computeCollidingTypes(self: *SymbolTable) !void {
        // Detect same-name STRUCT or ENUM declarations across modules (same-kind, cross-module). Codegen
        // scopes these two kinds; traits/unions are not scoped in codegen yet, so leaving them unmarked
        // keeps them at the pre-existing behaviour (S3: enums now handled, traits/unions a follow-on).
        const scopable = struct {
            fn f(k: SymbolKind) bool {
                return k == .struct_ or k == .enum_;
            }
        }.f;
        for (self.symbols.items, 0..) |a, i| {
            if (!scopable(a.kind)) continue;
            if (self.colliding_types.contains(a.name)) continue;
            for (self.symbols.items[i + 1 ..]) |b| {
                if (b.kind != a.kind) continue;
                if (a.module == b.module) continue;
                if (std.mem.eql(u8, a.name, b.name)) {
                    try self.colliding_types.put(self.allocator, a.name, {});
                    break;
                }
            }
        }
        for (self.symbols.items) |*s| {
            if (!scopable(s.kind)) continue;
            if (!self.colliding_types.contains(s.name)) continue;
            s.scoped_name = try self.computeScopedName(s.name, self.modules.items[@intFromEnum(s.module)].file);
        }
    }

    fn sepAgnosticEql(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            const na = if (ca == '/') '.' else ca;
            const nb = if (cb == '/') '.' else cb;
            if (na != nb) return false;
        }
        return true;
    }

    fn lastSegment(name: []const u8) []const u8 {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.');
        const slash = std.mem.lastIndexOfScalar(u8, name, '/');
        const cut: ?usize = if (dot) |d| (if (slash) |s| @max(d, s) else d) else slash;
        return if (cut) |i| name[i + 1 ..] else name;
    }

    fn dirOf(path: []const u8) []const u8 {
        const slash = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return "";
        return path[0..slash];
    }
    fn fileBaseNoExt(path: []const u8) []const u8 {
        const slash = std.mem.lastIndexOfAny(u8, path, "/\\");
        const base = if (slash) |s| path[s + 1 ..] else path;
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
        return base[0..dot];
    }

    // Importer-relative module resolution. When the importing file has a SIBLING module (in the same
    // directory) whose basename matches the import's last segment, prefer it. This makes two packages
    // that each contain a same-named internal module (e.g. nova-mysql/src/connection.nova and
    // nova-postgres/src/connection.nova) each resolve to their OWN module, instead of both binding to
    // whichever bare-name `connection` module was registered first. Falls back to the global name-based
    // lookup (stdlib and cross-package imports have unique names, so nothing changes for them).
    pub fn findModuleByImportNameForImporter(self: *const SymbolTable, import_name: []const u8, importer_file: []const u8) ?ModuleId {
        const imp_dir = dirOf(importer_file);
        if (imp_dir.len > 0) {
            const want = lastSegment(import_name);
            for (self.modules.items) |m| {
                if (std.mem.eql(u8, m.path, "<root>")) continue;
                if (std.mem.eql(u8, dirOf(m.file), imp_dir) and std.mem.eql(u8, fileBaseNoExt(m.file), want)) return m.id;
            }
        }
        return self.findModuleByImportName(import_name);
    }

    pub fn findModuleByImportName(self: *const SymbolTable, import_name: []const u8) ?ModuleId {

        for (self.modules.items) |m| {
            if (std.mem.eql(u8, m.path, "<root>")) continue;
            const stripped = if (std.mem.startsWith(u8, m.path, "std.")) m.path[4..] else m.path;
            if (sepAgnosticEql(stripped, import_name) or sepAgnosticEql(m.path, import_name)) return m.id;
        }

        const want_seg = lastSegment(import_name);
        for (self.modules.items) |m| {
            if (std.mem.eql(u8, m.path, "<root>")) continue;
            if (std.mem.eql(u8, lastSegment(m.path), want_seg)) return m.id;
        }
        return null;
    }

    pub fn findModuleByFile(self: *const SymbolTable, file: []const u8) ?ModuleId {
        for (self.modules.items) |m| {
            if (std.mem.eql(u8, m.file, file)) return m.id;
        }
        return null;
    }

    pub fn resolveImportedModule(self: *const SymbolTable, importer: ModuleId, segment: []const u8) ?ModuleId {
        for (self.imports.items) |imp| {
            if (imp.importer == importer and std.mem.eql(u8, imp.segment, segment)) return imp.imported;
        }
        return null;
    }

    fn own(self: *SymbolTable, s: []const u8) ![]const u8 {
        try self.owned.append(self.allocator, s);
        return s;
    }

    fn internModule(self: *SymbolTable, file: []const u8) !ModuleId {
        for (self.modules.items) |m| {
            if (std.mem.eql(u8, m.file, file)) return m.id;
        }
        const canon = try canonicalModulePath(self.allocator, file, self.root_file);
        const path = if (canon) |c| try self.own(c) else "<root>";
        const id: ModuleId = @enumFromInt(@as(u32, @intCast(self.modules.items.len)));
        try self.modules.append(self.allocator, .{ .id = id, .path = path, .file = file });
        return id;
    }

    pub fn moduleOf(self: *SymbolTable, id: ModuleId) Module {
        return self.modules.items[@intFromEnum(id)];
    }

    pub fn findType(self: *const SymbolTable, name: []const u8) ?SymbolId {
        for (self.symbols.items, 0..) |sym, i| {
            switch (sym.kind) {
                .struct_, .enum_, .trait_, .union_ => {
                    if (std.mem.eql(u8, sym.name, name)) return @enumFromInt(@as(u32, @intCast(i)));
                },
                else => {},
            }
        }
        return null;
    }

    fn isTypeSym(k: SymbolKind) bool {
        return k == .struct_ or k == .enum_ or k == .trait_ or k == .union_;
    }

    // Resolve a bare type name preferring, in order: (1) a type declared in the current module
    // (a local declaration shadows a same-named import), (2) a type declared in a module the current
    // module directly imports, (3) module-blind first-match as a last resort. Steps (1) and (2) matter
    // only when the name collides across modules; for a unique name every step returns the same symbol.
    pub fn findTypeInModule(self: *const SymbolTable, name: []const u8, ctx: ?ModuleId) ?SymbolId {
        if (ctx) |cm| {
            // (1) local declaration wins
            for (self.symbols.items, 0..) |sym, i| {
                if (isTypeSym(sym.kind) and sym.module == cm and std.mem.eql(u8, sym.name, name))
                    return @enumFromInt(@as(u32, @intCast(i)));
            }
            // (2) a directly-imported module that declares the name
            if (self.findTypeViaImports(name, cm)) |sid| return sid;
        }
        // (3) module-blind last resort
        return self.findType(name);
    }

    // Among the modules `cm` directly imports, find one that declares a type named `name`. Returns null
    // when none (or more than one distinct module) qualifies, so an ambiguous case falls through to the
    // module-blind resort rather than guessing between two equally-visible imports.
    fn findTypeViaImports(self: *const SymbolTable, name: []const u8, cm: ModuleId) ?SymbolId {
        var found: ?SymbolId = null;
        var found_mod: ?ModuleId = null;
        for (self.imports.items) |imp| {
            if (imp.importer != cm) continue;
            for (self.symbols.items, 0..) |sym, i| {
                if (!isTypeSym(sym.kind) or sym.module != imp.imported) continue;
                if (!std.mem.eql(u8, sym.name, name)) continue;
                if (found_mod) |fm| {
                    if (fm != sym.module) return null; // two distinct imported modules declare it -> ambiguous
                } else {
                    found = @enumFromInt(@as(u32, @intCast(i)));
                    found_mod = sym.module;
                }
            }
        }
        return found;
    }

    pub fn findTypeAmbiguous(self: *const SymbolTable, name: []const u8) bool {
        var n: usize = 0;
        for (self.symbols.items) |sym| {
            switch (sym.kind) {
                .struct_, .enum_, .trait_, .union_ => {
                    if (std.mem.eql(u8, sym.name, name)) n += 1;
                },
                else => {},
            }
        }
        return n > 1;
    }

    pub fn findFunction(self: *const SymbolTable, name: []const u8) ?SymbolId {
        for (self.symbols.items, 0..) |sym, i| {
            if (sym.kind != .function) continue;
            if (std.mem.eql(u8, sym.name, name)) return @enumFromInt(@as(u32, @intCast(i)));
        }
        return null;
    }

    pub fn findFunctionAmbiguous(self: *const SymbolTable, name: []const u8) bool {
        var n: usize = 0;
        for (self.symbols.items) |sym| {
            if (sym.kind != .function) continue;
            if (std.mem.eql(u8, sym.name, name)) n += 1;
        }
        return n > 1;
    }

    pub fn findMethod(self: *const SymbolTable, type_name: []const u8, method: []const u8) ?SymbolId {
        for (self.symbols.items, 0..) |sym, i| {
            if (sym.kind != .method) continue;
            const o = sym.owner orelse continue;
            if (std.mem.eql(u8, o, type_name) and std.mem.eql(u8, sym.name, method)) {
                return @enumFromInt(@as(u32, @intCast(i)));
            }
        }
        return null;
    }

    // Like findMethod, but when the owner type name collides across modules, prefer the method declared
    // in the SAME module as the receiver struct (owner_module). Falls back to the module-blind match so
    // trait defaults / non-colliding owners behave exactly as before.
    pub fn findMethodInModule(self: *const SymbolTable, type_name: []const u8, method: []const u8, owner_module: ModuleId) ?SymbolId {
        for (self.symbols.items, 0..) |sym, i| {
            if (sym.kind != .method or sym.module != owner_module) continue;
            const o = sym.owner orelse continue;
            if (std.mem.eql(u8, o, type_name) and std.mem.eql(u8, sym.name, method)) {
                return @enumFromInt(@as(u32, @intCast(i)));
            }
        }
        return self.findMethod(type_name, method);
    }

    pub fn findModuleBySegment(self: *const SymbolTable, name: []const u8) ?ModuleId {
        for (self.modules.items) |m| {
            if (std.mem.eql(u8, m.path, "<root>")) continue;

            const seg = if (std.mem.lastIndexOfScalar(u8, m.path, '.')) |i| m.path[i + 1 ..] else m.path;
            if (std.mem.eql(u8, seg, name)) return m.id;
        }
        return null;
    }

    pub fn findFunctionBySegment(self: *const SymbolTable, segment: []const u8, name: []const u8) ?SymbolId {
        var found: ?SymbolId = null;
        for (self.modules.items) |m| {
            if (std.mem.eql(u8, m.path, "<root>")) continue;
            const seg = if (std.mem.lastIndexOfScalar(u8, m.path, '.')) |i| m.path[i + 1 ..] else m.path;
            if (!std.mem.eql(u8, seg, segment)) continue;
            if (self.findFunctionIn(m.id, name)) |sid| {
                if (found != null) return null;
                found = sid;
            }
        }
        return found;
    }

    pub fn segmentIsAmbiguous(self: *const SymbolTable, segment: []const u8) bool {
        var n: usize = 0;
        for (self.modules.items) |m| {
            if (std.mem.eql(u8, m.path, "<root>")) continue;
            const seg = if (std.mem.lastIndexOfScalar(u8, m.path, '.')) |i| m.path[i + 1 ..] else m.path;
            if (std.mem.eql(u8, seg, segment)) n += 1;
        }
        return n > 1;
    }

    pub fn findFunctionIn(self: *const SymbolTable, mod: ModuleId, name: []const u8) ?SymbolId {
        for (self.symbols.items, 0..) |sym, i| {
            if (sym.kind != .function) continue;
            if (sym.module != mod) continue;
            if (std.mem.eql(u8, sym.name, name)) return @enumFromInt(@as(u32, @intCast(i)));
        }
        return null;
    }

    pub fn symbolAt(self: *const SymbolTable, id: SymbolId) Symbol {
        return self.symbols.items[@intFromEnum(id)];
    }

    fn addSymbol(self: *SymbolTable, sym: Symbol) !void {
        try self.symbols.append(self.allocator, sym);
    }

    pub fn build(self: *SymbolTable, program: ast.Program) !void {
        self.root_file = program.span.file;
        for (program.declarations) |*decl_ptr| {
            const decl = decl_ptr.*;
            switch (decl) {
                .fn_decl => |f| {
                    const mid = try self.internModule(f.span.file);
                    const legacy = try self.legacyNameForFn(f);
                    const canon = try self.canonicalNameForFn(f);
                    try self.addSymbol(.{
                        .name = f.name,
                        .module = mid,
                        .kind = .function,
                        .visibility = if (f.is_exported) .public else .private,
                        .owner = null,
                        .span = f.span,
                        .legacy_mangled = legacy,
                        .canonical_mangled = canon,
                        .decl = .{ .function = &decl_ptr.fn_decl },
                    });
                },
                .struct_decl => |s| {
                    const mid = try self.internModule(s.span.file);
                    try self.addSymbol(.{
                        .name = s.name,
                        .module = mid,
                        .kind = .struct_,
                        .visibility = if (s.is_public) .public else .private,
                        .owner = null,
                        .span = s.span,
                        .legacy_mangled = s.name,
                        .canonical_mangled = s.name,
                        .decl = .{ .struct_ = &decl_ptr.struct_decl },
                    });

                    for (s.methods) |*m| {
                        const legacy = try self.own(try std.fmt.allocPrint(
                            self.allocator,
                            "{s}_{s}",
                            .{ s.name, m.decl.name },
                        ));
                        try self.addSymbol(.{
                            .name = m.decl.name,
                            .module = mid,
                            .kind = .method,
                            .visibility = .public,
                            .owner = s.name,
                            .span = m.decl.span,
                            .legacy_mangled = legacy,
                            .canonical_mangled = legacy,
                            .decl = .{ .function = &m.decl },
                        });
                    }
                },
                .enum_decl => |e| {
                    const mid = try self.internModule(e.span.file);
                    try self.addSymbol(.{
                        .name = e.name,
                        .module = mid,
                        .kind = .enum_,
                        .visibility = .public,
                        .owner = null,
                        .span = e.span,
                        .legacy_mangled = e.name,
                        .canonical_mangled = e.name,
                        .decl = .{ .enum_ = &decl_ptr.enum_decl },
                    });

                    for (e.methods) |*m| {
                        const legacy = try self.own(try std.fmt.allocPrint(
                            self.allocator,
                            "{s}_{s}",
                            .{ e.name, m.decl.name },
                        ));
                        try self.addSymbol(.{
                            .name = m.decl.name,
                            .module = mid,
                            .kind = .method,
                            .visibility = .public,
                            .owner = e.name,
                            .span = m.decl.span,
                            .legacy_mangled = legacy,
                            .canonical_mangled = legacy,
                            .decl = .{ .function = &m.decl },
                        });
                    }
                },
                .trait_decl => |t| {
                    const mid = try self.internModule(t.span.file);
                    try self.addSymbol(.{
                        .name = t.name,
                        .module = mid,
                        .kind = .trait_,
                        .visibility = .public,
                        .owner = null,
                        .span = t.span,
                        .legacy_mangled = t.name,
                        .canonical_mangled = t.name,
                        .decl = .{ .trait_ = &decl_ptr.trait_decl },
                    });
                },
                .const_decl => |c| {
                    const mid = try self.internModule(c.span.file);
                    try self.addSymbol(.{
                        .name = c.name,
                        .module = mid,
                        .kind = .constant,
                        .visibility = .public,
                        .owner = null,
                        .span = c.span,
                        .legacy_mangled = c.name,
                        .canonical_mangled = c.name,
                        .decl = .{ .constant = &decl_ptr.const_decl },
                    });
                },
                else => {},
            }
        }

        for (program.declarations) |*decl_ptr| {
            if (decl_ptr.* != .import_decl) continue;
            const imp = decl_ptr.import_decl;
            if (std.mem.eql(u8, imp.module, "bytes")) continue;
            const importer = try self.internModule(imp.span.file);
            const imported = self.findModuleByImportNameForImporter(imp.module, imp.span.file) orelse continue;

            const dot = std.mem.lastIndexOfScalar(u8, imp.module, '.');
            const slash = std.mem.lastIndexOfScalar(u8, imp.module, '/');
            const cut: ?usize = if (dot) |d| (if (slash) |s| @max(d, s) else d) else slash;
            const seg = if (cut) |i| imp.module[i + 1 ..] else imp.module;
            try self.imports.append(self.allocator, .{ .importer = importer, .imported = imported, .segment = seg });
        }

        try self.computeCollidingTypes();
    }

    fn canonicalNameForFn(self: *SymbolTable, f: ast.FunctionDecl) ![]const u8 {
        if (try canonicalModulePrefix(self.allocator, f.span.file, self.root_file)) |prefix| {
            defer self.allocator.free(prefix);
            if (isAlreadyNamespaced(f.name)) return f.name;
            return try self.own(try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, f.name }));
        }
        return f.name;
    }

    fn legacyNameForFn(self: *SymbolTable, f: ast.FunctionDecl) ![]const u8 {

        if (try legacyModulePrefix(self.allocator, f.span.file, self.root_file)) |prefix| {
            defer self.allocator.free(prefix);
            if (isAlreadyNamespaced(f.name)) return f.name;
            return try self.own(try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, f.name }));
        }
        return f.name;
    }
};

pub fn isAlreadyNamespaced(name: []const u8) bool {
    const prefixes = [_][]const u8{
        "string",   "json",       "http",       "list",     "map",       "set",
        "net_tcp",  "serde_json", "serde_yaml", "mem_arena", "bytes",    "math",
        "datetime", "fs",         "io_file",    "io_dir",   "env",       "process",
        "crypto",   "yaml",       "bson",       "assert",   "collections", "concurrency",
        "data_btree", "web",      "router",     "session",  "template",  "text",
    };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, name, p) and name.len > p.len and name[p.len] == '_') return true;
    }
    return false;
}

const testing = std.testing;

test "canonicalModulePrefix: the SAME file yields the SAME prefix from any root" {
    const a = testing.allocator;

    const via_src = (try canonicalModulePrefix(a, "src/std/string.nova", "app.nova")).?;
    defer a.free(via_src);
    const via_home = (try canonicalModulePrefix(a, "/Users/someone/.nova/std/string.nova", "app.nova")).?;
    defer a.free(via_home);
    try testing.expectEqualStrings("string", via_src);
    try testing.expectEqualStrings("string", via_home);
    try testing.expect(std.mem.indexOf(u8, via_home, "Users") == null);
}

test "canonicalModulePrefix: nested modules keep their path, slashes become underscores" {
    const a = testing.allocator;
    const p = (try canonicalModulePrefix(a, "src/std/collections/list.nova", "app.nova")).?;
    defer a.free(p);
    try testing.expectEqualStrings("collections_list", p);
    const q = (try canonicalModulePrefix(a, "/home/x/.nova/std/collections/list.nova", "app.nova")).?;
    defer a.free(q);
    try testing.expectEqualStrings("collections_list", q);
}

test "canonicalModulePrefix: an absolute checkout path still canonicalises" {
    const a = testing.allocator;

    const p = (try canonicalModulePrefix(a, "/abs/checkout/lang/src/std/string.nova", "app.nova")).?;
    defer a.free(p);
    try testing.expectEqualStrings("string", p);
}

test "canonicalModulePrefix: the root program and harness files have no prefix" {
    const a = testing.allocator;
    try testing.expect(try canonicalModulePrefix(a, "app.nova", "app.nova") == null);
    try testing.expect(try canonicalModulePrefix(a, "helpers.nova", "app.nova") == null);
    try testing.expect(try canonicalModulePrefix(a, "test_harness.nova", "app.nova") == null);
    try testing.expect(try canonicalModulePrefix(a, "", "app.nova") == null);
}

test "legacyModulePrefix reproduces the OLD behaviour — including the $HOME bug" {

    const a = testing.allocator;
    const via_src = (try legacyModulePrefix(a, "src/std/string.nova", "app.nova")).?;
    defer a.free(via_src);
    try testing.expectEqualStrings("string", via_src);

    const via_home = (try legacyModulePrefix(a, "/Users/kamlesh/.nova/std/string.nova", "app.nova")).?;
    defer a.free(via_home);

    try testing.expect(std.mem.indexOf(u8, via_home, "Users") != null);
    try testing.expect(!std.mem.eql(u8, via_src, via_home));
}

test "isAlreadyNamespaced: an allowlisted prefix must be followed by '_'" {

    try testing.expect(isAlreadyNamespaced("string_concat"));
    try testing.expect(isAlreadyNamespaced("map_reduce"));
    try testing.expect(isAlreadyNamespaced("set_value"));

    try testing.expect(!isAlreadyNamespaced("string"));
    try testing.expect(!isAlreadyNamespaced("stringify"));
    try testing.expect(!isAlreadyNamespaced("hash"));
    try testing.expect(!isAlreadyNamespaced("mapper"));
}

test "findModuleBySegment: match the name a module is USED under" {

    const a = testing.allocator;
    var tab = SymbolTable.init(a);
    defer tab.deinit();
    var decls = [_]ast.Declaration{
        .{ .fn_decl = .{
            .name = "hash",
            .params = &.{},
            .ret_type = null,
            .body = .{ .statements = &.{}, .span = .{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "src/std/string.nova" } },
            .is_exported = true,
            .attributes = &.{},
            .span = .{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "src/std/string.nova" },
        } },
        .{ .fn_decl = .{
            .name = "push",
            .params = &.{},
            .ret_type = null,
            .body = .{ .statements = &.{}, .span = .{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "src/std/collections/list.nova" } },
            .is_exported = true,
            .attributes = &.{},
            .span = .{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "src/std/collections/list.nova" },
        } },
    };
    try tab.build(.{ .declarations = &decls, .span = .{ .start = 0, .end = 0, .line = 0, .col = 0, .file = "app.nova" } });

    const m_string = tab.findModuleBySegment("string") orelse return error.TestExpectedEqual;

    const m_list = tab.findModuleBySegment("list") orelse return error.TestExpectedEqual;
    try testing.expect(m_string != m_list);
    try testing.expect(tab.findModuleBySegment("nosuchmodule") == null);

    try testing.expect(tab.findFunctionIn(m_string, "hash") != null);
    try testing.expect(tab.findFunctionIn(m_string, "push") == null);
    try testing.expect(tab.findFunctionIn(m_list, "push") != null);
}

test "build: a method's decl points INTO the AST, not at a dead stack copy" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };

    var methods = [_]ast.MethodDecl{.{
        .is_public = true,
        .is_static = false,
        .decl = .{
            .name = "get",
            .params = &.{},
            .ret_type = null,
            .body = .{ .statements = &.{}, .span = sp },
            .is_exported = false,
            .attributes = &.{},
            .is_async = false,
            .span = sp,
        },
    }};
    var decls = [_]ast.Declaration{.{ .struct_decl = .{
        .name = "Box",
        .fields = &.{},
        .methods = &methods,
        .attributes = &.{},
        .impls = &.{},
        .is_public = true,
        .span = sp,
    } }};
    const program = ast.Program{ .declarations = &decls, .span = sp };

    var tab = SymbolTable.init(a);
    defer tab.deinit();
    try tab.build(program);

    const mid = tab.findMethod("Box", "get") orelse return error.TestExpectedEqual;
    const sym = tab.symbolAt(mid);
    try testing.expect(sym.decl == .function);

    try testing.expectEqual(&decls[0].struct_decl.methods[0].decl, sym.decl.function);
}
