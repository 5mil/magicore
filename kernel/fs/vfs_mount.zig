//! Magicore VFS mount table.
//! Maintains the list of mounted filesystems and resolves paths to inodes.
//!
//! Mount table is a flat array — no more than MAX_MOUNTS active mounts.
//! Path resolution: longest prefix match.
//! Special files:
//!   fd 0 = stdin  (read  from UART)
//!   fd 1 = stdout (write to UART/console)
//!   fd 2 = stderr (write to UART/console)

const std     = @import("std");
const vfs     = @import("../../fs/vfs.zig");
const uart    = @import("../../drivers/uart16550.zig");
const console = @import("../../lib/console.zig");
const ramfs_m = @import("ramfs.zig");

pub const MAX_MOUNTS: usize = 16;

pub const Mount = struct {
    path:   []const u8,
    ctx:    *anyopaque,
    vtable: *const vfs.FsVtable,
    active: bool,
};

var mounts: [MAX_MOUNTS]Mount = undefined;
var mount_count: usize = 0;

/// Root ramfs — always present
pub var root_fs: ramfs_m.RamFs = undefined;
pub var root_fs_ready: bool = false;

// ----------------------------------------------------------------
// Stdout/stderr special file (writes to UART console)
// ----------------------------------------------------------------

const StdoutFile = struct {
    fn writeFn(_ctx: *anyopaque, buf: []const u8, _offset: u64) anyerror!usize {
        _ = _ctx;
        if (uart.kernel_uart_ready) {
            uart.kernel_uart.writeStr(buf);
        }
        return buf.len;
    }
    fn readFn(_ctx: *anyopaque, buf: []u8, _offset: u64) anyerror!usize {
        _ = _ctx;
        if (!uart.kernel_uart_ready) return 0;
        var n: usize = 0;
        while (n < buf.len) : (n += 1) {
            buf[n] = uart.kernel_uart.tryReadByte() orelse break;
        }
        return n;
    }
    fn closeFn(_ctx: *anyopaque) void { _ = _ctx; }
    fn statFn(_ctx: *anyopaque, out: *vfs.Stat) anyerror!void {
        _ = _ctx;
        out.* = std.mem.zeroes(vfs.Stat);
        out.kind = .device;
    }
    const vtable = vfs.FileVtable{
        .read  = readFn,
        .write = writeFn,
        .close = closeFn,
        .stat  = statFn,
    };
};

var stdout_ctx: u8 = 0; // dummy context pointer target

pub const stdout_file = vfs.File{
    .ctx    = @ptrCast(&stdout_ctx),
    .vtable = &StdoutFile.vtable,
};
pub const stderr_file = vfs.File{
    .ctx    = @ptrCast(&stdout_ctx),
    .vtable = &StdoutFile.vtable,
};

// ----------------------------------------------------------------
// RamFs VFS vtable adapter
// ----------------------------------------------------------------

fn ramfsOpenFn(ctx: *anyopaque, path: []const u8, flags: vfs.OpenFlags) anyerror!vfs.File {
    _ = flags;
    const fs: *ramfs_m.RamFs = @ptrCast(@alignCast(ctx));
    if (!fs.exists(path)) return error.NotFound;
    // Allocate a RamFsFileCtx on the kernel heap
    const file_ctx = try @import("../../kernel/mm/mm.zig").kernel_allocator.create(RamFsFileCtx);
    file_ctx.* = .{ .fs = fs, .path = path, .offset = 0 };
    return vfs.File{ .ctx = file_ctx, .vtable = &ramfs_file_vtable };
}

fn ramfsUnlinkFn(ctx: *anyopaque, path: []const u8) anyerror!void {
    const fs: *ramfs_m.RamFs = @ptrCast(@alignCast(ctx));
    try fs.unlink(path);
}

fn ramfsMkdirFn(_ctx: *anyopaque, _path: []const u8) anyerror!void {
    _ = _ctx; _ = _path;
    return error.NotSupported;
}

fn ramfsReaddirFn(_ctx: *anyopaque, _path: []const u8, _out: []vfs.DirEntry) anyerror!usize {
    _ = _ctx; _ = _path; _ = _out;
    return 0;
}

pub const ramfs_vtable = vfs.FsVtable{
    .open    = ramfsOpenFn,
    .unlink  = ramfsUnlinkFn,
    .mkdir   = ramfsMkdirFn,
    .readdir = ramfsReaddirFn,
};

// ----------------------------------------------------------------
// RamFs per-file context (open file state)
// ----------------------------------------------------------------

const RamFsFileCtx = struct {
    fs:     *ramfs_m.RamFs,
    path:   []const u8,
    offset: u64,
};

fn ramfsFileRead(ctx: *anyopaque, buf: []u8, offset: u64) anyerror!usize {
    const fc: *RamFsFileCtx = @ptrCast(@alignCast(ctx));
    return fc.fs.read(fc.path, buf, offset) catch |err| switch (err) {
        error.NotFound   => error.NotFound,
        error.OutOfBounds => @as(usize, 0),
    };
}

fn ramfsFileWrite(ctx: *anyopaque, buf: []const u8, _offset: u64) anyerror!usize {
    const fc: *RamFsFileCtx = @ptrCast(@alignCast(ctx));
    try fc.fs.write(fc.path, buf);
    return buf.len;
}

fn ramfsFileClose(ctx: *anyopaque) void {
    const fc: *RamFsFileCtx = @ptrCast(@alignCast(ctx));
    @import("../../kernel/mm/mm.zig").kernel_allocator.destroy(fc);
}

fn ramfsFileStat(ctx: *anyopaque, out: *vfs.Stat) anyerror!void {
    const fc: *RamFsFileCtx = @ptrCast(@alignCast(ctx));
    var buf: [1]u8 = undefined;
    const sz = fc.fs.read(fc.path, &buf, 0) catch 0;
    out.* = std.mem.zeroes(vfs.Stat);
    out.kind = .file;
    out.size = sz;
}

const ramfs_file_vtable = vfs.FileVtable{
    .read  = ramfsFileRead,
    .write = ramfsFileWrite,
    .close = ramfsFileClose,
    .stat  = ramfsFileStat,
};

// ----------------------------------------------------------------
// Mount table management
// ----------------------------------------------------------------

pub fn init(allocator: std.mem.Allocator) void {
    root_fs = ramfs_m.RamFs.init(allocator);
    root_fs_ready = true;
    mounts[0] = .{
        .path   = "/",
        .ctx    = &root_fs,
        .vtable = &ramfs_vtable,
        .active = true,
    };
    mount_count = 1;
    console.print("[vfs] root ramfs mounted at /\n", .{});
}

/// Open a file by path. Returns a VFS File handle.
pub fn open(path: []const u8, flags: vfs.OpenFlags) anyerror!vfs.File {
    // Find longest-prefix matching mount
    var best: ?*Mount = null;
    var best_len: usize = 0;
    for (mounts[0..mount_count]) |*m| {
        if (!m.active) continue;
        if (std.mem.startsWith(u8, path, m.path) and m.path.len > best_len) {
            best = m;
            best_len = m.path.len;
        }
    }
    const m = best orelse return error.NotFound;
    const rel = if (best_len == 1) path else path[best_len..];
    return m.vtable.open(m.ctx, rel, flags);
}

test "stdout_file write does not crash" {
    // uart not initialized in host test — write should be a no-op
    _ = stdout_file.write("hi\n", 0) catch {};
}
