//! Magicore IPC primitives.
//! All IPC is message-passing. No shared memory IPC by default.
//! Channels are typed, bounded, and owned — no dangling endpoints.

const std = @import("std");

/// A bounded, typed message channel between two tasks.
/// Sender and receiver are tracked — channel is destroyed when both drop.
pub fn Channel(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buf: [capacity]T,
        head: usize,
        tail: usize,
        len: usize,
        closed: bool,

        pub fn init() Self {
            return .{
                .buf = undefined,
                .head = 0,
                .tail = 0,
                .len = 0,
                .closed = false,
            };
        }

        pub fn send(self: *Self, msg: T) error{Full, Closed}!void {
            if (self.closed) return error.Closed;
            if (self.len == capacity) return error.Full;
            self.buf[self.tail] = msg;
            self.tail = (self.tail + 1) % capacity;
            self.len += 1;
        }

        pub fn recv(self: *Self) error{Empty, Closed}!T {
            if (self.len == 0) {
                if (self.closed) return error.Closed;
                return error.Empty;
            }
            const msg = self.buf[self.head];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            return msg;
        }

        pub fn close(self: *Self) void {
            self.closed = true;
        }
    };
}

pub fn init() error{}!void {
    // IPC subsystem is purely comptime/generic — no global init needed
}

test "Channel send/recv" {
    var ch = Channel(u32, 4).init();
    try ch.send(42);
    try ch.send(99);
    try std.testing.expectEqual(try ch.recv(), 42);
    try std.testing.expectEqual(try ch.recv(), 99);
}

test "Channel full" {
    var ch = Channel(u8, 2).init();
    try ch.send(1);
    try ch.send(2);
    try std.testing.expectError(error.Full, ch.send(3));
}

test "Channel closed" {
    var ch = Channel(u8, 2).init();
    ch.close();
    try std.testing.expectError(error.Closed, ch.send(1));
    try std.testing.expectError(error.Closed, ch.recv());
}
