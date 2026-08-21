//! Semantic-versioning parser and node-semver range matcher.
//!
//! This module is the version-comparison core the package manager sits on top
//! of. It has two halves:
//!
//!   1. [`Version`]: parse a Semantic Versioning 2.0.0 string into its
//!      `major.minor.patch` plus optional prerelease, and order two versions by
//!      precedence exactly as the spec defines (including the tricky prerelease
//!      rules in spec section 11).
//!
//!   2. The range grammar ([`satisfies`], [`maxSatisfying`], [`unify`]): the
//!      node-semver dialect used by npm and Cargo, i.e. `^`, `~`, comparators
//!      (`>= > <= < =`), `x`/`*` wildcards, `a - b` hyphen ranges, and `||`
//!      alternation. This is what a manifest writes when it depends on
//!      `"nova-http@^1.2.0"`.
//!
//! It is deliberately allocation-free and dependency-free: everything works on
//! borrowed `[]const u8` slices of the caller's text, and the only failure mode
//! for a range match is "returns false / null". A malformed VERSION errors from
//! [`Version.parse`]; a malformed RANGE is treated as "matches nothing" rather
//! than erroring, because a range is untrusted manifest input and we would
//! rather reject a dependency than crash resolving it.
//!
//! `unify` is the dependency-tree entry point: given several ranges that must
//! all hold (one per dependent) and the list of published versions, it returns
//! the newest version satisfying every range, which is how two dependents on
//! the same package agree on one resolved version. See `src/registry.zig`,
//! which calls this to rewrite a name+range dependency into a concrete git ref.

const std = @import("std");

/// A parsed Semantic Versioning 2.0.0 identity.
///
/// Build metadata (`+sha`, `+build.1`) is intentionally NOT stored: per the
/// spec it does not affect precedence, so [`parse`] strips and ignores it. The
/// `prerelease` field borrows a slice of the original text, so a `Version` is
/// only valid for as long as the string it was parsed from stays alive.
pub const Version = struct {
    /// Major version. Bumped for incompatible API changes.
    major: u32,
    /// Minor version. Bumped for backwards-compatible feature additions.
    minor: u32,
    /// Patch version. Bumped for backwards-compatible bug fixes.
    patch: u32,
    /// Prerelease identifier without the leading `-` (e.g. `beta.2`), or the
    /// empty string for a normal release. A present prerelease sorts BELOW the
    /// same core version with none (`1.0.0-beta` < `1.0.0`).
    prerelease: []const u8 = "",

    /// Parses a version string into a [`Version`].
    ///
    /// Tolerant of the common cosmetic prefixes: a leading `v` or `=` is
    /// dropped (`v1.2.3` and `=1.2.3` both parse). Build metadata after `+` is
    /// discarded. A `-` splits off the prerelease. Missing minor/patch
    /// components default to `0`, and a wildcard component (`x`/`X`/`*`) counts
    /// as `0`, so `1`, `1.x` and `1.0.0` all parse to `1.0.0`.
    ///
    /// Returns `error.InvalidVersion` if the major component is missing or any
    /// present numeric component is not a base-10 integer.
    pub fn parse(text: []const u8) !Version {
        var s = std.mem.trim(u8, text, " \t");
        if (s.len > 0 and (s[0] == 'v' or s[0] == '=')) s = s[1..];
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

    /// Parses one numeric version component.
    ///
    /// An empty or wildcard component (`x`/`X`/`*`) is treated as `0` so that
    /// partial versions used as range bases (e.g. the `1.2` in `~1.2`) parse.
    /// Any other non-numeric text is `error.InvalidVersion`.
    fn parseNum(t: []const u8) !u32 {
        if (t.len == 0 or std.mem.eql(u8, t, "x") or std.mem.eql(u8, t, "X") or std.mem.eql(u8, t, "*")) return 0;
        return std.fmt.parseInt(u32, t, 10) catch error.InvalidVersion;
    }

    /// Orders two versions by SemVer precedence.
    ///
    /// Compares `major`, then `minor`, then `patch` numerically. If the cores
    /// are equal, the prerelease rule applies: a version WITH a prerelease has
    /// LOWER precedence than the same core WITHOUT one (`1.0.0-x` < `1.0.0`),
    /// and two prereleases are ordered by [`orderPrerelease`].
    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        if (a.patch != b.patch) return std.math.order(a.patch, b.patch);
        const ap = a.prerelease.len != 0;
        const bp = b.prerelease.len != 0;
        if (!ap and !bp) return .eq;
        if (!ap and bp) return .gt;
        if (ap and !bp) return .lt;
        return orderPrerelease(a.prerelease, b.prerelease);
    }

    /// Orders two non-empty prerelease strings per SemVer spec section 11.
    ///
    /// Each string is split on `.` into identifiers compared left to right:
    ///
    ///   - Two numeric identifiers compare numerically.
    ///   - A numeric identifier always ranks LOWER than an alphanumeric one.
    ///   - Two alphanumeric identifiers compare by ASCII order.
    ///   - If all compared identifiers are equal, the string with MORE
    ///     identifiers ranks higher (`alpha` < `alpha.1`).
    fn orderPrerelease(a: []const u8, b: []const u8) std.math.Order {
        var ia = std.mem.splitScalar(u8, a, '.');
        var ib = std.mem.splitScalar(u8, b, '.');
        while (true) {
            const xa = ia.next();
            const xb = ib.next();
            if (xa == null and xb == null) return .eq;
            if (xa == null) return .lt;
            if (xb == null) return .gt;
            const sa = xa.?;
            const sb = xb.?;
            const na = std.fmt.parseInt(u64, sa, 10) catch null;
            const nb = std.fmt.parseInt(u64, sb, 10) catch null;
            if (na != null and nb != null) {
                const o = std.math.order(na.?, nb.?);
                if (o != .eq) return o;
            } else if (na != null) {
                return .lt;
            } else if (nb != null) {
                return .gt;
            } else {
                const o = std.mem.order(u8, sa, sb);
                if (o != .eq) return o;
            }
        }
    }
};

