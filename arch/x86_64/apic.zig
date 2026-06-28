//! Magicore x86_64 APIC (Advanced Programmable Interrupt Controller).
//! Manages the local APIC: timer, EOI, spurious vector.
//!
//! Local APIC MMIO base is at 0xFEE00000 (physical), accessed via HHDM.
//! APIC timer fires at ~1000 Hz (1ms tick) — drives sched::tick().
//!
//! Steps:
//!   1. Disable legacy 8259 PIC (mask all interrupts)
//!   2. Enable local APIC via IA32_APIC_BASE MSR
//!   3. Set spurious interrupt vector to 0xFF
//!   4. Calibrate APIC timer against TSC or PIT
//!   5. Set APIC timer to periodic mode, vector 0x20

const std = @import("std");
const console = @import("../../lib/console.zig");

/// Local APIC MMIO base (physical)
pub const LAPIC_BASE_PHYS: u64 = 0xFEE0_0000;

/// Local APIC register offsets (from base)
const LAPIC_ID          : u32 = 0x020;
const LAPIC_VERSION     : u32 = 0x030;
const LAPIC_TPR         : u32 = 0x080; // Task Priority Register
const LAPIC_EOI         : u32 = 0x0B0; // End of Interrupt
const LAPIC_SPURIOUS    : u32 = 0x0F0; // Spurious Interrupt Vector
const LAPIC_ICR_LOW     : u32 = 0x300; // Interrupt Command (low)
const LAPIC_ICR_HIGH    : u32 = 0x310; // Interrupt Command (high)
const LAPIC_TIMER_LVT   : u32 = 0x320; // Timer Local Vector Table
const LAPIC_TIMER_INIT  : u32 = 0x380; // Timer Initial Count
const LAPIC_TIMER_CURR  : u32 = 0x390; // Timer Current Count
const LAPIC_TIMER_DIV   : u32 = 0x3E0; // Timer Divide Configuration

/// Timer vector (IDT entry for APIC timer IRQ)
pub const TIMER_VECTOR: u8 = 0x20;
/// Spurious vector
pub const SPURIOUS_VECTOR: u8 = 0xFF;

/// HHDM offset — set from mm during init
var hhdm_offset: u64 = 0;

/// Return a pointer to a local APIC register
inline fn lapicReg(offset: u32) *volatile u32 {
    const virt: u64 = LAPIC_BASE_PHYS + hhdm_offset + offset;
    return @ptrFromInt(virt);
}

inline fn lapicWrite(offset: u32, val: u32) void {
    lapicReg(offset).* = val;
}

inline fn lapicRead(offset: u32) u32 {
    return lapicReg(offset).*;
}

/// Disable the legacy 8259 PIC by masking all interrupts.
/// Must be done before enabling APIC.
fn disablePic() void {
    // Master PIC: mask all (port 0x21)
    asm volatile ("outb %[v], $0x21" : : [v] "{al}" (@as(u8, 0xFF)) );
    // Slave PIC: mask all (port 0xA1)
    asm volatile ("outb %[v], $0xA1" : : [v] "{al}" (@as(u8, 0xFF)) );
    // Small delay to let PIC settle
    asm volatile ("outb %[v], $0x80" : : [v] "{al}" (@as(u8, 0x00)) );
}

/// Initialize the local APIC.
/// `hhdm`: higher-half direct map offset from Limine.
pub fn init(hhdm: u64) void {
    hhdm_offset = hhdm;

    // 1. Disable legacy PIC
    disablePic();
    console.print("[apic] legacy PIC disabled\n", .{});

    // 2. Enable local APIC: set bit 8 (APIC global enable) in IA32_APIC_BASE MSR (0x1B)
    const msr_val = rdmsr(0x1B);
    wrmsr(0x1B, msr_val | (1 << 11)); // bit 11 = APIC enable

    // 3. Set spurious interrupt vector and enable APIC (bit 8 of spurious register)
    lapicWrite(LAPIC_SPURIOUS, 0x100 | SPURIOUS_VECTOR);

    // 4. Set task priority to 0 (accept all interrupts)
    lapicWrite(LAPIC_TPR, 0);

    const apic_id = lapicRead(LAPIC_ID) >> 24;
    const apic_ver = lapicRead(LAPIC_VERSION) & 0xFF;
    console.print("[apic] local APIC id={} version=0x{X:0>2}\n", .{ apic_id, apic_ver });

    // 5. Calibrate and start APIC timer (periodic, ~1ms tick)
    initTimer();
}

