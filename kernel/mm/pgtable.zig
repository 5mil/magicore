//! Magicore x86_64 4-level page table engine.
//!
//! Layout (IA-32e paging):
//!   PML4  (level 4) → 512 entries, each covers 512 GiB
//!   PDPT  (level 3) → 512 entries, each covers   1 GiB
//!   PD    (level 2) → 512 entries, each covers   2 MiB
//!   PT    (level 1) → 512 entries, each covers   4 KiB
//!
//! All tables are one page (4096 bytes) of 512 x u64 entries.
//! Physical addresses are stored in bits 51:12 of each entry.
//!
//! Magicore uses the Limine HHDM to access physical pages via virtual
//! addresses: virt = phys + hhdm_offset.
//!
//! Differences from Linux:
//!   - No pgd_lock, no rcu, no mmap_lock: all page table ops are
//!     explicit and owned by a single AddressSpace at a time.
//!   - No huge-page complexity in this module (2MB pages planned for Phase 6).
//!   - Typed entry flags — no raw bitmask manipulation at call sites.

const std = @import("std");
const mm  = @import("mm.zig");

pub const PAGE_SIZE:   usize = 4096;
pub const ENTRY_COUNT: usize = 512; // entries per table
pub const PhysAddr = mm.PhysAddr;
pub const VirtAddr = u64;

// ----------------------------------------------------------------
// Page table entry flags (x86_64 long mode)
// ----------------------------------------------------------------

pub const PteFlags = packed struct(u64) {
    present:       bool = false, // bit  0
    writable:      bool = false, // bit  1
    user:          bool = false, // bit  2
    write_through: bool = false, // bit  3
    cache_disable: bool = false, // bit  4
    accessed:      bool = false, // bit  5
    dirty:         bool = false, // bit  6
    huge_page:     bool = false, // bit  7 (PS bit — 2MB pages at PD level)
    global:        bool = false, // bit  8
    _avl:           u3  = 0,     // bits 9–11 (available)
    phys_addr:     u52  = 0,     // bits 12–63 (physical addr >> 12; NX in bit 63)
};

/// Compose a PTE from a physical address and flags.
/// Physical address must be page-aligned.
pub fn makePte(phys: PhysAddr, flags: PteFlags) u64 {
    std.debug.assert(phys % PAGE_SIZE == 0);
    var e = flags;
    e.phys_addr = @intCast(phys >> 12);
    return @bitCast(e);
}

/// Extract physical address from a PTE
pub fn ptePhys(entry: u64) PhysAddr {
    return (entry & 0x000F_FFFF_FFFF_F000);
}

/// True if PTE has the Present bit set
pub fn ptePresent(entry: u64) bool {
    return (entry & 1) != 0;
}

// ----------------------------------------------------------------
// Table type — a single 4096-byte array of 512 u64 entries
// ----------------------------------------------------------------

pub const Table = [ENTRY_COUNT]u64;

/// Return a pointer to a Table living at physical address `phys`.
/// Requires HHDM to be set up.
inline fn tableAt(phys: PhysAddr, hhdm: u64) *Table {
    const virt: u64 = phys + hhdm;
    return @ptrFromInt(virt);
}

/// Allocate a zeroed page-table page via buddy.
/// Returns physical address.
fn allocTable(hhdm: u64) error{OutOfMemory}!PhysAddr {
    const phys = try mm.buddy_alloc.alloc(0); // order-0 = 1 page
    // Zero it (must be clean before use as a page table)
    const virt: u64 = phys + hhdm;
    const ptr: [*]u8 = @ptrFromInt(virt);
    @memset(ptr[0..PAGE_SIZE], 0);
    return phys;
}

// ----------------------------------------------------------------
// Virtualaddress decomposition
// ----------------------------------------------------------------

/// x86_64 virtual address index extraction
const Indices = struct {
    pml4: u9, pdpt: u9, pd: u9, pt: u9, offset: u12,
};

pub fn decompose(vaddr: VirtAddr) Indices {
    return .{
        .pml4   = @intCast((vaddr >> 39) & 0x1FF),
        .pdpt   = @intCast((vaddr >> 30) & 0x1FF),
        .pd     = @intCast((vaddr >> 21) & 0x1FF),
        .pt     = @intCast((vaddr >> 12) & 0x1FF),
        .offset = @intCast(vaddr & 0xFFF),
    };
}

// ----------------------------------------------------------------
// Core mapping operations
// ----------------------------------------------------------------

pub const MapError = error{ OutOfMemory, AlreadyMapped };

/// Map a single 4KiB page: virt → phys with given flags.
/// Walks/allocates PML4→PDPT→PD→PT as needed.
pub fn mapPage(
    pml4_phys: PhysAddr,
    vaddr: VirtAddr,
    paddr: PhysAddr,
    flags: PteFlags,
    hhdm: u64,
) MapError!void {
    const idx = decompose(vaddr);
    const pml4 = tableAt(pml4_phys, hhdm);

    // PML4 → PDPT
    if (!ptePresent(pml4[idx.pml4])) {
        const pdpt_phys = try allocTable(hhdm);
        pml4[idx.pml4] = makePte(pdpt_phys, .{ .present=true, .writable=true, .user=flags.user });
    }
    const pdpt = tableAt(ptePhys(pml4[idx.pml4]), hhdm);

    // PDPT → PD
    if (!ptePresent(pdpt[idx.pdpt])) {
        const pd_phys = try allocTable(hhdm);
        pdpt[idx.pdpt] = makePte(pd_phys, .{ .present=true, .writable=true, .user=flags.user });
    }
    const pd = tableAt(ptePhys(pdpt[idx.pdpt]), hhdm);

    // PD → PT
    if (!ptePresent(pd[idx.pd])) {
        const pt_phys = try allocTable(hhdm);
        pd[idx.pd] = makePte(pt_phys, .{ .present=true, .writable=true, .user=flags.user });
    }
    const pt = tableAt(ptePhys(pd[idx.pd]), hhdm);

    // PT → page
    if (ptePresent(pt[idx.pt])) return error.AlreadyMapped;
    pt[idx.pt] = makePte(paddr, flags);
}

