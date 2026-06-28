//! Magicore init — PID 1.
//! The first userspace process. Built as a freestanding ELF64 binary.
//! Syscall ABI: rax=number, rdi/rsi/rdx/r10/r8/r9 = args.
//!
//! This binary is baked into the kernel image as initrd.
//! It is the simplest possible userspace process:
//!   1. write(1, "Hello from Magicore userspace!\n", 32)
//!   2. exit(0)

// Syscall numbers (must match kernel/syscall/table.zig)
const SYS_WRITE: u64 = 23;
const SYS_EXIT:  u64 = 0;

const MSG = "Hello from Magicore userspace!\n";

export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        // write(1, MSG, 32)
        \\  mov $23, %%rax          // SYS_WRITE
        \\  mov $1,  %%rdi          // fd = stdout
        \\  lea msg(%%rip), %%rsi   // buf
        \\  mov $32, %%rdx          // count
        \\  syscall
        // exit(0)
        \\  mov $0, %%rax           // SYS_EXIT
        \\  mov $0, %%rdi           // code = 0
        \\  syscall
        // Should not reach here
        \\  ud2
        \\  .section .rodata
        \\  msg: .ascii "Hello from Magicore userspace!\n"
        \\  .text
        :
        :
        :
    );
}
