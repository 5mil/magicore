//! Magicore Virtual Filesystem (VFS).
//! Clean vtable-driven design. No ioctl soup.
//! Every filesystem implements the same narrow interface.

const std = @import("std");

/// File open flags
pub const OpenFlags = packed struct {
    read: bool = false,
    write: bool = false,
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
    _pad: u27 = 0,
};

/// Directory entry
pub const DirEntry = struct {
    name: [256]u8,
    name_len: u8,
    inode: u64,
    kind: Kind,

    pub const Kind = enum { file, dir, symlink, device, socket, pipe };
};

/// File vtable — every fs implements this
pub const FileVtable = struct {
    read:  *const fn (ctx: *anyopaque, buf: []u8, offset: u64) anyerror!usize,
    write: *const fn (ctx: *anyopaque, buf: []const u8, offset: u64) anyerror!usize,
    close: *const fn (ctx: *anyopaque) void,
    stat:  *const fn (ctx: *anyopaque, out: *Stat) anyerror!void,
};

/// Filesystem vtable — mount point interface
pub const FsVtable = struct {
    open:   *const fn (ctx: *anyopaque, path: []const u8, flags: OpenFlags) anyerror!File,
    unlink: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
    mkdir:  *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
    readdir: *const fn (ctx: *anyopaque, path: []const u8, out: []DirEntry) anyerror!usize,
};

/// Open file handle
pub const File = struct {
    ctx: *anyopaque,
    vtable: *const FileVtable,

    pub fn read(self: File, buf: []u8, offset: u64) anyerror!usize {
        return self.vtable.read(self.ctx, buf, offset);
    }
    pub fn write(self: File, buf: []const u8, offset: u64) anyerror!usize {
        return self.vtable.write(self.ctx, buf, offset);
    }
    pub fn close(self: File) void {
        self.vtable.close(self.ctx);
    }
};

/// File metadata
pub const Stat = struct {
    inode: u64,
    size: u64,
    kind: DirEntry.Kind,
    mode: u32,
    uid: u32,
    gid: u32,
    atime: u64,
    mtime: u64,
    ctime: u64,
};

test "OpenFlags default" {
    const f = OpenFlags{};
    try std.testing.expect(!f.read);
    try std.testing.expect(!f.write);
}
