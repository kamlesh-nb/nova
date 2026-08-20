//! Semantic-versioning (semver 2.0.0) parsing, range matching, and version unification for the package
//! manager. Supports the node-semver range grammar commonly written in manifests: exact (`1.2.3`), caret
//! (`^1.2.3`), tilde (`~1.2`), comparators (`>=1.0.0 <2.0.0`), wildcards (`1.x`, `1.*`, `*`), hyphen ranges
//! (`1.2.0 - 2.3.4`), and OR (`||`). `maxSatisfying` picks the newest version matching a range; `unify`
//! picks the newest version satisfying ALL of several ranges (dependency-tree version unification).

const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    // Prerelease identifiers ("beta.1" -> "beta.1"); "" means a normal release. Stored as a slice into the
    // original text, so a Version borrows from the string it was parsed from.
    prerelease: []const u8 = "",

    pub fn parse(text: []const u8) !Version {
        var s = std.mem.trim(u8, text, " \t");
        if (s.len > 0 and (s[0] == 'v' or s[0] == '=')) s = s[1..];
        // Split off build metadata (+...) and prerelease (-...).
        if (std.mem.indexOfScalar(u8, s, '+')) |plus| s = s[0..plus];
        var pre: []const u8 = "";
        if (std.mem.indexOfScalar(u8, s, '-')) |dash| {
            pre = s[dash + 1 ..];
            s = s[0..dash];
        }
        var it = std.mem.splitScalar(u8, s, '.');
        const maj = it.next() orelse return error.InvalidVersion;
        const min = it.next() orelse "0";
        const pat = it.next() orelse "0";
        return .{
            .major = try parseNum(maj),
            .minor = try parseNum(min),
            .patch = try parseNum(pat),
            .prerelease = pre,
        };
    }

    fn parseNum(t: []const u8) !u32 {
        if (t.len == 0 or std.mem.eql(u8, t, "x") or std.mem.eql(u8, t, "X") or std.mem.eql(u8, t, "*")) return 0;
        return std.fmt.parseInt(u32, t, 10) catch error.InvalidVersion;
    }

    /// -1 / 0 / 1 ordering. A prerelease sorts BEFORE its associated normal release (1.0.0-beta < 1.0.0).
    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        if (a.patch != b.patch) return std.math.order(a.patch, b.patch);
        // Same core. No prerelease outranks a prerelease.
        const ap = a.prerelease.len != 0;
        const bp = b.prerelease.len != 0;
        if (!ap and !bp) return .eq;
        if (!ap and bp) return .gt;
        if (ap and !bp) return .lt;
        return orderPrerelease(a.prerelease, b.prerelease);
    }

    fn orderPrerelease(a: []const u8, b: []const u8) std.math.Order {
        var ia = std.mem.splitScalar(u8, a, '.');
        var ib = std.mem.splitScalar(u8, b, '.');
        while (true) {
            const xa = ia.next();
            const xb = ib.next();
            if (xa == null and xb == null) return .eq;
            if (xa == null) return .lt; // fewer identifiers = lower precedence
            if (xb == null) return .gt;
            const sa = xa.?;
            const sb = xb.?;
            const na = std.fmt.parseInt(u64, sa, 10) catch null;
            const nb = std.fmt.parseInt(u64, sb, 10) catch null;
            if (na != null and nb != null) {
                const o = std.math.order(na.?, nb.?);
                if (o != .eq) return o;
            } else if (na != null) {
                return .lt; // numeric < alphanumeric
            } else if (nb != null) {
                return .gt;
            } else {
                const o = std.mem.order(u8, sa, sb);
                if (o != .eq) return o;
            }
        }
    }
};

const Op = enum { gte, gt, lte, lt, eq };
const Comparator = struct { op: Op, ver: Version };

fn cmpHolds(c: Comparator, v: Version) bool {
    const o = Version.order(v, c.ver);
    return switch (c.op) {
        .gte => o != .lt,
        .gt => o == .gt,
        .lte => o != .gt,
        .lt => o == .lt,
        .eq => o == .eq,
    };
}

