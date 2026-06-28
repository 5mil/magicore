//! Magicore kernel entry point.
//! Init order:
//!   arch → mm → pgtable → apic → vfs → proc → sched → ipc → syscall → sched.start()

const std      = @import("std");
const arch     = @import("../arch/x86_64/init.zig");
const apic     = @import("../arch/x86_64/apic.zig");
const mm       = @import("mm/mm.zig");
const pgtable  = @import("mm/pgtable.zig");
const vfs_mnt  = @import("fs/vfs_mount.zig");
const proc_mod = @import("process/process.zig");
const sched    = @import("sched/sched.zig");
const ipc      = @import("ipc/ipc.zig");
const syscall  = @import("syscall/table.zig");
const console  = @import("../lib/console.zig");

pub fn kmain(boot_info: *const arch.BootInfo) noreturn {
    console.print("[kmain] entering kernel\n", .{});

    arch.init(boot_info) catch |err| console.panic("arch: {}", .{err});

    mm.init(boot_info.memory_map, boot_info.hhdm_offset)
        catch |err| console.panic("mm: {}", .{err});

    pgtable.initKernelPt(boot_info.hhdm_offset, mm.buddy_alloc.totalPages())
        catch |err| console.panic("pgtable: {}", .{err});
    pgtable.loadCr3(pgtable.kernel_pml4);
    console.print("[kmain] CR3=0x{X:0>16}\n", .{pgtable.kernel_pml4});

    apic.init(boot_info.hhdm_offset);

    // VFS: mount root ramfs, wire stdout/stderr
    vfs_mnt.init(mm.kernel_allocator);

    proc_mod.init();

    sched.init() catch |err| console.panic("sched: {}", .{err});
    console.print("[kmain] scheduler ready\n", .{});

    ipc.init() catch |err| console.panic("ipc: {}", .{err});
    console.print("[kmain] IPC ready\n", .{});

    syscall.init();
    console.print("[kmain] syscall table ready\n", .{});

    console.print("[kmain] Magicore kernel ready. Entering scheduler.\n", .{});
    sched.start();
}
