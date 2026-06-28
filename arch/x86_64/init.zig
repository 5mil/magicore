//! Magicore x86_64 architecture init.
//! GDT (with TSS) → IDT (with APIC timer + PF handler) → SYSCALL MSRs → CPU feature check.

const std     = @import("std");
const mm      = @import("../../kernel/mm/mm.zig");
const console = @import("../../lib/console.zig");
const sc      = @import("syscall.zig");
const ctx     = @import("context.zig");
const apic_m  = @import("apic.zig");
const pf      = @import("pagefault.zig");

pub const BootInfo = struct {
    memory_map:       []const mm.MemMapEntry,
    kernel_phys_base: u64,
    kernel_virt_base: u64,
    hhdm_offset:      u64,
    rsdp_addr:        u64,
    fb_addr:          u64,
    fb_width:         u32,
    fb_height:        u32,
    fb_pitch:         u32,
};

const GdtEntry = packed struct {
    limit_low:   u16,
    base_low:    u16,
    base_mid:    u8,
    access:      u8,
    granularity: u8,
    base_high:   u8,
};

// TSS descriptor is 16 bytes (system descriptor)
const TssDes = packed struct {
    limit_low:  u16,
    base_0_15:  u16,
    base_16_23: u8,
    access:     u8,   // 0x89 = present, 64-bit TSS available
    limit_hi:   u8,
    base_24_31: u8,
    base_32_63: u32,
    reserved:   u32,
};

const GDT_NULL        = GdtEntry{ .limit_low=0,      .base_low=0, .base_mid=0, .access=0x00, .granularity=0x00, .base_high=0 };
const GDT_KERNEL_CODE = GdtEntry{ .limit_low=0xFFFF, .base_low=0, .base_mid=0, .access=0x9A, .granularity=0xAF, .base_high=0 };
const GDT_KERNEL_DATA = GdtEntry{ .limit_low=0xFFFF, .base_low=0, .base_mid=0, .access=0x92, .granularity=0xCF, .base_high=0 };
const GDT_USER_CODE   = GdtEntry{ .limit_low=0xFFFF, .base_low=0, .base_mid=0, .access=0xFA, .granularity=0xAF, .base_high=0 };
const GDT_USER_DATA   = GdtEntry{ .limit_low=0xFFFF, .base_low=0, .base_mid=0, .access=0xF2, .granularity=0xCF, .base_high=0 };

const GdtPtr = packed struct { limit: u16, base: u64 };

// GDT: null, kernel code (0x08), kernel data (0x10),
//      user code (0x18), user data (0x20), TSS low (0x28), TSS high (0x30)
var gdt_raw: [7 * 8]u8 align(8) linksection(".data") = std.mem.zeroes([7 * 8]u8);

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

pub const KERNEL_CS: u16 = 0x08;
pub const KERNEL_DS: u16 = 0x10;
pub const USER_CS:   u16 = 0x18 | 3;
pub const USER_DS:   u16 = 0x20 | 3;

fn makeIdtEntry(handler: u64, selector: u16, ist: u8, attr: u8) IdtEntry {
    return .{
        .offset_low  = @intCast(handler & 0xFFFF),
        .selector    = selector,
        .ist         = ist,
        .type_attr   = attr,
        .offset_mid  = @intCast((handler >> 16) & 0xFFFF),
        .offset_high = @intCast(handler >> 32),
        .zero        = 0,
    };
}

pub fn init(boot_info: *const BootInfo) error{CpuFeatureMissing}!void {
    _ = boot_info;
    gdt_setup();
    console.print("[arch] GDT loaded (with TSS)\n", .{});
    idt_setup();
    console.print("[arch] IDT loaded\n", .{});
    try cpu_features_check();
    console.print("[arch] CPU features OK\n", .{});
    sc.init();
}

fn gdt_setup() void {
    // Entries 0–4: standard 8-byte descriptors
    const entries = [5]GdtEntry{ GDT_NULL, GDT_KERNEL_CODE, GDT_KERNEL_DATA, GDT_USER_CODE, GDT_USER_DATA };
    for (entries, 0..) |e, i| {
        @memcpy(gdt_raw[i * 8 ..][0..8], std.mem.asBytes(&e));
    }
    // Entry 5 (0x28): TSS low 8 bytes
    // Entry 6 (0x30): TSS high 8 bytes
    const tss_addr = @intFromPtr(&ctx.tss);
    const tss_limit: u32 = @sizeOf(ctx.Tss) - 1;
    const tss_lo = TssDes{
        .limit_low  = @intCast(tss_limit & 0xFFFF),
        .base_0_15  = @intCast(tss_addr & 0xFFFF),
        .base_16_23 = @intCast((tss_addr >> 16) & 0xFF),
        .access     = 0x89,
        .limit_hi   = @intCast((tss_limit >> 16) & 0x0F),
        .base_24_31 = @intCast((tss_addr >> 24) & 0xFF),
        .base_32_63 = @intCast(tss_addr >> 32),
        .reserved   = 0,
    };
    @memcpy(gdt_raw[5 * 8 ..][0..16], std.mem.asBytes(&tss_lo));

    const ptr = GdtPtr{ .limit = @intCast(gdt_raw.len - 1), .base = @intFromPtr(&gdt_raw) };
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
    asm volatile (
        \\pushq $0x08
        \\lea 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        : : : "rax", "memory"
    );
    ctx.loadTss();
}

fn idt_setup() void {
    // #PF at vector 14
    idt[14] = makeIdtEntry(@intFromPtr(&pf.pageFaultHandler), KERNEL_CS, 0, 0x8E);
    // APIC timer at vector 0x20
    idt[0x20] = makeIdtEntry(@intFromPtr(&apic_m.apicTimerHandler), KERNEL_CS, 0, 0x8E);

    const ptr = IdtPtr{ .limit = @intCast(@sizeOf(@TypeOf(idt)) - 1), .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[ptr])" : : [ptr] "r" (&ptr) : "memory");
}

fn cpu_features_check() error{CpuFeatureMissing}!void {
    var edx: u32 = 0;
    asm volatile (
        \\mov $1, %%eax
        \\cpuid
        : [edx] "={edx}" (edx) : : "eax", "ebx", "ecx"
    );
    if ((edx & (1 << 26)) == 0) return error.CpuFeatureMissing; // SSE2
    var edx2: u32 = 0;
    asm volatile (
        \\mov $0x80000001, %%eax
        \\cpuid
        : [edx2] "={edx}" (edx2) : : "eax", "ebx", "ecx"
    );
    if ((edx2 & (1 << 20)) == 0) return error.CpuFeatureMissing; // NX
    if ((edx2 & (1 << 11)) == 0) return error.CpuFeatureMissing; // SYSCALL
}

pub fn halt_all() noreturn {
    asm volatile ("cli");
    while (true) { asm volatile ("hlt"); }
}

test "GDT entry size" {
    try std.testing.expectEqual(@sizeOf(GdtEntry), 8);
    try std.testing.expectEqual(@sizeOf(IdtEntry), 16);
    try std.testing.expectEqual(@sizeOf(TssDes), 16);
}

test "selector values" {
    try std.testing.expectEqual(KERNEL_CS, 0x08);
    try std.testing.expectEqual(KERNEL_DS, 0x10);
}
