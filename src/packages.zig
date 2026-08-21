//! The git-backed package manager behind `nova get`, `nova restore`,
//! `nova update` and `nova publish`.
//!
//! Nova has no central package server: a dependency is just a git URL,
//! optionally pinned to a ref with a `#ref` suffix (a branch, tag or full SHA).
//! This module resolves the transitive dependency graph declared in a project's
//! `project.json`, materialises each dependency into a content-addressed cache
//! under `~/.nova/cache`, and records the exact resolved commit of every
//! dependency in `project.lock.json` so a later build is reproducible.
//!
//! Design decisions and invariants:
//!
//!   * **The cache is shared and content-addressed.** A checked-out dependency
//!     lives in `~/.nova/cache/<name>-<8-char-sha>` when it is pinned to a
//!     resolvable commit, or `<name>-branch` when it tracks a moving ref. The
//!     short-SHA suffix means two projects pinning the same commit share one
//!     checkout and a pin is never confused with a different pin.
//!
//!   * **The lock is authoritative during a build.** [`resolveTree`] in
//!     [`Mode.build`] reuses the commit already recorded in the lock (and the
//!     directory already in the cache) instead of touching the network. Only
//!     [`Mode.update`] re-fetches a moving ref to advance it to its tip. This
//!     is why `nova build` is offline once the lock exists, and why `nova
//!     update` is the one command that changes what a floating ref points at.
//!
//!   * **Resolution is a breadth-first worklist over sub-manifests.** Each
//!     fetched dependency's own `project.json` contributes more dependencies to
//!     the queue; a `visited` set keyed by cache directory name dedupes the
//!     graph so a diamond dependency is fetched once. There is no version
//!     unification here at the graph level: the first checkout of a given cache
//!     directory wins.
//!
//!   * **An optional registry rewrites `name@range` into a git URL.** When
//!     `project.json` names a `registry`, [`registryIndexDir`] clones/locates
//!     the index and [`registry.rewriteDep`] turns a `name@^1.2.0` dependency
//!     into a concrete `url#tag` before it is fetched. Direct git URLs bypass
//!     the registry entirely.
//!
//! Everything is driven through git subprocesses ([`runGit`]) rather than a git
//! library, and the HEAD commit is read by parsing `.git/HEAD`, loose refs and
//! `packed-refs` by hand ([`readHeadSha`]) so no libgit dependency is needed.
//! The CLI entry points are [`ensureDependencies`] (implicit, on every build),
//! [`cmdRestore`], [`cmdGet`], [`cmdUpdate`] and [`cmdPublish`].

const std = @import("std");
const Io = std.Io;
/// Access to [`pipeline.ProjectJson`], the `project.json` manifest schema
/// (name, version, type, repository, registry, dependencies) parsed here.
const pipeline = @import("pipeline.zig");
/// The optional package registry: index discovery plus `name@range` -> git-URL
/// rewriting via [`registry.rewriteDep`], applied before a dependency is fetched.
const registry = @import("registry.zig");


/// The user's home directory, used as the root of the `~/.nova` cache tree.
///
/// Reads `HOME` first (POSIX), then `USERPROFILE` (Windows), and falls back to
/// `/` if neither is set. Environment must be read from [`init.environ_map`] in
/// this Zig, not `std.posix.getenv`, which does not work in this toolchain.
fn homePath(init: std.process.Init) []const u8 {
    return init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/";
}

/// Builds the `~/.nova/cache` directory path where all fetched dependencies live.
///
/// Allocates the joined path with `allocator`; callers own the result. The
/// directory itself is created lazily by [`fetchDep`], not here.
fn cacheRoot(allocator: std.mem.Allocator, init: std.process.Init) ![]const u8 {
    return std.fs.path.join(allocator, &[_][]const u8{ homePath(init), ".nova", "cache" });
}

/// A dependency string split into its git URL and optional pinned ref.
///
/// Produced by [`parseDep`] from the `url#ref` syntax. `ref` is a branch, tag
/// or full SHA, or `null` when the dependency floats on the remote default
/// branch. Both fields borrow slices of the original dependency string.
const DepSpec = struct { url: []const u8, ref: ?[]const u8 };

/// Splits a `url#ref` dependency string into its [`DepSpec`] parts.
///
/// The ref is everything after the LAST `#` (so a `#` in the URL itself is
/// tolerated). A trailing `#` with nothing after it yields a `null` ref, same
/// as no `#` at all.
fn parseDep(dep: []const u8) DepSpec {
    if (std.mem.lastIndexOfScalar(u8, dep, '#')) |h| {
        return .{ .url = dep[0..h], .ref = if (h + 1 < dep.len) dep[h + 1 ..] else null };
    }
    return .{ .url = dep, .ref = null };
}

