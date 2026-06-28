//! Magicore kernel entry point.
//! Called from arch-specific boot stub after early hardware init.
//! Strict subsystem init order:
//!   arch → mm → sched → ipc → syscall → sched.start()

const std     = @import("std");
const arch    = @import("../arch/x86_64/init.zig");
const mm      = @import("mm/mm.zig");
const sched   = @import("sched/sched.zig");
const ipc     = @import("ipc/ipc.zig");
const syscall = @import("syscall/table.zig");
const console = @import("../lib/console.zig");

/// kmain — called by arch/x86_64/boot.zig with populated BootInfo.
/// UART console is already initialized before we are called.
pub fn kmain(boot_info: *const arch.BootInfo) noreturn {
    console.print("[kmain] entering kernel\n", .{});

    // 1. Architecture: GDT, IDT, CPU features
    arch.init(boot_info) catch |err| {
        console.panic("arch init failed: {}", .{err});
    };

    // 2. Physical memory manager
    mm.init(boot_info.memory_map, boot_info.hhdm_offset) catch |err| {
        console.panic("mm init failed: {}", .{err});
    };

    // 3. Scheduler
    sched.init() catch |err| {
        console.panic("sched init failed: {}", .{err});
    };
    console.print("[kmain] scheduler ready\n", .{});

    // 4. IPC
    ipc.init() catch |err| {
        console.panic("ipc init: {}", .{err});
    };
    console.print("[kmain] IPC ready\n", .{});

    // 5. Syscall table
    syscall.init();
    console.print("[kmain] syscall table ready\n", .{});

    console.print("[kmain] Magicore kernel ready. Entering scheduler.\n", .{});

    // Hand off to scheduler — never returns
    sched.start();
}
