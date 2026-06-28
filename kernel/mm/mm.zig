//! Magicore memory manager — top-level init and public interface.
//! Owns the global BuddyAllocator and SlabHeap.
//! Exposes a std.mem.Allocator for use throughout the kernel.
//!
//! Boot sequence:
//!   mm.init(mem_map, hhdm_offset)
//!     → buddy.addRegion() for each free memory map entry
//!     → slab heap bootstrapped on top of buddy
//!     → kernel_allocator available

const std    = @import("std");
const buddy  = @import("buddy.zig");
const slab   = @import("slab.zig");
const console = @import("../../lib/console.zig");

pub const PAGE_SIZE = buddy.PAGE_SIZE;
pub const PhysAddr  = buddy.PhysAddr;

/// Re-export for use by arch/boot
pub const MemMapEntry = struct {
    base: u64,
    len:  u64,
    kind: Kind,
    pub const Kind = enum { free, reserved, acpi, bad };
};

/// Page mapping flags
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
// Global state — initialized once in mm.init(), never reallocated
// ----------------------------------------------------------------

/// The one physical frame allocator for the entire kernel.
/// Initialized from the Limine memory map at boot.
pub var buddy_alloc: buddy.BuddyAllocator = undefined;
var buddy_ready: bool = false;

/// Kernel heap allocator — backed by buddy, served through KernelAllocator
var kernel_alloc_state: KernelAllocator = undefined;
pub var kernel_allocator: std.mem.Allocator = undefined;

// ----------------------------------------------------------------
// KernelAllocator — std.mem.Allocator backed by buddy (order-0 pages)
// ----------------------------------------------------------------
//
// This is a simple page-granularity allocator: every alloc gets at
// least one full page from buddy. For sub-page allocations the slab
// cache layer (slab.zig) is layered on top.
// This gives the rest of the kernel a normal std.mem.Allocator
// to pass to ArrayList, HashMap, etc.

const KernelAllocator = struct {
    fn allocFn(
        ctx: *anyopaque,
        len: usize,
        ptr_align: std.mem.Alignment,
        _ret_addr: usize,
    ) ?[*]u8 {
        _ = ctx;
        _ = ptr_align; // buddy is always page-aligned ≥ any reasonable align

        if (!buddy_ready) return null;

        // Round up to whole pages
        const pages = std.mem.alignForward(usize, len, PAGE_SIZE) / PAGE_SIZE;
        // Find the smallest order that covers `pages`
        var order: usize = 0;
        while ((@as(usize, 1) << @intCast(order)) < pages) : (order += 1) {
            if (order >= buddy.MAX_ORDER - 1) return null;
        }
        const phys = buddy_alloc.alloc(order) catch return null;
        // Convert to virtual via HHDM
        const virt = phys + buddy_alloc.hhdm_offset;
        return @ptrFromInt(virt);
    }

    fn resizeFn(
        _ctx: *anyopaque,
        _buf: []u8,
        _buf_align: std.mem.Alignment,
        _new_len: usize,
        _ret_addr: usize,
    ) bool {
        return false; // no in-place resize — always reallocate
    }

    fn freeFn(
        _ctx: *anyopaque,
        buf: []u8,
        _buf_align: std.mem.Alignment,
        _ret_addr: usize,
    ) void {
        if (!buddy_ready) return;
        const pages = std.mem.alignForward(usize, buf.len, PAGE_SIZE) / PAGE_SIZE;
        var order: usize = 0;
        while ((@as(usize, 1) << @intCast(order)) < pages) : (order += 1) {}
        const phys = @intFromPtr(buf.ptr) - buddy_alloc.hhdm_offset;
        buddy_alloc.free(phys, order);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc   = allocFn,
        .resize  = resizeFn,
        .free    = freeFn,
        .remap   = std.mem.Allocator.noRemap,
    };
};

// ----------------------------------------------------------------
// mm.init — called from kmain with Limine memory map
// ----------------------------------------------------------------

pub fn init(mem_map: []const MemMapEntry, hhdm_offset: u64) error{NoMemory}!void {
    console.print("[mm] initializing physical memory manager\n", .{});

    buddy_alloc = buddy.BuddyAllocator.init(hhdm_offset);

    // Feed every free region into the buddy allocator
    var free_regions: usize = 0;
    for (mem_map) |entry| {
        if (entry.kind != .free) continue;
        if (entry.len < PAGE_SIZE) continue;
        buddy_alloc.addRegion(entry.base, entry.len);
        free_regions += 1;
        console.print("[mm]   region 0x{X:0>12}–0x{X:0>12} ({} pages)\n", .{
            entry.base,
            entry.base + entry.len,
            entry.len / PAGE_SIZE,
        });
    }

    if (buddy_alloc.total_pages == 0) return error.NoMemory;

    console.print("[mm] total: {} pages ({} MiB), {} free regions\n", .{
        buddy_alloc.total_pages,
        (buddy_alloc.total_pages * PAGE_SIZE) / (1024 * 1024),
        free_regions,
    });

    // Bootstrap std.mem.Allocator
    buddy_ready = true;
    kernel_alloc_state = .{};
    kernel_allocator = std.mem.Allocator{
        .ptr    = &kernel_alloc_state,
        .vtable = &KernelAllocator.vtable,
    };

    console.print("[mm] kernel_allocator ready\n", .{});

    // Smoke-test: alloc and free one page to verify buddy is operational
    const test_page = try buddy_alloc.alloc(0);
    buddy_alloc.free(test_page, 0);
    console.print("[mm] buddy smoke test OK\n", .{});
}

// ----------------------------------------------------------------
// Public helpers
// ----------------------------------------------------------------

/// Allocate one physical page (order-0). Panics if OOM.
pub fn allocPage() PhysAddr {
    return buddy_alloc.alloc(0) catch @panic("mm: out of physical memory");
}

/// Free a single physical page
pub fn freePage(phys: PhysAddr) void {
    buddy_alloc.free(phys, 0);
}

/// Convert physical address to kernel virtual (HHDM)
pub fn physToVirt(phys: PhysAddr) u64 {
    return phys + buddy_alloc.hhdm_offset;
}

/// Convert kernel virtual address to physical
pub fn virtToPhys(virt: u64) PhysAddr {
    return virt - buddy_alloc.hhdm_offset;
}

test "PageFlags default" {
    const f = PageFlags{};
    try std.testing.expect(f.present);
    try std.testing.expect(!f.writable);
}

test "MemMapEntry kinds" {
    const e = MemMapEntry{ .base = 0x1000, .len = 0x1000, .kind = .free };
    try std.testing.expectEqual(e.kind, .free);
}
