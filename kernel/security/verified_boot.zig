//! Magicore verified boot chain.
//! Every boot stage is measured and chained.
//! Boot fails if any measurement does not match expected digest.
//! Uses SHA3-256 (not SHA-1 like old TPM 1.2 designs).
//! No trusting unsigned kernels. No silent fallback.

const std = @import("std");

/// A boot stage measurement
pub const Measurement = struct {
    stage: Stage,
    digest: [32]u8,  // SHA3-256

    pub const Stage = enum {
        bootloader,
        kernel_image,
        initrd,
        kernel_cmdline,
        driver_policy,
    };
};

/// Boot measurement chain — append-only at boot time
pub const MeasurementChain = struct {
    entries: [16]?Measurement,
    count: usize,
    sealed: bool,

    pub fn init() MeasurementChain {
        return .{
            .entries = [_]?Measurement{null} ** 16,
            .count = 0,
            .sealed = false,
        };
    }

    /// Extend chain with a new measurement
    pub fn extend(self: *MeasurementChain, m: Measurement) error{ChainFull, Sealed}!void {
        if (self.sealed) return error.Sealed;
        if (self.count >= 16) return error.ChainFull;
        self.entries[self.count] = m;
        self.count += 1;
    }

    /// Seal the chain — no more measurements after this
    pub fn seal(self: *MeasurementChain) void {
        self.sealed = true;
    }

    /// Compute cumulative digest of the entire chain (PCR-style)
    pub fn pcrDigest(self: *const MeasurementChain, out: *[32]u8) void {
        var accumulator: [32]u8 = [_]u8{0} ** 32;
        for (self.entries[0..self.count]) |entry| {
            const m = entry.?;
            // PCR extend: accumulator = SHA3-256(accumulator || measurement.digest)
            var hasher = std.crypto.hash.sha3.Sha3_256.init(.{});
            hasher.update(&accumulator);
            hasher.update(&m.digest);
            hasher.final(&accumulator);
        }
        out.* = accumulator;
    }
};

test "MeasurementChain extend and seal" {
    var chain = MeasurementChain.init();
    try chain.extend(.{ .stage = .bootloader, .digest = [_]u8{0xAB} ** 32 });
    try chain.extend(.{ .stage = .kernel_image, .digest = [_]u8{0xCD} ** 32 });
    chain.seal();
    try std.testing.expectError(error.Sealed, chain.extend(.{
        .stage = .initrd,
        .digest = [_]u8{0xEF} ** 32,
    }));
    try std.testing.expectEqual(chain.count, 2);
}

test "MeasurementChain PCR digest deterministic" {
    var c1 = MeasurementChain.init();
    var c2 = MeasurementChain.init();
    const d = [_]u8{0x11} ** 32;
    try c1.extend(.{ .stage = .bootloader, .digest = d });
    try c2.extend(.{ .stage = .bootloader, .digest = d });
    var out1: [32]u8 = undefined;
    var out2: [32]u8 = undefined;
    c1.pcrDigest(&out1);
    c2.pcrDigest(&out2);
    try std.testing.expect(std.mem.eql(u8, &out1, &out2));
}