/// Computes the cache subdirectory name for a dependency.
///
/// A resolvable commit gives `<name>-<first 8 chars of sha>`, so a pinned
/// dependency is content-addressed and two projects on the same commit share
/// one checkout. A moving ref (no sha recorded) gives `<name>-branch`, a single
/// slot that [`fetchDep`] overwrites on each update. The 8-character truncation
/// mirrors git's own short-SHA convention; collisions are not defended against
/// because a genuine collision needs two 8-hex-prefix-equal commits of the same
/// package name.
fn cacheDirName(allocator: std.mem.Allocator, name: []const u8, sha: ?[]const u8) ![]const u8 {
    if (sha) |s| {
        const n = @min(s.len, 8);
        return std.fmt.allocPrint(allocator, "{s}-{s}", .{ name, s[0..n] });
    }
    return std.fmt.allocPrint(allocator, "{s}-branch", .{name});
}

/// Derives a package name from a git URL as a fallback when no declared name
/// is available.
///
/// Trims trailing slashes, takes the final path segment, and strips a `.git`
/// suffix, so `https://host/org/nova-http.git/` yields `nova-http`. Returns
/// `null` when there is no `/` to split on or the segment is empty. Only used
/// when a dependency's `project.json` name cannot be read (see
/// [`readDeclaredName`]).
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

/// Reports whether `s` is a full 40-character lowercase-or-uppercase hex SHA-1.
///
/// Used to distinguish a resolved commit id from a symbolic ref when parsing
/// `.git/HEAD` and `packed-refs` in [`readHeadSha`]. The exact length check is
/// deliberate: an abbreviated SHA or a ref name must NOT be mistaken for a
/// commit.
fn isHexSha(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}


/// Runs a git subprocess and fails if it does not exit cleanly.
///
/// Spawns `argv` on [`init.io`], waits, and returns `error.GitCommandFailed`
/// for any non-zero exit code or abnormal termination (signal, etc.). This is
/// the single choke point through which every git operation in the module goes;
/// [`gitSucceeds`] wraps it for the probe cases where a non-zero exit is an
/// expected answer rather than an error.
fn runGit(init: std.process.Init, argv: []const []const u8) !void {
    var child = try std.process.spawn(init.io, .{ .argv = argv });
    const term = try child.wait(init.io);
    switch (term) {
        .exited => |code| if (code != 0) return error.GitCommandFailed,
        else => return error.GitCommandFailed,
    }
}

/// Resolves the checked-out commit of a cloned repo by reading git's on-disk
/// refs directly, without invoking git.
///
/// Handles the three shapes `.git/HEAD` can take:
///   1. a detached HEAD holding a raw 40-hex SHA, returned as-is;
///   2. a symbolic `ref: refs/heads/<branch>` whose target exists as a LOOSE
///      ref file under `.git/<ref>`, whose contents are the SHA;
///   3. the same symbolic ref when the loose file is absent because the ref is
///      PACKED, in which case `.git/packed-refs` is scanned for the line ending
///      in that ref (skipping `#` comments and `^` peeled-tag lines).
///
/// Returns the SHA duplicated into `allocator`, or `null` on any read/parse
/// failure. A `null` here means "moving ref" to [`fetchDep`], which then caches
/// the checkout under the `-branch` slot instead of a content-addressed one.
fn readHeadSha(allocator: std.mem.Allocator, io: std.Io, repo_dir: []const u8) ?[]const u8 {
    const head_path = std.fs.path.join(allocator, &[_][]const u8{ repo_dir, ".git", "HEAD" }) catch return null;
    const head = Io.Dir.readFileAlloc(.cwd(), io, head_path, allocator, .unlimited) catch return null;
    const trimmed = std.mem.trim(u8, head, " \t\r\n");
    if (isHexSha(trimmed)) return allocator.dupe(u8, trimmed) catch null;
    if (std.mem.startsWith(u8, trimmed, "ref:")) {
        const ref = std.mem.trim(u8, trimmed[4..], " \t\r\n");
        const loose = std.fs.path.join(allocator, &[_][]const u8{ repo_dir, ".git", ref }) catch return null;
        if (Io.Dir.readFileAlloc(.cwd(), io, loose, allocator, .unlimited)) |lref| {
            const s = std.mem.trim(u8, lref, " \t\r\n");
            if (isHexSha(s)) return allocator.dupe(u8, s) catch null;
        } else |_| {}
        const packed_path = std.fs.path.join(allocator, &[_][]const u8{ repo_dir, ".git", "packed-refs" }) catch return null;
        if (Io.Dir.readFileAlloc(.cwd(), io, packed_path, allocator, .unlimited)) |pr| {
            var it = std.mem.splitScalar(u8, pr, '\n');
            while (it.next()) |line| {
                const l = std.mem.trim(u8, line, " \t\r\n");
                if (l.len < 42 or l[0] == '#' or l[0] == '^') continue;
                if (std.mem.endsWith(u8, l, ref) and l[40] == ' ' and isHexSha(l[0..40])) {
                    return allocator.dupe(u8, l[0..40]) catch null;
                }
            }
        } else |_| {}
    }
    return null;
}

