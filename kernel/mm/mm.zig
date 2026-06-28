//! Magicore memory manager.
//! Manages physical frame allocation, virtual address spaces,
//! and kernel heap. No hidden allocations — every allocation
//! goes through an explicit Allocator interface.

const std = @import("std");

/// A physical memory frame (4096 bytes)
pub const PAGE_SIZE: usize = 4096;

/// Physical frame descriptor
pub const Frame = struct {
    addr: u64,
};

/// Physical frame allocator interface (vtable-driven)
pub const FrameAllocator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        alloc: *const fn (ptr: *anyopaque) error{OutOfMemory}!Frame,
        free: *const fn (ptr: *anyopaque, frame: Frame) void,
    };

    pub fn alloc(self: FrameAllocator) error{OutOfMemory}!Frame {
        return self.vtable.alloc(self.ptr);
    }

    pub fn free(self: FrameAllocator, frame: Frame) void {
        self.vtable.free(self.ptr, frame);
    }
};

/// Kernel virtual address space
pub const VAS = struct {
    /// Map a physical frame into virtual address space
    pub fn map(
        self: *VAS,
        virt: u64,
        frame: Frame,
        flags: PageFlags,
    ) error{AlreadyMapped, OutOfMemory}!void {
        _ = self;
        _ = virt;
        _ = frame;
        _ = flags;
        // TODO: walk/modify page table entries
    }

    /// Unmap a virtual address
    pub fn unmap(self: *VAS, virt: u64) error{NotMapped}!void {
        _ = self;
        _ = virt;
        // TODO: walk page tables, free frame if owned
    }
};

/// Page mapping flags
pub const PageFlags = packed struct {
    present: bool = true,
    writable: bool = false,
    user: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
    executable: bool = false,
    _pad: u10 = 0,
};

/// Boot-time memory map entry
pub const MemMapEntry = struct {
    base: u64,
    len: u64,
    kind: Kind,

    pub const Kind = enum { free, reserved, acpi, bad };
};

var frame_allocator: ?FrameAllocator = null;

/// Initialize memory manager from boot memory map
pub fn init(mem_map: []const MemMapEntry) error{NoMemory}!void {
    _ = mem_map;
    // TODO: build bitmap/buddy allocator over free regions
    // TODO: initialize kernel heap
    // TODO: set up kernel VAS
}

test "PageFlags default" {
    const f = PageFlags{};
    try std.testing.expect(f.present);
    try std.testing.expect(!f.writable);
}
