//! The compiler's global symbol table: a flat catalogue of every top-level
//! declaration in the whole program, keyed by name, plus the module graph that
//! tells you which file each symbol came from and which files import which.
//!
//! Kyte compiles the entire program (the root file plus every imported stdlib
//! and package module) into ONE monomorphised LLVM module, so at link time all
//! function names live in a single flat namespace. That creates two problems
//! this file exists to solve:
//!
//!   1. **Name collisions across modules.** Two different modules may each
//!      declare a `hash` function or a `Node` struct. Kyte does not erase types,
//!      so both must survive with distinct backing names. The answer is
//!      MODULE-PREFIXED MANGLING: a function `hash` in `src/std/string.ky`
//!      becomes `string_hash`. Types that actually collide get a `scoped_name`
//!      derived the same way; types that are unique keep their bare name so the
//!      common case stays readable.
//!
//!   2. **Resolving a name back to its declaration during sema.** Given an
//!      identifier at a use site (possibly qualified, like `list.push` or
//!      `collections.list.push`), find the one [`Symbol`] it refers to, honouring
//!      the importing module's view. The `findX` family walks the symbol list to
//!      do this, and reports ambiguity (more than one candidate) as a distinct
//!      answer so the caller can raise a proper diagnostic rather than silently
//!      picking one.
//!
//! The table is built once, up front, by [`SymbolTable.build`] from the parsed
//! [`ast.Program`]. It stores BORROWED slices into the AST wherever it can
//! (names, spans, and the `*const ast.*Decl` back-pointers), so it is only valid
//! for as long as the AST it was built from stays alive. The few strings it
//! must synthesise (mangled and scoped names) are allocated and tracked in
//! `owned` so [`SymbolTable.deinit`] can free them.
//!
//! **Mangling comes in two flavours, and both are kept on purpose.** The
//! `legacy_mangled`/`legacyModulePrefix` path reproduces an older, buggy scheme
//! (it leaks absolute `$HOME` path components into the prefix) so that already
//! emitted names still resolve; `canonical_mangled`/`canonicalModulePrefix` is
//! the corrected scheme that maps the same logical module to the same prefix
//! regardless of where on disk it was found. The tests at the bottom pin both
//! behaviours, including the `$HOME` bug in the legacy path, so a refactor cannot
//! accidentally "fix" the thing that must stay bug-compatible.

const std = @import("std");
const ast = @import("../ast.zig");

/// Opaque index of a [`Symbol`] within [`SymbolTable.symbols`].
///
/// A non-exhaustive `enum(u32)` used as a newtype over the array position, so a
/// symbol handle cannot be confused with a [`ModuleId`] or a raw integer.
/// Convert with `@intFromEnum`/`@enumFromInt`; resolve with
/// [`SymbolTable.symbolAt`].
pub const SymbolId = enum(u32) { _ };
/// Opaque index of a [`Module`] within [`SymbolTable.modules`].
///
/// Same newtype-over-array-index pattern as [`SymbolId`]. Assigned densely in
/// insertion order by [`SymbolTable.internModule`]; resolve with
/// [`SymbolTable.moduleOf`].
pub const ModuleId = enum(u32) { _ };

/// What kind of declaration a [`Symbol`] represents.
///
/// `struct_`/`enum_`/`trait_` are trailing-underscored because `struct`, `enum`
/// and `trait` are Zig keywords. `union_` appears in the type-lookup predicates
/// ([`SymbolTable.findType`], [`isTypeSym`]) but the current [`SymbolTable.build`]
/// never emits it, so no `union` declaration reaches the table today. `method`
/// is distinguished from `function` because a method carries an `owner` type
/// name and is looked up by (type, method) pair.
pub const SymbolKind = enum { function, method, struct_, enum_, union_, trait_, constant };

/// Whether a declaration is visible outside its defining module.
///
/// Derived from the source: an exported function or a `pub` struct is `public`,
/// everything else `private`. Only functions and structs carry a real
/// distinction today; enums, traits and constants are always recorded as
/// `public` by [`SymbolTable.build`].
pub const Visibility = enum { public, private };

/// One resolved top-level declaration: its source name, where it lives, how it
/// is spelled in the emitted module, and a back-pointer to its AST node.
///
/// All slice fields borrow from the AST or from [`SymbolTable.owned`]; a
/// `Symbol` never owns its strings. Constructed only by [`SymbolTable.build`].
pub const Symbol = struct {

    /// The declaration's source name, exactly as written (`hash`, `Node`, `get`).
    /// Borrowed from the AST.
    name: []const u8,
    /// The module this symbol was declared in, i.e. an index into
    /// [`SymbolTable.modules`].
    module: ModuleId,
    /// Which sort of declaration this is; see [`SymbolKind`].
    kind: SymbolKind,
    /// Whether the declaration is exported from its module; see [`Visibility`].
    visibility: Visibility,

    /// For a `method`, the source name of the type it hangs off (its receiver);
    /// `null` for every free declaration. Used by [`SymbolTable.findMethod`] to
    /// match on the (type, method) pair.
    owner: ?[]const u8,
    /// Source location of the declaration, borrowed from the AST. Carries the
    /// originating `file`, which is how symbols are attributed to modules.
    span: ast.Span,

    /// The name this symbol is emitted under by the OLD, bug-compatible mangling
    /// scheme (see [`legacyModulePrefix`]). Kept so previously emitted references
    /// keep resolving; do not "fix" it, the legacy `$HOME` leak is intentional.
    legacy_mangled: []const u8,

    /// The name this symbol is emitted under by the CORRECTED mangling scheme
    /// (see [`canonicalModulePrefix`]), which is stable across checkout location.
    canonical_mangled: []const u8,

    /// Back-pointer to the AST node this symbol was built from, tagged by kind;
    /// `.none` until set. See [`Decl`]. Points INTO the program's declaration
    /// array (not a stack copy), which the `build:` test at the bottom pins.
    decl: Decl = .none,

    /// For a type whose bare name COLLIDES with a same-kind type in another
    /// module, the module-prefixed disambiguated name to emit instead; `null`
    /// when the bare name is unique. Filled in by
    /// [`SymbolTable.computeCollidingTypes`]; read via
    /// [`SymbolTable.scopedNameFor`].
    scoped_name: ?[]const u8 = null,
};

