//! Magicore x86_64 page fault handler.
//! IDT vector 14 (#PF). Called from the low-level exception stub in init.zig.
//!
//! CR2 holds the faulting virtual address.
//! Error code bits:
//!   bit 0: 0=not-present fault, 1=protection violation
//!   bit 1: 0=read, 1=write
//!   bit 2: 0=kernel, 1=user mode
//!   bit 4: instruction fetch
//!
//! The handler:
//!   1. Reads CR2 and the error code.
//!   2. Checks if there is a current process with an AddressSpace.
//!   3. If yes: delegates to AddressSpace.handleFault().
//!   4. If no (kernel fault): panic immediately.

const std     = @import("std");
const vmm     = @import("../kernel/mm/vmm.zig");
const console = @import("../lib/console.zig");

/// x86_64 interrupt frame pushed by hardware + our stub
/// (error code already on stack before calling this)
pub const InterruptFrame = extern struct {
    // General-purpose regs saved by stub (in push order)
    r15: u64, r14: u64, r13: u64, r12: u64,
    r11: u64, r10: u64, r9:  u64, r8:  u64,
    rsi: u64, rdi: u64, rbp: u64, rdx: u64,
    rcx: u64, rbx: u64, rax: u64,
    // Hardware-pushed exception frame
    error_code: u64,
    rip:        u64,
    cs:         u64,
    rflags:     u64,
    rsp:        u64,
    ss:         u64,
};

/// Current process address space pointer.
/// Set by the scheduler when switching tasks. Null in early boot.
pub var current_as: ?*vmm.AddressSpace = null;

/// Page fault handler — called from IDT vector 14 stub.
/// `frame` points to the interrupt frame on the kernel stack.
pub fn handlePageFault(frame: *InterruptFrame) void {
    // Read CR2: faulting virtual address
    const fault_vaddr: u64 = asm volatile ("mov %%cr2, %[out]"
        : [out] "=r" (-> u64)
    );

    const error_code  = frame.error_code;
    const present     = (error_code & 1) != 0;  // protection fault if true
    const write_fault = (error_code & 2) != 0;
    const user_fault  = (error_code & 4) != 0;

    // Kernel fault with no current address space = unrecoverable
    if (!user_fault and current_as == null) {
        console.print("[#PF] KERNEL page fault\n", .{});
        console.print("[#PF]   vaddr=0x{X:0>16} rip=0x{X:0>16}\n", .{ fault_vaddr, frame.rip });
        console.print("[#PF]   error=0x{X} present={} write={} user={}\n", .{
            error_code, present, write_fault, user_fault,
        });
        console.panic("kernel page fault — halting", .{});
    }

    const as = current_as orelse {
        // User fault but no task — shouldn't happen; panic
        console.panic("#PF: no current_as for user fault at 0x{X:0>16}", .{fault_vaddr});
    };

    as.handleFault(fault_vaddr, write_fault) catch |err| switch (err) {
        error.SegFault => {
            console.print("[#PF] SIGSEGV vaddr=0x{X:0>16} rip=0x{X:0>16}\n", .{
                fault_vaddr, frame.rip,
            });
            // TODO: send SIGSEGV to current process / terminate task
            // For now: halt until process model is in place
            console.panic("unhandled user SIGSEGV", .{});
        },
        error.OutOfMemory => {
            console.print("[#PF] OOM during fault at 0x{X:0>16}\n", .{fault_vaddr});
            console.panic("OOM in page fault handler", .{});
        },
    };
}
