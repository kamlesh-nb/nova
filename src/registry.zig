//! A central registry / discovery layer for the package manager. A registry is an INDEX -- a directory (or,
//! once cloned, a git repo) with one `<name>.json` per package listing its published versions and where each
//! lives:
//!
//!   { "name": "nova-http",
//!     "versions": [ { "version": "1.0.0", "url": "https://github.com/x/nova-http", "ref": "v1.0.0" },
//!                   { "version": "1.2.0", "url": "https://github.com/x/nova-http", "ref": "9f3c..." } ] }
//!
//! This lets a manifest depend on a package by NAME + a semver RANGE (`"nova-http@^1.2.0"`) instead of a raw
//! git URL. `resolve` picks the newest published version satisfying the range (semver.maxSatisfying) and
//! returns its git url#ref, which the existing fetch path consumes unchanged. `unify` picks the newest
//! version satisfying SEVERAL ranges at once (dependency-tree version unification). Cargo-style git index;
//! a local-directory index makes the whole mechanism testable offline.

const std = @import("std");
const Io = std.Io;
const semver = @import("semver.zig");

pub const IndexVersion = struct { version: []const u8, url: []const u8, ref: ?[]const u8 = null };
pub const IndexEntry = struct { name: []const u8, versions: []IndexVersion };

pub const NameDep = struct { name: []const u8, range: []const u8 };
pub const Resolved = struct { url: []const u8, ref: ?[]const u8, version: []const u8 };

/// Parse a dependency string that names a registry package: `name` or `name@range`. Returns null if the
/// string is a git URL (contains "://" or a '/'), so the URL path is left untouched.
pub fn parseNameDep(dep: []const u8) ?NameDep {
    if (std.mem.indexOf(u8, dep, "://") != null) return null;
    if (std.mem.indexOfScalar(u8, dep, '/') != null) return null;
    if (dep.len == 0) return null;
    // `@range` -- but not a leading '@' scope (we don't support scopes), so require a name before '@'.
    if (std.mem.lastIndexOfScalar(u8, dep, '@')) |at| {
        if (at == 0) return null;
        const range = if (at + 1 < dep.len) dep[at + 1 ..] else "*";
        return .{ .name = dep[0..at], .range = range };
    }
    return .{ .name = dep, .range = "*" };
}

// Read + parse `<index_dir>/<name>.json`. Caller owns via `allocator`.
fn readEntry(allocator: std.mem.Allocator, io: std.Io, index_dir: []const u8, name: []const u8) ?std.json.Parsed(IndexEntry) {
    const fname = std.fmt.allocPrint(allocator, "{s}.json", .{name}) catch return null;
    const path = std.fs.path.join(allocator, &[_][]const u8{ index_dir, fname }) catch return null;
    const data = Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited) catch return null;
    return std.json.parseFromSlice(IndexEntry, allocator, data, .{ .ignore_unknown_fields = true }) catch null;
}

// Pure resolution over an already-parsed index entry (no I/O) -- the testable core.
pub fn resolveEntry(allocator: std.mem.Allocator, entry: IndexEntry, range: []const u8) ?Resolved {
    return pickBy(allocator, entry, semver.maxSatisfying, range);
}
pub fn unifyEntry(allocator: std.mem.Allocator, entry: IndexEntry, ranges: []const []const u8) ?Resolved {
    var versions = std.ArrayList([]const u8).empty;
    for (entry.versions) |v| versions.append(allocator, v.version) catch return null;
    const chosen = semver.unify(ranges, versions.items) orelse return null;
    return findVersion(entry, chosen);
}
fn pickBy(allocator: std.mem.Allocator, entry: IndexEntry, comptime f: fn ([]const u8, []const []const u8) ?[]const u8, range: []const u8) ?Resolved {
    var versions = std.ArrayList([]const u8).empty;
    for (entry.versions) |v| versions.append(allocator, v.version) catch return null;
    const chosen = f(range, versions.items) orelse return null;
    return findVersion(entry, chosen);
}
fn findVersion(entry: IndexEntry, version: []const u8) ?Resolved {
    for (entry.versions) |v| {
        if (std.mem.eql(u8, v.version, version)) return .{ .url = v.url, .ref = v.ref, .version = v.version };
    }
    return null;
}