/// A tagged pointer back to the AST declaration a [`Symbol`] came from.
///
/// The pointers are borrowed and stable: they reference nodes inside the
/// program's declaration array, so downstream passes can reach the full decl
/// (params, fields, body) from a resolved symbol without a second lookup. Note
/// `method` symbols store their body as a `function` variant (a method's `.decl`
/// is an `ast.FunctionDecl`), so there is no separate `method` tag here.
pub const Decl = union(enum) {
    /// No AST node attached yet (a freshly default-constructed [`Symbol`]).
    none,
    /// A free function, or the body of a method (see [`Decl`] note).
    function: *const ast.FunctionDecl,
    /// A `struct` declaration.
    struct_: *const ast.StructDecl,
    /// An `enum` declaration.
    enum_: *const ast.EnumDecl,
    /// A `trait` declaration.
    trait_: *const ast.TraitDecl,
    /// A top-level `const` declaration.
    constant: *const ast.ConstDecl,
};

/// One compilation module: a source file plus its canonical dotted import path.
///
/// Interned once per distinct `file` by [`SymbolTable.internModule`]. The root
/// program file is recorded with the sentinel `path` `"<root>"` and is skipped
/// by every path-based lookup.
pub const Module = struct {
    /// This module's own index within [`SymbolTable.modules`].
    id: ModuleId,

    /// The canonical dotted module path (`std.string`, `std.collections.list`),
    /// or the sentinel `"<root>"` for the root program file. Produced by
    /// [`canonicalModulePath`]; this is what import names are matched against.
    path: []const u8,

    /// The originating source file path, borrowed from the AST span. The
    /// identity key modules are interned by.
    file: []const u8,
};