// A comparator SET is an AND of comparators; a RANGE is an OR of sets. We evaluate lazily against a fixed
// input version rather than materialising the whole set list, keeping this allocation-free.

/// Does `version_text` satisfy `range_text`? Both are semver strings.
pub fn satisfies(range_text: []const u8, version_text: []const u8) bool {
    const v = Version.parse(version_text) catch return false;
    return satisfiesV(range_text, v);
}

pub fn satisfiesV(range_text: []const u8, v: Version) bool {
    // OR of sets separated by "||".
    var or_it = std.mem.splitSequence(u8, range_text, "||");
    while (or_it.next()) |set_text| {
        if (setSatisfies(std.mem.trim(u8, set_text, " \t"), v)) return true;
    }
    return false;
}

fn setSatisfies(set_text: []const u8, v: Version) bool {
    if (set_text.len == 0 or std.mem.eql(u8, set_text, "*")) return true;
    // Hyphen range "a - b".
    if (std.mem.indexOf(u8, set_text, " - ")) |dash| {
        const lo = std.mem.trim(u8, set_text[0..dash], " \t");
        const hi = std.mem.trim(u8, set_text[dash + 3 ..], " \t");
        const lov = Version.parse(lo) catch return false;
        const hiv = Version.parse(hi) catch return false;
        return cmpHolds(.{ .op = .gte, .ver = lov }, v) and cmpHolds(.{ .op = .lte, .ver = hiv }, v);
    }
    // AND of space-separated comparators / caret / tilde / wildcard atoms.
    var it = std.mem.tokenizeScalar(u8, set_text, ' ');
    while (it.next()) |atom| {
        if (!atomSatisfies(atom, v)) return false;
    }
    return true;
}

fn atomSatisfies(atom: []const u8, v: Version) bool {
    if (atom.len == 0 or std.mem.eql(u8, atom, "*") or std.mem.eql(u8, atom, "x") or std.mem.eql(u8, atom, "X")) return true;
    if (atom[0] == '^') return caret(atom[1..], v);
    if (atom[0] == '~') return tilde(atom[1..], v);
    if (std.mem.startsWith(u8, atom, ">=")) return cmpHolds(.{ .op = .gte, .ver = pv(atom[2..]) }, v);
    if (std.mem.startsWith(u8, atom, "<=")) return cmpHolds(.{ .op = .lte, .ver = pv(atom[2..]) }, v);
    if (atom[0] == '>') return cmpHolds(.{ .op = .gt, .ver = pv(atom[1..]) }, v);
    if (atom[0] == '<') return cmpHolds(.{ .op = .lt, .ver = pv(atom[1..]) }, v);
    if (atom[0] == '=') return wildcardOrExact(atom[1..], v);
    return wildcardOrExact(atom, v);
}

fn pv(t: []const u8) Version {
    return Version.parse(t) catch Version{ .major = 0, .minor = 0, .patch = 0 };
}

// A bare version, possibly with x/* wildcards in minor/patch: "1", "1.2", "1.x", "1.2.x", or exact "1.2.3".
fn wildcardOrExact(t0: []const u8, v: Version) bool {
    const t = std.mem.trim(u8, t0, " \t");
    var it = std.mem.splitScalar(u8, t, '.');
    const maj_s = it.next() orelse return true;
    const min_s = it.next();
    const pat_s = it.next();
    if (isWild(maj_s)) return true;
    const maj = std.fmt.parseInt(u32, maj_s, 10) catch return false;
    if (min_s == null or isWild(min_s.?)) {
        // "1" / "1.x" -> >=maj.0.0 <(maj+1).0.0
        return v.major == maj;
    }
    const min = std.fmt.parseInt(u32, min_s.?, 10) catch return false;
    if (pat_s == null or isWild(pat_s.?)) {
        // "1.2" / "1.2.x" -> major==maj and minor==min
        return v.major == maj and v.minor == min;
    }
    const pat = std.fmt.parseInt(u32, pat_s.?, 10) catch return false;
    return v.major == maj and v.minor == min and v.patch == pat and v.prerelease.len == 0;
}

