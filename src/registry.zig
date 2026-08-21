//! Package-index lookup and dependency resolution for the Nova package manager.
//!
//! This module is the bridge between a human-written dependency string (what a
//! manifest spells, e.g. `"nova-http@^1.2.0"`) and a concrete, fetchable git
//! location (a URL plus an optional ref/tag). It sits directly on top of
//! [`semver`]: this file knows the on-disk shape of the index and how to read
//! it, and it delegates every version-comparison decision to `semver.zig`.
//!
//! The index is modelled after the Cargo registry index: one JSON file per
//! package, named `<name>.json`, living under an `index_dir`. Each file
//! deserialises into an [`IndexEntry`] whose `versions` list carries, per
//! published version, the fetch URL and the git ref to check out. Resolution is
//! therefore two steps: [`readEntry`] loads and parses that JSON, then a
//! [`semver`] range picker selects one [`IndexVersion`] out of the list. The
//! two public entry points [`resolve`] and [`unify`] fuse both steps; the
//! `*Entry` variants ([`resolveEntry`], [`unifyEntry`]) take an already-parsed
//! entry so the unit tests (and any caller holding an entry in memory) can skip
//! the filesystem.
//!
//! Design decisions worth knowing:
//!
//!   * Everything is fail-soft. A missing index file, an unparseable JSON body,
//!     an allocation failure, or a range that matches nothing all collapse to
//!     `null` rather than an error. The package manager treats "cannot resolve"
//!     uniformly, and [`rewriteDep`] in particular is written so that an
//!     unresolvable dependency is passed through UNCHANGED rather than aborting
//!     the build. That is deliberate: a dep that is already a bare URL, or one
//!     the local index does not know about, should still reach the fetcher.
//!
//!   * All returned slices ([`Resolved.url`], [`Resolved.ref`], etc.) borrow
//!     out of the parsed JSON, which in turn borrows out of the `allocator`
//!     passed in. Callers therefore pass an arena and keep it alive for as long
//!     as the result is used; the parsed [`std.json.Parsed`] handle is dropped
//!     on the floor by [`resolve`]/[`unify`] on purpose, since the arena owns
//!     the backing memory.
//!
//!   * [`unify`] versus [`resolve`]: a single dependent uses [`resolve`] (newest
//!     version satisfying one range). When several dependents require the same
//!     package under DIFFERENT ranges, [`unify`] finds the one version that
//!     satisfies all of them at once, which is how the dependency tree agrees on
//!     a single resolved version instead of vendoring the package twice.

const std = @import("std");
/// Alias for the `std.Io` I/O interface, used to read index files through the
/// caller-supplied I/O object rather than touching global process state.
const Io = std.Io;
/// The semantic-versioning core ([`semver.maxSatisfying`], [`semver.unify`]).
/// This module owns index shape and I/O; every version-precedence decision is
/// delegated here.
const semver = @import("semver.zig");

/// One published version of a package, as it appears in an index file.
///
/// Fields:
///   * `version`, the SemVer string this record publishes (e.g. `"1.4.1"`).
///   * `url`, the git/fetch location to obtain this version from.
///   * `ref`, the git ref (tag or commit) to check out; `null` means the URL
///     alone is enough (default branch). [`rewriteDep`] appends it as `url#ref`
///     when present.
pub const IndexVersion = struct { version: []const u8, url: []const u8, ref: ?[]const u8 = null };
/// A whole package's index file: its name and every published [`IndexVersion`].
///
/// This is the exact JSON schema `readEntry` deserialises `<name>.json` into,
/// with `ignore_unknown_fields` so extra registry metadata does not break the
/// parse.
pub const IndexEntry = struct { name: []const u8, versions: []IndexVersion };

/// A dependency string split into its package name and version range.
///
/// Produced by [`parseNameDep`]; `range` is a node-semver range string handed
/// straight to [`semver`] (defaulting to `"*"` when the manifest gave no
/// version constraint).
pub const NameDep = struct { name: []const u8, range: []const u8 };
/// The outcome of resolving a name+range against the index: the concrete fetch
/// coordinates.
///
/// `version` is the exact chosen SemVer, `url`/`ref` come from the matching
/// [`IndexVersion`]. All three slices borrow out of the parsed index entry, so
/// the arena that backed the parse must outlive this value.
pub const Resolved = struct { url: []const u8, ref: ?[]const u8, version: []const u8 };