/// Derives a module's canonical DOTTED import path from its file path.
///
/// This is the human-facing module identity stored in [`Module.path`] and
/// matched against `import` statements. It strips whichever stdlib root the file
/// lives under (`src/std/`, `src/lib/`, or an installed `.kyte/std/`), drops the
/// extension, turns path separators into dots, and prefixes `std.` for anything
/// that came from a stripped root. So `src/std/collections/list.ky` and
/// `~/.kyte/std/collections/list.ky` both canonicalise to
/// `std.collections.list`, independent of where the checkout lives.
///
/// Returns `null` for files that have no module identity: an empty path, the
/// root program file itself, or the `helpers.ky`/`test_harness.ky` support
/// files. Contrast [`canonicalModulePrefix`], which produces the underscore-
/// joined MANGLING prefix rather than the dotted path.
pub fn canonicalModulePath(allocator: std.mem.Allocator, file: []const u8, root_file: []const u8) !?[]const u8 {
    if (file.len == 0) return null;
    if (std.mem.eql(u8, file, root_file)) return null;
    if (std.mem.eql(u8, file, "helpers.ky") or std.mem.eql(u8, file, "test_harness.ky")) return null;

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

        if (std.mem.indexOf(u8, path, ".kyte/std/")) |pos| {
            path = path[pos + ".kyte/std/".len ..];
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

/// Derives the CORRECTED underscore-joined mangling prefix for a module.
///
/// This is the prefix glued onto a function name to keep same-named functions in
/// different modules distinct in the flat emitted namespace: `hash` in
/// `src/std/string.ky` mangles as `string_hash`. It strips whichever stdlib
/// root the file lives under (including the installed `.kyte/std/`, `.kyte/lib/`
/// forms), drops the extension, and replaces `/`, `\` and `.` with `_`.
///
/// "Corrected" is meaningful here: because it strips the installed roots too, a
/// module found at `~/.kyte/std/string.ky` yields the same `string` prefix as
/// the in-tree `src/std/string.ky`, so no absolute `$HOME` component leaks into
/// the mangled name. That is exactly the [`legacyModulePrefix`] bug this function
/// avoids. Returns `null` for the same non-module files as [`canonicalModulePath`].
pub fn canonicalModulePrefix(allocator: std.mem.Allocator, file: []const u8, root_file: []const u8) !?[]const u8 {
    if (file.len == 0) return null;
    if (std.mem.eql(u8, file, root_file)) return null;
    if (std.mem.eql(u8, file, "helpers.ky") or std.mem.eql(u8, file, "test_harness.ky")) return null;
    var path = file;
    const roots = [_][]const u8{ "src/std/", "src/lib/", ".kyte/std/", ".kyte/lib/" };
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

/// Reproduces the OLD, bug-compatible mangling prefix for a module.
///
/// Kept verbatim so that names emitted under the historical scheme still
/// resolve. It strips ONLY the in-tree `src/std/` and `src/lib/` roots (via
/// `startsWith`, so the root must be a genuine prefix), and does NOT strip the
/// installed `.kyte/std/` form. Consequently a module loaded from
/// `~/.kyte/std/string.ky` keeps the whole absolute path (minus extension,
/// separators to `_`), leaking the `$HOME` components into the mangled name.
///
/// This `$HOME` leak is a deliberate bug preserved for compatibility, not an
/// oversight: the "legacyModulePrefix reproduces the OLD behaviour" test at the
/// bottom asserts the leak is still present. Use [`canonicalModulePrefix`] for
/// new, location-stable names. Same `null` cases as the other two.
pub fn legacyModulePrefix(allocator: std.mem.Allocator, file: []const u8, root_file: []const u8) !?[]const u8 {
    if (file.len == 0) return null;
    if (std.mem.eql(u8, file, root_file)) return null;
    if (std.mem.eql(u8, file, "helpers.ky") or std.mem.eql(u8, file, "test_harness.ky")) return null;
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

/// One resolved `import` edge: importer module → imported module, remembered
/// under the local `segment` name it is referenced by.
///
/// Recorded by [`SymbolTable.build`]'s second pass after every module is
/// interned, and consulted by [`SymbolTable.resolveImportedModule`] and
/// [`SymbolTable.findTypeViaImports`] so a name is resolved from the importing
/// module's point of view rather than globally.
pub const Import = struct {
    /// The module that wrote the `import`.
    importer: ModuleId,
    /// The module it resolved to.
    imported: ModuleId,
    /// The trailing path segment the import is spelled with locally (the part
    /// after the last `.`/`/`), e.g. `list` for `import std.collections.list`.
    /// This is the token a qualified use like `list.push` matches against.
    segment: []const u8,
};

/// The whole-program symbol catalogue and module graph.
///
/// Flat by design: symbols and modules are plain append-only arrays and every
/// lookup is a linear scan. That is deliberate for the program sizes involved
/// (build once, query during sema); there is no hash index keyed by name. The
/// one hash map, [`SymbolTable.colliding_types`], is a small set of names that
/// need scoped mangling, not a lookup index.
///
/// Lifetime: borrows names/spans/AST pointers from the [`ast.Program`] passed to
/// [`SymbolTable.build`], so it must not outlive that AST. Strings it synthesises
/// are tracked in `owned` and freed by [`SymbolTable.deinit`].
pub const SymbolTable = struct {
    /// Allocator backing every array and every owned string.
    allocator: std.mem.Allocator,
    /// Every top-level declaration, in discovery order. A [`SymbolId`] indexes
    /// this; the `findX` methods scan it linearly.
    symbols: std.ArrayListUnmanaged(Symbol) = .empty,
    /// Every distinct module, interned by file. A [`ModuleId`] indexes this.
    modules: std.ArrayListUnmanaged(Module) = .empty,

    /// Every resolved `import` edge; see [`Import`].
    imports: std.ArrayListUnmanaged(Import) = .empty,

    /// Strings this table allocated (mangled/scoped names). Held so
    /// [`SymbolTable.deinit`] can free them; symbols store borrowed slices into
    /// these. See [`SymbolTable.own`].
    owned: std.ArrayListUnmanaged([]const u8) = .empty,
    /// The root program's file path, set at the start of [`SymbolTable.build`].
    /// Every module-path helper takes this to recognise (and skip) the root file.
    root_file: []const u8 = "",

    /// Set of type names that appear in more than one module and therefore need a
    /// disambiguated [`Symbol.scoped_name`]. Populated by
    /// [`SymbolTable.computeCollidingTypes`], read by [`SymbolTable.scopedNameFor`].
    colliding_types: std.StringHashMapUnmanaged(void) = .empty,

    /// Creates an empty table bound to `allocator`. Fill it with
    /// [`SymbolTable.build`].
    pub fn init(allocator: std.mem.Allocator) SymbolTable {
        return .{ .allocator = allocator };
    }

    /// Frees the owned strings and all backing arrays.
    ///
    /// Only the strings in `owned` are freed; every other slice a [`Symbol`] or
    /// [`Module`] holds is borrowed from the AST and left untouched.
    pub fn deinit(self: *SymbolTable) void {
        for (self.owned.items) |s| self.allocator.free(s);
        self.owned.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.imports.deinit(self.allocator);
        self.colliding_types.deinit(self.allocator);
    }

    /// Returns the disambiguated name a colliding type should be emitted under
    /// in `file`, or `null` if the name is unique (and thus emitted as-is).
    ///
    /// Short-circuits on the common case: if `name` is not in
    /// [`SymbolTable.colliding_types`] it returns `null` immediately without
    /// scanning. Otherwise it finds the type symbol of that name declared in
    /// `file` and returns its precomputed [`Symbol.scoped_name`]. The `file`
    /// argument is what selects WHICH colliding declaration you meant.
    pub fn scopedNameFor(self: *const SymbolTable, name: []const u8, file: []const u8) ?[]const u8 {
        if (!self.colliding_types.contains(name)) return null;
        for (self.symbols.items) |s| {
            if (!isTypeSym(s.kind) or !std.mem.eql(u8, s.name, name)) continue;
            const mfile = self.modules.items[@intFromEnum(s.module)].file;
            if (std.mem.eql(u8, mfile, file)) return s.scoped_name;
        }
        return null;
    }

    /// Builds the scoped mangled name for a colliding type in `file`.
    ///
    /// Uses the LEGACY module prefix (so the scoped name matches the historical
    /// mangling of the module it lives in): `<prefix>_<name>` when the file maps
    /// to a module prefix, else `root_<name>` for a type declared in the root
    /// program. The result is interned via [`SymbolTable.own`]. Called only from
    /// [`SymbolTable.computeCollidingTypes`].
    fn computeScopedName(self: *SymbolTable, name: []const u8, file: []const u8) !?[]const u8 {
        const prefix = try legacyModulePrefix(self.allocator, file, self.root_file);
        if (prefix) |p| {
            defer self.allocator.free(p);
            return try self.own(try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ p, name }));
        }
        return try self.own(try std.fmt.allocPrint(self.allocator, "root_{s}", .{name}));
    }

    /// Finds every type name shared across modules and assigns each such type a
    /// [`Symbol.scoped_name`]. Run once at the end of [`SymbolTable.build`].
    ///
    /// Two passes. The first is an O(n^2) upper-triangular scan that records a
    /// name in [`SymbolTable.colliding_types`] as soon as it sees two `struct` or
    /// `enum` symbols of the SAME kind in DIFFERENT modules sharing that name
    /// (traits/unions are not scoped). The second pass then stamps a scoped name
    /// onto every scopable symbol whose name landed in that set. Only `struct`
    /// and `enum` collide here because those are the types that get distinct
    /// backing definitions; same-named traits do not need per-module bodies.
    fn computeCollidingTypes(self: *SymbolTable) !void {
        // True for the type kinds that participate in collision scoping
        // (`struct` and `enum` only).
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

    /// Compares two module-path strings treating `/` and `.` as equivalent
    /// separators.
    ///
    /// Lets `std/collections/list` match `std.collections.list`, so a path built
    /// with either convention resolves the same. Only `/` is normalised to `.`
    /// (a literal `.` already equals a normalised `/`), and the lengths must
    /// match, so this is a same-length char-by-char comparison, not a fuzzy one.
    fn sepAgnosticEql(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            const na = if (ca == '/') '.' else ca;
            const nb = if (cb == '/') '.' else cb;
            if (na != nb) return false;
        }
        return true;
    }

    /// Returns the final segment of a dotted-or-slashed module name.
    ///
    /// Cuts after the LAST `.` or `/` (whichever is further right), so
    /// `std.collections.list` and `std/collections/list` both yield `list`. If
    /// there is no separator the whole name is returned. This is the leaf name a
    /// module is used under at a call site.
    fn lastSegment(name: []const u8) []const u8 {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.');
        const slash = std.mem.lastIndexOfScalar(u8, name, '/');
        const cut: ?usize = if (dot) |d| (if (slash) |s| @max(d, s) else d) else slash;
        return if (cut) |i| name[i + 1 ..] else name;
    }

    /// Returns the directory portion of a FILE path (everything before the last
    /// `/` or `\`), or `""` if the path has no separator.
    ///
    /// Used by [`SymbolTable.findModuleByImportNameForImporter`] to prefer a
    /// module sitting in the importer's own directory.
    fn dirOf(path: []const u8) []const u8 {
        const slash = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return "";
        return path[0..slash];
    }
    /// Returns a file's base name with directory and extension stripped
    /// (`a/b/list.ky` → `list`).
    ///
    /// The sibling-directory counterpart to [`SymbolTable.dirOf`]; together they
    /// let an import be matched to a same-directory file by leaf name.
    fn fileBaseNoExt(path: []const u8) []const u8 {
        const slash = std.mem.lastIndexOfAny(u8, path, "/\\");
        const base = if (slash) |s| path[s + 1 ..] else path;
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
        return base[0..dot];
    }

    /// Resolves an import name to a module, preferring a sibling file in the
    /// importer's own directory before falling back to a global search.
    ///
    /// This is what makes a bare `import foo` next to `foo.ky` pick the local
    /// file rather than an unrelated stdlib module of the same leaf name: it
    /// first looks for a module whose directory equals the importer's and whose
    /// base name equals the import's last segment. Only if that finds nothing
    /// does it defer to [`SymbolTable.findModuleByImportName`].
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

    /// Resolves an import name to a module by dotted path, then by leaf segment.
    ///
    /// Two-stage match, both skipping the `"<root>"` module. First it looks for a
    /// FULL path match, separator-agnostically ([`SymbolTable.sepAgnosticEql`]) and
    /// also against the path with a leading `std.` stripped, so both
    /// `import std.string` and `import string` hit `std.string`. If no full match
    /// exists it falls back to matching just the last segment, so a bare
    /// `import list` finds `std.collections.list`. Returns the first match; use
    /// [`SymbolTable.findModuleByImportNameForImporter`] when directory context
    /// should take precedence.
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

    /// Finds the module whose source file path is exactly `file`, or `null`.
    ///
    /// Exact byte match on the file path, the same identity key modules are
    /// interned under by [`SymbolTable.internModule`].
    pub fn findModuleByFile(self: *const SymbolTable, file: []const u8) ?ModuleId {
        for (self.modules.items) |m| {
            if (std.mem.eql(u8, m.file, file)) return m.id;
        }
        return null;
    }

    /// Resolves a local `segment` name to the module `importer` imported it as.
    ///
    /// Consults the recorded [`Import`] edges rather than the global module list,
    /// so it answers "what does `list` mean INSIDE this module" using only that
    /// module's own imports. Returns `null` if the importer never imported
    /// anything under that segment.
    pub fn resolveImportedModule(self: *const SymbolTable, importer: ModuleId, segment: []const u8) ?ModuleId {
        for (self.imports.items) |imp| {
            if (imp.importer == importer and std.mem.eql(u8, imp.segment, segment)) return imp.imported;
        }
        return null;
    }

    /// Records an allocated string so [`SymbolTable.deinit`] will free it, and
    /// returns it unchanged for convenient chaining.
    ///
    /// Every synthesised name (mangled prefixes, scoped names) must pass through
    /// here; slices stored on a [`Symbol`] then borrow from this owned list.
    fn own(self: *SymbolTable, s: []const u8) ![]const u8 {
        try self.owned.append(self.allocator, s);
        return s;
    }

    /// Returns the [`ModuleId`] for `file`, creating and appending a new
    /// [`Module`] the first time a file is seen.
    ///
    /// Idempotent per file: a linear scan reuses an existing module so a file
    /// maps to exactly one id. New ids are assigned densely from the current
    /// module count. The canonical dotted path comes from
    /// [`canonicalModulePath`]; a file with no module identity (the root program)
    /// is stored with the `"<root>"` sentinel path.
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

    /// Returns the [`Module`] for a [`ModuleId`] by direct array index.
    ///
    /// Assumes `id` was produced by this table; there is no bounds check beyond
    /// the array access itself.
    pub fn moduleOf(self: *SymbolTable, id: ModuleId) Module {
        return self.modules.items[@intFromEnum(id)];
    }

    /// Finds the first type symbol (struct/enum/trait/union) named `name`, or
    /// `null`.
    ///
    /// Ignores functions, methods and constants, and returns the FIRST match
    /// regardless of module, so it is the un-scoped, un-contextual lookup. When
    /// the name might collide across modules use
    /// [`SymbolTable.findTypeInModule`] (context-aware) and check
    /// [`SymbolTable.findTypeAmbiguous`] first.
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

    /// True for any kind that names a TYPE (struct, enum, trait or union).
    ///
    /// Broader than [`SymbolTable.computeCollidingTypes`]'s `scopable` (which is
    /// struct/enum only): this is the set that participates in type resolution,
    /// while only a subset gets per-module scoping.
    fn isTypeSym(k: SymbolKind) bool {
        return k == .struct_ or k == .enum_ or k == .trait_ or k == .union_;
    }

    /// Finds a type named `name` as seen from module `ctx`, honouring imports.
    ///
    /// Resolution order when `ctx` is given: a type declared IN `ctx` wins first;
    /// otherwise a type reachable through `ctx`'s imports
    /// ([`SymbolTable.findTypeViaImports`]); and only then the global
    /// first-match [`SymbolTable.findType`]. Passing `ctx == null` collapses to
    /// the plain global lookup. This is how the same bare type name resolves to
    /// the right module-local definition.
    pub fn findTypeInModule(self: *const SymbolTable, name: []const u8, ctx: ?ModuleId) ?SymbolId {
        if (ctx) |cm| {
            for (self.symbols.items, 0..) |sym, i| {
                if (isTypeSym(sym.kind) and sym.module == cm and std.mem.eql(u8, sym.name, name))
                    return @enumFromInt(@as(u32, @intCast(i)));
            }
            if (self.findTypeViaImports(name, cm)) |sid| return sid;
        }
        return self.findType(name);
    }

    /// Finds a type `name` reachable through module `cm`'s imports, requiring the
    /// match to be UNAMBIGUOUS.
    ///
    /// Scans only the modules `cm` imports. If the name is found in exactly one
    /// imported module it returns that symbol; if two DIFFERENT imported modules
    /// both export the name it returns `null` (ambiguous, so the caller must not
    /// guess). Multiple matches within the SAME imported module are fine, they do
    /// not count as ambiguity. Called by [`SymbolTable.findTypeInModule`].
    fn findTypeViaImports(self: *const SymbolTable, name: []const u8, cm: ModuleId) ?SymbolId {
        var found: ?SymbolId = null;
        var found_mod: ?ModuleId = null;
        for (self.imports.items) |imp| {
            if (imp.importer != cm) continue;
            for (self.symbols.items, 0..) |sym, i| {
                if (!isTypeSym(sym.kind) or sym.module != imp.imported) continue;
                if (!std.mem.eql(u8, sym.name, name)) continue;
                if (found_mod) |fm| {
                    if (fm != sym.module) return null;
                } else {
                    found = @enumFromInt(@as(u32, @intCast(i)));
                    found_mod = sym.module;
                }
            }
        }
        return found;
    }

    /// True if more than one type symbol in the whole program is named `name`.
    ///
    /// A global count across struct/enum/trait/union kinds; the signal a caller
    /// uses to reject an unqualified type reference as ambiguous before trusting
    /// [`SymbolTable.findType`]'s first-match answer.
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

    /// Finds the first free FUNCTION named `name`, or `null`.
    ///
    /// Methods are excluded (they are matched by (type, method) via
    /// [`SymbolTable.findMethod`]). Returns the first match across all modules;
    /// pair with [`SymbolTable.findFunctionAmbiguous`] when the name may be
    /// declared in several modules.
    pub fn findFunction(self: *const SymbolTable, name: []const u8) ?SymbolId {
        for (self.symbols.items, 0..) |sym, i| {
            if (sym.kind != .function) continue;
            if (std.mem.eql(u8, sym.name, name)) return @enumFromInt(@as(u32, @intCast(i)));
        }
        return null;
    }

    /// True if more than one free function in the program is named `name`.
    ///
    /// The ambiguity guard for [`SymbolTable.findFunction`]; a global count over
    /// `function` symbols only.
    pub fn findFunctionAmbiguous(self: *const SymbolTable, name: []const u8) bool {
        var n: usize = 0;
        for (self.symbols.items) |sym| {
            if (sym.kind != .function) continue;
            if (std.mem.eql(u8, sym.name, name)) n += 1;
        }
        return n > 1;
    }

    /// Finds a method `method` declared on type `type_name`, or `null`.
    ///
    /// Matches a `method` symbol whose [`Symbol.owner`] equals `type_name` and
    /// whose name equals `method`. First match across all modules; the
    /// module-scoped variant is [`SymbolTable.findMethodInModule`].
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

    /// Finds `type_name.method` preferring the method defined in
    /// `owner_module`, falling back to a global search.
    ///
    /// Disambiguates when the same type name (and method) exists in more than one
    /// module: it first looks only within `owner_module`, and only if that misses
    /// does it defer to [`SymbolTable.findMethod`]. Used when the receiver type's
    /// home module is already known.
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

    /// Finds a module whose LAST path segment equals `name`, or `null`.
    ///
    /// Matches on the leaf of the dotted [`Module.path`] (`std.collections.list`
    /// matches `list`), skipping `"<root>"`. This is how a qualified use like
    /// `list.push` locates the module `list` refers to when no import context is
    /// available. Returns the first match; check
    /// [`SymbolTable.segmentIsAmbiguous`] when two modules could share a leaf.
    pub fn findModuleBySegment(self: *const SymbolTable, name: []const u8) ?ModuleId {
        for (self.modules.items) |m| {
            if (std.mem.eql(u8, m.path, "<root>")) continue;

            const seg = if (std.mem.lastIndexOfScalar(u8, m.path, '.')) |i| m.path[i + 1 ..] else m.path;
            if (std.mem.eql(u8, seg, name)) return m.id;
        }
        return null;
    }

    /// Finds function `name` inside the module addressed by `segment`, requiring
    /// the result to be UNAMBIGUOUS.
    ///
    /// Resolves a qualified call `segment.name`: it visits every module whose leaf
    /// segment is `segment` and looks for `name` in each
    /// ([`SymbolTable.findFunctionIn`]). If two different `segment` modules both
    /// contain the function it returns `null` rather than guessing; a single hit
    /// is returned. Complements [`SymbolTable.findModuleBySegment`], which
    /// resolves the module part alone.
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

    /// True if more than one module shares the leaf path `segment`.
    ///
    /// The ambiguity guard for [`SymbolTable.findModuleBySegment`] and
    /// [`SymbolTable.findFunctionBySegment`]: counts non-root modules whose last
    /// path segment equals `segment`.
    pub fn segmentIsAmbiguous(self: *const SymbolTable, segment: []const u8) bool {
        var n: usize = 0;
        for (self.modules.items) |m| {
            if (std.mem.eql(u8, m.path, "<root>")) continue;
            const seg = if (std.mem.lastIndexOfScalar(u8, m.path, '.')) |i| m.path[i + 1 ..] else m.path;
            if (std.mem.eql(u8, seg, segment)) n += 1;
        }
        return n > 1;
    }

    /// Finds function `name` declared in a specific module `mod`, or `null`.
    ///
    /// The module-restricted counterpart to [`SymbolTable.findFunction`]; used as
    /// the inner step of [`SymbolTable.findFunctionBySegment`].
    pub fn findFunctionIn(self: *const SymbolTable, mod: ModuleId, name: []const u8) ?SymbolId {
        for (self.symbols.items, 0..) |sym, i| {
            if (sym.kind != .function) continue;
            if (sym.module != mod) continue;
            if (std.mem.eql(u8, sym.name, name)) return @enumFromInt(@as(u32, @intCast(i)));
        }
        return null;
    }

    /// Returns the [`Symbol`] for a [`SymbolId`] by direct array index.
    ///
    /// The inverse of the `@enumFromInt(i)` every `findX` returns; assumes the id
    /// came from this table.
    pub fn symbolAt(self: *const SymbolTable, id: SymbolId) Symbol {
        return self.symbols.items[@intFromEnum(id)];
    }

    /// Appends a fully constructed [`Symbol`] to the table. Sole insertion point,
    /// used throughout [`SymbolTable.build`].
    fn addSymbol(self: *SymbolTable, sym: Symbol) !void {
        try self.symbols.append(self.allocator, sym);
    }

    /// Populates the table from a parsed program: interns modules, records every
    /// top-level declaration and its methods, wires up imports, and computes type
    /// collisions.
    ///
    /// Runs in three phases. (1) It walks `program.declarations`, interning each
    /// declaration's module and adding a [`Symbol`] for functions, structs (plus
    /// their methods), enums (plus their methods), traits and constants; other
    /// declaration kinds are ignored. Each symbol's [`Decl`] back-pointer is taken
    /// from `&decl_ptr.<field>` (the array element), NOT from the loop's by-value
    /// `decl` copy, so the pointer stays valid after the loop, which the
    /// "points INTO the AST" test pins. (2) A second walk records `import`
    /// edges, skipping the built-in `bytes` module and any import that does not
    /// resolve, and derives the local `segment` from the import's last path
    /// component. (3) It runs [`SymbolTable.computeCollidingTypes`] to assign
    /// scoped names.
    ///
    /// Method symbols are given a `<Type>_<method>` mangled name for BOTH the
    /// legacy and canonical fields (methods are already qualified by their owner,
    /// so they need no module prefix) and visibility `public`. Struct/enum
    /// visibility follows the source `pub`/export flag; enums, traits and
    /// constants are recorded as `public` unconditionally.
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

    /// Computes the CANONICAL mangled name for a free function.
    ///
    /// Returns `<prefix>_<name>` using [`canonicalModulePrefix`], unless the file
    /// has no module prefix (root program), in which case the bare name is used.
    /// If the name is ALREADY namespaced ([`isAlreadyNamespaced`], e.g. a stdlib
    /// function that hand-writes its `string_` prefix) it is returned untouched to
    /// avoid a double prefix. See [`legacyNameForFn`] for the bug-compatible twin.
    fn canonicalNameForFn(self: *SymbolTable, f: ast.FunctionDecl) ![]const u8 {
        if (try canonicalModulePrefix(self.allocator, f.span.file, self.root_file)) |prefix| {
            defer self.allocator.free(prefix);
            if (isAlreadyNamespaced(f.name)) return f.name;
            return try self.own(try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, f.name }));
        }
        return f.name;
    }

    /// Computes the LEGACY mangled name for a free function.
    ///
    /// Identical shape to [`canonicalNameForFn`] but built on
    /// [`legacyModulePrefix`], so it inherits the historical `$HOME`-leaking
    /// prefix for installed-stdlib files. Kept so previously emitted references
    /// keep resolving. Also skips re-prefixing an [`isAlreadyNamespaced`] name.
    fn legacyNameForFn(self: *SymbolTable, f: ast.FunctionDecl) ![]const u8 {

        if (try legacyModulePrefix(self.allocator, f.span.file, self.root_file)) |prefix| {
            defer self.allocator.free(prefix);
            if (isAlreadyNamespaced(f.name)) return f.name;
            return try self.own(try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, f.name }));
        }
        return f.name;
    }
};