/// Determines a dependency's package name, preferring its own manifest.
///
/// Reads `<repo_dir>/project.json` and returns its declared `name`. At every
/// failure step (missing manifest, unreadable file, invalid JSON, allocation
/// failure) it degrades to [`repoNameFromUrl`], and finally to the literal
/// `"dep"` so a name is always produced. The declared name is preferred because
/// it, not the URL slug, is what drives the cache directory name and lock
/// entry, keeping them stable if the repo is later mirrored to a different URL.
fn readDeclaredName(allocator: std.mem.Allocator, io: std.Io, repo_dir: []const u8, url: []const u8) []const u8 {
    const mpath = std.fs.path.join(allocator, &[_][]const u8{ repo_dir, "project.json" }) catch
        return repoNameFromUrl(url) orelse "dep";
    const data = Io.Dir.readFileAlloc(.cwd(), io, mpath, allocator, .unlimited) catch
        return repoNameFromUrl(url) orelse "dep";
    const parsed = std.json.parseFromSlice(pipeline.ProjectJson, allocator, data, .{ .ignore_unknown_fields = true }) catch
        return repoNameFromUrl(url) orelse "dep";
    return allocator.dupe(u8, parsed.value.name) catch (repoNameFromUrl(url) orelse "dep");
}


/// One resolved dependency as recorded in `project.lock.json`.
///
/// This is the serialised JSON shape as well as the in-memory form.
const LockEntry = struct {
    /// The dependency's git URL (the `#ref` suffix stripped off into [`ref`]).
    url: []const u8,
    /// The requested ref (branch/tag/SHA), or `null` if it floats on the
    /// remote default branch. Matched against on lookup by [`lockLookup`].
    ref: ?[]const u8 = null,
    /// The concrete commit SHA the ref resolved to, or `null` for a moving ref
    /// that was cached under the `-branch` slot. This is the field that makes a
    /// build reproducible: a `build` reuses it instead of re-fetching.
    resolved: ?[]const u8 = null,
    /// The dependency's declared package name (see [`readDeclaredName`]), which
    /// together with [`resolved`] reconstructs its cache directory name.
    name: []const u8,
};
/// The whole `project.lock.json` document: a version stamp plus the flat list
/// of every transitively resolved dependency.
const LockFile = struct {
    /// Lock format version, currently always `1`; present so a future format
    /// change can be detected.
    lockfileVersion: u32 = 1,
    /// Every resolved dependency in the transitive graph, in resolution order.
    dependencies: []LockEntry = &[_]LockEntry{},
};

/// Loads `project.lock.json` from the current directory, or an empty lock if it
/// is absent or malformed.
///
/// Any read or parse failure yields the default (empty) [`LockFile`] rather
/// than an error, so a missing or corrupt lock simply means "resolve from
/// scratch" instead of aborting the build.
fn readLock(allocator: std.mem.Allocator, io: std.Io) LockFile {
    const data = Io.Dir.readFileAlloc(.cwd(), io, "project.lock.json", allocator, .unlimited) catch return .{};
    const parsed = std.json.parseFromSlice(LockFile, allocator, data, .{ .ignore_unknown_fields = true }) catch return .{};
    return parsed.value;
}

