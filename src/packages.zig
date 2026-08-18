// packages.zig — Nova's package manager (design: docs/design/pkg-manager.md).
//
// Cargo-flavoured identity (imports are by the dependency's DECLARED name), Zig-flavoured resolution
// (exact git-ref pins, git as the source of truth, no registry / no semver ranges / no MVS). A recorded
// commit SHA is both the version lock and the integrity check (git is content-addressed).
//
//   project.json       — manifest: name/version/type/repository + dependencies as "url[#ref]" strings.
//   project.lock.json  — flat lock of the WHOLE tree: {url, ref, resolved SHA, declared name} per dep.
//   ~/.nova/cache/<name>-<sha8>  — one dir per (package, version); versions coexist, mangling is
//                                  path-derived so distinct paths give distinct symbols (no codegen change).

const std = @import("std");
const Io = std.Io;
const pipeline = @import("pipeline.zig");

// -------------------------------------------------------------------------------------------------
// Small helpers
// -------------------------------------------------------------------------------------------------

fn homePath(init: std.process.Init) []const u8 {
    return init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/";
}

fn cacheRoot(allocator: std.mem.Allocator, init: std.process.Init) ![]const u8 {
    return std.fs.path.join(allocator, &[_][]const u8{ homePath(init), ".nova", "cache" });
}

const DepSpec = struct { url: []const u8, ref: ?[]const u8 };

// "url#ref" -> {url, ref}. A bare url (no '#') is an unpinned dependency (default branch).
fn parseDep(dep: []const u8) DepSpec {
    if (std.mem.lastIndexOfScalar(u8, dep, '#')) |h| {
        return .{ .url = dep[0..h], .ref = if (h + 1 < dep.len) dep[h + 1 ..] else null };
    }
    return .{ .url = dep, .ref = null };
}

// Cache directory NAME for a (declared name, resolved sha): "<name>-<sha8>", or "<name>-branch" for an
// unpinned dep with no recorded sha. Separator is '-' (not '@') so the path stays an identifier-safe
// mangle prefix.
fn cacheDirName(allocator: std.mem.Allocator, name: []const u8, sha: ?[]const u8) ![]const u8 {
    if (sha) |s| {
        const n = @min(s.len, 8);
        return std.fmt.allocPrint(allocator, "{s}-{s}", .{ name, s[0..n] });
    }
    return std.fmt.allocPrint(allocator, "{s}-branch", .{name});
}

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

