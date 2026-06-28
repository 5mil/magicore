//! Magicore Local APIC + calibrated periodic timer.
//! Timer fires every 1ms on vector 0x20 → sched.tick().
//! IRQ handler dispatches to sched.tick() and sends EOI.

const std     = @import("std");
const console = @import("../../lib/console.zig");
const sched   = @import("../../kernel/sched/sched.zig");

// LAPIC MMIO register offsets (from LAPIC base)
const LAPIC_ID       : usize = 0x020;
const LAPIC_VER      : usize = 0x030;
const LAPIC_EOI      : usize = 0x0B0;
const LAPIC_SPURIOUS : usize = 0x0F0;
const LAPIC_LVT_TIMER: usize = 0x320;
const LAPIC_TMRINITCNT: usize = 0x380;
const LAPIC_TMRCURRCNT: usize = 0x390;
const LAPIC_TMRDIV   : usize = 0x3E0;

/// LVT Timer: periodic mode (bit 17), vector
const LVT_PERIODIC: u32 = 1 << 17;

/// 8259 PIC I/O ports
const PIC1_CMD : u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_CMD : u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;
const PIC_EOI  : u8  = 0x20;

/// PIT (channel 2) ports for calibration
const PIT_CH2  : u16 = 0x42;
const PIT_CMD  : u16 = 0x43;
const PIT_GATE : u16 = 0x61;

/// Virtual address of the LAPIC MMIO region (HHDM-mapped)
pub var lapic_base: u64 = 0;

/// Measured LAPIC ticks per millisecond
var ticks_per_ms: u32 = 0;

inline fn lapicRead(off: usize) u32 {
    const ptr: *volatile u32 = @ptrFromInt(lapic_base + off);
    return ptr.*;
}
inline fn lapicWrite(off: usize, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(lapic_base + off);
    ptr.* = val;
}
inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[v], %[p]" : : [v] "{al}" (val), [p] "N{dx}" (port));
}
inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[v]"
        : [v] "={al}" (-> u8)
        : [p] "N{dx}" (port)
    );
}

/// Disable legacy 8259 PIC (mask all interrupts).
fn disablePic() void {
    // Send ICW1
    outb(PIC1_CMD,  0x11);
    outb(PIC2_CMD,  0x11);
    // ICW2: remap to vectors 0x20–0x27 (PIC1) and 0x28–0x2F (PIC2)
    outb(PIC1_DATA, 0x20);
    outb(PIC2_DATA, 0x28);
    // ICW3, ICW4
    outb(PIC1_DATA, 0x04);
    outb(PIC2_DATA, 0x02);
    outb(PIC1_DATA, 0x01);
    outb(PIC2_DATA, 0x01);
    // Mask all interrupts on both PICs
    outb(PIC1_DATA, 0xFF);
    outb(PIC2_DATA, 0xFF);
    console.print("[apic] legacy PIC disabled\n", .{});
}

/// Enable the local APIC via MSR 0x1B and spurious vector register.
fn enableLapic() void {
    // Set IA32_APIC_BASE MSR: enable global APIC (bit 11)
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr" : [lo] "={eax}" (lo), [hi] "={edx}" (hi) : [msr] "{ecx}" (@as(u32, 0x1B)));
    lo |= (1 << 11);
    // Extract physical base from bits 12..35
    lapic_base = ((@as(u64, hi) << 32) | lo) & 0x0000_FFFF_FFFF_F000;
    asm volatile ("wrmsr" : : [lo] "{eax}" (lo), [hi] "{edx}" (hi), [msr] "{ecx}" (@as(u32, 0x1B)));
    // Software enable via spurious vector register (bit 8 = APIC enable, vector=0xFF)
    lapicWrite(LAPIC_SPURIOUS, 0x1FF);
    console.print("[apic] local APIC id={} version=0x{X}\n", .{
        lapicRead(LAPIC_ID) >> 24,
        lapicRead(LAPIC_VER) & 0xFF,
    });
}

/// Calibrate LAPIC timer against PIT channel 2 (10ms reference).
/// Sets `ticks_per_ms` and programs a 1ms periodic timer on vector 0x20.
fn calibrateAndStartTimer() void {
    // Divider = 1
    lapicWrite(LAPIC_TMRDIV, 0x0B);
    // Max initial count
    lapicWrite(LAPIC_TMRINITCNT, 0xFFFF_FFFF);

    // Set up PIT channel 2 for a 10ms one-shot
    const PIT_HZ: u32 = 1_193_182;
    const ticks_10ms: u16 = @intCast((PIT_HZ * 10) / 1000);
    outb(PIT_CMD, 0xB2); // channel 2, lobyte/hibyte, one-shot
    outb(PIT_CH2, @intCast(ticks_10ms & 0xFF));
    outb(PIT_CH2, @intCast(ticks_10ms >> 8));
    // Gate on
    outb(PIT_GATE, (inb(PIT_GATE) & 0xFD) | 0x01);

    // Wait for PIT OUT to go high (bit 5 of port 0x61)
    while ((inb(PIT_GATE) & 0x20) == 0) {}

    const elapsed = 0xFFFF_FFFF - lapicRead(LAPIC_TMRCURRCNT);
    ticks_per_ms = elapsed / 10;

    // Program 1ms periodic timer on vector 0x20
    lapicWrite(LAPIC_LVT_TIMER, LVT_PERIODIC | 0x20);
    lapicWrite(LAPIC_TMRDIV,    0x0B);
    lapicWrite(LAPIC_TMRINITCNT, ticks_per_ms);

    console.print("[apic] timer calibrated: {} ticks/ms, vector=0x20\n", .{ticks_per_ms});
}

pub fn init(_hhdm_offset: u64) void {
    _ = _hhdm_offset;
    disablePic();
    enableLapic();
    calibrateAndStartTimer();
}

/// Send EOI to local APIC.
/// Must be called at end of every IRQ handler.
pub inline fn eoi() void {
    lapicWrite(LAPIC_EOI, 0);
}

// ----------------------------------------------------------------
// IRQ 0x20: APIC timer handler (1ms tick)
// ----------------------------------------------------------------

/// IDT vector 0x20 handler — installed by idt_setup() in init.zig.
/// Calls sched.tick() then sends EOI.
export fn apicTimerHandler() callconv(.Interrupt) void {
    sched.tick();
    eoi();
}

test "LVT_PERIODIC bit" {
    try std.testing.expectEqual(LVT_PERIODIC, 1 << 17);
}
