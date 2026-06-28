//! Magicore networking — socket abstraction.
//! Clean protocol vtable design.
//! No ioctl. No mysterious flag combinations.
//! IPv4, IPv6, Unix domain sockets via same interface.

const std = @import("std");

pub const Domain = enum { ipv4, ipv6, unix };
pub const SockType = enum { stream, dgram, raw };
pub const Protocol = enum { tcp, udp, icmp, raw };

/// Socket address
pub const SockAddr = union(Domain) {
    ipv4: struct { addr: [4]u8, port: u16 },
    ipv6: struct { addr: [16]u8, port: u16 },
    unix: struct { path: [108]u8 },
};

/// Socket vtable — each protocol stack implements this
pub const SocketVtable = struct {
    bind:    *const fn (ctx: *anyopaque, addr: SockAddr) anyerror!void,
    connect: *const fn (ctx: *anyopaque, addr: SockAddr) anyerror!void,
    listen:  *const fn (ctx: *anyopaque, backlog: u32) anyerror!void,
    accept:  *const fn (ctx: *anyopaque) anyerror!Socket,
    send:    *const fn (ctx: *anyopaque, buf: []const u8, flags: u32) anyerror!usize,
    recv:    *const fn (ctx: *anyopaque, buf: []u8, flags: u32) anyerror!usize,
    close:   *const fn (ctx: *anyopaque) void,
};

/// Socket handle
pub const Socket = struct {
    ctx: *anyopaque,
    vtable: *const SocketVtable,
    domain: Domain,
    kind: SockType,

    pub fn bind(self: Socket, addr: SockAddr) anyerror!void {
        return self.vtable.bind(self.ctx, addr);
    }
    pub fn connect(self: Socket, addr: SockAddr) anyerror!void {
        return self.vtable.connect(self.ctx, addr);
    }
    pub fn send(self: Socket, buf: []const u8) anyerror!usize {
        return self.vtable.send(self.ctx, buf, 0);
    }
    pub fn recv(self: Socket, buf: []u8) anyerror!usize {
        return self.vtable.recv(self.ctx, buf, 0);
    }
    pub fn close(self: Socket) void {
        self.vtable.close(self.ctx);
    }
};

test "SockAddr ipv4" {
    const addr = SockAddr{ .ipv4 = .{ .addr = .{127, 0, 0, 1}, .port = 8080 } };
    try std.testing.expectEqual(addr.ipv4.port, 8080);
}