/// A single comparison operator in a range atom.
const Op = enum { gte, gt, lte, lt, eq };

/// One comparator: an operator applied against a bound version, e.g. `>=1.2.0`.
const Comparator = struct { op: Op, ver: Version };

/// Returns `true` if version `v` satisfies the comparator `c`.
///
/// Evaluated by mapping the [`std.math.Order`] of `v` against `c.ver` onto the
/// operator: for example `>=` holds when the order is anything but `.lt`.
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

/// Returns `true` if `version_text` satisfies `range_text`.
///
/// Convenience wrapper over [`satisfiesV`] that parses the version first; a
/// version that fails to parse satisfies nothing.
pub fn satisfies(range_text: []const u8, version_text: []const u8) bool {
    const v = Version.parse(version_text) catch return false;
    return satisfiesV(range_text, v);
}

/// Returns `true` if the parsed version `v` satisfies `range_text`.
///
/// A range is a list of comparator SETS separated by `||`; the range holds if
/// ANY set holds (logical OR). Each set is handled by [`setSatisfies`].
pub fn satisfiesV(range_text: []const u8, v: Version) bool {
    var or_it = std.mem.splitSequence(u8, range_text, "||");
    while (or_it.next()) |set_text| {
        if (setSatisfies(std.mem.trim(u8, set_text, " \t"), v)) return true;
    }
    return false;
}

/// Returns `true` if `v` satisfies a single comparator set (one `||` branch).
///
/// An empty set or `*` matches anything. A set containing ` - ` is a hyphen
/// range `lo - hi` (inclusive on both ends). Otherwise the set is a
/// space-separated list of atoms that must ALL hold (logical AND), each
/// evaluated by [`atomSatisfies`].
fn setSatisfies(set_text: []const u8, v: Version) bool {
    if (set_text.len == 0 or std.mem.eql(u8, set_text, "*")) return true;
    if (std.mem.indexOf(u8, set_text, " - ")) |dash| {
        const lo = std.mem.trim(u8, set_text[0..dash], " \t");
        const hi = std.mem.trim(u8, set_text[dash + 3 ..], " \t");
        const lov = Version.parse(lo) catch return false;
        const hiv = Version.parse(hi) catch return false;
        return cmpHolds(.{ .op = .gte, .ver = lov }, v) and cmpHolds(.{ .op = .lte, .ver = hiv }, v);
    }
    var it = std.mem.tokenizeScalar(u8, set_text, ' ');
    while (it.next()) |atom| {
        if (!atomSatisfies(atom, v)) return false;
    }
    return true;
}