/// Compares two optional refs for equality, treating two `null`s as equal.
///
/// A `null` ref (floating default branch) matches only another `null`; a
/// present ref matches only the identical string. Used by [`lockLookup`] so a
/// pinned and an unpinned dependency to the same URL are distinct lock entries.
fn refEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Finds the lock entry for a `(url, ref)` pair, or `null` if unlocked.
///
/// Matches on URL AND ref together (via [`refEql`]) so re-pinning a dependency
/// to a new ref is correctly treated as unresolved and re-fetched.
fn lockLookup(lock: LockFile, url: []const u8, ref: ?[]const u8) ?LockEntry {
    for (lock.dependencies) |e| {
        if (std.mem.eql(u8, e.url, url) and refEql(e.ref, ref)) return e;
    }
    return null;
}

/// Serialises the resolved dependency list to `project.lock.json`.
///
/// Wraps `entries` in a versioned [`LockFile`] and writes it pretty-printed
/// (2-space indent) so the lock is diff-friendly in version control. The
/// `@constCast` is safe because [`std.json.Stringify`] only reads the slice.
fn writeLock(allocator: std.mem.Allocator, io: std.Io, entries: []const LockEntry) !void {
    const lf = LockFile{ .lockfileVersion = 1, .dependencies = @constCast(entries) };
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(lf, .{ .whitespace = .indent_2 }, &out.writer);
    try Io.Dir.writeFile(.cwd(), io, .{ .data = out.written(), .sub_path = "project.lock.json", .flags = .{} });
}


/// The result of materialising a dependency into the cache: its declared name,
/// the resolved commit (or `null` for a moving ref), and the absolute cache
/// directory it now lives in. Returned by [`fetchDep`].
const Fetched = struct { name: []const u8, sha: ?[]const u8, dir: []const u8 };

/// Clones a dependency into the shared cache and returns where it landed.
///
/// Clones into a scratch `~/.nova/cache/.fetch-tmp`, then either checks out the
/// requested `checkout_target` (a full-history clone is used so any ref is
/// reachable) or, for a floating dependency, takes a `--depth 1` shallow clone
/// of the default branch. The declared name and HEAD SHA are read from the
/// clone, and the scratch dir is atomically renamed to its final
/// content-addressed location under [`cacheDirName`].
///
/// If the destination already exists (another project, or an earlier run,
/// cached the identical commit) the scratch clone is simply discarded and the
/// existing checkout is reused. `recorded_sha` is deliberately `null` for a
/// floating dependency even though a SHA was read, so the caller caches it in
/// the reusable `-branch` slot rather than pinning it. Returns
/// `error.CacheMoveFailed` if the rename into the cache fails.
fn fetchDep(allocator: std.mem.Allocator, init: std.process.Init, url: []const u8, checkout_target: ?[]const u8) !Fetched {
    const root = try cacheRoot(allocator, init);
    Io.Dir.createDirPath(.cwd(), init.io, root) catch {};
    const tmp = try std.fs.path.join(allocator, &[_][]const u8{ root, ".fetch-tmp" });
    Io.Dir.deleteTree(.cwd(), init.io, tmp) catch {};

    if (checkout_target) |target| {
        try runGit(init, &[_][]const u8{ "git", "clone", "--quiet", url, tmp });
        try runGit(init, &[_][]const u8{ "git", "-C", tmp, "checkout", "--quiet", target });
    } else {
        try runGit(init, &[_][]const u8{ "git", "clone", "--quiet", "--depth", "1", url, tmp });
    }

    const sha = readHeadSha(allocator, init.io, tmp);
    const name = readDeclaredName(allocator, init.io, tmp, url);
    const recorded_sha: ?[]const u8 = if (checkout_target == null) null else sha;
    const dirname = try cacheDirName(allocator, name, recorded_sha);
    const dest = try std.fs.path.join(allocator, &[_][]const u8{ root, dirname });

    if (Io.Dir.access(.cwd(), init.io, dest, .{})) |_| {
        Io.Dir.deleteTree(.cwd(), init.io, tmp) catch {};
    } else |_| {
        Io.Dir.renameAbsolute(tmp, dest, init.io) catch {
            return error.CacheMoveFailed;
        };
    }
    return .{ .name = name, .sha = recorded_sha, .dir = dest };
}


/// Whether [`resolveTree`] should honour the lock or advance moving refs.
const Mode = enum {
    /// Reproducible resolution: reuse locked commits and cached checkouts,
    /// touch the network only for genuinely new dependencies. The mode used by
    /// every `nova build` and by [`cmdRestore`] / [`cmdGet`].
    build,
    /// Advance floating refs to their current tip and rewrite the lock. The
    /// mode used by [`cmdUpdate`], optionally narrowed to a single URL.
    update,
};

