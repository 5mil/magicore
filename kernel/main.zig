//! Magicore kernel entry point.
//! Strict init order:
//!   arch (GDT/IDT/CPUID) → mm (buddy+PT) → apic (timer) →
//!   sched → ipc → syscall → sched.start()

const std       = @import("std");
const arch      = @import("../arch/x86_64/init.zig");
const apic      = @import("../arch/x86_64/apic.zig");
const mm        = @import("mm/mm.zig");
const pgtable   = @import("mm/pgtable.zig");
const sched     = @import("sched/sched.zig");
const ipc       = @import("ipc/ipc.zig");
const syscall   = @import("syscall/table.zig");
const console   = @import("../lib/console.zig");

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

    // 3. Kernel page tables
    pgtable.initKernelPt(
        boot_info.hhdm_offset,
        mm.buddy_alloc.totalPages(),
    ) catch |err| {
        console.panic("pgtable init failed: {}", .{err});
    };
    console.print("[kmain] page tables ready, CR3=0x{X:0>16}\n", .{pgtable.kernel_pml4});
    // Switch to our own page tables
    pgtable.loadCr3(pgtable.kernel_pml4);
    console.print("[kmain] CR3 loaded\n", .{});

    // 4. APIC: disable legacy PIC, enable local APIC, start timer
    apic.init(boot_info.hhdm_offset);

    // 5. Scheduler
    sched.init() catch |err| {
        console.panic("sched init failed: {}", .{err});
    };
    console.print("[kmain] scheduler ready\n", .{});

    // 6. IPC
    ipc.init() catch |err| {
        console.panic("ipc init failed: {}", .{err});
    };
    console.print("[kmain] IPC ready\n", .{});

    // 7. Syscall table
    syscall.init();
    console.print("[kmain] syscall table ready\n", .{});

    console.print("[kmain] Magicore kernel ready. Entering scheduler.\n", .{});
    sched.start();
}
