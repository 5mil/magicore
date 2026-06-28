//! Magicore x86_64 context switch.
//!
//! switch_to(prev, next):
//!   1. Saves all callee-saved regs + RSP of `prev` onto its kernel stack.
//!   2. Loads `next`'s kernel stack pointer.
//!   3. Restores callee-saved regs of `next`.
//!   4. Returns into `next`'s kernel context (which may be a fresh IRETQ frame).
//!
//! First-time task entry:
//!   A new task's kernel stack is pre-loaded with an IRETQ frame:
//!     [0] user RIP
//!     [1] user CS  (0x18 | 3)
//!     [2] RFLAGS   (IF set)
//!     [3] user RSP (bottom of user stack page)
//!     [4] user SS  (0x20 | 3)
//!   switch_to restores callee-saved regs (all zero for a fresh task),
//!   then `ret` inside the stub pops into `task_entry_trampoline`,
//!   which executes IRETQ into userspace.
//!
//! TSS RSP0 is updated before every IRETQ so that the next syscall
//! or interrupt finds the correct kernel stack.

const std     = @import("std");
const mm      = @import("../../kernel/mm/mm.zig");
const console = @import("../../lib/console.zig");

// ----------------------------------------------------------------
// Saved context (callee-saved regs + RSP)
// ----------------------------------------------------------------

/// Saved kernel register context for a task.
/// Stored at the TOP of the task's kernel stack.
pub const KernelContext = extern struct {
    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    rbx: u64 = 0,
    rbp: u64 = 0,
    /// Return address — for a fresh task this points to `task_entry_trampoline`.
    rip: u64 = 0,
};

// ----------------------------------------------------------------
// IRETQ frame (pushed on kernel stack for first entry to userspace)
// ----------------------------------------------------------------

pub const IretFrame = extern struct {
    rip:    u64,
    cs:     u64,
    rflags: u64,
    rsp:    u64,
    ss:     u64,
};

pub const USER_CS: u64 = 0x18 | 3;
pub const USER_SS: u64 = 0x20 | 3;
pub const RFLAGS_IF: u64 = 1 << 9; // interrupt-enable flag

// ----------------------------------------------------------------
// TSS (Task State Segment) — one per CPU
// Only RSP0 matters for us (kernel stack on interrupt/syscall from ring 3)
// ----------------------------------------------------------------

pub const Tss = extern struct {
    reserved0:  u32 = 0,
    rsp0:       u64 = 0, // kernel stack for ring-3 → ring-0 transitions
    rsp1:       u64 = 0,
    rsp2:       u64 = 0,
    reserved1:  u64 = 0,
    ist:        [7]u64 = [_]u64{0} ** 7,
    reserved2:  u64 = 0,
    reserved3:  u16 = 0,
    iopb_off:   u16 = @sizeOf(Tss),
};

pub var tss: Tss align(16) linksection(".bss") = .{};

/// Load TR (task register) with TSS selector.
/// TSS descriptor must be in the GDT at selector 0x28.
pub fn loadTss() void {
    asm volatile ("ltr %[sel]" : : [sel] "r" (@as(u16, 0x28)));
}

/// Update TSS.RSP0 to the top of `task`'s kernel stack.
/// Called before every IRETQ into userspace.
pub inline fn setRsp0(kernel_stack_top: u64) void {
    tss.rsp0 = kernel_stack_top;
}

// ----------------------------------------------------------------
// Trampoline: called as `ret` target for first-time task entry
// Executes IRETQ using the frame already on the stack
// ----------------------------------------------------------------

export fn taskEntryTrampoline() callconv(.Naked) noreturn {
    asm volatile (
        \\  // Stack at this point: ... | IretFrame (5 u64s) |
        \\  // RSP points just below the frame. IRETQ pops 5 words.
        \\  swapgs          // switch to user GS (gs_base = 0 for now)
        \\  iretq
    );
}

// ----------------------------------------------------------------
// switch_to: the actual context switch
// ----------------------------------------------------------------

/// Switch from `prev` to `next`.
/// prev_rsp: pointer to where we save prev's RSP
/// next_rsp: next's saved RSP (loaded from next's KernelContext)
export fn switchTo(
    prev_rsp_ptr: *u64, // [rdi] &prev.saved_rsp
    next_rsp:     u64,  // [rsi] next.saved_rsp
    rsp0:         u64,  // [rdx] top of next's kernel stack (for TSS)
) callconv(.Naked) void {
    asm volatile (
        // Save callee-saved registers of prev onto its kernel stack
        \\  push %%rbp
        \\  push %%rbx
        \\  push %%r12
        \\  push %%r13
        \\  push %%r14
        \\  push %%r15
        // Save prev's RSP
        \\  mov %%rsp, (%%rdi)
        // Update TSS.RSP0 for next task (next kernel stack top via rdx)
        \\  lea tss(%%rip), %%rax
        \\  mov %%rdx, 4(%%rax)    // tss.rsp0 is at offset 4
        // Load next's RSP
        \\  mov %%rsi, %%rsp
        // Restore callee-saved registers of next
        \\  pop %%r15
        \\  pop %%r14
        \\  pop %%r13
        \\  pop %%r12
        \\  pop %%rbx
        \\  pop %%rbp
        // Return into next's kernel context
        // (For a fresh task: returns into taskEntryTrampoline → IRETQ)
        \\  ret
        :
        : [prev_rsp_ptr] "{rdi}" (prev_rsp_ptr),
          [next_rsp]     "{rsi}" (next_rsp),
          [rsp0]         "{rdx}" (rsp0)
        : "memory"
    );
}

// ----------------------------------------------------------------
// Build a fresh kernel stack for a new task
// ----------------------------------------------------------------

/// Prepare a new task's kernel stack so that switch_to will
/// IRETQ into userspace at `user_rip` with `user_rsp`.
///
/// Stack layout (high to low):
///   IretFrame (5 * u64)
///   KernelContext (rip = &taskEntryTrampoline, regs = 0)
///
/// Returns the RSP value to store in Task.saved_rsp.
pub fn buildKernelStack(
    kstack_top:  u64,  // physical address of top of the 4KB kernel stack
    user_rip:    u64,
    user_rsp:    u64,
    hhdm_offset: u64,
) u64 {
    var sp: u64 = mm.physToVirt(kstack_top) + hhdm_offset;

    // Push IRETQ frame
    sp -= @sizeOf(IretFrame);
    const frame: *IretFrame = @ptrFromInt(sp);
    frame.* = .{
        .rip    = user_rip,
        .cs     = USER_CS,
        .rflags = RFLAGS_IF,
        .rsp    = user_rsp,
        .ss     = USER_SS,
    };

    // Push KernelContext (callee-saved = 0, rip = trampoline)
    sp -= @sizeOf(KernelContext);
    const kctx: *KernelContext = @ptrFromInt(sp);
    kctx.* = .{ .rip = @intFromPtr(&taskEntryTrampoline) };

    return sp; // this is next.saved_rsp
}

// ----------------------------------------------------------------
// Tests
// ----------------------------------------------------------------

test "IretFrame size" {
    try std.testing.expectEqual(@sizeOf(IretFrame), 40);
}

test "KernelContext size" {
    try std.testing.expectEqual(@sizeOf(KernelContext), 56);
}

test "TSS iopb offset" {
    try std.testing.expectEqual(tss.iopb_off, @sizeOf(Tss));
}

test "USER_CS ring bits" {
    try std.testing.expectEqual(USER_CS & 3, 3);
    try std.testing.expectEqual(USER_SS & 3, 3);
}
