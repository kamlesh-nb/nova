//! Allocation profiler, an `std.mem.Allocator` wrapper that attributes every
//! live allocation to the CALL SITE that made it.
//!
//! The compiler and its runtime allocate heavily, and when memory grows without
//! bound the useful question is not "how much is live" but "which line of code
//! is holding it". This module answers that. [`Profiler`] wraps a real backing
//! allocator, forwards every operation to it unchanged, and on the side records
//! the return address of the caller (`ret_addr`, i.e. the instruction just after
//! the `alloc` call) as a proxy for the site, tallying counts and live bytes per
//! site. [`Profiler.dump`] then prints the top sites ranked by live bytes, which
//! is the leak/bloat report.
//!
//! Design decisions and invariants:
//!
//!   * Bookkeeping uses a SEPARATE `track` allocator, not the profiled `backing`
//!     one, so the profiler's own hash-map growth never pollutes the numbers it
//!     is reporting (and never recurses through itself).
//!
//!   * The profiler is best-effort and MUST NOT change program behaviour: every
//!     bookkeeping step swallows its own errors (`catch return` / `catch {}`).
//!     If the `track` allocator is out of memory a site simply goes uncounted;
//!     the profiled allocation still succeeds. Never abort the program to
//!     record a statistic.
//!
//!   * Live accounting is keyed by the returned pointer address, so `resize`,
//!     `remap` and `free` can find the owning site and adjust its live bytes.
//!     Because addresses are reused over time the `live` map holds only
//!     currently-outstanding allocations; it shrinks on free.
//!
//! Sites are printed as runtime addresses, not symbol names. [`Profiler.dump`]
//! also prints the runtime address of `dump` itself as an ANCHOR, so a caller
//! can subtract it from a site address to recover the static offset and resolve
//! the symbol against the binary out-of-band.

const std = @import("std");

