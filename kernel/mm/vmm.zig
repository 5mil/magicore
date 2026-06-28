//! Magicore virtual memory manager.
//! Per-process address spaces with explicit ownership.
//! Drives the hardware page table engine (pgtable.zig).
//! Handles demand-paging via page fault dispatch.
//!
//! No implicit COW — copy-on-write is an explicit policy, not a default.
//! VMA list is a sorted ArrayList; lookup is linear now, interval tree later.

const std    = @import("std");
const buddy  = @import("buddy.zig");
const mm     = @import("mm.zig");
const pt     = @import("pgtable.zig");
const console = @import("../../lib/console.zig");

pub const PAGE_SIZE = buddy.PAGE_SIZE;
pub const PhysAddr  = buddy.PhysAddr;
pub const VirtAddr  = u64;

// ----------------------------------------------------------------
// Region descriptor
// ----------------------------------------------------------------

pub const RegionKind = enum {
    code,      // r-x
    rodata,    // r--
    data,      // rw-
    stack,     // rw- grows down
    heap,      // rw- grows up
    mmap,      // user mapped file or anonymous
    kernel,    // kernel only
    inference, // pinned for AI; never swapped
};

pub const Prot = packed struct {
    read:   bool = false,
    write:  bool = false,
    exec:   bool = false,
    user:   bool = false,
    pinned: bool = false, // inference regions: never evict
    _pad:   u3   = 0,
};

pub const Region = struct {
    base: VirtAddr,
    len:  usize,
    prot: Prot,
    kind: RegionKind,
};

// ----------------------------------------------------------------
// AddressSpace
// ----------------------------------------------------------------

