//! Magicore buddy allocator — physical frame management.
//! O(log N) alloc/free. Zero external fragmentation at page granularity.
//! Order-0 = 1 page (4KB), Order-11 = 2048 pages (8MB max contiguous block).
//!
//! Design:
//!   Each order has an intrusive free list of FreeNode headers.
//!   FreeNode is written directly into the free page — zero external metadata.
//!   Buddy coalescing: buddy address = addr XOR (1 << order) * PAGE_SIZE.
//!   If buddy is in the free list at the same order, remove and merge up.
//!
//!   Linux uses per-zone spinlocks. Magicore is single-threaded in early boot;
//!   SMP locking is added later at the per-CPU layer, not here.

const std = @import("std");

pub const PAGE_SIZE: usize = 4096;
pub const MAX_ORDER: usize = 12; // orders 0..11; max block = 2^11 * 4KB = 8MB

pub const PhysAddr = u64;

/// Intrusive free list node — lives inside the free page itself.
/// No external heap needed for allocator metadata.
const FreeNode = struct {
    next: ?*FreeNode,
};

/// Buddy allocator state
pub const BuddyAllocator = struct {
    /// Head of free list per order
    free_lists: [MAX_ORDER]?*FreeNode,
    total_pages: usize,
    free_pages:  usize,
    /// Higher-half direct map offset (HHDM) — needed to convert phys→virt
    /// for writing FreeNode headers into free pages.
    hhdm_offset: u64,

    pub fn init(hhdm_offset: u64) BuddyAllocator {
        return .{
            .free_lists  = [_]?*FreeNode{null} ** MAX_ORDER,
            .total_pages = 0,
            .free_pages  = 0,
            .hhdm_offset = hhdm_offset,
        };
    }

    // ----------------------------------------------------------------
    // Internal helpers
    // ----------------------------------------------------------------

    /// Physical address → virtual address via HHDM
    inline fn phys2virt(self: *const BuddyAllocator, phys: PhysAddr) u64 {
        return phys + self.hhdm_offset;
    }

    /// Push a physical address onto free_lists[order]
    fn pushFree(self: *BuddyAllocator, phys: PhysAddr, order: usize) void {
        const virt = self.phys2virt(phys);
        const node: *FreeNode = @ptrFromInt(virt);
        node.next = self.free_lists[order];
        self.free_lists[order] = node;
    }

    /// Pop a physical address from free_lists[order], or null if empty
    fn popFree(self: *BuddyAllocator, order: usize) ?PhysAddr {
        const node = self.free_lists[order] orelse return null;
        self.free_lists[order] = node.next;
        // Physical address = virtual - hhdm_offset
        return @intFromPtr(node) - self.hhdm_offset;
    }

    /// Remove a specific physical address from free_lists[order].
    /// Returns true if found and removed.
    fn removeFree(self: *BuddyAllocator, phys: PhysAddr, order: usize) bool {
        const target_virt = self.phys2virt(phys);
        var prev: ?*?*FreeNode = &self.free_lists[order];
        var curr = self.free_lists[order];
        while (curr) |node| {
            if (@intFromPtr(node) == target_virt) {
                prev.?.* = node.next;
                return true;
            }
            prev = &node.next;
            curr = node.next;
        }
        return false;
    }

    /// Compute buddy address for a block at `addr` of `order`
    inline fn buddyAddr(addr: PhysAddr, order: usize) PhysAddr {
        return addr ^ (@as(u64, 1) << @intCast(order)) * PAGE_SIZE;
    }

    // ----------------------------------------------------------------
    // Public API
    // ----------------------------------------------------------------

    /// Add a free memory region at boot time.
    /// Region must be page-aligned. Excess bytes below PAGE_SIZE are ignored.
    pub fn addRegion(self: *BuddyAllocator, base: PhysAddr, length: u64) void {
        var addr = std.mem.alignForward(u64, base, PAGE_SIZE);
        var remaining = length / PAGE_SIZE; // whole pages only

        self.total_pages += remaining;
        self.free_pages  += remaining;

        // Greedily insert largest possible order blocks
        // This minimises fragmentation from the very start.
        while (remaining > 0) {
            // Find the largest order whose block fits and is naturally aligned
            var order: usize = MAX_ORDER - 1;
            while (order > 0) : (order -= 1) {
                const block_pages = @as(usize, 1) << @intCast(order);
                // Must fit in remaining pages AND be naturally aligned
                const aligned = (addr % (@as(u64, block_pages) * PAGE_SIZE)) == 0;
                if (block_pages <= remaining and aligned) break;
            }
            self.pushFree(addr, order);
            const block_pages = @as(usize, 1) << @intCast(order);
            addr      += @as(u64, block_pages) * PAGE_SIZE;
            remaining -= block_pages;
        }
    }

    /// Allocate 2^order contiguous pages. Returns physical address.
    pub fn alloc(self: *BuddyAllocator, order: usize) error{OutOfMemory}!PhysAddr {
        if (order >= MAX_ORDER) return error.OutOfMemory;

        // Find smallest available order >= requested
        var found_order: usize = order;
        while (found_order < MAX_ORDER) : (found_order += 1) {
            if (self.free_lists[found_order] != null) break;
        }
        if (found_order >= MAX_ORDER) return error.OutOfMemory;

        const addr = self.popFree(found_order).?;

        // Split down to the requested order, pushing buddies onto free lists
        var split = found_order;
        while (split > order) {
            split -= 1;
            const buddy = addr + @as(u64, @as(usize, 1) << @intCast(split)) * PAGE_SIZE;
            self.pushFree(buddy, split);
        }

        self.free_pages -= (@as(usize, 1) << @intCast(order));
        return addr;
    }

    /// Free 2^order pages at physical address addr.
    /// Coalesces with buddy if the buddy is also free.
    pub fn free(self: *BuddyAllocator, addr: PhysAddr, order: usize) void {
        var current_addr  = addr;
        var current_order = order;

        self.free_pages += (@as(usize, 1) << @intCast(order));

        // Coalesce upward while buddy is free
        while (current_order < MAX_ORDER - 1) {
            const buddy = buddyAddr(current_addr, current_order);
            if (!self.removeFree(buddy, current_order)) break;
            // Merge: lower address becomes the merged block
            if (buddy < current_addr) current_addr = buddy;
            current_order += 1;
        }

        self.pushFree(current_addr, current_order);
    }

    pub fn freePages(self: *const BuddyAllocator) usize { return self.free_pages; }
    pub fn totalPages(self: *const BuddyAllocator) usize { return self.total_pages; }

    pub fn utilization(self: *const BuddyAllocator) f64 {
        if (self.total_pages == 0) return 0.0;
        const used: f64 = @floatFromInt(self.total_pages - self.free_pages);
        const total: f64 = @floatFromInt(self.total_pages);
        return used / total;
    }
};

