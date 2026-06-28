//! Magicore syscall table.
//! Syscalls are the ONLY user→kernel interface.
//! Every syscall is explicitly listed, typed, and auditable.
//! No undocumented back-channels. No ioctl sprawl.

const std = @import("std");

/// Syscall numbers — stable ABI once frozen
pub const Syscall = enum(u64) {
    // Process lifecycle
    exit     = 0,
    fork     = 1,
    exec     = 2,
    wait     = 3,
    getpid   = 4,

    // Memory
    mmap     = 10,
    munmap   = 11,
    mprotect = 12,

    // File I/O
    open     = 20,
    close    = 21,
    read     = 22,
    write    = 23,
    seek     = 24,
    stat     = 25,
    unlink   = 26,

    // IPC
    chan_create = 30,
    chan_send   = 31,
    chan_recv   = 32,
    chan_close  = 33,

    // Networking
    socket   = 40,
    bind     = 41,
    connect  = 42,
    listen   = 43,
    accept   = 44,
    sendmsg  = 45,
    recvmsg  = 46,

    // Time
    clock_get  = 50,
    clock_sleep = 51,

    // System info
    sysinfo   = 60,
    uname     = 61,

    _,  // unknown/invalid
};

/// Syscall handler function type
pub const Handler = *const fn (args: [6]u64) u64;

/// Syscall dispatch table
var table: std.EnumArray(Syscall, ?Handler) = std.EnumArray(Syscall, ?Handler).initFill(null);

pub fn init() void {
    // Handlers registered by subsystems at init time
    // e.g. table.set(.write, &fs.sys_write);
    // TODO: wire each subsystem's handlers
}

/// Main syscall entry — called from arch interrupt stub
pub fn dispatch(num: u64, args: [6]u64) u64 {
    const sc = std.meta.intToEnum(Syscall, num) catch return @bitCast(@as(i64, -1)); // ENOSYS
    const handler = table.get(sc) orelse return @bitCast(@as(i64, -1));
    return handler(args);
}

test "dispatch unknown syscall returns error" {
    init();
    const ret = dispatch(0xDEAD, .{0, 0, 0, 0, 0, 0});
    try std.testing.expectEqual(ret, @bitCast(@as(i64, -1)));
}