/// Resolve `name@range` against the index at `index_dir` to a concrete git url#ref (the newest published
/// version satisfying the range). Returns null if the package is unknown or no version satisfies.
pub fn resolve(allocator: std.mem.Allocator, io: std.Io, index_dir: []const u8, name: []const u8, range: []const u8) ?Resolved {
    const parsed = readEntry(allocator, io, index_dir, name) orelse return null;
    return resolveEntry(allocator, parsed.value, range);
}

/// The newest published version of `name` satisfying EVERY range in `ranges` (version unification), or null.
pub fn unify(allocator: std.mem.Allocator, io: std.Io, index_dir: []const u8, name: []const u8, ranges: []const []const u8) ?Resolved {
    const parsed = readEntry(allocator, io, index_dir, name) orelse return null;
    return unifyEntry(allocator, parsed.value, ranges);
}

/// Rewrite a name-form dependency into the `url#ref` form the fetch path expects, using the registry at
/// `index_dir`. A URL-form dep (or an unresolvable/unknown one) is returned unchanged, so this is a safe,
/// additive hook: with no registry configured it is never called, and a plain git-URL project is untouched.
pub fn rewriteDep(allocator: std.mem.Allocator, io: std.Io, index_dir: []const u8, dep: []const u8) []const u8 {
    const nd = parseNameDep(dep) orelse return dep;
    const r = resolve(allocator, io, index_dir, nd.name, nd.range) orelse return dep;
    if (r.ref) |ref| {
        return std.fmt.allocPrint(allocator, "{s}#{s}", .{ r.url, ref }) catch dep;
    }
    return r.url;
}

// ---- tests ------------------------------------------------------------------------------------------------

test "parseNameDep" {
    try std.testing.expect(parseNameDep("https://github.com/x/y") == null);
    try std.testing.expect(parseNameDep("github.com/x/y") == null);
    const a = parseNameDep("nova-http").?;
    try std.testing.expectEqualStrings("nova-http", a.name);
    try std.testing.expectEqualStrings("*", a.range);
    const b = parseNameDep("nova-http@^1.2.0").?;
    try std.testing.expectEqualStrings("nova-http", b.name);
    try std.testing.expectEqualStrings("^1.2.0", b.range);
}

test "resolve + unify against an index entry (JSON-parsed)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{ "name": "nova-http",
        \\  "versions": [ {"version":"1.0.0","url":"https://ex/nova-http","ref":"v1.0.0"},
        \\                {"version":"1.2.0","url":"https://ex/nova-http","ref":"v1.2.0"},
        \\                {"version":"1.4.1","url":"https://ex/nova-http","ref":"9f3c"},
        \\                {"version":"2.0.0","url":"https://ex/nova-http","ref":"v2.0.0"} ] }
    ;
    const parsed = try std.json.parseFromSlice(IndexEntry, a, json, .{ .ignore_unknown_fields = true });
    const entry = parsed.value;

    // ^1.2.0 -> newest 1.x = 1.4.1
    const r = resolveEntry(a, entry, "^1.2.0").?;
    try std.testing.expectEqualStrings("1.4.1", r.version);
    try std.testing.expectEqualStrings("9f3c", r.ref.?);
    try std.testing.expectEqualStrings("https://ex/nova-http", r.url);

    // ~1.2 -> 1.2.0 (stays on 1.2.x); >=2.0.0 -> 2.0.0
    try std.testing.expectEqualStrings("1.2.0", resolveEntry(a, entry, "~1.2").?.version);
    try std.testing.expectEqualStrings("2.0.0", resolveEntry(a, entry, ">=2.0.0").?.version);

    // Unify ^1.0.0 AND >=1.3.0 -> 1.4.1 (2.0.0 excluded by ^1).
    const ranges = [_][]const u8{ "^1.0.0", ">=1.3.0" };
    try std.testing.expectEqualStrings("1.4.1", unifyEntry(a, entry, &ranges).?.version);

    // Unsatisfiable -> null.
    try std.testing.expect(resolveEntry(a, entry, "^3.0.0") == null);
    const bad = [_][]const u8{ "^1.0.0", ">=2.0.0" };
    try std.testing.expect(unifyEntry(a, entry, &bad) == null);
}
