// symbols.zig — F1 stage 1: a real symbol table.
//
// See docs/design/F1-name-resolution.md. Today Nova has no symbol table: ~10 flat
// StringHashMaps keyed by mangled strings, and when an exact lookup misses it
// LINEARLY SCANS every function looking for an `_`-delimited suffix match, taking
// the first hit in hash-iteration order. The load-bearing defect:
//
//   `_` is simultaneously the module separator, the struct-method separator, the
//   captured-global separator, AND a legal identifier character.
//
// Because the separator is ambiguous with the payload, a mangled name cannot be
// PARSED — only guessed. Guessing is implemented as a scan, and a scan over a hash
// map is nondeterministic when two modules export the same name.
//
// STAGE 1 IS SHADOW MODE. Nothing here is consumed by codegen yet. It is built
// alongside the legacy resolution and DIFFED against it, so the blast radius is
// observable before it is taken (F1 §5). Report-only: no behaviour change.
const std = @import("std");
const ast = @import("../ast.zig");

pub const SymbolId = enum(u32) { _ };
pub const ModuleId = enum(u32) { _ };

pub const SymbolKind = enum { function, method, struct_, enum_, union_, trait_, constant };

pub const Visibility = enum { public, private };

pub const Symbol = struct {
    /// Source spelling, unmangled. `hash`, not `_Users_kamlesh_.nova_std_string_hash`.
    name: []const u8,
    module: ModuleId,
    kind: SymbolKind,
    visibility: Visibility,
    /// For a method: the owning type's name. null otherwise.
    owner: ?[]const u8,
    span: ast.Span,
    /// The name legacy codegen will emit for this decl — recorded so stage 1 can
    /// diff the two schemes. Not used for resolution.
    legacy_mangled: []const u8,
    /// What the decl would be called once getModulePrefix strips the absolute
    /// `~/.nova/std/` root too. Used to PREDICT collisions before cutting over —
    /// declarations.zig:737-748 dedups functions by name, so a collision created by
    /// the rename would silently drop one.
    canonical_mangled: []const u8,
    /// The declaration this symbol names. F1 §3.2 always had this; it was
    /// simplified away in stage 1 because nothing consumed it yet. F2 stage 2c
    /// does: expression inference needs a call's return type and a field's type,
    /// and "look it up by re-scanning the AST" is how the string-matching got in.
    /// Borrowed — the AST outlives the table.
    decl: Decl = .none,
    /// F1 module-scoped types: for a struct whose bare name COLLIDES across modules, the module-unique
    /// codegen spelling (`<legacyModulePrefix(file)>_<name>`), precomputed in `build` and owned by the
    /// table. null for every non-colliding struct (and non-struct) — those keep their bare name. Both the
    /// renderer (via the symbol directly) and codegen (via `scopedNameFor`) read THIS one string, so the
    /// definition and every reference spell a colliding struct identically.
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
    /// The LOGICAL import path (`std.string`), derived canonically. This is the
    /// point of the exercise: today's prefix is the FILESYSTEM path with slashes
    /// turned into underscores, and `getModulePrefix` only strips `src/std/` —
    /// while the loader falls back to an absolute `$HOME/.nova/std/...` which it
    /// does not strip. The same file therefore yields a different linker symbol
    /// depending on which path it was found under, with the user's home directory
    /// baked into the symbol. Canonicalising kills that (F1 §2.2).
    path: []const u8,
    /// The `span.file` this module was recovered from.
    file: []const u8,
};

/// Derive a canonical, path-independent module identity from a span's file.
/// `src/std/collections/list.nova` and `/Users/x/.nova/std/collections/list.nova`
/// must both yield `std.collections.list`.
pub fn canonicalModulePath(allocator: std.mem.Allocator, file: []const u8, root_file: []const u8) !?[]const u8 {
    if (file.len == 0) return null;
    if (std.mem.eql(u8, file, root_file)) return null; // the program itself
    if (std.mem.eql(u8, file, "helpers.nova") or std.mem.eql(u8, file, "test_harness.nova")) return null;

    var path = file;
    // Strip whichever stdlib root this was found under. The legacy scheme knows
    // only the first two and silently mangles the absolute path otherwise.
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
        // Absolute stdlib fallback: .../.nova/std/<sub>
        if (std.mem.indexOf(u8, path, ".nova/std/")) |pos| {
            path = path[pos + ".nova/std/".len ..];
            stripped = true;
        }
    }
    // Drop the extension (last '.'), then '/'|'\\' -> '.'
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