/// A profiling `std.mem.Allocator` that wraps a backing allocator and records,
/// per call site, how many allocations were made and how many bytes are still
/// live.
///
/// Construct with [`Profiler.init`], then hand [`Profiler.allocator`]'s result
/// to the code under study. The `Profiler` value must outlive that allocator.
/// Call [`Profiler.dump`] at any point to print the current per-site report.
pub const Profiler = struct {
    /// The real allocator every request is forwarded to. All actual memory
    /// comes from here; the profiler only observes.
    backing: std.mem.Allocator,
    /// The allocator used for the profiler's OWN bookkeeping (`sites`/`live`).
    /// Deliberately distinct from [`Profiler.backing`] so profiling overhead is
    /// not counted as profiled memory and cannot recurse into the profiler.
    track: std.mem.Allocator,
    /// Per-site aggregates, keyed by the caller's return address (`ret_addr`).
    /// See [`Profiler.Site`].
    sites: std.AutoHashMapUnmanaged(usize, Site) = .empty,
    /// Currently-outstanding allocations, keyed by their pointer address, so a
    /// later resize/free can find the owning site. See [`Profiler.Live`].
    live: std.AutoHashMapUnmanaged(usize, Live) = .empty,
    /// Lifetime count of alloc calls observed (never decremented).
    total_alloc: usize = 0,
    /// Lifetime count of free calls observed. `total_alloc - total_free` is the
    /// net number of live allocations.
    total_free: usize = 0,

    /// Aggregate statistics for one call site.
    ///
    /// `count`/`bytes` are cumulative over the whole run and only ever grow;
    /// `live_count`/`live_bytes` track what is outstanding RIGHT NOW and move
    /// both up (on alloc) and down (on free/resize), which is why the report
    /// ranks by `live_bytes`.
    const Site = struct { count: usize = 0, bytes: usize = 0, live_count: usize = 0, live_bytes: usize = 0 };
    /// Record of one outstanding allocation: the `site` that made it (its key in
    /// [`Profiler.sites`]) and its current `len`, so a free can subtract the
    /// right amount from the right site.
    const Live = struct { site: usize, len: usize };

    /// The allocator vtable that routes `std.mem.Allocator` calls into this
    /// module's [`Profiler.alloc`]/[`Profiler.resize`]/[`Profiler.remap`]/[`Profiler.free`]
    /// shims. Shared by every [`Profiler.allocator`] handle.
    const vtable = std.mem.Allocator.VTable{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    /// Creates a profiler over `backing`, using `track` for its own bookkeeping.
    ///
    /// Pass two DIFFERENT allocators: `backing` is what you want to measure,
    /// `track` is somewhere else (e.g. a page allocator) so the measurement does
    /// not perturb the measured. Maps start empty and grow lazily.
    pub fn init(backing: std.mem.Allocator, track: std.mem.Allocator) Profiler {
        return .{ .backing = backing, .track = track };
    }
    /// Returns an `std.mem.Allocator` interface backed by this profiler.
    ///
    /// The returned handle borrows `self`, so `self` must stay alive (and at a
    /// fixed address) for as long as the handle is used.
    pub fn allocator(self: *Profiler) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Records a newly-granted allocation of `len` bytes at address `ptr`, made
    /// from call site `site`.
    ///
    /// Bumps the site's cumulative and live tallies and inserts a [`Profiler.Live`]
    /// entry keyed by `ptr`. Every failure path is swallowed: a failed
    /// `getOrPut` returns without counting, and a failed `live` insert is
    /// ignored, so profiling can never make a real allocation fail.
    fn onAlloc(self: *Profiler, ptr: usize, site: usize, len: usize) void {
        self.total_alloc += 1;
        const gop = self.sites.getOrPut(self.track, site) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.count += 1;
        gop.value_ptr.bytes += len;
        gop.value_ptr.live_count += 1;
        gop.value_ptr.live_bytes += len;
        self.live.put(self.track, ptr, .{ .site = site, .len = len }) catch {};
    }
    /// Records that the allocation at `ptr` has been freed.
    ///
    /// Removes its [`Profiler.Live`] entry and decrements the owning site's live
    /// count and bytes (saturating with `-|=`, so a double-free or an untracked
    /// pointer cannot underflow into a huge value). A `ptr` with no live entry
    /// (e.g. allocated before profiling began) is silently ignored.
    fn onFree(self: *Profiler, ptr: usize) void {
        self.total_free += 1;
        if (self.live.fetchRemove(ptr)) |kv| {
            if (self.sites.getPtr(kv.value.site)) |s| {
                s.live_count -|= 1;
                s.live_bytes -|= kv.value.len;
            }
        }
    }

    /// Vtable `alloc` shim: forwards to `backing.rawAlloc`, and on success
    /// records the allocation against `ret_addr` (the call site).
    ///
    /// Returns `null` unchanged if the backing allocator fails, without
    /// recording anything. `ctx` is the erased `*Profiler`.
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Profiler = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.onAlloc(@intFromPtr(p), ret_addr, len);
        return p;
    }
    /// Vtable `resize` shim: an in-place resize keeps the SAME base pointer, so
    /// it updates the existing [`Profiler.Live`] entry and the site's live bytes
    /// by the delta (`new_len - old_len`) rather than moving anything.
    ///
    /// Returns `false` untouched if the backing allocator cannot resize in
    /// place. The site's cumulative `bytes` is intentionally not adjusted (it
    /// counts allocation volume, not peak).
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Profiler = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (self.live.getPtr(@intFromPtr(memory.ptr))) |lv| {
            if (self.sites.getPtr(lv.site)) |s| {
                s.live_bytes = s.live_bytes - lv.len + new_len;
            }
            lv.len = new_len;
        }
        return true;
    }
    /// Vtable `remap` shim: a remap MAY move the block, so the old `live` entry
    /// is removed and a new one inserted at the (possibly new) address `np`.
    ///
    /// The subtle part is site attribution: the block should stay charged to the
    /// site that originally allocated it, so the old entry's `site` is carried
    /// over. If the old address was untracked, it falls back to `ret_addr` (the
    /// site of the remap call). Live bytes are moved off the old length and onto
    /// `new_len` for that site.
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Profiler = @ptrCast(@alignCast(ctx));
        const np = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        const site = if (self.live.fetchRemove(@intFromPtr(memory.ptr))) |kv| blk: {
            if (self.sites.getPtr(kv.value.site)) |s| s.live_bytes -|= kv.value.len;
            break :blk kv.value.site;
        } else ret_addr;
        if (self.sites.getPtr(site)) |s| s.live_bytes += new_len;
        self.live.put(self.track, @intFromPtr(np), .{ .site = site, .len = new_len }) catch {};
        return np;
    }
    /// Vtable `free` shim: records the free via [`Profiler.onFree`] BEFORE
    /// handing the memory back to the backing allocator.
    ///
    /// Order matters only for clarity; both operations use the same pointer.
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Profiler = @ptrCast(@alignCast(ctx));
        self.onFree(@intFromPtr(memory.ptr));
        self.backing.rawFree(memory, alignment, ret_addr);
    }

    /// One flattened, sortable row of the [`Profiler.dump`] report: a site's
    /// address plus the three numbers printed for it. Materialised from
    /// [`Profiler.sites`] so the entries can be sorted without disturbing the
    /// live map.
    const Entry = struct { addr: usize, live_count: usize, live_bytes: usize, total: usize };

    /// Prints the profiling report to stderr: the run totals followed by the top
    /// 30 sites ranked by descending live bytes.
    ///
    /// Copies every site into an [`Profiler.Entry`] list allocated from `track`
    /// (freed on return), sorts by `live_bytes`, and prints. The `ANCHOR` line
    /// reports the runtime address of `dump` itself: subtract it from a printed
    /// site address to get that site's static offset within the binary, which is
    /// how a raw address is turned back into a symbol out-of-band. Append/sort
    /// failures are swallowed, consistent with the module's best-effort rule.
    pub fn dump(self: *Profiler) void {
        var list = std.ArrayListUnmanaged(Entry).empty;
        defer list.deinit(self.track);
        var it = self.sites.iterator();
        while (it.next()) |e| list.append(self.track, .{ .addr = e.key_ptr.*, .live_count = e.value_ptr.live_count, .live_bytes = e.value_ptr.live_bytes, .total = e.value_ptr.count }) catch {};
        std.mem.sort(Entry, list.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                return a.live_bytes > b.live_bytes;
            }
        }.lt);
        const anchor = @intFromPtr(&dump);
        std.debug.print("\n=== NOVA_ALLOC_PROFILE ===\n  total allocs={d}  total frees={d}  net-live={d}\n  ANCHOR allocprof.Profiler.dump runtime=0x{x}\n  TOP 30 SITES BY LIVE BYTES (addr  live_count  live_MB  total_allocs):\n", .{ self.total_alloc, self.total_free, self.total_alloc -| self.total_free, anchor });
        const n = @min(list.items.len, 30);
        for (list.items[0..n]) |e| {
            std.debug.print("  0x{x}  {d:>12}  {d:>8.1}  {d:>12}\n", .{ e.addr, e.live_count, @as(f64, @floatFromInt(e.live_bytes)) / (1024.0 * 1024.0), e.total });
        }
        std.debug.print("=== end ===\n", .{});
    }
};