pub const AddressSpace = struct {
    /// Sorted list of virtual memory regions
    regions: std.ArrayListUnmanaged(Region),
    /// Physical address of PML4 (CR3 value for this AS)
    pml4:    PhysAddr,
    /// HHDM offset (copied from mm for convenience)
    hhdm:    u64,
    allocator: std.mem.Allocator,

    /// Create a new address space with a fresh PML4.
    pub fn init(allocator: std.mem.Allocator, hhdm: u64) error{OutOfMemory}!AddressSpace {
        const pml4 = try mm.buddy_alloc.alloc(0);
        // Zero the PML4
        const virt: u64 = pml4 + hhdm;
        const ptr: [*]u8 = @ptrFromInt(virt);
        @memset(ptr[0..PAGE_SIZE], 0);
        return .{
            .regions   = .{},
            .pml4      = pml4,
            .hhdm      = hhdm,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AddressSpace) void {
        self.regions.deinit(self.allocator);
        // TODO: walk and free all page table pages
    }

    // ----------------------------------------------------------------
    // Region management
    // ----------------------------------------------------------------

    /// Add a virtual memory region (does NOT allocate physical pages).
    /// Physical pages are allocated lazily on first fault (demand paging).
    pub fn mapRegion(self: *AddressSpace, region: Region) error{OutOfMemory, Overlap}!void {
        // Overlap check
        for (self.regions.items) |r| {
            if (region.base < r.base + r.len and region.base + region.len > r.base) {
                return error.Overlap;
            }
        }
        // Keep sorted by base address for fast lookup
        var insert_at: usize = self.regions.items.len;
        for (self.regions.items, 0..) |r, i| {
            if (region.base < r.base) { insert_at = i; break; }
        }
        try self.regions.insert(self.allocator, insert_at, region);
    }

    /// Remove a region by base address (does NOT unmap hardware PT entries).
    pub fn unmapRegion(self: *AddressSpace, base: VirtAddr) bool {
        for (self.regions.items, 0..) |r, i| {
            if (r.base == base) {
                _ = self.regions.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Find the region containing vaddr, or null.
    pub fn find(self: *const AddressSpace, vaddr: VirtAddr) ?Region {
        for (self.regions.items) |r| {
            if (vaddr >= r.base and vaddr < r.base + r.len) return r;
        }
        return null;
    }

    // ----------------------------------------------------------------
    // Demand paging: map a single page immediately (eager)
    // ----------------------------------------------------------------

    /// Eagerly map `vaddr` in this address space.
    /// Allocates a physical frame and inserts the PT entry.
    pub fn mapPage(
        self: *AddressSpace,
        vaddr: VirtAddr,
        prot: Prot,
    ) error{OutOfMemory, AlreadyMapped}!PhysAddr {
        const phys = try mm.buddy_alloc.alloc(0);
        pt.mapPage(self.pml4, vaddr, phys, .{
            .present  = true,
            .writable = prot.write,
            .user     = prot.user,
        }, self.hhdm) catch |err| {
            mm.buddy_alloc.free(phys, 0); // roll back on failure
            return err;
        };
        return phys;
    }

    /// Unmap a single page and free its physical frame.
    pub fn unmapPage(self: *AddressSpace, vaddr: VirtAddr) bool {
        const phys = pt.unmapPage(self.pml4, vaddr, self.hhdm) orelse return false;
        mm.buddy_alloc.free(phys, 0);
        return true;
    }

    /// Translate vaddr → phys in this address space
    pub fn translate(self: *const AddressSpace, vaddr: VirtAddr) ?PhysAddr {
        return pt.translate(self.pml4, vaddr, self.hhdm);
    }

    // ----------------------------------------------------------------
    // Page fault handler (called from IDT #PF handler)
    // ----------------------------------------------------------------

    /// Handle a page fault at `fault_vaddr`.
    /// - If the address is in a mapped region: allocate frame + map PT entry.
    /// - Otherwise: return SegFault → caller sends SIGSEGV / kills process.
    pub fn handleFault(
        self: *AddressSpace,
        fault_vaddr: VirtAddr,
        write_fault: bool,
    ) error{SegFault, OutOfMemory}!void {
        const region = self.find(fault_vaddr) orelse {
            console.print("[vmm] segfault vaddr=0x{X:0>16}\n", .{fault_vaddr});
            return error.SegFault;
        };

        // Permission check: write fault on read-only mapping
        if (write_fault and !region.prot.write) {
            console.print("[vmm] write fault on read-only region 0x{X:0>16}\n", .{fault_vaddr});
            return error.SegFault;
        }

        // Allocate physical frame
        const phys = try mm.buddy_alloc.alloc(0);
        // Zero the frame
        const frame_virt: u64 = phys + self.hhdm;
        const frame_ptr: [*]u8 = @ptrFromInt(frame_virt);
        @memset(frame_ptr[0..PAGE_SIZE], 0);

        // Align fault address down to page boundary
        const page_vaddr = fault_vaddr & ~@as(u64, PAGE_SIZE - 1);

        pt.mapPage(self.pml4, page_vaddr, phys, .{
            .present  = true,
            .writable = region.prot.write,
            .user     = region.prot.user,
        }, self.hhdm) catch |err| switch (err) {
            // Another CPU raced and mapped this page: that's fine
            error.AlreadyMapped => mm.buddy_alloc.free(phys, 0),
            else => {
                mm.buddy_alloc.free(phys, 0);
                return error.OutOfMemory;
            },
        };
    }

    /// Switch to this address space (load CR3)
    pub fn activate(self: *const AddressSpace) void {
        pt.loadCr3(self.pml4);
    }
};

// ----------------------------------------------------------------
// Tests (host, no hardware)
// ----------------------------------------------------------------

test "AddressSpace region map and find" {
    var as = AddressSpace{
        .regions   = .{},
        .pml4      = 0,
        .hhdm      = 0,
        .allocator = std.testing.allocator,
    };
    defer as.deinit();

    try as.mapRegion(.{ .base=0x1000, .len=0x1000, .prot=.{.read=true}, .kind=.code });
    const r = as.find(0x1500);
    try std.testing.expect(r != null);
    try std.testing.expectEqual(r.?.base, 0x1000);
}

test "AddressSpace overlap rejection" {
    var as = AddressSpace{
        .regions   = .{},
        .pml4      = 0,
        .hhdm      = 0,
        .allocator = std.testing.allocator,
    };
    defer as.deinit();

    try as.mapRegion(.{ .base=0x1000, .len=0x3000, .prot=.{}, .kind=.data });
    try std.testing.expectError(error.Overlap,
        as.mapRegion(.{ .base=0x2000, .len=0x1000, .prot=.{}, .kind=.data }));
}

test "AddressSpace sorted insert" {
    var as = AddressSpace{
        .regions   = .{},
        .pml4      = 0,
        .hhdm      = 0,
        .allocator = std.testing.allocator,
    };
    defer as.deinit();

    try as.mapRegion(.{ .base=0x3000, .len=0x1000, .prot=.{}, .kind=.data });
    try as.mapRegion(.{ .base=0x1000, .len=0x1000, .prot=.{}, .kind=.code });
    // After sorted insert, regions[0] must be the lower one
    try std.testing.expectEqual(as.regions.items[0].base, 0x1000);
    try std.testing.expectEqual(as.regions.items[1].base, 0x3000);
}