fn isWild(s: []const u8) bool {
    return s.len == 0 or std.mem.eql(u8, s, "x") or std.mem.eql(u8, s, "X") or std.mem.eql(u8, s, "*");
}

// ^a.b.c: >=a.b.c and < the next version that changes the LEFTMOST non-zero of (a,b,c).
fn caret(t: []const u8, v: Version) bool {
    const b = pv(t);
    if (!cmpHolds(.{ .op = .gte, .ver = b }, v)) return false;
    var upper = Version{ .major = 0, .minor = 0, .patch = 0 };
    if (b.major != 0) {
        upper = .{ .major = b.major + 1, .minor = 0, .patch = 0 };
    } else if (b.minor != 0) {
        upper = .{ .major = 0, .minor = b.minor + 1, .patch = 0 };
    } else {
        upper = .{ .major = 0, .minor = 0, .patch = b.patch + 1 };
    }
    return cmpHolds(.{ .op = .lt, .ver = upper }, v);
}

// ~a.b.c: >=a.b.c <a.(b+1).0 ; ~a.b: same ; ~a: >=a.0.0 <(a+1).0.0
fn tilde(t: []const u8, v: Version) bool {
    const b = pv(t);
    if (!cmpHolds(.{ .op = .gte, .ver = b }, v)) return false;
    // Did the range name a minor? (i.e. is there a second dotted component)
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, t, " \t"), '.');
    _ = it.next();
    const had_minor = it.next() != null;
    const upper = if (had_minor)
        Version{ .major = b.major, .minor = b.minor + 1, .patch = 0 }
    else
        Version{ .major = b.major + 1, .minor = 0, .patch = 0 };
    return cmpHolds(.{ .op = .lt, .ver = upper }, v);
}

/// The newest of `versions` satisfying `range`, or null. `versions` are semver strings.
pub fn maxSatisfying(range_text: []const u8, versions: []const []const u8) ?[]const u8 {
    var best: ?Version = null;
    var best_text: ?[]const u8 = null;
    for (versions) |vt| {
        const v = Version.parse(vt) catch continue;
        if (!satisfiesV(range_text, v)) continue;
        if (best == null or Version.order(v, best.?) == .gt) {
            best = v;
            best_text = vt;
        }
    }
    return best_text;
}

/// The newest of `versions` satisfying EVERY range in `ranges` (dependency-tree version unification), or
/// null if the constraints are jointly unsatisfiable by the available versions.
pub fn unify(ranges: []const []const u8, versions: []const []const u8) ?[]const u8 {
    var best: ?Version = null;
    var best_text: ?[]const u8 = null;
    for (versions) |vt| {
        const v = Version.parse(vt) catch continue;
        var all = true;
        for (ranges) |r| {
            if (!satisfiesV(r, v)) {
                all = false;
                break;
            }
        }
        if (!all) continue;
        if (best == null or Version.order(v, best.?) == .gt) {
            best = v;
            best_text = vt;
        }
    }
    return best_text;
}

// ---- tests ------------------------------------------------------------------------------------------------

