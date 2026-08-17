// allocprof.zig — opt-in allocation profiler (NOVA_ALLOC_PROFILE). Wraps a backing allocator and tracks, per
// call site (return address), how many allocations are still LIVE (allocated minus freed) at exit -- i.e. the
// leaked ones. This attributes a compiler memory leak to its exact Zig source line without the pathological
// slowness of macOS malloc_history. Overhead: a per-live-allocation ptr->site map (one entry per live block).
const std = @import("std");

pub const Profiler = struct {
    backing: std.mem.Allocator,
    track: std.mem.Allocator, // allocator for the profiler's own maps (must NOT be the profiled one)
    sites: std.AutoHashMapUnmanaged(usize, Site) = .empty,
    live: std.AutoHashMapUnmanaged(usize, Live) = .empty, // ptr -> {site, len}
    total_alloc: usize = 0,
    total_free: usize = 0,

    const Site = struct { count: usize = 0, bytes: usize = 0, live_count: usize = 0, live_bytes: usize = 0 };
    const Live = struct { site: usize, len: usize };

    const vtable = std.mem.Allocator.VTable{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    pub fn init(backing: std.mem.Allocator, track: std.mem.Allocator) Profiler {
        return .{ .backing = backing, .track = track };
    }
    pub fn allocator(self: *Profiler) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

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
    fn onFree(self: *Profiler, ptr: usize) void {
        self.total_free += 1;
        if (self.live.fetchRemove(ptr)) |kv| {
            if (self.sites.getPtr(kv.value.site)) |s| {
                s.live_count -|= 1;
                s.live_bytes -|= kv.value.len;
            }
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Profiler = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.onAlloc(@intFromPtr(p), ret_addr, len);
        return p;
    }
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
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Profiler = @ptrCast(@alignCast(ctx));
        const np = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        // Preserve the ORIGINAL allocation site across the move.
        const site = if (self.live.fetchRemove(@intFromPtr(memory.ptr))) |kv| blk: {
            if (self.sites.getPtr(kv.value.site)) |s| s.live_bytes -|= kv.value.len;
            break :blk kv.value.site;
        } else ret_addr;
        if (self.sites.getPtr(site)) |s| s.live_bytes += new_len;
        self.live.put(self.track, @intFromPtr(np), .{ .site = site, .len = new_len }) catch {};
        return np;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Profiler = @ptrCast(@alignCast(ctx));
        self.onFree(@intFromPtr(memory.ptr));
        self.backing.rawFree(memory, alignment, ret_addr);
    }

    const Entry = struct { addr: usize, live_count: usize, live_bytes: usize, total: usize };

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