/// Reads the `dependencies` array from a `project.json` manifest.
///
/// Returns an empty slice on any read or parse failure so a dependency with no
/// or an unreadable manifest simply contributes no sub-dependencies, rather
/// than aborting the whole resolution. Used both for the root manifest and for
/// each fetched dependency's own manifest during the BFS in [`resolveTree`].
fn readManifestDeps(allocator: std.mem.Allocator, io: std.Io, manifest_path: []const u8) [][]const u8 {
    const data = Io.Dir.readFileAlloc(.cwd(), io, manifest_path, allocator, .unlimited) catch return &[_][]const u8{};
    const parsed = std.json.parseFromSlice(pipeline.ProjectJson, allocator, data, .{ .ignore_unknown_fields = true }) catch return &[_][]const u8{};
    return parsed.value.dependencies;
}

/// Locates the local registry index directory named by the root
/// `project.json`, cloning it if needed, or `null` when there is no registry.
///
/// A `registry` value with no `://` is treated as an already-local path and
/// returned verbatim. A URL is cloned (shallow) into
/// `~/.nova/registry-cache/<name>` on first use and that path is reused
/// afterwards. Returns `null` at every failure point (no manifest, no
/// `registry` key, clone failure), which makes registry resolution a strict
/// opt-in: absent a registry, [`resolveTree`] passes dependency strings through
/// untouched.
fn registryIndexDir(allocator: std.mem.Allocator, init: std.process.Init) ?[]const u8 {
    const data = Io.Dir.readFileAlloc(.cwd(), init.io, "project.json", allocator, .unlimited) catch return null;
    const parsed = std.json.parseFromSlice(pipeline.ProjectJson, allocator, data, .{ .ignore_unknown_fields = true }) catch return null;
    const reg = parsed.value.registry orelse return null;
    if (std.mem.indexOf(u8, reg, "://") == null) return reg;
    const home = homePath(init);
    const cache = std.fs.path.join(allocator, &[_][]const u8{ home, ".nova", "registry-cache" }) catch return null;
    Io.Dir.createDirPath(.cwd(), init.io, cache) catch {};
    const name = repoNameFromUrl(reg) orelse "index";
    const dir = std.fs.path.join(allocator, &[_][]const u8{ cache, name }) catch return null;
    if (Io.Dir.access(.cwd(), init.io, dir, .{})) |_| {
        return dir;
    } else |_| {
        runGit(init, &[_][]const u8{ "git", "clone", "--quiet", "--depth", "1", reg, dir }) catch return null;
        return dir;
    }
}

/// Resolves the full transitive dependency graph into a flat lock list.
///
/// Runs a breadth-first traversal over a worklist seeded from the root
/// manifest's dependencies. For each dependency it optionally rewrites a
/// `name@range` through the registry ([`registry.rewriteDep`]), splits off the
/// ref ([`parseDep`]), and looks it up in the existing lock ([`lockLookup`]).
///
/// `moving` is true only in [`Mode.update`] for a dependency matching
/// `update_target` (or all of them when the target is `null`). A non-moving
/// dependency whose locked checkout is still present in the cache is reused
/// verbatim, its sub-manifest enqueued, and the network untouched; otherwise
/// the recorded commit (if any) is checked out fresh. A moving dependency is
/// always re-fetched at its ref tip. Each newly seen cache directory is added
/// to `visited` so a diamond dependency is processed once.
///
/// Returns the resolved entries in traversal order. Fetch failures propagate
/// after printing a `[deps]` diagnostic; all other per-dependency failures
/// (missing sub-manifest, etc.) degrade quietly via the helpers.
fn resolveTree(allocator: std.mem.Allocator, init: std.process.Init, mode: Mode, update_target: ?[]const u8) ![]LockEntry {
    const existing = readLock(allocator, init.io);

    var result = std.ArrayList(LockEntry).empty;
    var visited = std.StringHashMap(void).init(allocator);

    var work = std.ArrayList([]const u8).empty;
    for (readManifestDeps(allocator, init.io, "project.json")) |d| try work.append(allocator, d);

    const root = try cacheRoot(allocator, init);
    const registry_dir = registryIndexDir(allocator, init);

    while (work.items.len > 0) {
        const raw_dep = work.orderedRemove(0);
        const dep = if (registry_dir) |rd| registry.rewriteDep(allocator, init.io, rd, raw_dep) else raw_dep;
        const spec = parseDep(dep);
        const locked = lockLookup(existing, spec.url, spec.ref);

        const moving = mode == .update and (update_target == null or std.mem.eql(u8, spec.url, update_target.?));

        if (!moving) {
            if (locked) |l| {
                const dirname0 = try cacheDirName(allocator, l.name, l.resolved);
                const dir0 = try std.fs.path.join(allocator, &[_][]const u8{ root, dirname0 });
                if (Io.Dir.access(.cwd(), init.io, dir0, .{})) |_| {
                    if (visited.contains(dirname0)) continue;
                    try visited.put(try allocator.dupe(u8, dirname0), {});
                    try result.append(allocator, .{ .url = l.url, .ref = l.ref, .resolved = l.resolved, .name = l.name });
                    const sm = try std.fs.path.join(allocator, &[_][]const u8{ dir0, "project.json" });
                    for (readManifestDeps(allocator, init.io, sm)) |sd| try work.append(allocator, sd);
                    continue;
                } else |_| {}
            }
        }

        const checkout_target: ?[]const u8 = blk: {
            if (!moving) {
                if (locked) |l| if (l.resolved) |r| break :blk r;
            }
            break :blk spec.ref;
        };

        const fetched = fetchDep(allocator, init, spec.url, checkout_target) catch |err| {
            std.debug.print("[deps] failed to fetch {s}: {any}\n", .{ spec.url, @errorName(err) });
            return err;
        };
        const dirname = std.fs.path.basename(fetched.dir);
        if (visited.contains(dirname)) continue;
        try visited.put(try allocator.dupe(u8, dirname), {});

        try result.append(allocator, .{
            .url = spec.url,
            .ref = spec.ref,
            .resolved = fetched.sha,
            .name = fetched.name,
        });

        const sub_manifest = try std.fs.path.join(allocator, &[_][]const u8{ fetched.dir, "project.json" });
        for (readManifestDeps(allocator, init.io, sub_manifest)) |sd| try work.append(allocator, sd);
    }
    return result.items;
}