/// Calibrate APIC timer using the PIT channel 2 as reference.
/// Target: TIMER_VECTOR fires at ~1000 Hz.
fn initTimer() void {
    // Set APIC timer divisor to 16
    lapicWrite(LAPIC_TIMER_DIV, 0x3);

    // Use PIT channel 2 as 10ms reference
    // PIT frequency = 1193182 Hz; 10ms = 11932 counts
    const PIT_COUNTS: u16 = 11932;

    // Gate PIT channel 2 (port 0x61 bits 0+1)
    const gate_val = @as(u8, 0x01); // gate on, speaker off
    asm volatile ("outb %[v], $0x61" : : [v] "{al}" (gate_val));

    // Program PIT channel 2: mode 0 (one-shot), binary
    asm volatile ("outb %[v], $0x43" : : [v] "{al}" (@as(u8, 0xB2)));
    asm volatile ("outb %[v], $0x42" : : [v] "{al}" (@as(u8, PIT_COUNTS & 0xFF)));
    asm volatile ("outb %[v], $0x42" : : [v] "{al}" (@as(u8, PIT_COUNTS >> 8)));

    // Start APIC timer with a large initial count
    lapicWrite(LAPIC_TIMER_INIT, 0xFFFF_FFFF);

    // Wait for PIT to expire (poll bit 5 of port 0x61)
    while (true) {
        const v = asm volatile ("inb $0x61, %[out]" : [out] "={al}" (-> u8));
        if ((v & 0x20) != 0) break;
    }

    // Read how many APIC ticks elapsed in 10ms
    const elapsed = 0xFFFF_FFFF - lapicRead(LAPIC_TIMER_CURR);
    // 1ms tick target
    const ticks_per_ms = elapsed / 10;

    // Stop the timer
    lapicWrite(LAPIC_TIMER_INIT, 0);
    lapicWrite(LAPIC_TIMER_LVT, 0x10000); // mask

    // Configure periodic timer: vector TIMER_VECTOR, periodic mode
    lapicWrite(LAPIC_TIMER_LVT, 0x20000 | TIMER_VECTOR); // mode=periodic
    lapicWrite(LAPIC_TIMER_DIV, 0x3);                     // divisor=16
    lapicWrite(LAPIC_TIMER_INIT, ticks_per_ms);           // reload value

    console.print("[apic] timer calibrated: {} ticks/ms, vector=0x{X:0>2}\n", .{
        ticks_per_ms, TIMER_VECTOR,
    });
}

/// Signal end-of-interrupt to the local APIC.
/// Must be called at the end of every interrupt handler.
pub fn eoi() void {
    lapicWrite(LAPIC_EOI, 0);
}

/// Read an MSR
fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi)
        : [msr] "{ecx}" (msr)
    );
    return (@as(u64, hi) << 32) | lo;
}

/// Write an MSR
fn wrmsr(msr: u32, val: u64) void {
    const lo: u32 = @truncate(val);
    const hi: u32 = @truncate(val >> 32);
    asm volatile ("wrmsr"
        :
        : [lo] "{eax}" (lo),
          [hi] "{edx}" (hi),
          [msr] "{ecx}" (msr)
    );
}

test "LAPIC register offsets are multiples of 16" {
    // All local APIC registers must be 16-byte aligned
    try std.testing.expect(LAPIC_EOI % 16 == 0);
    try std.testing.expect(LAPIC_SPURIOUS % 16 == 0);
    try std.testing.expect(LAPIC_TIMER_LVT % 16 == 0);
    try std.testing.expect(LAPIC_TIMER_INIT % 16 == 0);
}
