//! Magicore process model.
//! Owns: PID, AddressSpace, fd table (with VFS File handles), kstack.
//! fork/exec/exit/wait/getpid + open/close/read/write/stat.

const std      = @import("std");
const mm       = @import("../mm/mm.zig");
const vmm      = @import("../mm/vmm.zig");
const sched    = @import("../sched/sched.zig");
const vfs      = @import("../../fs/vfs.zig");
const vfs_mnt  = @import("../fs/vfs_mount.zig");
const console  = @import("../../lib/console.zig");

pub const Pid = u32;
pub const MAX_PID: Pid   = 65535;
pub const MAX_FDS: usize = 64;

// ----------------------------------------------------------------
// File descriptor
// ----------------------------------------------------------------

pub const Fd = struct {
    open:   bool      = false,
    offset: u64       = 0,
    flags:  u32       = 0,
    file:   ?vfs.File = null, // null only for closed fds
};

// ----------------------------------------------------------------
// Process control block
// ----------------------------------------------------------------

pub const ProcessState = enum { running, blocked, zombie };

pub const Process = struct {
    pid:       Pid,
    ppid:      Pid,
    state:     ProcessState,
    exit_code: i32,
    as:        vmm.AddressSpace,
    fds:       [MAX_FDS]Fd,
    kstack:    mm.PhysAddr,
    rsp:       u64,
    rip:       u64,

    pub fn deinit(self: *Process) void {
        // Close all open file descriptors
        for (&self.fds) |*fd| {
            if (fd.open) {
                if (fd.file) |f| f.close();
                fd.open = false;
            }
        }
        self.as.deinit();
        if (self.kstack != 0) mm.freePage(self.kstack);
    }

    /// Allocate the next free fd index, or null if table is full
    fn allocFd(self: *Process) ?usize {
        for (&self.fds, 0..) |*fd, i| {
            if (!fd.open) return i;
        }
        return null;
    }
};

// ----------------------------------------------------------------
// Process table
// ----------------------------------------------------------------

var ptable: [MAX_PID + 1]?*Process = [_]?*Process{null} ** (MAX_PID + 1);
var next_pid: Pid = 1;
pub var current: ?*Process = null;

pub fn init() void {
    console.print("[proc] process table ready (max {} processes)\n", .{MAX_PID});
}

fn allocPid() error{PidExhausted}!Pid {
    var tries: usize = 0;
    while (tries < MAX_PID) : (tries += 1) {
        const pid = next_pid;
        next_pid = if (pid >= MAX_PID) 1 else pid + 1;
        if (ptable[pid] == null) return pid;
    }
    return error.PidExhausted;
}

fn allocProcess(pid: Pid, ppid: Pid) error{OutOfMemory}!*Process {
    const p = try mm.kernel_allocator.create(Process);
    const kstack = try mm.buddy_alloc.alloc(0);
    p.* = .{
        .pid       = pid,
        .ppid      = ppid,
        .state     = .running,
        .exit_code = 0,
        .as        = try vmm.AddressSpace.init(mm.kernel_allocator, mm.buddy_alloc.hhdm_offset),
        .fds       = [_]Fd{.{}} ** MAX_FDS,
        .kstack    = kstack,
        .rsp       = 0,
        .rip       = 0,
    };
    // Wire stdio: fd0=stdin, fd1=stdout, fd2=stderr
    p.fds[0] = .{ .open=true, .file=vfs_mnt.stdout_file, .flags=0, .offset=0 }; // stdin (UART read)
    p.fds[1] = .{ .open=true, .file=vfs_mnt.stdout_file, .flags=0, .offset=0 }; // stdout
    p.fds[2] = .{ .open=true, .file=vfs_mnt.stderr_file, .flags=0, .offset=0 }; // stderr
    return p;
}

// ----------------------------------------------------------------
// Process syscalls
// ----------------------------------------------------------------

pub fn sys_fork() u64 {
    const parent = current orelse return enoproc();
    const pid    = allocPid()   catch return enomem();
    const child  = allocProcess(pid, parent.pid) catch return enomem();
    for (parent.as.regions.items) |region| {
        child.as.mapRegion(region) catch {
            child.deinit();
            mm.kernel_allocator.destroy(child);
            return enomem();
        };
    }
    child.fds = parent.fds;
    ptable[pid] = child;
    console.print("[proc] fork pid={} -> child={}\n", .{ parent.pid, pid });
    return pid;
}

pub fn sys_exit(code: u64) u64 {
    const p = current orelse return enoproc();
    p.state     = .zombie;
    p.exit_code = @intCast(code & 0xFF);
    console.print("[proc] exit pid={} code={}\n", .{ p.pid, p.exit_code });
    return 0;
}

pub fn sys_wait(_: u64) u64 {
    const parent = current orelse return enoproc();
    for (ptable[1..]) |maybe| {
        const child = maybe orelse continue;
        if (child.ppid != parent.pid) continue;
        if (child.state != .zombie) continue;
        const cpid = child.pid;
        child.deinit();
        mm.kernel_allocator.destroy(child);
        ptable[cpid] = null;
        console.print("[proc] wait reaped pid={}\n", .{cpid});
        return cpid;
    }
    return @bitCast(@as(i64, -10)); // ECHILD
}

pub fn sys_getpid() u64 {
    const p = current orelse return 0;
    return p.pid;
}