fn isHexSha(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

// -------------------------------------------------------------------------------------------------
// git
// -------------------------------------------------------------------------------------------------

fn runGit(init: std.process.Init, argv: []const []const u8) !void {
    var child = try std.process.spawn(init.io, .{ .argv = argv });
    const term = try child.wait(init.io);
    switch (term) {
        .exited => |code| if (code != 0) return error.GitCommandFailed,
        else => return error.GitCommandFailed,
    }
}

// Read the resolved 40-char commit SHA from a freshly-fetched repo WITHOUT capturing subprocess output:
//   - a tag/SHA checkout leaves HEAD DETACHED, so .git/HEAD is the raw 40-hex SHA;
//   - a branch HEAD is `ref: refs/heads/<b>`, followed one level through the loose ref then packed-refs.
fn readHeadSha(allocator: std.mem.Allocator, io: std.Io, repo_dir: []const u8) ?[]const u8 {
    const head_path = std.fs.path.join(allocator, &[_][]const u8{ repo_dir, ".git", "HEAD" }) catch return null;
    const head = Io.Dir.readFileAlloc(.cwd(), io, head_path, allocator, .unlimited) catch return null;
    const trimmed = std.mem.trim(u8, head, " \t\r\n");
    if (isHexSha(trimmed)) return allocator.dupe(u8, trimmed) catch null;
    if (std.mem.startsWith(u8, trimmed, "ref:")) {
        const ref = std.mem.trim(u8, trimmed[4..], " \t\r\n");
        // loose ref: .git/<ref>
        const loose = std.fs.path.join(allocator, &[_][]const u8{ repo_dir, ".git", ref }) catch return null;
        if (Io.Dir.readFileAlloc(.cwd(), io, loose, allocator, .unlimited)) |lref| {
            const s = std.mem.trim(u8, lref, " \t\r\n");
            if (isHexSha(s)) return allocator.dupe(u8, s) catch null;
        } else |_| {}
        // packed-refs: lines "<sha> <ref>"
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

// Read the DECLARED package name from a fetched repo's project.json (falls back to the repo url name).
fn readDeclaredName(allocator: std.mem.Allocator, io: std.Io, repo_dir: []const u8, url: []const u8) []const u8 {
    const mpath = std.fs.path.join(allocator, &[_][]const u8{ repo_dir, "project.json" }) catch
        return repoNameFromUrl(url) orelse "dep";
    const data = Io.Dir.readFileAlloc(.cwd(), io, mpath, allocator, .unlimited) catch
        return repoNameFromUrl(url) orelse "dep";
    const parsed = std.json.parseFromSlice(pipeline.ProjectJson, allocator, data, .{ .ignore_unknown_fields = true }) catch
        return repoNameFromUrl(url) orelse "dep";
    return allocator.dupe(u8, parsed.value.name) catch (repoNameFromUrl(url) orelse "dep");
}

// -------------------------------------------------------------------------------------------------
// Lockfile
// -------------------------------------------------------------------------------------------------

const LockEntry = struct {
    url: []const u8,
    ref: ?[]const u8 = null,
    resolved: ?[]const u8 = null,
    name: []const u8,
};
const LockFile = struct {
    lockfileVersion: u32 = 1,
    dependencies: []LockEntry = &[_]LockEntry{},
};

fn readLock(allocator: std.mem.Allocator, io: std.Io) LockFile {
    const data = Io.Dir.readFileAlloc(.cwd(), io, "project.lock.json", allocator, .unlimited) catch return .{};
    const parsed = std.json.parseFromSlice(LockFile, allocator, data, .{ .ignore_unknown_fields = true }) catch return .{};
    return parsed.value;
}

fn refEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

// Match a dependency to its lock entry by (url, ref) — the SAME url at two DIFFERENT refs is two distinct
// pins (multi-version, pkg-manager.md §6), so ref must be part of the key, not url alone.
fn lockLookup(lock: LockFile, url: []const u8, ref: ?[]const u8) ?LockEntry {
    for (lock.dependencies) |e| {
        if (std.mem.eql(u8, e.url, url) and refEql(e.ref, ref)) return e;
    }
    return null;
}

fn writeLock(allocator: std.mem.Allocator, io: std.Io, entries: []const LockEntry) !void {
    const lf = LockFile{ .lockfileVersion = 1, .dependencies = @constCast(entries) };
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(lf, .{ .whitespace = .indent_2 }, &out.writer);
    try Io.Dir.writeFile(.cwd(), io, .{ .data = out.written(), .sub_path = "project.lock.json", .flags = .{} });
}

// -------------------------------------------------------------------------------------------------
// Fetch one dependency into the version-keyed cache (pkg-manager.md §4)
// -------------------------------------------------------------------------------------------------

const Fetched = struct { name: []const u8, sha: ?[]const u8, dir: []const u8 };

// checkout_target: the exact SHA/ref to check out (a locked SHA, or a #ref). null => default branch.
// `pinned` says whether a specific version is wanted (needs full history so a SHA checkout works).
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
    // An unpinned dep is honestly unversioned: no recorded sha, dir "<name>-branch".
    const recorded_sha: ?[]const u8 = if (checkout_target == null) null else sha;
    const dirname = try cacheDirName(allocator, name, recorded_sha);
    const dest = try std.fs.path.join(allocator, &[_][]const u8{ root, dirname });

    if (Io.Dir.access(.cwd(), init.io, dest, .{})) |_| {
        // cache hit — discard the tmp clone, reuse the existing dir
        Io.Dir.deleteTree(.cwd(), init.io, tmp) catch {};
    } else |_| {
        Io.Dir.renameAbsolute(tmp, dest, init.io) catch {
            // rename can fail across mounts; fall back to leaving tmp and pointing at it is unsafe, so error.
            return error.CacheMoveFailed;
        };
    }
    return .{ .name = name, .sha = recorded_sha, .dir = dest };
}

// -------------------------------------------------------------------------------------------------
// Whole-tree resolution (pkg-manager.md §3 + §5): recursive worklist, cache-deduped, honoring the lock.
// -------------------------------------------------------------------------------------------------

const Mode = enum { build, update };

fn readManifestDeps(allocator: std.mem.Allocator, io: std.Io, manifest_path: []const u8) [][]const u8 {
    const data = Io.Dir.readFileAlloc(.cwd(), io, manifest_path, allocator, .unlimited) catch return &[_][]const u8{};
    const parsed = std.json.parseFromSlice(pipeline.ProjectJson, allocator, data, .{ .ignore_unknown_fields = true }) catch return &[_][]const u8{};
    return parsed.value.dependencies;
}

// Resolve the whole dependency tree of the project in the CWD. Returns the flat lock (owned by allocator).
// mode=build honors existing lock entries (never moves a pinned SHA); a dep with no lock entry is resolved
// and ADDED. mode=update re-resolves `update_target` (or all when null) to the ref's current tip.
fn resolveTree(allocator: std.mem.Allocator, init: std.process.Init, mode: Mode, update_target: ?[]const u8) ![]LockEntry {
    const existing = readLock(allocator, init.io);

    var result = std.ArrayList(LockEntry).empty;
    var visited = std.StringHashMap(void).init(allocator); // cache dirnames already processed (§5 dedup)

    // worklist of "url[#ref]" dependency strings; seed with the root manifest's deps.
    var work = std.ArrayList([]const u8).empty;
    for (readManifestDeps(allocator, init.io, "project.json")) |d| try work.append(allocator, d);

    const root = try cacheRoot(allocator, init);

    while (work.items.len > 0) {
        const dep = work.orderedRemove(0);
        const spec = parseDep(dep);
        const locked = lockLookup(existing, spec.url, spec.ref);

        const moving = mode == .update and (update_target == null or std.mem.eql(u8, spec.url, update_target.?));

        // Fast path (§3: build honors the lock and never re-fetches): a locked entry whose version-keyed
        // cache dir already exists is reused as-is — no clone, no network. This is what makes a plain
        // `nova build` cheap and offline once restored. Only a MISSING dir or `nova update` fetches.
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

        // §3 precedence: locked SHA (build), else #ref, else default branch. update moves the target.
        const checkout_target: ?[]const u8 = blk: {
            if (!moving) {
                if (locked) |l| if (l.resolved) |r| break :blk r; // honor the lock
            }
            break :blk spec.ref; // resolve the ref (or null = default branch)
        };

        const fetched = fetchDep(allocator, init, spec.url, checkout_target) catch |err| {
            std.debug.print("[deps] failed to fetch {s}: {any}\n", .{ spec.url, @errorName(err) });
            return err;
        };
        const dirname = std.fs.path.basename(fetched.dir);
        if (visited.contains(dirname)) continue; // same (package, version) already resolved
        try visited.put(try allocator.dupe(u8, dirname), {});

        try result.append(allocator, .{
            .url = spec.url,
            .ref = spec.ref,
            .resolved = fetched.sha,
            .name = fetched.name,
        });

        // §5: recurse into the fetched package's own manifest.
        const sub_manifest = try std.fs.path.join(allocator, &[_][]const u8{ fetched.dir, "project.json" });
        for (readManifestDeps(allocator, init.io, sub_manifest)) |sd| try work.append(allocator, sd);
    }
    return result.items;
}

// -------------------------------------------------------------------------------------------------
// Auto-fetch before build/test — honor the lock, never move it (pkg-manager.md §3/§7).
// -------------------------------------------------------------------------------------------------

pub fn ensureDependencies(allocator: std.mem.Allocator, init: std.process.Init) !void {
    // No project.json => a bare-file compile; nothing to do.
    Io.Dir.access(.cwd(), init.io, "project.json", .{}) catch return;
    const deps = readManifestDeps(allocator, init.io, "project.json");
    if (deps.len == 0) return;

    const entries = try resolveTree(allocator, init, .build, null);
    // Only (re)write the lock if it changed — build must be idempotent and must not churn the file.
    const before = readLock(allocator, init.io);
    if (!lockEquals(before.dependencies, entries)) {
        try writeLock(allocator, init.io, entries);
    }
}

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

// -------------------------------------------------------------------------------------------------
// Commands
// -------------------------------------------------------------------------------------------------

pub fn cmdRestore(allocator: std.mem.Allocator, init: std.process.Init) !void {
    Io.Dir.access(.cwd(), init.io, "project.json", .{}) catch {
        std.debug.print("Error: project.json not found. Run 'nova init' first.\n", .{});
        return;
    };
    const entries = try resolveTree(allocator, init, .build, null);
    try writeLock(allocator, init.io, entries);
    std.debug.print("Restored {d} dependenc{s} (locked).\n", .{ entries.len, if (entries.len == 1) "y" else "ies" });
}

// nova get <url[#ref]> : add the dep to project.json, resolve, fetch (+transitive), write the lock.
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

// nova update [dep] : the ONLY command that moves a locked SHA to the ref's current tip.
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

// nova publish : tag v<version> at HEAD and push to origin (pkg-manager.md §8).
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

    // 1. library + repository required.
    if (m.type == null or !std.mem.eql(u8, m.type.?, "library")) {
        std.debug.print("publish: only a library can be published (set \"type\": \"library\").\n", .{});
        return error.NotALibrary;
    }
    if (m.repository == null or m.repository.?.len == 0) {
        std.debug.print("publish: set \"repository\" (canonical git URL) before publishing.\n", .{});
        return error.NoRepository;
    }

    // 2. version looks like semver X.Y.Z (warn, don't block).
    if (!looksSemver(m.version)) {
        std.debug.print("publish: warning — version \"{s}\" is not X.Y.Z semver.\n", .{m.version});
    }
    const tag = try std.fmt.allocPrint(allocator, "v{s}", .{m.version});

    // 3. refuse if the tag already exists locally or on the remote.
    if (tagExistsLocal(init, tag) or tagExistsRemote(init, tag)) {
        std.debug.print("publish: tag {s} already exists — never clobber a released version.\n", .{tag});
        return error.TagExists;
    }
    // 4. warn (do not block) if the working tree is dirty.
    if (workingTreeDirty(init)) {
        std.debug.print("publish: warning — working tree is dirty; uncommitted changes are NOT in the tag.\n", .{});
    }
    // 5. annotated tag at HEAD.
    const msg = try std.fmt.allocPrint(allocator, "{s}", .{tag});
    try runGit(init, &[_][]const u8{ "git", "tag", "-a", tag, "-m", msg });
    // 6. push to origin.
    try runGit(init, &[_][]const u8{ "git", "push", "origin", tag });
    // 7. print the consume line.
    std.debug.print("Published {s}. Consume with:\n  nova get {s}#{s}\n", .{ tag, m.repository.?, tag });
}

fn looksSemver(v: []const u8) bool {
    var dots: u8 = 0;
    for (v) |c| {
        if (c == '.') dots += 1 else if (!std.ascii.isDigit(c)) return false;
    }
    return dots == 2;
}

fn gitSucceeds(init: std.process.Init, argv: []const []const u8) bool {
    runGit(init, argv) catch return false;
    return true;
}

fn tagExistsLocal(init: std.process.Init, tag: []const u8) bool {
    const ref = std.fmt.allocPrint(init_alloc, "refs/tags/{s}", .{tag}) catch return false;
    defer init_alloc.free(ref);
    return gitSucceeds(init, &[_][]const u8{ "git", "show-ref", "--quiet", "--verify", ref });
}

fn tagExistsRemote(init: std.process.Init, tag: []const u8) bool {
    // `git ls-remote --exit-code --tags origin <tag>` exits 0 only if the tag exists on the remote.
    return gitSucceeds(init, &[_][]const u8{ "git", "ls-remote", "--exit-code", "--tags", "origin", tag });
}

fn workingTreeDirty(init: std.process.Init) bool {
    // `git diff --quiet` exits non-zero when there are unstaged changes; add --cached for staged.
    return !gitSucceeds(init, &[_][]const u8{ "git", "diff", "--quiet", "HEAD" });
}

// A tiny page allocator for the few short throwaway strings in publish helpers (avoids threading an
// allocator through the bool helpers). The compiler is short-lived; these frees are handled with defer.
var init_alloc = std.heap.page_allocator;