/// True if a function name already carries one of the known stdlib module
/// prefixes (so it must NOT be prefixed again by the manglers).
///
/// Matches an allowlisted prefix followed by an underscore: `string_concat` and
/// `map_reduce` are namespaced, but `string`, `stringify` and `mapper` are not
/// (the `_` boundary is required, so a prefix that is merely a substring of a
/// longer word does not count). This is what stops a hand-written `string_hash`
/// in `src/std/string.ky` becoming `string_string_hash`. Consulted by
/// [`SymbolTable.canonicalNameForFn`] and [`SymbolTable.legacyNameForFn`].
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

/// Shorthand for the test allocator and assertion helpers used below.
const testing = std.testing;

// Pins the point of [`canonicalModulePrefix`]: a module found in-tree
// (`src/std/string.ky`) and the same module installed under `~/.kyte/std/`
// must produce the identical `string` prefix, with no `$HOME` component leaking
// in. This is the exact behaviour the legacy path gets wrong on purpose.
test "canonicalModulePrefix: the SAME file yields the SAME prefix from any root" {
    const a = testing.allocator;

    const via_src = (try canonicalModulePrefix(a, "src/std/string.ky", "app.ky")).?;
    defer a.free(via_src);
    const via_home = (try canonicalModulePrefix(a, "/Users/someone/.kyte/std/string.ky", "app.ky")).?;
    defer a.free(via_home);
    try testing.expectEqualStrings("string", via_src);
    try testing.expectEqualStrings("string", via_home);
    try testing.expect(std.mem.indexOf(u8, via_home, "Users") == null);
}

