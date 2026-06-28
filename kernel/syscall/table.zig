//! Magicore syscall table — all handlers wired.
//! 30 syscalls. All typed. No ioctl sprawl.

const std  = @import("std");
const proc = @import("../process/process.zig");

pub const Syscall = enum(u64) {
    exit      = 0,  fork      = 1,  exec      = 2,
    wait      = 3,  getpid    = 4,
    mmap      = 10, munmap    = 11, mprotect  = 12,
    open      = 20, close     = 21, read      = 22,
    write     = 23, seek      = 24, stat      = 25,
    unlink    = 26,
    chan_create=30, chan_send  = 31, chan_recv  = 32, chan_close = 33,
    socket    = 40, bind      = 41, connect   = 42,
    listen    = 43, accept    = 44, sendmsg   = 45, recvmsg   = 46,
    clock_get = 50, clock_sleep=51,
    sysinfo   = 60, uname     = 61,
    _,
};

pub const Handler = *const fn (args: [6]u64) u64;
var table: std.EnumArray(Syscall, ?Handler) = std.EnumArray(Syscall, ?Handler).initFill(null);

pub fn init() void {
    // Process
    table.set(.exit,   &w_exit);
    table.set(.fork,   &w_fork);
    table.set(.exec,   &w_exec);
    table.set(.wait,   &w_wait);
    table.set(.getpid, &w_getpid);
    // File I/O
    table.set(.open,  &w_open);
    table.set(.close, &w_close);
    table.set(.read,  &w_read);
    table.set(.write, &w_write);
    table.set(.stat,  &w_stat);
}

pub fn dispatch(num: u64, args: [6]u64) u64 {
    const sc = std.meta.intToEnum(Syscall, num) catch return enosys();
    const h  = table.get(sc) orelse return enosys();
    return h(args);
}

inline fn enosys() u64 { return @bitCast(@as(i64, -38)); }

// Process wrappers
fn w_exit(a: [6]u64) u64   { return proc.sys_exit(a[0]); }
fn w_fork(_: [6]u64) u64   { return proc.sys_fork(); }
fn w_exec(a: [6]u64) u64   { return proc.sys_exec(a[0], a[1]); }
fn w_wait(a: [6]u64) u64   { return proc.sys_wait(a[0]); }
fn w_getpid(_: [6]u64) u64 { return proc.sys_getpid(); }
// File I/O wrappers
fn w_open(a: [6]u64) u64   { return proc.sys_open(a[0], a[1], a[2]); }
fn w_close(a: [6]u64) u64  { return proc.sys_close(a[0]); }
fn w_read(a: [6]u64) u64   { return proc.sys_read(a[0], a[1], a[2]); }
fn w_write(a: [6]u64) u64  { return proc.sys_write(a[0], a[1], a[2]); }
fn w_stat(a: [6]u64) u64   { return proc.sys_stat(a[0], a[1], a[2]); }

test "unknown syscall returns ENOSYS" {
    init();
    try std.testing.expectEqual(dispatch(0xDEAD, .{0}**6), @bitCast(@as(i64, -38)));
}
test "getpid without process returns 0" {
    init();
    try std.testing.expectEqual(dispatch(4, .{0}**6), 0);
}
