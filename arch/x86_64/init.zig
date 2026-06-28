//! Magicore x86_64 architecture init.
//! Handles early CPU setup: GDT, IDT, APIC, CPU feature detection.
//! Called before any other kernel subsystem.

const std = @import("std");

/// Boot information passed from bootloader (Limine protocol)
pub const BootInfo = struct {
    memory_map: []const @import("../../kernel/mm/mm.zig").MemMapEntry,
    kernel_phys_base: u64,
    kernel_virt_base: u64,
    rsdp_addr: u64,     // ACPI root pointer
    fb_addr: u64,       // Framebuffer base
    fb_width: u32,
    fb_height: u32,
    fb_pitch: u32,
};

/// Initialize CPU: GDT → IDT → APIC → features
pub fn init(boot_info: *const BootInfo) error{CpuFeatureMissing}!void {
    _ = boot_info;
    gdt_init();
    idt_init();
    try cpu_features_check();
    // TODO: APIC init
    // TODO: TSC calibration
}

fn gdt_init() void {
    // TODO: load 64-bit GDT with kernel/user code+data segments, TSS
}

fn idt_init() void {
    // TODO: populate IDT with exception and IRQ handlers
    // TODO: SYSCALL/SYSRET MSR setup
}

fn cpu_features_check() error{CpuFeatureMissing}!void {
    // Require: SSE2, SSSE3, POPCNT, NX
    // TODO: CPUID checks
}

/// Halt all CPUs — used in panic
pub fn halt_all() noreturn {
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}