/// Ensures dependencies are resolved and the lock is current, called
/// implicitly on every project build.
///
/// A no-op when there is no `project.json` or it declares no dependencies. It
/// resolves the tree in [`Mode.build`] and rewrites `project.lock.json` ONLY if
/// the resolved set differs from what is already locked (see [`lockEquals`]),
/// so an up-to-date build does not churn the lock file's mtime.
pub fn ensureDependencies(allocator: std.mem.Allocator, init: std.process.Init) !void {
    Io.Dir.access(.cwd(), init.io, "project.json", .{}) catch return;
    const deps = readManifestDeps(allocator, init.io, "project.json");
    if (deps.len == 0) return;

    const entries = try resolveTree(allocator, init, .build, null);
    const before = readLock(allocator, init.io);
    if (!lockEquals(before.dependencies, entries)) {
        try writeLock(allocator, init.io, entries);
    }
}

/// Reports whether two lock lists are equivalent for the purpose of avoiding a
/// rewrite.
///
/// Compares by count, then matches each entry in `b` to one in `a` by URL and
/// checks their resolved commit and name agree (treating a `null` resolved as
/// the empty string). Order-independent, and deliberately ignores the `ref`
/// field: only the RESOLVED commit and name determine what actually gets built,
/// so a cosmetic ref change that resolves to the same commit does not force a
/// rewrite.
fn lockEquals(a: []const LockEntry, b: []const LockEntry) bool {
    if (a.len != b.len) return false;
    for (b) |be| {
        const ae = for (a) |x| {
            if (std.mem.eql(u8, x.url, be.url)) break x;
        } else return false;
        const ar = ae.resolved orelse "";
        const br = be.resolved orelse "";
        if (!std.mem.eql(u8, ar, br)) return false;
        if (!std.mem.eql(u8, ae.name, be.name)) return false;
    }
    return true;
}


/// Implements `nova restore`: resolve the graph and (re)write the lock.
///
/// Errors out with a message if there is no `project.json`. Unlike
/// [`ensureDependencies`], it always writes the lock and prints a count, since
/// restoring is an explicit user request to reconcile the cache and lock.
pub fn cmdRestore(allocator: std.mem.Allocator, init: std.process.Init) !void {
    Io.Dir.access(.cwd(), init.io, "project.json", .{}) catch {
        std.debug.print("Error: project.json not found. Run 'nova init' first.\n", .{});
        return;
    };
    const entries = try resolveTree(allocator, init, .build, null);
    try writeLock(allocator, init.io, entries);
    std.debug.print("Restored {d} dependenc{s} (locked).\n", .{ entries.len, if (entries.len == 1) "y" else "ies" });
}

