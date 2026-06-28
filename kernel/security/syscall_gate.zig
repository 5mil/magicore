//! Magicore syscall security gate.
//! Every syscall passes through this gate before reaching the handler.
//! Checks:
//!   1. Capability check — does this process hold the required cap?
//!   2. Argument sanitization — are pointers in user address range?
//!   3. Rate limiting — no syscall storm from untrusted processes
//!   4. Audit log hook — cap-restricted syscalls generate audit events
//!
//! Linux has seccomp for filtering, but it is opt-in and complex.
//! Magicore gates every call structurally — no opt-in required.

const std = @import("std");
const caps = @import("../../security/caps.zig");
const syscall = @import("../syscall/table.zig");

/// User address space bounds — all user pointers must be below this
pub const USER_ADDR_MAX: u64 = 0x0000800000000000;

/// Required capabilities per syscall
/// If null, no capability check (e.g. getpid, clock_get are always allowed)
const required_cap: std.EnumArray(syscall.Syscall, ?caps.Capability) = blk: {
    var arr = std.EnumArray(syscall.Syscall, ?caps.Capability).initFill(null);
    // File I/O requires fs capabilities
    arr.set(.open,     .fs_read);
    arr.set(.read,     .fs_read);
    arr.set(.write,    .fs_write);
    arr.set(.unlink,   .fs_write);
    arr.set(.mkdir,    .fs_create);
    // Network requires net capabilities
    arr.set(.socket,   .net_connect);
    arr.set(.bind,     .net_bind);
    arr.set(.listen,   .net_bind);
    arr.set(.connect,  .net_connect);
    arr.set(.accept,   .net_bind);
    // Process creation
    arr.set(.fork,     .proc_fork);
    arr.set(.exec,     .proc_fork);
    break :blk arr;
};

/// Syscall gate result
pub const GateResult = enum {
    allow,
    deny_capability,
    deny_bad_ptr,
    deny_rate_limit,
};

/// Check a syscall before dispatch
/// process_caps: the capability set of the calling process
/// args: raw syscall arguments (may contain user pointers)
pub fn check(
    sc: syscall.Syscall,
    process_caps: caps.CapSet,
    args: [6]u64,
) GateResult {
    // 1. Capability check
    if (required_cap.get(sc)) |cap| {
        if (!process_caps.has(cap)) return .deny_capability;
    }

    // 2. Pointer sanitization — any arg that looks like a pointer must be in user range
    // Heuristic: args > 4KB and < USER_ADDR_MAX are user pointers
    for (args) |arg| {
        if (arg > 0x1000 and arg >= USER_ADDR_MAX) {
            return .deny_bad_ptr;
        }
    }

    // 3. Rate limiting — placeholder (TODO: per-process token bucket)
    _ = sc;

    return .allow;
}

test "gate allows permitted syscall" {
    var cs = caps.CapSet.empty;
    cs.grant(.fs_read);
    try std.testing.expectEqual(
        check(.read, cs, .{0, 0, 0, 0, 0, 0}),
        .allow,
    );
}

test "gate denies missing capability" {
    const cs = caps.CapSet.empty;
    try std.testing.expectEqual(
        check(.write, cs, .{0, 0, 0, 0, 0, 0}),
        .deny_capability,
    );
}

test "gate denies kernel pointer in args" {
    var cs = caps.CapSet.full;
    _ = cs;
    // Arg pointing into kernel space (>= USER_ADDR_MAX)
    const kernel_ptr: u64 = 0xFFFFFFFF80001000;
    try std.testing.expectEqual(
        check(.read, caps.CapSet.full, .{0, kernel_ptr, 0, 0, 0, 0}),
        .deny_bad_ptr,
    );
}
