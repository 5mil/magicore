//! Magicore buddy allocator — physical frame management.
//! O(log N) alloc/free. Zero external fragmentation at page granularity.
//! Order-0 = 1 page (4KB), Order-11 = 2048 pages (8MB)
//! Each order has a free list of blocks.
//! Linux buddy allocator has per-zone spinlocks;
//! Magicore uses per-order atomic free lists for reduced contention.

const std = @import("std");

pub const PAGE_SIZE: usize = 4096;
pub const MAX_ORDER: usize = 12; // 2^11 pages = 8MB max contiguous block

/// A physical address (page-aligned)
pub const PhysAddr = u64;

/// Free block in the buddy system
pub const Block = struct {
    addr: PhysAddr,
    order: u5,
};

/// Buddy allocator state
pub const BuddyAllocator = struct {
    /// Free lists per order
    free_lists: [MAX_ORDER]std.SinglyLinkedList(PhysAddr),
    total_pages: usize,
    free_pages: usize,

    pub fn init() BuddyAllocator {
        return .{
            .free_lists = [_]std.SinglyLinkedList(PhysAddr){
                std.SinglyLinkedList(PhysAddr){},
            } ** MAX_ORDER,
            .total_pages = 0,
            .free_pages = 0,
        };
    }

    /// Add a free region to the allocator at boot
    pub fn addRegion(self: *BuddyAllocator, base: PhysAddr, pages: usize) void {
        self.total_pages += pages;
        self.free_pages += pages;
        // TODO: align base to largest possible order block, insert into free lists
        _ = base;
    }

    /// Allocate 2^order contiguous pages
    pub fn alloc(self: *BuddyAllocator, order: u5) error{OutOfMemory}!PhysAddr {
        if (order >= MAX_ORDER) return error.OutOfMemory;
        // Find smallest available order >= requested
        var current_order = order;
        while (current_order < MAX_ORDER) : (current_order += 1) {
            if (self.free_lists[current_order].first != null) {
                const node = self.free_lists[current_order].popFirst().?;
                const addr = node.data;
                // Split down to requested order
                var split = current_order;
                while (split > order) {
                    split -= 1;
                    const buddy_addr = addr + (@as(u64, 1) << @intCast(split)) * PAGE_SIZE;
                    // TODO: push buddy_addr onto free_lists[split]
                    _ = buddy_addr;
                }
                self.free_pages -= (@as(usize, 1) << order);
                return addr;
            }
        }
        return error.OutOfMemory;
    }

    /// Free 2^order pages at addr
    pub fn free(self: *BuddyAllocator, addr: PhysAddr, order: u5) void {
        // Coalesce with buddy if free
        var current_addr = addr;
        var current_order = order;
        while (current_order < MAX_ORDER - 1) : (current_order += 1) {
            const buddy_addr = current_addr ^ ((@as(u64, 1) << @intCast(current_order)) * PAGE_SIZE);
            // TODO: check if buddy is in free_lists[current_order], if so coalesce
            _ = buddy_addr;
            break; // placeholder until list walk implemented
        }
        // TODO: insert current_addr at current_order into free list
        self.free_pages += (@as(usize, 1) << order);
        _ = current_addr;
    }

    pub fn utilization(self: *const BuddyAllocator) f64 {
        if (self.total_pages == 0) return 0.0;
        const used = self.total_pages - self.free_pages;
        return @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(self.total_pages));
    }
};

test "BuddyAllocator init" {
    var b = BuddyAllocator.init();
    try std.testing.expectEqual(b.total_pages, 0);
    try std.testing.expectEqual(b.free_pages, 0);
}

test "BuddyAllocator utilization zero" {
    var b = BuddyAllocator.init();
    try std.testing.expectApproxEqAbs(b.utilization(), 0.0, 0.001);
}