/// Implements `nova get [<dependency>]`: add a dependency to the manifest and
/// re-resolve, or restore when called with no argument.
///
/// With fewer than three args (no dependency named) it delegates to
/// [`cmdRestore`]. Otherwise it reads `project.json`, appends the new
/// dependency string to `dependencies` unless it is already present (idempotent
/// re-add), rewrites the manifest pretty-printed, then resolves the tree and
/// writes the lock. Errors from missing or invalid `project.json` are reported
/// and returned.
pub fn cmdGet(allocator: std.mem.Allocator, init: std.process.Init, args: []const []const u8) !void {
    if (args.len < 3) return cmdRestore(allocator, init);
    const new_dep = args[2];

    const json_data = Io.Dir.readFileAlloc(.cwd(), init.io, "project.json", allocator, .unlimited) catch {
        std.debug.print("Error: project.json not found in current directory. Run 'nova init' first.\n", .{});
        return;
    };
    const parsed = std.json.parseFromSlice(pipeline.ProjectJson, allocator, json_data, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("Failed to parse project.json: {any}\n", .{err});
        return err;
    };

    var deps = std.ArrayList([]const u8).empty;
    var already = false;
    for (parsed.value.dependencies) |d| {
        try deps.append(allocator, d);
        if (std.mem.eql(u8, d, new_dep)) already = true;
    }
    if (!already) try deps.append(allocator, new_dep);

    const updated = pipeline.ProjectJson{
        .name = parsed.value.name,
        .version = parsed.value.version,
        .type = parsed.value.type,
        .repository = parsed.value.repository,
        .dependencies = deps.items,
    };
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(updated, .{ .whitespace = .indent_2 }, &out.writer);
    try Io.Dir.writeFile(.cwd(), init.io, .{ .data = out.written(), .sub_path = "project.json", .flags = .{} });

    const entries = try resolveTree(allocator, init, .build, null);
    try writeLock(allocator, init.io, entries);
    std.debug.print("Added {s}; resolved {d} dependenc{s} into the lock.\n", .{ new_dep, entries.len, if (entries.len == 1) "y" else "ies" });
}

/// Implements `nova update [<url>]`: advance floating refs to their tip and
/// rewrite the lock.
///
/// With a URL argument only that dependency is advanced; without one, all
/// pinned/floating dependencies are. Runs [`resolveTree`] in [`Mode.update`],
/// which is the only path that re-fetches an already-locked moving ref, then
/// always writes the lock. Errors out if there is no `project.json`.
pub fn cmdUpdate(allocator: std.mem.Allocator, init: std.process.Init, args: []const []const u8) !void {
    Io.Dir.access(.cwd(), init.io, "project.json", .{}) catch {
        std.debug.print("Error: project.json not found.\n", .{});
        return;
    };
    const target: ?[]const u8 = if (args.len >= 3) args[2] else null;
    const entries = try resolveTree(allocator, init, .update, target);
    try writeLock(allocator, init.io, entries);
    if (target) |t| {
        std.debug.print("Updated {s} to its ref tip; lock rewritten ({d} deps).\n", .{ t, entries.len });
    } else {
        std.debug.print("Updated all pinned deps to their ref tips; lock rewritten ({d} deps).\n", .{entries.len});
    }
}

