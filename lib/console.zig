//! Magicore kernel console — early output before framebuffer/serial is fully initialized.
//! Used for boot diagnostics and kernel panic output.
//! No allocator required.

const std = @import("std");

var initialized = false;

pub fn init() void {
    // TODO: detect and init serial UART (COM1: 0x3F8)
    // TODO: if framebuffer available from boot, init fb console
    initialized = true;
}

/// Print formatted message to kernel console
pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (!initialized) return;
    // TODO: write to serial port / framebuffer
    // Using std.debug.print as placeholder for hosted tests
    std.debug.print(fmt, args);
}

/// Kernel panic — print message and halt all CPUs
pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    print("\n!!! MAGICORE KERNEL PANIC !!!\n", .{});
    print(fmt, args);
    print("\n", .{});
    // TODO: dump stack trace
    // TODO: call arch.halt_all()
    @panic("kernel panic");
}
