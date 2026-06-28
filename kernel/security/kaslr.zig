//! Magicore KASLR — Kernel Address Space Layout Randomization.
//! Randomizes kernel load offset at every boot using hardware entropy.
//! Linux KASLR has had bypass CVEs; Magicore uses larger entropy pool
//! and aligns to 2MB boundaries to avoid TLB fragmentation.

const std = @import("std");
const entropy = @import("entropy.zig");

/// Kernel virtual base is randomized within this window.
/// Higher-half kernel: 0xFFFFFFFF80000000 ± KASLR_RANGE
const KASLR_BASE: u64    = 0xFFFFFFFF80000000;
const KASLR_RANGE: u64   = 0x0000000040000000; // ±1GB window
const KASLR_ALIGN: u64   = 0x200000;           // 2MB alignment

/// Chosen kernel virtual offset for this boot (set once at boot)
var kernel_slide: u64 = 0;

/// Compute KASLR slide using hardware entropy.
/// Called before any kernel virtual addresses are used.
pub fn computeSlide() void {
    const raw = entropy.getU64();
    // Constrain to range, align to 2MB
    const range_pages = KASLR_RANGE / KASLR_ALIGN;
    const idx = raw % range_pages;
    kernel_slide = idx * KASLR_ALIGN;
}

/// Return the kernel virtual base for this boot
pub fn kernelBase() u64 {
    return KASLR_BASE + kernel_slide;
}

/// Translate a link-time virtual address to the runtime address
pub fn slide(link_addr: u64) u64 {
    return link_addr + kernel_slide;
}

test "KASLR slide is 2MB aligned" {
    // Simulate: manually set slide and check alignment
    kernel_slide = 0x600000; // 3 * 2MB
    try std.testing.expectEqual(kernelBase() % KASLR_ALIGN, 0);
}

test "KASLR slide function" {
    kernel_slide = 0x400000;
    try std.testing.expectEqual(slide(0xFFFFFFFF80100000), 0xFFFFFFFF80500000);
}
