//! Magicore ramfs — in-memory filesystem.
//! First real filesystem implementation.
//! Backed by a flat hash map of path → file data.
//! No persistence. Used for initrd, /tmp, early boot.
//! Implements FsVtable from vfs.zig.

const std = @import("std");
const vfs = @import("../../fs/vfs.zig");

pub const RamFs = struct {
    files: std.StringHashMap(File),
    allocator: std.mem.Allocator,

    const File = struct {
        data: std.ArrayList(u8),
        mode: u32,
        uid: u32,
        gid: u32,
    };

    pub fn init(allocator: std.mem.Allocator) RamFs {
        return .{
            .files = std.StringHashMap(File).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RamFs) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.data.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.files.deinit();
    }

    /// Create or overwrite a file
    pub fn write(self: *RamFs, path: []const u8, data: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        var file = File{
            .data = std.ArrayList(u8).init(self.allocator),
            .mode = 0o644,
            .uid = 0,
            .gid = 0,
        };
        try file.data.appendSlice(data);
        try self.files.put(owned_path, file);
    }

    /// Read a file's contents
    pub fn read(self: *RamFs, path: []const u8, buf: []u8, offset: u64) error{NotFound, OutOfBounds}!usize {
        const file = self.files.get(path) orelse return error.NotFound;
        if (offset >= file.data.items.len) return 0;
        const available = file.data.items.len - @as(usize, @intCast(offset));
        const n = @min(available, buf.len);
        @memcpy(buf[0..n], file.data.items[@intCast(offset)..][0..n]);
        return n;
    }

    /// Check if a path exists
    pub fn exists(self: *RamFs, path: []const u8) bool {
        return self.files.contains(path);
    }

    /// Delete a file
    pub fn unlink(self: *RamFs, path: []const u8) error{NotFound}!void {
        const entry = self.files.fetchRemove(path) orelse return error.NotFound;
        entry.value.data.deinit();
    }
};

test "RamFs write and read" {
    var fs = RamFs.init(std.testing.allocator);
    defer fs.deinit();
    try fs.write("/hello", "world");
    var buf: [16]u8 = undefined;
    const n = try fs.read("/hello", &buf, 0);
    try std.testing.expectEqualStrings("world", buf[0..n]);
}

test "RamFs not found" {
    var fs = RamFs.init(std.testing.allocator);
    defer fs.deinit();
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.NotFound, fs.read("/nope", &buf, 0));
}

test "RamFs unlink" {
    var fs = RamFs.init(std.testing.allocator);
    defer fs.deinit();
    try fs.write("/x", "data");
    try std.testing.expect(fs.exists("/x"));
    try fs.unlink("/x");
    try std.testing.expect(!fs.exists("/x"));
}

test "RamFs offset read" {
    var fs = RamFs.init(std.testing.allocator);
    defer fs.deinit();
    try fs.write("/abc", "0123456789");
    var buf: [4]u8 = undefined;
    const n = try fs.read("/abc", &buf, 5);
    try std.testing.expectEqualStrings("5678", buf[0..n]);
}