/// Splits a manifest dependency string into a [`NameDep`], or `null` if it is
/// not a registry name+range at all.
///
/// Only *bare package names* (optionally suffixed with `@<range>`) resolve
/// through the index, so this returns `null` for anything that is already a
/// location: a string containing `://` (a URL scheme) or `/` (a path or
/// `owner/repo` form) is rejected, as is an empty string. The `@` is found from
/// the RIGHT ([`std.mem.lastIndexOfScalar`]) so a name may itself contain `@`;
/// a leading `@` (index 0) is rejected because that would leave an empty name.
/// A trailing `@` with nothing after it, and a name with no `@` at all, both
/// default the range to `"*"` (match any version).
pub fn parseNameDep(dep: []const u8) ?NameDep {
    if (std.mem.indexOf(u8, dep, "://") != null) return null;
    if (std.mem.indexOfScalar(u8, dep, '/') != null) return null;
    if (dep.len == 0) return null;
    if (std.mem.lastIndexOfScalar(u8, dep, '@')) |at| {
        if (at == 0) return null;
        const range = if (at + 1 < dep.len) dep[at + 1 ..] else "*";
        return .{ .name = dep[0..at], .range = range };
    }
    return .{ .name = dep, .range = "*" };
}

/// Loads and JSON-parses the index file `<index_dir>/<name>.json` into an
/// [`IndexEntry`], or `null` on any failure.
///
/// Fail-soft by design: a formatting failure, a path-join failure, a missing or
/// unreadable file, or a malformed JSON body all return `null` rather than
/// propagating an error, because the package manager treats every "cannot load"
/// the same way. Unknown JSON fields are ignored so registry-side schema
/// additions do not break resolution. The returned [`std.json.Parsed`] owns its
/// arena-backed memory via `allocator`; the public wrappers keep only its
/// `.value` and rely on the caller's arena to free it.
fn readEntry(allocator: std.mem.Allocator, io: std.Io, index_dir: []const u8, name: []const u8) ?std.json.Parsed(IndexEntry) {
    const fname = std.fmt.allocPrint(allocator, "{s}.json", .{name}) catch return null;
    const path = std.fs.path.join(allocator, &[_][]const u8{ index_dir, fname }) catch return null;
    const data = Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited) catch return null;
    return std.json.parseFromSlice(IndexEntry, allocator, data, .{ .ignore_unknown_fields = true }) catch null;
}

/// Picks the newest version of an already-parsed `entry` that satisfies a
/// single `range`, as a [`Resolved`], or `null` if none does.
///
/// Thin wrapper over [`pickBy`] with [`semver.maxSatisfying`] as the selector.
/// Use this (rather than [`resolve`]) when the entry is already in memory, e.g.
/// in tests.
pub fn resolveEntry(allocator: std.mem.Allocator, entry: IndexEntry, range: []const u8) ?Resolved {
    return pickBy(allocator, entry, semver.maxSatisfying, range);
}
/// Picks the newest version of `entry` that satisfies ALL of `ranges` at once,
/// or `null` if no single version does.
///
/// This is the multi-dependent case: several parts of the tree require the same
/// package under different constraints and must agree on one version. It gathers
/// the entry's version strings into a list and hands them plus `ranges` to
/// [`semver.unify`], then maps the chosen string back to its full record via
/// [`findVersion`]. An allocation failure while gathering yields `null`.
pub fn unifyEntry(allocator: std.mem.Allocator, entry: IndexEntry, ranges: []const []const u8) ?Resolved {
    var versions = std.ArrayList([]const u8).empty;
    for (entry.versions) |v| versions.append(allocator, v.version) catch return null;
    const chosen = semver.unify(ranges, versions.items) orelse return null;
    return findVersion(entry, chosen);
}
/// Shared machinery for single-range resolution: gather `entry`'s version
/// strings, let selector `f` choose one against `range`, then look the winner
/// back up as a full [`Resolved`].
///
/// `f` is a comptime-known selector with [`semver.maxSatisfying`]'s signature
/// `(range, versions) -> ?version`; taking it as a parameter keeps the
/// gather-then-map boilerplate in one place. Returns `null` on allocation
/// failure or when `f` selects nothing.
fn pickBy(allocator: std.mem.Allocator, entry: IndexEntry, comptime f: fn ([]const u8, []const []const u8) ?[]const u8, range: []const u8) ?Resolved {
    var versions = std.ArrayList([]const u8).empty;
    for (entry.versions) |v| versions.append(allocator, v.version) catch return null;
    const chosen = f(range, versions.items) orelse return null;
    return findVersion(entry, chosen);
}
/// Maps a chosen version STRING back to its full [`Resolved`] coordinates by
/// linear-scanning `entry.versions` for an exact string match.
///
/// The [`semver`] selectors return only the winning version string, but callers
/// need its `url`/`ref` too; this recovers them. Returns `null` if the string is
/// somehow absent from the entry (should not happen when the string came from
/// the same entry's own version list).
fn findVersion(entry: IndexEntry, version: []const u8) ?Resolved {
    for (entry.versions) |v| {
        if (std.mem.eql(u8, v.version, version)) return .{ .url = v.url, .ref = v.ref, .version = v.version };
    }
    return null;
}

