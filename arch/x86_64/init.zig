//! Magicore x86_64 architecture init.
//! GDT → IDT → APIC → CPU feature detection.
//! Called as the first thing inside kmain after early console is ready.

const std    = @import("std");
const mm     = @import("../../kernel/mm/mm.zig");
const console = @import("../../lib/console.zig");

/// Boot information — built by boot.zig from Limine responses
pub const BootInfo = struct {
    memory_map:       []const mm.MemMapEntry,
    kernel_phys_base: u64,
    kernel_virt_base: u64,
    hhdm_offset:      u64,  // higher-half direct map offset
    rsdp_addr:        u64,
    fb_addr:          u64,
    fb_width:         u32,
    fb_height:        u32,
    fb_pitch:         u32,
};

/// 64-bit GDT — minimal: null, kernel code, kernel data, user code, user data, TSS
const GdtEntry = packed struct {
    limit_low:  u16,
    base_low:   u16,
    base_mid:   u8,
    access:     u8,
    granularity:u8,
    base_high:  u8,
};

const GDT_NULL        = GdtEntry{ .limit_low=0, .base_low=0, .base_mid=0, .access=0, .granularity=0, .base_high=0 };
const GDT_KERNEL_CODE = GdtEntry{ .limit_low=0xFFFF, .base_low=0, .base_mid=0, .access=0x9A, .granularity=0xAF, .base_high=0 };
const GDT_KERNEL_DATA = GdtEntry{ .limit_low=0xFFFF, .base_low=0, .base_mid=0, .access=0x92, .granularity=0xCF, .base_high=0 };
const GDT_USER_CODE   = GdtEntry{ .limit_low=0xFFFF, .base_low=0, .base_mid=0, .access=0xFA, .granularity=0xAF, .base_high=0 };
const GDT_USER_DATA   = GdtEntry{ .limit_low=0xFFFF, .base_low=0, .base_mid=0, .access=0xF2, .granularity=0xCF, .base_high=0 };

const GdtPtr = packed struct { limit: u16, base: u64 };

var gdt: [5]GdtEntry align(8) = .{
    GDT_NULL,
    GDT_KERNEL_CODE,
    GDT_KERNEL_DATA,
    GDT_USER_CODE,
    GDT_USER_DATA,
};

/// IDT entry (16 bytes)
const IdtEntry = packed struct {
    offset_low:  u16,
    selector:    u16,
    ist:         u8,
    type_attr:   u8,
    offset_mid:  u16,
    offset_high: u32,
    zero:        u32,
};

const IDT_SIZE = 256;
var idt: [IDT_SIZE]IdtEntry align(16) = std.mem.zeroes([IDT_SIZE]IdtEntry);
const IdtPtr = packed struct { limit: u16, base: u64 };

/// Selector constants
pub const KERNEL_CS: u16 = 0x08; // GDT index 1 * 8
pub const KERNEL_DS: u16 = 0x10; // GDT index 2 * 8
pub const USER_CS:   u16 = 0x18 | 3;
pub const USER_DS:   u16 = 0x20 | 3;

/// Initialize CPU: GDT → IDT → CPU features
pub fn init(boot_info: *const BootInfo) error{CpuFeatureMissing}!void {
    _ = boot_info;
    gdt_load();
    console.print("[arch] GDT loaded\n", .{});
    idt_load();
    console.print("[arch] IDT loaded\n", .{});
    try cpu_features_check();
    console.print("[arch] CPU features OK\n", .{});
    // TODO: APIC init, TSC calibration, SYSCALL MSR
}

fn gdt_load() void {
    const ptr = GdtPtr{
        .limit = @intCast(@sizeOf(@TypeOf(gdt)) - 1),
        .base  = @intFromPtr(&gdt),
    };
    asm volatile (
        \\lgdt (%[ptr])
        \\mov $0x10, %%ax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\mov %%ax, %%ss
        : : [ptr] "r" (&ptr) : "ax", "memory"
    );
    // Far return to reload CS
    asm volatile (
        \\pushq $0x08
        \\lea 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        : : : "rax", "memory"
    );
}

fn idt_load() void {
    // Install minimal exception handlers (stubs that halt)
    for (0..32) |i| {
        idt[i] = makeIdtEntry(exceptionStub, KERNEL_CS, 0x8E);
        _ = i;
    }
    const ptr = IdtPtr{
        .limit = @intCast(@sizeOf(@TypeOf(idt)) - 1),
        .base  = @intFromPtr(&idt),
    };
    asm volatile ("lidt (%[ptr])" : : [ptr] "r" (&ptr) : "memory");
}

fn makeIdtEntry(handler: *const fn() callconv(.Naked) void, sel: u16, attr: u8) IdtEntry {
    const addr = @intFromPtr(handler);
    return .{
        .offset_low  = @truncate(addr & 0xFFFF),
        .selector    = sel,
        .ist         = 0,
        .type_attr   = attr,
        .offset_mid  = @truncate((addr >> 16) & 0xFFFF),
        .offset_high = @truncate((addr >> 32) & 0xFFFFFFFF),
        .zero        = 0,
    };
}

fn exceptionStub() callconv(.Naked) void {
    asm volatile (
        \\cli
        \\hlt
        \\jmp exceptionStub
    );
}

fn cpu_features_check() error{CpuFeatureMissing}!void {
    // Check for SSE2 (CPUID.1.EDX bit 26)
    var edx: u32 = 0;
    asm volatile (
        \\mov $1, %%eax
        \\cpuid
        : [edx] "={edx}" (edx)
        : : "eax", "ebx", "ecx"
    );
    if ((edx & (1 << 26)) == 0) return error.CpuFeatureMissing;
    // NX bit check via CPUID.80000001h.EDX bit 20
    var edx2: u32 = 0;
    asm volatile (
        \\mov $0x80000001, %%eax
        \\cpuid
        : [edx2] "={edx}" (edx2)
        : : "eax", "ebx", "ecx"
    );
    if ((edx2 & (1 << 20)) == 0) return error.CpuFeatureMissing;
}

/// Halt all CPUs — used in panic
pub fn halt_all() noreturn {
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

test "GDT entry sizes" {
    try std.testing.expectEqual(@sizeOf(GdtEntry), 8);
    try std.testing.expectEqual(@sizeOf(IdtEntry), 16);
}

test "selector values" {
    try std.testing.expectEqual(KERNEL_CS, 0x08);
    try std.testing.expectEqual(KERNEL_DS, 0x10);
}