/// The FIXED prefix: strip whichever stdlib root the file was found under,
/// including the absolute `$HOME/.nova/std/` fallback the legacy scheme misses.
/// Deliberately produces the SAME string the legacy scheme already produces for a
/// `src/std/`-resolved file, so a src-resolved build's symbols are unchanged and a
/// HOME-resolved build simply agrees with it.
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
    for (base, 0..) |c, i| out[i] = if (c == '/' or c == '\\') '_' else c;
    return out;
}

/// What the legacy scheme will name this declaration. Mirrors
/// `llvm_codegen.zig:getModulePrefix` + `getStructPrefix` + `isAlreadyNamespaced`
/// so stage 1 can diff without touching codegen.
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
    for (base, 0..) |c, i| out[i] = if (c == '/' or c == '\\') '_' else c;
    return out;
}

/// F1-4: one recorded `import <path>;` edge — module `importer` imports module `imported`, used under
/// `segment` (the last path component, the name it is REFERENCED by: `import collections.list;` then
/// `list.List(...)`). This is the import GRAPH the loader used to throw away; with it, resolving a
/// segment name is a scoped LOOKUP (what THIS module imported) instead of a global file-path
/// reconstruction that goes ambiguous when two modules share a last segment (the ycsb `client` case).
pub const Import = struct {
    importer: ModuleId,
    imported: ModuleId,
    segment: []const u8,
};