/// End-to-end single-dependent resolution: read `<index_dir>/<name>.json` and
/// return the newest version satisfying `range`, or `null` if the file cannot
/// be loaded or nothing matches.
///
/// Composition of [`readEntry`] and [`resolveEntry`]. The parsed handle is
/// intentionally not retained: its memory lives in `allocator` (an arena the
/// caller keeps alive), which the returned borrowed slices point into.
pub fn resolve(allocator: std.mem.Allocator, io: std.Io, index_dir: []const u8, name: []const u8, range: []const u8) ?Resolved {
    const parsed = readEntry(allocator, io, index_dir, name) orelse return null;
    return resolveEntry(allocator, parsed.value, range);
}

/// End-to-end multi-dependent resolution: read `<index_dir>/<name>.json` and
/// return the newest version satisfying ALL of `ranges`, or `null`.
///
/// Composition of [`readEntry`] and [`unifyEntry`]; see [`resolve`] for the
/// memory-ownership note.
pub fn unify(allocator: std.mem.Allocator, io: std.Io, index_dir: []const u8, name: []const u8, ranges: []const []const u8) ?Resolved {
    const parsed = readEntry(allocator, io, index_dir, name) orelse return null;
    return unifyEntry(allocator, parsed.value, ranges);
}

/// Rewrites a manifest dependency string into a concrete fetch spec, passing it
/// through unchanged when it cannot (or should not) be rewritten.
///
/// The intended flow: `"nova-http@^1.2.0"` becomes the matching version's
/// `url#ref` (e.g. `https://ex/nova-http#9f3c`), or just its `url` when the
/// chosen version has no `ref`. Any of the following returns `dep` verbatim, so
/// the caller can feed the result straight to the fetcher regardless:
///   * `dep` is not a bare name+range ([`parseNameDep`] returns `null`, e.g. it
///     is already a URL or `owner/repo`),
///   * the index has no matching entry/version ([`resolve`] returns `null`),
///   * the `allocPrint` that builds `url#ref` fails.
/// This total-function contract (always returns a usable string) is why the
/// package manager can call it unconditionally on every dependency.
pub fn rewriteDep(allocator: std.mem.Allocator, io: std.Io, index_dir: []const u8, dep: []const u8) []const u8 {
    const nd = parseNameDep(dep) orelse return dep;
    const r = resolve(allocator, io, index_dir, nd.name, nd.range) orelse return dep;
    if (r.ref) |ref| {
        return std.fmt.allocPrint(allocator, "{s}#{s}", .{ r.url, ref }) catch dep;
    }
    return r.url;
}


// Verifies parseNameDep's classification: URLs and path-like strings are
// rejected (null), a bare name defaults to the "*" range, and a `name@range`
// suffix is split into its two parts.
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

// End-to-end check over a JSON-parsed [`IndexEntry`]: [`resolveEntry`] picks
// the newest match for `^`, `~` and `>=` ranges (carrying the right `url`/`ref`
// through), [`unifyEntry`] finds the single version satisfying two ranges at
// once, and both return `null` when a range (or a pair of ranges) matches
// nothing.
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

    const r = resolveEntry(a, entry, "^1.2.0").?;
    try std.testing.expectEqualStrings("1.4.1", r.version);
    try std.testing.expectEqualStrings("9f3c", r.ref.?);
    try std.testing.expectEqualStrings("https://ex/nova-http", r.url);

    try std.testing.expectEqualStrings("1.2.0", resolveEntry(a, entry, "~1.2").?.version);
    try std.testing.expectEqualStrings("2.0.0", resolveEntry(a, entry, ">=2.0.0").?.version);

    const ranges = [_][]const u8{ "^1.0.0", ">=1.3.0" };
    try std.testing.expectEqualStrings("1.4.1", unifyEntry(a, entry, &ranges).?.version);

    try std.testing.expect(resolveEntry(a, entry, "^3.0.0") == null);
    const bad = [_][]const u8{ "^1.0.0", ">=2.0.0" };
    try std.testing.expect(unifyEntry(a, entry, &bad) == null);
}