// Checks that a NESTED module keeps its full sub-path in the prefix, with
// separators flattened to `_`: `collections/list.ky` → `collections_list`,
// again identically whether found in-tree or under `.kyte/std/`.
test "canonicalModulePrefix: nested modules keep their path, slashes become underscores" {
    const a = testing.allocator;
    const p = (try canonicalModulePrefix(a, "src/std/collections/list.ky", "app.ky")).?;
    defer a.free(p);
    try testing.expectEqualStrings("collections_list", p);
    const q = (try canonicalModulePrefix(a, "/home/x/.kyte/std/collections/list.ky", "app.ky")).?;
    defer a.free(q);
    try testing.expectEqualStrings("collections_list", q);
}

// Checks that an absolute checkout path (`/abs/checkout/lang/src/std/...`) is
// still stripped down to the module prefix, since `src/std/` is matched
// anywhere in the path rather than only as a leading prefix.
test "canonicalModulePrefix: an absolute checkout path still canonicalises" {
    const a = testing.allocator;

    const p = (try canonicalModulePrefix(a, "/abs/checkout/lang/src/std/string.ky", "app.ky")).?;
    defer a.free(p);
    try testing.expectEqualStrings("string", p);
}

// Checks the `null` cases: the root program file itself, the `helpers.ky`
// and `test_harness.ky` support files, and an empty path all have no module
// identity and therefore no prefix.
test "canonicalModulePrefix: the root program and harness files have no prefix" {
    const a = testing.allocator;
    try testing.expect(try canonicalModulePrefix(a, "app.ky", "app.ky") == null);
    try testing.expect(try canonicalModulePrefix(a, "helpers.ky", "app.ky") == null);
    try testing.expect(try canonicalModulePrefix(a, "test_harness.ky", "app.ky") == null);
    try testing.expect(try canonicalModulePrefix(a, "", "app.ky") == null);
}