pub fn sys_exec(elf_ptr: u64, elf_len: u64) u64 {
    const p = current orelse return enoproc();
    const region = p.as.find(elf_ptr) orelse return efault();
    if (!region.prot.read) return efault();
    const kvirt = mm.physToVirt(p.as.translate(elf_ptr) orelse return efault());
    const elf_bytes: []const u8 = @as([*]const u8, @ptrFromInt(kvirt))[0..elf_len];
    const entry = @import("elf.zig").load(&p.as, elf_bytes) catch |err| {
        console.print("[proc] exec failed: {}\n", .{err});
        return @bitCast(@as(i64, -8)); // ENOEXEC
    };
    p.rip = entry;
    console.print("[proc] exec pid={} entry=0x{X:0>16}\n", .{ p.pid, entry });
    return 0;
}

// ----------------------------------------------------------------
// File I/O syscalls
// ----------------------------------------------------------------

pub fn sys_open(path_ptr: u64, path_len: u64, flags_raw: u64) u64 {
    const p = current orelse return enoproc();
    const fdidx = p.allocFd() orelse return @bitCast(@as(i64, -24)); // EMFILE

    // Validate user pointer
    const kvirt = mm.physToVirt(p.as.translate(path_ptr) orelse return efault());
    const path: []const u8 = @as([*]const u8, @ptrFromInt(kvirt))[0..path_len];

    const flags = vfs.OpenFlags{
        .read  = (flags_raw & 1) != 0,
        .write = (flags_raw & 2) != 0,
        .create = (flags_raw & 4) != 0,
    };

    const file = vfs_mnt.open(path, flags) catch |err| {
        console.print("[proc] open({s}) failed: {}\n", .{ path, err });
        return @bitCast(@as(i64, -2)); // ENOENT
    };

    p.fds[fdidx] = .{ .open=true, .file=file, .offset=0, .flags=@intCast(flags_raw) };
    return @intCast(fdidx);
}

pub fn sys_close(fd: u64) u64 {
    const p = current orelse return enoproc();
    if (fd >= MAX_FDS) return ebadf();
    const fdp = &p.fds[@intCast(fd)];
    if (!fdp.open) return ebadf();
    if (fdp.file) |f| f.close();
    fdp.* = .{};
    return 0;
}

pub fn sys_read(fd: u64, buf_ptr: u64, count: u64) u64 {
    const p = current orelse return enoproc();
    if (fd >= MAX_FDS) return ebadf();
    const fdp = &p.fds[@intCast(fd)];
    if (!fdp.open) return ebadf();
    const file = fdp.file orelse return ebadf();

    // Validate user buffer pointer
    const kvirt = mm.physToVirt(p.as.translate(buf_ptr) orelse return efault());
    const buf: []u8 = @as([*]u8, @ptrFromInt(kvirt))[0..count];

    const n = file.read(buf, fdp.offset) catch return @bitCast(@as(i64, -5)); // EIO
    fdp.offset += n;
    return n;
}

pub fn sys_write(fd: u64, buf_ptr: u64, count: u64) u64 {
    const p = current orelse return enoproc();
    if (fd >= MAX_FDS) return ebadf();
    const fdp = &p.fds[@intCast(fd)];
    if (!fdp.open) return ebadf();
    const file = fdp.file orelse return ebadf();

    // Validate user buffer pointer
    const kvirt = mm.physToVirt(p.as.translate(buf_ptr) orelse return efault());
    const buf: []const u8 = @as([*]const u8, @ptrFromInt(kvirt))[0..count];

    const n = file.write(buf, fdp.offset) catch return @bitCast(@as(i64, -5)); // EIO
    fdp.offset += n;
    return n;
}

pub fn sys_stat(path_ptr: u64, path_len: u64, stat_ptr: u64) u64 {
    const p = current orelse return enoproc();
    const kvirt_path = mm.physToVirt(p.as.translate(path_ptr) orelse return efault());
    const path: []const u8 = @as([*]const u8, @ptrFromInt(kvirt_path))[0..path_len];

    const file = vfs_mnt.open(path, .{ .read=true }) catch return @bitCast(@as(i64, -2));
    defer file.close();

    const kvirt_stat = mm.physToVirt(p.as.translate(stat_ptr) orelse return efault());
    const stat: *vfs.Stat = @ptrFromInt(kvirt_stat);
    file.vtable.stat(file.ctx, stat) catch return @bitCast(@as(i64, -5));
    return 0;
}

// ----------------------------------------------------------------
// Error helpers (Linux errno negated)
// ----------------------------------------------------------------
inline fn enoproc() u64 { return @bitCast(@as(i64, -3));  } // ESRCH
inline fn enomem()  u64 { return @bitCast(@as(i64, -12)); } // ENOMEM
inline fn efault()  u64 { return @bitCast(@as(i64, -14)); } // EFAULT
inline fn ebadf()   u64 { return @bitCast(@as(i64, -9));  } // EBADF

// ----------------------------------------------------------------
// Tests
// ----------------------------------------------------------------

test "Pid wrap" {
    var pid: Pid = MAX_PID;
    pid = if (pid >= MAX_PID) 1 else pid + 1;
    try std.testing.expectEqual(pid, 1);
}

test "ProcessState zombie" {
    var s: ProcessState = .running;
    s = .zombie;
    try std.testing.expectEqual(s, .zombie);
}

test "Fd default closed" {
    const fd = Fd{};
    try std.testing.expect(!fd.open);
    try std.testing.expectEqual(fd.offset, 0);
    try std.testing.expect(fd.file == null);
}