pub const SymbolTable = struct {
    allocator: std.mem.Allocator,
    symbols: std.ArrayListUnmanaged(Symbol) = .empty,
    modules: std.ArrayListUnmanaged(Module) = .empty,
    /// F1-4: the recorded import edges (see `Import`). Populated by `build`'s second pass.
    imports: std.ArrayListUnmanaged(Import) = .empty,
    /// Owned strings (canonical paths, mangled names).
    owned: std.ArrayListUnmanaged([]const u8) = .empty,
    root_file: []const u8 = "",
    /// F1 module-scoped types: struct names DECLARED in more than one distinct module. Populated at the
    /// end of `build`. A name in here is module-qualified by `scopedTypeName` (in rendering, the struct
    /// table, method mangling, construction, and vtables) so two modules' same-named structs stay
    /// distinct; a name NOT in here keeps its bare spelling — so this is a no-op for a program with no
    /// collisions (every existing corpus program), which is what keeps the change safe.
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

    /// F1 module-scoped types: the module-unique codegen name for a struct declared in `file`, or null
    /// when the bare `name` is unique (no collision) — callers keep the bare spelling. Const lookup over
    /// the PRECOMPUTED `scoped_name` (owned in `build`), so it never allocates and is byte-identical to
    /// what the renderer reads off the symbol. Codegen calls this for its AST-decl / reference sites.
    pub fn scopedNameFor(self: *const SymbolTable, name: []const u8, file: []const u8) ?[]const u8 {
        if (!self.colliding_types.contains(name)) return null;
        for (self.symbols.items) |s| {
            if (s.kind != .struct_ or !std.mem.eql(u8, s.name, name)) continue;
            const mfile = self.modules.items[@intFromEnum(s.module)].file;
            if (std.mem.eql(u8, mfile, file)) return s.scoped_name;
        }
        return null;
    }

    /// The qualified spelling `<legacyModulePrefix(file)>_<name>` (underscore form, so `getStructBaseName`
    /// — which strips only '.'/'<' — does NOT collapse it); a ROOT-file struct (prefix null) gets a
    /// synthetic `root_` prefix so a user struct shadowing a stdlib name still resolves distinctly.
    fn computeScopedName(self: *SymbolTable, name: []const u8, file: []const u8) !?[]const u8 {
        const prefix = try legacyModulePrefix(self.allocator, file, self.root_file);
        if (prefix) |p| {
            defer self.allocator.free(p);
            return try self.own(try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ p, name }));
        }
        return try self.own(try std.fmt.allocPrint(self.allocator, "root_{s}", .{name}));
    }

    /// Populate `colliding_types` (struct names declared in >=2 distinct modules), then precompute each
    /// colliding struct symbol's `scoped_name`. O(n^2) over struct symbols, but n is small and once.
    fn computeCollidingTypes(self: *SymbolTable) !void {
        for (self.symbols.items, 0..) |a, i| {
            if (a.kind != .struct_) continue;
            if (self.colliding_types.contains(a.name)) continue;
            for (self.symbols.items[i + 1 ..]) |b| {
                if (b.kind != .struct_) continue;
                if (a.module == b.module) continue;
                if (std.mem.eql(u8, a.name, b.name)) {
                    try self.colliding_types.put(self.allocator, a.name, {});
                    break;
                }
            }
        }
        for (self.symbols.items) |*s| {
            if (s.kind != .struct_) continue;
            if (!self.colliding_types.contains(s.name)) continue;
            s.scoped_name = try self.computeScopedName(s.name, self.modules.items[@intFromEnum(s.module)].file);
        }
    }

    /// F1-4: the ModuleId whose canonical path matches the import NAME as written (`collections.list`
    /// -> module `std.collections.list`; a user module `app.foo` matches directly). Tries an exact
    /// match on the std-stripped path, then the full path, then the last segment. Null if unknown.
    /// Compare two module spellings treating '.' and '/' as the SAME separator, so a '/'-spelled import
    /// name (`serde/json`) equals a '.'-spelled module path (`serde.json`).
    fn sepAgnosticEql(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            const na = if (ca == '/') '.' else ca;
            const nb = if (cb == '/') '.' else cb;
            if (na != nb) return false;
        }
        return true;
    }

    /// The last path segment across EITHER separator ('.' or '/').
    fn lastSegment(name: []const u8) []const u8 {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.');
        const slash = std.mem.lastIndexOfScalar(u8, name, '/');
        const cut: ?usize = if (dot) |d| (if (slash) |s| @max(d, s) else d) else slash;
        return if (cut) |i| name[i + 1 ..] else name;
    }

    pub fn findModuleByImportName(self: *const SymbolTable, import_name: []const u8) ?ModuleId {
        // The import spelling separates segments with '/' (`serde/json`, `lib/helper`) while a module
        // `path` uses '.' (`std.serde.json`). Compare separator-AGNOSTICALLY, or NO multi-segment import
        // ever matched here — the import edge was silently dropped and every multi-segment call fell back
        // to the global segment search (which skipped visibility enforcement: the E1 hole).
        for (self.modules.items) |m| {
            if (std.mem.eql(u8, m.path, "<root>")) continue;
            const stripped = if (std.mem.startsWith(u8, m.path, "std.")) m.path[4..] else m.path;
            if (sepAgnosticEql(stripped, import_name) or sepAgnosticEql(m.path, import_name)) return m.id;
        }
        // Last-segment fallback (best-effort; the exact-path match above is preferred).
        const want_seg = lastSegment(import_name);
        for (self.modules.items) |m| {
            if (std.mem.eql(u8, m.path, "<root>")) continue;
            if (std.mem.eql(u8, lastSegment(m.path), want_seg)) return m.id;
        }
        return null;
    }

    /// F1-4: the ModuleId already interned for `file` (find-only, no interning — for read-only callers
    /// like the inferer that need the CURRENT module without mutating the table).
    pub fn findModuleByFile(self: *const SymbolTable, file: []const u8) ?ModuleId {
        for (self.modules.items) |m| {
            if (std.mem.eql(u8, m.file, file)) return m.id;
        }
        return null;
    }

    /// F1-4: which module did `importer` import under `segment`? A scoped lookup over the recorded
    /// edges — the replacement for findModuleBySegment's global reconstruction. Null if `importer`
    /// imported nothing under that name.
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

    /// Resolve a TYPE name (struct / enum / trait) to its SymbolId — the F1<->F2
    /// join. F2's lowerer calls this so `.ident "Stats"` becomes
    /// `.struct_{decl}` instead of `.unresolved`.
    ///
    /// Keyed by BARE name, faithfully reproducing today's reality: codegen's
    /// structs/enums/traits maps are keyed by bare name with `put` and no
    /// collision check (llvm_codegen.zig:76-79), so two modules declaring
    /// `struct Config` silently overwrite each other (§2.5). `findTypeAmbiguous`
    /// exposes that rather than hiding it.
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

    /// F1 module-scoped types: resolve a BARE type name in the SCOPE of `ctx` module. A bare `Widget` in
    /// module a means a's Widget — so a type DEFINED in `ctx` wins over any same-named type elsewhere.
    /// Falls back to the global first-match (`findType`) when `ctx` doesn't define it (a non-colliding
    /// name is unique globally, so the fallback is exact; a colliding name not defined locally is a
    /// genuine cross-module ambiguity that should be qualified — the fallback preserves prior behavior).
    pub fn findTypeInModule(self: *const SymbolTable, name: []const u8, ctx: ?ModuleId) ?SymbolId {
        if (ctx) |cm| {
            for (self.symbols.items, 0..) |sym, i| {
                switch (sym.kind) {
                    .struct_, .enum_, .trait_, .union_ => {
                        if (sym.module == cm and std.mem.eql(u8, sym.name, name)) return @enumFromInt(@as(u32, @intCast(i)));
                    },
                    else => {},
                }
            }
        }
        return self.findType(name);
    }

    /// True when two DIFFERENT declarations claim the same type name — the silent
    /// overwrite at llvm_codegen.zig:76-79, made observable.
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

    /// Resolve a FUNCTION name to its SymbolId. Bare-name keyed, like findType —
    /// faithful to today's flat namespace (§2.1).
    pub fn findFunction(self: *const SymbolTable, name: []const u8) ?SymbolId {
        for (self.symbols.items, 0..) |sym, i| {
            if (sym.kind != .function) continue;
            if (std.mem.eql(u8, sym.name, name)) return @enumFromInt(@as(u32, @intCast(i)));
        }
        return null;
    }

    /// True when a bare function name matches TWO OR MORE distinct declarations — the same
    /// ambiguity the codegen suffix scan rejects as an N2 error (F1 §2.3). `findFunction` returns
    /// the FIRST match silently, so F1-3b must consult this before recording a call's SymbolId:
    /// an ambiguous bare call must keep falling through to the scan, which errors naming both, not
    /// resolve to an arbitrary pick. Mirrors `findTypeAmbiguous`.
    pub fn findFunctionAmbiguous(self: *const SymbolTable, name: []const u8) bool {
        var n: usize = 0;
        for (self.symbols.items) |sym| {
            if (sym.kind != .function) continue;
            if (std.mem.eql(u8, sym.name, name)) n += 1;
        }
        return n > 1;
    }

    /// Resolve `Type.method` to its SymbolId.
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

    /// Find a module by the name it is USED under. `import collections.list;` then
    /// `list.List<int>()` — the object is the LAST SEGMENT of the import path, and
    /// the canonical prefix is `collections_list`. So match on the last segment.
    ///
    /// This exists because the loader DISCARDS import_decl (§2.1) — nothing records
    /// which module a name came from, so the module has to be recovered from the
    /// file path. F1 stage 4 gives modules real identity and this becomes a lookup
    /// rather than a reconstruction.
    pub fn findModuleBySegment(self: *const SymbolTable, name: []const u8) ?ModuleId {
        for (self.modules.items) |m| {
            if (std.mem.eql(u8, m.path, "<root>")) continue;
            // Module.path is DOT-separated (canonicalModulePath: `std.collections.list`),
            // not underscore-separated — that is canonicalModulePrefix's format, and
            // confusing the two is why the first cut of this silently matched nothing.
            const seg = if (std.mem.lastIndexOfScalar(u8, m.path, '.')) |i| m.path[i + 1 ..] else m.path;
            if (std.mem.eql(u8, seg, name)) return m.id;
        }
        return null;
    }

    /// Resolve `<segment>.<fn>` across EVERY module used under that segment.
    ///
    /// findModuleBySegment alone is not enough, and the reason is a real finding:
    /// ycsb.nova imports BOTH `net.tcp.client` and `data.btree.client`, so two
    /// modules are used under the name `client`. Taking the first match is
    /// first-match-wins on an ambiguous name — the very pattern F1 removed from
    /// codegen this morning — and it silently resolved `client.connect` against the
    /// wrong module (31 expressions).
    ///
    /// So: search all candidates. Exactly one match -> resolve. Zero -> null.
    /// More than one -> genuinely ambiguous, and we refuse to guess (F1 N2).
    ///
    /// This is a RECONSTRUCTION, and it is ambiguous only because the loader
    /// DISCARDS import_decl (§2.1) — nothing records that `client` HERE meant
    /// `data.btree.client`. That fact is right there in the source and is thrown
    /// away. F1 stage 4 makes this a lookup instead of a guess.
    pub fn findFunctionBySegment(self: *const SymbolTable, segment: []const u8, name: []const u8) ?SymbolId {
        var found: ?SymbolId = null;
        for (self.modules.items) |m| {
            if (std.mem.eql(u8, m.path, "<root>")) continue;
            const seg = if (std.mem.lastIndexOfScalar(u8, m.path, '.')) |i| m.path[i + 1 ..] else m.path;
            if (!std.mem.eql(u8, seg, segment)) continue;
            if (self.findFunctionIn(m.id, name)) |sid| {
                if (found != null) return null; // ambiguous — do not guess
                found = sid;
            }
        }
        return found;
    }

    /// True when two different modules are used under the same segment name.
    pub fn segmentIsAmbiguous(self: *const SymbolTable, segment: []const u8) bool {
        var n: usize = 0;
        for (self.modules.items) |m| {
            if (std.mem.eql(u8, m.path, "<root>")) continue;
            const seg = if (std.mem.lastIndexOfScalar(u8, m.path, '.')) |i| m.path[i + 1 ..] else m.path;
            if (std.mem.eql(u8, seg, segment)) n += 1;
        }
        return n > 1;
    }

    /// A function declared IN a specific module. Unlike findFunction (bare-name,
    /// faithful to the flat namespace), this is properly qualified.
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

    /// Collect every top-level declaration. Mirrors what `collectFunctions` sees,
    /// but keyed by (module, name) rather than by a mangled string.
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
                        .legacy_mangled = s.name, // types are keyed by BARE name today
                        .canonical_mangled = s.name,
                        .decl = .{ .struct_ = &decl_ptr.struct_decl },
                    });
                    // `|*m|`, NOT `|m|`: `&m.decl` is stored in the symbol table
                    // and must outlive this loop. A by-value capture makes it the
                    // address of a loop-local — see the pointer-identity test.
                    // `s.methods` is a slice, so the element pointer is the AST's.
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
                    // Register the enum's METHODS as `.method` symbols owned by the enum name —
                    // EXACTLY as the struct branch does. Without this, findMethod (and so
                    // staticMethodReturn) never resolved `Status.reasonPhrase(x)`, so an unannotated
                    // `let r = Status.reasonPhrase(s)` was left UNTYPED — and a `+` concat then rendered
                    // the string RESULT as its pointer address (numToString path). That corrupted every
                    // HTTP response's reason phrase + header lines in web.response.serialize. `|*m|` (not
                    // `|m|`): the stored `&m.decl` must outlive this loop — same discipline as structs.
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

        // F1-4 SECOND PASS: record the import edges. Every module is interned now (first pass), so an
        // imported module NAME resolves to a real ModuleId. Skip the magic `bytes` pseudo-import and
        // any name that resolves to no known module (a builtin, or a module the loader did not reach).
        for (program.declarations) |*decl_ptr| {
            if (decl_ptr.* != .import_decl) continue;
            const imp = decl_ptr.import_decl;
            if (std.mem.eql(u8, imp.module, "bytes")) continue;
            const importer = try self.internModule(imp.span.file);
            const imported = self.findModuleByImportName(imp.module) orelse continue;
            // The import spelling separates segments with '/' (`lib/helper`, `serde/json`); take the last
            // segment across EITHER separator so the recv name (`helper`, `json`) matches at the call site.
            const dot = std.mem.lastIndexOfScalar(u8, imp.module, '.');
            const slash = std.mem.lastIndexOfScalar(u8, imp.module, '/');
            const cut: ?usize = if (dot) |d| (if (slash) |s| @max(d, s) else d) else slash;
            const seg = if (cut) |i| imp.module[i + 1 ..] else imp.module;
            try self.imports.append(self.allocator, .{ .importer = importer, .imported = imported, .segment = seg });
        }

        // F1 module-scoped types: after every struct symbol is registered, flag the names declared in
        // more than one module so `scopedTypeName` can qualify exactly those.
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
        // Mirrors collectFunctions' priority: struct prefix (param[0] named `self`)
        // > module prefix > bare. We only model the module/bare split here; methods
        // are collected from StructDecl above.
        if (try legacyModulePrefix(self.allocator, f.span.file, self.root_file)) |prefix| {
            defer self.allocator.free(prefix);
            if (isAlreadyNamespaced(f.name)) return f.name;
            return try self.own(try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, f.name }));
        }
        return f.name;
    }
};

