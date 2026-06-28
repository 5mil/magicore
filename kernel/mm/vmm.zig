//! Magicore virtual memory manager.
//! Per-process address spaces with explicit ownership.
//! Kernel and user mappings are tracked in typed region sets.
//! No implicit COW — copy-on-write is an explicit policy.
//! VMA descriptors are compactly stored, not linked lists like Linux.

const std = @import("std");
const buddy = @import("buddy.zig");

pub const PAGE_SIZE = buddy.PAGE_SIZE;
pub const PhysAddr = buddy.PhysAddr;
pub const VirtAddr = u64;

/// Virtual memory region kinds
pub const RegionKind = enum {
    code,       // r-x
    rodata,     // r--
    data,       // rw-
    stack,      // rw- grows down
    heap,       // rw- grows up
    mmap,       // user-mapped file or anonymous
    kernel,     // kernel-only
    inference,  // pinned for AI inference, never swapped
};

/// Page protection flags
pub const Prot = packed struct {
    read: bool    = false,
    write: bool   = false,
    exec: bool    = false,
    user: bool    = false,
    pinned: bool  = false,  // never swap (inference regions)
    _pad: u3      = 0,
};

/// A virtual memory region descriptor
pub const Region = struct {
    base: VirtAddr,
    len: usize,
    prot: Prot,
    kind: RegionKind,
    /// Physical backing (null = not yet faulted in)
    phys: ?PhysAddr,
};

/// A process address space
pub const AddressSpace = struct {
    regions: std.ArrayList(Region),
    page_table_root: PhysAddr,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, pt_root: PhysAddr) AddressSpace {
        return .{
            .regions = std.ArrayList(Region).init(allocator),
            .page_table_root = pt_root,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AddressSpace) void {
        self.regions.deinit();
    }

    /// Map a new region into this address space
    pub fn map(self: *AddressSpace, region: Region) error{OutOfMemory, Overlap}!void {
        // Check for overlap with existing regions
        for (self.regions.items) |r| {
            if (region.base < r.base + r.len and region.base + region.len > r.base) {
                return error.Overlap;
            }
        }
        try self.regions.append(region);
    }

    /// Find the region containing a virtual address
    pub fn find(self: *const AddressSpace, vaddr: VirtAddr) ?*const Region {
        for (self.regions.items) |*r| {
            if (vaddr >= r.base and vaddr < r.base + r.len) return r;
        }
        return null;
    }

    /// Handle page fault: allocate physical frame and map it
    pub fn handleFault(
        self: *AddressSpace,
        vaddr: VirtAddr,
        phys_alloc: *buddy.BuddyAllocator,
    ) error{SegFault, OutOfMemory}!void {
        const region = self.find(vaddr) orelse return error.SegFault;
        if (!region.prot.write and !region.prot.read) return error.SegFault;
        // Allocate physical frame
        const frame = try phys_alloc.alloc(0); // order-0 = 1 page
        _ = frame;
        // TODO: insert into page table at vaddr
        _ = region;
    }
};

test "AddressSpace map no overlap" {
    var as = AddressSpace.init(std.testing.allocator, 0);
    defer as.deinit();
    try as.map(.{
        .base = 0x1000,
        .len = 0x1000,
        .prot = .{ .read = true },
        .kind = .code,
        .phys = null,
    });
    try std.testing.expectEqual(as.regions.items.len, 1);
}

test "AddressSpace overlap detection" {
    var as = AddressSpace.init(std.testing.allocator, 0);
    defer as.deinit();
    try as.map(.{ .base = 0x1000, .len = 0x2000, .prot = .{}, .kind = .data, .phys = null });
    try std.testing.expectError(error.Overlap, as.map(.{
        .base = 0x2000, .len = 0x1000, .prot = .{}, .kind = .data, .phys = null,
    }));
}

test "AddressSpace find" {
    var as = AddressSpace.init(std.testing.allocator, 0);
    defer as.deinit();
    try as.map(.{ .base = 0x4000, .len = 0x1000, .prot = .{ .read = true }, .kind = .rodata, .phys = null });
    try std.testing.expect(as.find(0x4500) != null);
    try std.testing.expect(as.find(0x3FFF) == null);
}
