//! Magicore TCP state machine.
//! Clean enum-driven RFC 793 state machine.
//! No implicit transitions. Every event is explicit.
//! Linux TCP has ~15,000 lines across multiple files with
//! state transitions scattered through the code.
//! Magicore's state machine is a single typed dispatch table.

const std = @import("std");

/// RFC 793 TCP states
pub const TcpState = enum {
    closed,
    listen,
    syn_sent,
    syn_received,
    established,
    fin_wait_1,
    fin_wait_2,
    close_wait,
    closing,
    last_ack,
    time_wait,
};

/// TCP events that trigger transitions
pub const TcpEvent = enum {
    passive_open,   // listen()
    active_open,    // connect()
    send_syn,
    recv_syn,
    recv_syn_ack,
    send_ack,
    recv_ack,
    close,          // app calls close()
    send_fin,
    recv_fin,
    recv_fin_ack,
    timeout,
    rst,
};

/// TCP control block
pub const TcpCb = struct {
    state: TcpState,
    local_seq: u32,
    remote_seq: u32,
    window: u16,
    mss: u16,

    /// Window scaling factor (RFC 7323)
    wscale: u8,
    /// Congestion window (bytes)
    cwnd: u32,
    /// Slow start threshold
    ssthresh: u32,
    /// RTT estimate (microseconds)
    rtt_us: u32,

    pub fn init() TcpCb {
        return .{
            .state = .closed,
            .local_seq = 0,
            .remote_seq = 0,
            .window = 65535,
            .mss = 1460,
            .wscale = 0,
            .cwnd = 10 * 1460, // 10 MSS initial window (RFC 6928)
            .ssthresh = 65535,
            .rtt_us = 0,
        };
    }

    /// Apply a TCP event — returns new state or error if invalid transition
    pub fn transition(self: *TcpCb, event: TcpEvent) error{InvalidTransition}!TcpState {
        const new_state: TcpState = switch (self.state) {
            .closed => switch (event) {
                .passive_open => .listen,
                .active_open  => .syn_sent,
                else          => return error.InvalidTransition,
            },
            .listen => switch (event) {
                .recv_syn => .syn_received,
                .close    => .closed,
                else      => return error.InvalidTransition,
            },
            .syn_sent => switch (event) {
                .recv_syn_ack => .established,
                .recv_syn     => .syn_received,
                .close        => .closed,
                .timeout      => .closed,
                .rst          => .closed,
                else          => return error.InvalidTransition,
            },
            .syn_received => switch (event) {
                .recv_ack => .established,
                .close    => .fin_wait_1,
                .rst      => .closed,
                else      => return error.InvalidTransition,
            },
            .established => switch (event) {
                .close    => .fin_wait_1,
                .recv_fin => .close_wait,
                .rst      => .closed,
                else      => return error.InvalidTransition,
            },
            .fin_wait_1 => switch (event) {
                .recv_ack     => .fin_wait_2,
                .recv_fin     => .closing,
                .recv_fin_ack => .time_wait,
                else          => return error.InvalidTransition,
            },
            .fin_wait_2 => switch (event) {
                .recv_fin => .time_wait,
                else      => return error.InvalidTransition,
            },
            .close_wait => switch (event) {
                .close => .last_ack,
                else   => return error.InvalidTransition,
            },
            .closing => switch (event) {
                .recv_ack => .time_wait,
                else      => return error.InvalidTransition,
            },
            .last_ack => switch (event) {
                .recv_ack => .closed,
                else      => return error.InvalidTransition,
            },
            .time_wait => switch (event) {
                .timeout => .closed,
                else     => return error.InvalidTransition,
            },
        };
        self.state = new_state;
        return new_state;
    }
};

test "TCP three-way handshake (client)" {
    var cb = TcpCb.init();
    try std.testing.expectEqual(try cb.transition(.active_open), .syn_sent);
    try std.testing.expectEqual(try cb.transition(.recv_syn_ack), .established);
}

test "TCP passive open" {
    var cb = TcpCb.init();
    try std.testing.expectEqual(try cb.transition(.passive_open), .listen);
    try std.testing.expectEqual(try cb.transition(.recv_syn), .syn_received);
    try std.testing.expectEqual(try cb.transition(.recv_ack), .established);
}

test "TCP invalid transition returns error" {
    var cb = TcpCb.init();
    try std.testing.expectError(error.InvalidTransition, cb.transition(.recv_fin));
}

test "TCP close from established" {
    var cb = TcpCb.init();
    _ = try cb.transition(.active_open);
    _ = try cb.transition(.recv_syn_ack);
    try std.testing.expectEqual(try cb.transition(.close), .fin_wait_1);
}
