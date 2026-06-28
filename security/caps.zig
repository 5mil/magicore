//! Magicore capability-based security model.
//! Every process has an explicit capability set.
//! No ambient authority. No setuid hack. No sudo magic.
//! Capabilities are unforgeable tokens — passed explicitly or inherited.

const std = @import("std");

/// Fine-grained capability flags
pub const Capability = enum(u64) {
    /// Read/write own process memory
    proc_mem        = 1 << 0,
    /// Create new processes
    proc_fork       = 1 << 1,
    /// Open files in allowed paths
    fs_read         = 1 << 2,
    fs_write        = 1 << 3,
    fs_create       = 1 << 4,
    fs_admin        = 1 << 5,
    /// Network: outbound connections
    net_connect     = 1 << 6,
    /// Network: bind/listen
    net_bind        = 1 << 7,
    /// Network: raw sockets
    net_raw         = 1 << 8,
    /// Hardware device access
    device_read     = 1 << 9,
    device_write    = 1 << 10,
    /// System administration
    sys_time        = 1 << 11,
    sys_mount       = 1 << 12,
    sys_module      = 1 << 13,
    sys_reboot      = 1 << 14,
    /// AI/model runtime
    ml_infer        = 1 << 15,
    ml_train        = 1 << 16,
    _,
};

/// A capability set — bitmask of granted capabilities
pub const CapSet = struct {
    bits: u64 = 0,

    pub fn grant(self: *CapSet, cap: Capability) void {
        self.bits |= @intFromEnum(cap);
    }

    pub fn revoke(self: *CapSet, cap: Capability) void {
        self.bits &= ~@intFromEnum(cap);
    }

    pub fn has(self: CapSet, cap: Capability) bool {
        return (self.bits & @intFromEnum(cap)) != 0;
    }

    pub fn subset(self: CapSet, other: CapSet) bool {
        return (self.bits & other.bits) == self.bits;
    }

    /// Empty capability set — no authority
    pub const empty = CapSet{ .bits = 0 };

    /// Full capability set — kernel/init only
    pub const full = CapSet{ .bits = std.math.maxInt(u64) };
};

test "CapSet grant/revoke/has" {
    var cs = CapSet.empty;
    cs.grant(.net_connect);
    try std.testing.expect(cs.has(.net_connect));
    cs.revoke(.net_connect);
    try std.testing.expect(!cs.has(.net_connect));
}

test "CapSet subset" {
    var a = CapSet.empty;
    var b = CapSet.empty;
    a.grant(.fs_read);
    b.grant(.fs_read);
    b.grant(.fs_write);
    try std.testing.expect(a.subset(b));
    try std.testing.expect(!b.subset(a));
}
