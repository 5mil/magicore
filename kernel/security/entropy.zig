//! Magicore entropy source.
//! Uses RDRAND (hardware RNG) as primary source on x86_64.
//! Falls back to RDTSC+seed mixing if RDRAND unavailable.
//! ChaCha20 CSPRNG seeded at boot for all kernel random needs.
//! Key insight: Linux /dev/random has had design debates for 30+ years.
//! Magicore makes it simple: RDRAND → ChaCha20 → done.

const std = @import("std");

/// Read one 64-bit value from RDRAND.
/// Returns error if RDRAND not available or CF=0 (retry exhausted).
fn rdrand() error{Unavailable}!u64 {
    // Inline assembly for RDRAND on x86_64
    var val: u64 = 0;
    var ok: u8 = 0;
    asm volatile (
        \\rdrand %[val]
        \\setc %[ok]
        : [val] "=r" (val),
          [ok] "=r" (ok)
        :
        : "cc"
    );
    if (ok == 0) return error.Unavailable;
    return val;
}

/// ChaCha20 state (256-bit key + 128-bit nonce/counter)
pub const ChaCha20State = struct {
    state: [16]u32,

    pub fn init(seed: [32]u8) ChaCha20State {
        var s: ChaCha20State = undefined;
        // ChaCha20 constants
        s.state[0] = 0x61707865;
        s.state[1] = 0x3320646e;
        s.state[2] = 0x79622d32;
        s.state[3] = 0x6b206574;
        // Key (256-bit)
        for (0..8) |i| {
            s.state[4 + i] = std.mem.readInt(u32, seed[i*4..][0..4], .little);
        }
        // Counter
        s.state[12] = 0;
        s.state[13] = 0;
        // Nonce
        s.state[14] = 0xDEADBEEF;
        s.state[15] = 0xCAFEBABE;
        return s;
    }

    /// Generate 64 bytes of random output
    pub fn fill(self: *ChaCha20State, out: *[64]u8) void {
        var working = self.state;
        // 20 rounds of ChaCha
        for (0..10) |_| {
            quarterRound(&working, 0, 4, 8, 12);
            quarterRound(&working, 1, 5, 9, 13);
            quarterRound(&working, 2, 6, 10, 14);
            quarterRound(&working, 3, 7, 11, 15);
            quarterRound(&working, 0, 5, 10, 15);
            quarterRound(&working, 1, 6, 11, 12);
            quarterRound(&working, 2, 7, 8, 13);
            quarterRound(&working, 3, 4, 9, 14);
        }
        for (0..16) |i| {
            working[i] +%= self.state[i];
        }
        // Serialize to bytes
        for (0..16) |i| {
            std.mem.writeInt(u32, out[i*4..][0..4], working[i], .little);
        }
        // Increment counter
        self.state[12] +%= 1;
        if (self.state[12] == 0) self.state[13] +%= 1;
    }

    fn quarterRound(s: *[16]u32, a: usize, b: usize, c: usize, d: usize) void {
        s[a] +%= s[b]; s[d] ^= s[a]; s[d] = std.math.rotl(u32, s[d], 16);
        s[c] +%= s[d]; s[b] ^= s[c]; s[b] = std.math.rotl(u32, s[b], 12);
        s[a] +%= s[b]; s[d] ^= s[a]; s[d] = std.math.rotl(u32, s[d], 8);
        s[c] +%= s[d]; s[b] ^= s[c]; s[b] = std.math.rotl(u32, s[b], 7);
    }
};

/// Kernel CSPRNG — singleton, seeded at boot
var kernel_rng: ?ChaCha20State = null;

/// Initialize entropy at boot — must be called after CPU init
pub fn init() void {
    var seed: [32]u8 = undefined;
    // Seed from RDRAND (8 * 4 bytes = 32 bytes)
    for (0..4) |i| {
        const r = rdrand() catch blk: {
            // Fallback: mix RDTSC with i
            var tsc: u64 = 0;
            asm volatile ("rdtsc" : [tsc] "=A" (tsc));
            break :blk tsc ^ (@as(u64, i) * 0x9e3779b97f4a7c15);
        };
        std.mem.writeInt(u64, seed[i*8..][0..8], r, .little);
    }
    kernel_rng = ChaCha20State.init(seed);
}

/// Get N random bytes
pub fn getBytes(out: []u8) void {
    var rng = &(kernel_rng orelse @panic("entropy not initialized"));
    var buf: [64]u8 = undefined;
    var offset: usize = 0;
    while (offset < out.len) {
        rng.fill(&buf);
        const n = @min(buf.len, out.len - offset);
        @memcpy(out[offset..][0..n], buf[0..n]);
        offset += n;
    }
}

/// Get a random u64
pub fn getU64() u64 {
    var buf: [8]u8 = undefined;
    getBytes(&buf);
    return std.mem.readInt(u64, &buf, .little);
}

test "ChaCha20 fills different blocks" {
    var rng = ChaCha20State.init([_]u8{0x42} ** 32);
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    rng.fill(&a);
    rng.fill(&b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "ChaCha20 deterministic" {
    var rng1 = ChaCha20State.init([_]u8{0x01} ** 32);
    var rng2 = ChaCha20State.init([_]u8{0x01} ** 32);
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    rng1.fill(&a);
    rng2.fill(&b);
    try std.testing.expect(std.mem.eql(u8, &a, &b));
}
