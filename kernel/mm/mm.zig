//! Magicore memory manager — top-level init and public interface.

const std     = @import("std");
const buddy   = @import("buddy.zig");
const pgtable = @import("pgtable.zig");
const console = @import("../../lib/console.zig");

pub const PAGE_SIZE = buddy.PAGE_SIZE;
pub const PhysAddr  = buddy.PhysAddr;

pub const MemMapEntry = struct {
    base: u64,
    len:  u64,
    kind: Kind,
    pub const Kind = enum { free, reserved, acpi, bad };
};

pub const PageFlags = packed struct {
    present:       bool = true,
    writable:      bool = false,
    user:          bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
    executable:    bool = false,
    _pad: u10 = 0,
};

// ----------------------------------------------------------------
// Global state
// ----------------------------------------------------------------

pub var buddy_alloc: buddy.BuddyAllocator = undefined;
var   buddy_ready: bool = false;

var kernel_alloc_state: KernelAllocator = undefined;
pub var kernel_allocator: std.mem.Allocator = undefined;

// ----------------------------------------------------------------
// KernelAllocator — std.mem.Allocator over buddy
// ----------------------------------------------------------------

const KernelAllocator = struct {
    fn allocFn(
        _ctx: *anyopaque,
        len: usize,
        _ptr_align: std.mem.Alignment,
        _ret_addr: usize,
    ) ?[*]u8 {
        if (!buddy_ready) return null;
        const pages = std.mem.alignForward(usize, len, PAGE_SIZE) / PAGE_SIZE;
        var order: usize = 0;
        while ((@as(usize, 1) << @intCast(order)) < pages) : (order += 1) {
            if (order >= buddy.MAX_ORDER - 1) return null;
        }
        const phys = buddy_alloc.alloc(order) catch return null;
        const virt = phys + buddy_alloc.hhdm_offset;
        return @ptrFromInt(virt);
    }

    fn resizeFn(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn freeFn(_: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
        if (!buddy_ready) return;
        const pages = std.mem.alignForward(usize, buf.len, PAGE_SIZE) / PAGE_SIZE;
        var order: usize = 0;
        while ((@as(usize, 1) << @intCast(order)) < pages) : (order += 1) {}
        const phys = @intFromPtr(buf.ptr) - buddy_alloc.hhdm_offset;
        buddy_alloc.free(phys, order);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc  = allocFn,
        .resize = resizeFn,
        .free   = freeFn,
        .remap  = std.mem.Allocator.noRemap,
    };
};

// ----------------------------------------------------------------
// mm.init
// ----------------------------------------------------------------

pub fn init(mem_map: []const MemMapEntry, hhdm_offset: u64) error{NoMemory}!void {
    console.print("[mm] initializing physical memory manager\n", .{});
    buddy_alloc = buddy.BuddyAllocator.init(hhdm_offset);

    var free_regions: usize = 0;
    for (mem_map) |entry| {
        if (entry.kind != .free) continue;
        if (entry.len < PAGE_SIZE) continue;
        buddy_alloc.addRegion(entry.base, entry.len);
        free_regions += 1;
        console.print("[mm]   region 0x{X:0>12}–0x{X:0>12} ({} pages)\n", .{
            entry.base, entry.base + entry.len, entry.len / PAGE_SIZE,
        });
    }

    if (buddy_alloc.total_pages == 0) return error.NoMemory;
    console.print("[mm] total: {} pages ({} MiB), {} free regions\n", .{
        buddy_alloc.total_pages,
        (buddy_alloc.total_pages * PAGE_SIZE) / (1024 * 1024),
        free_regions,
    });

    buddy_ready = true;
    kernel_alloc_state = .{};
    kernel_allocator = std.mem.Allocator{
        .ptr    = &kernel_alloc_state,
        .vtable = &KernelAllocator.vtable,
    };
    console.print("[mm] kernel_allocator ready\n", .{});

    // Smoke-test
    const p = try buddy_alloc.alloc(0);
    buddy_alloc.free(p, 0);
    console.print("[mm] buddy smoke test OK\n", .{});
}

// ----------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------

pub fn allocPage() PhysAddr {
    return buddy_alloc.alloc(0) catch @panic("mm: out of physical memory");
}

pub fn freePage(phys: PhysAddr) void {
    buddy_alloc.free(phys, 0);
}

pub fn physToVirt(phys: PhysAddr) u64 {
    return phys + buddy_alloc.hhdm_offset;
}

pub fn virtToPhys(virt: u64) PhysAddr {
    return virt - buddy_alloc.hhdm_offset;
}

test "PageFlags default" {
    const f = PageFlags{};
    try std.testing.expect(f.present);
    try std.testing.expect(!f.writable);
}

test "MemMapEntry kinds" {
    const e = MemMapEntry{ .base=0x1000, .len=0x1000, .kind=.free };
    try std.testing.expectEqual(e.kind, .free);
}
