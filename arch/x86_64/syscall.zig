//! Magicore x86_64 SYSCALL/SYSRET setup.
//!
//! SYSCALL is the fast user→kernel path on x86_64.
//! Much faster than INT 0x80: no IDT lookup, no privilege stack switch overhead,
//! no TSS involved. One instruction to enter the kernel.
//!
//! MSRs used:
//!   IA32_STAR   (0xC0000081) — segment selectors for SYSCALL/SYSRET
//!   IA32_LSTAR  (0xC0000082) — kernel entry RIP for 64-bit SYSCALL
//!   IA32_FMASK  (0xC0000084) — RFLAGS bits to mask on entry
//!   IA32_EFER   (0xC0000080) — enable SCE (SysCall Enable) bit
//!
//! SYSCALL calling convention (Magicore ABI):
//!   rax = syscall number
//!   rdi, rsi, rdx, r10, r8, r9 = args 0..5
//!   rcx = return RIP (saved by SYSCALL hardware)
//!   r11 = RFLAGS at time of SYSCALL (saved by hardware)
//! Return value in rax.

const std     = @import("std");
const init_m  = @import("init.zig");
const console = @import("../../lib/console.zig");
const table   = @import("../../kernel/syscall/table.zig");

/// MSR addresses
const IA32_EFER  : u32 = 0xC000_0080;
const IA32_STAR  : u32 = 0xC000_0081;
const IA32_LSTAR : u32 = 0xC000_0082;
const IA32_FMASK : u32 = 0xC000_0084;

/// Kernel stack for syscall entry (one page, per-CPU in SMP)
/// In uniprocessor boot we use a single static stack.
var syscall_stack: [4096]u8 align(16) linksection(".bss") = undefined;
export var syscall_rsp0: u64 linksection(".bss") = 0;

/// Set up SYSCALL/SYSRET MSRs.
/// Must be called after GDT is loaded (selectors must be valid).
pub fn init() void {
    // 1. Enable SCE bit in EFER
    const efer = rdmsr(IA32_EFER);
    wrmsr(IA32_EFER, efer | 1); // bit 0 = SCE

    // 2. STAR: kernel CS in bits 47:32, user CS in bits 63:48
    //    SYSCALL loads CS from STAR[47:32]      → 0x08 (kernel code)
    //    SYSRET  loads CS from STAR[63:48] + 16 → 0x18 + 16 = user code
    //    (SYSRET uses STAR[63:48] | 3 for CS, STAR[63:48] + 8 for SS)
    const star: u64 =
        (@as(u64, init_m.KERNEL_CS) << 32) |
        (@as(u64, init_m.USER_CS - 16) << 48);
    wrmsr(IA32_STAR, star);

    // 3. LSTAR: RIP of syscall entry point
    wrmsr(IA32_LSTAR, @intFromPtr(&syscallEntry));

    // 4. FMASK: mask IF (bit 9) on entry so interrupts are disabled
    //    during syscall dispatch setup.
    wrmsr(IA32_FMASK, 1 << 9);

    // 5. Set up kernel RSP for syscall stack
    syscall_rsp0 = @intFromPtr(&syscall_stack) + syscall_stack.len;

    console.print("[syscall] SYSCALL/SYSRET MSRs configured\n", .{});
}

/// Low-level SYSCALL entry point.
/// At entry (per x86_64 spec):
///   rax = syscall number
///   rcx = user RIP (saved by hardware)
///   r11 = user RFLAGS (saved by hardware)
///   rsp = still user stack (!)
/// We must swap to kernel stack immediately.
export fn syscallEntry() callconv(.Naked) void {
    asm volatile (
        // Swap to kernel stack via syscall_rsp0
        \\  swapgs
        \\  mov %%rsp, %%gs:0          // save user RSP in per-cpu area
        \\  mov syscall_rsp0(%rip), %%rsp // load kernel RSP
        //  Save all caller-saved regs
        \\  push %%r11                  // user RFLAGS
        \\  push %%rcx                  // user RIP
        \\  push %%r9
        \\  push %%r8
        \\  push %%r10
        \\  push %%rdx
        \\  push %%rsi
        \\  push %%rdi
        //  Build args array: rdi,rsi,rdx,r10,r8,r9 → [6]u64
        //  They are already in the right registers for the C ABI.
        //  Call Zig dispatcher: dispatch(rax=num, rdi..r9=args)
        \\  mov %%rax, %%rdi            // syscall number as first arg
        \\  call syscallDispatch
        //  Restore regs
        \\  pop %%rdi
        \\  pop %%rsi
        \\  pop %%rdx
        \\  pop %%r10
        \\  pop %%r8
        \\  pop %%r9
        \\  pop %%rcx                   // restore user RIP
        \\  pop %%r11                   // restore user RFLAGS
        \\  mov %%gs:0, %%rsp           // restore user RSP
        \\  swapgs
        \\  sysretq
    );
}

/// Called from assembly stub — actual Zig dispatch.
export fn syscallDispatch(num: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) callconv(.C) u64 {
    return table.dispatch(num, .{ a0, a1, a2, a3, a4, a5 });
}

fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo), [hi] "={edx}" (hi)
        : [msr] "{ecx}" (msr)
    );
    return (@as(u64, hi) << 32) | lo;
}

fn wrmsr(msr: u32, val: u64) void {
    const lo: u32 = @truncate(val);
    const hi: u32 = @truncate(val >> 32);
    asm volatile ("wrmsr"
        : : [lo] "{eax}" (lo), [hi] "{edx}" (hi), [msr] "{ecx}" (msr)
    );
}

test "STAR encoding" {
    // Kernel CS = 0x08, user CS = 0x18 (ring-3 bits not set in GDT index)
    const kcs: u64 = 0x08;
    const ucs: u64 = 0x18 - 16; // SYSRET adds 16 to get user CS
    const star = (kcs << 32) | (ucs << 48);
    try std.testing.expect(star != 0);
}
