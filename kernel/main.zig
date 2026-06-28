//! Magicore kernel entry point.
//! Called from arch-specific boot stub after early hardware init.

const arch = @import("../arch/x86_64/init.zig");
const mm = @import("mm/mm.zig");
const sched = @import("sched/sched.zig");
const ipc = @import("ipc/ipc.zig");
const syscall = @import("syscall/table.zig");
const console = @import("../lib/console.zig");

/// kmain — called by arch boot stub with memory map and boot info.
/// All subsystems are initialized here in strict dependency order.
pub fn kmain(boot_info: *const arch.BootInfo) noreturn {
    // 1. Console first — needed for all subsequent diagnostics
    console.init();
    console.print("Magicore v0.1.0 — booting\n", .{});

    // 2. Architecture-level init (GDT, IDT, APIC, CPU features)
    arch.init(boot_info) catch |err| {
        console.panic("arch init failed: {}", .{err});
    };

    // 3. Physical and virtual memory
    mm.init(boot_info.memory_map) catch |err| {
        console.panic("mm init failed: {}", .{err});
    };

    // 4. Scheduler
    sched.init() catch |err| {
        console.panic("sched init failed: {}", .{err});
    };

    // 5. IPC primitives
    ipc.init() catch |err| {
        console.panic("ipc init failed: {}", .{err});
    };

    // 6. Syscall table
    syscall.init();

    console.print("Magicore kernel ready.\n", .{});

    // Hand off to scheduler — does not return
    sched.start();
}
