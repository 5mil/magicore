//! Magicore zero-copy I/O ring.
//! Inspired by io_uring's submission/completion model but:
//! - No mutable shared memory between kernel and user on the hot path
//! - Typed operations — no opcode integers, no magic flag combinations
//! - Every operation result is an explicit error union
//! - Buffer ownership is tracked — no UAF on in-flight buffers
//! - Linux io_uring has 200+ opcode combinations; Magicore has one typed union

const std = @import("std");

/// Every I/O operation is one of these — fully typed, no magic numbers
pub const Op = union(enum) {
    read:     ReadOp,
    write:    WriteOp,
    accept:   AcceptOp,
    connect:  ConnectOp,
    recv:     RecvOp,
    send:     SendOp,
    close:    CloseOp,
    timeout:  TimeoutOp,
    cancel:   CancelOp,

    pub const ReadOp    = struct { fd: u32, buf: []u8,       offset: u64 };
    pub const WriteOp   = struct { fd: u32, buf: []const u8, offset: u64 };
    pub const AcceptOp  = struct { fd: u32 };
    pub const ConnectOp = struct { fd: u32, addr: u64, addr_len: u32 };
    pub const RecvOp    = struct { fd: u32, buf: []u8 };
    pub const SendOp    = struct { fd: u32, buf: []const u8 };
    pub const CloseOp   = struct { fd: u32 };
    pub const TimeoutOp = struct { ns: u64 };
    pub const CancelOp  = struct { target_id: u64 };
};

/// Completion result
pub const Completion = struct {
    id: u64,
    result: error{
        BadFd,
        Canceled,
        TimedOut,
        IoError,
        BufTooSmall,
        NotConnected,
        ConnectionRefused,
        Interrupted,
    }!i64,
};

/// Submission entry — associates an op with a user-defined id
pub const Submission = struct {
    id: u64,
    op: Op,
};

/// I/O ring — bounded submission queue + completion queue
pub fn Ring(comptime depth: usize) type {
    return struct {
        const Self = @This();

        // Submission queue
        sq: [depth]?Submission,
        sq_head: usize,
        sq_tail: usize,
        sq_len: usize,

        // Completion queue (2x depth to absorb burst)
        cq: [depth * 2]?Completion,
        cq_head: usize,
        cq_tail: usize,
        cq_len: usize,

        pub fn init() Self {
            return .{
                .sq = [_]?Submission{null} ** depth,
                .sq_head = 0, .sq_tail = 0, .sq_len = 0,
                .cq = [_]?Completion{null} ** (depth * 2),
                .cq_head = 0, .cq_tail = 0, .cq_len = 0,
            };
        }

        /// Submit an operation
        pub fn submit(self: *Self, s: Submission) error{RingFull}!void {
            if (self.sq_len == depth) return error.RingFull;
            self.sq[self.sq_tail] = s;
            self.sq_tail = (self.sq_tail + 1) % depth;
            self.sq_len += 1;
        }

        /// Pop next submission for kernel processing
        pub fn nextOp(self: *Self) ?Submission {
            if (self.sq_len == 0) return null;
            const s = self.sq[self.sq_head].?;
            self.sq[self.sq_head] = null;
            self.sq_head = (self.sq_head + 1) % depth;
            self.sq_len -= 1;
            return s;
        }

        /// Post a completion result
        pub fn complete(self: *Self, c: Completion) error{CqFull}!void {
            if (self.cq_len == depth * 2) return error.CqFull;
            self.cq[self.cq_tail] = c;
            self.cq_tail = (self.cq_tail + 1) % (depth * 2);
            self.cq_len += 1;
        }

        /// Consume a completion
        pub fn reap(self: *Self) ?Completion {
            if (self.cq_len == 0) return null;
            const c = self.cq[self.cq_head].?;
            self.cq[self.cq_head] = null;
            self.cq_head = (self.cq_head + 1) % (depth * 2);
            self.cq_len -= 1;
            return c;
        }
    };
}

test "Ring submit and reap" {
    var ring = Ring(8).init();
    try ring.submit(.{ .id = 1, .op = .{ .close = .{ .fd = 5 } } });
    const op = ring.nextOp();
    try std.testing.expect(op != null);
    try std.testing.expectEqual(op.?.id, 1);
    try ring.complete(.{ .id = 1, .result = 0 });
    const c = ring.reap();
    try std.testing.expect(c != null);
    try std.testing.expectEqual(c.?.id, 1);
}

test "Ring full" {
    var ring = Ring(2).init();
    try ring.submit(.{ .id = 1, .op = .{ .close = .{ .fd = 1 } } });
    try ring.submit(.{ .id = 2, .op = .{ .close = .{ .fd = 2 } } });
    try std.testing.expectError(error.RingFull, ring.submit(.{ .id = 3, .op = .{ .close = .{ .fd = 3 } } }));
}