/// Implements `nova publish`: tag the current commit as a release and push the
/// tag.
///
/// Publishing a Nova package IS creating a git tag; there is no upload to a
/// server. The guardrails, all of which must pass, are:
///   * `project.json` must set `"type": "library"` (only libraries publish) and
///     a non-empty `repository` URL (the canonical clone URL consumers use);
///   * the version becomes tag `v<version>` and that tag must NOT already exist
///     locally or on the remote (a released version is never clobbered);
///   * a non-`X.Y.Z` version or a dirty working tree only warn, not fail, since
///     both are recoverable and the tag still captures a real commit.
///
/// On success it creates an annotated tag, pushes it to `origin`, and prints
/// the `nova get <repo>#<tag>` line consumers use. Returns
/// `error.NotALibrary`, `error.NoRepository` or `error.TagExists` for the hard
/// failures above.
pub fn cmdPublish(allocator: std.mem.Allocator, init: std.process.Init) !void {
    const json_data = Io.Dir.readFileAlloc(.cwd(), init.io, "project.json", allocator, .unlimited) catch {
        std.debug.print("Error: project.json not found.\n", .{});
        return;
    };
    const parsed = std.json.parseFromSlice(pipeline.ProjectJson, allocator, json_data, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("Failed to parse project.json: {any}\n", .{err});
        return err;
    };
    const m = parsed.value;

    if (m.type == null or !std.mem.eql(u8, m.type.?, "library")) {
        std.debug.print("publish: only a library can be published (set \"type\": \"library\").\n", .{});
        return error.NotALibrary;
    }
    if (m.repository == null or m.repository.?.len == 0) {
        std.debug.print("publish: set \"repository\" (canonical git URL) before publishing.\n", .{});
        return error.NoRepository;
    }

    if (!looksSemver(m.version)) {
        std.debug.print("publish: warning — version \"{s}\" is not X.Y.Z semver.\n", .{m.version});
    }
    const tag = try std.fmt.allocPrint(allocator, "v{s}", .{m.version});

    if (tagExistsLocal(init, tag) or tagExistsRemote(init, tag)) {
        std.debug.print("publish: tag {s} already exists — never clobber a released version.\n", .{tag});
        return error.TagExists;
    }
    if (workingTreeDirty(init)) {
        std.debug.print("publish: warning — working tree is dirty; uncommitted changes are NOT in the tag.\n", .{});
    }
    const msg = try std.fmt.allocPrint(allocator, "{s}", .{tag});
    try runGit(init, &[_][]const u8{ "git", "tag", "-a", tag, "-m", msg });
    try runGit(init, &[_][]const u8{ "git", "push", "origin", tag });
    std.debug.print("Published {s}. Consume with:\n  nova get {s}#{s}\n", .{ tag, m.repository.?, tag });
}

/// Reports whether `v` looks like a bare `X.Y.Z` semver (digits and exactly two
/// dots).
///
/// A cheap sanity check for [`cmdPublish`]'s warning, not a full semver parse:
/// it rejects prerelease/build suffixes and any non-digit, non-dot character.
/// Failing it only warns; it never blocks a publish.
fn looksSemver(v: []const u8) bool {
    var dots: u8 = 0;
    for (v) |c| {
        if (c == '.') dots += 1 else if (!std.ascii.isDigit(c)) return false;
    }
    return dots == 2;
}

/// Runs a git command and reports success as a bool instead of raising.
///
/// The probe variant of [`runGit`]: used where a non-zero git exit is a normal
/// answer (the ref does not exist, the tree is clean) rather than an error to
/// propagate. Backs [`tagExistsLocal`], [`tagExistsRemote`] and
/// [`workingTreeDirty`].
fn gitSucceeds(init: std.process.Init, argv: []const []const u8) bool {
    runGit(init, argv) catch return false;
    return true;
}

/// Reports whether the tag already exists in the local repository.
///
/// Verifies `refs/tags/<tag>` with `git show-ref`. Allocates the ref string
/// from [`init_alloc`] (the page allocator) because it holds no caller
/// allocator, freeing it before returning.
fn tagExistsLocal(init: std.process.Init, tag: []const u8) bool {
    const ref = std.fmt.allocPrint(init_alloc, "refs/tags/{s}", .{tag}) catch return false;
    defer init_alloc.free(ref);
    return gitSucceeds(init, &[_][]const u8{ "git", "show-ref", "--quiet", "--verify", ref });
}

/// Reports whether the tag already exists on the `origin` remote.
///
/// Uses `git ls-remote --exit-code --tags origin <tag>`, which exits non-zero
/// when no matching tag is found. Together with [`tagExistsLocal`] this stops
/// [`cmdPublish`] re-tagging a version someone else already released.
fn tagExistsRemote(init: std.process.Init, tag: []const u8) bool {
    return gitSucceeds(init, &[_][]const u8{ "git", "ls-remote", "--exit-code", "--tags", "origin", tag });
}

/// Reports whether the working tree has uncommitted changes against HEAD.
///
/// `git diff --quiet HEAD` exits non-zero when the tree differs, so a dirty
/// tree is the NEGATION of [`gitSucceeds`]. Used only to warn in [`cmdPublish`]
/// that uncommitted work will not be captured by the tag.
fn workingTreeDirty(init: std.process.Init) bool {
    return !gitSucceeds(init, &[_][]const u8{ "git", "diff", "--quiet", "HEAD" });
}

/// Process-wide fallback allocator for the few publish helpers that receive no
/// caller allocator.
///
/// The page allocator suffices because [`tagExistsLocal`] makes one short-lived
/// allocation and frees it immediately; nothing here needs an arena or the
/// build's allocator.
var init_alloc = std.heap.page_allocator;