// Locks in the bug on purpose: [`legacyModulePrefix`] must STILL leak the
// `$HOME` path components for an installed-stdlib file, and must therefore
// differ from the in-tree prefix. If someone "fixes" the legacy path this test
// fails, which is the intended tripwire.
test "legacyModulePrefix reproduces the OLD behaviour, including the $HOME bug" {

    const a = testing.allocator;
    const via_src = (try legacyModulePrefix(a, "src/std/string.ky", "app.ky")).?;
    defer a.free(via_src);
    try testing.expectEqualStrings("string", via_src);

    const via_home = (try legacyModulePrefix(a, "/Users/kamlesh/.kyte/std/string.ky", "app.ky")).?;
    defer a.free(via_home);

    try testing.expect(std.mem.indexOf(u8, via_home, "Users") != null);
    try testing.expect(!std.mem.eql(u8, via_src, via_home));
}

// Checks the `_`-boundary rule of [`isAlreadyNamespaced`]: `string_concat`,
// `map_reduce`, `set_value` are namespaced, but the bare prefix words
// `string`/`hash` and the mere-substring cases `stringify`/`mapper` are not.
test "isAlreadyNamespaced: an allowlisted prefix must be followed by '_'" {

    try testing.expect(isAlreadyNamespaced("string_concat"));
    try testing.expect(isAlreadyNamespaced("map_reduce"));
    try testing.expect(isAlreadyNamespaced("set_value"));

    try testing.expect(!isAlreadyNamespaced("string"));
    try testing.expect(!isAlreadyNamespaced("stringify"));
    try testing.expect(!isAlreadyNamespaced("hash"));
    try testing.expect(!isAlreadyNamespaced("mapper"));
}

