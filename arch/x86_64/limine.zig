//! Magicore Limine boot protocol v8 request/response structures.
//! Limine is the bootloader that hands control to the kernel.
//! It places response pointers in request structs before jumping to _start.
//!
//! Every request is a comptime-typed struct placed in .requests section.
//! Limine scans that section, finds magic IDs, fills in response pointers.
//!
//! Spec: https://github.com/limine-bootloader/limine/blob/v8.x/PROTOCOL.md

const std = @import("std");

/// Common magic IDs that prefix every Limine request
pub const MAGIC_0: u64 = 0xc7b1dd30df4c8b88;
pub const MAGIC_1: u64 = 0x0a82e883a194f07b;

/// Limine framebuffer mode
pub const FramebufferMemoryModel = enum(u8) {
    rgb = 1,
};

/// A single framebuffer descriptor
pub const Framebuffer = extern struct {
    address:       u64,
    width:         u64,
    height:        u64,
    pitch:         u64,
    bpp:           u16,
    memory_model:  FramebufferMemoryModel,
    red_mask_size: u8,
    red_mask_shift:u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    _unused:       [7]u8,
    edid_size:     u64,
    edid:          ?*anyopaque,
    mode_count:    u64,
    modes:         ?[*]?*anyopaque,
};

/// Framebuffer response
pub const FramebufferResponse = extern struct {
    revision:          u64,
    framebuffer_count: u64,
    framebuffers:      [*]*Framebuffer,
};

/// Framebuffer request
pub const FramebufferRequest = extern struct {
    id:       [4]u64 = .{ MAGIC_0, MAGIC_1, 0x9d5827dcd881dd75, 0xa3148604f6fab11b },
    revision: u64    = 0,
    response: ?*FramebufferResponse = null,
};

/// Memory map entry types
pub const MemMapEntryType = enum(u64) {
    usable                = 0,
    reserved              = 1,
    acpi_reclaimable      = 2,
    acpi_nvs              = 3,
    bad_memory            = 4,
    bootloader_reclaimable= 5,
    kernel_and_modules    = 6,
    framebuffer           = 7,
};

/// Memory map entry
pub const MemMapEntry = extern struct {
    base:   u64,
    length: u64,
    kind:   MemMapEntryType,
};

/// Memory map response
pub const MemMapResponse = extern struct {
    revision:    u64,
    entry_count: u64,
    entries:     [*]*MemMapEntry,
};

/// Memory map request
pub const MemMapRequest = extern struct {
    id:       [4]u64 = .{ MAGIC_0, MAGIC_1, 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    revision: u64    = 0,
    response: ?*MemMapResponse = null,
};

/// Kernel address response
pub const KernelAddressResponse = extern struct {
    revision:  u64,
    physical_base: u64,
    virtual_base:  u64,
};

/// Kernel address request
pub const KernelAddressRequest = extern struct {
    id:       [4]u64 = .{ MAGIC_0, MAGIC_1, 0x71ba76863cc55f63, 0xb2644a48c516a487 },
    revision: u64    = 0,
    response: ?*KernelAddressResponse = null,
};

/// RSDP (ACPI root pointer) response
pub const RsdpResponse = extern struct {
    revision: u64,
    address:  u64,
};

/// RSDP request
pub const RsdpRequest = extern struct {
    id:       [4]u64 = .{ MAGIC_0, MAGIC_1, 0xc5e77b6b397e7b43, 0x27637845accdcf3c },
    revision: u64    = 0,
    response: ?*RsdpResponse = null,
};

/// Boot time (UNIX epoch seconds) response
pub const BootTimeResponse = extern struct {
    revision: u64,
    boot_time: i64,
};

/// Boot time request
pub const BootTimeRequest = extern struct {
    id:       [4]u64 = .{ MAGIC_0, MAGIC_1, 0x502746e184c088aa, 0xfbc5ec83e6327893 },
    revision: u64    = 0,
    response: ?*BootTimeResponse = null,
};

/// Higher-half direct map response
pub const HhdmResponse = extern struct {
    revision: u64,
    offset:   u64,
};

/// Higher-half direct map request
/// Limine maps all physical memory at a fixed virtual offset.
/// We use this to access physical memory via virtual addresses.
pub const HhdmRequest = extern struct {
    id:       [4]u64 = .{ MAGIC_0, MAGIC_1, 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    revision: u64    = 0,
    response: ?*HhdmResponse = null,
};

/// Limine requests — placed in .requests section so bootloader can find them
/// All exported so they are not dead-stripped
pub export var framebuffer_request: FramebufferRequest linksection(".requests") = .{};
pub export var memmap_request:      MemMapRequest      linksection(".requests") = .{};
pub export var kaddr_request:       KernelAddressRequest linksection(".requests") = .{};
pub export var rsdp_request:        RsdpRequest        linksection(".requests") = .{};
pub export var boottime_request:    BootTimeRequest    linksection(".requests") = .{};
pub export var hhdm_request:        HhdmRequest        linksection(".requests") = .{};

test "request sizes are nonzero" {
    try std.testing.expect(@sizeOf(FramebufferRequest) > 0);
    try std.testing.expect(@sizeOf(MemMapRequest) > 0);
    try std.testing.expect(@sizeOf(HhdmRequest) > 0);
}