/// Mirrors `llvm_codegen.zig:isAlreadyNamespaced` — a hardcoded 40-entry prefix
/// allowlist. A user fn named `map_reduce` or `set_value` starts with an
/// allowlisted prefix followed by `_`, so it is silently treated as
/// already-namespaced and never gets a module prefix. Reproduced here only so the
/// diff is faithful; F1 deletes it.
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

// ---------------------------------------------------------------------------
// Tests. These pin the pure functions that the 2026-07-15 $HOME bug lived in —
// see docs/design/README.md §2b: every bug fixed that day was in an untested pure
// function, found months later by a user-visible symptom rather than by a test at
// the point of the mistake.
// ---------------------------------------------------------------------------
const testing = std.testing;

test "canonicalModulePrefix: the SAME file yields the SAME prefix from any root" {
    const a = testing.allocator;
    // This is the whole $HOME bug: getModulePrefix stripped only `src/std/`, while
    // the loader falls back to an absolute `$HOME/.nova/std/...` (main.zig:422).
    // Both must now canonicalise identically.
    const via_src = (try canonicalModulePrefix(a, "src/std/string.nova", "app.nova")).?;
    defer a.free(via_src);
    const via_home = (try canonicalModulePrefix(a, "/Users/someone/.nova/std/string.nova", "app.nova")).?;
    defer a.free(via_home);
    try testing.expectEqualStrings("string", via_src);
    try testing.expectEqualStrings("string", via_home);
    try testing.expect(std.mem.indexOf(u8, via_home, "Users") == null); // no $HOME in a symbol
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
    // indexOf, not startsWith — a path CONTAINING a root must strip too.
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
    // The shadow diff is only honest if the legacy side is faithful. This pins the
    // bug on purpose: it is the `before` half of the comparison.
    const a = testing.allocator;
    const via_src = (try legacyModulePrefix(a, "src/std/string.nova", "app.nova")).?;
    defer a.free(via_src);
    try testing.expectEqualStrings("string", via_src);

    const via_home = (try legacyModulePrefix(a, "/Users/kamlesh/.nova/std/string.nova", "app.nova")).?;
    defer a.free(via_home);
    // The legacy scheme did NOT strip the absolute root, so the home directory
    // ended up in the linker symbol — and the two disagreed for the same file.
    try testing.expect(std.mem.indexOf(u8, via_home, "Users") != null);
    try testing.expect(!std.mem.eql(u8, via_src, via_home));
}