// End-to-end check of segment resolution: after building a table with a
// `string` module and a nested `collections/list` module,
// [`SymbolTable.findModuleBySegment`] resolves each by its leaf name, the two
// are distinct, an unknown segment is `null`, and
// [`SymbolTable.findFunctionIn`] finds each module's function only in its own
// module.
test "findModuleBySegment: match the name a module is USED under" {

    const a = testing.allocator;
    var tab = SymbolTable.init(a);
    defer tab.deinit();
    var decls = [_]ast.Declaration{
        .{ .fn_decl = .{
            .name = "hash",
            .params = &.{},
            .ret_type = null,
            .body = .{ .statements = &.{}, .span = .{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "src/std/string.ky" } },
            .is_exported = true,
            .attributes = &.{},
            .span = .{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "src/std/string.ky" },
        } },
        .{ .fn_decl = .{
            .name = "push",
            .params = &.{},
            .ret_type = null,
            .body = .{ .statements = &.{}, .span = .{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "src/std/collections/list.ky" } },
            .is_exported = true,
            .attributes = &.{},
            .span = .{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "src/std/collections/list.ky" },
        } },
    };
    try tab.build(.{ .declarations = &decls, .span = .{ .start = 0, .end = 0, .line = 0, .col = 0, .file = "app.ky" } });

    const m_string = tab.findModuleBySegment("string") orelse return error.TestExpectedEqual;

    const m_list = tab.findModuleBySegment("list") orelse return error.TestExpectedEqual;
    try testing.expect(m_string != m_list);
    try testing.expect(tab.findModuleBySegment("nosuchmodule") == null);

    try testing.expect(tab.findFunctionIn(m_string, "hash") != null);
    try testing.expect(tab.findFunctionIn(m_string, "push") == null);
    try testing.expect(tab.findFunctionIn(m_list, "push") != null);
}

// Guards the subtle back-pointer invariant in [`SymbolTable.build`]: a method
// symbol's [`Decl`] must point at the method node INSIDE the program's
// declaration array, not at the by-value `decl` copy the build loop iterates.
// The final `expectEqual` compares the stored pointer against
// `&decls[0].struct_decl.methods[0].decl` to prove it aliases live AST.
test "build: a method's decl points INTO the AST, not at a dead stack copy" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.ky" };

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
