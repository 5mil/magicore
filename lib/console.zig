//! Magicore kernel console.
//! Two-phase design:
//!   Phase 1 (early): UART only — no allocation, no VFS, called from boot stub
//!   Phase 2 (late):  UART + framebuffer — after mm and graphics init
//!
//! console.print() is safe to call from ANY context:
//!   - before kmain
//!   - inside interrupt handlers
//!   - inside panic paths
//! It never allocates. It never locks in a way that can deadlock.

const std  = @import("std");
const uart = @import("../drivers/uart16550.zig");

/// Backing UART pointer — set in earlyInit()
var early_uart: ?*uart.Uart = null;

/// Phase 1 init: wire console to a UART instance
pub fn earlyInit(u: *uart.Uart) void {
    early_uart = u;
}

/// Write a formatted string to all available outputs
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
        const overflow = "<console: format overflow>\n";
        if (early_uart) |u| u.writeStr(overflow);
        break :blk overflow;
    };
    if (early_uart) |u| u.writeStr(s);
    // TODO: Phase 2 — also write to framebuffer
}

/// Kernel panic — print banner + message then halt
pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    print("\n", .{});
    print("╔══════════════════════════════════════════╗\n", .{});
    print("║     MAGICORE KERNEL PANIC                ║\n", .{});
    print("╚══════════════════════════════════════════╝\n", .{});
    print(fmt, args);
    print("\n", .{});
    // TODO: dump stack trace
    // TODO: call arch.halt_all()
    @panic("kernel panic");
}

/// Formatted write to console — alias for print
pub fn log(comptime fmt: []const u8, args: anytype) void {
    print(fmt, args);
}

test "console does not crash without uart" {
    // earlyInit not called — print should be a no-op
    early_uart = null;
    print("test\n", .{});
}