/// Returns `true` if `v` satisfies a single range atom.
///
/// Dispatches on the atom's leading sigil: `*`/`x`/`X` (any), `^` ([`caret`]),
/// `~` ([`tilde`]), the comparators `>= <= > <`, and `=` or a bare version
/// ([`wildcardOrExact`]).
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

/// Parses a version bound inside a range, defaulting to `0.0.0` on error.
///
/// Range atoms are untrusted text, and a comparator with a malformed bound
/// should fail the match rather than crash; `0.0.0` is the safe floor that
/// makes a bad `>=` bound trivially true and a bad `<` bound trivially false.
fn pv(t: []const u8) Version {
    return Version.parse(t) catch Version{ .major = 0, .minor = 0, .patch = 0 };
}

/// Matches a partial-wildcard or exact-version atom.
///
/// Handles `1`, `1.2`, `1.x`, `1.2.x`, and a fully specified `1.2.3`. A
/// wildcard (or omitted) component matches any value at that position, so
/// `1.x` matches every `1.*.*`. A fully specified atom requires an exact
/// core match AND no prerelease (`1.2.3` does not match `1.2.3-beta`).
fn wildcardOrExact(t0: []const u8, v: Version) bool {
    const t = std.mem.trim(u8, t0, " \t");
    var it = std.mem.splitScalar(u8, t, '.');
    const maj_s = it.next() orelse return true;
    const min_s = it.next();
    const pat_s = it.next();
    if (isWild(maj_s)) return true;
    const maj = std.fmt.parseInt(u32, maj_s, 10) catch return false;
    if (min_s == null or isWild(min_s.?)) {
        return v.major == maj;
    }
    const min = std.fmt.parseInt(u32, min_s.?, 10) catch return false;
    if (pat_s == null or isWild(pat_s.?)) {
        return v.major == maj and v.minor == min;
    }
    const pat = std.fmt.parseInt(u32, pat_s.?, 10) catch return false;
    return v.major == maj and v.minor == min and v.patch == pat and v.prerelease.len == 0;
}

/// Returns `true` if a component is a wildcard: empty, `x`, `X`, or `*`.
fn isWild(s: []const u8) bool {
    return s.len == 0 or std.mem.eql(u8, s, "x") or std.mem.eql(u8, s, "X") or std.mem.eql(u8, s, "*");
}

/// Evaluates a caret range `^base` against `v`.
///
/// Caret allows changes that do not modify the left-most NON-ZERO component: it
/// is `>= base` and `<` the next bump of that component. So `^1.2.3` is
/// `>=1.2.3 <2.0.0`; `^0.2.3` is `>=0.2.3 <0.3.0`; and `^0.0.3` is
/// `>=0.0.3 <0.0.4`. This mirrors npm/Cargo caret semantics where the 0.x
/// series treats minor (and 0.0.x treats patch) as the breaking axis.
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

/// Evaluates a tilde range `~base` against `v`.
///
/// Tilde allows patch-level changes if a minor is specified, otherwise
/// minor-level changes: it is `>= base` and `<` the next minor when the base
/// names a minor, else `<` the next major. So `~1.2.3` and `~1.2` are both
/// `>=base <1.3.0`, while `~1` is `>=1.0.0 <2.0.0`. Whether a minor was given
/// is detected by re-splitting the base text (a bare `1` has no second field).
fn tilde(t: []const u8, v: Version) bool {
    const b = pv(t);
    if (!cmpHolds(.{ .op = .gte, .ver = b }, v)) return false;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, t, " \t"), '.');
    _ = it.next();
    const had_minor = it.next() != null;
    const upper = if (had_minor)
        Version{ .major = b.major, .minor = b.minor + 1, .patch = 0 }
    else
        Version{ .major = b.major + 1, .minor = 0, .patch = 0 };
    return cmpHolds(.{ .op = .lt, .ver = upper }, v);
}

