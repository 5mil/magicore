//! Magicore syscall table.
//! Syscalls are the ONLY user→kernel interface.
//! 30 syscalls. All typed. All auditable.
//! No undocumented back-channels. No ioctl sprawl.

const std  = @import("std");
const proc = @import("../process/process.zig");

/// Syscall numbers — stable ABI once frozen
pub const Syscall = enum(u64) {
    // Process lifecycle
    exit      = 0,
    fork      = 1,
    exec      = 2,
    wait      = 3,
    getpid    = 4,
    // Memory
    mmap      = 10,
    munmap    = 11,
    mprotect  = 12,
    // File I/O
    open      = 20,
    close     = 21,
    read      = 22,
    write     = 23,
    seek      = 24,
    stat      = 25,
    unlink    = 26,
    // IPC
    chan_create = 30,
    chan_send   = 31,
    chan_recv   = 32,
    chan_close  = 33,
    // Networking
    socket    = 40,
    bind      = 41,
    connect   = 42,
    listen    = 43,
    accept    = 44,
    sendmsg   = 45,
    recvmsg   = 46,
    // Time
    clock_get   = 50,
    clock_sleep = 51,
    // System info
    sysinfo   = 60,
    uname     = 61,
    _,
};

pub const Handler = *const fn (args: [6]u64) u64;

var table: std.EnumArray(Syscall, ?Handler) = std.EnumArray(Syscall, ?Handler).initFill(null);

pub fn init() void {
    // Process lifecycle — wired to real implementations
    table.set(.exit,   &sys_exit_wrap);
    table.set(.fork,   &sys_fork_wrap);
    table.set(.exec,   &sys_exec_wrap);
    table.set(.wait,   &sys_wait_wrap);
    table.set(.getpid, &sys_getpid_wrap);
    // Remaining handlers registered in Phase 2 (fs, net, etc.)
}

/// Main syscall entry — called from arch/x86_64/syscall.zig stub
pub fn dispatch(num: u64, args: [6]u64) u64 {
    const sc = std.meta.intToEnum(Syscall, num) catch return enosys();
    const handler = table.get(sc) orelse return enosys();
    return handler(args);
}

inline fn enosys() u64 { return @bitCast(@as(i64, -38)); } // -ENOSYS

// ----------------------------------------------------------------
// Wrapper shims: unpack [6]u64 args and call typed process functions
// ----------------------------------------------------------------

fn sys_exit_wrap(args: [6]u64) u64   { return proc.sys_exit(args[0]); }
fn sys_fork_wrap(_: [6]u64) u64      { return proc.sys_fork(); }
fn sys_exec_wrap(args: [6]u64) u64   { return proc.sys_exec(args[0], args[1]); }
fn sys_wait_wrap(args: [6]u64) u64   { return proc.sys_wait(args[0]); }
fn sys_getpid_wrap(_: [6]u64) u64    { return proc.sys_getpid(); }

test "dispatch unknown syscall returns ENOSYS" {
    init();
    const ret = dispatch(0xDEAD, .{0,0,0,0,0,0});
    try std.testing.expectEqual(ret, @bitCast(@as(i64, -38)));
}

test "dispatch getpid without current process returns 0" {
    init();
    // no current process set — sys_getpid returns 0
    const ret = dispatch(4, .{0,0,0,0,0,0});
    try std.testing.expectEqual(ret, 0);
}