test "isAlreadyNamespaced: an allowlisted prefix must be followed by '_'" {
    // The 40-entry hardcoded allowlist (llvm_codegen.zig:659). A user fn named
    // `map_reduce` starts with `map` + `_`, so it is silently treated as
    // pre-namespaced and never gets a module prefix.
    try testing.expect(isAlreadyNamespaced("string_concat"));
    try testing.expect(isAlreadyNamespaced("map_reduce")); // the trap, pinned
    try testing.expect(isAlreadyNamespaced("set_value")); // ditto
    // ...but a bare name, or one merely starting with the letters, must not match
    try testing.expect(!isAlreadyNamespaced("string"));
    try testing.expect(!isAlreadyNamespaced("stringify"));
    try testing.expect(!isAlreadyNamespaced("hash"));
    try testing.expect(!isAlreadyNamespaced("mapper"));
}

test "findModuleBySegment: match the name a module is USED under" {
    // `import collections.list;` then `list.List<int>()` — the object is the LAST
    // SEGMENT. Module.path is dot-separated (`std.collections.list`); splitting on
    // '_' (canonicalModulePrefix's format) matched nothing and the whole
    // module-qualified call path silently did nothing.
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
    // a NESTED module is used under its last segment: `list`, not `collections.list`
    const m_list = tab.findModuleBySegment("list") orelse return error.TestExpectedEqual;
    try testing.expect(m_string != m_list);
    try testing.expect(tab.findModuleBySegment("nosuchmodule") == null);

    // and the functions resolve INSIDE their own module, not across
    try testing.expect(tab.findFunctionIn(m_string, "hash") != null);
    try testing.expect(tab.findFunctionIn(m_string, "push") == null);
    try testing.expect(tab.findFunctionIn(m_list, "push") != null);
}

test "build: a method's decl points INTO the AST, not at a dead stack copy" {
    // `for (s.methods) |m|` binds a COPY; `&m.decl` is then the address of a
    // loop-local that dies at the end of the iteration. Every method symbol's
    // decl pointer dangled, and reading `.ret_type` through it returned whatever
    // later occupied that stack slot.
    //
    // It survived because the garbage happened to still parse as a valid TypeRef
    // tag. Widening ast.Expression (stage 4a) shifted the stack layout, the same
    // read hit a different byte pattern, and it became `switch on corrupt value`
    // in lower.zig — a latent use-after-scope, not a new bug.
    //
    // Asserting POINTER IDENTITY rather than reading a field is what makes this
    // deterministic: a dangling read only sometimes looks wrong.
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
    // The one assertion that matters: the symbol must point at the AST's own
    // FunctionDecl, so it stays valid for as long as the AST does.
    try testing.expectEqual(&decls[0].struct_decl.methods[0].decl, sym.decl.function);
}