/// Returns the newest version in `versions` that satisfies `range_text`.
///
/// Iterates the candidate list, keeps every version that both parses and
/// satisfies the range, and returns the one with the highest precedence
/// (returned as the ORIGINAL text so the caller can use it verbatim). Returns
/// `null` if none match. Unparseable candidates are skipped, not errors.
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

/// Returns the newest version in `versions` that satisfies EVERY range.
///
/// This is dependency-tree version unification: given the several ranges that
/// different dependents place on one package (`ranges`) and that package's
/// published versions (`versions`), it returns the single newest version that
/// all ranges accept, or `null` if the ranges have no common satisfier. It is
/// [`maxSatisfying`] generalised from one range to an AND of ranges.
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

// Core parse + precedence, including the prerelease ordering rules (spec §11).
test "version parse + order" {
    const a = try Version.parse("1.2.3");
    try std.testing.expectEqual(@as(u32, 1), a.major);
    try std.testing.expectEqual(@as(u32, 2), a.minor);
    try std.testing.expectEqual(@as(u32, 3), a.patch);
    try std.testing.expectEqual(std.math.Order.lt, Version.order(try Version.parse("1.2.3"), try Version.parse("1.2.4")));
    try std.testing.expectEqual(std.math.Order.gt, Version.order(try Version.parse("2.0.0"), try Version.parse("1.9.9")));
    try std.testing.expectEqual(std.math.Order.eq, Version.order(try Version.parse("1.0.0"), try Version.parse("1.0.0")));
    try std.testing.expectEqual(std.math.Order.lt, Version.order(try Version.parse("1.0.0-beta"), try Version.parse("1.0.0")));
    try std.testing.expectEqual(std.math.Order.lt, Version.order(try Version.parse("1.0.0-alpha"), try Version.parse("1.0.0-beta")));
    try std.testing.expectEqual(std.math.Order.lt, Version.order(try Version.parse("1.0.0-alpha.1"), try Version.parse("1.0.0-alpha.2")));
}

// Caret bounds across the 1.x, 0.x and 0.0.x breaking-axis cases.
test "caret ranges" {
    try std.testing.expect(satisfies("^1.2.3", "1.2.3"));
    try std.testing.expect(satisfies("^1.2.3", "1.9.0"));
    try std.testing.expect(!satisfies("^1.2.3", "2.0.0"));
    try std.testing.expect(!satisfies("^1.2.3", "1.2.2"));
    try std.testing.expect(satisfies("^0.2.3", "0.2.9"));
    try std.testing.expect(!satisfies("^0.2.3", "0.3.0"));
    try std.testing.expect(satisfies("^0.0.3", "0.0.3"));
    try std.testing.expect(!satisfies("^0.0.3", "0.0.4"));
}

// Tilde, wildcard, comparator, hyphen-range and `||` alternation grammar.
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

// maxSatisfying picks the newest match; unify picks the newest common match.
test "maxSatisfying + unify" {
    const versions = [_][]const u8{ "1.0.0", "1.2.0", "1.4.1", "2.0.0", "2.1.0" };
    try std.testing.expectEqualStrings("1.4.1", maxSatisfying("^1.2.0", &versions).?);
    try std.testing.expectEqualStrings("2.1.0", maxSatisfying(">=2.0.0", &versions).?);
    try std.testing.expect(maxSatisfying("^3.0.0", &versions) == null);
    const ranges = [_][]const u8{ "^1.0.0", ">=1.3.0" };
    try std.testing.expectEqualStrings("1.4.1", unify(&ranges, &versions).?);
    const bad = [_][]const u8{ "^1.0.0", ">=2.0.0" };
    try std.testing.expect(unify(&bad, &versions) == null);
}