/// Unmap a single page. Returns the physical address that was mapped,
/// or null if the page was not present.
pub fn unmapPage(
    pml4_phys: PhysAddr,
    vaddr: VirtAddr,
    hhdm: u64,
) ?PhysAddr {
    const idx = decompose(vaddr);
    const pml4 = tableAt(pml4_phys, hhdm);
    if (!ptePresent(pml4[idx.pml4])) return null;
    const pdpt = tableAt(ptePhys(pml4[idx.pml4]), hhdm);
    if (!ptePresent(pdpt[idx.pdpt])) return null;
    const pd = tableAt(ptePhys(pdpt[idx.pdpt]), hhdm);
    if (!ptePresent(pd[idx.pd])) return null;
    const pt = tableAt(ptePhys(pd[idx.pd]), hhdm);
    if (!ptePresent(pt[idx.pt])) return null;
    const phys = ptePhys(pt[idx.pt]);
    pt[idx.pt] = 0;
    // Invalidate TLB entry for this address
    asm volatile ("invlpg (%[addr])" : : [addr] "r" (vaddr) : "memory");
    return phys;
}

/// Walk the page tables and return the physical address mapped at vaddr,
/// or null if not present.
pub fn translate(
    pml4_phys: PhysAddr,
    vaddr: VirtAddr,
    hhdm: u64,
) ?PhysAddr {
    const idx = decompose(vaddr);
    const pml4 = tableAt(pml4_phys, hhdm);
    if (!ptePresent(pml4[idx.pml4])) return null;
    const pdpt = tableAt(ptePhys(pml4[idx.pml4]), hhdm);
    if (!ptePresent(pdpt[idx.pdpt])) return null;
    const pd   = tableAt(ptePhys(pdpt[idx.pdpt]), hhdm);
    if (!ptePresent(pd[idx.pd])) return null;
    const pt   = tableAt(ptePhys(pd[idx.pd]), hhdm);
    if (!ptePresent(pt[idx.pt])) return null;
    return ptePhys(pt[idx.pt]) | idx.offset;
}

/// Load a PML4 into CR3, activating the address space.
/// Flushes the entire TLB.
pub fn loadCr3(pml4_phys: PhysAddr) void {
    asm volatile ("mov %[phys], %%cr3"
        :
        : [phys] "r" (pml4_phys)
        : "memory"
    );
}

/// Read the current CR3 (physical address of active PML4)
pub fn readCr3() PhysAddr {
    return asm volatile ("mov %%cr3, %[out]"
        : [out] "=r" (-> u64)
    );
}

// ----------------------------------------------------------------
// Kernel address space bootstrap
// ----------------------------------------------------------------

/// Kernel page table root (PML4 physical address)
pub var kernel_pml4: PhysAddr = 0;

/// Bootstrap the kernel address space.
/// Maps:
///   - kernel text/rodata/data/bss (from linker symbols)
///   - all of physical memory via HHDM (identity-equivalent at offset)
/// Called from mm.init() after buddy is ready.
pub fn initKernelPt(hhdm: u64, total_pages: usize) error{OutOfMemory}!void {
    kernel_pml4 = try allocTable(hhdm);

    // Map kernel higher-half: 0xFFFFFFFF80000000 → phys 0
    // We map the first 64 MiB to cover any reasonable kernel image.
    const KERNEL_VIRT: u64 = 0xFFFFFFFF80000000;
    const MAP_PAGES: usize  = 64 * 1024 * 1024 / PAGE_SIZE; // 16384 pages
    var i: usize = 0;
    while (i < MAP_PAGES) : (i += 1) {
        const virt = KERNEL_VIRT + @as(u64, i) * PAGE_SIZE;
        const phys = @as(u64, i) * PAGE_SIZE;
        try mapPage(kernel_pml4, virt, phys, .{
            .present  = true,
            .writable = true,
            .global   = true,
        }, hhdm);
    }

    // Map HHDM: phys 0 → hhdm + 0, hhdm + 4K, ... up to total RAM
    const hhdm_pages = @min(total_pages, 1024 * 1024); // max 4 GiB
    i = 0;
    while (i < hhdm_pages) : (i += 1) {
        const phys = @as(u64, i) * PAGE_SIZE;
        const virt = hhdm + phys;
        // Skip if already mapped (kernel region overlap)
        mapPage(kernel_pml4, virt, phys, .{
            .present  = true,
            .writable = true,
            .global   = true,
        }, hhdm) catch |err| switch (err) {
            error.AlreadyMapped => {}, // fine — kernel region already covered
            else => return err,
        };
    }
}

// ----------------------------------------------------------------
// Tests
// ----------------------------------------------------------------

test "decompose canonical higher-half address" {
    const addr: u64 = 0xFFFFFFFF80001234;
    const idx = decompose(addr);
    // PML4 index for 0xFFFFFFFF80000000 = 511
    try std.testing.expectEqual(idx.pml4, 511);
    try std.testing.expectEqual(idx.offset, 0x234);
}

test "makePte and ptePhys round-trip" {
    const phys: PhysAddr = 0x0000_0020_0000;
    const entry = makePte(phys, .{ .present = true, .writable = true });
    try std.testing.expect(ptePresent(entry));
    try std.testing.expectEqual(ptePhys(entry), phys);
}

test "PteFlags size is 8 bytes" {
    try std.testing.expectEqual(@sizeOf(PteFlags), 8);
}