test "version parse + order" {
    const a = try Version.parse("1.2.3");
    try std.testing.expectEqual(@as(u32, 1), a.major);
    try std.testing.expectEqual(@as(u32, 2), a.minor);
    try std.testing.expectEqual(@as(u32, 3), a.patch);
    try std.testing.expectEqual(std.math.Order.lt, Version.order(try Version.parse("1.2.3"), try Version.parse("1.2.4")));
    try std.testing.expectEqual(std.math.Order.gt, Version.order(try Version.parse("2.0.0"), try Version.parse("1.9.9")));
    try std.testing.expectEqual(std.math.Order.eq, Version.order(try Version.parse("1.0.0"), try Version.parse("1.0.0")));
    // Prerelease sorts before release, and by identifier.
    try std.testing.expectEqual(std.math.Order.lt, Version.order(try Version.parse("1.0.0-beta"), try Version.parse("1.0.0")));
    try std.testing.expectEqual(std.math.Order.lt, Version.order(try Version.parse("1.0.0-alpha"), try Version.parse("1.0.0-beta")));
    try std.testing.expectEqual(std.math.Order.lt, Version.order(try Version.parse("1.0.0-alpha.1"), try Version.parse("1.0.0-alpha.2")));
}

test "caret ranges" {
    try std.testing.expect(satisfies("^1.2.3", "1.2.3"));
    try std.testing.expect(satisfies("^1.2.3", "1.9.0"));
    try std.testing.expect(!satisfies("^1.2.3", "2.0.0"));
    try std.testing.expect(!satisfies("^1.2.3", "1.2.2"));
    // 0.x: caret pins the minor.
    try std.testing.expect(satisfies("^0.2.3", "0.2.9"));
    try std.testing.expect(!satisfies("^0.2.3", "0.3.0"));
    // 0.0.x: caret pins the patch.
    try std.testing.expect(satisfies("^0.0.3", "0.0.3"));
    try std.testing.expect(!satisfies("^0.0.3", "0.0.4"));
}

test "tilde + wildcard + comparators + hyphen + or" {
    try std.testing.expect(satisfies("~1.2.3", "1.2.9"));
    try std.testing.expect(!satisfies("~1.2.3", "1.3.0"));
    try std.testing.expect(satisfies("~1.2", "1.2.5"));
    try std.testing.expect(!satisfies("~1.2", "1.3.0"));
    try std.testing.expect(satisfies("1.x", "1.9.9"));
    try std.testing.expect(!satisfies("1.x", "2.0.0"));
    try std.testing.expect(satisfies("1.2.x", "1.2.7"));
    try std.testing.expect(!satisfies("1.2.x", "1.3.0"));
    try std.testing.expect(satisfies("*", "9.9.9"));
    try std.testing.expect(satisfies(">=1.2.0 <2.0.0", "1.5.0"));
    try std.testing.expect(!satisfies(">=1.2.0 <2.0.0", "2.0.0"));
    try std.testing.expect(satisfies("1.2.0 - 2.3.4", "2.0.0"));
    try std.testing.expect(!satisfies("1.2.0 - 2.3.4", "2.4.0"));
    try std.testing.expect(satisfies("1.0.0 || >=2.0.0", "2.5.0"));
    try std.testing.expect(satisfies("1.0.0 || >=2.0.0", "1.0.0"));
    try std.testing.expect(!satisfies("1.0.0 || >=2.0.0", "1.5.0"));
    try std.testing.expect(satisfies("=1.2.3", "1.2.3"));
}

test "maxSatisfying + unify" {
    const versions = [_][]const u8{ "1.0.0", "1.2.0", "1.4.1", "2.0.0", "2.1.0" };
    try std.testing.expectEqualStrings("1.4.1", maxSatisfying("^1.2.0", &versions).?);
    try std.testing.expectEqualStrings("2.1.0", maxSatisfying(">=2.0.0", &versions).?);
    try std.testing.expect(maxSatisfying("^3.0.0", &versions) == null);
    // unify: highest version satisfying BOTH ^1.0.0 and >=1.3.0 -> 1.4.1 (2.x excluded by ^1).
    const ranges = [_][]const u8{ "^1.0.0", ">=1.3.0" };
    try std.testing.expectEqualStrings("1.4.1", unify(&ranges, &versions).?);
    // Jointly unsatisfiable.
    const bad = [_][]const u8{ "^1.0.0", ">=2.0.0" };
    try std.testing.expect(unify(&bad, &versions) == null);
}