// ----------------------------------------------------------------
// Tests — run on host with zig build test
// Uses a fake HHDM offset of 0 so phys == virt in test memory.
// ----------------------------------------------------------------

test "addRegion populates free list" {
    // Allocate a backing buffer to act as our "physical memory"
    const backing = try std.testing.allocator.alloc(u8, 16 * PAGE_SIZE);
    defer std.testing.allocator.free(backing);
    const base: PhysAddr = @intFromPtr(backing.ptr);

    // HHDM offset = 0 → phys == virt (test only)
    var b = BuddyAllocator.init(0);
    b.addRegion(base, 16 * PAGE_SIZE);
    try std.testing.expectEqual(b.total_pages, 16);
    try std.testing.expectEqual(b.free_pages, 16);
}

test "alloc order-0" {
    const backing = try std.testing.allocator.alloc(u8, 8 * PAGE_SIZE);
    defer std.testing.allocator.free(backing);
    const base: PhysAddr = @intFromPtr(backing.ptr);

    var b = BuddyAllocator.init(0);
    b.addRegion(base, 8 * PAGE_SIZE);

    const p = try b.alloc(0);
    try std.testing.expect(p >= base);
    try std.testing.expectEqual(b.free_pages, 7);
}

test "alloc and free coalesces" {
    const backing = try std.testing.allocator.alloc(u8, 4 * PAGE_SIZE);
    defer std.testing.allocator.free(backing);
    const base: PhysAddr = @intFromPtr(backing.ptr);

    var b = BuddyAllocator.init(0);
    b.addRegion(base, 4 * PAGE_SIZE);
    const before_free = b.free_pages;

    const p = try b.alloc(0);
    try std.testing.expectEqual(b.free_pages, before_free - 1);
    b.free(p, 0);
    try std.testing.expectEqual(b.free_pages, before_free);
}

test "alloc order-2 (4 pages)" {
    const backing = try std.testing.allocator.alloc(u8, 8 * PAGE_SIZE);
    defer std.testing.allocator.free(backing);
    const base: PhysAddr = @intFromPtr(backing.ptr);

    var b = BuddyAllocator.init(0);
    b.addRegion(base, 8 * PAGE_SIZE);

    const p = try b.alloc(2); // 4 pages
    try std.testing.expect(p >= base);
    try std.testing.expectEqual(b.free_pages, 4); // 8 - 4 = 4 remaining
}

test "OutOfMemory when exhausted" {
    const backing = try std.testing.allocator.alloc(u8, PAGE_SIZE);
    defer std.testing.allocator.free(backing);
    const base: PhysAddr = @intFromPtr(backing.ptr);

    var b = BuddyAllocator.init(0);
    b.addRegion(base, PAGE_SIZE); // 1 page only
    _ = try b.alloc(0);
    try std.testing.expectError(error.OutOfMemory, b.alloc(0));
}

test "utilization" {
    const backing = try std.testing.allocator.alloc(u8, 4 * PAGE_SIZE);
    defer std.testing.allocator.free(backing);
    const base: PhysAddr = @intFromPtr(backing.ptr);

    var b = BuddyAllocator.init(0);
    b.addRegion(base, 4 * PAGE_SIZE);
    _ = try b.alloc(1); // 2 pages
    const u = b.utilization();
    try std.testing.expectApproxEqAbs(u, 0.5, 0.01);
}
